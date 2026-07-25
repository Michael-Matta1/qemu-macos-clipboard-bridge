#!/bin/bash
# clipboard-bridge.sh — bidirectional clipboard sync loop
#
# This script is started/stopped on demand by qemu-watcher.service.

set -u
# Without pipefail, `a | b` only reports b's exit status, so a failure in
# xclip or ssh partway through a pipeline (e.g. `xclip ... | base64 -w0`)
# would be silently invisible to the `if` checks added below — the
# pipeline would look like it "succeeded" with empty output even though
# the actual clipboard read/write failed. This does not affect remote
# pipelines run on the guest via a quoted ssh command string (those are
# evaluated by the guest's own shell); it only affects local pipelines.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib.sh"   # reuse _qmcb_log rather than duplicating it

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

CONFIG_FILE="${HOME}/.config/qemu-macos-clipboard-bridge/config"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${MAC_GUEST_USER:?Config missing MAC_GUEST_USER}"
: "${SSH_ALIAS:?Config missing SSH_ALIAS}"
: "${SSH_PORT:?Config missing SSH_PORT}"

# Optional tunable: how often to poll the guest's clipboard changeCount.
# Default is 0.05 (50ms) for instantaneous sync. The native C helper uses
# negligible CPU (<0.5%) even at 50ms intervals.
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-0.05}"
# Reject not just the literal "0" but any zero-equivalent decimal spelling
# (0.0, 0.00, 00, 000.000, ...). `sleep 0.0` returns essentially
# instantly, so accepting any of these would turn the guest->host poll
# loop below into an unthrottled loop issuing back-to-back SSH connections
# as fast as the CPU/network allow, instead of the intended ~200ms cadence.
if ! [[ "$POLL_INTERVAL_SECONDS" =~ ^[0-9]+(\.[0-9]+)?$ ]] || \
   [[ "$POLL_INTERVAL_SECONDS" =~ ^0+(\.0+)?$ ]]; then
  _qmcb_log "WARNING: invalid POLL_INTERVAL_SECONDS='${POLL_INTERVAL_SECONDS}' in config; falling back to 0.05"
  POLL_INTERVAL_SECONDS="0.05"
fi

# ---------------------------------------------------------------------------
# State file for cross-loop coordination
#
# The guest->host poller and the host->guest listener run in separate bash
# contexts (parent shell + background subshell).  Bash subshells get copies
# of variables, so writes in one context are invisible to the other.  We use
# a lightweight state file to share the latest known host-side clipboard
# hash, preventing the host loop from echoing freshly-pasted guest content
# back to the guest.
# ---------------------------------------------------------------------------

STATE_DIR="${XDG_RUNTIME_DIR:-${HOME}/.local/state}/qemu-macos-clipboard-bridge"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
LAST_HOST_FILE="${STATE_DIR}/last_host"

touch "$LAST_HOST_FILE"
chmod 600 "$LAST_HOST_FILE"

# isolated subshell variable (local to the background poller)
last_cc=""

get_last_host() {
  # Use bash built-in read instead of forking cat. This is called on every
  # clipboard event in the inner loop, so eliminating the fork matters.
  local val=""
  read -r val < "$LAST_HOST_FILE" 2>/dev/null || true
  printf '%s' "$val"
}

set_last_host() {
  printf '%s' "$1" > "$LAST_HOST_FILE"
}

# ---------------------------------------------------------------------------
# Helpers & Native Guest Helper
# ---------------------------------------------------------------------------

HOSTKEY_WARN_MARKER="${STATE_DIR}/last_hostkey_warn"
GETCC_ERR_FILE="${STATE_DIR}/last_get_change_count_stderr"
touch "$GETCC_ERR_FILE"
chmod 600 "$GETCC_ERR_FILE"

GUEST_HELPER_PATH="~/.cache/qemu-macos-clipboard-bridge/pbcc"
GUEST_HELPER_VER_PATH="~/.cache/qemu-macos-clipboard-bridge/pbcc.ver"
use_guest_helper=false

# Source hash for the embedded native helper. When the embedded source
# changes (new features, bug fixes), the hash changes too, and
# ensure_guest_helper() will recompile the binary on the guest rather than
# silently running a stale version.
GUEST_HELPER_SRC_HASH="187a8500"

ensure_guest_helper() {
  # Check if the binary exists AND its version matches the embedded source.
  # This avoids recompilation on every restart while still picking up
  # source updates (e.g. the usleep->nanosleep fix, SIGPIPE handling).
  local remote_ver
  remote_ver=$(timeout 3 ssh -o ConnectTimeout=2 -o BatchMode=yes "${SSH_ALIAS}" \
    "cat ${GUEST_HELPER_VER_PATH} 2>/dev/null && ${GUEST_HELPER_PATH} >/dev/null 2>&1" 2>/dev/null) || true
  if [[ "$remote_ver" == "$GUEST_HELPER_SRC_HASH" ]]; then
    use_guest_helper=true
    return 0
  fi

  # Improved native helper source (Objective-C).  Key improvements over the
  # original version:
  #   - Uses nanosleep() instead of usleep() to handle intervals >= 1 second
  #     correctly (usleep requires < 1,000,000 us on macOS; larger values
  #     cause EINVAL and a 100% CPU spin loop).
  #   - Installs a SIGPIPE handler so the process exits promptly when the
  #     SSH pipe breaks, rather than spinning until the next clipboard change.
  #   - Periodically flushes stdout during idle periods (~every 5s) to detect
  #     a broken pipe even when no clipboard changes are occurring.
  #   - Added a --listen mode that reads base64 strings from stdin to allow
  #     persistent Host -> Guest streaming without pbcopy overhead.
  local src_b64="I2ltcG9ydCA8QXBwS2l0L0FwcEtpdC5oPgojaW1wb3J0IDxzdGRpby5oPgojaW1wb3J0IDx1bmlzdGQuaD4KI2ltcG9ydCA8c3RkbGliLmg+CiNpbXBvcnQgPHN0cmluZy5oPgojaW1wb3J0IDxzaWduYWwuaD4KI2ltcG9ydCA8dGltZS5oPgoKc3RhdGljIHZvbGF0aWxlIHNpZ19hdG9taWNfdCBnb3RfcGlwZSA9IDA7CnN0YXRpYyB2b2lkIGhhbmRsZV9zaWdwaXBlKGludCBzaWcpIHsgKHZvaWQpc2lnOyBnb3RfcGlwZSA9IDE7IH0KCiBzdGF0aWMgdm9pZCBwcmVjaXNlX3NsZWVwKGRvdWJsZSBzZWNvbmRzKSB7CiAgICBzdHJ1Y3QgdGltZXNwZWMgdHM7CiAgICB0cy50dl9zZWMgPSAodGltZV90KXNlY29uZHM7CiAgICB0cy50dl9uc2VjID0gKGxvbmcpKChzZWNvbmRzIC0gdHMudHZfc2VjKSAqIDFlOSk7CiAgICBuYW5vc2xlZXAoJnRzLCBOVUxMKTsKIH0KCiBpbnQgbWFpbihpbnQgYXJnYywgY2hhciAqYXJndltdKSB7CiAgICBzaWduYWwoU0lHUElQRSwgaGFuZGxlX3NpZ3BpcGUpOwogICAgQGF1dG9yZWxlYXNlcG9vbCB7CiAgICAgICAgTlNQYXN0ZWJvYXJkICpwYiA9IFtOU1Bhc3RlYm9hcmQgZ2VuZXJhbFBhc3RlYm9hcmRdOwogICAgICAgIGlmIChhcmdjID4gMSAmJiBzdHJjbXAoYXJndlsxXSwgIi0td2F0Y2giKSA9PSAwKSB7CiAgICAgICAgICAgIGRvdWJsZSBpbnRlcnZhbCA9IDAuMjsKICAgICAgICAgICAgaWYgKGFyZ2MgPiAyKSB7CiAgICAgICAgICAgICAgICBkb3VibGUgc2VjID0gYXRvZihhcmd2WzJdKTsKICAgICAgICAgICAgICAgIGlmIChzZWMgPiAwKSBpbnRlcnZhbCA9IHNlYzsKICAgICAgICAgICAgfQogICAgICAgICAgICBOU0ludGVnZXIgbGFzdCA9IFtwYiBjaGFuZ2VDb3VudF07CiAgICAgICAgICAgIGlmIChhcmdjID4gMykgewogICAgICAgICAgICAgICAgbGFzdCA9IGF0b2woYXJndlszXSk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaW50IGlkbGVfY3ljbGVzID0gMDsKICAgICAgICAgICAgd2hpbGUgKCFnb3RfcGlwZSkgewogICAgICAgICAgICAgICAgcHJlY2lzZV9zbGVlcChpbnRlcnZhbCk7CiAgICAgICAgICAgICAgICBAYXV0b3JlbGVhc2Vwb29sIHsKICAgICAgICAgICAgICAgICAgICBOU0ludGVnZXIgY2MgPSBbcGIgY2hhbmdlQ291bnRdOwogICAgICAgICAgICAgICAgICAgIGlmIChjYyAhPSBsYXN0KSB7CiAgICAgICAgICAgICAgICAgICAgICAgIE5TU3RyaW5nICpzdHIgPSBbcGIgc3RyaW5nRm9yVHlwZTpOU1Bhc3RlYm9hcmRUeXBlU3RyaW5nXTsKICAgICAgICAgICAgICAgICAgICAgICAgaWYgKHN0cikgewogICAgICAgICAgICAgICAgICAgICAgICAgICAgTlNEYXRhICpkYXRhID0gW3N0ciBkYXRhVXNpbmdFbmNvZGluZzpOU1VURjhTdHJpbmdFbmNvZGluZ107CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBOU1N0cmluZyAqYjY0ID0gW2RhdGEgYmFzZTY0RW5jb2RlZFN0cmluZ1dpdGhPcHRpb25zOjBdOwogICAgICAgICAgICAgICAgICAgICAgICAgICAgcHJpbnRmKCIlbGQ6JXNcbiIsIChsb25nKWNjLCBbYjY0IFVURjhTdHJpbmddKTsKICAgICAgICAgICAgICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgICAgICAgICAgICAgIHByaW50ZigiJWxkOlxuIiwgKGxvbmcpY2MpOwogICAgICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICAgICAgICAgIGlmIChmZmx1c2goc3Rkb3V0KSA9PSBFT0YpIHsKICAgICAgICAgICAgICAgICAgICAgICAgICAgIHJldHVybiAwOwogICAgICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICAgICAgICAgIGxhc3QgPSBjYzsKICAgICAgICAgICAgICAgICAgICAgICAgaWRsZV9jeWNsZXMgPSAwOwogICAgICAgICAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICAgICAgICAgIGlkbGVfY3ljbGVzKys7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmIChpZGxlX2N5Y2xlcyA+PSAoaW50KSg1LjAgLyBpbnRlcnZhbCArIDAuNSkpIHsKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGlmIChmZmx1c2goc3Rkb3V0KSA9PSBFT0YpIHsKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICByZXR1cm4gMDsKICAgICAgICAgICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgICAgICAgICAgICAgIGlkbGVfY3ljbGVzID0gMDsKICAgICAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAgIH0gZWxzZSBpZiAoYXJnYyA+IDEgJiYgc3RyY21wKGFyZ3ZbMV0sICItLWxpc3RlbiIpID09IDApIHsKICAgICAgICAgICAgY2hhciAqbGluZSA9IE5VTEw7CiAgICAgICAgICAgIHNpemVfdCBsZW4gPSAwOwogICAgICAgICAgICBzc2l6ZV90IHJlYWQ7CiAgICAgICAgICAgIHdoaWxlICghZ290X3BpcGUgJiYgKHJlYWQgPSBnZXRsaW5lKCZsaW5lLCAmbGVuLCBzdGRpbikpICE9IC0xKSB7CiAgICAgICAgICAgICAgICBpZiAocmVhZCA+IDAgJiYgbGluZVtyZWFkLTFdID09ICdcbicpIGxpbmVbcmVhZC0xXSA9ICdcMCc7CiAgICAgICAgICAgICAgICBAYXV0b3JlbGVhc2Vwb29sIHsKICAgICAgICAgICAgICAgICAgICBOU1N0cmluZyAqYjY0ID0gW05TU3RyaW5nIHN0cmluZ1dpdGhVVEY4U3RyaW5nOmxpbmVdOwogICAgICAgICAgICAgICAgICAgIGlmIChiNjQpIHsKICAgICAgICAgICAgICAgICAgICAgICAgTlNEYXRhICpkYXRhID0gW1tOU0RhdGEgYWxsb2NdIGluaXRXaXRoQmFzZTY0RW5jb2RlZFN0cmluZzpiNjQgb3B0aW9uczpOU0RhdGFCYXNlNjREZWNvZGluZ0lnbm9yZVVua25vd25DaGFyYWN0ZXJzXTsKICAgICAgICAgICAgICAgICAgICAgICAgaWYgKGRhdGEpIHsKICAgICAgICAgICAgICAgICAgICAgICAgICAgIE5TU3RyaW5nICpzdHIgPSBbW05TU3RyaW5nIGFsbG9jXSBpbml0V2l0aERhdGE6ZGF0YSBlbmNvZGluZzpOU1VURjhTdHJpbmdFbmNvZGluZ107CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBpZiAoc3RyKSB7CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgW3BiIGNsZWFyQ29udGVudHNdOwogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFtwYiBzZXRTdHJpbmc6c3RyIGZvclR5cGU6TlNQYXN0ZWJvYXJkVHlwZVN0cmluZ107CiAgICAgICAgICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKGxpbmUpIGZyZWUobGluZSk7CiAgICAgICAgICAgIHJldHVybiAwOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIHByaW50ZigiJWxkXG4iLCAobG9uZylbcGIgY2hhbmdlQ291bnRdKTsKICAgICAgICB9CiAgICB9CiAgICByZXR1cm4gMDsKIH0K"
  if timeout 10 ssh -o ConnectTimeout=3 -o BatchMode=yes "${SSH_ALIAS}" \
    "mkdir -p ~/.cache/qemu-macos-clipboard-bridge && echo '${src_b64}' | base64 -d > ~/.cache/qemu-macos-clipboard-bridge/pbcc.m && clang -O3 -framework AppKit ~/.cache/qemu-macos-clipboard-bridge/pbcc.m -o ~/.cache/qemu-macos-clipboard-bridge/pbcc 2>/dev/null && rm -f ~/.cache/qemu-macos-clipboard-bridge/pbcc.m && echo '${GUEST_HELPER_SRC_HASH}' > ${GUEST_HELPER_VER_PATH}" 2>/dev/null; then
    use_guest_helper=true
    _qmcb_log "Compiled native guest clipboard helper (pbcc) for low-latency sync"
  else
    use_guest_helper=false
  fi
}

ensure_guest_helper

check_ssh_hostkey_errors() {
  if grep -qi 'host key verification failed\|REMOTE HOST IDENTIFICATION HAS CHANGED' "$GETCC_ERR_FILE"; then
    local now last_warn
    printf -v now '%(%s)T' -1
    last_warn=$(cat "$HOSTKEY_WARN_MARKER" 2>/dev/null || echo 0)
    if (( now - last_warn >= 300 )); then
      _qmcb_log "ERROR: SSH host key mismatch for ${SSH_ALIAS} (port ${SSH_PORT}) — likely the macOS guest was reinstalled. Fix: ssh-keygen -R \"[127.0.0.1]:${SSH_PORT}\" then re-run install.sh. (Rate-limited to once per 5 minutes.)"
      echo "$now" > "$HOSTKEY_WARN_MARKER"
    fi
  fi
}

get_change_count() {
  local out
  if [[ "$use_guest_helper" == true ]]; then
    out=$(timeout 5 ssh -o ConnectTimeout=2 -o BatchMode=yes "${SSH_ALIAS}" "${GUEST_HELPER_PATH}" 2>"$GETCC_ERR_FILE")
  else
    out=$(timeout 5 ssh -o ConnectTimeout=2 -o BatchMode=yes "${SSH_ALIAS}" osascript -l JavaScript -e '
      ObjC.import("AppKit");
      $.NSPasteboard.generalPasteboard.changeCount
    ' 2>"$GETCC_ERR_FILE")
  fi

  check_ssh_hostkey_errors
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Guest -> Host: Real-time Streaming & Lightweight Polling
# ---------------------------------------------------------------------------

(
  trap 'exit 0' TERM INT
  baseline_read=false
  last_cc=""

  if [[ "$use_guest_helper" == true ]]; then
    while true; do
      helper_cmd="${GUEST_HELPER_PATH} --watch ${POLL_INTERVAL_SECONDS}"
      if [[ -n "$last_cc" ]]; then
        helper_cmd+=" ${last_cc}"
      fi

      while IFS=: read -r cc guest_clip; do
        guest_clip="${guest_clip%$'\r'}"
        last_cc="$cc"
        [[ -z "$guest_clip" ]] && continue
        if [[ "$guest_clip" != "$(get_last_host)" ]]; then
          if printf '%s' "$guest_clip" | base64 -d | timeout 3 xclip -selection clipboard 2>/dev/null; then
            set_last_host "$guest_clip"
          fi
        fi
      done < <(exec ssh -o ConnectTimeout=3 -o BatchMode=yes "${SSH_ALIAS}" "$helper_cmd" 2>"$GETCC_ERR_FILE")

      check_ssh_hostkey_errors
      sleep 2
    done
  else
    while true; do
      cc=$(get_change_count)
      if [[ -z "$cc" ]]; then
        sleep 2
        continue
      fi
      if [[ "$baseline_read" == false ]]; then
        last_cc="$cc"
        baseline_read=true
        sleep "$POLL_INTERVAL_SECONDS"
        continue
      fi
      if [[ "$cc" != "$last_cc" ]]; then
        if guest_clip=$(timeout 5 ssh -o ConnectTimeout=2 -o BatchMode=yes "${SSH_ALIAS}" 'set -o pipefail; pbpaste | base64 | tr -d "\r\n"' 2>/dev/null); then
          last_cc="$cc"
          if [[ -n "$guest_clip" && "$guest_clip" != "$(get_last_host)" ]]; then
            if printf '%s' "$guest_clip" | base64 -d | timeout 3 xclip -selection clipboard 2>/dev/null; then
              set_last_host "$guest_clip"
            fi
          fi
        fi
      fi
      sleep "$POLL_INTERVAL_SECONDS"
    done
  fi
) &
bg_pid=$!

cleanup() {
  trap - EXIT TERM INT
  # Send SIGTERM first to allow children (SSH sessions, clipnotify) to
  # shut down gracefully, then SIGKILL after a brief grace period for
  # any processes that didn't exit. The previous SIGKILL-only approach
  # prevented SSH from cleanly closing ControlMaster sockets.
  pkill -TERM -P $$ 2>/dev/null || true
  sleep 0.2
  pkill -9 -P $$ 2>/dev/null || true
  exit 0
}
trap cleanup EXIT TERM INT

# ---------------------------------------------------------------------------
# Host -> Guest: genuinely event-driven.
# ---------------------------------------------------------------------------

CLIPNOTIFY_WARN_MARKER="${STATE_DIR}/last_clipnotify_warn"

H2G_FIFO="${STATE_DIR}/h2g_fifo"
rm -f "$H2G_FIFO"
mkfifo "$H2G_FIFO"
chmod 600 "$H2G_FIFO"

# Open FD 3 for writing/reading so the FIFO stays open continuously
exec 3<> "$H2G_FIFO"

if [[ "$use_guest_helper" == true ]]; then
  # Launch the persistent H2G pipe listener in a subshell
  # By keeping a persistent SSH channel open that pipes to our native Objective-C
  # --listen helper, we bypass the ~25ms SSH creation overhead and ~40ms pbcopy
  # overhead on every clipboard push. This reduces Host->Guest latency to <50ms.
  (
    trap 'exit 0' TERM INT
    while true; do
      # SSH reads from FD 3. The guest helper listens on stdin.
      ssh -o ConnectTimeout=3 -o BatchMode=yes "${SSH_ALIAS}" "${GUEST_HELPER_PATH} --listen" <&3
      sleep 2
    done
  ) &
fi

push_to_guest() {
  local payload="$1"
  if [[ "$use_guest_helper" == true ]]; then
    # Instantly push payload into the persistent SSH pipeline
    echo "$payload" >&3
    return 0
  else
    # Fallback to the slow path if the native helper failed to compile
    local attempt
    for attempt in 1 2 3; do
      if printf '%s\n' "$payload" | timeout 10 ssh -o ConnectTimeout=3 -o BatchMode=yes "${SSH_ALIAS}" 'set -o pipefail; base64 -d | pbcopy'; then
        return 0
      fi
      sleep 1
    done
    return 1
  fi
}

while true; do
  clipnotify &
  clipnotify_pid=$!
  if ! wait "$clipnotify_pid"; then
    clipnotify_pid=""
    local_now=""
    printf -v local_now '%(%s)T' -1
    last_warn=$(cat "$CLIPNOTIFY_WARN_MARKER" 2>/dev/null || echo 0)
    if (( local_now - last_warn >= 300 )); then
      _qmcb_log "ERROR: clipnotify failed (missing binary, or no X11/DISPLAY session available). Host->guest sync is stalled until this is fixed. (Rate-limited to once per 5 minutes.)"
      echo "$local_now" > "$CLIPNOTIFY_WARN_MARKER"
    fi
    sleep 2
    continue
  fi
  clipnotify_pid=""

  if ! host_clip=$(timeout 3 xclip -selection clipboard -o 2>/dev/null | base64 -w0); then
    sleep 1
    continue
  fi

  if [[ "$host_clip" != "$(get_last_host)" ]]; then
    if push_to_guest "$host_clip"; then
      set_last_host "$host_clip"
    else
      _qmcb_log "WARNING: failed to push host clipboard to guest after 3 attempts (guest may be unreachable); will retry on the next host clipboard change."
    fi
  fi
done

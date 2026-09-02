#!/bin/bash
# lib.sh — shared helpers for qemu-macos-clipboard-bridge
# Sourced by both qemu-watcher.sh and install.sh.

set -u

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

_QMCB_STATE_DIR="${XDG_RUNTIME_DIR:-${HOME}/.local/state}/qemu-macos-clipboard-bridge"
mkdir -p "$_QMCB_STATE_DIR"
chmod 700 "$_QMCB_STATE_DIR"

_QMCB_LOG_MAX_BYTES=102400  # 100KB — rotated, not truncated

_qmcb_log() {
  local msg="$1"
  local ts
  # printf '%(%...)T' is a bash built-in (4.2+) that formats the current
  # time without forking a `date` subprocess. This function runs on every
  # watcher cycle and every bridge event, so the fork savings add up over
  # the weeks/months these services stay running.
  printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
  local logfile="$_QMCB_STATE_DIR/watcher.log"
  printf '%s %s\n' "$ts" "$msg" >> "$logfile"

  # Simple log rotation: if the log exceeds the cap, keep the most recent
  # half. This avoids unbounded growth on systems with long uptimes while
  # preserving enough history to be useful for troubleshooting.
  local log_size
  log_size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
  if (( log_size > _QMCB_LOG_MAX_BYTES )); then
    tail -c $(( _QMCB_LOG_MAX_BYTES / 2 )) "$logfile" > "${logfile}.tmp" 2>/dev/null
    mv -f "${logfile}.tmp" "$logfile" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# VM detection
# ---------------------------------------------------------------------------

find_mac_vm_pid() {
  local pids=()
  local pid
  # A single `pgrep -f` matching both the binary name and the isa-applesmc
  # device flag replaces the previous per-PID loop that opened and read
  # /proc/<pid>/cmdline via `tr`+`grep` for every qemu-system-x86_64
  # process found. pgrep already does this matching in-process (no forked
  # helpers per candidate), which matters here because this function runs
  # on every watcher cycle (every 5s) for as long as the user is logged
  # in — often days or weeks — so fewer forked processes per cycle adds
  # up. Semantics are unchanged: pgrep -f matches against the same
  # space-joined argv that `tr '\0' ' '` would have produced.
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(pgrep -f 'qemu.*isa-applesmc' 2>/dev/null || true)

  if [[ ${#pids[@]} -eq 0 ]]; then
    return 1
  fi

  if [[ ${#pids[@]} -gt 1 ]]; then
    # Rate-limited (once per 5 min), same pattern as the hostkey/clipnotify
    # warnings in clipboard-bridge.sh. This function runs every watcher
    # cycle (every 5s), so an unconditional log line here would write
    # ~17,000 duplicate lines/day into watcher.log for as long as two VMs
    # happen to be up at once, instead of surfacing the condition once and
    # getting out of the way.
    local now last_warn
    printf -v now '%(%s)T' -1
    last_warn=$(cat "${_QMCB_STATE_DIR}/last_multi_vm_warn" 2>/dev/null || echo 0)
    if (( now - last_warn >= 300 )); then
      _qmcb_log "WARNING: multiple macOS QEMU VMs detected (${pids[*]}); bridging only the first one (${pids[0]})"
      echo "$now" > "${_QMCB_STATE_DIR}/last_multi_vm_warn"
    fi
  fi

  echo "${pids[0]}"
}

# ---------------------------------------------------------------------------
# Port extraction
# ---------------------------------------------------------------------------

get_forwarded_port() {
  local pid="$1"
  local cmdline
  cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)

  # QEMU's hostfwd syntax is hostfwd=tcp:[hostaddr]:hostport-[guestaddr]:22
  # -- hostaddr defaults to empty (all interfaces) if omitted, but is
  # commonly set explicitly (e.g. "127.0.0.1") to restrict exposure, which
  # is exactly what install.sh's check_port_exposure() and
  # docs/TROUBLESHOOTING.md tell users to do. guestaddr is similarly
  # optional. Match both the bare "tcp::2222-:22" form and the
  # "tcp:127.0.0.1:2222-:22" / "tcp:[::1]:2222-192.168.1.5:22" forms so
  # port detection keeps working no matter which one the user's launch
  # script uses. [^:,]* covers a bare IPv4/hostname hostaddr (no colons);
  # \[...\] covers a bracketed IPv6 literal.
  if [[ "$cmdline" =~ hostfwd=tcp:(\[[0-9a-fA-F:]*\]|[^:,]*):([0-9]+)-(\[[0-9a-fA-F:]*\]|[^:,]*):22(,|$|[^0-9]) ]]; then
    echo "${BASH_REMATCH[2]}"
    return 0
  fi

  return 1
}

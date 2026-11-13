#!/bin/bash
# qemu-watcher.sh — detects macOS VM start/stop, starts/stops the bridge
#
# This is a lightweight polling watcher (always running while you are logged
# in to your X session). It does NOT wrap or modify the user's VM launch script.
#
# It can run under two service backends (SERVICE_BACKEND in the config file):
#   systemd - clipboard-bridge.service is managed via `systemctl --user`
#             (the original behaviour, and the default for older configs).
#   direct  - no systemd user manager (sysVinit, runit, OpenRC, s6, dinit ...):
#             this watcher starts and supervises clipboard-bridge.sh itself.

set -u

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${HOME}/.config/qemu-macos-clipboard-bridge/config"
SSH_CONFIG_FRAGMENT="${HOME}/.ssh/config.d/99-qemu-macos-clipboard-bridge.conf"

# ---------------------------------------------------------------------------
# Single instance (a session startup file can easily run us twice)
# ---------------------------------------------------------------------------

# The lock is taken on this script file itself rather than on a file in the
# state directory: the state directory depends on XDG_RUNTIME_DIR, which can
# differ between the contexts that launch us (login shell vs. X session), and
# a per-directory lock would then allow two watchers to run side by side.
if command -v flock >/dev/null 2>&1 && exec 8<"$0"; then
  if ! flock -n 8; then
    exit 0   # another watcher already holds the lock
  fi
fi
printf '%s\n' "$$" > "${_QMCB_STATE_DIR}/watcher.pid"

# ---------------------------------------------------------------------------
# Service backend
# ---------------------------------------------------------------------------

SERVICE_BACKEND=""
if [[ -f "$CONFIG_FILE" ]]; then
  SERVICE_BACKEND=$(grep -m1 '^SERVICE_BACKEND=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2)
fi
[[ "$SERVICE_BACKEND" == "direct" ]] || SERVICE_BACKEND="systemd"   # unknown/missing -> original behaviour

BRIDGE_SCRIPT="${SCRIPT_DIR}/clipboard-bridge.sh"
BRIDGE_PIDFILE="${_QMCB_STATE_DIR}/bridge.pid"
BRIDGE_OUT="${_QMCB_STATE_DIR}/bridge.out"

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

known_pid=""
known_port=""

# Rate-limit marker for the "failed to start clipboard-bridge.service"
# log line (see the retry branch below) -- reuses the same state dir
# lib.sh already created for watcher.log.
START_FAIL_WARN_MARKER="${_QMCB_STATE_DIR}/last_start_fail_warn"
PORT_DETECT_WARN_MARKER="${_QMCB_STATE_DIR}/last_port_detect_warn"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

update_config_port() {
  local port="$1"

  # Update runtime config (sourceable KEY="value" file)
  if [[ -f "$CONFIG_FILE" ]]; then
    if grep -q '^SSH_PORT=' "$CONFIG_FILE"; then
      sed -i "s/^SSH_PORT=.*$/SSH_PORT=\"$port\"/" "$CONFIG_FILE"
    else
      echo "SSH_PORT=\"$port\"" >> "$CONFIG_FILE"
    fi
  fi

  # Update SSH config fragment Port line
  if [[ -f "$SSH_CONFIG_FRAGMENT" ]]; then
    if grep -q '^[[:space:]]*Port ' "$SSH_CONFIG_FRAGMENT"; then
      sed -i "s/^[[:space:]]*Port .*/    Port $port/" "$SSH_CONFIG_FRAGMENT"
    else
      # Insert Port after Host line
      sed -i "/^Host /a\\    Port $port" "$SSH_CONFIG_FRAGMENT"
    fi
  fi
}

# PID of the bridge we launched ("direct" backend). Checks the command line
# to guard against a recycled PID, and rejects zombies.
direct_bridge_pid() {
  local pid
  [[ -r "$BRIDGE_PIDFILE" ]] || return 1
  read -r pid < "$BRIDGE_PIDFILE" || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  grep -qa 'clipboard-bridge\.sh' "/proc/$pid/cmdline" 2>/dev/null || return 1
  grep -q '^State:[[:space:]]*Z' "/proc/$pid/status" 2>/dev/null && return 1
  echo "$pid"
}

is_bridge_running() {
  if [[ "$SERVICE_BACKEND" == "direct" ]]; then
    direct_bridge_pid >/dev/null
  else
    systemctl --user is-active --quiet clipboard-bridge.service 2>/dev/null
  fi
}

bridge_start() {
  if [[ "$SERVICE_BACKEND" == "direct" ]]; then
    qmcb_kill_stale_bridge   # we only get here when no live bridge exists
    qmcb_cap_file "$BRIDGE_OUT" 512
    # Double-fork via a subshell so the bridge is re-parented to init (no
    # zombie in this watcher), setsid so it is detached from our session,
    # and "8>&-" so it does NOT inherit the watcher's lock (otherwise a
    # surviving bridge would block a restarted watcher from starting).
    if command -v setsid >/dev/null 2>&1; then
      ( setsid "$BRIDGE_SCRIPT" >>"$BRIDGE_OUT" 2>&1 8>&- </dev/null & )
    else
      ( nohup "$BRIDGE_SCRIPT" >>"$BRIDGE_OUT" 2>&1 8>&- </dev/null & )
    fi
    sleep 1 8>&-
    direct_bridge_pid >/dev/null
  else
    systemctl --user start clipboard-bridge.service 2>/dev/null
  fi
}

bridge_stop() {
  if [[ "$SERVICE_BACKEND" == "direct" ]]; then
    local pid i
    pid=$(direct_bridge_pid) || return 0
    kill -TERM "$pid" 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do   # ~5s, same as TimeoutStopSec in the unit
      direct_bridge_pid >/dev/null || return 0
      sleep 0.5 8>&-
    done
    kill -KILL "$pid" 2>/dev/null || true
    qmcb_kill_stale_bridge
  else
    systemctl --user stop clipboard-bridge.service 2>/dev/null
  fi
}

bridge_restart() {
  if [[ "$SERVICE_BACKEND" == "direct" ]]; then
    bridge_stop && bridge_start
  else
    systemctl --user restart clipboard-bridge.service 2>/dev/null
  fi
}

bridge_reset_failed() {
  # systemd-only concept (start-limit-hit); nothing to do for "direct".
  [[ "$SERVICE_BACKEND" == "direct" ]] || systemctl --user reset-failed clipboard-bridge.service 2>/dev/null || true
}

# Label used in log lines. Under systemd it is byte-for-byte the original
# wording ("clipboard-bridge.service"), so existing log greps keep working.
if [[ "$SERVICE_BACKEND" == "direct" ]]; then
  BRIDGE_LABEL="clipboard-bridge (direct backend)"
else
  BRIDGE_LABEL="clipboard-bridge.service"
fi

bridge_diag_hint() {
  if [[ "$SERVICE_BACKEND" == "direct" ]]; then
    printf "see %s" "$BRIDGE_OUT"
  else
    printf "run 'systemctl --user status clipboard-bridge.service' for details"
  fi
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

while true; do
  pid=$(find_mac_vm_pid 2>/dev/null || true)
  port_changed=false

  if [[ -n "$pid" ]]; then
    if [[ "$pid" != "$known_pid" ]]; then
      _qmcb_log "Detected macOS QEMU VM (PID $pid)"
      known_pid="$pid"
    fi

    # Retry on every cycle until the command line is readable and contains a
    # forwarding rule. QEMU can be observable by pgrep briefly before its
    # complete command line is available; only trying on PID changes would
    # leave the bridge stopped for the lifetime of that VM.
    if [[ -n "$known_port" && -d "/proc/$pid" && "$pid" == "$known_pid" ]]; then
      port="$known_port"
    else
      port=$(get_forwarded_port "$pid" 2>/dev/null || true)
    fi

    if [[ -n "$port" ]]; then
      if [[ "$port" != "$known_port" ]]; then
        _qmcb_log "Detected forwarded SSH port: $port"
        update_config_port "$port"
        known_port="$port"
        port_changed=true
      fi
    else
      printf -v now '%(%s)T' -1
      last_warn=$(cat "$PORT_DETECT_WARN_MARKER" 2>/dev/null || echo 0)
      if (( now - last_warn >= 300 )); then
        _qmcb_log "WARNING: could not detect forwarded SSH port for PID $pid; retrying every 5s"
        printf '%s\n' "$now" > "$PORT_DETECT_WARN_MARKER"
      fi
    fi

    # Always self-heal: check every cycle, not just when a new VM is first
    # detected. Confirmed bug in an earlier version — if the very first
    # `systemctl start` attempt failed (e.g. a transient systemd/dbus
    # hiccup before units were fully reloaded), known_pid was already set,
    # so the retry-on-next-cycle branch above would never re-trigger for
    # as long as the same VM kept running, leaving the bridge permanently
    # stopped. systemctl start on an already-active unit is a safe no-op,
    # so checking/retrying every cycle is harmless and self-healing.
    #
    # If the forwarded port just changed while the bridge was already
    # active, a plain "start" is a no-op against the running instance —
    # clipboard-bridge.sh only reads its config once, at its own startup,
    # so it would otherwise keep trying to reach the OLD port forever.
    # Force a restart in that specific case so the new port takes effect
    # immediately instead of requiring a manual restart.
    if [[ "$port_changed" == true ]] && is_bridge_running; then
      _qmcb_log "Forwarded port changed to ${known_port}; restarting ${BRIDGE_LABEL} to apply it"
      bridge_restart || \
        _qmcb_log "ERROR: failed to restart ${BRIDGE_LABEL}"
    elif ! is_bridge_running; then
      if bridge_start; then
        _qmcb_log "Starting ${BRIDGE_LABEL}"
      else
        # A persistently crash-looping clipboard-bridge.sh (bad config,
        # an SSH auth failure that surfaces immediately, etc.) can trip
        # systemd's own StartLimitBurst (see the .service template)
        # independently of this retry loop -- once that happens, the
        # unit is marked "failed (start-limit-hit)" and every subsequent
        # `start` call fails immediately without even trying, no matter
        # how many times we ask. `reset-failed` clears that counter; it's
        # a harmless no-op when the unit isn't in that state (same
        # rationale as the blind `start` retry itself), and it means a
        # since-fixed problem (e.g. the user just corrected the config)
        # can actually restart on the next cycle instead of staying
        # wedged until something manually runs
        # `systemctl --user reset-failed`.
        bridge_reset_failed

        # Rate-limited to once per 5 minutes -- without this, a
        # persistent failure would otherwise write "Starting..." and
        # "ERROR: failed to start..." into watcher.log every 5s
        # indefinitely (the underlying retry above still happens every
        # cycle regardless; only the logging is throttled).
        printf -v now '%(%s)T' -1
        last_warn=$(cat "$START_FAIL_WARN_MARKER" 2>/dev/null || echo 0)
        if (( now - last_warn >= 300 )); then
          _qmcb_log "ERROR: failed to start ${BRIDGE_LABEL} (retrying every 5s; rate-limited to once per 5 minutes; $(bridge_diag_hint))"
          echo "$now" > "$START_FAIL_WARN_MARKER"
        fi
      fi
    fi
  else
    if [[ -n "$known_pid" ]]; then
      _qmcb_log "macOS QEMU VM (PID $known_pid) no longer running; stopping bridge"
      known_pid=""
      known_port=""
      # direct backend: a bridge that died uncleanly (SIGKILL / OOM killer)
      # may have left orphaned loops behind; sweep them once, now.
      if [[ "$SERVICE_BACKEND" == "direct" ]] && ! is_bridge_running; then
        qmcb_kill_stale_bridge
      fi
    fi
    if is_bridge_running; then
      bridge_stop || true
    fi
  fi

  # "8>&-": do not let this sleep inherit the single-instance lock. If the
  # watcher is killed mid-sleep, an inheriting sleep would keep the lock held
  # for up to 5s and a freshly started watcher would silently refuse to run.
  sleep 5 8>&-
done

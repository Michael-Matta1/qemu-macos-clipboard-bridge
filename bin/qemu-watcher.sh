#!/bin/bash
# qemu-watcher.sh — detects macOS VM start/stop, starts/stops the bridge
#
# This is a lightweight polling watcher (systemd user service, always running).
# It does NOT wrap or modify the user's VM launch script.

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

is_bridge_running() {
  systemctl --user is-active --quiet clipboard-bridge.service 2>/dev/null
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
      _qmcb_log "Forwarded port changed to ${known_port}; restarting clipboard-bridge.service to apply it"
      systemctl --user restart clipboard-bridge.service 2>/dev/null || \
        _qmcb_log "ERROR: failed to restart clipboard-bridge.service"
    elif ! is_bridge_running; then
      if systemctl --user start clipboard-bridge.service 2>/dev/null; then
        _qmcb_log "Starting clipboard-bridge.service"
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
        systemctl --user reset-failed clipboard-bridge.service 2>/dev/null || true

        # Rate-limited to once per 5 minutes -- without this, a
        # persistent failure would otherwise write "Starting..." and
        # "ERROR: failed to start..." into watcher.log every 5s
        # indefinitely (the underlying retry above still happens every
        # cycle regardless; only the logging is throttled).
        printf -v now '%(%s)T' -1
        last_warn=$(cat "$START_FAIL_WARN_MARKER" 2>/dev/null || echo 0)
        if (( now - last_warn >= 300 )); then
          _qmcb_log "ERROR: failed to start clipboard-bridge.service (retrying every 5s; rate-limited to once per 5 minutes; run 'systemctl --user status clipboard-bridge.service' for details)"
          echo "$now" > "$START_FAIL_WARN_MARKER"
        fi
      fi
    fi
  else
    if [[ -n "$known_pid" ]]; then
      _qmcb_log "macOS QEMU VM (PID $known_pid) no longer running; stopping bridge"
      known_pid=""
      known_port=""
    fi
    if is_bridge_running; then
      systemctl --user stop clipboard-bridge.service 2>/dev/null || true
    fi
  fi

  sleep 5
done

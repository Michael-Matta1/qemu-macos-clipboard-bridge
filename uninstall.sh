#!/bin/bash
# uninstall.sh — clean, complete removal of qemu-macos-clipboard-bridge
#
# Reverses every change made by install.sh.  Interactive by default;
# pass --yes for non-interactive/CI use.

set -u
set -e

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

INSTALL_PREFIX="${HOME}/.local/share/qemu-macos-clipboard-bridge"
CONFIG_DIR="${HOME}/.config/qemu-macos-clipboard-bridge"
STATE_DIR="${HOME}/.local/state/qemu-macos-clipboard-bridge"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

SSH_DIR="${HOME}/.ssh"
SSH_CONFIG="${SSH_DIR}/config"
SSH_CONFIG_D="${SSH_DIR}/config.d"
SSH_CONFIG_FRAGMENT="${SSH_CONFIG_D}/99-qemu-macos-clipboard-bridge.conf"
SSH_KEY="${SSH_DIR}/qemu_macos_clipboard_bridge_ed25519"
SSH_SOCKETS_DIR="${SSH_DIR}/sockets"

INCLUDE_MARKER="# added by qemu-macos-clipboard-bridge installer"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info() { printf '\e[34m[INFO]\e[0m %s\n' "$1"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$1" >&2; }
ok()   { printf '\e[32m[OK]\e[0m %s\n' "$1"; }
err()  { printf '\e[31m[ERR]\e[0m %s\n' "$1" >&2; }

YES=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=true ;;
  esac
done

confirm_deletion() {
  local desc="$1"
  if [[ "$YES" == true ]]; then
    return 0
  fi
  local resp
  read -r -p "Remove $desc? [y/N] " resp
  case "$resp" in
    [Yy]|[Yy][Ee][Ss]) return 0;;
    *) return 1;;
  esac
}

# ---------------------------------------------------------------------------
# 1. Stop & disable services
# ---------------------------------------------------------------------------

stop_services() {
  if systemctl --user is-active --quiet qemu-watcher.service 2>/dev/null; then
    info "Stopping qemu-watcher.service …"
    systemctl --user stop qemu-watcher.service 2>/dev/null || true
  fi

  if systemctl --user is-active --quiet clipboard-bridge.service 2>/dev/null; then
    info "Stopping clipboard-bridge.service …"
    systemctl --user stop clipboard-bridge.service 2>/dev/null || true
  fi

  if systemctl --user is-enabled --quiet qemu-watcher.service 2>/dev/null; then
    info "Disabling qemu-watcher.service …"
    systemctl --user disable qemu-watcher.service 2>/dev/null || true
  fi

  ok "Services stopped/disabled"
}

# ---------------------------------------------------------------------------
# 2. Remove systemd unit files
# ---------------------------------------------------------------------------

remove_units() {
  local removed=0
  for unit in qemu-watcher.service clipboard-bridge.service; do
    local path="${SYSTEMD_USER_DIR}/${unit}"
    if [[ -f "$path" ]]; then
      rm -f "$path"
      removed=1
    fi
  done

  if [[ "$removed" -eq 1 ]]; then
    systemctl --user daemon-reload 2>/dev/null || true
    ok "Removed systemd user units"
  fi
}

# ---------------------------------------------------------------------------
# 3. Remove runtime/config/state directories
# ---------------------------------------------------------------------------

remove_control_socket() {
  # install.sh's SSH config fragment uses
  # ControlPath ~/.ssh/sockets/%r@%h-%p — with our fixed HostName
  # (127.0.0.1), that resolves to a specific, uniquely-named socket file
  # for this tool once we know MAC_GUEST_USER and SSH_PORT. We only ever
  # remove that one specific file, never the ~/.ssh/sockets directory
  # itself, since other unrelated SSH hosts on the system may also use it
  # for their own multiplexing. Must run before remove_app_dirs, which
  # deletes CONFIG_DIR (and with it, the config file this reads from).
  local config_file="${CONFIG_DIR}/config"
  if [[ ! -f "$config_file" ]]; then
    return 0
  fi

  local mac_user="" ssh_port=""
  # shellcheck source=/dev/null
  source "$config_file" 2>/dev/null || true
  mac_user="${MAC_GUEST_USER:-}"
  ssh_port="${SSH_PORT:-}"

  if [[ -z "$mac_user" || -z "$ssh_port" ]]; then
    return 0
  fi

  local sock="${SSH_SOCKETS_DIR}/${mac_user}@127.0.0.1-${ssh_port}"
  if [[ -S "$sock" || -e "$sock" ]]; then
    if confirm_deletion "the leftover SSH ControlMaster socket ($sock)"; then
      rm -f "$sock"
      ok "Removed $sock"
    else
      warn "Kept $sock"
    fi
  fi
}

remove_app_dirs() {
  local state_tmpfs="${XDG_RUNTIME_DIR:-}/qemu-macos-clipboard-bridge"
  local dirs=("$INSTALL_PREFIX" "$CONFIG_DIR" "$STATE_DIR")
  if [[ -n "${XDG_RUNTIME_DIR:-}" && "$state_tmpfs" != "$STATE_DIR" ]]; then
    dirs+=("$state_tmpfs")
  fi
  local to_remove=()

  for d in "${dirs[@]}"; do
    if [[ -d "$d" ]]; then
      to_remove+=("$d")
    fi
  done

  if [[ ${#to_remove[@]} -eq 0 ]]; then
    return 0
  fi

  echo "The following directories will be removed:"
  for d in "${to_remove[@]}"; do
    echo "  - $d"
  done

  if confirm_deletion "these directories"; then
    for d in "${to_remove[@]}"; do
      rm -rf "$d"
      info "Removed $d"
    done
    ok "Application directories removed"
  else
    warn "Skipped removing application directories"
  fi
}

# ---------------------------------------------------------------------------
# 4. Remove SSH config fragment
# ---------------------------------------------------------------------------

remove_ssh_fragment() {
  if [[ -f "$SSH_CONFIG_FRAGMENT" ]]; then
    if confirm_deletion "SSH config fragment ($SSH_CONFIG_FRAGMENT)"; then
      rm -f "$SSH_CONFIG_FRAGMENT"
      ok "Removed $SSH_CONFIG_FRAGMENT"
    else
      warn "Kept $SSH_CONFIG_FRAGMENT"
    fi
  fi

  # Remove config.d only if now empty
  if [[ -d "$SSH_CONFIG_D" ]]; then
    local remaining
    remaining=$(find "$SSH_CONFIG_D" -mindepth 1 -print -quit 2>/dev/null || true)
    if [[ -z "$remaining" ]]; then
      if confirm_deletion "empty $SSH_CONFIG_D directory"; then
        rmdir "$SSH_CONFIG_D"
        ok "Removed empty $SSH_CONFIG_D"
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# 5. Remove Include line from ~/.ssh/config (only if we added it)
# ---------------------------------------------------------------------------

remove_include_line() {
  if [[ ! -f "$SSH_CONFIG" ]]; then
    return 0
  fi

  # Check whether our marker exists
  if ! grep -qF "$INCLUDE_MARKER" "$SSH_CONFIG"; then
    info "No installer-added Include line found in ~/.ssh/config; skipping."
    return 0
  fi

  if ! confirm_deletion "the installer-added Include line from ~/.ssh/config"; then
    warn "Kept Include line in ~/.ssh/config"
    return 0
  fi

  # Backup before modifying
  local backup
  backup="${SSH_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$SSH_CONFIG" "$backup"
  ok "Backed up ~/.ssh/config to $backup"

  local tmpfile="${SSH_CONFIG}.tmp.$$"
  sed -e '/^# added by qemu-macos-clipboard-bridge installer$/d' -e '/^Include ~\/[.]ssh\/config[.]d\/\*[\.]conf$/d' "$SSH_CONFIG" > "$tmpfile"
  chmod 600 "$tmpfile"
  mv "$tmpfile" "$SSH_CONFIG"
  ok "Removed installer-added Include line from ~/.ssh/config"
}

# ---------------------------------------------------------------------------
# 6. Remove dedicated SSH keypair
# ---------------------------------------------------------------------------

remove_ssh_key() {
  local keys=()
  [[ -f "$SSH_KEY" ]]      && keys+=("$SSH_KEY")
  [[ -f "${SSH_KEY}.pub" ]] && keys+=("${SSH_KEY}.pub")

  if [[ ${#keys[@]} -eq 0 ]]; then
    return 0
  fi

  echo "The following SSH keys will be removed:"
  for k in "${keys[@]}"; do
    echo "  - $k"
  done

  if confirm_deletion "dedicated SSH keypair"; then
    for k in "${keys[@]}"; do
      rm -f "$k"
    done
    ok "Removed dedicated SSH keypair"
  else
    warn "Kept dedicated SSH keypair"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  info "qemu-macos-clipboard-bridge uninstaller"
  info "========================================"
  info "This will remove all files installed by install.sh."
  info "Pass --yes to skip interactive confirmation."
  echo

  stop_services
  remove_units
  remove_control_socket
  remove_app_dirs
  remove_ssh_fragment
  remove_include_line
  remove_ssh_key

  echo
  ok "Uninstall complete."
}

main "$@"

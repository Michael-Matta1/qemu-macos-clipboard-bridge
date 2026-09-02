#!/bin/bash
# install.sh — one-shot setup for qemu-macos-clipboard-bridge
#
# Safety rules (see IMPLEMENTATION_PLAN.md §4):
#   - Never edits ~/.ssh/config in place without a backup
#   - Uses Include mechanism + dedicated config fragment
#   - Uses a dedicated SSH keypair, never the user's personal key
#   - Idempotent by default
#   - Asks before installing system packages
#   - Provides full reversibility via uninstall.sh

set -u
set -e

# ---------------------------------------------------------------------------
# Paths / constants
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SH="${SCRIPT_DIR}/bin/lib.sh"

INSTALL_PREFIX="${HOME}/.local/share/qemu-macos-clipboard-bridge"
CONFIG_DIR="${HOME}/.config/qemu-macos-clipboard-bridge"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
# Note: the state dir (~/.local/state/qemu-macos-clipboard-bridge) is created
# on demand by bin/lib.sh when sourced by qemu-watcher.sh — nothing in
# install.sh itself writes there directly.

SSH_DIR="${HOME}/.ssh"
SSH_CONFIG="${SSH_DIR}/config"
SSH_CONFIG_D="${SSH_DIR}/config.d"
SSH_CONFIG_FRAGMENT="${SSH_CONFIG_D}/99-qemu-macos-clipboard-bridge.conf"
SSH_KEY="${SSH_DIR}/qemu_macos_clipboard_bridge_ed25519"
SSH_SOCKETS_DIR="${SSH_DIR}/sockets"

# Marker comment so uninstall.sh can safely identify our Include line
INCLUDE_MARKER="# added by qemu-macos-clipboard-bridge installer"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# NOTE: all four helpers write to stderr, never stdout. Several functions in
# this script (e.g. find_vm_and_port, prompt_username) are invoked via
# command substitution ($(...)) to capture a return value — if ok()/info()
# wrote to stdout, that output would be silently swallowed into the
# captured variable instead of reaching the user's terminal. Confirmed bug
# in an earlier version: error-path guidance text in find_vm_and_port()
# never displayed because of exactly this. Keep stdout reserved solely for
# values a caller intends to capture.
ok()   { printf '\e[32m[OK]\e[0m %s\n' "$1" >&2; }
info() { printf '\e[34m[INFO]\e[0m %s\n' "$1" >&2; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$1" >&2; }
err()  { printf '\e[31m[ERR]\e[0m %s\n' "$1" >&2; }

prompt_yn() {
  local question="$1"
  local resp
  while true; do
    read -r -p "$question [y/N] " resp
    case "$resp" in
      [Yy]|[Yy][Ee][Ss]) return 0;;
      [Nn]|[Nn][Oo]|""|*) return 1;;
    esac
  done
}

# Check for a command, return 0 if present
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# 0. Dependency check (with user consent)
# ---------------------------------------------------------------------------

check_deps() {
  local missing=()

  if ! have_cmd clipnotify; then
    missing+=("clipnotify")
  fi

  if ! have_cmd xclip; then
    missing+=("xclip")
  fi

  # All three OpenSSH client tools are used later. Checking them together
  # avoids a confusing late failure when ssh-copy-id or ssh-keygen is absent.
  if ! have_cmd ssh || ! have_cmd ssh-keygen || ! have_cmd ssh-copy-id; then
    missing+=("openssh-client")
  fi

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  warn "Missing required tools: ${missing[*]}"

  local pm=""
  if have_cmd apt; then
    pm="apt"
  elif have_cmd dnf; then
    pm="dnf"
  elif have_cmd pacman; then
    pm="pacman"
  fi

  if [[ -z "$pm" ]]; then
    err "Could not detect your package manager. Please install: ${missing[*]}"
    exit 1
  fi

  local pkg_list=()
  case "$pm" in
    apt)
      for m in "${missing[@]}"; do
        case "$m" in
          clipnotify) pkg_list+=("clipnotify") ;;
          xclip)      pkg_list+=("xclip") ;;
          openssh-client) pkg_list+=("openssh-client") ;;
        esac
      done
      ;;
    dnf)
      for m in "${missing[@]}"; do
        case "$m" in
          clipnotify) pkg_list+=("clipnotify") ;;
          xclip)      pkg_list+=("xclip") ;;
          openssh-client) pkg_list+=("openssh-clients") ;;
        esac
      done
      ;;
    pacman)
      for m in "${missing[@]}"; do
        case "$m" in
          clipnotify) pkg_list+=("clipnotify") ;;
          xclip)      pkg_list+=("xclip") ;;
          openssh-client) pkg_list+=("openssh") ;;
        esac
      done
      ;;
  esac

  if ! prompt_yn "Install missing packages via $pm? (${pkg_list[*]})"; then
    err "Cannot continue without required tools. Exiting."
    exit 1
  fi

  case "$pm" in
    apt)  sudo apt update && sudo apt install -y "${pkg_list[@]}" ;;
    dnf)  sudo dnf install -y "${pkg_list[@]}" ;;
    pacman) sudo pacman -S --noconfirm "${pkg_list[@]}" ;;
  esac
}

# ---------------------------------------------------------------------------
# 1. Find running VM and forwarded port
# ---------------------------------------------------------------------------

find_vm_and_port() {
  # shellcheck source=/dev/null
  source "$LIB_SH"

  local pid
  pid=$(find_mac_vm_pid 2>/dev/null || true)

  if [[ -z "$pid" ]]; then
    err "No running macOS QEMU VM detected."
    info "Please boot your macOS VM first, then re-run this installer."
    info "(The VM must include '-device isa-applesmc' in its QEMU command line.)"
    exit 1
  fi

  local port
  port=$(get_forwarded_port "$pid" 2>/dev/null || true)

  if [[ -z "$port" ]]; then
    err "Found macOS VM (PID $pid) but could not detect a hostfwd rule forwarding a host port to guest port 22."
    info "Make sure your QEMU launch script forwards a host port to guest port 22."
    exit 1
  fi

  echo "$port"
}

# ---------------------------------------------------------------------------
# 2. Generate dedicated SSH keypair (idempotent)
# ---------------------------------------------------------------------------

generate_key() {
  local have_priv=false have_pub=false
  [[ -f "$SSH_KEY" ]]      && have_priv=true
  [[ -f "${SSH_KEY}.pub" ]] && have_pub=true

  if [[ "$have_priv" == true && "$have_pub" == true ]]; then
    info "Dedicated SSH key already exists; skipping generation."
    return 0
  fi

  if [[ "$have_priv" == true || "$have_pub" == true ]]; then
    # Inconsistent partial state — e.g. a previous run was interrupted
    # between writing the private and public key. Clean up rather than
    # let ssh-keygen hit an interactive "Overwrite (y/n)?" prompt, which
    # would hang a script that's meant to be non-interactive from here on.
    warn "Found an incomplete dedicated SSH keypair; regenerating cleanly."
    rm -f "$SSH_KEY" "${SSH_KEY}.pub"
  fi

  info "Generating dedicated SSH keypair …"
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "qemu-macos-clipboard-bridge"
  ok "Generated ${SSH_KEY}"
}

# ---------------------------------------------------------------------------
# 3. Detect if Remote Login is reachable
# ---------------------------------------------------------------------------

check_remote_login() {
  local port="$1"
  info "Checking whether Remote Login is reachable on port $port …"

  if timeout 2 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
    ok "Port $port is reachable."
    return 0
  else
    err "Cannot connect to port $port — Remote Login may not be enabled."
    info "Before continuing, enable Remote Login inside the macOS guest:"
    info "  Apple menu → System Settings → General → Sharing → toggle 'Remote Login' on."
    info "Then re-run this installer."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# 3b. Check whether the forwarded port is exposed beyond localhost
#
# QEMU's SLIRP user-mode networking binds hostfwd listeners to ALL host
# interfaces (0.0.0.0) by default when no explicit hostaddr is given —
# i.e. a launch script using `hostfwd=tcp::2222-:22` (no IP before the
# port) exposes the guest's SSH port to your entire LAN, not just this
# machine. This is documented, current QEMU behavior (see e.g. QEMU
# GitLab issue #1593, "SLIRP hostfwd ignores bind address and uses
# INADDR_ANY"), not a bug in this project — but it's the kind of thing a
# user following this guide would want to know and fix, since it affects
# the guest's actual exposure regardless of what this tool does. We only
# warn here; we never modify the user's QEMU launch script.
# ---------------------------------------------------------------------------

check_port_exposure() {
  local port="$1"
  local exposed_ips=()
  local listener_addr
  local listener_addrs=()
  local saw_listener=false
  local loopback_only=true

  # Prefer inspecting the socket table directly: ss tells us whether the
  # forwarded port is bound to loopback or to all interfaces, without
  # opening a TCP connection to every local address. That makes the check
  # both cheaper and less dependent on network stack quirks.
  if have_cmd ss; then
    while IFS= read -r listener_addr; do
      [[ -z "$listener_addr" ]] && continue
      saw_listener=true
      listener_addrs+=("$listener_addr")
      case "$listener_addr" in
        127.0.0.1:*|\[::1\]:*|::1:*) ;;
        *)
          loopback_only=false
          break
          ;;
      esac
    done < <(ss -H -ltn "sport = :$port" 2>/dev/null | awk '{print $4}')

    if [[ "$saw_listener" == true && "$loopback_only" == true ]]; then
      return 0
    fi

    if [[ "$saw_listener" == true ]]; then
      exposed_ips=("${listener_addrs[@]}")
    fi
  fi

  # Fallback for environments without ss, or if the socket table could not
  # be inspected for some reason: probe the host's local addresses directly.
  if [[ ${#exposed_ips[@]} -eq 0 ]]; then
    local ip
    for ip in $(hostname -I 2>/dev/null); do
      if timeout 2 bash -c "cat < /dev/null > /dev/tcp/$ip/$port" 2>/dev/null; then
        exposed_ips+=("$ip")
      fi
    done
  fi

  if [[ ${#exposed_ips[@]} -gt 0 ]]; then
    warn "Port $port is reachable from your local network, not just from this machine (127.0.0.1):"
    for ip in "${exposed_ips[@]}"; do
      warn "  - $ip:$port"
    done
    warn "This is QEMU's default hostfwd behavior, not something this installer caused."
    warn "This bridge itself only ever connects via 127.0.0.1, but your guest's SSH port"
    warn "is currently reachable by anyone on your LAN. To restrict it to this machine"
    warn "only, change your QEMU launch script's forwarding rule from:"
    warn "    hostfwd=tcp::${port}-:22"
    warn "to:"
    warn "    hostfwd=tcp:127.0.0.1:${port}-:22"
    warn "and reboot the VM. Continuing installation regardless — this is a heads-up"
    warn "about your VM's own network exposure, not something install.sh can safely fix"
    warn "for you (it isn't this project's file to edit)."
  fi
}

# ---------------------------------------------------------------------------
# 4. Prompt for macOS guest username
# ---------------------------------------------------------------------------

prompt_username() {
  local user="${MAC_GUEST_USER:-${1:-}}"
  if [[ -n "$user" ]]; then
    echo "$user"
    return 0
  fi
  while [[ -z "$user" ]]; do
    read -r -p "Enter the macOS guest username: " user
  done
  echo "$user"
}

# ---------------------------------------------------------------------------
# 5–7. Write SSH config, copy key, verify access
# ---------------------------------------------------------------------------

write_ssh_config() {
  local user="$1"
  local port="$2"

  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"

  mkdir -p "$SSH_CONFIG_D"
  chmod 700 "$SSH_CONFIG_D"

  mkdir -p "$SSH_SOCKETS_DIR"
  chmod 700 "$SSH_SOCKETS_DIR"

  local fragment_tmp
  fragment_tmp=$(mktemp "${SSH_CONFIG_FRAGMENT}.tmp.XXXXXX")
  chmod 600 "$fragment_tmp"
  cat > "$fragment_tmp" <<EOF
Host qemu-macos-clipboard-bridge
    HostName 127.0.0.1
    Port $port
    User $user
    IdentityFile ~/.ssh/qemu_macos_clipboard_bridge_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h-%p
    ControlPersist 10m
    BatchMode yes
    ConnectTimeout 3
    ServerAliveInterval 5
    ServerAliveCountMax 2
    Compression no
EOF
  mv "$fragment_tmp" "$SSH_CONFIG_FRAGMENT"
  ok "Wrote SSH config fragment: $SSH_CONFIG_FRAGMENT"

  local existing_include_regex='^[[:space:]]*include[[:space:]]+"?(~/\.ssh/)?config\.d/\*(\.conf)?"?[[:space:]]*$'
  if [[ -f "$SSH_CONFIG" ]]; then
    if grep -qiE "$existing_include_regex" "$SSH_CONFIG"; then
      info "Include directive already present in ~/.ssh/config"
      if ! grep -qF "$INCLUDE_MARKER" "$SSH_CONFIG"; then
        local include_line_num non_comment_before
        include_line_num=$(grep -inE "$existing_include_regex" "$SSH_CONFIG" | head -1 | cut -d: -f1)
        non_comment_before=$(head -n "$((include_line_num - 1))" "$SSH_CONFIG" | grep -vc '^[[:space:]]*#\|^[[:space:]]*$' || true)
        if [[ "${non_comment_before:-0}" -gt 0 ]]; then
          warn "Your existing Include directive for config.d/*.conf in ~/.ssh/config is not at the top of the file."
          warn "An earlier Host block could take precedence over this tool's settings for the 'qemu-macos-clipboard-bridge' alias."
          warn "Not moving it automatically since we didn't add it — consider moving it to the top of the file yourself if you hit connection issues."
        fi
      fi
    else
      local backup
      backup="${SSH_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
      cp "$SSH_CONFIG" "$backup"
      ok "Backed up ~/.ssh/config to $backup"

      local tmpfile
      tmpfile="${SSH_CONFIG}.tmp.$$"
      {
        echo "$INCLUDE_MARKER"
        echo "Include ~/.ssh/config.d/*.conf"
        cat "$SSH_CONFIG"
      } > "$tmpfile"
      chmod 600 "$tmpfile"
      mv "$tmpfile" "$SSH_CONFIG"
      ok "Prepended Include directive to ~/.ssh/config"
    fi
  else
    {
      echo "$INCLUDE_MARKER"
      echo "Include ~/.ssh/config.d/*.conf"
    } > "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"
    ok "Created ~/.ssh/config with Include directive"
  fi
}

copy_ssh_key() {
  local user="$1"
  local port="$2"

  if ssh -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=3 -p "$port" "${user}@127.0.0.1" 'echo ok' 2>/dev/null | grep -q '^ok$'; then
    ok "Dedicated SSH key is already authorized on the guest; skipping ssh-copy-id."
    return 0
  fi

  info "Copying the dedicated public key to the guest …"
  if ! ssh-copy-id -o BatchMode=yes -p "$port" -i "${SSH_KEY}.pub" "${user}@127.0.0.1" 2>/dev/null; then
    if ! ssh-copy-id -p "$port" -i "${SSH_KEY}.pub" "${user}@127.0.0.1"; then
      err "ssh-copy-id failed."
      info "Double-check the username/password and that Remote Login is enabled in the guest, then re-run ./install.sh."
      exit 1
    fi
  fi
}

verify_passwordless() {
  info "Verifying passwordless SSH access …"
  # Deliberately connect via the alias (not raw user@host flags) so this
  # also validates that the Include mechanism and the config fragment we
  # just wrote actually resolve correctly — a stronger check than bypassing
  # our own config, and it catches config errors now instead of on first
  # real bridge start.
  if ssh -o BatchMode=yes -o ConnectTimeout=5 qemu-macos-clipboard-bridge 'echo ok' 2>/dev/null | grep -q '^ok$'; then
    ok "Passwordless access confirmed."
    return 0
  else
    err "Could not confirm passwordless access via the 'qemu-macos-clipboard-bridge' SSH alias."
    info "Check that the username is correct and that ~/.ssh/config.d/99-qemu-macos-clipboard-bridge.conf was written correctly."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# 8+. Install runtime files, systemd units, enable services
# ---------------------------------------------------------------------------

install_runtime() {
  mkdir -p "$INSTALL_PREFIX/bin"
  cp "${SCRIPT_DIR}/bin/lib.sh"                "${INSTALL_PREFIX}/bin/lib.sh"
  cp "${SCRIPT_DIR}/bin/clipboard-bridge.sh"   "${INSTALL_PREFIX}/bin/clipboard-bridge.sh"
  cp "${SCRIPT_DIR}/bin/qemu-watcher.sh"       "${INSTALL_PREFIX}/bin/qemu-watcher.sh"
  chmod +x "${INSTALL_PREFIX}/bin/"*.sh
  ok "Installed runtime scripts to ${INSTALL_PREFIX}/bin/"
}

write_runtime_config() {
  local user="$1"
  local port="$2"

  mkdir -p "$CONFIG_DIR"
  cat > "${CONFIG_DIR}/config" <<EOF
MAC_GUEST_USER="$user"
SSH_ALIAS="qemu-macos-clipboard-bridge"
SSH_PORT="$port"
EOF
  chmod 600 "${CONFIG_DIR}/config"
  ok "Wrote runtime config to ${CONFIG_DIR}/config"
}

install_systemd_units() {
  mkdir -p "$SYSTEMD_USER_DIR"

  sed "s|%h|${HOME}|g" \
    "${SCRIPT_DIR}/systemd/qemu-watcher.service.template" \
    > "${SYSTEMD_USER_DIR}/qemu-watcher.service"

  sed "s|%h|${HOME}|g" \
    "${SCRIPT_DIR}/systemd/clipboard-bridge.service.template" \
    > "${SYSTEMD_USER_DIR}/clipboard-bridge.service"

  ok "Installed systemd user units to ${SYSTEMD_USER_DIR}/"

  systemctl --user daemon-reload
  ok "Reloaded systemd user daemon"

  systemctl --user enable --now qemu-watcher.service
  ok "Enabled and started qemu-watcher.service"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  info "qemu-macos-clipboard-bridge installer"
  info "======================================"

  check_deps

  local detected_port
  detected_port=$(find_vm_and_port)
  ok "Detected forwarded SSH port: $detected_port"

  generate_key

  check_remote_login "$detected_port"
  check_port_exposure "$detected_port"

  local mac_user
  mac_user=$(prompt_username)

  write_ssh_config "$mac_user" "$detected_port"
  copy_ssh_key "$mac_user" "$detected_port"
  verify_passwordless

  install_runtime
  write_runtime_config "$mac_user" "$detected_port"
  install_systemd_units

  # clipboard-bridge.sh only reads its config once, at its own startup —
  # if it was already running (e.g. this is a re-install with a new
  # username or a regenerated key, done while the VM is still up), it's
  # holding stale credentials in memory and won't pick up what we just
  # wrote until something restarts it. Do that now rather than leaving
  # the user with a silently-broken bridge until their next VM reboot.
  if systemctl --user is-active --quiet clipboard-bridge.service 2>/dev/null; then
    info "clipboard-bridge.service is already running; restarting it to apply the updated configuration …"
    systemctl --user restart clipboard-bridge.service 2>/dev/null || \
      warn "Could not restart clipboard-bridge.service; it will pick up the new config next time the VM restarts."
  fi

  echo
  ok "Installation complete!"
  info "The clipboard bridge will start automatically whenever your macOS VM boots."
  info "Run 'systemctl --user status qemu-watcher.service' to check the watcher."
  info "Run './uninstall.sh' at any time to remove everything."
}

main "$@"

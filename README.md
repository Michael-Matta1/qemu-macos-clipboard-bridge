# qemu-macos-clipboard-bridge

Automatic bidirectional clipboard sync between a Linux host and a macOS guest running under QEMU/KVM (e.g. [OSX-KVM](https://github.com/kholia/OSX-KVM)), without requiring you to install anything inside the guest, run manual commands after the first setup, or change your existing VM launch workflow.

It behaves like a "guest integration tool" (in the spirit of SPICE vdagent or VirtualBox Guest Additions), but implemented entirely from the host side — because macOS has no equivalent guest-agent clipboard API.

## Table of Contents

- [What this is / isn't](#what-this-is--isnt)
- [Architecture & Performance](#architecture--performance)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Startup behavior and control](#startup-behavior-and-control)
- [Configuration](#configuration)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [License](#license)

## What this is / isn't

- **Is:** bidirectional **text** clipboard sync between a Linux host and a macOS guest under plain QEMU/KVM (e.g. OSX-KVM-based setups) for Seamless clipboard sharing.
- **Is not:** for VirtualBox, VMware, UTM, or Apple-Silicon setups.
- **Is not:** image clipboard support (v1 is plain text only).
- **Is not:** for Windows or Linux guests.
- **Is not:** for networked/remote (non-localhost) use — this is strictly for local QEMU guests reachable via a loopback-forwarded SSH port.

## Architecture & Performance

This bridge uses a highly optimized, dual event-driven architecture that achieves instantaneous synchronization with optimized CPU usage and memory consumption.

- **Host → Guest:** Strictly event-driven. The Linux host waits on X11 clipboard events natively (via `clipnotify`). When a change occurs, the text is instantly pushed down a pre-established, persistent SSH pipeline directly into the memory of a native Objective-C daemon running on the guest.
- **Guest → Host:** Near-instant event polling. A native compiled Objective-C helper (`pbcc`) runs on the guest, monitoring the `NSPasteboard` change count at highly efficient 50ms intervals using `nanosleep`. Because the helper is native, it consumes virtually zero CPU (~0.4%) and only communicates over the SSH stream when a genuine change is detected.

## Requirements

**Linux host**

- A systemd-based Linux host running an **X11** session (Wayland is not supported)
- `xclip`, and the OpenSSH client tools (`ssh`, `ssh-keygen`, `ssh-copy-id`)
- `clipnotify`. Some distributions don't package it (for example, it isn't in Ubuntu 24.04's repositories), and the installer can't install it there. In that case build it **before** running the installer:
    ```bash
    git clone https://github.com/cdown/clipnotify.git
    cd clipnotify
    make
    sudo make install
    ```

**Your macOS VM's QEMU command line** (the bridge never starts or changes your VM; it only has to recognize it)

- `-device isa-applesmc,...` — standard in OSX-KVM launch scripts; this is how a macOS VM is recognized.
- An SSH port forward to the guest's port 22, written with the `tcp:` prefix, e.g. `-netdev user,id=net0,hostfwd=tcp::2222-:22`. Any host port works.

**macOS guest**

- **Remote Login** (SSH) turned on.
- Recommended: the Xcode Command Line Tools (`xcode-select --install`) for best sync performance.

## Quick Start

Choose either path — both give you the same setup:

- **Automated:** run `./install.sh` (below).
- **Manual:** follow **[MANUAL_SETUP.md](MANUAL_SETUP.md)** if you'd rather not run the script, want control over each step, or need to adapt the project to an existing SSH setup.

```bash
git clone https://github.com/Michael-Matta1/qemu-macos-clipboard-bridge.git
cd qemu-macos-clipboard-bridge
./install.sh
```

Run it as your normal user (not with `sudo`). **Boot your macOS VM first**: the installer reads the forwarded SSH port from the running VM. If Remote Login isn't enabled in the guest yet, the installer tells you how and stops safely. (If a downloaded ZIP gives `Permission denied`, run `bash install.sh`.)

The installer will:

1. Offer to install any missing packages (`apt`, `dnf` or `pacman`)
2. Detect your running macOS VM and its forwarded SSH port
3. Generate a dedicated SSH keypair
4. Prompt once for your macOS guest username and copy the key to the guest
5. Install the systemd user services and enable `qemu-watcher.service`, so the bridge starts automatically on every future VM boot — see [Startup behavior and control](#startup-behavior-and-control)

## Startup behavior and control

**After the automated setup, the bridge starts by itself.** The installer enables `qemu-watcher.service`, which systemd starts every time you log in. The watcher starts `clipboard-bridge.service` while your macOS VM is running and stops it when the VM shuts down. There is nothing to run after the first setup.

| Goal | Command |
| --- | --- |
| Check status | `systemctl --user status qemu-watcher.service clipboard-bridge.service` |
| **Stop temporarily** (automatic start stays configured; it comes back at next login) | `systemctl --user stop qemu-watcher.service clipboard-bridge.service` |
| **Start manually** | `systemctl --user start qemu-watcher.service` (the bridge starts within seconds if the VM is running) |
| **Stop it starting automatically** | `systemctl --user disable --now qemu-watcher.service` then `systemctl --user stop clipboard-bridge.service` |
| **Turn automatic start back on** | `systemctl --user enable --now qemu-watcher.service` |

Optional aliases for your `~/.bashrc` or `~/.zshrc`:

```bash
alias bridge-off='systemctl --user stop qemu-watcher.service clipboard-bridge.service'
alias bridge-on='systemctl --user start qemu-watcher.service'
```

Always stop **both** services together: stopping only the bridge doesn't last (the watcher starts it again), and stopping only the watcher leaves the bridge running. Use the full unit name `clipboard-bridge.service`.

### Keep automatic start available, but stop the bridge from your shell

If you'd rather have the bridge off by default while keeping the automatic setup in place, add this line to the end of `~/.bashrc` (bash) or `~/.zshrc` (zsh):

```bash
systemctl --user stop qemu-watcher.service clipboard-bridge.service 2>/dev/null
```

To get the normal startup behavior back, comment the line out (`# systemctl ...`).

How it behaves:

- Automatic start stays enabled. At login the watcher starts as usual, and the line stops both services as soon as you open a terminal.
- It runs in **every** new terminal, so after `bridge-on` the next terminal you open turns the bridge off again. To make a manual start stick, use this version, which only acts in the first terminal after login:

    ```bash
    if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ ! -e "$XDG_RUNTIME_DIR/.qmcb-autostop-done" ]; then
      systemctl --user stop qemu-watcher.service clipboard-bridge.service 2>/dev/null
      touch "$XDG_RUNTIME_DIR/.qmcb-autostop-done"
    fi
    ```

- After commenting the line out it only affects terminals opened afterwards; run `systemctl --user start qemu-watcher.service` to bring the bridge back right away.

## Configuration

The installer writes `~/.config/qemu-macos-clipboard-bridge/config`. After editing it, run `systemctl --user restart clipboard-bridge.service`.

- `POLL_INTERVAL_SECONDS` (optional): how often the guest clipboard is checked. Default `0.05`; raise it (e.g. `0.5`) to lower CPU load.
- To change the macOS username, re-run `./install.sh`.
- To use an SSH host entry you already have instead of the one the installer creates, see [MANUAL_SETUP.md → Using your own SSH entry](MANUAL_SETUP.md#using-your-own-ssh-entry).

## Uninstall

```bash
./uninstall.sh          # add --yes to skip the confirmation prompts
```

This removes:

- The SSH config fragment (`~/.ssh/config.d/99-qemu-macos-clipboard-bridge.conf`)
- The `Include` line in `~/.ssh/config` (only if the installer added it)
- The dedicated SSH keypair (`~/.ssh/qemu_macos_clipboard_bridge_ed25519`)
- Runtime scripts and systemd user units (stopping and disabling the services first)
- The `~/.config/qemu-macos-clipboard-bridge/` and `~/.local/share/qemu-macos-clipboard-bridge/` directories

Your original `~/.ssh/config` content (if any) is left fully intact.

## Troubleshooting

<details>
<summary><strong>VM not detected by the watcher</strong></summary>

**Symptom:** `systemctl --user status qemu-watcher.service` shows the watcher running, but `clipboard-bridge.service` never starts after booting the VM.

See what the watcher sees:

```bash
pgrep -af 'qemu.*isa-applesmc'
```

**Cause 1 — No `isa-applesmc` device:**
The watcher looks for a QEMU process whose command line contains `isa-applesmc`. If your launch script does not include this device, the watcher won't recognize it as a macOS VM.

**Fix:** Confirm your QEMU command line includes:

```
-device isa-applesmc,osk="..."
```

This is standard in virtually all OSX-KVM launch scripts. If you removed it, add it back.

**Cause 2 — No SSH port forward the watcher can read:**
The watcher needs a `hostfwd=tcp:...` rule that forwards a host port to the guest's port 22.

**Fix:** Ensure your launch script contains something like:

```
-netdev user,id=net0,hostfwd=tcp::2222-:22
```

If you can't change your launch command, see [MANUAL_SETUP.md → VM not recognized](MANUAL_SETUP.md#vm-not-recognized) for how to adapt the project instead.

</details>

<details>
<summary><strong>Clipboard not syncing</strong></summary>

**Symptom:** The VM is running, both services are active, but copying on one side does not reach the other.

**Quick diagnostic checklist:**

1. Check the bridge service status:

    ```bash
    systemctl --user status clipboard-bridge.service
    ```

    Look for errors (e.g. `osascript` not found inside the guest, SSH connection timeouts).

2. Test SSH connectivity manually:

    ```bash
    ssh qemu-macos-clipboard-bridge 'echo hello'
    ```

    If this prompts for a password, the key was not installed correctly. Re-run `./install.sh` or use `ssh-copy-id` manually.

3. Verify the guest-side `osascript` works:

    ```bash
    ssh qemu-macos-clipboard-bridge osascript -l JavaScript -e '$.NSPasteboard.generalPasteboard.changeCount'
    ```

    This should print an integer. If it fails or hangs, the guest user account may lack permissions to run JXA scripts.

4. Check host-side tools:

    ```bash
    which clipnotify xclip
    ```

    Both must be installed and in your `$PATH`.

5. Check the watcher log for port-detection issues:
    ```bash
    cat "$XDG_RUNTIME_DIR/qemu-macos-clipboard-bridge/watcher.log"
    ```
    </details>

<details>
<summary><strong>"clipnotify failed" in the log / host->guest sync stalled</strong></summary>

**Symptom:** `watcher.log` shows:

> ERROR: clipnotify failed (missing binary, or no X11/DISPLAY session available). Host->guest sync is stalled until this is fixed.

**Cause:** `clipnotify` is missing, or the bridge service can't see your X11 display. Services get their environment from systemd's user manager, not from your terminal, so `echo $DISPLAY` working in a terminal isn't enough. Full desktop environments (GNOME, KDE, …) normally set this up; window-manager-only sessions often don't.

**Fix:**

```bash
which clipnotify                                   # installed?
systemctl --user show-environment | grep DISPLAY   # visible to services?
```

If `DISPLAY` is missing, add this to your session startup (for example `~/.xprofile`, `~/.xinitrc` or your window manager's autostart), log in again, and restart the bridge:

```bash
systemctl --user import-environment DISPLAY XAUTHORITY
systemctl --user restart clipboard-bridge.service
```

</details>

<details>
<summary><strong>"Could not confirm passwordless access"</strong></summary>

**Symptom:** `install.sh` fails at the verification step after `ssh-copy-id`.

**Causes & fixes:**

- **Wrong username:** the macOS guest username is not the same as your Linux host username. Double-check the spelling and case.
- **SSH key not copied:** `ssh-copy-id` may have silently failed. Run it manually:
    ```bash
    ssh-copy-id -p PORT -i ~/.ssh/qemu_macos_clipboard_bridge_ed25519.pub USER@127.0.0.1
    ```
    Then re-run `./install.sh`.
    </details>

<details>
<summary><strong>Clipboard stopped syncing after reinstalling/recreating the macOS VM</strong></summary>

**Symptom:** Everything worked before, but after wiping and reinstalling macOS (or replacing `mac_hdd_ng.img`), the bridge silently stops working — `clipboard-bridge.service` runs without errors, but nothing syncs.

**Cause:** a fresh macOS install generates a new SSH host key. Your host's `~/.ssh/known_hosts` still has the _old_ key cached for `127.0.0.1:PORT` from before, so SSH refuses to connect ("REMOTE HOST IDENTIFICATION HAS CHANGED!") rather than silently trusting the new one — this is SSH working as intended, not a bug.

**Fix:** remove the stale entry, then let the next connection re-trust the new key:

```bash
ssh-keygen -R "[127.0.0.1]:PORT"
```

(replace `PORT` with your forwarded SSH port). Since the guest was reinstalled, you also need to re-enable Remote Login in the fresh macOS install and run `./install.sh` again to copy the key onto it.

</details>

<details>
<summary><strong>Bridge or watcher fails to start after reinstall</strong></summary>

**Symptom:** You ran `uninstall.sh` then `install.sh`, but systemd reports the services are in a failed state.

**Fix:**

```bash
systemctl --user daemon-reload
systemctl --user reset-failed
systemctl --user enable --now qemu-watcher.service
```

If `uninstall.sh` left stale unit files behind, remove them manually from `~/.config/systemd/user/` and repeat the above.

</details>

<details>
<summary><strong>Sync works but is slow, or the guest is busy</strong></summary>

Make sure the guest has the Xcode Command Line Tools (`xcode-select --install`), wait until the guest desktop is up, then restart the bridge:

```bash
systemctl --user restart clipboard-bridge.service
```

</details>

<details>
<summary><strong>Where are the logs and config files?</strong></summary>

| What                | Where                                                        |
| ------------------- | ------------------------------------------------------------ |
| Watcher/bridge log  | `$XDG_RUNTIME_DIR/qemu-macos-clipboard-bridge/watcher.log`   |
| Runtime config      | `~/.config/qemu-macos-clipboard-bridge/config`               |
| SSH config fragment | `~/.ssh/config.d/99-qemu-macos-clipboard-bridge.conf`        |
| systemd units       | `~/.config/systemd/user/`                                    |

</details>

## Known limitations

- **One VM at a time:** if you run two OSX-KVM instances simultaneously, only the first one detected will be bridged.
- **Plain text only:** images and files are not synced, and only the regular clipboard (Ctrl+C / Ctrl+V) is synced, not the select-to-copy selection.

## License

MIT — see [LICENSE](LICENSE).

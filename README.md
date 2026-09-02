# qemu-macos-clipboard-bridge

Automatic bidirectional clipboard sync between a Linux host and a macOS guest running under QEMU/KVM (e.g. [OSX-KVM](https://github.com/kholia/OSX-KVM)), without requiring you to install anything inside the guest, run manual commands after the first setup, or change your existing VM launch workflow.

It behaves like a "guest integration tool" (in the spirit of SPICE vdagent or VirtualBox Guest Additions), but implemented entirely from the host side — because macOS has no equivalent guest-agent clipboard API.

## Table of Contents

- [What this is / isn't](#what-this-is--isnt)
- [Architecture & Performance](#architecture--performance)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Security Considerations](#security-considerations)
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

- systemd-based Linux host (**X11 display server only** — Wayland is not currently supported)
- `xclip` (reads/writes the X11 clipboard)
- `ssh`, `ssh-keygen`, `ssh-copy-id`
- A macOS guest with **Remote Login** (SSH) enabled and reachable via a loopback-forwarded port (e.g. `-netdev user,...,hostfwd=tcp::2222-:22`)
- `clipnotify` (notifies on X11 clipboard ownership changes). If not available in your distribution's repositories, build it from source:
    ```bash
    git clone https://github.com/cdown/clipnotify.git
    cd clipnotify
    make
    sudo make install
    ```

## Quick Start

```bash
git clone https://github.com/Michael-Matta1/qemu-macos-clipboard-bridge.git
cd qemu-macos-clipboard-bridge
./install.sh
```

The installer will:

1. Detect your running macOS VM and its forwarded SSH port
2. Generate a dedicated SSH keypair
3. Prompt once for your macOS guest username and copy the key
4. Install systemd user services that start the bridge automatically on every future VM boot

**Boot your macOS VM first** before running `./install.sh`. If you haven't enabled Remote Login inside the guest yet, the installer will tell you how and stop safely.

For manual, convenient control over the bridge you can add the following aliases to your shell configuration (e.g. `~/.bashrc` or `~/.zshrc`):

```bash
alias bridge-off='systemctl --user stop qemu-watcher.service clipboard-bridge.service'
alias bridge-on='systemctl --user start qemu-watcher.service'
```

## Security Considerations

- **QEMU hostfwd binding:** By default, QEMU's `hostfwd=tcp::2222-:22` binds to all host interfaces. Restrict it to loopback-only (`hostfwd=tcp:127.0.0.1:2222-:22`) in your VM launch script to prevent network exposure. `install.sh` warns if an open binding is detected.
- The dedicated SSH key has no passphrase to allow unattended background operation.

## Uninstall

```bash
./uninstall.sh
```

This removes:

- The SSH config fragment (`~/.ssh/config.d/99-qemu-macos-clipboard-bridge.conf`)
- The `Include` line in `~/.ssh/config` (only if the installer added it)
- The dedicated SSH keypair (`~/.ssh/qemu_macos_clipboard_bridge_ed25519`)
- Runtime scripts and systemd user units
- The `~/.config/qemu-macos-clipboard-bridge/` and `~/.local/share/qemu-macos-clipboard-bridge/` directories

Your original `~/.ssh/config` content (if any) is left fully intact.

## Troubleshooting

<details>
<summary><strong>"Remote Login not enabled"</strong></summary>

**Symptom:** `install.sh` exits with:

> Cannot connect to port NNNN — Remote Login may not be enabled.

**Cause:** macOS ships with SSH ("Remote Login") turned off by default.

**Fix:**

1. Inside the macOS guest, open **Apple menu → System Settings → General → Sharing**
2. Toggle **Remote Login** on
3. Re-run `./install.sh`
 </details>

<details>
<summary><strong>VM not detected by the watcher</strong></summary>

**Symptom:** `systemctl --user status qemu-watcher.service` shows the watcher running, but `clipboard-bridge.service` never starts after booting the VM.

**Cause 1 — No `isa-applesmc` device:**
The watcher looks for a `qemu-system-x86_64` process whose command line contains `isa-applesmc`. If your launch script does not include this device, the watcher won't recognize it as a macOS VM.

**Fix:** Confirm your QEMU command line includes:

```
-device isa-applesmc,osk="..."
```

This is standard in virtually all OSX-KVM launch scripts. If you removed it, add it back.

**Cause 2 — No SSH port forwarded:**
The watcher also checks for a `hostfwd=tcp:...:PORT-...:22` rule forwarding some host port to the guest's port 22 — both the bare form (`hostfwd=tcp::2222-:22`) and a form with an explicit host address (`hostfwd=tcp:127.0.0.1:2222-:22`, e.g. after applying the fix in the "Port NNNN is reachable from your local network" section below) are recognized.

**Fix:** Ensure your launch script forwards a host port to the guest's port 22, e.g.:

```
-netdev user,id=net0,hostfwd=tcp::2222-:22
```

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

    This should print an integer. If it fails or hangs, Remote Login may have been disabled again, or the guest user account may lack permissions to run JXA scripts.

4. Check host-side tools:

    ```bash
    which clipnotify xclip
    ```

    Both must be installed and in your `$PATH`.

5. Check the watcher log for port-detection issues:
    ```bash
    cat ~/.local/state/qemu-macos-clipboard-bridge/watcher.log
    ```
    </details>

<details>
<summary><strong>"clipnotify failed" in the log / host->guest sync stalled</strong></summary>

**Symptom:** `~/.local/state/qemu-macos-clipboard-bridge/watcher.log` shows:

> ERROR: clipnotify failed (missing binary, or no X11/DISPLAY session available). Host->guest sync is stalled until this is fixed.

**Cause:** `clipnotify` requires an X11 session. This fires if the binary went missing after install (e.g. an OS upgrade removed it) or if the desktop session it's running under doesn't have a usable `DISPLAY` (e.g. a pure-Wayland session without XWayland).

**Fix:**

```bash
which clipnotify   # confirm it's installed and on PATH
echo $DISPLAY       # should print something like :0 or :1
```

Reinstall the package if missing, or ensure XWayland is available if you're on Wayland. This message is rate-limited to once per 5 minutes so it won't flood the log while the underlying issue persists.

</details>

<details>
<summary><strong>"Could not confirm passwordless access"</strong></summary>

**Symptom:** `install.sh` fails at the verification step after `ssh-copy-id`.

**Causes & fixes:**

- **Wrong username:** the macOS guest username is not the same as your Linux host username. Double-check the spelling and case.
- **Remote Login restrictions:** inside the guest, go to **System Settings → General → Sharing → Remote Login** and make sure "Allow full disk access for remote users" (or equivalent) is enabled if your version of macOS offers it.
- **SSH key not copied:** `ssh-copy-id` may have silently failed. Run it manually:
    ```bash
    ssh-copy-id -p PORT -i ~/.ssh/qemu_macos_clipboard_bridge_ed25519.pub USER@127.0.0.1
    ```
    Then re-run `./install.sh`.
    </details>

<details>
<summary><strong>"Port NNNN is reachable from your local network, not just from this machine"</strong></summary>

**Symptom:** `install.sh` warns about this during setup.

**Cause:** QEMU's user-mode networking binds `hostfwd` port forwards to **all host interfaces** by default — a launch script using `hostfwd=tcp::2222-:22` (no IP before the port) exposes your macOS guest's SSH port to your entire LAN, not just this machine. This is documented QEMU behavior, not something this project causes or can safely fix for you (editing your VM launch script is outside this tool's scope).

**Fix:** in your QEMU launch script (e.g. `OpenCore-Boot.sh`), change:

```
hostfwd=tcp::2222-:22
```

to:

```
hostfwd=tcp:127.0.0.1:2222-:22
```

and reboot the VM. This restricts the forwarded port to loopback-only. Re-run `install.sh` afterward if the port number changed. The watcher recognizes both forms, so switching to the restricted form doesn't require any other changes.

</details>

<details>
<summary><strong>Clipboard stopped syncing after reinstalling/recreating the macOS VM</strong></summary>

**Symptom:** Everything worked before, but after wiping and reinstalling macOS (or replacing `mac_hdd_ng.img`), the bridge silently stops working — `clipboard-bridge.service` runs without errors, but nothing syncs.

**Cause:** a fresh macOS install generates a new SSH host key. Your host's `~/.ssh/known_hosts` still has the _old_ key cached for `127.0.0.1:PORT` from before, so SSH refuses to connect ("REMOTE HOST IDENTIFICATION HAS CHANGED!") rather than silently trusting the new one — this is SSH working as intended, not a bug.

**Fix:** remove the stale entry, then let the next connection re-trust the new key:

```bash
ssh-keygen -R "[127.0.0.1]:PORT"
```

(replace `PORT` with your forwarded SSH port). You do **not** need to re-run `install.sh` or regenerate the dedicated keypair — only the _guest's_ host key changed, not your bridge's key or its authorization on the (now-wiped) guest. Since the guest was reinstalled, you will need to re-enable Remote Login inside the fresh macOS install and run `./install.sh` again to re-copy the dedicated public key onto the new system.

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

Note: `clipboard-bridge.service` specifically now clears its own start-limit-hit state automatically (`qemu-watcher.sh` calls `systemctl --user reset-failed clipboard-bridge.service` whenever a start attempt fails, then retries on the next 5s cycle), so this manual fix is mainly needed for `qemu-watcher.service` itself — nothing else is watching it to restart it on its behalf.

</details>

<details>
<summary><strong>Where are the Logs and State Paths?</strong></summary>

| What                | Where                                                    |
| ------------------- | -------------------------------------------------------- |
| Watcher log         | `~/.local/state/qemu-macos-clipboard-bridge/watcher.log` |
| Runtime config      | `~/.config/qemu-macos-clipboard-bridge/config`           |
| SSH config fragment | `~/.ssh/config.d/99-qemu-macos-clipboard-bridge.conf`    |
| systemd units       | `~/.config/systemd/user/`                                |

</details>

## Known limitations

- **One VM at a time:** if you run two OSX-KVM instances simultaneously, only the first one detected will be bridged.
- **Plain text only:** images and files are not synced.

## License

MIT — see [LICENSE](LICENSE).

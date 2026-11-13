# Manual Setup Guide

For users who don't want to run `install.sh`, or who want control over each step. The result is the same as the automated setup. The [Requirements in the README](README.md#requirements) apply here too: have them in place first, and have your macOS VM **running** (steps 3 and 4 talk to it).

**systemd or not?** Steps 1, 5 and 6, *Verify*, *Adapting to your setup* and *Uninstall* differ depending on how your system starts services. Check which applies to you:

```bash
[ -d /run/systemd/system ] && echo "systemd" || echo "no systemd (sysVinit, runit, OpenRC, s6, dinit, ...)"
```

Both cases are written out below, marked **systemd** and **no systemd**. This is the same test `install.sh` uses to choose.

## Contents

- [Before you start](#before-you-start)
- [Setup steps](#setup-steps)
- [Verify](#verify)
- [Startup and control](#startup-and-control)
- [Adapting to your setup](#adapting-to-your-setup)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)

## Before you start

Install the packages (run as your normal user; `sudo` is only for the package manager):

```bash
sudo apt install xclip openssh-client     # Debian / Ubuntu
sudo dnf install xclip openssh-clients    # Fedora
sudo pacman -S xclip openssh clipnotify   # Arch (clipnotify is packaged there)
```

On other distributions, install the equivalents. If `clipnotify` isn't packaged for yours, build it as shown in the README.

Then set two variables in your terminal; the steps below reuse them:

```bash
PORT=2222                       # the host port your VM forwards to the guest's SSH port 22
GUEST_USER=your-macos-username  # the macOS account the bridge will use
```

Not sure which port your VM forwards? With the VM running, this prints its command line; look for `hostfwd=tcp::PORT-:22`:

```bash
pgrep -af 'qemu.*isa-applesmc'
```

**Note (the installer checks this for you):** QEMU's `hostfwd=tcp::PORT-:22` listens on all of your network interfaces, so the guest's SSH port is reachable from your whole LAN. The bridge itself only connects through `127.0.0.1`, so it works either way, but you can restrict the forward to your own machine by changing the rule in your QEMU launch command to `hostfwd=tcp:127.0.0.1:PORT-:22` and rebooting the VM. To see how your port is currently bound (if `ss` is installed), run `ss -ltn "sport = :$PORT"` (with `PORT` set as above): a local address of `127.0.0.1:PORT` means local-only.

## Setup steps

### 1. Install the scripts

From the project folder (use wherever you cloned or extracted it):

```bash
install -d ~/.local/share/qemu-macos-clipboard-bridge/bin
install -m 755 bin/lib.sh bin/qemu-watcher.sh bin/clipboard-bridge.sh \
    ~/.local/share/qemu-macos-clipboard-bridge/bin/
```

**No systemd:** also install the control script, which you will use in step 6 and to manage the bridge afterwards:

```bash
install -m 755 bin/qmcb-ctl ~/.local/share/qemu-macos-clipboard-bridge/bin/
```

Keep the scripts together in one folder (three files, or four without systemd). If you use a different folder, change the `ExecStart=` lines in step 6 (systemd) to match; without systemd the scripts find each other, so nothing else needs changing.

### 2. Create a dedicated SSH key

```bash
install -d -m 700 ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/qemu_macos_clipboard_bridge_ed25519 -N "" -C qemu-macos-clipboard-bridge
```

The empty passphrase is intentional: the bridge runs in the background and can't ask for one.

### 3. Create the SSH host entry

```bash
install -d -m 700 ~/.ssh/config.d ~/.ssh/sockets

cat > ~/.ssh/config.d/99-qemu-macos-clipboard-bridge.conf <<EOT
Host qemu-macos-clipboard-bridge
    HostName 127.0.0.1
    Port ${PORT}
    User ${GUEST_USER}
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
EOT
chmod 600 ~/.ssh/config.d/99-qemu-macos-clipboard-bridge.conf
```

Use the options as shown, and keep the `~/.ssh/sockets` folder (it must exist).

Make `~/.ssh/config` load that folder by putting this line at the **top** of the file (it must come before any `Host` block, because SSH uses the first value it finds):

```
Include ~/.ssh/config.d/*.conf
```

Skip this if the line is already there. To add it from the command line:

```bash
cp -a ~/.ssh/config ~/.ssh/config.bak 2>/dev/null || true
{ echo "Include ~/.ssh/config.d/*.conf"; cat ~/.ssh/config 2>/dev/null; } > ~/.ssh/config.new
chmod 600 ~/.ssh/config.new && mv ~/.ssh/config.new ~/.ssh/config
```

### 4. Authorize the key on the guest

```bash
ssh-copy-id -p "$PORT" -i ~/.ssh/qemu_macos_clipboard_bridge_ed25519.pub "$GUEST_USER@127.0.0.1"
ssh qemu-macos-clipboard-bridge 'echo ok'      # must print "ok" without asking for anything
```

You type the guest account's password once, for the first command only.

### 5. Write the runtime config

```bash
install -d ~/.config/qemu-macos-clipboard-bridge
cat > ~/.config/qemu-macos-clipboard-bridge/config <<EOT
MAC_GUEST_USER="${GUEST_USER}"
SSH_ALIAS="qemu-macos-clipboard-bridge"
SSH_PORT="${PORT}"
EOT
chmod 600 ~/.config/qemu-macos-clipboard-bridge/config
```

`config/config.example` shows the optional `POLL_INTERVAL_SECONDS` setting as well.

**No systemd:** add one more line now, before step 6, so the watcher supervises the bridge itself (without it the watcher assumes systemd and can never start the bridge):

```bash
echo 'SERVICE_BACKEND="direct"' >> ~/.config/qemu-macos-clipboard-bridge/config
```

**systemd:** nothing to add; a config without `SERVICE_BACKEND` means systemd.

### 6. Start the bridge service

#### systemd: install the user services

```bash
install -d ~/.config/systemd/user
cp systemd/qemu-watcher.service.template     ~/.config/systemd/user/qemu-watcher.service
cp systemd/clipboard-bridge.service.template ~/.config/systemd/user/clipboard-bridge.service
systemctl --user daemon-reload
```

The files can be copied unchanged. Now choose how the bridge starts:

| You want | Run |
| --- | --- |
| **Automatic start** (same as `install.sh`) | `systemctl --user enable --now qemu-watcher.service` |
| **Manual start only** | Nothing now. When you want the bridge: `systemctl --user start qemu-watcher.service` |

Enable only `qemu-watcher.service`; it starts and stops the bridge for you.

#### No systemd: start the watcher yourself

Skip the systemd instructions above. Nothing goes into `/etc/init.d` or any other init system: the bridge needs your X11 session and your SSH key, so it runs as you, inside your X session. From a terminal inside that session run:

```bash
~/.local/share/qemu-macos-clipboard-bridge/bin/qmcb-ctl start
```

Then add that same line to your X session's startup file so it runs at every login (for example `~/.xinitrc`, `~/.xprofile`, your window manager's autostart, or on antiX `~/.desktop-session/startup`). It is safe to run repeatedly. More detail: [Running without systemd](README.md#running-without-systemd-sysvinit-runit-openrc-) in the README.

## Verify

With the VM running and the guest at its desktop:

**systemd:**

```bash
systemctl --user status qemu-watcher.service clipboard-bridge.service
```

**No systemd:**

```bash
~/.local/share/qemu-macos-clipboard-bridge/bin/qmcb-ctl status
```

Then, in both cases:

```bash
# the log (the folder is ~/.local/state/qemu-macos-clipboard-bridge if XDG_RUNTIME_DIR is unset)
tail "${XDG_RUNTIME_DIR:-$HOME/.local/state}/qemu-macos-clipboard-bridge/watcher.log"

# host -> guest
printf 'from-host' | xclip -selection clipboard
sleep 1; ssh qemu-macos-clipboard-bridge pbpaste; echo     # from-host

# guest -> host
printf 'from-guest' | ssh qemu-macos-clipboard-bridge pbcopy
sleep 1; xclip -selection clipboard -o; echo            # from-guest
```

The log should mention the detected VM, the detected SSH port, and the bridge being started. Then try a normal copy and paste in both directions.

## Startup and control

With systemd, stopping, starting, disabling automatic start, and the `~/.bashrc` / `~/.zshrc` option are described in the README: [Startup behavior and control](README.md#startup-behavior-and-control). Without systemd, use `qmcb-ctl status|start|stop|restart`; see [Running without systemd](README.md#running-without-systemd-sysvinit-runit-openrc-).

## Adapting to your setup

Each case below can be solved by changing your setup (preferred when it's easy) or by changing the project. If you edit the installed scripts in `~/.local/share/qemu-macos-clipboard-bridge/bin/`, restart the services afterwards (systemd: `systemctl --user restart qemu-watcher.service clipboard-bridge.service`; no systemd: `qmcb-ctl restart`); re-installing overwrites your edits.

### Using your own SSH entry

If you already have an SSH `Host` entry for the VM and want to keep it, skip steps 2–3 and point the bridge at it: set `SSH_ALIAS` in `~/.config/qemu-macos-clipboard-bridge/config` to your entry's name, then restart the bridge (systemd: `systemctl --user restart clipboard-bridge.service`; no systemd: `qmcb-ctl restart`). Your entry must:

- connect to `127.0.0.1` on the VM's forwarded port, as your macOS user, with key login that needs no prompt (`BatchMode yes`);
- ideally use the other options from step 3 (they keep the connection fast and quick to recover).

Keep `MAC_GUEST_USER` and `SSH_PORT` filled in in the config file. The watcher only updates the port in the file created in step 3, so with your own entry use a fixed forwarded port, or update its `Port` yourself when it changes.

### VM not recognized

The watcher recognizes your VM from its QEMU command line:

- it must contain `isa-applesmc`, and
- it must contain an SSH forward written as `hostfwd=tcp:...:PORT-...:22`.

The easiest fix is to adjust your launch command to match. To adapt the project instead, edit `~/.local/share/qemu-macos-clipboard-bridge/bin/lib.sh`:

- **Different way to recognize the VM:** in `find_mac_vm_pid()`, change the pattern in `pgrep -f 'qemu.*isa-applesmc'` to one that matches only your VM, for example `'qemu.*-name macos-vm'`.
- **Forward not on the command line** (for example added later through the QEMU monitor): at the top of `get_forwarded_port()`, add `echo 2222; return 0`, using your real port.

Restart the watcher afterwards: `systemctl --user restart qemu-watcher.service` (no systemd: `qmcb-ctl restart`).

## Troubleshooting

The [README troubleshooting section](README.md#troubleshooting) covers the common problems. For a manual setup also check:

| Symptom | Fix |
| --- | --- |
| `Failed to connect to bus` from `systemctl --user` | Run the commands as your normal user, from a terminal inside your desktop session (not via `sudo` or `su`). |
| `Unit qemu-watcher.service not found` | The files belong in `~/.config/systemd/user/`; then run `systemctl --user daemon-reload`. |
| `ssh qemu-macos-clipboard-bridge` asks for a password or uses the wrong port or user | Make sure the `Include` line is the first line of `~/.ssh/config`; inspect the result with `ssh -G qemu-macos-clipboard-bridge`. |
| SSH reports `unix_listener: cannot bind to path` | Create the `~/.ssh/sockets` folder (step 3). |
| Bridge starts, then fails repeatedly (systemd) | `journalctl --user -u clipboard-bridge.service -n 50`; after fixing the cause, `systemctl --user reset-failed`. |
| No systemd: `qmcb-ctl status` says the watcher is not running | Run `qmcb-ctl start` from a terminal inside your X session. If that works, your session startup file isn't running it (or isn't executable). |
| No systemd: the bridge never starts or keeps failing | Read `bridge.out` and `watcher.log` in `~/.local/state/qemu-macos-clipboard-bridge/` (or `$XDG_RUNTIME_DIR/qemu-macos-clipboard-bridge/`). There is no journal. |
| No systemd: host-to-guest sync stalled, log says `clipnotify failed` | The watcher was started without a valid `DISPLAY`. Run `qmcb-ctl restart` from inside your X session. |

## Uninstall

`./uninstall.sh` also works for a manual setup that used the paths above (an `Include` line you added by hand has to be removed by hand). To do it manually:

First stop the services.

**systemd:**

```bash
systemctl --user disable --now qemu-watcher.service
systemctl --user stop clipboard-bridge.service
rm -f ~/.config/systemd/user/qemu-watcher.service ~/.config/systemd/user/clipboard-bridge.service
systemctl --user daemon-reload
```

**No systemd** (do this *before* deleting the folders below, because `qmcb-ctl` lives in one of them):

```bash
~/.local/share/qemu-macos-clipboard-bridge/bin/qmcb-ctl stop
```

Then, in both cases, remove the files:

```bash
rm -rf ~/.local/share/qemu-macos-clipboard-bridge ~/.config/qemu-macos-clipboard-bridge
rm -rf ~/.local/state/qemu-macos-clipboard-bridge "${XDG_RUNTIME_DIR:-/nonexistent}/qemu-macos-clipboard-bridge"
rm -f ~/.ssh/config.d/99-qemu-macos-clipboard-bridge.conf
rm -f ~/.ssh/qemu_macos_clipboard_bridge_ed25519 ~/.ssh/qemu_macos_clipboard_bridge_ed25519.pub
```

Then remove the `Include ~/.ssh/config.d/*.conf` line from `~/.ssh/config` if you added it. Inside the guest you can also delete the bridge's line from `~/.ssh/authorized_keys` and the folder `~/.cache/qemu-macos-clipboard-bridge`.

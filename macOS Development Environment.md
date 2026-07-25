### OSX-KVM — real macOS Sequoia VM for runtime testing

Location: `~/OSX-KVM`. Start (boots the already-installed system): `cd ~/OSX-KVM && ./OpenCore-Boot.sh`. Run
in a persistent tmux/screen session rather than per-test. RAM: 8192 MiB (`ALLOCATED_RAM` in the script).

Transfer/execute over SSH (guest 22 → host 2222; same username `michael` on both sides; passwordless key
auth configured):

```
scp -P 2222 ./file michael@localhost:~/
ssh -p 2222 michael@localhost './file --help'
```

Or via the `macos-vm` SSH config alias if set up: `scp ./binary macos-vm:~/` / `ssh macos-vm '...'`.

Remote Management and Remote Application Scripting are also enabled on the guest (screen sharing / `osascript`
over SSH)

Note 1: you already have `accessibility : granted` in the VM and if you face any issue you can ask me to solve it for you if you can't solve it yourself.

Note 2: I have installed Command Line Developer Tools for you on macOS also so now you will find things like python3 availbe for you there. I have also installed Xcode command line tools. and also installed homebrew so you can install anything you would need easly via `brew` .

`open -a` change the frontmost app over SSH if needed.

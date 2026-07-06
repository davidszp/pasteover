# pasteover — paste Windows screenshots into Claude Code & Codex CLI over SSH

Take a screenshot on your Windows machine (`Win+Shift+S`), press a key in
Claude Code running on a remote Linux machine over SSH — and the image pastes.
Two tiny dependency-free scripts and a standard SSH tunnel; nothing to install
on either side.

Works with **any agent CLI that reads clipboard images via `xclip`** on
Linux — Claude Code, Codex CLI, and opencode all use the same convention. The
steps below say "Claude Code" throughout; only step 5 (the paste keybinding)
is tool-specific.

```
Windows laptop                                Linux box (runs Claude Code)
──────────────                                ────────────────────────────
clip-server.ps1                               xclip shim (~/.local/bin/xclip)
listens 127.0.0.1:18339  <──  SSH tunnel  ──  connects 127.0.0.1:18339
serves clipboard as PNG    (RemoteForward)    feeds PNG to Claude Code
```

## How it works

Claude Code on Linux reads clipboard images by shelling out to `xclip`:

```
xclip -selection clipboard -t TARGETS -o     # "is there an image?"
xclip -selection clipboard -t image/png -o   # "give me the PNG"
```

`linux/xclip` is a bash shim that answers those two calls by fetching the
image from the **Windows clipboard** through an SSH reverse tunnel, served by
`windows/clip-server.ps1`. Everything stays on loopback at both ends; the only
transport is your existing SSH connection. Full write-up (protocol, design
notes, prior art): [GUIDE.md](GUIDE.md).

---

## Setup — recommended: clone on the remote Linux box

You SSH into this machine anyway, so start there. Git on Windows not required.

### 1. Remote (Linux): clone and install the shim

```bash
git clone https://github.com/davidszp/pasteover ~/pasteover
mkdir -p ~/.local/bin
cp ~/pasteover/linux/xclip ~/.local/bin/xclip
chmod +x ~/.local/bin/xclip
```

Check that `~/.local/bin` wins the PATH race (prints the shim's path, and
warns you if a real xclip is installed — see Troubleshooting if so):

```bash
which xclip   # must print: /home/you/.local/bin/xclip
```

### 2. Windows: pull the server script from the remote

In PowerShell on the laptop (you already have SSH access — reuse it):

```powershell
scp you@your-server:pasteover/windows/clip-server.ps1 $HOME\clip-server.ps1
```

(No scp? The script is one file — open `windows/clip-server.ps1` on the remote
and copy-paste it into Notepad, save as `clip-server.ps1` in your home folder.)

### 3. Windows: add the SSH tunnel

Edit `%USERPROFILE%\.ssh\config` (`notepad $HOME\.ssh\config`; create it if
missing, and make sure it isn't saved as `config.txt`). Add `RemoteForward`
to the host entry you use:

```
Host your-server
    HostName your-server.example.com
    User you
    RemoteForward 18339 127.0.0.1:18339
```

One-off alternative, no config file: `ssh -R 18339:127.0.0.1:18339 you@your-server`.

### 4. Windows: start the clipboard server

```powershell
powershell.exe -STA -ExecutionPolicy Bypass -File $HOME\clip-server.ps1
```

Leave that window open, or register it to auto-start hidden at every logon
(one line — the `-User` scoping is required, or you get `Access is denied`):

```powershell
Register-ScheduledTask -TaskName 'pasteover' -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-STA -WindowStyle Hidden -ExecutionPolicy Bypass -File $HOME\clip-server.ps1") -Trigger (New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME")
```

### 5. The paste key (Windows Terminal users: don't skip this)

**Windows Terminal swallows Ctrl+V** for its own text-paste, so the keypress
never reaches Claude Code — paste will silently do nothing. Fix: give Claude
Code a second paste key. On the **remote**, the repo ships the config:

```bash
cp ~/pasteover/claude/keybindings.json ~/.claude/keybindings.json
# (or merge the "alt+v" binding into your existing file)
```

Restart Claude Code. **Alt+V** now pastes images. (Alternative: unbind
`ctrl+v` in Windows Terminal's settings — you keep Ctrl+Shift+V for text.)

### 6. Use it

Reconnect SSH (the tunnel only exists on sessions started after step 3), take
a screenshot with `Win+Shift+S`, press **Alt+V** in Claude Code →
`[Image #1]`.

---

## Troubleshooting

Work down the chain from the Linux side:

```bash
# 1. Tunnel up?
ss -tln | grep 18339          # nothing -> reconnect SSH (RemoteForward missing)

# 2. Windows server answering?
exec 3<>/dev/tcp/127.0.0.1/18339 && printf 'CHECK\n' >&3 && head -c 8 <&3; exec 3<&- 3>&-
# "PNG"  -> bridge works, image on clipboard
# "NONE" -> bridge works, clipboard holds text/nothing
# error  -> tunnel up but clip-server.ps1 not running on Windows

# 3. Shim behaving? (exactly what Claude Code runs)
xclip -selection clipboard -t TARGETS -o                        # -> image/png
xclip -selection clipboard -t image/png -o > /tmp/t.png && file /tmp/t.png
```

- **Bridge answers `PNG` but the paste key does nothing:** you're in the
  Windows Terminal Ctrl+V trap — see step 5. (Tell-tale: pasting into Paint
  works, the terminal doesn't.)
- **A real xclip is already installed** (desktop Linux): the shim shadows it
  for everything, and non-image xclip calls will silently fail. Edit the
  shim's last line from `exit 1` to `exec /usr/bin/xclip "$@"` to pass
  everything else through.
- **`Warning: remote port forwarding failed` on a second SSH session:**
  harmless — the first session holds the tunnel and keeps serving. Paste
  breaks only when *that* session closes; reconnect any session to rebind.
- **Different port:** change `$port` in clip-server.ps1 and the RemoteForward
  line; the shim reads `CLIP_BRIDGE_PORT`.

## Security

Both listeners bind loopback only; the image crosses machines exclusively
inside the SSH channel. Scope: anyone who can reach `127.0.0.1:18339` on the
*Linux box* while your tunnel is up can read images (only images) from your
Windows clipboard — fine on a single-user box, think twice on a shared one.

---

## Alternative setup: clone on the Windows host

If you'd rather keep the repo on the laptop and push files *up* to the remote:

```powershell
# 1. Clone on Windows
git clone https://github.com/davidszp/pasteover $HOME\pasteover

# 2. Server runs straight from the repo
powershell.exe -STA -ExecutionPolicy Bypass -File $HOME\pasteover\windows\clip-server.ps1

# 3. Upload the shim and keybindings to the remote
ssh you@your-server "mkdir -p .local/bin .claude"
scp $HOME\pasteover\linux\xclip you@your-server:.local/bin/xclip
scp $HOME\pasteover\claude\keybindings.json you@your-server:.claude/keybindings.json
ssh you@your-server "chmod +x .local/bin/xclip"
```

Then continue with steps 3–6 above (SSH tunnel, scheduled task, paste key).
Careful with the scp of `keybindings.json` if the remote already has one —
merge instead of overwriting.

## Files

| File | Goes to | Machine |
|---|---|---|
| `linux/xclip` | `~/.local/bin/xclip` (`chmod +x`) | remote (Linux) |
| `windows/clip-server.ps1` | anywhere, e.g. `$HOME` | laptop (Windows) |
| `claude/keybindings.json` | `~/.claude/keybindings.json` | remote (Linux) |

## Prior art

[clipaste](https://github.com/hqhq1025/clipaste) (SSH mode macOS-only),
[cc-clip](https://github.com/ShunmeiCho/cc-clip) (Windows path experimental),
[clipssh](https://github.com/samuellawrentz/clipssh) (pastes a file path, not
a keypress), [claude-ssh-image-skill](https://github.com/AlexZeitler/claude-ssh-image-skill)
(no Windows client). Native support is tracked in
[anthropics/claude-code#42712](https://github.com/anthropics/claude-code/issues/42712).
See [GUIDE.md](GUIDE.md) for the full comparison and design write-up.

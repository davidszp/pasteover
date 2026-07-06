# pasteover — the full write-up

**Paste Windows screenshots directly into Claude Code (or Codex CLI, or
opencode) running on a remote Linux machine over SSH — with a real keypress,
zero installs, ~120 lines of code.**

You're on a Windows laptop. Claude Code runs on a Linux box you reach via SSH
(Windows Terminal, PowerShell, Tailscale, whatever). You take a screenshot
(`Win+Shift+S`) and want to paste it into Claude Code like you would locally.
By default this is impossible: your clipboard lives on Windows, Claude Code
reads the clipboard on Linux, and SSH doesn't carry images.

This guide builds a bridge from two tiny, dependency-free scripts:

- a **PowerShell clipboard server** on Windows (pure built-in .NET, no installs)
- a **bash `xclip` shim** on the Linux box (pure bash, uses `/dev/tcp`)

connected by a standard **SSH reverse tunnel**. Loopback-only at both ends —
the only transport is your existing SSH connection.

```
Windows laptop                                Linux box
──────────────                                ─────────
clip-server.ps1                               xclip shim (~/.local/bin/xclip)
listens 127.0.0.1:18339  <──  SSH tunnel  ──  connects 127.0.0.1:18339
serves clipboard as PNG    (RemoteForward)    feeds PNG to Claude Code
```

---

## How Claude Code reads clipboard images (the key insight)

When you press the paste key, Claude Code on Linux doesn't use any terminal
protocol — it **shells out to `xclip`** (with `wl-paste` as fallback). Digging
through the CLI binary shows exactly two calls that matter:

```bash
# 1. "is there an image on the clipboard?"
xclip -selection clipboard -t TARGETS -o 2>/dev/null \
  | grep -E "image/(png|jpeg|jpg|gif|webp|bmp)"

# 2. "give me the PNG"
xclip -selection clipboard -t image/png -o > /tmp/somefile.png 2>/dev/null
```

So we don't need X11 forwarding, a display server, or any terminal support.
We just need **something named `xclip`, earlier in `$PATH`, that answers those
two calls** with data from the Windows clipboard. That's the whole trick —
the same approach used by [cc-clip](https://github.com/ShunmeiCho/cc-clip)
and [clipaste](https://github.com/hqhq1025/clipaste), whose SSH modes are
macOS-only or experimental on Windows (see [Prior art](#prior-art)).

It's also why this isn't Claude-specific: Codex CLI and opencode read
clipboard images with the **same xclip convention** on Linux, so the bridge
serves them unmodified — only the paste-keybinding fix in Part 4 is per-tool.

## The protocol

One request per TCP connection, then close. Deliberately dumber than HTTP:

| Client sends | Server replies |
|---|---|
| `CHECK\n` | `PNG\n` if an image is on the clipboard, else `NONE\n` |
| `GET\n` | raw PNG bytes, then EOF (nothing if no image) |

Dumb enough that the Linux client needs no curl, no netcat — bash's built-in
`/dev/tcp` does it.

---

## Part 1 — Windows: the clipboard server

Save as `clip-server.ps1` (e.g. in `$HOME`). Uses only built-in .NET
assemblies — works on stock Windows PowerShell 5.1, nothing to install.

```powershell
# clip-server.ps1 — serves the Windows clipboard image as PNG over localhost TCP.
#
# Protocol (one request per connection, then close):
#   client sends "CHECK\n" -> server replies "PNG\n" or "NONE\n"
#   client sends "GET\n"   -> server replies with raw PNG bytes (empty if no image)
#
# Run with Windows PowerShell (STA is required for clipboard access):
#   powershell.exe -STA -ExecutionPolicy Bypass -File clip-server.ps1
#
# Listens on loopback only — nothing is exposed to the network.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$port = 18339
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
$listener.Start()
Write-Host "clip-server listening on 127.0.0.1:$port (Ctrl+C to stop)"

function Get-ClipboardPng {
    # Clipboard can be transiently locked by another app; retry briefly.
    for ($i = 0; $i -lt 3; $i++) {
        try {
            if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) { return $null }
            $img = [System.Windows.Forms.Clipboard]::GetImage()
            if ($null -eq $img) { return $null }
            $ms = New-Object System.IO.MemoryStream
            $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $img.Dispose()
            return $ms.ToArray()
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }
    return $null
}

while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 5000
        $stream = $client.GetStream()

        # Read the one-line command.
        $buf = New-Object byte[] 16
        $cmd = ''
        while ($cmd.Length -lt 16 -and -not $cmd.Contains("`n")) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $cmd += [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
        }
        $cmd = $cmd.Trim()

        if ($cmd -eq 'CHECK') {
            $reply = if ([System.Windows.Forms.Clipboard]::ContainsImage()) { "PNG`n" } else { "NONE`n" }
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($reply)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        elseif ($cmd -eq 'GET') {
            $png = Get-ClipboardPng
            if ($null -ne $png) {
                $stream.Write($png, 0, $png.Length)
                Write-Host ("{0}  served {1:N0} byte PNG" -f (Get-Date -Format 'HH:mm:ss'), $png.Length)
            }
        }
        $stream.Flush()
    } catch {
        # Per-connection errors are non-fatal; keep serving.
    } finally {
        if ($null -ne $client) { $client.Close() }
    }
}
```

Notes:

- **`-STA` matters.** The WinForms `Clipboard` class requires a
  single-threaded-apartment thread. Windows PowerShell 5.1 consoles default to
  STA, but pass the flag anyway so it also works when launched from Task
  Scheduler or `pwsh`.
- `TcpListener` on loopback needs no admin rights and no firewall rule
  (unlike `HttpListener`, which requires a URL ACL for non-admins — the reason
  this isn't HTTP).

### Start it

```powershell
powershell.exe -STA -ExecutionPolicy Bypass -File $HOME\clip-server.ps1
```

Leave the window open, or register it to auto-start hidden at logon:

```powershell
Register-ScheduledTask -TaskName 'pasteover' -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-STA -WindowStyle Hidden -ExecutionPolicy Bypass -File $HOME\clip-server.ps1") -Trigger (New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME")
Start-ScheduledTask -TaskName 'pasteover'
```

Two things in there that matter:

- **`-User` on the trigger:** a bare `-AtLogOn` means "at *any* user's logon",
  which needs admin rights and fails with `Access is denied`; scoped to your
  own account it registers fine from a normal shell.
- **It's one line on purpose:** multi-line paste (backtick continuations) is
  unreliable in some PowerShell consoles.

## Part 2 — Windows: the SSH tunnel

Add a `RemoteForward` line to `%USERPROFILE%\.ssh\config` (create the file if
it doesn't exist — and make sure Notepad doesn't save it as `config.txt`):

```
Host myserver
    HostName myserver.example.com
    User you
    RemoteForward 18339 127.0.0.1:18339
```

`RemoteForward 18339 127.0.0.1:18339` means: *on the server*, listen on
`127.0.0.1:18339` and pipe every connection back to `127.0.0.1:18339` *on this
laptop* — i.e. to clip-server.ps1. The tunnel exists only while the SSH
session does, which is exactly when you can paste anyway.

One-off equivalent, no config file: `ssh -R 18339:127.0.0.1:18339 you@myserver`.

## Part 3 — Linux: the `xclip` shim

Save as `~/.local/bin/xclip` and `chmod +x` it. Requirements: bash, and
`~/.local/bin` before any real xclip in `$PATH` (on most distros it already is;
headless boxes usually have no real xclip at all, which is even cleaner).

```bash
#!/usr/bin/env bash
# xclip shim — bridges Claude Code's clipboard-image reads to a Windows/macOS
# clipboard server reached over an SSH RemoteForward tunnel on 127.0.0.1:18339.
#
# Claude Code (Linux) calls:
#   xclip -selection clipboard -t TARGETS -o      -> list mime types
#   xclip -selection clipboard -t image/png -o    -> raw PNG bytes
# Everything else fails silently.

PORT="${CLIP_BRIDGE_PORT:-18339}"
HOST="${CLIP_BRIDGE_HOST:-127.0.0.1}"

bridge() {  # bridge CHECK|GET  -> server response on stdout
    local cmd="$1"
    exec 3<>"/dev/tcp/$HOST/$PORT" 2>/dev/null || return 1
    printf '%s\n' "$cmd" >&3
    cat <&3
    exec 3<&- 3>&-
}

has_image() {
    local resp
    resp="$(bridge CHECK 2>/dev/null)" || return 1
    resp="${resp%%$'\r'*}"
    resp="${resp%%$'\n'*}"
    [ "$resp" = "PNG" ]
}

# --- parse the arguments we care about ---
target="" out=0
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
        -t|-target) target="${args[$((i+1))]}"; ((i++)) ;;
        -o|-out)    out=1 ;;
    esac
done

if [ "$out" = 1 ]; then
    case "$target" in
        TARGETS)
            if has_image; then
                printf 'image/png\n'
                exit 0
            fi
            exit 1
            ;;
        image/png)
            if has_image; then
                bridge GET
                exit 0
            fi
            exit 1
            ;;
    esac
fi

# Anything else (copy-to-clipboard, text paste, other targets): unsupported.
exit 1
```

Design points:

- **Fails fast and silent.** Tunnel down → loopback connect is refused in
  ~10 ms → exit 1 → Claude Code just does nothing, no hang, no error spam.
- **Everything non-image exits 1**, so Claude Code's `cmd1 || cmd2 || cmd3`
  fallback chains behave as if xclip simply had nothing to offer.
- The `${resp%%$'\r'*}` strip is because PowerShell's `WriteLine`-style output
  is CRLF.
- If your box *does* have a real xclip you use for other things, either rename
  it out of the way or add a passthrough at the bottom
  (`exec /usr/bin/xclip.real "$@"` instead of `exit 1`).

## Part 4 — the Windows Terminal Ctrl+V trap

At this point the bridge works — but pressing **Ctrl+V** in Claude Code may
still do *nothing*, and this catches every Windows Terminal user:

**Windows Terminal binds Ctrl+V to its own text-paste action.** The keypress
is consumed locally, tries to paste clipboard *text*, finds an image instead,
and silently does nothing. Claude Code never sees the key. (Pasting the same
screenshot into Paint works fine — Paint is a local app receiving the
keystroke directly. That contrast is the tell.)

Two fixes — pick one:

**Option A (recommended): give Claude Code a second paste key.**
Claude Code's keybindings are user-configurable. On the **Linux box**, create
`~/.claude/keybindings.json`:

```json
{
  "$schema": "https://www.schemastore.org/claude-code-keybindings.json",
  "$docs": "https://code.claude.com/docs/en/keybindings",
  "bindings": [
    {
      "context": "Chat",
      "bindings": {
        "alt+v": "chat:imagePaste"
      }
    }
  ]
}
```

Restart Claude Code. **Alt+V** now pastes images (Ctrl+V still works in
terminals that pass it through — the binding is additive). Windows Terminal
doesn't claim Alt+V, so it reaches the remote app untouched.

**Option B: unbind Ctrl+V in Windows Terminal.**
Settings → Open JSON file → in the `"keybindings"` (or `"actions"`) array,
remove the `ctrl+v` paste entry or add
`{ "command": "unbound", "keys": "ctrl+v" }`. You keep Ctrl+Shift+V and
right-click for text paste, and as a bonus Ctrl+V starts working in vim
(visual block) and other TUI apps too.

## Use it

1. `Win+Shift+S`, snip a region (the image lands on the clipboard when you
   *complete* the selection).
2. In Claude Code over SSH: **Alt+V** (or Ctrl+V with option B).
3. `[Image #1]` appears in the input box. Done.

---

## Troubleshooting

Work down the chain from the Linux side:

```bash
# 1. Is the tunnel up?
ss -tln | grep 18339
# nothing -> this SSH session was opened without the RemoteForward; reconnect.

# 2. Does the Windows server answer?
exec 3<>/dev/tcp/127.0.0.1/18339 && printf 'CHECK\n' >&3 && head -c 8 <&3; exec 3<&- 3>&-
# "PNG"  -> whole bridge works, image is on the clipboard
# "NONE" -> whole bridge works, but the clipboard holds text / nothing
# hangs or error -> tunnel is up but clip-server.ps1 isn't running on Windows

# 3. Does the shim behave? (exactly what Claude Code runs)
xclip -selection clipboard -t TARGETS -o          # should print: image/png
xclip -selection clipboard -t image/png -o > /tmp/t.png && file /tmp/t.png
```

- **`Warning: remote port forwarding failed` when opening a second SSH
  session:** harmless — the first session already holds port 18339 and keeps
  serving. Paste breaks only when *that first* session closes; reconnect any
  session to rebind.
- **Bridge answers `PNG` but the paste key does nothing:** you're in the
  Windows Terminal Ctrl+V trap — see Part 4.
- **Different port:** change `$port` in clip-server.ps1 and the RemoteForward
  line; the shim reads `CLIP_BRIDGE_PORT`.

## Security notes

- Both listeners bind **loopback only**; nothing is reachable over the
  network. The image crosses machines exclusively inside the encrypted SSH
  channel you already trust.
- Scope: anyone who can connect to `127.0.0.1:18339` *on the Linux box* while
  your tunnel is up can read images (only images) from your Windows clipboard.
  On a single-user box that's just you; on a shared box, consider that before
  deploying, or add a shared-secret line to the protocol.

## Prior art

Existing tools in this space, and why this guide exists anyway:

| Project | Approach | Gap |
|---|---|---|
| [clipaste](https://github.com/hqhq1025/clipaste) | daemon + xclip shim + SSH tunnel | SSH remote mode is macOS-only (Windows only as a WSL2 host) |
| [cc-clip](https://github.com/ShunmeiCho/cc-clip) | daemon + xclip shim + SSH tunnel | Windows direct-paste path experimental/unreleased; stable flow is hotkey → scp upload → paths |
| [clipssh](https://github.com/samuellawrentz/clipssh) | hotkey → scp upload → path on clipboard | pastes a file path, not a real paste keypress |
| [claude-ssh-image-skill](https://github.com/AlexZeitler/claude-ssh-image-skill) | local daemon + Claude Code skill | client uses xclip/wl-paste/pngpaste — no Windows |

Native support (OSC 52 / kitty image protocol) is tracked upstream in
[anthropics/claude-code#42712](https://github.com/anthropics/claude-code/issues/42712);
until then, the xclip shim is the seam to exploit.

What's different here: **Windows-native client with zero installs** (built-in
PowerShell 5.1 + .NET), a dependency-free bash shim (no curl/nc/python), a
true in-app paste keypress rather than a typed file path — and the Windows
Terminal Ctrl+V interception documented, which bites everyone and none of the
above mention.

## Caveats

- Claude Code's `xclip` calls are an implementation detail, not a contract — a
  future version could switch to terminal escape sequences (that's the
  upstream plan). The shim degrades gracefully (worst case: paste stops
  working, nothing breaks).
- `Clipboard.GetImage()` re-encodes whatever is on the clipboard to PNG:
  screenshots are lossless, but pasting a JPEG photo grows it; animated GIFs
  paste as a single frame.
- One clipboard server per laptop, one tunnel per server — if you SSH into
  several boxes, add the same `RemoteForward` line to each host entry.

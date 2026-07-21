# pasteover — laptop on Linux (Wayland / Hyprland, e.g. Omarchy)

The laptop side of pasteover, ported from Windows to a Wayland/Hyprland laptop.
The **remote (VM) side is unchanged** — `~/.local/bin/xclip`, `~/.local/bin/bigpaste`,
and `~/pasteover-inbox/` on the VM are what these talk to over the SSH tunnel.

## What each type does

| Clipboard holds | How it reaches the agent | Needs |
|---|---|---|
| **image** / screenshot | agent's **Alt+V** → VM `xclip` shim → pulls PNG from `clip-server` over the tunnel | clip-server + tunnel |
| **short text** | normal terminal paste (Ctrl+Shift+V) — goes over the PTY | nothing |
| **long text** (>~60 KB) | type `!bigpaste` in the agent → VM helper pulls text from `clip-server` | clip-server + tunnel |
| **file** (PDF/doc/…) | **Super+V** → `pastefile.sh` scp's it to the VM inbox, hands you an `@path` | tunnel + Hyprland bind |

> **Why Alt+V isn't one universal key here (unlike the Windows build):** on
> Wayland you can't cleanly suppress-and-re-emit a global key, so Alt+V stays
> dedicated to the agent's native image paste, and files get their own key.

## Install (on the laptop)

**0. Prereqs**

```bash
sudo pacman -S --needed wl-clipboard openssh        # wl-paste, ssh (usually already present)
# optional, only if you want files auto-typed instead of clipboard-handed:
sudo pacman -S --needed wtype
```

`ssh builds` must work **non-interactively** (key auth, agent loaded) — test:

```bash
ssh -o BatchMode=yes builds true && echo OK
```

If that prompts, load your key into an agent (Omarchy runs one) or set up a
passphraseless key for this host.

**1. Get these scripts onto the laptop** (run from the laptop):

```bash
scp -r builds:Builds/pasteover ~/pasteover        # or: git clone, once it's pushed
```

**2. Make the VM inbox dir** (once; may already exist):

```bash
ssh builds 'mkdir -p ~/pasteover-inbox'
```

**3. Autostart the bridge + bind the file key.** Add to your Hyprland config
(Omarchy: `~/.config/hypr/hyprland.conf`, or the `autostart` / `bindings` files
it sources):

```bash
exec-once = ~/pasteover/linux-host/tunnel.sh          # keep the reverse tunnel up
exec-once = ~/pasteover/linux-host/clip-server        # serve the clipboard over it
bind = SUPER, V, exec, ~/pasteover/linux-host/pastefile.sh   # file paste
```

Then reload Hyprland (`hyprctl reload`) or log out/in.

**4. Do NOT** add `RemoteForward 18339 127.0.0.1:18339` to `~/.ssh/config` for
the `builds` host — `tunnel.sh` owns that port; a config forward would collide.

## Test

```bash
# tunnel up? (run on the VM)
ssh builds 'ss -tln | grep 18339'                 # should show a listener

# clip-server answering? copy a screenshot, then on the VM:
ssh builds 'printf CHECK | nc 127.0.0.1 18339'    # -> PNG   (NONE if clipboard is text/empty)
```

- **Image:** copy/screenshot → focus the agent on an empty prompt → **Alt+V**.
- **File:** copy a file in your file manager → **Super+V** → notification says it's
  on the VM → **Ctrl+Shift+V** into the agent to drop the `@path` (or set
  `PASTEOVER_WTYPE=1` to have it typed for you).
- **Long text:** copy → type `!bigpaste` in the agent.

## Tunables (env vars)

`PASTEOVER_SSH_HOST` (default `builds`), `PASTEOVER_INBOX` (default
`<remote $HOME>/pasteover-inbox`), `PASTEOVER_PREFIX` (`@` → `` for a bare path),
`PASTEOVER_PORT` (`18339`), `PASTEOVER_WTYPE` (`1` = auto-type the mention).

## Notes / gotchas

- `clip-server` must run **inside** the Hyprland session (it needs
  `WAYLAND_DISPLAY`) — that's why it's an `exec-once`, not a plain systemd service.
- The **file** path depends on your file manager putting a `file://` URI (or a
  plain path) on the clipboard; `pastefile.sh` handles both. GUI managers
  (Nautilus/Thunar) set `text/uri-list`; terminal ones (yazi) usually yank the path.
- Everything stays on the loopback SSH tunnel; files ride the same authenticated
  `ssh builds` connection (no new listener on the VM).

# pasteover — laptop side (Wayland / Hyprland, e.g. Omarchy)

Bridges the laptop's Wayland clipboard into **Claude Code running on the `builds` VM**.
Bind **one key** and it pastes whatever you copied — text, image, or file — over SSH.

The VM side is unchanged (`~/.local/bin/{xclip,bigpaste}` + `/tmp/pasteover-inbox/`).

## The one key: `SUPER+ALT+V`

Copy anything, focus the **laptop terminal running your `ssh builds` Claude Code
session**, press `SUPER+ALT+V`:

| Clipboard | What happens |
|---|---|
| **small text** | Shift+Insert paste (via Hyprland `sendshortcut`, same as Omarchy's SUPER+V) |
| **large text** (>4000 chars) | types `!bigpaste`; VM pulls the text over the tunnel |
| **image** | re-emits `Alt+V` → the agent's own image paste (VM `xclip` shim pulls the PNG) |
| **file** (PDF/any) | `scp`s it to the VM inbox, types an `@/path` mention |

> `SUPER+V` alone is Omarchy's *local* clipboard paste — unrelated. `SUPER+ALT+V`
> is the one that reaches the VM.

## Install (laptop)

```bash
# 1. deps
sudo pacman -S --needed wl-clipboard openssh wtype hyprland

# 2. passwordless ssh to the VM must work
ssh -o BatchMode=yes builds true && echo OK

# 3. get the scripts
git clone https://github.com/davidszp/pasteover ~/pasteover   # or: scp -r builds:Builds/pasteover ~/pasteover

# 4. bridge as self-healing user services
cp ~/pasteover/linux-host/systemd/pasteover-*.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now pasteover-server.service pasteover-tunnel.service
```

Then bind the key in `~/.config/hypr/bindings.conf` (`SUPER, V` is taken by Omarchy):

```
bind = SUPER ALT, V, exec, ~/pasteover/linux-host/pasteover-smart
```

…and `hyprctl reload`.

## Tunables (env vars, all optional)

| Var | Default | Notes |
|---|---|---|
| `PASTEOVER_SSH_HOST` | `builds` | VM ssh alias |
| `PASTEOVER_INBOX` | `/tmp/pasteover-inbox` | file drop dir on the VM |
| `PASTEOVER_TERMINALS` | Alacritty/kitty/foot/… | window classes it acts in; empty = any |
| `PASTEOVER_PASTE_SHORTCUT` | `SHIFT, Insert` | small-text paste combo; `""` → wtype fallback |
| `PASTEOVER_IMAGE_KEY` | `alt v` | must match the agent's imagePaste binding |
| `PASTEOVER_TEXT_INLINE_MAX` | `4000` | chars above this → `!bigpaste` |
| `PASTEOVER_KEY_DELAY` | `0.15` | seconds for physical SUPER+ALT to lift; raise if a branch mis-fires |

Also: `PASTEOVER_PREFIX`, `PASTEOVER_PORT`, `PASTEOVER_BIGPASTE`, `PASTEOVER_PASTE_KEY`.

## Gotchas

- **Focus matters** — it synthesizes keystrokes into the focused window, so the
  `ssh builds` terminal must be focused (it notifies and bails otherwise).
- **`pasteover-server` needs the Hyprland session** for `WAYLAND_DISPLAY` — that's
  why it's a systemd *user* service (`WantedBy=graphical-session.target`), not a
  system one.
- **Don't** add `RemoteForward 18339` to `~/.ssh/config` for `builds` —
  `pasteover-tunnel` owns that port and a config forward would collide.
- Separate-keys mode still exists: bind `pasteover-file` instead and use the
  agent's native `Alt+V` / `Ctrl+Shift+V` / `!bigpaste` for the rest.

## Debug

```bash
~/pasteover/linux-host/pasteover-smart          # run directly to see its notifications
ssh builds 'ss -tln | grep 18339'               # tunnel listener up on the VM?
```

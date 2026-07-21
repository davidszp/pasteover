# pasteover — laptop on Linux (Wayland / Hyprland, e.g. Omarchy)

The laptop side of pasteover, ported from Windows to a Wayland/Hyprland laptop.
The **remote (VM) side is unchanged** — `~/.local/bin/xclip`, `~/.local/bin/bigpaste`,
and `/tmp/pasteover-inbox/` on the VM are what these talk to over the SSH tunnel.

## What each type does

| Clipboard holds | How it reaches the agent | Needs |
|---|---|---|
| **image** / screenshot | agent's **Alt+V** → VM `xclip` shim → pulls PNG from `pasteover-server` over the tunnel | pasteover-server + tunnel |
| **short text** | normal terminal paste (Ctrl+Shift+V) — goes over the PTY | nothing |
| **long text** (>~60 KB) | type `!bigpaste` in the agent → VM helper pulls text from `pasteover-server` | pasteover-server + tunnel |
| **file** (PDF/doc/…) | **Super+Alt+V** → `pasteover-file` scp's it to the VM inbox, hands you an `@path` | tunnel + Hyprland bind |

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

**2. VM inbox dir** — nothing to do. It's `/tmp/pasteover-inbox` on the VM and
`pasteover-file` `mkdir -p`s it on each push (so it survives `/tmp` being cleared on
reboot). Override the location with `PASTEOVER_INBOX` if you want it elsewhere.

**3. Run the bridge as systemd user services** (self-healing — `Restart=always`
brings them back on a crash, not just on next login). Ship-ready units are in
`linux-host/systemd/`:

```bash
cp ~/pasteover/linux-host/systemd/pasteover-*.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now pasteover-server.service pasteover-tunnel.service
```

They're `WantedBy=graphical-session.target`, so they start on login (survive
reboot) and restart within seconds if either process dies. Omarchy/uwsm exposes
`WAYLAND_DISPLAY` to the systemd user manager, so `pasteover-server` gets the
clipboard access it needs.

**4. Bind the file-paste key** in `~/.config/hypr/bindings.conf`. `SUPER, V` is
Omarchy's Universal paste, so file-paste lives on `SUPER ALT, V`:

```bash
bind = SUPER ALT, V, exec, ~/pasteover/linux-host/pasteover-file
```

Then `hyprctl reload` (and check `hyprctl configerrors`).

**5. Do NOT** add `RemoteForward 18339 127.0.0.1:18339` to `~/.ssh/config` for
the `builds` host — `pasteover-tunnel` owns that port; a config forward would collide.

## Test

```bash
# tunnel up? (run on the VM)
ssh builds 'ss -tln | grep 18339'                 # should show a listener

# pasteover-server answering? copy a screenshot, then on the VM:
ssh builds "printf 'CHECK\n' | nc -w2 127.0.0.1 18339"   # -> PNG   (NONE if clipboard is text/empty)
```

- **Image:** copy/screenshot → focus the agent on an empty prompt → **Alt+V**.
- **File:** copy a file in your file manager → **Super+Alt+V** → notification says it's
  on the VM → **Ctrl+Shift+V** into the agent to drop the `@path` (or set
  `PASTEOVER_WTYPE=1` to have it typed for you).
- **Long text:** copy → type `!bigpaste` in the agent.

## Tunables (env vars)

`PASTEOVER_SSH_HOST` (default `builds`), `PASTEOVER_INBOX`
(`/tmp/pasteover-inbox`), `PASTEOVER_PREFIX` (`@` → `` for a bare path),
`PASTEOVER_PORT` (`18339`), `PASTEOVER_WTYPE` (`1` = auto-type the mention).

## Notes / gotchas

- `pasteover-server` must run **inside** the Hyprland session (it needs
  `WAYLAND_DISPLAY`). It runs as a systemd **user** service — Omarchy/uwsm imports
  `WAYLAND_DISPLAY` into the user manager, and the unit is
  `WantedBy=graphical-session.target`, so it starts with the session. (A plain
  *system* service would not have the Wayland env — keep it a user unit.)
- The **file** path depends on your file manager putting a `file://` URI (or a
  plain path) on the clipboard; `pasteover-file` handles both. GUI managers
  (Nautilus/Thunar) set `text/uri-list`; terminal ones (yazi) usually yank the path.
- Everything stays on the loopback SSH tunnel; files ride the same authenticated
  `ssh builds` connection (no new listener on the VM).

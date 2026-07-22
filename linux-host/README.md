# pasteover — laptop on Linux (Wayland / Hyprland, e.g. Omarchy)

The laptop side of pasteover, ported from Windows to a Wayland/Hyprland laptop.
The **remote (VM) side is unchanged** — `~/.local/bin/xclip`, `~/.local/bin/bigpaste`,
and `/tmp/pasteover-inbox/` on the VM are what these talk to over the SSH tunnel.

## One key for everything — `pasteover-smart` (recommended)

`pasteover-smart` is the Wayland port of the Windows `smartpaste.py`: bind **one**
key (`SUPER+ALT+V`) and it inspects the clipboard and does the right thing.

**`SUPER+ALT+V` is the single universal paste into Claude Code on the VM** — no
matter whether the clipboard holds short text, long text, an image, or a file
(PDF or anything else). Mental model: the script runs **on the laptop** and
synthesizes keystrokes / pushes bytes into whatever laptop window is **focused**.
The intended target is the **laptop terminal that holds your `ssh builds` session
running Claude Code** — the keystrokes travel through that SSH session into the
VM's agent prompt (and the image / large-text bytes ride the reverse tunnel).
Wherever this README says "the agent terminal," it means *that* laptop terminal,
not any Claude Code running locally on the laptop. (`SUPER+V` alone is Omarchy's
*local* clipboard paste — unrelated.)

| Clipboard holds | `pasteover-smart` does | Needs |
|---|---|---|
| **file** (PDF/doc/…) | scp's it to the VM inbox, then types an `@path` mention | tunnel + `wtype` |
| **image** / screenshot | re-emits **Alt+V** so the agent's own image paste fires (VM `xclip` shim pulls the PNG over the tunnel) | server + tunnel + `wtype` |
| **small text** (≤ ~4000 chars) | fires **Ctrl+Shift+V** (bracketed paste over the PTY) | `wtype` |
| **large text** (> ~4000 chars) | types `!bigpaste` → VM helper pulls the text over the tunnel into a file | server + tunnel + `wtype` |

> **Why one key CAN be universal here** (the earlier build split it across keys
> "because Wayland can't suppress-and-re-emit"): a Hyprland `bind` *already
> consumes* the key — that's the suppress half the Windows build needed a global
> hook for — and `wtype` supplies the re-emit half. The one rule is that the
> re-emitted key must differ from the bound key, so we bind `SUPER+ALT+V` and the
> image branch re-emits plain `Alt+V`. **No VM change needed** — the agent's
> `alt+v → chat:imagePaste` binding is untouched.

### Individual-key mode (`pasteover-file`, still supported)

If you'd rather keep separate keys, the older split still works — bind
`pasteover-file` for the file branch and use the agent's native `Alt+V` (image),
`Ctrl+Shift+V` (text) and `!bigpaste` (long text) directly:

| Clipboard holds | How it reaches the agent | Needs |
|---|---|---|
| **image** / screenshot | agent's **Alt+V** → VM `xclip` shim → pulls PNG from `pasteover-server` over the tunnel | pasteover-server + tunnel |
| **short text** | normal terminal paste (Ctrl+Shift+V) — goes over the PTY | nothing |
| **long text** | type `!bigpaste` in the agent → VM helper pulls text from `pasteover-server` | pasteover-server + tunnel |
| **file** (PDF/doc/…) | **Super+Alt+V** → `pasteover-file` scp's it to the VM inbox, hands you an `@path` | tunnel + Hyprland bind |

## Install (on the laptop)

**0. Prereqs**

```bash
sudo pacman -S --needed wl-clipboard openssh wtype   # wl-paste, ssh, wtype
```

`wtype` is **required for `pasteover-smart`** (it synthesizes the paste
keystrokes). `wl-clipboard`/`openssh` are usually already present on Omarchy.

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

**4. Bind the one smart key** in `~/.config/hypr/bindings.conf`. `SUPER, V` is
Omarchy's Universal paste, so pasteover lives on `SUPER ALT, V`:

```bash
bind = SUPER ALT, V, exec, ~/pasteover/linux-host/pasteover-smart
```

(Prefer separate keys? Bind `pasteover-file` here instead and use the agent's
native Alt+V / Ctrl+Shift+V / `!bigpaste` for the other types.)

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

With `pasteover-smart` bound to `SUPER+ALT+V`, focus the agent terminal on an
empty prompt and press it after copying each of these:

- **Image:** copy/screenshot → **Super+Alt+V** (re-emits Alt+V for you).
- **File:** copy a file in your file manager → **Super+Alt+V** → the `@path` is typed in.
- **Small text:** copy a few words → **Super+Alt+V** (bracketed-pasted).
- **Large text:** copy a big blob → **Super+Alt+V** (types `!bigpaste`, pulls it over the tunnel).

Run the script from a terminal (`~/pasteover/linux-host/pasteover-smart`) to see
its `notify`/stderr output while debugging.

## Tunables (env vars)

`PASTEOVER_SSH_HOST` (default `builds`), `PASTEOVER_INBOX`
(`/tmp/pasteover-inbox`), `PASTEOVER_PREFIX` (`@` → `` for a bare path),
`PASTEOVER_PORT` (`18339`), `PASTEOVER_WTYPE` (`1` = auto-type the mention,
`pasteover-file` only).

`pasteover-smart` adds: `PASTEOVER_IMAGE_KEY` (`alt v` — must match the agent's
imagePaste binding), `PASTEOVER_PASTE_KEY` (`ctrl shift v` — your terminal's own
paste), `PASTEOVER_BIGPASTE` (`!bigpaste`), `PASTEOVER_TEXT_INLINE_MAX` (`4000`
chars; above → bigpaste), `PASTEOVER_KEY_DELAY` (`0.15` s — time for your
physical SUPER/ALT to lift before it synthesizes), `PASTEOVER_TERMINALS`
(space-separated window classes it acts in; empty = act regardless of focus).

## Notes / gotchas

- `pasteover-server` must run **inside** the Hyprland session (it needs
  `WAYLAND_DISPLAY`). It runs as a systemd **user** service — Omarchy/uwsm imports
  `WAYLAND_DISPLAY` into the user manager, and the unit is
  `WantedBy=graphical-session.target`, so it starts with the session. (A plain
  *system* service would not have the Wayland env — keep it a user unit.)
- The **file** path depends on your file manager putting a `file://` URI (or a
  plain path) on the clipboard; both `pasteover-smart` and `pasteover-file`
  handle both. GUI managers (Nautilus/Thunar) set `text/uri-list`; terminal ones
  (yazi) usually yank the path.
- **`pasteover-smart` synthesizes keystrokes with `wtype`**, so the agent
  terminal must be focused when you press it (it bails with a notification
  otherwise). It waits `PASTEOVER_KEY_DELAY` (0.15 s) before synthesizing so your
  physical `SUPER+ALT` has lifted — if the image branch ever mis-fires, that
  delay is the first knob to raise. The re-emitted image key (`Alt+V`)
  intentionally differs from the bound key (`SUPER+ALT+V`) so Hyprland doesn't
  re-trigger the script; if you rebind, keep them different.
- Everything stays on the loopback SSH tunnel; files ride the same authenticated
  `ssh builds` connection (no new listener on the VM).

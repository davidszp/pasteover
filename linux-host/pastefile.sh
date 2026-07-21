#!/usr/bin/env bash
# pastefile.sh — copy the clipboard file(s) to the builds VM inbox and hand you
# an @mention to drop into the agent. This is the Wayland equivalent of the file
# branch of the Windows smartpaste.py.
#
# Bind it to a Hyprland key (Alt+V stays reserved for the agent's image paste).
# Pick a combo your compositor doesn't already use — e.g. on Omarchy SUPER+V is
# the system paste, so use SUPER+ALT+V. In ~/.config/hypr/ bindings:
#   bind = SUPER ALT, V, exec, ~/pasteover/linux-host/pastefile.sh
#
# Flow: read file URIs (or a plain path) from the Wayland clipboard -> scp each
# to builds:~/pasteover-inbox/ -> put "@<remote-path>" on the clipboard (wl-copy)
# and notify. Then paste it into the agent with Ctrl+Shift+V.
# Set PASTEOVER_WTYPE=1 (and install `wtype`) to auto-type the mention instead.

set -uo pipefail

REMOTE="${PASTEOVER_SSH_HOST:-builds}"
PREFIX="${PASTEOVER_PREFIX:-@}"

# Remote inbox dir. Must be ABSOLUTE so the @mention resolves from any agent cwd.
# Defaults to <remote $HOME>/pasteover-inbox, resolved over SSH once; override with
# PASTEOVER_INBOX for a fixed path.
INBOX="${PASTEOVER_INBOX:-}"
if [ -z "$INBOX" ]; then
    remote_home="$(ssh -o BatchMode=yes "$REMOTE" 'printf %s "$HOME"' 2>/dev/null)"
    INBOX="${remote_home:?could not resolve remote \$HOME (is ssh $REMOTE working?)}/pasteover-inbox"
fi

notify() { command -v notify-send >/dev/null 2>&1 && notify-send "pasteover" "$1" || echo "pasteover: $1"; }

urldecode() {  # percent-decode a file:// path (spaces -> %20 etc.)
    local s="${1//+/ }"
    printf '%b' "${s//%/\\x}"
}

# 1) Collect candidate local paths: prefer text/uri-list, fall back to a plain
#    clipboard path (covers terminal file managers like yazi that yank a path).
paths=()
while IFS= read -r line; do
    line="${line%$'\r'}"
    [ -n "$line" ] || continue
    if [[ "$line" == file://* ]]; then
        paths+=("$(urldecode "${line#file://}")")
    fi
done < <(wl-paste -t text/uri-list 2>/dev/null || true)

if [ ${#paths[@]} -eq 0 ]; then
    cand="$(wl-paste -n 2>/dev/null || true)"
    if [ -n "$cand" ] && [ -f "$cand" ]; then
        paths+=("$cand")
    fi
fi

if [ ${#paths[@]} -eq 0 ]; then
    notify "no file on the clipboard"
    exit 0
fi

# 2) scp each to the VM inbox under a shell-safe name; build @mentions.
mentions=()
for p in "${paths[@]}"; do
    [ -f "$p" ] || continue
    safe="$(basename -- "$p")"; safe="${safe//[^A-Za-z0-9._-]/_}"   # bash-native: avoids basename's trailing \n becoming a '_'
    if scp -B -q "$p" "${REMOTE}:${INBOX}/${safe}"; then
        mentions+=("${PREFIX}${INBOX}/${safe}")
    else
        notify "scp failed for $(basename "$p")"
    fi
done

if [ ${#mentions[@]} -eq 0 ]; then
    exit 1
fi

text="${mentions[*]} "

# 3) Deliver the mention: auto-type (wtype) or hand off via clipboard.
if [ "${PASTEOVER_WTYPE:-0}" = "1" ] && command -v wtype >/dev/null 2>&1; then
    wtype "$text"
    notify "typed ${#mentions[@]} file mention(s)"
else
    printf '%s' "$text" | wl-copy
    notify "${#mentions[@]} file(s) → VM. Press Ctrl+Shift+V to paste the @path."
fi

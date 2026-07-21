#!/usr/bin/env bash
# tunnel.sh — keep the pasteover SSH reverse tunnel up (laptop -> builds VM).
#
# Linux-laptop port of windows/tunnel.ps1. Reverse-forwards remote
# 127.0.0.1:18339 to this laptop's clip-server, so the VM-side xclip shim and
# bigpaste helper can reach the laptop clipboard. Holds a dedicated,
# auto-reconnecting connection so the bridge is up whenever the laptop is,
# independent of any interactive SSH session.
#
# One-time setup:
#   1. `ssh builds` must work NON-interactively (key auth, agent loaded):
#        ssh -o BatchMode=yes builds true
#   2. Do NOT also put `RemoteForward 18339 127.0.0.1:18339` in ~/.ssh/config for
#      the builds host — interactive sessions would fight this tunnel for the port.
#   3. Autostart it (Omarchy / Hyprland), in ~/.config/hypr/hyprland.conf:
#        exec-once = ~/pasteover/linux-host/tunnel.sh

REMOTE="${PASTEOVER_SSH_HOST:-builds}"
PORT="${PASTEOVER_PORT:-18339}"

while true; do
    ssh -N \
        -o BatchMode=yes \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -R "${PORT}:127.0.0.1:${PORT}" "$REMOTE"
    # ssh exited (drop, sleep/resume, or the port was momentarily held): back off
    # and reconnect.
    sleep 5
done

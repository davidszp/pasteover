#!/usr/bin/env python3
"""smartpaste.py — ONE key (Alt+V) that pastes ANYTHING from the Windows
clipboard into a remote agent CLI (Claude Code, Codex, opencode, ...) over SSH.

Press Alt+V and it inspects the clipboard and does the right thing:

  * file(s)  (PDF, doc, code, ...) -> push the bytes to the VM over SSH (scp)
                                      into an inbox dir, then type an "@<path>"
                                      mention into the terminal so the agent
                                      Reads the file.
  * image / screenshot             -> hand Alt+V back to the agent so its own
                                      image paste fires (the proven xclip-shim
                                      path — unchanged, no rebinding needed).
  * small text                     -> Ctrl+V (inline terminal paste).
  * large text (> ~4000 chars)     -> run "!bigpaste" (over the tunnel into a
                                      file — terminals truncate huge pastes, so
                                      inline Ctrl+V would silently cut it short).

How one key stays universal: a global hook OWNS Alt+V and suppresses it, so it
reaches this script before the agent's TUI. For the cases the agent already
handles well (images), and when the focused window is NOT the terminal, the hook
briefly removes itself, re-emits a real Alt+V, and re-arms — so Alt+V behaves
exactly as before there. No keybindings.json change; Alt+V -> chat:imagePaste
stays as-is.

Transport reuses the same passwordless key-auth SSH tunnel.ps1 relies on (Host
alias `builds`, BatchMode). No new auth; nothing new listens on the VM — the
file just lands in an inbox directory.

Requires (laptop):  pip install keyboard pywin32
Run hidden at logon alongside clip-server / tunnel (see README).
"""

import os
import re
import subprocess
import sys
import threading
import time

import keyboard
import win32clipboard as cb
import win32gui
import win32process
import win32api

# ---- config (env-overridable) ------------------------------------------------
HOTKEY         = os.environ.get("SMARTPASTE_HOTKEY", "alt+v")
SSH_HOST       = os.environ.get("SMARTPASTE_SSH_HOST", "builds")      # ~/.ssh/config alias, key auth
REMOTE_INBOX   = os.environ.get("SMARTPASTE_INBOX", "~/pasteover-inbox")  # remote path; ~ expands on the VM
MENTION_PREFIX = os.environ.get("SMARTPASTE_PREFIX", "@")             # "@" = file mention; "" = bare path
PASTE_KEY      = os.environ.get("SMARTPASTE_PASTE_KEY", "ctrl+v")     # terminal's own paste (small text)
BIGPASTE_CMD   = os.environ.get("SMARTPASTE_BIGPASTE", "!bigpaste")   # agent shell cmd for large text
TEXT_INLINE_MAX = int(os.environ.get("SMARTPASTE_TEXT_INLINE_MAX", "4000"))   # chars; above -> bigpaste
MAX_BYTES      = int(os.environ.get("SMARTPASTE_MAX_BYTES", str(100 * 1024 * 1024)))  # 100 MB guard
# Only act when one of these processes is focused; else hand Alt+V back untouched.
# Set SMARTPASTE_TERMINALS="" to disable gating (always act).
_terms = os.environ.get("SMARTPASTE_TERMINALS", "WindowsTerminal.exe")
TERMINAL_PROCS = {t.strip().lower() for t in _terms.split(",") if t.strip()}

_hk_handle = None          # keyboard hotkey handle, for temporary passthrough
_busy = False              # re-entrancy guard


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


# ---- clipboard inspection ----------------------------------------------------
def _clip_open():
    for _ in range(10):
        try:
            cb.OpenClipboard()
            return True
        except Exception:
            time.sleep(0.05)
    return False


def read_clipboard():
    """('files', [paths]) | ('image', None) | ('text', str) | ('none', None).

    Files win over image/text: a copied file is the explicit, intentful case.
    """
    if not _clip_open():
        return ("none", None)
    try:
        if cb.IsClipboardFormatAvailable(cb.CF_HDROP):
            paths = [p for p in cb.GetClipboardData(cb.CF_HDROP) if os.path.isfile(p)]
            if paths:
                return ("files", paths)
        if cb.IsClipboardFormatAvailable(cb.CF_DIB) or cb.IsClipboardFormatAvailable(cb.CF_BITMAP):
            return ("image", None)
        if cb.IsClipboardFormatAvailable(cb.CF_UNICODETEXT):
            return ("text", cb.GetClipboardData(cb.CF_UNICODETEXT) or "")
        return ("none", None)
    finally:
        cb.CloseClipboard()


# ---- focus gating ------------------------------------------------------------
def foreground_is_terminal():
    """True if the focused window is one of TERMINAL_PROCS (or gating disabled)."""
    if not TERMINAL_PROCS:
        return True
    try:
        hwnd = win32gui.GetForegroundWindow()
        _, pid = win32process.GetWindowThreadProcessId(hwnd)
        h = win32api.OpenProcess(0x0410, False, pid)   # QUERY_INFORMATION | VM_READ
        try:
            exe = win32process.GetModuleFileNameEx(h, 0)
        finally:
            win32api.CloseHandle(h)
        return os.path.basename(exe).lower() in TERMINAL_PROCS
    except Exception as e:
        log(f"focus check failed ({e}); assuming terminal")
        return True   # fail open: don't break the primary flow


# ---- helpers -----------------------------------------------------------------
def safe_remote_name(local_path):
    """Remote basename with no shell-special chars, so scp/@mention need no quoting."""
    stem, ext = os.path.splitext(os.path.basename(local_path))
    stem = re.sub(r"[^A-Za-z0-9._-]+", "_", stem).strip("._") or "file"
    ext = re.sub(r"[^A-Za-z0-9.]+", "", ext)
    return stem + ext


def push_file(local_path):
    """scp one file to the VM inbox. Returns the remote path, or None on failure."""
    try:
        if os.path.getsize(local_path) > MAX_BYTES:
            log(f"SKIP (>{MAX_BYTES} bytes): {local_path}")
            return None
    except OSError as e:
        log(f"SKIP (stat failed): {local_path} — {e}")
        return None

    remote_path = f"{REMOTE_INBOX}/{safe_remote_name(local_path)}"
    try:
        subprocess.run(
            ["scp", "-B", "-q", local_path, f"{SSH_HOST}:{remote_path}"],  # -B batch, -q quiet
            check=True, timeout=120,
        )
        log(f"pushed {os.path.getsize(local_path):,} bytes -> {remote_path}")
        return remote_path
    except subprocess.CalledProcessError as e:
        log(f"scp failed ({e.returncode}) for {local_path}")
    except subprocess.TimeoutExpired:
        log(f"scp timed out for {local_path}")
    except FileNotFoundError:
        log("scp not found — install the OpenSSH client")
    return None


def release_modifiers():
    """The Alt (and any Shift/Ctrl) from the hotkey may still be physically down;
    drop them so injected keystrokes aren't corrupted."""
    for m in ("alt", "shift", "ctrl"):
        try:
            keyboard.release(m)
        except Exception:
            pass
    time.sleep(0.12)


def passthrough_hotkey():
    """Re-emit a real Alt+V to the focused app: unhook ourselves, send, re-arm.
    Used for images (let the agent's own paste fire) and non-terminal windows."""
    global _hk_handle
    try:
        if _hk_handle is not None:
            keyboard.remove_hotkey(_hk_handle)
    except Exception:
        pass
    keyboard.send(HOTKEY)
    _hk_handle = keyboard.add_hotkey(HOTKEY, on_hotkey, suppress=True)


# ---- the work ----------------------------------------------------------------
def do_paste():
    global _busy
    try:
        if not foreground_is_terminal():
            passthrough_hotkey()          # not our terminal: behave like a normal Alt+V
            return

        kind, payload = read_clipboard()
        release_modifiers()

        if kind == "files":
            remotes = [rp for rp in (push_file(p) for p in payload) if rp]
            if not remotes:
                log("no files pushed")
                return
            keyboard.write(" ".join(f"{MENTION_PREFIX}{rp}" for rp in remotes) + " ", delay=0.005)
            log(f"typed mention for {len(remotes)} file(s)")

        elif kind == "image":
            passthrough_hotkey()          # hand Alt+V to the agent's image paste
            log("delegated image -> agent Alt+V")

        elif kind == "text":
            if len(payload) <= TEXT_INLINE_MAX:
                keyboard.send(PASTE_KEY)
                log(f"text {len(payload)} chars -> {PASTE_KEY}")
            else:
                keyboard.write(BIGPASTE_CMD, delay=0.005)
                keyboard.send("enter")
                log(f"text {len(payload)} chars -> {BIGPASTE_CMD}")

        else:
            log("clipboard empty / unsupported")
    finally:
        _busy = False


def on_hotkey():
    """Runs on the hook thread — hand off to a worker so keyboard.send/scp don't
    block or re-enter the hook."""
    global _busy
    if _busy:
        return
    _busy = True
    threading.Thread(target=do_paste, daemon=True).start()


def main():
    global _hk_handle
    log(f"smartpaste up — hotkey {HOTKEY!r}, ssh {SSH_HOST}, inbox {REMOTE_INBOX}, "
        f"gate={sorted(TERMINAL_PROCS) or 'off'}")
    _hk_handle = keyboard.add_hotkey(HOTKEY, on_hotkey, suppress=True)
    keyboard.wait()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)

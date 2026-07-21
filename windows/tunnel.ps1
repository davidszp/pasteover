# tunnel.ps1 — keep the pasteover SSH reverse tunnel always up (laptop -> remote).
#
# The clipboard bridge needs the VM to reach 127.0.0.1:18339 and have it routed
# back to clip-server.ps1 on this laptop. That routing is a reverse forward that
# only exists while an SSH session carrying it is alive — so interactive sessions
# coming and going leave the bridge dead half the time. This holds a dedicated,
# auto-reconnecting SSH connection open in the background so the tunnel is up
# whenever the laptop is, independent of any interactive session.
#
# One-time setup:
#   1. Make sure `ssh <remote>` below works NON-interactively (key auth, no
#      passphrase prompt — passphraseless key, or a key already loaded in a
#      persistent ssh-agent). Test:  ssh -o BatchMode=yes builds true
#   2. Remove the `RemoteForward 18339 127.0.0.1:18339` line from the Host block
#      in %USERPROFILE%\.ssh\config so interactive sessions don't fight this
#      dedicated tunnel for the port. (This script binds it exclusively.)
#   3. Register it to run hidden at logon (see README).
#
# Run manually to test:
#   powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File $HOME\tunnel.ps1

$remote = 'builds'   # Host alias in %USERPROFILE%\.ssh\config (key auth)
$port   = 18339

while ($true) {
    try {
        # -N: no shell, just the forward. Keepalives detect a dead link fast so
        # we reconnect promptly after a network drop or laptop sleep/resume.
        ssh -N `
            -o BatchMode=yes `
            -o ExitOnForwardFailure=yes `
            -o ServerAliveInterval=30 `
            -o ServerAliveCountMax=3 `
            -R "${port}:127.0.0.1:${port}" $remote
    } catch {
        # swallow — the sleep + loop retries
    }
    # ssh has exited (drop, sleep, or the port was momentarily held). Back off,
    # then reconnect.
    Start-Sleep -Seconds 5
}

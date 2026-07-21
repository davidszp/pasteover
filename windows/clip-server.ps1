# clip-server.ps1 — serves the Windows clipboard (image OR text) over localhost TCP.
#
# Pairs with two clients on the remote box, both reached via the same SSH
# RemoteForward tunnel (remote 127.0.0.1:18339 -> this machine 127.0.0.1:18339):
#   * the xclip shim (~/.local/bin/xclip) for images  -> CHECK / GET
#   * the bigpaste helper (~/.local/bin/bigpaste) for large text -> CHECKTEXT / GETTEXT
#
# Protocol (one request per connection, then close):
#   client sends "CHECK\n"     -> "PNG\n"  if an image is on the clipboard, else "NONE\n"
#   client sends "GET\n"       -> raw PNG bytes (empty if no image)
#   client sends "CHECKTEXT\n" -> "TEXT\n" if text is on the clipboard, else "NONE\n"
#   client sends "GETTEXT\n"   -> clipboard text as raw UTF-8 bytes (empty if no text)
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

function Get-ClipboardText {
    # Clipboard can be transiently locked by another app; retry briefly.
    for ($i = 0; $i -lt 3; $i++) {
        try {
            if (-not [System.Windows.Forms.Clipboard]::ContainsText()) { return $null }
            $text = [System.Windows.Forms.Clipboard]::GetText()
            if ([string]::IsNullOrEmpty($text)) { return $null }
            return $text
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
        elseif ($cmd -eq 'CHECKTEXT') {
            $reply = if ([System.Windows.Forms.Clipboard]::ContainsText()) { "TEXT`n" } else { "NONE`n" }
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($reply)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        elseif ($cmd -eq 'GETTEXT') {
            $text = Get-ClipboardText
            if ($null -ne $text) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
                $stream.Write($bytes, 0, $bytes.Length)
                Write-Host ("{0}  served {1:N0} byte text" -f (Get-Date -Format 'HH:mm:ss'), $bytes.Length)
            }
        }
        $stream.Flush()
    } catch {
        # Per-connection errors are non-fatal; keep serving.
    } finally {
        if ($null -ne $client) { $client.Close() }
    }
}

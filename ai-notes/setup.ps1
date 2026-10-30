# Roofr Assist AI notes: one-time setup on a CSR's computer. No admin rights needed; everything goes into this
# Windows user's own folders. Run from PowerShell with the one line Options -> Coach & Sales -> AI notes shows:
#
#   & ([scriptblock]::Create((irm https://arizona-roofers.github.io/roofr-assist-releases/ai-notes/setup.ps1))) -Backend agy -ExtId <id>
#
# What it does:
#   1. installs the notes helper into %LOCALAPPDATA%\RoofrAssist\notes-helper
#   2. registers it with Chrome (native messaging host com.arizonaroofers.notes, for this Windows user only)
#   3. sets up the AI tool and signs in with the person's OWN account:
#        agy    = Google Antigravity CLI; a browser opens: pick your @arizonaroofers.com account (CSR default)
#        claude = Claude Code CLI with a Claude subscription (testing)
#   4. runs a live test
param(
    [ValidateSet('agy', 'claude')][string]$Backend = 'agy',
    [string[]]$ExtId = @()
)
$ErrorActionPreference = 'Stop'
$Base = 'https://arizona-roofers.github.io/roofr-assist-releases/ai-notes'
$RoofrAssistId = 'fkldnfkfppeicfcgmlnpknfkmnfkaabo'   # the force-installed Roofr Assist
$HostName = 'com.arizonaroofers.notes'
$Dir = Join-Path $env:LOCALAPPDATA 'RoofrAssist\notes-helper'

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
Say "`nRoofr Assist AI notes setup ($Backend)" 'Cyan'

# 1. helper files
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
foreach ($f in 'notes-helper.ps1', 'notes-helper.bat') {
    Invoke-WebRequest -UseBasicParsing -Uri "$Base/$f" -OutFile (Join-Path $Dir $f)
}
[IO.File]::WriteAllText((Join-Path $Dir 'config.json'), (@{ backend = $Backend } | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
Say "  [1/4] helper installed in $Dir" 'Green'

# 2. register with Chrome (this user only)
$ids = @($RoofrAssistId) + $ExtId | Where-Object { $_ -match '^[a-p]{32}$' } | Select-Object -Unique
$manifest = [ordered]@{
    name            = $HostName
    description     = 'Roofr Assist AI notes helper'
    path            = (Join-Path $Dir 'notes-helper.bat')
    type            = 'stdio'
    allowed_origins = @($ids | ForEach-Object { "chrome-extension://$_/" })
}
$manifestPath = Join-Path $Dir "$HostName.json"
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
$key = "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$HostName"
New-Item -Path $key -Force | Out-Null
Set-ItemProperty -Path $key -Name '(default)' -Value $manifestPath
Say "  [2/4] registered with Chrome for: $($ids -join ', ')" 'Green'

# 3. the AI tool, signed in with the person's own account
if ($Backend -eq 'agy') {
    if (-not (Get-Command agy -ErrorAction SilentlyContinue) -and -not (Test-Path "$env:LOCALAPPDATA\agy\bin\agy.exe")) {
        Say '  installing Google Antigravity CLI (agy)...'
        if (Get-Command winget -ErrorAction SilentlyContinue) { winget install --id Google.AntigravityCLI --silent --accept-source-agreements --accept-package-agreements | Out-Null }
        else { Invoke-Expression (Invoke-RestMethod 'https://antigravity.google/cli/install.ps1') }
        $env:Path += ";$env:LOCALAPPDATA\agy\bin"
    }
    Say '  signing in: a browser window opens. Pick your @arizonaroofers.com Google account and click Allow.' 'Yellow'
    & "$env:LOCALAPPDATA\agy\bin\agy.exe" -p "Reply with exactly: OK" --print-timeout 120s | Out-Null
} else {
    if (-not (Get-Command claude -ErrorAction SilentlyContinue) -and -not (Test-Path "$env:USERPROFILE\.local\bin\claude.exe")) {
        throw 'Claude Code CLI is not installed. Install it, sign in with your Claude subscription (run: claude), then run this setup again.'
    }
}
Say "  [3/4] $Backend ready" 'Green'

# 4. live test through the helper, the same way Chrome will call it
$req = [Text.Encoding]::UTF8.GetBytes((@{ type = 'generate'; backend = $Backend; system = 'You are a test. Reply with exactly: NOTES-OK'; prompt = 'test' } | ConvertTo-Json -Compress))
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = 'cmd.exe'; $psi.Arguments = "/c `"$(Join-Path $Dir 'notes-helper.bat')`""
$psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
$p = [Diagnostics.Process]::Start($psi)
$p.StandardInput.BaseStream.Write([BitConverter]::GetBytes([int]$req.Length), 0, 4)
$p.StandardInput.BaseStream.Write($req, 0, $req.Length); $p.StandardInput.Close()
$ms = New-Object IO.MemoryStream; $p.StandardOutput.BaseStream.CopyTo($ms); $p.WaitForExit()
$bytes = $ms.ToArray()
$reply = if ($bytes.Length -gt 4) { [Text.Encoding]::UTF8.GetString($bytes, 4, $bytes.Length - 4) | ConvertFrom-Json } else { $null }
if ($reply -and $reply.ok) { Say "  [4/4] live test passed: $($reply.text.Trim())" 'Green' }
else { Say "  [4/4] live test FAILED: $(if ($reply) { $reply.error } else { 'no reply from the helper' })" 'Red' }

Say "`nDone. In Chrome: Roofr Assist Options -> Coach & Sales -> AI notes -> Test." 'Cyan'

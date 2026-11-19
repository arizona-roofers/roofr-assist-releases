# Roofr Assist notes helper: lets Call Coach (a Chrome extension, which can't start programs) run an AI CLI on
# this computer under the user's OWN account. Chrome starts this through notes-helper.bat (native messaging host
# com.arizonaroofers.notes), sends ONE request, reads ONE reply, and the script exits.
#
#   {"type":"ping"}                                           -> {ok, version, backend, cli}
#   {"type":"generate","backend":"agy|claude","model":"..","system":"<doc>","prompt":"<call>"} -> {ok, text} | {ok:false, error}
#
# Backends:
#   agy     Google Antigravity CLI, signed in with the user's own @arizonaroofers.com Google account (CSR default)
#   claude  Claude Code CLI, signed in with a Claude subscription (Travis's testing)
# Installed by setup.ps1 into %LOCALAPPDATA%\RoofrAssist\notes-helper. Nothing here holds a key or a password.
$ErrorActionPreference = 'Stop'
$Version = '1.2.0'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Log = Join-Path $Here 'helper.log'

function Write-Log($m) { try { Add-Content -Path $Log -Value ("{0} {1}" -f (Get-Date -Format s), $m) -Encoding UTF8 } catch {} }

# ---- Chrome native messaging framing: 4-byte little-endian length + UTF-8 JSON, both directions ----
function Read-Message {
    $in = [Console]::OpenStandardInput()
    $lenBuf = New-Object byte[] 4; $got = 0
    while ($got -lt 4) { $n = $in.Read($lenBuf, $got, 4 - $got); if ($n -le 0) { return $null }; $got += $n }
    $len = [BitConverter]::ToInt32($lenBuf, 0)
    $buf = New-Object byte[] $len; $got = 0
    while ($got -lt $len) { $n = $in.Read($buf, $got, $len - $got); if ($n -le 0) { break }; $got += $n }
    return ([Text.Encoding]::UTF8.GetString($buf, 0, $got) | ConvertFrom-Json)
}
function Send-Message($obj) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress -Depth 6))
    $out = [Console]::OpenStandardOutput()
    $out.Write([BitConverter]::GetBytes([int]$bytes.Length), 0, 4)
    $out.Write($bytes, 0, $bytes.Length)
    $out.Flush()
}

function Get-Config {
    $p = Join-Path $Here 'config.json'
    if (Test-Path $p) { try { return Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    return [pscustomobject]@{ backend = 'agy' }
}

function Find-Cli($name) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    # Chrome may start us with a thinner PATH than a terminal: check the usual install spots.
    foreach ($p in @("$env:LOCALAPPDATA\agy\bin\agy.exe", "$env:USERPROFILE\.local\bin\claude.exe", "$env:APPDATA\npm\claude.cmd")) {
        if ((Split-Path -Leaf $p) -like "$name*" -and (Test-Path $p)) { return $p }
    }
    return $null
}

# Run a CLI with the prompt on stdin, UTF-8 both ways (PowerShell 5.1 pipes default to ASCII and mangle names).
function Invoke-Cli($exe, [string]$arguments, [string]$stdin, [int]$timeoutSec, [string]$cwd = '') {
    $psi = New-Object Diagnostics.ProcessStartInfo
    if ($cwd) { $psi.WorkingDirectory = $cwd }
    $psi.FileName = $exe; $psi.Arguments = $arguments
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    $w = New-Object IO.StreamWriter($p.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false)))
    $w.Write($stdin); $w.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($timeoutSec * 1000)) { try { $p.Kill() } catch {}; throw "timed out after $timeoutSec s" }
    return @{ code = $p.ExitCode; out = $outTask.Result; err = $errTask.Result }
}

function Invoke-Claude($req) {
    $exe = Find-Cli 'claude'; if (-not $exe) { throw 'Claude Code CLI not found (install it and sign in with your Claude subscription)' }
    $sys = Join-Path $env:TEMP ("ra-note-sys-{0}.txt" -f [guid]::NewGuid())
    [IO.File]::WriteAllText($sys, [string]$req.system, (New-Object Text.UTF8Encoding($false)))
    try {
        $model = if ($req.model) { $req.model } else { 'claude-sonnet-5-5' }
        $cliArgs = "-p --model $model --system-prompt-file `"$sys`" --tools `"`" --strict-mcp-config --output-format json --no-session-persistence"
        $r = Invoke-Cli $exe $cliArgs ([string]$req.prompt) 240
        $j = $r.out | ConvertFrom-Json
        if ($j.is_error) { throw ("claude: " + $j.result) }
        return [string]$j.result
    } finally { Remove-Item $sys -ErrorAction SilentlyContinue }
}

# agy (Antigravity) reads the whole prompt from stdin as one stream-json message and answers in stream-json: no
# 32K command-line limit, and the reply comes back as data. (The old "-p" form took "--output-format" as the prompt, so
# every note came back empty, Bronte's Mac 9/30.) Any model agy offers ("agy models"); agy has two quota pools (Claude +
# GPT-OSS, and everything else), so a used-up pool retries once on a model from the other one.
# agy's default agent has tools (run a command, read files, browse) and, asked to write a note, sometimes reaches for
# one; headless mode can't ask permission, so the turn ends with no text (Bronte's Mac 9/30). Notes run as a custom
# agent with NO tools: it can only answer. Auto-approving tools would let a caller's words steer commands on the CSR's
# computer. The agent file lives next to this script and agy runs from here, so it's found as a project agent.
$AgentMd = (@(
    '---',
    'name: notes-writer',
    'description: Writes Roofr call notes as plain text from the message it is given. Uses no tools.',
    'mainAgent: true',
    'subagent: false',
    'excludeDefaultComponents: true',
    'tools: []',
    '---',
    '# Notes writer',
    'Reply with text only. Never call a tool, run a command, open a file or browse: everything you need is in the message.',
    ''
) -join "`n")
function Get-AgyAgentDir {
    $dir = Join-Path $Here '.agents\agents\notes-writer'; $file = Join-Path $dir 'agent.md'
    $have = if (Test-Path $file) { [IO.File]::ReadAllText($file) } else { '' }
    if ($have -ne $AgentMd) { New-Item -ItemType Directory -Force -Path $dir | Out-Null; [IO.File]::WriteAllText($file, $AgentMd, (New-Object Text.UTF8Encoding($false))) }
    return $Here
}
function Get-AgyPool($m) { if ([string]$m -match 'claude|gpt-oss') { 'other' } else { 'gemini' } }
function Invoke-AgyOnce($exe, [string]$model, [string]$prompt) {
    $msg = (@{ event = 'user'; message = @{ role = 'user'; content = $prompt } } | ConvertTo-Json -Compress -Depth 5) + "`n"
    $m = if ($model) { " --model `"$model`"" } else { '' }
    $r = Invoke-Cli $exe ("--agent notes-writer --input-format stream-json --output-format stream-json --print-timeout 180s --disable-slash-commands" + $m) $msg 240 (Get-AgyAgentDir)
    $res = $null
    foreach ($line in ([string]$r.out -split "`n")) {
        if (-not $line.Trim()) { continue }
        try { $j = $line | ConvertFrom-Json } catch { continue }
        if ($j.event -eq 'result') { $res = $j.result }
    }
    if ($res -and $res.status -eq 'SUCCESS' -and ([string]$res.response).Trim()) { return @{ text = [string]$res.response } }
    $why = if ($res -and $res.error) { [string]$res.error } elseif ($r.err) { ([string]$r.err -split "`n")[0] } else { 'no reply' }
    return @{ error = $why; quota = ($why -match 'QUOTA|RESOURCE_EXHAUSTED|429' -or [string]$r.err -match 'QUOTA|RESOURCE_EXHAUSTED|429') }
}
function Invoke-Agy($req, $cfg) {
    $exe = Find-Cli 'agy'; if (-not $exe) { throw 'agy (Google Antigravity CLI) not found: run the AI notes setup again' }
    # agy has no system-prompt flag: the note instructions and the call go in one prompt.
    $prompt = [string]$req.system + "`n`n=====`n`n" + [string]$req.prompt
    $model = if ($req.model) { [string]$req.model } elseif ($cfg.model) { [string]$cfg.model } else { '' }
    $spare = if ($null -ne $req.fallbackModel) { [string]$req.fallbackModel } elseif ((Get-AgyPool $model) -eq 'gemini') { 'claude-sonnet-4-6' } else { 'gemini-3.8-flash-medium' }
    $r = Invoke-AgyOnce $exe $model $prompt
    if ($r.text) { return @{ text = $r.text; model = $(if ($model) { $model } else { 'agy default' }) } }
    if ($r.quota -and $spare -and (Get-AgyPool $spare) -ne (Get-AgyPool $model)) {
        Write-Log ("agy quota on {0}, trying {1}" -f $(if ($model) { $model } else { 'default' }), $spare)
        $r2 = Invoke-AgyOnce $exe $spare $prompt
        if ($r2.text) { return @{ text = $r2.text; model = $spare } }
        if ($r2.quota) { throw 'agy quota is used up on both model pools for now; Call Coach keeps its own note' }
        throw ("agy ({0}): {1}; Call Coach keeps its own note" -f $spare, $r2.error)
    }
    if ($r.quota) { throw 'your agy quota is used up for now; Call Coach keeps its own note' }
    throw ("agy: {0}; Call Coach keeps its own note" -f $r.error)
}

try {
    $req = Read-Message
    if (-not $req) { exit 0 }
    $cfg = Get-Config
    if ($req.type -eq 'ping') {
        $b = if ($req.backend) { $req.backend } else { $cfg.backend }
        Send-Message @{ ok = $true; version = $Version; backend = $b; cli = (Find-Cli $b) }
        exit 0
    }
    if ($req.type -eq 'generate') {
        $b = if ($req.backend) { $req.backend } else { $cfg.backend }
        $t0 = Get-Date
        if ($b -eq 'claude') { $text = Invoke-Claude $req; $used = [string]$req.model }
        elseif ($b -eq 'agy') { $g = Invoke-Agy $req $cfg; $text = $g.text; $used = $g.model }
        else { throw "unknown backend '$b'" }
        Write-Log ("generate {0} {1} ok {2:n1}s {3} chars" -f $b, $used, ((Get-Date) - $t0).TotalSeconds, $text.Length)
        Send-Message @{ ok = $true; text = $text; backend = $b; model = $used }
        exit 0
    }
    Send-Message @{ ok = $false; error = "unknown request type '$($req.type)'" }
} catch {
    Write-Log ("error: " + $_.Exception.Message)
    try { Send-Message @{ ok = $false; error = $_.Exception.Message } } catch {}
}

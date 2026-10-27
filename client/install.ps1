# Office AI-proxy automation for Windows (macOS/Linux: install.sh).
#
# Installs, for the current user only (no admin needed):
#   - gost: local proxy on 127.0.0.1:1080 (HTTP + SOCKS5), always running.
#     On the office network, hosts from the office PAC go through the office
#     proxy and everything else is direct. Elsewhere, everything is direct
#     and the office proxy is never contacted.
#   - proxy-auto: watcher started at logon that checks every 15s, switches
#     gost between those two modes (refreshing its host list from the PAC)
#     and keeps it running. It also sets the proxy env in
#     ~/.claude/settings.json on the office network if that file exists.
#
# Served by the proxy container's nginx, which fills in the PAC URL. Usage (PowerShell):
#   & ([scriptblock]::Create((irm http://<server>:<pac port>/install.ps1)))              install or update
#   & ([scriptblock]::Create((irm http://<server>:<pac port>/install.ps1))) -Uninstall   remove everything
# Running a local copy needs PAC_URL set:
#   $env:PAC_URL = 'http://<server>:<pac port>/proxy.pac'; powershell -ExecutionPolicy Bypass -File client\install.ps1
#
# The proxy host/port and host list come from the PAC. Overrides (env vars):
#   PROXY_HOST, PROXY_PORT, OFFICE_NET (IP prefix that counts as "office";
#   default: first three octets of PROXY_HOST), LISTEN, GOST_VERSION

param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-Setting($name, $default) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if ($v) { $v } else { $default }
}

$PacUrl      = Get-Setting PAC_URL '__PAC_URL__'
$Listen      = Get-Setting LISTEN '127.0.0.1:1080'
$GostVersion = Get-Setting GOST_VERSION '3.3.1'

$Dir      = Join-Path $env:LOCALAPPDATA 'proxy-auto'
$Watcher  = Join-Path $Dir 'proxy-auto.ps1'
$TaskName = 'proxy-auto'
$Shortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'proxy-auto.lnk'

function Say($msg) { Write-Host "==> $msg" }

function Write-Utf8($path, $text) {
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
}

function Stop-ProxyAuto {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" |
        Where-Object { $_.CommandLine -like "*$Watcher*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-Process gost -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq (Join-Path $Dir 'gost.exe') } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

if ($Uninstall) {
    Stop-ProxyAuto
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $Shortcut -Force -ErrorAction SilentlyContinue
    Start-Sleep 1
    Remove-Item $Dir -Recurse -Force -ErrorAction SilentlyContinue
    Say 'Removed proxy-auto and gost.'
    return
}

if ($PacUrl -notmatch '^https?://') {
    throw "Set PAC_URL first, e.g. `$env:PAC_URL = 'http://192.168.50.200:44081/proxy.pac'"
}
try {
    $req = [Net.WebRequest]::Create($PacUrl)
    $req.Proxy = $null
    $req.Timeout = 10000
    $resp = $req.GetResponse()
    try { $pac = (New-Object IO.StreamReader $resp.GetResponseStream()).ReadToEnd() }
    finally { $resp.Close() }
} catch {
    throw "Can't fetch $PacUrl. Run this on the office network."
}
# PAC line: var PROXY = "PROXY host:port". PacProxy is what the office PAC
# names; the watcher checks for it to tell the real office from a lookalike.
if ($pac -notmatch '"PROXY ([^:"]+):(\d+)"') {
    throw "Couldn't find 'PROXY host:port' in $PacUrl"
}
$PacProxy  = "$($Matches[1]):$($Matches[2])"
$ProxyHost = Get-Setting PROXY_HOST $Matches[1]
$ProxyPort = Get-Setting PROXY_PORT $Matches[2]
$OfficeNet = Get-Setting OFFICE_NET ($ProxyHost -replace '\d+$', '')
Say "Office proxy: ${ProxyHost}:$ProxyPort (office network: $OfficeNet*)"

New-Item -ItemType Directory -Force $Dir | Out-Null
Stop-ProxyAuto   # so an update can replace gost.exe and pick up new config

$GostExe = Join-Path $Dir 'gost.exe'
$haveGost = (Test-Path $GostExe) -and ((& $GostExe -V 2>$null) -match "^gost $([regex]::Escape($GostVersion))")
if (-not $haveGost) {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $url = "https://github.com/go-gost/gost/releases/download/v$GostVersion/gost_${GostVersion}_windows_${arch}.zip"
    Say "Downloading gost $GostVersion"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("gost-" + [guid]::NewGuid())
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        Invoke-WebRequest -UseBasicParsing $url -OutFile "$tmp\gost.zip"
        Expand-Archive "$tmp\gost.zip" $tmp
        Copy-Item "$tmp\gost.exe" $GostExe -Force
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Say "Writing config to $Dir"
$config = [ordered]@{
    ProxyHost = $ProxyHost
    ProxyPort = [int]$ProxyPort
    PacUrl    = $PacUrl
    PacProxy  = $PacProxy
    OfficeNet = $OfficeNet
}
Write-Utf8 (Join-Path $Dir 'config.json') ($config | ConvertTo-Json)

$hostsPath = (Join-Path $Dir 'hosts.txt') -replace '\\', '/'
$logPath   = (Join-Path $Dir 'gost.log') -replace '\\', '/'
# gost runs gost.yaml, which proxy-auto keeps as a copy of one of these.
Write-Utf8 (Join-Path $Dir 'gost-office.yaml') @"
# Generated by proxy-auto install.ps1. Office mode: hosts in hosts.txt go
# through the office proxy; everything else connects directly.
services:
- name: local
  addr: $Listen
  handler: { type: auto, chain: office }
  listener: { type: tcp }
chains:
- name: office
  hops:
  - name: hop-0
    bypass: office-hosts
    nodes:
    - name: office-proxy
      addr: ${ProxyHost}:$ProxyPort
      connector: { type: http }
      dialer: { type: tcp }
bypasses:
- name: office-hosts
  whitelist: true
  reload: 60s
  file:
    path: $hostsPath
log:
  output: $logPath
"@

Write-Utf8 (Join-Path $Dir 'gost-direct.yaml') @"
# Generated by proxy-auto install.ps1. Direct mode (off the office network):
# everything connects directly.
services:
- name: local
  addr: $Listen
  handler: { type: auto }
  listener: { type: tcp }
log:
  output: $logPath
"@
# Start direct; proxy-auto switches to office mode if we're there.
Copy-Item (Join-Path $Dir 'gost-direct.yaml') (Join-Path $Dir 'gost.yaml') -Force

Say "Installing $Watcher"
Write-Utf8 $Watcher @'
# Toggle the office AI proxy setup (Windows). Installed by proxy-auto
# install.ps1 and started at logon.
# On (office) when this machine's IP starts with OfficeNet, the PAC at PacUrl
# names PacProxy, AND the proxy port is reachable:
#   - gost: switch between office mode (PAC hosts via the office proxy) and
#     direct mode; refresh its hosts from the PAC. gost is kept running.
#   - Claude Code: add/remove proxy env in ~/.claude/settings.json (if present)
#
#   proxy-auto.ps1 watch           check every 15s (what the logon task runs)
#   proxy-auto.ps1 check           check once
#   proxy-auto.ps1 refresh-hosts   re-sync the host list from the PAC

param([string]$Mode = 'check')

$Dir      = $PSScriptRoot
$Cfg      = Get-Content (Join-Path $Dir 'config.json') -Raw | ConvertFrom-Json
$Hosts    = Join-Path $Dir 'hosts.txt'
$GostExe  = Join-Path $Dir 'gost.exe'
$Log      = Join-Path $Dir 'proxy-auto.log'
$Settings = Join-Path $env:USERPROFILE '.claude\settings.json'
$Utf8     = New-Object Text.UTF8Encoding $false

function Log($msg) {
    Add-Content $Log ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $msg)
}

# Fetch the PAC directly (no system proxy); '' on failure.
# Works on Windows PowerShell 5.1 and 7.
function Get-Pac {
    try {
        $req = [Net.WebRequest]::Create($Cfg.PacUrl)
        $req.Proxy = $null
        $req.Timeout = 3000
        $resp = $req.GetResponse()
        try { return (New-Object IO.StreamReader $resp.GetResponseStream()).ReadToEnd() }
        finally { $resp.Close() }
    } catch { return '' }
}

# Only the office PAC server serves a PAC naming our proxy; a lookalike
# network on the same subnet (e.g. a home router) won't.
function Test-OfficePac {
    for ($i = 1; $i -le 3; $i++) {
        if ((Get-Pac).Contains("`"PROXY $($Cfg.PacProxy)`"")) { return $true }
        if ($i -lt 3) { Start-Sleep 1 }
    }
    return $false
}

# PAC HOST_PATTERNS_STR -> one gost matcher per line ("*.x" -> ".x", which
# gost treats as x and all its subdomains, same as the PAC).
function Update-Hosts {
    $pac = Get-Pac
    if ($pac -notmatch 'HOST_PATTERNS_STR\s*=\s*"([^"]*)"') {
        Log "hosts: could not read $($Cfg.PacUrl), keeping current list"
        return $false
    }
    $list = $Matches[1] -split ',' | ForEach-Object { $_.Trim() -replace '^\*\.', '.' } |
        Where-Object { $_ } | Sort-Object -Unique
    $new = ($list -join "`n") + "`n"
    $old = if (Test-Path $Hosts) { [IO.File]::ReadAllText($Hosts) } else { '' }
    if ($new -ceq $old) {
        (Get-Item $Hosts).LastWriteTime = Get-Date
    } else {
        [IO.File]::WriteAllText($Hosts, $new, $Utf8)
        Log "hosts: updated from PAC ($(@($list).Count) entries)"
    }
    return $true
}

function Get-LocalIP {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
    if (-not $route) { return $null }
    (Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Select-Object -First 1).IPAddress
}

function Test-Proxy {
    $c = New-Object Net.Sockets.TcpClient
    try { $c.ConnectAsync($Cfg.ProxyHost, $Cfg.ProxyPort).Wait(1000) -and $c.Connected }
    catch { $false }
    finally { $c.Close() }
}

function Get-Gost {
    Get-Process gost -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $GostExe }
}

function Start-Gost {
    try {
        Start-Process $GostExe -ArgumentList '-C', "`"$(Join-Path $Dir 'gost.yaml')`"" -WindowStyle Hidden
    } catch { Log "gost: FAILED to start: $_" }
}

# gost always runs so 127.0.0.1:1080 keeps working everywhere; only its
# config changes. It's restarted only when the mode changes (or if it died).
function Set-Gost($on) {
    $mode   = if ($on) { 'office' } else { 'direct' }
    $active = Join-Path $Dir 'gost.yaml'
    $want   = [IO.File]::ReadAllText((Join-Path $Dir "gost-$mode.yaml"))
    $switch = $want -cne [IO.File]::ReadAllText($active)
    if ($on) {
        # Re-sync hosts on entering the office and at least hourly while there.
        $stale = -not (Test-Path $Hosts) -or (Get-Item $Hosts).LastWriteTime -lt (Get-Date).AddHours(-1)
        if ($switch -or $stale) { Update-Hosts | Out-Null }
    }
    $running = Get-Gost
    if ($switch) {
        foreach ($p in @($running)) { if ($p) { $p.Kill(); $p.WaitForExit(3000) | Out-Null } }
        $running = $null
        [IO.File]::WriteAllText($active, $want, $Utf8)
        Log "gost: $mode mode"
    }
    if (-not $running) { Start-Gost }
}

function Set-Claude($on) {
    if (-not (Test-Path $Settings)) { return }
    try { $json = [IO.File]::ReadAllText($Settings) | ConvertFrom-Json } catch { Log 'claude settings: unreadable, skipped'; return }
    $p = "http://$($Cfg.ProxyHost):$($Cfg.ProxyPort)"
    $want = [ordered]@{ HTTP_PROXY = $p; HTTPS_PROXY = $p; NO_PROXY = 'localhost,127.0.0.1,::1,.local' }
    $cur = $json.env
    $changed = $false
    if ($on) {
        if (-not $cur) {
            $cur = New-Object PSObject
            $json | Add-Member -NotePropertyName env -NotePropertyValue $cur -Force
        }
        foreach ($k in $want.Keys) {
            if ($cur.$k -ne $want[$k]) {
                $cur | Add-Member -NotePropertyName $k -NotePropertyValue $want[$k] -Force
                $changed = $true
            }
        }
    } elseif ($cur) {
        foreach ($k in $want.Keys) {
            if ($cur.PSObject.Properties[$k]) { $cur.PSObject.Properties.Remove($k); $changed = $true }
        }
        if ($changed -and -not @($cur.PSObject.Properties).Count) { $json.PSObject.Properties.Remove('env') }
    }
    if (-not $changed) { return }
    $tmp = "$Settings.tmp"
    [IO.File]::WriteAllText($tmp, ($json | ConvertTo-Json -Depth 64), $Utf8)
    Move-Item $tmp $Settings -Force
    Log "claude settings: proxy $(if ($on) { 'on' } else { 'off' })"
}

function Invoke-Check {
    $ip = Get-LocalIP
    if (-not $ip) {
        # No network yet: keep the current mode, just make sure gost is up.
        if (-not (Get-Gost)) { Start-Gost }
        return
    }
    $on = $ip.StartsWith($Cfg.OfficeNet) -and (Test-OfficePac) -and (Test-Proxy)
    Set-Claude $on
    Set-Gost $on
}

switch ($Mode) {
    'refresh-hosts' { if (-not (Update-Hosts)) { exit 1 } }
    'watch' {
        while ($true) {
            try { Invoke-Check } catch { Log "error: $_" }
            Start-Sleep 15
        }
    }
    default { Invoke-Check }
}
'@

Say "Fetching host list from $PacUrl"
& powershell -NoProfile -ExecutionPolicy Bypass -File $Watcher refresh-hosts
if ($LASTEXITCODE -ne 0) { throw "No host list found in $PacUrl" }

Say 'Registering logon task'
$psArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Watcher`" watch"
try {
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
    $trigger  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Remove-Item $Shortcut -Force -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $TaskName
} catch {
    # Some managed machines block task creation; fall back to the Startup folder.
    Say "Scheduled task not allowed ($($_.Exception.Message)); using Startup folder instead"
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($Shortcut)
    $lnk.TargetPath = 'powershell.exe'
    $lnk.Arguments = $psArgs
    $lnk.WindowStyle = 7
    $lnk.Save()
    Start-Process powershell.exe -ArgumentList $psArgs -WindowStyle Hidden
}

Start-Sleep 4
$running = Get-Process gost -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $GostExe }
$office = [IO.File]::ReadAllText((Join-Path $Dir 'gost.yaml')) -ceq [IO.File]::ReadAllText((Join-Path $Dir 'gost-office.yaml'))
if (-not $running) {
    Say "Installed, but gost isn't running yet. Check $Dir\proxy-auto.log and $Dir\gost.log."
} elseif ($office) {
    Say "Done. gost is running on $Listen in office mode (PAC hosts via ${ProxyHost}:$ProxyPort)."
} else {
    Say "Done. gost is running on $Listen in direct mode (not on the office network)."
}
Write-Host "    Use http://$Listen or socks5h://$Listen in your apps."
Write-Host "    Logs: $Dir\proxy-auto.log, $Dir\gost.log"

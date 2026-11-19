$ErrorActionPreference = 'Stop'
# Model a shell that ran a release before PATH setup was added.
if (-not ('TabResumeNative' -as [type])) {
    Add-Type 'public static class TabResumeNative { public static string GetCwd(int pid) { return null; } }'
}
if (-not ('SameSeshPathNative' -as [type])) {
    Add-Type 'public static class SameSeshPathNative { public static int Notifications; public static void NotifyEnvironmentChanged() { Notifications++; } }'
}
. "$PSScriptRoot\same-sesh.ps1" -Command help 6>$null

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("same-sesh-tests-" + [guid]::NewGuid())
$oldCopilotHome = $env:COPILOT_HOME
$checks = 0

function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -cne $Expected) { throw "$Label`: expected '$Expected', got '$Actual'." }
    $script:checks++
}

function Get-Cwd([int]$ProcessId) { 'C:\process-start' }

function New-TestSession([string]$Id, [string]$Cwd, [int]$ProcessId) {
    $dir = Join-Path $env:COPILOT_HOME "session-state\$Id"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $dir "inuse.$ProcessId.lock"), "$ProcessId`n")
    [IO.File]::WriteAllText((Join-Path $dir 'workspace.yaml'), "cwd: $Cwd`nname: Synthetic session`n")
    [IO.File]::WriteAllText((Join-Path $dir 'events.jsonl'), '{"type":"user.message","data":{"content":"Synthetic prompt"}}' + "`n")
    $dir
}

try {
    $notifications = [SameSeshPathNative]::Notifications
    Send-PathChangeNotification
    Assert-Equal ([SameSeshPathNative]::Notifications) ($notifications + 1) 'PATH notification works with the old runtime already loaded'
    $initialPath = '%SAME_SESH_OTHER_TOOL%;C:\Tools'
    Assert-Equal (Add-PathEntry $initialPath 'C:\My Repo') ($initialPath + ';C:\My Repo') 'PATH setup preserves existing entries and variable references'
    Assert-Equal (Add-PathEntry $initialPath 'c:\tools\') $initialPath 'PATH setup handles existing entries case-insensitively'
    Assert-Equal (Add-PathEntry '' 'C:\My Repo') 'C:\My Repo' 'PATH setup handles an empty user path'
    $env:COPILOT_HOME = Join-Path $testRoot 'copilot'
    $first = '11111111-1111-4111-8111-111111111111'
    $second = '22222222-2222-4222-8222-222222222222'
    $stale = '33333333-3333-4333-8333-333333333333'
    $started = (Get-Date).AddMinutes(-1)
    $proc = [pscustomobject]@{
        Name = 'copilot.exe'; ProcessId = 104; ParentProcessId = 103
        CommandLine = 'copilot.exe'; CreationDate = $started
    }
    $firstDir = New-TestSession $first 'C:\synthetic-one' 104
    $resolved = Resolve-Copilot $proc
    Assert-Equal $resolved.sessionId $first 'Fresh session without resume flag'
    Assert-Equal $resolved.cwd 'C:\synthetic-one' 'Workspace overrides startup cwd'
    Assert-Equal $resolved.title 'Synthetic session' 'Workspace title'
    Assert-Equal $resolved.lastPrompt 'Synthetic prompt' 'User event content'
    Assert-Equal $resolved.resume "copilot --resume $first" 'Exact resume command'

    $events = Join-Path $firstDir 'events.jsonl'
    $prompt = '{"type": "user.message", "data": {"content": "Older prompt beyond tail"}}' + "`n"
    $output = '{"type":"tool.execution_complete","data":{"output":"' + ('x' * 300000) + '"}}' + "`n"
    [IO.File]::WriteAllText($events, $prompt + $output + '{"type":"user.message","data":{"content":"unfinished')
    Assert-Equal (Resolve-Copilot $proc).lastPrompt 'Older prompt beyond tail' 'Long output and incomplete final event'
    [IO.File]::WriteAllText($events, $output)
    Assert-Equal (Resolve-Copilot $proc).lastPrompt $null 'No submitted prompt'

    $realReadTail = ${function:Read-TailLines}
    function Read-TailLines { throw 'An unchanged file must not be read again.' }
    Assert-Equal (Resolve-Copilot $proc).lastPrompt $null 'Unchanged file is answered from cache'
    Set-Item function:Read-TailLines $realReadTail
    Add-Content -LiteralPath $events -Value '{"type":"user.message","data":{"content":"After change"}}'
    Assert-Equal (Resolve-Copilot $proc).lastPrompt 'After change' 'Changed file is read again'

    $secondDir = New-TestSession $second 'C:\synthetic-one' 104
    $logDir = Join-Path $testRoot 'custom logs'
    New-Item -ItemType Directory -Path $logDir | Out-Null
    $stamp = [long](($started.ToUniversalTime().AddSeconds(1) - [datetime]'1970-01-01').TotalMilliseconds)
    $log = Join-Path $logDir "process-$stamp-104.log"
    [IO.File]::WriteAllText($log, "[INFO] Registering foreground session: $second`n[INFO] Unregistering foreground session: $second`n[INFO] Registering foreground session: $first`n")
    $proc.CommandLine = "copilot.exe --resume $second --log-dir `"$logDir`""
    Assert-Equal (Resolve-Copilot $proc).sessionId $first 'Foreground wins over launch ID and lock order'
    Add-Content -LiteralPath $log -Value "[INFO] Registering foreground session: $second"
    Assert-Equal (Resolve-Copilot $proc).sessionId $second 'Foreground switches in same folder'
    Add-Content -LiteralPath $log -Value "[INFO] Unregistering foreground session: $second"
    $warnings = @()
    $resolved = Resolve-Copilot $proc -WarningVariable warnings 3>$null
    Assert-Equal $resolved.sessionId $null 'Ambiguity must not guess from launch ID'
    Assert-Equal ($warnings.Count -gt 0) $true 'Ambiguity is reported'
    Add-Content -LiteralPath $log -Value "[INFO] Registering foreground session: $second"
    $oldLog = Join-Path $logDir 'process-1-104.log'
    [IO.File]::WriteAllText($oldLog, "[INFO] Registering foreground session: $first`n")
    Assert-Equal (Resolve-Copilot $proc).sessionId $second 'Ignore logs from recycled PID'

    $staleDir = New-TestSession $stale 'C:\stale' 104
    (Get-Item (Join-Path $staleDir 'inuse.104.lock')).LastWriteTimeUtc = $started.ToUniversalTime().AddDays(-1)
    Assert-Equal (Resolve-Copilot $proc).sessionId $second 'Ignore locks from recycled PID'
    $wrapper = [pscustomobject]@{
        Name = 'node.exe'; ProcessId = 103; ParentProcessId = 102
        CommandLine = 'node.exe C:\npm\node_modules\@github\copilot\npm-loader.js'
        CreationDate = $started.AddSeconds(-1)
    }
    Assert-Equal (Resolve-Copilot $wrapper) $null 'Npm loader cannot claim native child session'

    $workspace = Join-Path $secondDir 'workspace.yaml'
    [IO.File]::WriteAllText($workspace, "cwd: `"C:\\synthetic-two`"`nname: 'It''s a synthetic title'`n")
    $resolved = Resolve-Copilot $proc
    Assert-Equal $resolved.cwd 'C:\synthetic-two' 'Quoted workspace path'
    Assert-Equal $resolved.title "It's a synthetic title" 'Quoted workspace title'
    [IO.File]::WriteAllText($workspace, "cwd: C:\synthetic-two`nsummary: >-`n  A folded`n  summary`n")
    Assert-Equal (Resolve-Copilot $proc).title 'A folded summary' 'Summary fallback'

    $fallback = [pscustomobject]@{
        Name = 'copilot.exe'; ProcessId = 105; ParentProcessId = 102
        CommandLine = "copilot.exe --resume=`"$first`""; CreationDate = $started
    }
    Assert-Equal (Resolve-Copilot $fallback).sessionId $first 'Explicit ID fallback without lock'
    $fallback.CommandLine = "copilot.exe --session-id $first"
    Assert-Equal (Resolve-Copilot $fallback).sessionId $first 'Session ID flag fallback'

    $script:fakeProcesses = @(
        [pscustomobject]@{ Name = 'WindowsTerminal.exe'; ProcessId = 101; ParentProcessId = 0; CreationDate = $started.AddSeconds(-3) }
        [pscustomobject]@{ Name = 'pwsh.exe'; ProcessId = 102; ParentProcessId = 101; CreationDate = $started.AddSeconds(-2) }
        $wrapper
        $proc
    )
    function Get-CimInstance { $script:fakeProcesses }
    function Get-Epoch { 'synthetic-epoch' }
    $tabs = @(Get-LiveTabs | Where-Object tool -eq 'copilot')
    Assert-Equal $tabs.Count 1 'Tabs remain pipeline-friendly'
    Assert-Equal $tabs[0].sessionId $second 'Native CLI beneath wrapper is captured'
    Assert-Equal $tabs[0].cwd 'C:\synthetic-two' 'Captured native workspace'
    $tabCommand = ConvertTo-WtTab $tabs[0]
    if ($tabCommand -notmatch '-EncodedCommand (\S+)') { throw 'Resume command was not encoded.' }
    $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
    Assert-Equal $decoded "copilot --resume $second" 'Encoded restore preserves exact ID'
    $tab = @{ tool = 'copilot'; sessionId = $second; resume = 'untrusted stored command'; shell = 'powershell.exe' }
    Assert-Equal (Get-RestoreCommand $tab) "copilot --resume $second" 'Recorded resume text is ignored'
    $tab.sessionId = 'invalid session ID'
    $invalidIdRejected = $false
    try { $null = ConvertTo-WtTab $tab } catch { $invalidIdRejected = $_.Exception.Message -like 'Invalid session ID*' }
    Assert-Equal $invalidIdRejected $true 'Malformed session ID is rejected'
    $tab.tool = 'unsupported'
    Assert-Equal (Get-RestoreCommand $tab) $null 'Unsupported tools cannot run recorded commands'
    $tab.wasRunning = 'quoted ' + [char]0x2019 + ' text' + [Environment]::NewLine + 'second line'
    foreach ($shell in 'powershell.exe', 'cmd.exe') {
        $tab.shell = $shell
        $tabCommand = ConvertTo-WtTab $tab
        if ($tabCommand -notmatch '-EncodedCommand (\S+)') { throw 'Display script was not encoded.' }
        $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
        if ($decoded -notmatch "\AWrite-Host \(\[Text.Encoding\]::Unicode.GetString\(\[Convert\]::FromBase64String\('([A-Za-z0-9+/=]+)'\)\)\) -ForegroundColor DarkGray\z") {
            throw 'Display script contains unexpected code.'
        }
        $message = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
        Assert-Equal $message "same-sesh: this tab was running: $($tab.wasRunning)" "Process arguments stay data in $shell"
    }

    $StateDir = Join-Path $testRoot 'snapshots'
    $HistoryDir = Join-Path $StateDir 'history'
    $LastFile = Join-Path $StateDir 'last.json'
    $WatcherMutexName = 'Local\same-sesh-test-' + [guid]::NewGuid()
    $status = @(Show-WatcherStatus 6>&1)
    Assert-Equal ($status[0].ToString() -like 'Watcher: not running*') $true 'Status detects stopped watcher'
    Assert-Equal $status[1].ToString() 'Last saved: no snapshot yet.' 'Status handles missing snapshot'
    $snap = Save-Snapshot
    Assert-Equal @($snap.tabs).Count 1 'Single-tab snapshot shape'
    $created = $false
    $watcher = New-Object Threading.Mutex($true, $WatcherMutexName, [ref]$created)
    try {
        $status = @(Show-WatcherStatus 6>&1)
        $savedAt = [datetime]::Parse($snap.takenAt, $null, 'RoundtripKind').ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
        Assert-Equal $status[0].ToString() 'Watcher: running' 'Status detects active watcher'
        Assert-Equal $status[1].ToString() "Last saved: $savedAt (1 tab)" 'Status displays the saved timestamp'
    } finally {
        if ($created) { $watcher.ReleaseMutex() }
        $watcher.Dispose()
    }
    $previous = [IO.File]::ReadAllText($LastFile)
    $pin = Save-Snapshot -SnapshotName 'Before deploy'
    Assert-Equal $pin.name 'Before deploy' 'Named snapshot keeps original casing'
    Assert-Equal (Read-NamedSnapshot 'BEFORE DEPLOY').tabs[0].sessionId $second 'Named lookup ignores case'
    Assert-Equal ([IO.File]::ReadAllText($LastFile)) $previous 'Named save leaves last snapshot alone'
    Assert-Equal @(Get-AllSnapshots).Count 1 'Named save leaves numbered history alone'
    $list = (Show-SnapshotList 6>&1) -join "`n"
    Assert-Equal ($list -match 'Before deploy' -and $list -match 'Reopen these') $true 'List includes both kinds of snapshot'
    $automaticFile = $LastFile
    $LastFile = Join-Path $StateDir 'missing.json'
    try {
        $list = (Show-SnapshotList 6>&1) -join "`n"
        Assert-Equal ($list -match 'Named snapshots:' -and $list -match 'Before deploy') $true 'List includes a named-only store'
        Assert-Equal ($list -match 'No snapshot yet') $false 'Named-only store is not reported empty'
    } finally { $LastFile = $automaticFile }
    $duplicateRejected = $false
    try { $null = Save-Snapshot -SnapshotName 'before deploy' } catch { $duplicateRejected = $_.Exception.Message -like 'Snapshot name already exists*' }
    Assert-Equal $duplicateRejected $true 'Duplicate names are rejected'
    $unsafeRejected = $false
    try { $null = Read-NamedSnapshot '../outside' } catch { $unsafeRejected = $_.Exception.Message -like 'Use 1-64*' }
    Assert-Equal $unsafeRejected $true 'Unsafe names are rejected'
    $script:fakeProcesses = @()
    $emptyNamedRejected = $false
    try { $null = Save-Snapshot -SnapshotName 'Empty' } catch { $emptyNamedRejected = $_.Exception.Message -like 'No live terminals*' }
    Assert-Equal $emptyNamedRejected $true 'Empty named saves are rejected'
    $MarkerFile = Join-Path $StateDir 'restored-epoch.txt'
    function Start-Process { param($FilePath, $ArgumentList) $script:namedLaunch = $ArgumentList }
    Restore-Snapshot -SnapshotName 'Before deploy' 6>$null
    Assert-Equal ($script:namedLaunch -like '*-EncodedCommand*') $true 'Named restore uses the normal launcher'
    Assert-Equal (Test-Path -LiteralPath $MarkerFile) $false 'Named restore preserves automatic restore selection'
    Assert-Equal (Save-Snapshot) $null 'Empty state is not recorded'
    Assert-Equal ([IO.File]::ReadAllText($LastFile)) $previous 'Empty state preserves last snapshot'

    $script:fakeProcesses = @(
        [pscustomobject]@{ Name = 'WindowsTerminal.exe'; ProcessId = 101; ParentProcessId = 0; CreationDate = $started.AddSeconds(-3) }
        [pscustomobject]@{ Name = 'pwsh.exe'; ProcessId = 102; ParentProcessId = 101; CreationDate = $started.AddSeconds(-2) }
        $wrapper
        $proc
    )
    function Select-Snapshot { [pscustomobject]@{ tabs = @([pscustomobject]$resolved) } }
    function Show-Snapshot {}
    function Start-Process { throw 'Already-open session must not be launched again.' }
    Restore-Snapshot 6>$null
    $checks++
    Write-Output "$checks checks passed."
} finally {
    $env:COPILOT_HOME = $oldCopilotHome
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

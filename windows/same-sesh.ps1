<#
same-sesh: remember which AI CLI sessions were open in which terminal tabs,
and reopen them after a restart.

  same-sesh              show what would be restored (where you left off)
  same-sesh snapshot     record the current tabs once
  same-sesh restore      reopen the recorded tabs   (-DryRun to preview, -Index N to pick from history)
  same-sesh history      list older snapshots
  same-sesh watch        snapshot every 30s until stopped
  same-sesh install      start the watcher at every login (uninstall removes it)

Pilot scope: Windows Terminal + Windows PowerShell 5.1. The snapshot file is
plain JSON with nothing Windows-specific in its shape, so other terminals
(cmux, tmux) and OSes can read and write the same format later.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'snapshot', 'restore', 'history', 'watch', 'install', 'uninstall', 'help')]
    [string]$Command = 'list',
    [int]$Index = -1,
    [switch]$DryRun,
    [int]$IntervalSeconds = 30
)

$ErrorActionPreference = 'Stop'

# Kept in the home folder, not AppData: Windows gives packaged apps a private
# copy of AppData, so a snapshot written from inside one is invisible elsewhere.
$StateDir = Join-Path $HOME '.same-sesh'
$HistoryDir = Join-Path $StateDir 'history'
$LastFile = Join-Path $StateDir 'last.json'
$MarkerFile = Join-Path $StateDir 'restored-epoch.txt'
$HistoryKeep = 40
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

# --- Terminal adapter (capture side): which processes host tabs -------------
$TerminalHosts = @('WindowsTerminal.exe')
$TerminalHelpers = @('OpenConsole.exe', 'conhost.exe')

# --- Native helper: read another process's working directory ----------------
if (-not ('TabResumeNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class TabResumeNative {
    [StructLayout(LayoutKind.Sequential)]
    struct PBI { public IntPtr R1; public IntPtr Peb; public IntPtr R2a; public IntPtr R2b; public IntPtr Pid; public IntPtr R3; }
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PBI pbi, int len, out int retLen);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    public static string GetCwd(int pid) {
        if (IntPtr.Size != 8) return null;
        IntPtr h = OpenProcess(0x0400 | 0x0010, false, pid);
        if (h == IntPtr.Zero) return null;
        try {
            PBI pbi = new PBI(); int rl; IntPtr n;
            if (NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(typeof(PBI)), out rl) != 0) return null;
            byte[] b = new byte[8];
            if (!ReadProcessMemory(h, IntPtr.Add(pbi.Peb, 0x20), b, (IntPtr)8, out n)) return null;
            IntPtr pp = (IntPtr)BitConverter.ToInt64(b, 0);
            byte[] us = new byte[16];
            if (!ReadProcessMemory(h, IntPtr.Add(pp, 0x38), us, (IntPtr)16, out n)) return null;
            int len = BitConverter.ToUInt16(us, 0);
            if (len <= 0) return null;
            byte[] s = new byte[len];
            if (!ReadProcessMemory(h, (IntPtr)BitConverter.ToInt64(us, 8), s, (IntPtr)len, out n)) return null;
            string r = Encoding.Unicode.GetString(s);
            if (r.Length > 3) r = r.TrimEnd('\\');
            return r;
        } catch { return null; }
        finally { CloseHandle(h); }
    }
}
'@
}

# --- Small helpers ----------------------------------------------------------
function Get-Cwd([int]$ProcessId) {
    try { [TabResumeNative]::GetCwd($ProcessId) } catch { $null }
}

function Read-TailLines([string]$Path, [int]$Bytes = 262144) {
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite,Delete')
    try {
        $start = [Math]::Max(0, $fs.Length - $Bytes)
        [void]$fs.Seek($start, 'Begin')
        $buf = New-Object byte[] ($fs.Length - $start)
        $read = $fs.Read($buf, 0, $buf.Length)
        $lines = [Text.Encoding]::UTF8.GetString($buf, 0, $read) -split "`n"
        if ($start -gt 0) {
            $lines = if ($lines.Count -gt 1) { $lines[1..($lines.Count - 1)] } else { @() }
        }
        $lines
    } finally { $fs.Dispose() }
}

# The watcher asks the same question of the same files every cycle, and a miss
# can mean reading most of a large file. Remember the answer until the file changes.
$script:LastLineCache = @{}

function Read-LastMatchingLine([string]$Path, [string]$Pattern) {
    $file = Get-Item -LiteralPath $Path
    $length = $file.Length
    $key = "$Path|$Pattern"
    $stamp = "$length|$($file.LastWriteTimeUtc.Ticks)"
    $cached = $script:LastLineCache[$key]
    if ($cached -and $cached.stamp -eq $stamp) { return $cached.line }
    $bytes = 262144
    do {
        $line = Read-TailLines $Path $bytes | Where-Object { $_ -match $Pattern } | Select-Object -Last 1
        if ($line -or $bytes -ge $length) {
            $script:LastLineCache[$key] = @{ stamp = $stamp; line = $line }
            return $line
        }
        if ($bytes -eq [int]::MaxValue) { throw "No matching record within the last 2 GB of $Path." }
        $bytes = [int][Math]::Min([long]$bytes * 2, [Math]::Min($length, [int]::MaxValue))
    } while ($true)
}

function Write-Json([string]$Path, $Object) {
    $tmp = "$Path.tmp"
    $json = ConvertTo-Json -InputObject $Object -Depth 6
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-Snapshot([string]$Path) {
    try {
        $s = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $s | Add-Member -NotePropertyName path -NotePropertyValue $Path -Force
        $s | Add-Member -NotePropertyName when -NotePropertyValue ([datetime]::Parse($s.takenAt, $null, 'RoundtripKind')) -Force
        $s
    } catch { $null }
}

function Get-TabKey($Tab) { "$($Tab.tool)|$($Tab.sessionId)|$($Tab.cwd)" }

function Format-Ago($IsoOrDate) {
    if (-not $IsoOrDate) { return '' }
    $d = if ($IsoOrDate -is [datetime]) { $IsoOrDate } else { [datetime]::Parse($IsoOrDate, $null, 'RoundtripKind') }
    $span = (Get-Date) - $d.ToLocalTime()
    if ($span.TotalMinutes -lt 1) { 'just now' }
    elseif ($span.TotalHours -lt 1) { '{0}m ago' -f [int]$span.TotalMinutes }
    elseif ($span.TotalDays -lt 1) { '{0}h ago' -f [int]$span.TotalHours }
    else { '{0}d ago' -f [int]$span.TotalDays }
}

# A new "epoch" starts whenever everything in the terminal has died: reboot or
# sign-out. Boot time alone misses sign-outs and fast-startup shutdowns, so use
# the oldest process in this login session.
function Get-Epoch {
    $sid = (Get-Process -Id $PID).SessionId
    $first = Get-CimInstance Win32_Process -Filter "SessionId=$sid" |
        Where-Object CreationDate | Sort-Object CreationDate | Select-Object -First 1
    if ($first) { $first.CreationDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    else { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
}

# --- Tool adapters ----------------------------------------------------------
# Each takes a process (and the PIDs beneath it) and returns $null, or a
# hashtable: tool, sessionId, cwd, title, resume, lastPrompt, lastActive.

function Resolve-Claude($Proc) {
    if ($Proc.Name -ne 'claude.exe' -and "$($Proc.CommandLine)" -notmatch 'claude-code|@anthropic-ai') { return $null }
    $r = @{ tool = 'claude'; sessionId = $null; cwd = $null; title = $null
            resume = 'claude --continue'; lastPrompt = $null; lastActive = $null }
    # Best source: the record Claude writes for its own PID once the session is live.
    $pidFile = Join-Path $HOME ".claude\sessions\$($Proc.ProcessId).json"
    if (Test-Path -LiteralPath $pidFile) {
        $info = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
        # Ignore a stale file left by an older process that had this PID.
        $stale = $info.procStart -and [Math]::Abs([long]$info.procStart - $Proc.CreationDate.ToFileTimeUtc()) -gt 50000000
        if (-not $stale) { $r.sessionId = $info.sessionId; $r.cwd = $info.cwd; $r.title = $info.name }
    }
    # Otherwise the ID it was launched with; failing that, --continue picks the
    # most recent conversation in the folder.
    if (-not $r.sessionId -and "$($Proc.CommandLine)" -match '(?:--resume|-r)[= ]+([0-9a-fA-F-]{36})') { $r.sessionId = $Matches[1] }
    if (-not $r.cwd) { $r.cwd = Get-Cwd $Proc.ProcessId }
    if (-not $r.sessionId) { return $r }
    $r.resume = "claude --resume $($r.sessionId)"
    $transcript = Get-ChildItem (Join-Path $HOME '.claude\projects') -Filter "$($r.sessionId).jsonl" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($transcript) {
        $r.lastActive = $transcript.LastWriteTimeUtc.ToString('o')
        $line = Read-TailLines $transcript.FullName | Where-Object { $_ -like '*"type":"last-prompt"*' } | Select-Object -Last 1
        if ($line) { try { $r.lastPrompt = ($line | ConvertFrom-Json).lastPrompt } catch {} }
    }
    $r
}

function Read-CopilotWorkspace([string]$Path) {
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^(cwd|name|summary):\s*(.*)$') { continue }
        $key = $Matches[1]; $value = $Matches[2]
        if ($value -match '^[>|][-+]?$') {
            $folded = $value.StartsWith('>')
            $parts = @()
            while ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match '^  (.*)$') {
                $parts += $Matches[1]; $i++
            }
            $value = $parts -join $(if ($folded) { ' ' } else { "`n" })
        } elseif ($value.StartsWith('"')) {
            try { $value = $value | ConvertFrom-Json }
            catch { Write-Warning "Could not read Copilot workspace field '$key' in ${Path}: $($_.Exception.Message)"; continue }
        } elseif ($value.StartsWith("'") -and $value.EndsWith("'")) {
            $value = $value.Substring(1, $value.Length - 2).Replace("''", "'")
        }
        $result[$key] = $value
    }
    $result
}

function Resolve-Copilot {
    [CmdletBinding()]
    param($Proc)
    $cmd = "$($Proc.CommandLine)"
    if ($Proc.Name -ne 'copilot.exe' -and $cmd -notmatch '[\\/]@github[\\/]copilot[\\/]') { return $null }
    $r = @{ tool = 'copilot'; sessionId = $null; cwd = (Get-Cwd $Proc.ProcessId); title = $null
            resume = 'copilot --resume'; lastPrompt = $null; lastActive = $null }
    $copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
    $stateRoot = Join-Path $copilotHome 'session-state'
    $uuid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $locks = @()
    if (Test-Path -LiteralPath $stateRoot) {
        $locks = @(Get-ChildItem -LiteralPath $stateRoot -Filter "inuse.$($Proc.ProcessId).lock" -Recurse -Depth 1 |
            Where-Object {
                $_.Directory.Name -match "^$uuid$" -and
                (-not $Proc.CreationDate -or $_.LastWriteTimeUtc -ge $Proc.CreationDate.ToUniversalTime())
            })
    }
    # The npm loader is not the native CLI. Never borrow a descendant's locks:
    # an agent can itself launch another Copilot process.
    if ($Proc.Name -ne 'copilot.exe' -and $locks.Count -eq 0) { return $null }
    if ($locks.Count -eq 1) { $r.sessionId = $locks[0].Directory.Name }
    elseif ($locks.Count -gt 1) {
        # Sidebar sessions retain locks. The process log records which one is
        # in the foreground, including switches after --resume was launched.
        $logDir = Join-Path $copilotHome 'logs'
        if ($cmd -match '(?:^|\s)--log-dir(?:=|\s+)(?:"([^"]+)"|(\S+))') {
            $logDir = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
        }
        $log = if (Test-Path -LiteralPath $logDir) {
            Get-ChildItem -LiteralPath $logDir -Filter "process-*-$($Proc.ProcessId).log" |
                Where-Object {
                    $_.Name -match "^process-(\d+)-$($Proc.ProcessId)\.log$" -and
                    (-not $Proc.CreationDate -or
                        [long]$Matches[1] -ge [long](($Proc.CreationDate.ToUniversalTime() - [datetime]'1970-01-01').TotalMilliseconds))
                } | Sort-Object Name -Descending | Select-Object -First 1
        }
        if ($log) {
            $line = Read-LastMatchingLine $log.FullName "\[INFO\] (?:Unregistering|Registering) foreground session: $uuid\s*$"
            if ($line -match "\[INFO\] Registering foreground session: ($uuid)\s*$") {
                $id = $Matches[1]
                if ($locks.Directory.Name -contains $id) { $r.sessionId = $id }
            }
        }
        if (-not $r.sessionId) { Write-Warning "Copilot PID $($Proc.ProcessId) has multiple locked sessions but no confirmed foreground session; restore will open its picker." }
    }
    elseif ($cmd -match "(?:^|\s)(?:--resume|-r|--session-id|--new-session-id)(?:=|\s+)`"?($uuid)`"?(?=\s|$)") {
        $r.sessionId = $Matches[1]
    }
    if ($r.sessionId) {
        $r.resume = "copilot --resume $($r.sessionId)"
        $workspace = Read-CopilotWorkspace (Join-Path $stateRoot "$($r.sessionId)\workspace.yaml")
        if ($workspace.cwd) { $r.cwd = $workspace.cwd }
        $r.title = if ($workspace.name) { $workspace.name } else { $workspace.summary }
        $events = Join-Path $stateRoot "$($r.sessionId)\events.jsonl"
        if (Test-Path -LiteralPath $events) {
            $r.lastActive = (Get-Item -LiteralPath $events).LastWriteTimeUtc.ToString('o')
            $line = Read-LastMatchingLine $events '"type"\s*:\s*"user\.message".*}\s*$'
            if ($line) {
                try { $r.lastPrompt = ($line | ConvertFrom-Json).data.content }
                catch { Write-Warning "Could not read Copilot's last prompt in ${events}: $($_.Exception.Message)" }
            }
        }
    }
    $r
}

# UNVERIFIED and minimal: resumes by ID only when the ID is on the command
# line; otherwise reopens Codex's own session picker in the right folder.
function Resolve-Codex($Proc) {
    $cmd = "$($Proc.CommandLine)"
    if ($Proc.Name -ne 'codex.exe' -and $cmd -notmatch '[\\/]@openai[\\/]codex[\\/]') { return $null }
    if ($cmd -match 'app-server|exec-server') { return $null }
    $r = @{ tool = 'codex'; sessionId = $null; cwd = (Get-Cwd $Proc.ProcessId); title = $null
            resume = 'codex resume'; lastPrompt = $null; lastActive = $null }
    if ($cmd -match 'resume\s+([0-9a-fA-F-]{36})') { $r.sessionId = $Matches[1]; $r.resume = "codex resume $($Matches[1])" }
    $r
}

# --- Capture ----------------------------------------------------------------
function Get-LiveTabs {
    $all = @(Get-CimInstance Win32_Process)
    $byId = @{}
    foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
    $kids = @{}
    foreach ($p in $all) {
        $parent = $byId[[int]$p.ParentProcessId]
        # A parent created after its "child" is a recycled PID, not a parent.
        if ($parent -and $parent.CreationDate -and $p.CreationDate -and $parent.CreationDate -le $p.CreationDate) {
            if (-not $kids.ContainsKey([int]$parent.ProcessId)) { $kids[[int]$parent.ProcessId] = New-Object Collections.ArrayList }
            [void]$kids[[int]$parent.ProcessId].Add($p)
        }
    }
    $roots = foreach ($t in ($all | Where-Object { $TerminalHosts -contains $_.Name })) {
        $kids[[int]$t.ProcessId] | Where-Object { $_ -and $TerminalHelpers -notcontains $_.Name }
    }
    $tabs = New-Object Collections.ArrayList
    foreach ($root in ($roots | Sort-Object CreationDate)) {
        # Breadth-first: the root shell, then whatever is running under it.
        $tree = New-Object Collections.ArrayList
        $queue = New-Object Collections.Queue
        $queue.Enqueue($root)
        while ($queue.Count) {
            $p = $queue.Dequeue(); [void]$tree.Add($p)
            foreach ($k in @($kids[[int]$p.ProcessId])) { if ($k) { $queue.Enqueue($k) } }
        }
        $found = $null
        foreach ($p in $tree) {
            try {
                $found = Resolve-Claude $p
                if (-not $found) { $found = Resolve-Copilot $p }
                if (-not $found) { $found = Resolve-Codex $p }
            } catch { Write-Warning "Could not inspect $($p.Name) PID $($p.ProcessId): $($_.Exception.Message)"; $found = $null }
            if ($found) { break }
        }
        $tab = [ordered]@{
            order = $tabs.Count; shell = $root.Name; cwd = $null; tool = $null; sessionId = $null
            title = $null; resume = $null; wasRunning = $null; lastPrompt = $null; lastActive = $null
        }
        if ($found) {
            foreach ($k in 'tool', 'sessionId', 'cwd', 'title', 'resume', 'lastPrompt', 'lastActive') { $tab[$k] = $found[$k] }
        } else {
            $child = @($kids[[int]$root.ProcessId]) | Where-Object { $_ -and $TerminalHelpers -notcontains $_.Name } |
                Sort-Object CreationDate | Select-Object -Last 1
            if ($child) { $tab.wasRunning = $child.CommandLine; $tab.cwd = Get-Cwd $child.ProcessId }
        }
        if (-not $tab.cwd) { $tab.cwd = Get-Cwd $root.ProcessId }
        if ($tab.lastPrompt -and $tab.lastPrompt.Length -gt 500) { $tab.lastPrompt = $tab.lastPrompt.Substring(0, 500) }
        [void]$tabs.Add([pscustomobject]$tab)
    }
    @($tabs)
}

function Save-Snapshot {
    $tabs = @(Get-LiveTabs)
    # Never record "nothing open": that is exactly the state right after a restart.
    if ($tabs.Count -eq 0) { return $null }
    New-Item -ItemType Directory -Force $HistoryDir | Out-Null
    $snap = [ordered]@{
        version = 1; takenAt = (Get-Date).ToUniversalTime().ToString('o'); epoch = (Get-Epoch)
        os = 'windows'; terminal = 'windows-terminal'; tabs = @($tabs)
    }
    $prev = if (Test-Path $LastFile) { Read-Snapshot $LastFile }
    if ($prev) {
        $old = (@($prev.tabs) | ForEach-Object { Get-TabKey $_ } | Sort-Object) -join "`n"
        $new = (@($tabs) | ForEach-Object { Get-TabKey $_ } | Sort-Object) -join "`n"
        if ($old -ne $new -or $prev.epoch -ne $snap.epoch) {
            Copy-Item -LiteralPath $LastFile -Destination (Join-Path $HistoryDir ($prev.when.ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '.json')) -Force
            Get-ChildItem $HistoryDir -Filter *.json | Sort-Object Name -Descending | Select-Object -Skip $HistoryKeep | Remove-Item -Force
        }
    }
    Write-Json $LastFile $snap
    $snap
}

# --- Choosing what to restore ------------------------------------------------
function Get-AllSnapshots {
    $files = @()
    if (Test-Path $HistoryDir) { $files += @(Get-ChildItem $HistoryDir -Filter *.json | ForEach-Object FullName) }
    if (Test-Path $LastFile) { $files += $LastFile }
    @($files | ForEach-Object { Read-Snapshot $_ } | Where-Object { $_ } | Sort-Object when)
}

function Select-Snapshot {
    $all = Get-AllSnapshots
    if ($all.Count -eq 0) { return $null }
    if ($Index -ge 0) {
        $newestFirst = @($all | Sort-Object when -Descending)
        if ($Index -ge $newestFirst.Count) { throw "No snapshot #$Index (there are $($newestFirst.Count))." }
        return $newestFirst[$Index]
    }
    $epoch = Get-Epoch
    $restoredIn = if (Test-Path $MarkerFile) { (Get-Content $MarkerFile -Raw).Trim() }
    $earlier = @($all | Where-Object { $_.epoch -ne $epoch })
    # First restore after a restart: go back to how the last login ended, even
    # if a tab or two has already been opened (and snapshotted) since.
    $pool = if ($earlier.Count -and $restoredIn -ne $epoch) { @($all | Where-Object { $_.epoch -eq $earlier[-1].epoch }) }
            else { @($all | Where-Object { $_.epoch -eq $all[-1].epoch }) }
    $pick = $pool[-1]
    # Shutdown closes tabs one by one, so the final snapshot may have caught
    # only some of them. Prefer a fuller one from the few minutes before it.
    $pickKeys = @($pick.tabs | ForEach-Object { Get-TabKey $_ })
    foreach ($c in $pool) {
        if ($c.when -lt $pick.when.AddMinutes(-3) -or @($c.tabs).Count -le @($pick.tabs).Count) { continue }
        $cKeys = @($c.tabs | ForEach-Object { Get-TabKey $_ })
        if (-not ($pickKeys | Where-Object { $cKeys -notcontains $_ })) { $pick = $c }
    }
    $pick
}

# --- Output -----------------------------------------------------------------
function Show-Snapshot($Snap) {
    $n = @($Snap.tabs).Count
    Write-Host ''
    Write-Host ("  {0} tab{1}, recorded {2}" -f $n, $(if ($n -ne 1) { 's' }), (Format-Ago $Snap.when)) -ForegroundColor Cyan
    Write-Host ''
    $i = 1
    foreach ($t in @($Snap.tabs)) {
        $label = if ($t.tool) { $t.tool } else { 'shell' }
        Write-Host ("  {0,2}. " -f $i) -NoNewline
        Write-Host ("{0,-8}" -f $label) -ForegroundColor $(if ($t.tool) { 'Green' } else { 'DarkGray' }) -NoNewline
        Write-Host $t.cwd -NoNewline
        if ($t.lastActive) { Write-Host ("   ({0})" -f (Format-Ago $t.lastActive)) -ForegroundColor DarkGray -NoNewline }
        Write-Host ''
        if ($t.title) { Write-Host "              $($t.title)" -ForegroundColor Yellow }
        if ($t.lastPrompt) {
            $p = ($t.lastPrompt -replace '\s+', ' ').Trim()
            if ($p.Length -gt 100) { $p = $p.Substring(0, 100) + '...' }
            Write-Host "              you: $p" -ForegroundColor Gray
        }
        if (-not $t.tool -and $t.wasRunning) { Write-Host "              was running: $($t.wasRunning)" -ForegroundColor DarkGray }
        if ($t.tool -and -not $t.sessionId) { Write-Host '              session not identified; will open the session picker' -ForegroundColor DarkYellow }
        $i++
    }
    Write-Host ''
}

# --- Terminal adapter (restore side): Windows Terminal -----------------------
function Get-RestoreCommand($Tab) {
    if ($Tab.tool -isnot [string]) { return }
    switch -Exact ($Tab.tool) {
        'claude'  { $command = if ($Tab.sessionId) { 'claude --resume' } else { 'claude --continue' } }
        'copilot' { $command = 'copilot --resume' }
        'codex'   { $command = 'codex resume' }
        default   { return }
    }
    if (-not $Tab.sessionId) { return $command }
    if ($Tab.sessionId -isnot [string] -or $Tab.sessionId -notmatch '\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z') {
        throw "Invalid session ID for $($Tab.tool)."
    }
    "$command $($Tab.sessionId)"
}

function ConvertTo-WtTab($Tab) {
    $cwd = if ($Tab.cwd -and (Test-Path -LiteralPath $Tab.cwd)) { $Tab.cwd } else { $HOME }
    if ($cwd.EndsWith('\')) { $cwd += '.' }   # a trailing backslash would escape the closing quote
    $title = if ($Tab.title) { $Tab.title } else { Split-Path $cwd -Leaf }
    $title = $title -replace '["'';]', ''
    $resume = Get-RestoreCommand $Tab
    $script = $resume
    if (-not $script -and $Tab.wasRunning) {
        $message = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("same-sesh: this tab was running: $($Tab.wasRunning)"))
        # Only the base64 data goes into the fixed script. The decoded text is never parsed.
        $script = "Write-Host ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$message'))) -ForegroundColor DarkGray"
    }
    $shell = if ($Tab.shell -in 'powershell.exe', 'pwsh.exe', 'cmd.exe') { $Tab.shell } else { 'powershell.exe' }
    $run = if ($shell -eq 'cmd.exe') {
               if ($resume) { "cmd.exe /k $resume" }
               elseif ($script) { 'cmd.exe /k powershell.exe -NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script)) }
               else { 'cmd.exe' }
           }
           elseif ($script) {
               # Encoded so that nothing in the command can be re-split by wt or the shell.
               "$shell -NoExit -EncodedCommand " + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
           } else { $shell }
    "new-tab --title `"$title`" -d `"$cwd`" $run"
}

function Restore-Snapshot {
    $snap = Select-Snapshot
    if (-not $snap) { Write-Host 'No snapshot yet. Run: same-sesh snapshot' -ForegroundColor Yellow; return }
    $live = @(Get-LiveTabs)
    $liveSessions = @($live | Where-Object sessionId | ForEach-Object { "$($_.tool)|$($_.sessionId)" })
    $liveShellDirs = @($live | Where-Object { -not $_.tool } | ForEach-Object cwd)
    $todo = @($snap.tabs | Where-Object {
        if ($_.sessionId) { $liveSessions -notcontains "$($_.tool)|$($_.sessionId)" }
        elseif ($_.tool) { $true }
        else { $liveShellDirs -notcontains $_.cwd }
    })
    Show-Snapshot $snap
    $skipped = @($snap.tabs).Count - $todo.Count
    if ($skipped) { Write-Host "  $skipped already open, skipping." -ForegroundColor DarkGray }
    if ($todo.Count -eq 0) { Write-Host '  Nothing to reopen.'; return }
    $wtArgs = '-w 0 ' + (($todo | ForEach-Object { ConvertTo-WtTab $_ }) -join ' ; ')
    if ($DryRun) { Write-Host "  Would run:`n  wt $wtArgs"; return }
    Start-Process wt.exe -ArgumentList $wtArgs
    New-Item -ItemType Directory -Force $StateDir | Out-Null
    Set-Content -LiteralPath $MarkerFile -Value (Get-Epoch) -Encoding ASCII
    Write-Host "  Reopened $($todo.Count) tab$(if ($todo.Count -ne 1) { 's' })." -ForegroundColor Green
}

# --- Commands ---------------------------------------------------------------
switch ($Command) {
    'help' { Get-Content -LiteralPath $PSCommandPath -TotalCount 14 | Select-Object -Skip 1 | Write-Host }
    'snapshot' {
        $s = Save-Snapshot
        if ($s) { Show-Snapshot (Read-Snapshot $LastFile) } else { Write-Host 'No terminal tabs open; nothing recorded.' -ForegroundColor Yellow }
    }
    'list' {
        $s = Select-Snapshot
        if ($s) { Show-Snapshot $s; Write-Host '  Reopen these with: same-sesh restore' -ForegroundColor DarkGray }
        else { Write-Host 'No snapshot yet. Run: same-sesh snapshot' -ForegroundColor Yellow }
    }
    'history' {
        $i = 0
        foreach ($s in (Get-AllSnapshots | Sort-Object when -Descending)) {
            $tools = (@($s.tabs) | Group-Object { if ($_.tool) { $_.tool } else { 'shell' } } | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
            Write-Host ("  #{0,-3} {1,-10} {2}   {3}" -f $i, (Format-Ago $s.when), $s.when.ToLocalTime().ToString('ddd HH:mm'), $tools)
            $i++
        }
        Write-Host '  Restore one with: same-sesh restore -Index N' -ForegroundColor DarkGray
    }
    'restore' { Restore-Snapshot }
    'watch' {
        $created = $false
        $mutex = New-Object Threading.Mutex($true, 'Local\same-sesh-watch', [ref]$created)
        if (-not $created) { Write-Host 'A watcher is already running.'; return }
        try {
            New-Item -ItemType Directory -Force $StateDir | Out-Null
            $logFile = Join-Path $StateDir 'watch.log'
            $lastError = $null
            while ($true) {
                try { [void](Save-Snapshot); $lastError = $null }
                catch {
                    # Log an error when it starts, not on every cycle it persists.
                    $message = $_.Exception.Message
                    if ($message -ne $lastError) {
                        if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -gt 262144) {
                            Set-Content -LiteralPath $logFile -Value (Get-Content -LiteralPath $logFile -Tail 200)
                        }
                        Add-Content -LiteralPath $logFile -Value ("{0:o} {1}" -f (Get-Date), $message)
                        $lastError = $message
                    }
                }
                Start-Sleep -Seconds $IntervalSeconds
            }
        }
        finally { $mutex.ReleaseMutex() }
    }
    'install' {
        # conhost --headless keeps the watcher from flashing a console window at login.
        $cmd = "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" watch"
        Set-ItemProperty -Path $RunKey -Name 'same-sesh' -Value $cmd
        Start-Process conhost.exe -ArgumentList "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" watch"
        Write-Host 'Watcher started, and it will start again at every login.' -ForegroundColor Green
    }
    'uninstall' {
        Remove-ItemProperty -Path $RunKey -Name 'same-sesh' -ErrorAction SilentlyContinue
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -like "*same-sesh.ps1*watch*" -and $_.ProcessId -ne $PID } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Write-Host 'Watcher stopped and removed from login. Snapshots are kept in' $StateDir
    }
}

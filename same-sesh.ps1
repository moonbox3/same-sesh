# Existing Windows login entries may still point to this checkout path.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'snapshot', 'restore', 'history', 'status', 'watch', 'install', 'uninstall', 'help')]
    [string]$Command = 'list',
    [int]$Index = -1,
    [switch]$DryRun,
    [int]$IntervalSeconds = 30,
    [string]$Name,
    [switch]$Yes
)

& "$PSScriptRoot\windows\same-sesh.ps1" @PSBoundParameters

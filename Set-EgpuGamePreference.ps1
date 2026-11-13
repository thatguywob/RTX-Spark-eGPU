#requires -Version 5.1
<#
.SYNOPSIS
Prefer the external NVIDIA GPU for one game or application.
.DESCRIPTION
Sets SpecificAdapter=<VEN>&<DEV>&<SUBSYS> in the per-user Windows graphics preference
(HKCU\Software\Microsoft\DirectX\UserGpuPreferences) for the given executable. Other
settings in that value, such as SingleAdapterHybridMode, are preserved; GpuPreference
is added only when missing. The existing key is exported to
%LOCALAPPDATA%\SparkEgpu\Backups before any change. No administrator rights needed.

After binding, the eGPU also shows as "NVIDIA RTX Spark N1X", so Windows Settings
cannot tell the two GPUs apart by name; this sets the adapter by hardware ID instead.
.EXAMPLE
.\Set-EgpuGamePreference.ps1 -ExePath 'C:\Games\Cyberpunk 2077\bin\x64\Cyberpunk2077.exe' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ExePath,
    [string]$InstanceId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SparkEgpu.psm1') -Force

if ($InstanceId) { $device = Get-DeviceState $InstanceId }
else {
    $externals = @(Get-ExternalGpu (Get-InternalSpark))
    if ($externals.Count -ne 1) {
        throw "Specify -InstanceId. External NVIDIA GPUs present: $(($externals | ForEach-Object { $_.InstanceId }) -join '; ')"
    }
    $device = $externals[0]
}
$match = [regex]::Match([string]@($device.HardwareIds)[0], '^PCI\\VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})&SUBSYS_([0-9A-F]{8})', 'IgnoreCase')
if (-not $match.Success) { throw "Cannot parse hardware ID of $($device.InstanceId)." }
$adapter = ($match.Groups[1].Value + '&' + $match.Groups[2].Value + '&' + $match.Groups[3].Value).ToUpperInvariant()

$exe = (Resolve-Path -LiteralPath $ExePath).ProviderPath
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Not a file: $exe" }

$key = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$old = ''
if (Test-Path -LiteralPath $key) {
    $item = Get-Item -LiteralPath $key
    if ($item.GetValueNames() -contains $exe) { $old = [string]$item.GetValue($exe) }
}

$pairs = New-Object System.Collections.Generic.List[string]
foreach ($part in $old -split ';') { if ($part) { $pairs.Add($part) } }
$names = @($pairs | ForEach-Object { ($_ -split '=', 2)[0] })
$index = [array]::IndexOf([string[]]$names, 'SpecificAdapter')
if ($index -ge 0) { $pairs[$index] = "SpecificAdapter=$adapter" } else { $pairs.Add("SpecificAdapter=$adapter") }
if ($names -notcontains 'GpuPreference') { $pairs.Add('GpuPreference=1073741824') }
$new = ($pairs | ForEach-Object { "$_;" }) -join ''

Write-Host "Executable: $exe"
Write-Host "Old value:  $old"
Write-Host "New value:  $new"
if ($PSCmdlet.ShouldProcess($exe, "Set SpecificAdapter=$adapter")) {
    if (Test-Path -LiteralPath $key) {
        $backups = Join-Path $env:LOCALAPPDATA 'SparkEgpu\Backups'
        [IO.Directory]::CreateDirectory($backups) | Out-Null
        $backup = Join-Path $backups ('UserGpuPreferences-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.reg')
        & "$env:SystemRoot\System32\reg.exe" export 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences' $backup /y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Registry export failed: $backup" }
        Write-Host "Backup: $backup"
    } else { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -LiteralPath $key -Name $exe -PropertyType String -Value $new -Force | Out-Null
    Write-Host 'Fully exit and relaunch the game. This sets the Windows preference; it does not prove which GPU the game uses.'
}

#requires -Version 5.1
<#
.SYNOPSIS
Install or remove the scheduled task that configures an external NVIDIA GPU on connect.
.DESCRIPTION
Copies Configure-SparkEgpu.ps1 and SparkEgpu.psm1 to %ProgramFiles%\SparkEgpu
(administrators-only write) and registers \SparkEgpu\SparkEgpu. The task fires on
Kernel-PnP configuration events 400/411 (device configured / problem starting).

  -Trigger Automatic  Runs as SYSTEM at boot and on connect. Binds without asking.
                      Requires -AcceptUnsupportedBinding. Log: %ProgramData%\SparkEgpu\Logs
  -Trigger Prompt     Runs as the current user at logon and on connect. Shows a
                      dialog, then asks for administrator approval (UAC).
                      Log: %LOCALAPPDATA%\SparkEgpu\Logs plus %ProgramData%\SparkEgpu\Logs

Re-running with the other -Trigger replaces the task. Re-run after editing the
scripts to refresh the installed copy. -Uninstall removes the task and the copy;
backups and logs are kept.
.EXAMPLE
.\Install-SparkEgpuAutomation.ps1 -Trigger Prompt
.EXAMPLE
.\Install-SparkEgpuAutomation.ps1 -Trigger Automatic -AcceptUnsupportedBinding
.EXAMPLE
.\Install-SparkEgpuAutomation.ps1 -Uninstall
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Install')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Install')][ValidateSet('Automatic', 'Prompt')][string]$Trigger,
    [Parameter(ParameterSetName = 'Install')][switch]$AcceptUnsupportedBinding,
    [Parameter(Mandatory, ParameterSetName = 'Uninstall')][switch]$Uninstall
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'Arm64') {
    throw 'Run this script in native ARM64 PowerShell.'
}
Import-Module (Join-Path $PSScriptRoot 'SparkEgpu.psm1') -Force

$installDir = Join-Path $env:ProgramFiles 'SparkEgpu'
$files = 'Configure-SparkEgpu.ps1', 'SparkEgpu.psm1'
$taskPath = '\SparkEgpu\'
$taskName = 'SparkEgpu'
$exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

if ($PSCmdlet.ParameterSetName -eq 'Uninstall') {
    if ($PSCmdlet.ShouldProcess("$taskPath$taskName", 'Remove automation task and installed scripts')) {
        Assert-Administrator
        if (Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false
        }
        if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }
        Write-Host "Backups and logs kept in $env:ProgramData\SparkEgpu."
    }
    return
}

if ($Trigger -eq 'Automatic' -and -not $AcceptUnsupportedBinding) {
    throw 'Automatic mode binds an unsupported driver without asking. Review README.md, then pass -AcceptUnsupportedBinding.'
}
function Escape([string]$Text) { [Security.SecurityElement]::Escape($Text) }
$script = Join-Path $installDir 'Configure-SparkEgpu.ps1'
# Display class only: dock USB/HID devices otherwise queue one run per event.
$query = '<QueryList><Query Id="0" Path="Microsoft-Windows-Kernel-PnP/Configuration"><Select Path="Microsoft-Windows-Kernel-PnP/Configuration">*[System[(EventID=400 or EventID=411)]] and *[EventData[Data[@Name=''ClassGuid'']=''{4d36e968-e325-11ce-bfc1-08002be10318}'']]</Select></Query></QueryList>'
if ($Trigger -eq 'Automatic') {
    $extraTrigger = '<BootTrigger><Delay>PT1M</Delay></BootTrigger>'
    $principal = '<UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel>'
    $policy = 'Queue' # Events arriving mid-run must still be processed.
    $limit = 'PT15M'
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Mode Auto -AcceptUnsupportedBinding"
    $log = "$env:ProgramData\SparkEgpu\Logs"
} else {
    # Fires on any logon; the principal limits it to this user.
    $extraTrigger = '<LogonTrigger><Delay>PT30S</Delay></LogonTrigger>'
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $principal = "<UserId>$(Escape $sid)</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel>"
    $policy = 'IgnoreNew' # One dialog per burst of connect events.
    $limit = 'PT1H'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Mode Prompt"
    $log = "$env:LOCALAPPDATA\SparkEgpu\Logs and $env:ProgramData\SparkEgpu\Logs"
}
$xml = @"
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$(Escape "Spark eGPU: bind RTX Spark driver to external NVIDIA GPU on connect ($Trigger).")</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>$(Escape $query)</Subscription>
      <Delay>PT5S</Delay>
    </EventTrigger>
    $extraTrigger
  </Triggers>
  <Principals>
    <Principal id="Author">$principal</Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>$policy</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>$limit</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(Escape $exe)</Command>
      <Arguments>$(Escape $arguments)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
[xml]$xml | Out-Null
if ($WhatIfPreference) { Write-Host $xml }

if ($PSCmdlet.ShouldProcess("$taskPath$taskName", "Install $Trigger automation")) {
    Assert-Administrator
    [IO.Directory]::CreateDirectory($installDir) | Out-Null
    # Program Files inherits administrators-only write: the task never runs a user-writable script.
    foreach ($file in $files) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $installDir -Force }
    Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Xml $xml -Force | Out-Null
    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName
    Write-Host "Task $taskPath$taskName ($Trigger): $($task.State)"
    Write-Host "Reconnect the eGPU, or run: Start-ScheduledTask -TaskPath '$taskPath' -TaskName $taskName"
    Write-Host "Logs: $log"
}

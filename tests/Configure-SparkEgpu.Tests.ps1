# Run in a fresh process: powershell -NoProfile -ExecutionPolicy Bypass -File tests\Configure-SparkEgpu.Tests.ps1
# No hardware or registry writes. Exercise the real configuration flow and JSON history
# with simulated device/SetupAPI boundaries; keep every file in an isolated temp folder.
#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ('SparkEgpu.Binding' -as [type]) { throw 'Run these tests in a fresh PowerShell process.' }
Add-Type -TypeDefinition @'
namespace SparkEgpu {
    public static class Binding {
        public static bool Fail, Reboot;
        public static int Calls;
        public static Result Install(string id, string inf, int index, string hardware, string section) {
            Calls++;
            if (Fail) throw new System.InvalidOperationException("SetupAPI rejected install");
            return new Result { NeedReboot = Reboot };
        }
    }
    public sealed class Result { public bool NeedReboot; }
}
'@
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'Configure-SparkEgpu.ps1'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$errors)
if ($errors.Count) { throw $errors[0] }
$names = 'Invoke-Configure', 'Get-PendingAction', 'Get-HistoryKey', 'Get-RestartKey', 'Read-BindHistory', 'Write-BindHistory', 'Save-State', 'Show-Item'
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($node.Name -in $names) { . ([scriptblock]::Create($node.Extent.Text)) }
}
function Assert-Equal($Actual, $Expected, [string]$Context) {
    if ($Actual -ne $Expected) { throw "${Context}: expected '$Expected', got '$Actual'" }
}
function Assert-Administrator {}
function Initialize-DataRoot {}
function Assert-Identity($Device, $Internal) {}
function Start-Sleep([int]$Seconds) {}
function Get-CimInstance([string]$ClassName) { [pscustomobject]@{ DeviceID = 'internal'; IsSigned = $true } }
function Select-SparkModel([string]$Id, $Internal) {
    [pscustomobject]@{ Inf = 'oem41.inf'; Index = 2; HardwareId = 'model'; Section = 'Section006' }
}
function Get-DeviceState([string]$Id) { $script:bound }
function Get-NvidiaSiblingHealth([string]$ExcludeInstanceId) {
    $script:healthCalls++
    if ($script:healthCalls -eq 1) { return $script:before }
    $script:after
}
function Test-NvidiaSmi($Device) {
    $script:smiCalls++
    if ($script:smiFail) { throw 'NVIDIA enumeration failed' }
}
function Get-BootId { $script:bootId }
function Get-Override($Device) { [pscustomobject]@{ Exists = $true; Value = 1 } }
function Assert-OwnedDriverKey($Device) {}
function Export-DeviceKey($Device, [string]$File) {}
function Invoke-DeviceCommand([string]$Command, [string]$Id) { $script:restartCalls++; $script:bound = $script:afterRestart }
$root = Join-Path ([IO.Path]::GetTempPath()) ('SparkEgpu-tests-' + [guid]::NewGuid().ToString('N'))
$backupRoot = Join-Path $root 'Backups'
$historyFile = Join-Path $root 'history.json'
[IO.Directory]::CreateDirectory($backupRoot) | Out-Null
$internal = [pscustomobject]@{ InstanceId = 'internal'; Inf = 'oem41.inf'; Version = '32.0.16.2114'; ProblemCode = 0 }
$target = [pscustomobject]@{ InstanceId = 'external'; Inf = 'display.inf'; Provider = 'Microsoft'; Version = '10.0'; ProblemCode = 10; DriverKey = $null }
$bound = [pscustomobject]@{ InstanceId = 'external'; Inf = 'oem41.inf'; Provider = 'NVIDIA'; Version = '32.0.16.2114'; ProblemCode = 0 }
$before = @{ 'ACPI\NVDA200A\0' = [pscustomobject]@{ ProblemCode = 0; Inf = 'oem41.inf' } }
$bootId = 'boot-1'
$cases = @(
    @{ Name = 'install failure'; Result = 'Failed'; Fail = $true; Message = 'SetupAPI rejected install'; SmiCalls = 0 },
    @{ Name = 'reboot required'; Result = 'RebootRequired'; Reboot = $true; Message = 'Windows requires a reboot'; SmiCalls = 0 },
    @{ Name = 'missing sibling'; Result = 'VerificationFailed'; After = @{}; Message = 'ACPI\NVDA200A\0: device missing (before: Code 0, INF oem41.inf)'; SmiCalls = 0 },
    @{ Name = 'sibling problem'; Result = 'VerificationFailed'; After = @{ 'ACPI\NVDA200A\0' = [pscustomobject]@{ ProblemCode = 43; Inf = 'oem41.inf' } }; Message = 'Code 0 -> 43'; SmiCalls = 0 },
    @{ Name = 'sibling package changed'; Result = 'VerificationFailed'; After = @{ 'ACPI\NVDA200A\0' = [pscustomobject]@{ ProblemCode = 0; Inf = 'oem80.inf' } }; Message = 'INF oem41.inf -> oem80.inf'; SmiCalls = 0 },
    @{ Name = 'NVIDIA enumeration failure'; Result = 'VerificationFailed'; SmiFail = $true; Message = 'NVIDIA enumeration failed'; SmiCalls = 1 },
    @{ Name = 'verified binding'; Result = 'Succeeded'; SmiCalls = 1 }
)
try {
    foreach ($case in $cases) {
        [SparkEgpu.Binding]::Fail = $case['Fail'] -eq $true
        [SparkEgpu.Binding]::Reboot = $case['Reboot'] -eq $true
        [SparkEgpu.Binding]::Calls = 0
        $healthCalls = 0
        $smiCalls = 0
        $smiFail = $case['SmiFail'] -eq $true
        $after = if ($case.ContainsKey('After')) { $case['After'] } else { $before }
        $errorText = ''
        try { Invoke-Configure $target $internal 'Auto' @() *> $null } catch { $errorText = $_.Exception.Message }
        if ($case.ContainsKey('Message')) {
            if (-not $errorText.Contains($case['Message'])) { throw "$($case.Name): unexpected error '$errorText'" }
        } elseif ($errorText) { throw "$($case.Name): $errorText" }
        $history = @(Read-BindHistory)
        Assert-Equal $history.Count 1 "$($case.Name) history cardinality"
        Assert-Equal $history[0].Result $case.Result "$($case.Name) outcome"
        Assert-Equal $history[0].Key (Get-HistoryKey $target $internal) "$($case.Name) device/package key"
        Assert-Equal $smiCalls $case.SmiCalls "$($case.Name) verification ordering"
        Assert-Equal ([SparkEgpu.Binding]::Calls) 1 "$($case.Name) install count"
        Assert-Equal (Get-PendingAction $target $internal $history).Action 'None' "$($case.Name) prevents automatic retry"
        $updated = [pscustomobject]@{ InstanceId = 'internal'; Inf = 'oem99.inf'; Version = '32.0.16.2200' }
        Assert-Equal (Get-PendingAction $target $updated $history).Action 'Bind' "$($case.Name) permits new package"
        Write-Host "PASS: $($case.Name)"
    }
    Remove-Item -LiteralPath $historyFile -Force

    $code43 = [pscustomobject]@{ InstanceId = 'external'; Inf = 'oem41.inf'; Provider = 'NVIDIA'; Version = '32.0.16.2114'; ProblemCode = 43; DriverKey = '{4d36e968-e325-11ce-bfc1-08002be10318}\0012' }
    $restarted = [pscustomobject]@{ InstanceId = 'external'; Inf = 'oem41.inf'; Provider = 'NVIDIA'; Version = '32.0.16.2114'; ProblemCode = 0; DriverKey = '{4d36e968-e325-11ce-bfc1-08002be10318}\0012' }

    $restartCalls = 0; $healthCalls = 0; $smiCalls = 0; $smiFail = $false; $after = $before
    $bound = $code43
    $afterRestart = $restarted
    Assert-Equal (Get-PendingAction $code43 $internal @()).Action 'Restart' 'restart once per boot initial action'
    Invoke-Configure $code43 $internal 'Auto' @() *> $null
    Assert-Equal $restartCalls 1 'restart once per boot restart count'
    $history = @(Read-BindHistory)
    Assert-Equal $history.Count 1 'restart once per boot history cardinality'
    Assert-Equal $history[0].Key 'external|restart|boot-1' 'restart once per boot key'
    Assert-Equal $history[0].Result 'Succeeded' 'restart once per boot outcome'
    Assert-Equal (Get-PendingAction $code43 $internal $history).Action 'None' 'restart once per boot prevents second restart'
    $bootId = 'boot-2'
    Assert-Equal (Get-PendingAction $code43 $internal $history).Action 'Restart' 'restart once per boot permits next boot'
    Write-Host 'PASS: restart once per boot'

    Remove-Item -LiteralPath $historyFile -Force
    $bootId = 'boot-1'
    $restartCalls = 0; $healthCalls = 0; $smiCalls = 0; $smiFail = $false; $after = $before
    $bound = $code43
    $afterRestart = $code43
    $errorText = ''
    try { Invoke-Configure $code43 $internal 'Auto' @() *> $null } catch { $errorText = $_.Exception.Message }
    if (-not $errorText.Contains('still reports Code 43')) { throw "restart fails: unexpected error '$errorText'" }
    $history = @(Read-BindHistory)
    Assert-Equal $history.Count 1 'restart fails history cardinality'
    Assert-Equal $history[0].Result 'Failed' 'restart fails outcome'
    Assert-Equal $restartCalls 1 'restart fails restart count'
    Assert-Equal $smiCalls 0 'restart fails verification ordering'
    Write-Host 'PASS: restart fails'

    $disabled = [pscustomobject]@{ InstanceId = 'external'; Inf = 'display.inf'; Provider = 'Microsoft'; Version = '10.0'; ProblemCode = 22; DriverKey = $null }
    $action = Get-PendingAction $disabled $internal @()
    Assert-Equal $action.Action 'None' 'disabled device not bound action'
    if (-not $action.Reason.Contains('Code 22')) { throw "disabled device not bound: unexpected reason '$($action.Reason)'" }
    Write-Host 'PASS: disabled device not bound'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}

#requires -Version 5.1
<#
.SYNOPSIS
Inspect, configure, or restore an external NVIDIA GPU on an ARM64 RTX Spark laptop.
.DESCRIPTION
Binds the internal RTX Spark's already-installed signed ARM64 NVIDIA driver to an
external NVIDIA PCI display device (eGPU) with SetupAPI, the same explicit model
selection as "Have Disk". If the device then reports Code 43, RM1774520 is set to
DWORD 1 in its driver key and the device is restarted. Acts on any present NVIDIA
PCI display device that is not the internal Spark. This is an unsupported binding:
a crash or display interruption is possible. Shut down Windows before unplugging
the eGPU or powering off its enclosure. No security settings are changed.
No downloads, driver removal, INF edits, or automatic reboot.

Modes:
  Inspect  (default) Read-only. Shows the internal Spark, each external NVIDIA GPU,
           the Spark model that would be bound, and the pending action.
  Install  Manual configuration of one external GPU. Requires an elevated shell and
           -AcceptUnsupportedBinding. Supports -WhatIf.
  Restore  Rebinds the driver saved in a backup's state.json and restores the
           RM1774520 value it recorded. Supports -WhatIf.
  Auto     Unattended configuration of every external GPU that needs it. Used by
           the Automatic scheduled task and by Prompt's elevated child.
  Prompt   Non-elevated. Asks the logged-on user, then runs Auto through UAC.
  Restart  Restarts one external GPU (pnputil /restart-device), then verifies it. Supports -WhatIf.
  Stop     Disables one external GPU until -Mode Start; automation leaves it alone. Supports -WhatIf.
  Start    Re-enables a stopped external GPU, then verifies it. Supports -WhatIf.

Scheduling lives in Install-SparkEgpuAutomation.ps1. This script never elevates
itself except in Prompt mode, and only after the user agrees.

Data lives in %ProgramData%\SparkEgpu (administrators-only write):
  Backups\<run>\state.json  recovery state plus registry exports per change
  Logs\auto-<date>.log      Auto mode transcripts
  bind-history.json         one automatic bind per device and driver package
Restore only accepts backups from that folder.

Source: https://forum.level1techs.com/t/rtx-egpus-working-on-rtx-spark-hp-omnibook/259662
API: https://learn.microsoft.com/windows/win32/api/newdev/nf-newdev-diinstalldevice
.EXAMPLE
.\Configure-SparkEgpu.ps1
.EXAMPLE
.\Configure-SparkEgpu.ps1 -Mode Install -WhatIf
.EXAMPLE
.\Configure-SparkEgpu.ps1 -Mode Install -AcceptUnsupportedBinding
.EXAMPLE
.\Configure-SparkEgpu.ps1 -Mode Install -InstanceId 'PCI\VEN_10DE&DEV_2204&...' -AcceptUnsupportedBinding
.EXAMPLE
.\Configure-SparkEgpu.ps1 -Mode Restore -BackupPath "$env:ProgramData\SparkEgpu\Backups\<run>\state.json" -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Inspect', 'Install', 'Restore', 'Auto', 'Prompt', 'Restart', 'Stop', 'Start')][string]$Mode = 'Inspect',
    [string]$InstanceId,
    [string]$BackupPath,
    [switch]$AcceptUnsupportedBinding
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'Arm64') {
    throw 'Run this script in native ARM64 PowerShell.'
}
$displayClass = '{4d36e968-e325-11ce-bfc1-08002be10318}'
$overrideName = 'RM1774520'
$dataRoot = Join-Path $env:ProgramData 'SparkEgpu'
$backupRoot = Join-Path $dataRoot 'Backups'
$logRoot = Join-Path $dataRoot 'Logs'
$historyFile = Join-Path $dataRoot 'bind-history.json'
$powershellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

# Class-driver enumeration allows the same explicit model selection as Have Disk.
# The helper never updates devices by hardware-ID wildcard. It opens one instance.
if (-not ('SparkEgpu.Binding' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace SparkEgpu {
    // Start a new PowerShell session after editing this type.
    public sealed class Selection {
        public string Description, Provider, HardwareId, Section, Inf, VersionText;
        public ulong Version;
        public int Index;
        public bool NeedReboot;
    }
    public static class Binding {
        [StructLayout(LayoutKind.Sequential)] struct Device {
            public uint Size; public Guid ClassGuid; public uint DevInst; public UIntPtr Reserved;
        }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Parameters {
            public uint Size, Flags, FlagsEx;
            public IntPtr Parent, Callback, Context, Queue; public UIntPtr ClassReserved;
            public uint Reserved;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string Path;
        }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Driver {
            public uint Size, Type; public UIntPtr Reserved;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string Description;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string Manufacturer;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string Provider;
            public System.Runtime.InteropServices.ComTypes.FILETIME Date;
            public ulong Version;
        }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Detail {
            public uint Size; public System.Runtime.InteropServices.ComTypes.FILETIME Date;
            public uint CompatOffset, CompatLength; public UIntPtr Reserved;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string Section;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string Inf;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string Description;
            public char HardwareId;
        }
        [DllImport("setupapi.dll", SetLastError=true)] static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid guid, IntPtr parent);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetupDiOpenDeviceInfoW(IntPtr set, string id, IntPtr parent, uint flags, ref Device device);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetupDiGetDeviceInstallParamsW(IntPtr set, ref Device device, ref Parameters parameters);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetupDiSetDeviceInstallParamsW(IntPtr set, ref Device device, ref Parameters parameters);
        [DllImport("setupapi.dll", SetLastError=true)] static extern bool SetupDiBuildDriverInfoList(IntPtr set, ref Device device, uint type);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetupDiEnumDriverInfoW(IntPtr set, ref Device device, uint type, uint index, ref Driver driver);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetupDiGetDriverInfoDetailW(IntPtr set, ref Device device, ref Driver driver, IntPtr detail, uint bytes, out uint required);
        [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDriverInfoList(IntPtr set, ref Device device, uint type);
        [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
        [DllImport("newdev.dll", SetLastError=true)] static extern bool DiInstallDevice(IntPtr parent, IntPtr set, ref Device device, ref Driver driver, uint flags, out bool reboot);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetupGetInfDriverStoreLocationW(string inf, IntPtr platform, string locale, System.Text.StringBuilder buffer, uint size, out uint required);
        static void Check(bool success, string operation) {
            if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(), operation);
        }
        public static string DriverStoreInf(string inf) {
            var path = new System.Text.StringBuilder(260); // API supports at most MAX_PATH.
            uint required;
            Check(SetupGetInfDriverStoreLocationW(inf, IntPtr.Zero, null, path, (uint)path.Capacity, out required), "Find driver-store INF");
            return path.ToString();
        }
        // Returns a set with a built class-driver list for one INF; the caller destroys both.
        static IntPtr OpenList(string instance, string inf, ref Device device) {
            Guid guid = new Guid("4d36e968-e325-11ce-bfc1-08002be10318");
            IntPtr set = SetupDiCreateDeviceInfoList(ref guid, IntPtr.Zero);
            if (set == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
            device = new Device { Size = (uint)Marshal.SizeOf<Device>() };
            try {
                Check(SetupDiOpenDeviceInfoW(set, instance, IntPtr.Zero, 0, ref device), "Open target");
                Parameters parameters = new Parameters { Size = (uint)Marshal.SizeOf<Parameters>() };
                Check(SetupDiGetDeviceInstallParamsW(set, ref device, ref parameters), "Get install parameters");
                parameters.Flags |= 0x00010000; // DI_ENUMSINGLEINF
                // Keep identically named HP models separate so exact subsystem selection works.
                parameters.FlagsEx |= 0x08000800; // DI_FLAGSEX_NO_CLASSLIST_NODE_MERGE | DI_FLAGSEX_ALLOWEXCLUDEDDRVS
                parameters.Path = inf;
                Check(SetupDiSetDeviceInstallParamsW(set, ref device, ref parameters), "Set INF enumeration parameters");
                Check(SetupDiBuildDriverInfoList(set, ref device, 1), "Build class-driver list");
                return set;
            } catch {
                SetupDiDestroyDeviceInfoList(set);
                throw;
            }
        }
        static Selection ReadAt(IntPtr set, ref Device device, uint index, out Driver driver) {
            driver = new Driver { Size = (uint)Marshal.SizeOf<Driver>() };
            if (!SetupDiEnumDriverInfoW(set, ref device, 1, index, ref driver)) {
                int error = Marshal.GetLastWin32Error();
                if (error == 259) return null; // ERROR_NO_MORE_ITEMS
                throw new Win32Exception(error, "Enumerate models");
            }
            uint required;
            bool sized = SetupDiGetDriverInfoDetailW(set, ref device, ref driver, IntPtr.Zero, 0, out required);
            if (!sized && Marshal.GetLastWin32Error() != 122)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Size model detail");
            int bytes = Math.Max(checked((int)required), Marshal.SizeOf<Detail>());
            IntPtr buffer = Marshal.AllocHGlobal(bytes);
            try {
                Marshal.WriteInt32(buffer, Marshal.SizeOf<Detail>());
                Check(SetupDiGetDriverInfoDetailW(set, ref device, ref driver, buffer, (uint)bytes, out required), "Read model detail");
                Detail detail = Marshal.PtrToStructure<Detail>(buffer);
                int offset = Marshal.OffsetOf<Detail>("HardwareId").ToInt32();
                string hardwareId = Marshal.PtrToStringUni(IntPtr.Add(buffer, offset));
                ulong v = driver.Version;
                return new Selection { Index = checked((int)index), Description = driver.Description, Provider = driver.Provider,
                    HardwareId = hardwareId, Section = detail.Section, Inf = detail.Inf, Version = v,
                    VersionText = (v >> 48) + "." + ((v >> 32) & 0xFFFF) + "." + ((v >> 16) & 0xFFFF) + "." + (v & 0xFFFF) };
            } finally { Marshal.FreeHGlobal(buffer); }
        }
        public static Selection[] Enumerate(string instance, string inf) {
            Device device = new Device();
            IntPtr set = OpenList(instance, inf, ref device);
            try {
                var models = new System.Collections.Generic.List<Selection>();
                for (uint index = 0; ; index++) {
                    Driver driver;
                    Selection model = ReadAt(set, ref device, index, out driver);
                    if (model == null) break;
                    models.Add(model);
                }
                return models.ToArray();
            } finally {
                SetupDiDestroyDriverInfoList(set, ref device, 1);
                SetupDiDestroyDeviceInfoList(set);
            }
        }
        public static Selection Install(string instance, string inf, int index, string hardwareId, string section) {
            if (index < 0) throw new ArgumentOutOfRangeException("index");
            Device device = new Device();
            IntPtr set = OpenList(instance, inf, ref device);
            try {
                Driver driver;
                Selection model = ReadAt(set, ref device, (uint)index, out driver);
                if (model == null ||
                    !String.Equals(model.HardwareId, hardwareId, StringComparison.OrdinalIgnoreCase) ||
                    !String.Equals(model.Section, section, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Driver list changed between enumeration and install; refusing.");
                bool reboot;
                Check(DiInstallDevice(IntPtr.Zero, set, ref device, ref driver, 0, out reboot), "Install selected driver on external device");
                model.NeedReboot = reboot;
                return model;
            } finally {
                SetupDiDestroyDriverInfoList(set, ref device, 1);
                SetupDiDestroyDeviceInfoList(set);
            }
        }
    }
}
'@
}
Import-Module (Join-Path $PSScriptRoot 'SparkEgpu.psm1') -Force

function Show-Item($Value) { $Value | Format-List | Out-Host }
function Get-KeyPath($Device) {
    'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Class\' + $Device.DriverKey
}
function Get-Override($Device) {
    $key = Get-Item -LiteralPath (Get-KeyPath $Device)
    $exists = $key.GetValueNames() -contains $overrideName
    if ($exists -and $key.GetValueKind($overrideName) -ne [Microsoft.Win32.RegistryValueKind]::DWord) {
        throw 'Existing RM1774520 is not a DWORD; refusing to overwrite it.'
    }
    [pscustomobject]@{ Exists = $exists; Value = $(if ($exists) { $key.GetValue($overrideName) } else { $null }) }
}
function Export-DeviceKey($Device, [string]$File) {
    & "$env:SystemRoot\System32\reg.exe" export (
        'HKLM\SYSTEM\CurrentControlSet\Control\Class\' + $Device.DriverKey) $File /y
    if ($LASTEXITCODE -ne 0) { throw "Registry export failed: $File" }
}
function Save-State($State, [string]$File) {
    # Atomic replacement leaves the prior recovery state intact on interruption.
    $temporary = "$File.tmp"
    # -InputObject keeps a one-element array serialized as a JSON array.
    [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $State -Depth 8))
    # PowerShell converts $null to '' for string parameters; Replace needs a real null.
    if ([IO.File]::Exists($File)) { [IO.File]::Replace($temporary, $File, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $File) }
}
function Invoke-DeviceCommand([ValidateSet('restart', 'disable', 'enable')][string]$Command, [string]$Id) {
    & "$env:SystemRoot\System32\pnputil.exe" "/$Command-device" $Id
    $code = $LASTEXITCODE
    if ($code -eq 3010) { throw 'Windows requires a reboot. Reboot manually, then run Inspect.' }
    if ($code -ne 0) { throw "Device $Command failed (exit $code). Recovery state is saved; no automatic reboot." }
    Start-Sleep -Seconds 3
}
function Assert-Identity($Device, $Internal) {
    $prefix = Get-SparkFamilyPrefix $Internal
    if ($Device.Class -ne 'Display' -or $Device.InstanceId -notlike 'PCI\VEN_10DE&*' -or
        $Device.InstanceId -eq $Internal.InstanceId -or
        @($Device.HardwareIds | Where-Object { $_ -like "$prefix*" }).Count -ne 0) {
        throw "Refusing: $($Device.InstanceId) is not an external NVIDIA display device."
    }
    if ($null -eq $Device.ProblemCode) { throw 'Cannot read target problem code.' }
}
function Assert-OwnedDriverKey($Device) {
    if ($Device.DriverKey -notmatch ('^' + [regex]::Escape($displayClass) + '\\\d{4}$')) {
        throw 'Target has no unambiguous display-driver registry key.'
    }
    $owners = @(Get-PnpDevice -PresentOnly -Class Display | ForEach-Object {
        $key = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_Driver -WhatIf:$false).Data
        if ($key -eq $Device.DriverKey) { $_.InstanceId }
    })
    if ($owners.Count -ne 1 -or $owners[0] -ne $Device.InstanceId) {
        throw 'Refusing: registry key is not exclusively owned by the target.'
    }
}
function Resolve-Target([string]$Id, $Internal) {
    if ($Id) { $target = Get-DeviceState $Id }
    else {
        $externals = @(Get-ExternalGpu $Internal)
        if ($externals.Count -ne 1) {
            throw "Specify -InstanceId. External NVIDIA GPUs present: $(($externals | ForEach-Object { $_.InstanceId }) -join '; ')"
        }
        $target = $externals[0]
    }
    Assert-Identity $target $Internal
    $target
}
function Initialize-DataRoot {
    # A non-administrator could pre-create this folder and plant backups or history.
    if (Test-Path -LiteralPath $dataRoot) {
        $owner = (Get-Acl -LiteralPath $dataRoot).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -ne 'S-1-5-32-544' -and $owner -ne 'S-1-5-18') {
            throw "$dataRoot exists with an unexpected owner; delete it and rerun."
        }
    }
    foreach ($directory in $dataRoot, $backupRoot, $logRoot) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @(('S-1-5-18', 'FullControl'), ('S-1-5-32-544', 'FullControl'), ('S-1-5-32-545', 'ReadAndExecute'))) {
        $sid = New-Object Security.Principal.SecurityIdentifier $rule[0]
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $sid, $rule[1], $inherit, $none, $allow))
    }
    Set-Acl -LiteralPath $dataRoot -AclObject $acl
}
function Enter-RunLock([int]$TimeoutSeconds) {
    # PowerShell wraps .NET exceptions; match on the base exception.
    try { $mutex = New-Object Threading.Mutex($false, 'Global\SparkEgpu') }
    catch {
        # Opening a mutex created under another account (SYSTEM task) can be denied while it runs.
        if ($_.Exception.GetBaseException() -is [UnauthorizedAccessException]) { return $null }
        throw
    }
    try { $acquired = $mutex.WaitOne($TimeoutSeconds * 1000) }
    catch {
        if ($_.Exception.GetBaseException() -isnot [Threading.AbandonedMutexException]) { $mutex.Dispose(); throw }
        $acquired = $true
    }
    if ($acquired) { return $mutex }
    $mutex.Dispose()
    $null
}
function Exit-RunLock($Mutex) {
    $Mutex.ReleaseMutex()
    $Mutex.Dispose()
}
function Read-BindHistory {
    if (-not (Test-Path -LiteralPath $historyFile)) { return @() }
    # Assign first: Windows PowerShell emits a JSON array as one object.
    $parsed = Get-Content -LiteralPath $historyFile -Raw | ConvertFrom-Json
    @($parsed)
}
function Write-BindHistory([string]$Key, [string]$Result) {
    $entries = @(Read-BindHistory | Where-Object { $_.Key -ne $Key })
    $entries += [pscustomobject]@{ Key = $Key; Utc = (Get-Date).ToUniversalTime().ToString('o'); Result = $Result }
    Save-State $entries $historyFile
}
function Get-HistoryKey($Device, $Internal) {
    "$($Device.InstanceId)|$($Internal.Inf)|$($Internal.Version)"
}
function Get-BootId { (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') }
function Get-RestartKey($Device) { "$($Device.InstanceId)|restart|$(Get-BootId)" }
function Show-PackageDiagnostics($Internal, $Externals) {
    foreach ($device in $Externals) {
        if ($device.Provider -eq 'NVIDIA' -and $device.Inf -ne $Internal.Inf) {
            Write-Warning "Package mismatch for $($device.InstanceId): $($device.Inf) $($device.Version); internal Spark uses $($Internal.Inf) $($Internal.Version). Package age is not inferred; automatic mode leaves a healthy NVIDIA binding unchanged."
        }
    }
    try {
        $storeInf = [SparkEgpu.Binding]::DriverStoreInf((Join-Path "$env:SystemRoot\INF" $Internal.Inf))
        Write-Host "Internal Spark package: $($Internal.Inf) -> $storeInf"
        $image = [string](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm' -Name ImagePath).ImagePath
        Write-Host "Configured nvlddmkm ImagePath (not proof of the loaded image): $image"
        $path = [Environment]::ExpandEnvironmentVariables($image).Trim('"')
        if ($path.StartsWith('\??\', [StringComparison]::OrdinalIgnoreCase)) { $path = $path.Substring(4) }
        if ($path.StartsWith('\SystemRoot\', [StringComparison]::OrdinalIgnoreCase)) {
            $path = Join-Path $env:SystemRoot $path.Substring(12)
        }
        $expected = Join-Path ([IO.Path]::GetDirectoryName($storeInf)) 'nvlddmkm.sys'
        if (-not [string]::Equals($path, $expected, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning "Shared NVIDIA service package mismatch: configured $image; expected $expected for internal Spark $($Internal.Inf). No drivers or service settings were changed."
        }
    } catch {
        Write-Warning "Cannot inspect the configured NVIDIA service package: $_"
    }
}
function Select-SparkModel([string]$Id, $Internal) {
    $infPath = Join-Path "$env:SystemRoot\INF" $Internal.Inf
    $prefix = Get-SparkFamilyPrefix $Internal
    $models = @([SparkEgpu.Binding]::Enumerate($Id, $infPath))
    $candidates = @($models | Where-Object { $_.Section -eq $Internal.Section -and $_.HardwareId -like "$prefix*" })
    $exact = @($candidates | Where-Object { $_.HardwareId -eq $Internal.MatchingId })
    if ($exact.Count -eq 1) { $model = $exact[0] }
    elseif ($candidates.Count -eq 1) { $model = $candidates[0] }
    else {
        throw ("Cannot choose a unique Spark model in $($Internal.Inf) for $($Internal.Section). Enumerated: " +
            (($models | ForEach-Object { "$($_.HardwareId) [$($_.Section)] $($_.Description)" }) -join '; '))
    }
    if ($model.Provider -ne 'NVIDIA' -or $model.Description -notlike 'NVIDIA RTX Spark*') {
        throw 'Unexpected driver model; refusing configuration.'
    }
    $model.Inf = $infPath
    $model
}
function Get-PendingAction($Device, $Internal, $History, [switch]$Manual) {
    function New-Action([string]$Action, [string]$Reason) { [pscustomobject]@{ Action = $Action; Reason = $Reason } }
    $current = $Device.Inf -eq $Internal.Inf
    $code = $Device.ProblemCode
    if ($code -eq 22) { return New-Action 'None' 'Disabled (Code 22); run -Mode Start to enable.' }
    # Automation leaves a healthy different NVIDIA package alone; manual Install rebinds it.
    if ($Device.Provider -eq 'NVIDIA' -and $code -eq 0 -and ($current -or -not $Manual)) {
        if ($current) { return New-Action 'None' 'Healthy on the current Spark package.' }
        return New-Action 'None' "Healthy on different NVIDIA package $($Device.Inf); run -Mode Install to rebind."
    }
    if (-not $current) {
        $key = Get-HistoryKey $Device $Internal
        $recorded = @($History | Where-Object { $null -ne $_ -and $_.Key -eq $key })
        if ($recorded.Count) {
            return New-Action 'None' ("Automatic bind already recorded for this device and package " +
                "($($recorded[0].Result) at $($recorded[0].Utc)); run -Mode Install manually.")
        }
        return New-Action 'Bind' "Not bound to the internal Spark package $($Internal.Inf)."
    }
    if ($code -eq 43) {
        if (-not $Device.DriverKey) { return New-Action 'None' 'Code 43 without a driver key.' }
        $override = Get-Override $Device
        if (-not ($override.Exists -and $override.Value -eq 1)) { return New-Action 'Patch' 'Code 43 without RM1774520=1.' }
        $restartKey = Get-RestartKey $Device
        if (@($History | Where-Object { $null -ne $_ -and $_.Key -eq $restartKey }).Count) {
            return New-Action 'None' 'Code 43 persists with RM1774520=1 after a restart this boot; shut down Windows, power-cycle the enclosure, then boot.'
        }
        return New-Action 'Restart' 'Code 43 with RM1774520=1; restarting the device once this boot.'
    }
    if ($code -ne 0) {
        return New-Action 'None' "Code $code has no automatic fix (Code 12 = PCIe resource allocation; see README)."
    }
    New-Action 'None' 'Healthy.'
}
function Get-NvidiaSiblingHealth([string]$ExcludeInstanceId) {
    $health = @{}
    Get-PnpDevice -PresentOnly -Class Display | Where-Object {
        $_.InstanceId -match '^(PCI\\VEN_10DE&|ACPI\\NVDA)' -and $_.InstanceId -ne $ExcludeInstanceId
    } | ForEach-Object { $health[$_.InstanceId] = Get-DeviceState $_.InstanceId }
    $health
}
function Test-NvidiaSmi($Device) {
    $match = [regex]::Match([string]$Device.HardwareIds[0], '^PCI\\VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})&SUBSYS_([0-9A-F]{8})', 'IgnoreCase')
    if (-not $match.Success) { throw "Cannot parse hardware ID $($Device.HardwareIds[0])." }
    $deviceId = ('0x' + $match.Groups[2].Value + $match.Groups[1].Value).ToUpperInvariant()
    $subsystemId = ('0x' + $match.Groups[3].Value).ToUpperInvariant()
    $rows = @(& "$env:SystemRoot\System32\nvidia-smi.exe" --query-gpu=name,pci.bus_id,pci.device_id,pci.sub_device_id,driver_version,memory.total --format=csv,noheader)
    $exit = $LASTEXITCODE
    $rows | Out-Host
    # Index from the end: the name column may contain commas.
    $matched = @($rows | Where-Object {
        $fields = @("$_" -split ',\s*')
        $fields.Count -ge 6 -and $fields[-4].ToUpperInvariant() -eq $deviceId -and $fields[-3].ToUpperInvariant() -eq $subsystemId
    })
    if ($exit -ne 0 -or $matched.Count -eq 0) { throw 'PnP reports healthy but nvidia-smi does not list this device.' }
}
function Confirm-Healthy($Device) {
    $code = $Device.ProblemCode
    if ($code -eq 43) { throw 'Device reports Code 43; run -Mode Restart, or shut down and power-cycle the enclosure.' }
    if ($code -ne 0) { throw "Device reports Code $code." }
    Show-Item $Device
    Test-NvidiaSmi $Device
    Write-Host 'Device healthy; nvidia-smi lists it.'
}

# Shared change path for Install and Auto. The caller holds the run lock and has
# already confirmed -AcceptUnsupportedBinding and ShouldProcess.
function Invoke-Configure($Target, $Internal, [string]$RunMode, $History) {
    Assert-Administrator
    Initialize-DataRoot
    if ($Internal.ProblemCode -ne 0) { throw 'Internal Spark is not healthy; refusing configuration.' }
    $installed = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceID -eq $Internal.InstanceId })
    if ($installed.Count -ne 1 -or -not $installed[0].IsSigned -or $Internal.Inf -notmatch '^oem\d+\.inf$') {
        throw 'Cannot establish the internal Spark signed-driver package.'
    }
    $model = Select-SparkModel $Target.InstanceId $Internal
    $action = Get-PendingAction $Target $Internal $History -Manual:($RunMode -eq 'Install')
    if ($action.Action -eq 'None') {
        Write-Host $action.Reason
        return
    }
    $siblingsBefore = Get-NvidiaSiblingHealth $Target.InstanceId
    $run = Join-Path $backupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + "-$RunMode-" + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($run) | Out-Null
    $statePath = Join-Path $run 'state.json'
    $originalOverride = if ($Target.DriverKey) { Get-Override $Target } else { [pscustomobject]@{ Exists = $false; Value = $null } }
    # Device is the binding at backup time; Rebind records whether this run changes it.
    $state = [pscustomobject]@{
        Schema = 2
        CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Mode = $RunMode
        Device = $Target
        Rebind = ($action.Action -eq 'Bind')
        OriginalOverride = $originalOverride
        Patch = $null
    }
    Save-State $state $statePath
    if ($Target.DriverKey) {
        Assert-OwnedDriverKey $Target
        Export-DeviceKey $Target (Join-Path $run 'before-install.reg')
    }
    Write-Host "Recovery state: $statePath"
    $historyKey = Get-HistoryKey $Target $Internal
    $failureResult = 'Failed'
    $restartKey = $null
    try {
        if ($action.Action -eq 'Bind') {
            Write-BindHistory $historyKey 'Started'
            $binding = [SparkEgpu.Binding]::Install($Target.InstanceId, $model.Inf, $model.Index, $model.HardwareId, $model.Section)
            $failureResult = 'VerificationFailed'
            Write-BindHistory $historyKey 'Bound'
            if ($binding.NeedReboot) {
                $failureResult = 'RebootRequired'
                throw "Driver bound; Windows requires a reboot. Reboot manually. Keep $statePath`: it is the backup that restores the driver this device had before binding."
            }
            Start-Sleep -Seconds 3
            $Target = Get-DeviceState $Target.InstanceId
            Assert-Identity $Target $Internal
            if ($Target.Inf -ne $Internal.Inf) { throw 'NVIDIA package did not remain bound; no registry workaround applied.' }
        }
        if ($Target.ProblemCode -eq 43) {
            Assert-OwnedDriverKey $Target
            Export-DeviceKey $Target (Join-Path $run 'before-code43.reg')
            $before = Get-Override $Target
            if (-not ($before.Exists -and $before.Value -eq 1)) {
                $state.Patch = [pscustomobject]@{ DriverKey = $Target.DriverKey; Before = $before }
                Save-State $state $statePath
                New-ItemProperty -LiteralPath (Get-KeyPath $Target) -Name $overrideName -PropertyType DWord -Value 1 -Force | Out-Null
            }
            $restartKey = Get-RestartKey $Target
            Write-BindHistory $restartKey 'Started'
            Invoke-DeviceCommand restart $Target.InstanceId
            $Target = Get-DeviceState $Target.InstanceId
        }
        Show-Item $Target
        if ($Target.ProblemCode -ne 0) { throw "External device still reports Code $($Target.ProblemCode); no other workarounds attempted." }
        $siblingsAfter = Get-NvidiaSiblingHealth $Target.InstanceId
        foreach ($id in $siblingsBefore.Keys) {
            $before = $siblingsBefore[$id]
            if ($before.ProblemCode -ne 0) { continue }
            $after = $siblingsAfter[$id]
            if ($null -eq $after) {
                throw "Internal Spark/NPU health changed for ${id}: device missing (before: Code $($before.ProblemCode), INF $($before.Inf)). Review saved recovery state."
            }
            if ($after.ProblemCode -ne 0 -or $after.Inf -ne $before.Inf) {
                throw "Internal Spark/NPU health changed for ${id}: Code $($before.ProblemCode) -> $($after.ProblemCode), INF $($before.Inf) -> $($after.Inf). Review saved recovery state."
            }
        }
        Test-NvidiaSmi $Target
        if ($action.Action -eq 'Bind') { Write-BindHistory $historyKey 'Succeeded' }
        if ($restartKey) { Write-BindHistory $restartKey 'Succeeded' }
        Write-Host 'PnP and NVIDIA enumeration passed. CUDA, graphics, and reboot persistence still require functional checks.'
    } catch {
        if ($action.Action -eq 'Bind') {
            try { Write-BindHistory $historyKey $failureResult } catch { Write-Warning "Could not record bind outcome: $_" }
        }
        if ($restartKey) {
            try { Write-BindHistory $restartKey 'Failed' } catch { Write-Warning "Could not record restart outcome: $_" }
        }
        Write-Warning "Stopped. Recovery state: $statePath"
        Write-Warning "Restore command: & '$PSCommandPath' -Mode Restore -BackupPath '$statePath'"
        throw
    }
}

switch ($Mode) {
'Inspect' {
    $internal = Get-InternalSpark
    Write-Host 'Internal RTX Spark:'
    Show-Item $internal
    $externals = @(Get-ExternalGpu $internal)
    Show-PackageDiagnostics $internal $externals
    if ($externals.Count -eq 0) {
        Write-Host 'No external NVIDIA GPU present.'
        return
    }
    $history = @(Read-BindHistory)
    foreach ($external in $externals) {
        Write-Host 'External NVIDIA GPU:'
        Show-Item $external
        if ($external.DriverKey) { Write-Host 'Current RM1774520:' (Get-Override $external | ConvertTo-Json -Compress) }
        Write-Host 'Candidate Spark model:'
        Show-Item (Select-SparkModel $external.InstanceId $internal)
        $action = Get-PendingAction $external $internal $history
        Write-Host "Pending action: $($action.Action) - $($action.Reason)"
        if ($external.Inf) {
            Write-Host 'Current driver available for rollback:'
            Show-Item ([SparkEgpu.Binding]::Enumerate($external.InstanceId, (Join-Path "$env:SystemRoot\INF" $external.Inf)) |
                Where-Object { $_.HardwareId -eq $external.MatchingId })
        }
    }
}
'Install' {
    $internal = Get-InternalSpark
    $target = Resolve-Target $InstanceId $internal
    Show-PackageDiagnostics $internal @($target)
    Show-Item $target
    Write-Host 'Candidate Spark model:'
    Show-Item (Select-SparkModel $target.InstanceId $internal)
    $action = Get-PendingAction $target $internal @() -Manual
    Write-Host "Pending action: $($action.Action) - $($action.Reason)"
    if ($action.Action -eq 'None') { return }
    Write-Warning 'Unsupported binding of the Spark driver to an external NVIDIA GPU. Possible crash/display interruption. Shut down Windows before unplugging the eGPU or powering off its enclosure.'
    if (-not $WhatIfPreference -and -not $AcceptUnsupportedBinding) {
        throw 'Review this script first, then explicitly pass -AcceptUnsupportedBinding to install.'
    }
    if (-not $PSCmdlet.ShouldProcess($target.InstanceId, 'Back up, bind current signed Spark driver, and apply Code 43 workaround only if needed')) { return }
    $lock = Enter-RunLock 0
    if ($null -eq $lock) { throw 'Another Spark eGPU run is active; retry when it finishes.' }
    try { Invoke-Configure $target $internal 'Install' @() }
    finally { Exit-RunLock $lock }
}
'Restore' {
    if (-not $BackupPath) { throw 'Restore requires -BackupPath pointing to state.json from an install.' }
    $BackupPath = (Resolve-Path -LiteralPath $BackupPath).ProviderPath
    if (-not $BackupPath.StartsWith($backupRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Restore only accepts backups under $backupRoot."
    }
    $state = Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json
    if ($null -eq $state.PSObject.Properties['Schema'] -or $state.Schema -ne 2) { throw 'Unsupported backup schema.' }
    $id = $state.Device.InstanceId
    try { $target = Get-DeviceState $id }
    catch { throw "Reconnect the eGPU to the USB4 port used for this backup (instance $id)." }
    $internal = Get-InternalSpark
    Assert-Identity $target $internal
    if (@($target.HardwareIds)[0] -ne @($state.Device.HardwareIds)[0]) { throw 'Backup does not belong to this target.' }
    $needsRebind = $state.Rebind -and $target.Inf -ne $state.Device.Inf
    if ($needsRebind) {
        $originalName = [string]$state.Device.Inf
        if ($originalName -notmatch '^(oem\d+|display)\.inf$') { throw 'Unexpected backup INF name.' }
        $originalInf = Join-Path "$env:SystemRoot\INF" $originalName
        $original = @([SparkEgpu.Binding]::Enumerate($id, $originalInf) | Where-Object { $_.HardwareId -eq $state.Device.MatchingId })
        if ($original.Count -ne 1) { throw "Cannot find exactly one $($state.Device.MatchingId) model in $originalName." }
        $original = $original[0]
        # Inbox display.inf changes version with cumulative updates; OEM packages must match exactly.
        if ($originalName -like 'oem*' -and
            ($original.VersionText -ne $state.Device.Version -or $original.Provider -ne $state.Device.Provider)) {
            throw ("Driver package $originalName no longer matches the backup (found $($original.Provider) $($original.VersionText), " +
                "expected $($state.Device.Provider) $($state.Device.Version)); refusing to rebind.")
        }
        Write-Host 'Original driver to rebind:'
        Show-Item $original
    }
    if (-not $PSCmdlet.ShouldProcess($id, 'Restore saved driver binding and RM1774520 override')) { return }
    Assert-Administrator
    Initialize-DataRoot
    $lock = Enter-RunLock 0
    if ($null -eq $lock) { throw 'Another Spark eGPU run is active; retry when it finishes.' }
    try {
        if ($needsRebind) {
            # Recorded first so the automation does not rebind this device for the current package.
            Write-BindHistory (Get-HistoryKey $target $internal) 'Restored'
            $restored = [SparkEgpu.Binding]::Install($id, $originalInf, $original.Index, $original.HardwareId, $original.Section)
            if ($restored.NeedReboot) {
                Write-Warning 'Reboot required to finish restoring. After rebooting, rerun this Restore command to reconcile RM1774520.'
                return
            }
            $target = Get-DeviceState $id
            Assert-Identity $target $internal
            if ($target.Inf -ne $state.Device.Inf) { throw 'Original driver did not remain bound.' }
            Write-Host 'Automation will not rebind this device for the current Spark package. Run -Mode Install to bind again.'
        }
        if (-not $state.Rebind -and $null -ne $state.Patch -and $target.DriverKey -ne $state.Patch.DriverKey) {
            throw 'Driver key changed since patch; refusing to write a stale registry key.'
        }
        if (-not $target.DriverKey) {
            Write-Host 'No driver key; override not reconciled.'
        } else {
            Assert-OwnedDriverKey $target
            $key = Get-KeyPath $target
            $currentOverride = Get-Override $target
            $changedOverride = $false
            if ($state.OriginalOverride.Exists -and
                (-not $currentOverride.Exists -or $currentOverride.Value -ne $state.OriginalOverride.Value)) {
                New-ItemProperty -LiteralPath $key -Name $overrideName -PropertyType DWord -Value $state.OriginalOverride.Value -Force | Out-Null
                $changedOverride = $true
            } elseif (-not $state.OriginalOverride.Exists -and $currentOverride.Exists) {
                Remove-ItemProperty -LiteralPath $key -Name $overrideName
                $changedOverride = $true
            }
            if ($changedOverride) { Invoke-DeviceCommand restart $id }
        }
        Show-Item (Get-DeviceState $id)
    } finally { Exit-RunLock $lock }
}
'Restart' {
    $internal = Get-InternalSpark
    $target = Resolve-Target $InstanceId $internal
    if ($target.ProblemCode -eq 22) { throw 'Device is disabled; run -Mode Start.' }
    if (-not $PSCmdlet.ShouldProcess($target.InstanceId, 'Restart external GPU')) { return }
    Assert-Administrator
    $lock = Enter-RunLock 0
    if ($null -eq $lock) { throw 'Another Spark eGPU run is active; retry when it finishes.' }
    try {
        Invoke-DeviceCommand restart $target.InstanceId
        Confirm-Healthy (Get-DeviceState $target.InstanceId)
    } finally { Exit-RunLock $lock }
}
'Stop' {
    $internal = Get-InternalSpark
    $target = Resolve-Target $InstanceId $internal
    if ($target.ProblemCode -eq 22) { throw 'Device is already disabled.' }
    if (-not $PSCmdlet.ShouldProcess($target.InstanceId, 'Disable external GPU')) { return }
    Assert-Administrator
    $lock = Enter-RunLock 0
    if ($null -eq $lock) { throw 'Another Spark eGPU run is active; retry when it finishes.' }
    try {
        Invoke-DeviceCommand disable $target.InstanceId
        $code = (Get-DeviceState $target.InstanceId).ProblemCode
        if ($code -ne 22) { throw "Disable did not take effect (Code $code)." }
        Write-Host 'Disabled. It stays disabled across reboots until -Mode Start.'
        Write-Warning 'Disabling is not verified to make hot-removal safe. Shut down Windows before unplugging the eGPU or powering off its enclosure.'
    } finally { Exit-RunLock $lock }
}
'Start' {
    $internal = Get-InternalSpark
    $target = Resolve-Target $InstanceId $internal
    if ($target.ProblemCode -ne 22) { throw 'Device is not disabled; use -Mode Restart.' }
    if (-not $PSCmdlet.ShouldProcess($target.InstanceId, 'Enable external GPU')) { return }
    Assert-Administrator
    $lock = Enter-RunLock 0
    if ($null -eq $lock) { throw 'Another Spark eGPU run is active; retry when it finishes.' }
    try {
        Invoke-DeviceCommand enable $target.InstanceId
        Confirm-Healthy (Get-DeviceState $target.InstanceId)
    } finally { Exit-RunLock $lock }
}
'Auto' {
    Assert-Administrator
    Initialize-DataRoot
    Start-Transcript -LiteralPath (Join-Path $logRoot ('auto-' + (Get-Date -Format 'yyyyMMdd') + '.log')) -Append | Out-Null
    $failed = $false
    try {
        Get-ChildItem -LiteralPath $logRoot -Filter 'auto-*.log' |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force
        if (-not $AcceptUnsupportedBinding) { throw 'Auto mode requires -AcceptUnsupportedBinding.' }
        $lock = Enter-RunLock 600
        if ($null -eq $lock) {
            Write-Host 'Another run held the lock for 10 minutes; exiting.'
            return
        }
        try {
            $internal = Get-InternalSpark
            $externals = @(Get-ExternalGpu $internal)
            Show-PackageDiagnostics $internal $externals
            if ($externals.Count -eq 0) { Write-Host 'No external NVIDIA GPU present.' }
            $history = @(Read-BindHistory)
            foreach ($external in $externals) {
                $id = $external.InstanceId
                try {
                    $action = Get-PendingAction $external $internal $history
                    Write-Host "${id}: $($action.Action) - $($action.Reason)"
                    if ($action.Action -ne 'None') { Invoke-Configure $external $internal 'Auto' $history }
                } catch {
                    Write-Host "FAILED ${id}: $_"
                    $failed = $true
                }
            }
        } finally { Exit-RunLock $lock }
    } catch {
        Write-Host "FAILED: $_"
        $failed = $true
    } finally { Stop-Transcript | Out-Null }
    exit ([int]$failed)
}
'Prompt' {
    $userLogs = Join-Path $env:LOCALAPPDATA 'SparkEgpu\Logs'
    [IO.Directory]::CreateDirectory($userLogs) | Out-Null
    Start-Transcript -LiteralPath (Join-Path $userLogs ('prompt-' + (Get-Date -Format 'yyyyMMdd') + '.log')) -Append | Out-Null
    try {
        $internal = Get-InternalSpark
        $history = @(Read-BindHistory)
        $pending = @(Get-ExternalGpu $internal | ForEach-Object {
            $action = Get-PendingAction $_ $internal $history
            Write-Host "$($_.InstanceId): $($action.Action) - $($action.Reason)"
            if ($action.Action -ne 'None') { [pscustomobject]@{ InstanceId = $_.InstanceId; Reason = $action.Reason } }
        })
        if ($pending.Count -eq 0) { return }
        Add-Type -AssemblyName System.Windows.Forms
        $lines = @('External NVIDIA GPU needs configuration:') + @($pending | ForEach-Object { "$($_.InstanceId): $($_.Reason)" }) + @('',
            'Configure it now (bind the RTX Spark driver, apply the Code 43 workaround, or restart the device as listed)? This is an unsupported binding; the display may flicker or the system may crash. Shut down Windows before unplugging the eGPU or powering off its enclosure. Windows will ask for administrator approval.')
        $answer = [System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), 'Spark eGPU', 'YesNo', 'Warning', 'Button2')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Host 'User declined.'
            return
        }
        try {
            $child = Start-Process -FilePath $powershellExe -Verb RunAs -Wait -PassThru -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Mode', 'Auto', '-AcceptUnsupportedBinding')
        } catch {
            Write-Host "Elevation declined. $_"
            return
        }
        $code = $child.ExitCode
        Write-Host "Auto exit code: $code"
        $message = if ($code -eq 0) { "Configuration finished. Log: $logRoot" } else { "Configuration failed (exit $code). Log: $logRoot" }
        [System.Windows.Forms.MessageBox]::Show($message, 'Spark eGPU', 'OK', $(if ($code -eq 0) { 'Information' } else { 'Error' })) | Out-Null
    } finally { Stop-Transcript | Out-Null }
}
}

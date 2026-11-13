Set-StrictMode -Version Latest

function Get-DeviceState([string]$InstanceId) {
    $device = Get-PnpDevice -PresentOnly -InstanceId $InstanceId -ErrorAction SilentlyContinue
    if ($null -eq $device) { throw "Device is not present: $InstanceId" }
    $properties = @{}
    # The PnP module marks even this read-only CIM query as ShouldProcess.
    Get-PnpDeviceProperty -InstanceId $InstanceId -WhatIf:$false | ForEach-Object { $properties[$_.KeyName] = $_.Data }
    [pscustomobject]@{
        InstanceId = $device.InstanceId
        Name = $device.FriendlyName
        Class = $device.Class
        HardwareIds = @($properties['DEVPKEY_Device_HardwareIds'])
        LocationPaths = @($properties['DEVPKEY_Device_LocationPaths'])
        ProblemCode = $properties['DEVPKEY_Device_ProblemCode']
        DriverKey = $properties['DEVPKEY_Device_Driver']
        Inf = $properties['DEVPKEY_Device_DriverInfPath']
        Section = $properties['DEVPKEY_Device_DriverInfSection']
        Provider = $properties['DEVPKEY_Device_DriverProvider']
        Version = $properties['DEVPKEY_Device_DriverVersion']
        MatchingId = $properties['DEVPKEY_Device_MatchingDeviceId']
    }
}

function Get-NvidiaPciDisplay {
    @(Get-PnpDevice -PresentOnly -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'PCI\VEN_10DE&*' } |
        ForEach-Object { Get-DeviceState $_.InstanceId })
}

function Get-InternalSpark {
    $native = @(Get-NvidiaPciDisplay | Where-Object {
        $_.MatchingId -and ($_.HardwareIds -contains $_.MatchingId) -and $_.Inf -match '^oem\d+\.inf$'
    })
    if ($native.Count -ne 1) {
        throw 'Cannot identify the internal RTX Spark GPU: need exactly one NVIDIA PCI display device natively matched by an OEM driver package.'
    }
    $native[0]
}

function Get-SparkFamilyPrefix($Internal) {
    $prefix = [regex]::Match([string]$Internal.MatchingId, '^pci\\ven_[0-9a-f]{4}&dev_[0-9a-f]{4}', 'IgnoreCase').Value
    if (-not $prefix) { throw 'Cannot derive the internal Spark family prefix.' }
    $prefix
}

function Get-ExternalGpu($Internal) {
    $prefix = Get-SparkFamilyPrefix $Internal
    @(Get-NvidiaPciDisplay | Where-Object {
        $device = $_
        $device.InstanceId -ne $Internal.InstanceId -and
            -not @($device.HardwareIds | Where-Object { $_ -like "$prefix*" }).Count
    })
}

function Assert-Administrator {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run from an elevated native ARM64 PowerShell after reviewing this script; no changes made.'
    }
}

Export-ModuleMember -Function Get-DeviceState, Get-InternalSpark, Get-SparkFamilyPrefix, Get-ExternalGpu, Assert-Administrator

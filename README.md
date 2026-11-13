# Spark eGPU

Run an external NVIDIA GPU (eGPU over USB4/Thunderbolt) on a Windows on ARM laptop
with an NVIDIA RTX Spark (N1X), such as the HP OmniBook, by binding the Spark's own
ARM64 NVIDIA driver to the eGPU and applying the `RM1774520` Code 43 workaround.
Optional connect-time automation re-applies this whenever the eGPU shows up.

## Warning

- This is an **unsupported** driver binding. NVIDIA does not ship an ARM64 driver
  for desktop GPUs; the Spark driver is forced onto a device it does not list.
- A display interruption, driver crash, or system crash is possible.
- **Shut down Windows before unplugging the eGPU or powering off its enclosure.**
  Hot-unplugging an RTX 3090 on driver 621.14 has caused
  `VIDEO_DXGKRNL_FATAL_ERROR` (`0x113`) on this HP setup. Passing PnP and
  `nvidia-smi` checks does not establish safe hot-removal.
- No security settings are changed (no test signing, no Secure Boot or driver
  signature changes, no INF edits). Nothing is downloaded.
- Use at your own risk. Read the scripts before running them elevated.

## Connecting

- Supported order: shut down Windows, boot, log on, then plug in the eGPU. A cold
  boot with the eGPU attached is not possible with the AOOSTAR AG02.
- Each USB4 port gives the eGPU its own device instance, so the first connect on a
  new port needs one bind. The [automation](#automation) does this on connect.
- Code 43 can return on a later connect even with `RM1774520=1` set. Restarting only
  the eGPU (`-Mode Restart`, or automatically once per boot) has cleared it.

## Tested hardware

Reports from the [Level1Techs thread](https://forum.level1techs.com/t/rtx-egpus-working-on-rtx-spark-hp-omnibook/259662).
All on an HP OmniBook X 14-ks000 over USB4.

| eGPU | Dock | Driver | Result |
|---|---|---|---|
| RTX 4070 | AOOSTAR AG02 | 621.01 | Working after `RM1774520=1` |
| RTX 3090 (MSI) | AOOSTAR AG02 | 621.14 | Working: hot-plug after logon on both USB4 ports; 10 min gaming load with no TDR/Xid; CUDA kernel OK (809 GB/s device bandwidth); Cyberpunk 2077 benchmark 76.72 FPS average. Code 43 sometimes returns, cleared by restarting the eGPU |
| RTX 5090 | - | 621.14 | Code 12 (PCIe BAR placement); no fix known |
| NVIDIA A2 | - | - | Code 43 persists with `RM1774520=1` |

## Requirements

- Windows 11 ARM64 laptop with an NVIDIA RTX Spark GPU, with NVIDIA's ARM64 Spark
  driver already installed and healthy on the internal GPU. The scripts never
  download, extract, or install driver packages; they reuse the one in the driver store.
- Built-in Windows PowerShell 5.1 or PowerShell 7, running natively on ARM64.
- Administrator rights for any change. Inspect and `-WhatIf` need none.

## Quick start

Get the scripts, then unblock them (files downloaded from the internet are blocked):

```powershell
git clone https://github.com/thatguywob/RTX-Spark-eGPU
cd RTX-Spark-eGPU
Get-ChildItem *.ps1, *.psm1 | Unblock-File
```

Or download a release ZIP, extract it, and run the `Unblock-File` line in that folder.

Connect the eGPU, then from this folder:

```powershell
# Read-only: internal Spark, each external NVIDIA GPU, the model that would be bound,
# and the pending action.
.\Configure-SparkEgpu.ps1

# Dry run.
.\Configure-SparkEgpu.ps1 -Mode Install -WhatIf

# From an elevated PowerShell: back up, bind, and apply the Code 43 fix if needed.
.\Configure-SparkEgpu.ps1 -Mode Install -AcceptUnsupportedBinding
```

If the execution policy blocks scripts:

```powershell
powershell -ExecutionPolicy Bypass -File .\Configure-SparkEgpu.ps1 -Mode Install -AcceptUnsupportedBinding
```

The scripts act on every present NVIDIA PCI display device that is not the internal
Spark. With more than one, pass `-InstanceId` (shown by Inspect).

What Install does:

1. Checks the internal Spark is healthy on a signed OEM driver package.
2. Picks the Spark model from that package, preferring the internal GPU's exact
   matching hardware ID. Identically named models remain separate during enumeration;
   a unique same-section/device-family candidate is used only if no exact match exists.
   Binds it to the eGPU with `DiInstallDevice`.
3. If the eGPU then reports Code 43, sets `RM1774520` (DWORD 1) in its driver key and
   restarts the device.
4. Checks the internal Spark and NPU are still healthy and that `nvidia-smi` lists the eGPU.
   If a previously healthy sibling disappears or changes problem code or INF, the
   error identifies the device and its before/after state.

Every change first saves `state.json` plus registry exports for Restore.

Inspect, Install, and Auto report the internal GPU's published and original
driver-store INF paths. They warn about a different eGPU package or a configured
`nvlddmkm` service path outside the internal GPU's package. This is advisory:
the service registry path does not prove which driver image is currently loaded,
and no package is removed or service setting changed.

## Restart, stop, start

From an elevated PowerShell (each supports `-WhatIf` and `-InstanceId`):

```powershell
# Restart the eGPU, e.g. when it boots at Code 43 although already bound; then verify it.
.\Configure-SparkEgpu.ps1 -Mode Restart

# Disable the eGPU. It stays disabled across reboots and automation leaves it alone.
.\Configure-SparkEgpu.ps1 -Mode Stop

# Re-enable a stopped eGPU, then verify it.
.\Configure-SparkEgpu.ps1 -Mode Start
```

Shutting down Windows before unplugging the eGPU or powering off its enclosure remains
the recommended path. Hot-unplug after `Stop` worked once (RTX 3090, driver 621.14):
the cable was pulled with the eGPU disabled, the internal Spark stayed at Code 0, and
after replugging into the same USB4 port the device returned with the same instance ID,
still disabled (Code 22) and ignored by automation, and `Start` brought it back healthy.
That single test does not establish that hot-removal is safe. Unplugging an eGPU that
is still enabled has not been tested. To try it: save your work, run Stop, unplug the
cable only, check with Inspect, replug into the same port, then run Start.

## Optional mise tasks

With [mise](https://mise.jdx.dev) installed, `mise tasks ls` lists every action in
`mise.toml` and `mise run <task>` runs the matching PowerShell command above
(`inspect`, `install`, `restart`, `stop`, `start`, `restore`, `automation-auto`,
`automation-prompt`, `automation-remove`, `test`). Arguments after `--` are passed
through, e.g. `mise run restart -- -WhatIf` or
`mise run restore -- -BackupPath <state.json>`. Tasks that change devices or the
scheduled task need an elevated terminal. mise is not required.

## Automation

Each USB4 port gives the eGPU a new device instance, so moving ports or reinstalling
can leave it on the Microsoft Basic Display Adapter again. The scheduled task fixes
that on connect. Install it from an elevated PowerShell, picking one mode:

```powershell
# Prompt: asks the logged-on user, then requests administrator approval (UAC).
.\Install-SparkEgpuAutomation.ps1 -Trigger Prompt

# Automatic: runs as SYSTEM, binds without asking.
.\Install-SparkEgpuAutomation.ps1 -Trigger Automatic -AcceptUnsupportedBinding

# Remove the task and installed scripts (backups and logs are kept).
.\Install-SparkEgpuAutomation.ps1 -Uninstall
```

- The scripts are copied to `%ProgramFiles%\SparkEgpu`, so the task never runs a
  user-writable file. Re-run the installer after editing the scripts.
- Triggers: Kernel-PnP configuration events 400 (device configured) and 411 (problem
  starting) for Display-class devices only, plus boot (Automatic) or logon (Prompt).
- Automation binds a given device instance to a given Spark driver package **once**.
  The result is recorded in `%ProgramData%\SparkEgpu\bind-history.json`, so a failed
  bind is not retried on every reconnect and a Restore is not undone. A driver update
  (new package) allows one new attempt. To retry by hand, run
  `.\Configure-SparkEgpu.ps1 -Mode Install -AcceptUnsupportedBinding`.
  History records each attempt's result (for example `Failed`, `Succeeded`,
  `Restored`); any recorded result blocks another automatic bind for that
  device/package. See [Logs and backups](#logs-and-backups).
- An eGPU working on a different NVIDIA package is left alone and logged; it may
  be older, newer, or another OEM's package. Run a manual Install to move it to
  the internal GPU's current package.
- Code 12 (PCIe resource allocation, seen on the RTX 5090) has no automatic fix.
- A bound eGPU that reports Code 43 with `RM1774520=1` already set is restarted
  **once per device per boot** (recorded in `bind-history.json` as
  `<id>|restart|<boot time>`). If Code 43 persists, later runs that boot leave it
  alone: shut down Windows, power-cycle the enclosure, then boot.
- A disabled eGPU (Code 22, from `-Mode Stop`) is never bound or restarted.

If the Automatic task does not run on your system (for example because Group Policy
enforces `AllSigned`, visible in the log as "is not digitally signed"), sign the
scripts or use Prompt mode.

## Restore

Each change writes `%ProgramData%\SparkEgpu\Backups\<time>-<mode>-<id>\state.json`.
Restore only accepts backups from that folder.

```powershell
.\Configure-SparkEgpu.ps1 -Mode Restore -BackupPath "$env:ProgramData\SparkEgpu\Backups\<run>\state.json" -WhatIf
.\Configure-SparkEgpu.ps1 -Mode Restore -BackupPath "$env:ProgramData\SparkEgpu\Backups\<run>\state.json"
```

- The backup whose `state.json` has `"Rebind": true` is the one that restores the
  driver the eGPU had before binding (usually the Microsoft Basic Display Adapter,
  which reports Code 10 for these cards: restoring it is not a working-GPU fix).
- Restore needs the eGPU on the same USB4 port as the backup.
- If Windows asks for a reboot, reboot and run the same Restore command again.
- After a Restore, automation will not bind that device to the same package again.

## Game GPU preference

Once bound, the eGPU also shows as "NVIDIA RTX Spark N1X", so Windows Settings cannot
tell the two GPUs apart by name. Set the preference by hardware ID instead:

```powershell
.\Set-EgpuGamePreference.ps1 -ExePath 'C:\Games\Cyberpunk 2077\bin\x64\Cyberpunk2077.exe' -WhatIf
.\Set-EgpuGamePreference.ps1 -ExePath 'C:\Games\Cyberpunk 2077\bin\x64\Cyberpunk2077.exe'
```

This writes `SpecificAdapter=<VEN>&<DEV>&<SUBSYS>` (for example `10DE&2204&38841462`)
into `HKCU\Software\Microsoft\DirectX\UserGpuPreferences`, keeping other settings in
that value. No administrator rights are needed. Fully exit and relaunch the game.

An existing `GpuPreference` is kept. If the game was already set to Power saving
(`GpuPreference=1`) or High performance (`2`) in Windows Settings, `SpecificAdapter`
may be ignored: set the game back to "Let Windows decide" (or delete its value), then
run the helper again. The helper sets a preference; to see which GPU a running game
actually uses, watch the `sm` column per GPU (index from `nvidia-smi -L`):

```powershell
nvidia-smi dmon -s u
```

## Logs and backups

| Path | Contents |
|---|---|
| `%ProgramData%\SparkEgpu\Backups` | `state.json` and registry exports per change |
| `%ProgramData%\SparkEgpu\Logs` | `auto-<date>.log` transcripts (30 days) |
| `%ProgramData%\SparkEgpu\bind-history.json` | One entry per device instance and driver package, plus one per automatic Code 43 restart per boot. Results: `Started`, `Bound` (SetupAPI returned successfully), `RebootRequired`, `Failed` (bind did not return successfully), `VerificationFailed` (bind returned but later configuration/checks failed), `Succeeded`, `Restored` (rollback). Existing entries are not reclassified |
| `%LOCALAPPDATA%\SparkEgpu\Logs` | Prompt mode transcripts |
| `%LOCALAPPDATA%\SparkEgpu\Backups` | `UserGpuPreferences` exports from the game helper |

`%ProgramData%\SparkEgpu` is writable only by SYSTEM and Administrators.

## Regression checks

Run the isolated, hardware-free configuration-flow tests in a fresh process:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Configure-SparkEgpu.Tests.ps1
```

These cover bind failures, reboot requests, sibling disappearance/problem/package
changes, NVIDIA enumeration failure, successful verification, the once-per-boot
automatic Code 43 restart (success and failure), and leaving a disabled device alone,
including history round-tripping and the per-device/package automatic retry guard.
Live inspection does not establish CUDA, graphics, or safe hot-removal support.

## Reporting results

Open a GitHub issue or post in the
[Level1Techs thread](https://forum.level1techs.com/t/rtx-egpus-working-on-rtx-spark-hp-omnibook/259662) with:

- Laptop model and BIOS version
- Dock/enclosure and connection (USB4/Thunderbolt port)
- eGPU model and hardware ID (`PCI\VEN_10DE&DEV_xxxx&SUBSYS_xxxxxxxx`)
- NVIDIA driver version
- Output of `.\Configure-SparkEgpu.ps1` (Inspect)
- The relevant lines from `%ProgramData%\SparkEgpu\Logs\auto-<date>.log`

## Credits

- [RTX eGPUs working on RTX Spark (HP OmniBook)](https://forum.level1techs.com/t/rtx-egpus-working-on-rtx-spark-hp-omnibook/259662), Level1Techs forum
- Reddit `/r/eGPU` post [1xekn5m](https://www.reddit.com/r/eGPU/comments/1xekn5m/)
- [AleCyriaco/nvidia-error43-fix](https://github.com/AleCyriaco/nvidia-error43-fix)
- [DiInstallDevice](https://learn.microsoft.com/windows/win32/api/newdev/nf-newdev-diinstalldevice) (Microsoft docs)

## License

MIT; see [LICENSE](LICENSE).

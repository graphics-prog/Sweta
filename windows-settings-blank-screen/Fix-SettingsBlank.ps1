<#
.SYNOPSIS
    Guided, step-by-step repair for "Windows Settings opens as a blank / white window".

.DESCRIPTION
    Runs the safe repairs from README.md one at a time, and after each one opens
    Settings and asks whether it is fixed. It stops as soon as Settings works.

      Step 0  Read-only diagnostic report (Diagnose-SettingsBlank.ps1)
      Step 1  Create a System Restore point
      Step 2  Reset the Settings app's own cached data (current user only)
      Step 3  Re-register the Settings app package
      Step 4  Repair the Windows component store (DISM /RestoreHealth)
      Step 5  Repair protected system files (sfc /scannow)
      Step 6  Offer a restart (only if you say yes)

    It does NOT delete personal files, uninstall apps, reset Windows, edit the
    registry, uninstall updates or touch antivirus/security settings. Every step
    asks before it runs and can be skipped.

    Needs administrator rights. The easiest way to start it is to double-click
    Fix-Settings.cmd in the same folder.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$desktop = [Environment]::GetFolderPath('Desktop')
$log = Join-Path $desktop ('SettingsFix_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
Start-Transcript -Path $log -Append | Out-Null

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
}

function Confirm-Yes([string]$Question) {
    while ($true) {
        $a = (Read-Host "$Question [Y/N]").Trim().ToUpper()
        if ($a -eq 'Y') { return $true }
        if ($a -eq 'N') { return $false }
    }
}

function Stop-Settings {
    Get-Process -Name SystemSettings -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Test-SettingsFixed {
    Stop-Settings
    Write-Host ''
    Write-Host 'Opening Windows Settings now. Look at it carefully...' -ForegroundColor Yellow
    Start-Process 'ms-settings:'
    Start-Sleep -Seconds 5
    $ok = Confirm-Yes 'Does Settings now show its categories (System, Apps, Windows Update...)?'
    if ($ok) {
        Write-Host ''
        Write-Host 'Settings is working again. Stopping here - no further changes needed.' -ForegroundColor Green
        Write-Host 'Please also open System > Display and Windows Update to make sure inner pages work,'
        Write-Host 'and restart the PC once to confirm the fix stays.'
    }
    return $ok
}

function Finish {
    Write-Host ''
    Write-Host "A log of everything done was saved to: $log" -ForegroundColor Cyan
    Stop-Transcript | Out-Null
    Read-Host 'Press Enter to close this window'
    exit
}

# ---------------------------------------------------------------- pre-checks
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'This needs administrator rights. Please start it with Fix-Settings.cmd and click "Yes" on the prompt.' -ForegroundColor Red
    Finish
}

# Per-user repairs (Step 2) must run as the person who is signed in. If they typed a
# DIFFERENT admin account's password at the UAC prompt, skip the per-user step.
$consoleUser = (Get-CimInstance Win32_ComputerSystem).UserName
$sameUser = (-not $consoleUser) -or ($consoleUser -ieq $identity.Name)

Write-Host ''
Write-Host 'Windows Settings blank-screen repair' -ForegroundColor Green
Write-Host 'Nothing will be deleted. Each step asks you first. You can answer N to skip any step.'
Write-Host 'Please save your work and close other programs before continuing.'
if (-not (Confirm-Yes 'Start?')) { Finish }

# ---------------------------------------------------------------- Step 0
Write-Step 'Step 0 of 6 - Diagnostic report (read-only)'
$diag = Join-Path $here 'Diagnose-SettingsBlank.ps1'
if (Test-Path $diag) {
    & $diag
    Write-Host ''
    Write-Host 'Read the SUMMARY above. The diagnostic report is also on your Desktop.' -ForegroundColor Yellow
    Read-Host 'Press Enter to continue with the repairs'
} else {
    Write-Host "Diagnose-SettingsBlank.ps1 not found next to this script - skipping." -ForegroundColor Yellow
}

if (Test-SettingsFixed) { Finish }

# ---------------------------------------------------------------- Step 1
Write-Step 'Step 1 of 6 - Create a System Restore point (safety net)'
if (Confirm-Yes 'Create a restore point now? (recommended)') {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Checkpoint-Computer -Description 'Before Settings blank-screen repair' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Host 'Restore point created.' -ForegroundColor Green
    } catch {
        Write-Host "Could not create a restore point: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '(If it says one was created recently, that is fine.)'
        if (-not (Confirm-Yes 'Continue without a new restore point?')) { Finish }
    }
}

# ---------------------------------------------------------------- Step 2
Write-Step 'Step 2 of 6 - Reset the Settings app data (your files are not touched)'
if (-not $sameUser) {
    Write-Host "Skipped: this window runs as $($identity.Name) but $consoleUser is signed in." -ForegroundColor Yellow
    Write-Host 'To do this step, open a normal (not admin) PowerShell and run:'
    Write-Host '    Get-AppxPackage windows.immersivecontrolpanel | Reset-AppxPackage'
} elseif (-not (Get-Command Reset-AppxPackage -ErrorAction SilentlyContinue)) {
    Write-Host 'Skipped: this Windows version does not have Reset-AppxPackage.' -ForegroundColor Yellow
} elseif (Confirm-Yes 'Reset the Settings app data now?') {
    Stop-Settings
    try {
        Get-AppxPackage windows.immersivecontrolpanel | Reset-AppxPackage -ErrorAction Stop
        Write-Host 'Settings app data reset.' -ForegroundColor Green
    } catch {
        Write-Host "Reset failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    if (Test-SettingsFixed) { Finish }
}

# ---------------------------------------------------------------- Step 3
Write-Step 'Step 3 of 6 - Re-register the Settings app'
if (Confirm-Yes 'Re-register the Settings app now?') {
    Stop-Settings
    $pkgs = @(Get-AppxPackage -AllUsers -Name windows.immersivecontrolpanel)
    if ($pkgs.Count -eq 0) {
        Write-Host 'Settings package not found - Step 4 and 5 will restore it.' -ForegroundColor Yellow
    }
    foreach ($p in $pkgs) {
        $manifest = Join-Path $p.InstallLocation 'AppxManifest.xml'
        try {
            Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
            Write-Host "Re-registered $($p.PackageFullName)" -ForegroundColor Green
        } catch {
            Write-Host "Re-register failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if (Test-SettingsFixed) { Finish }
}

# ---------------------------------------------------------------- Step 4
Write-Step 'Step 4 of 6 - Repair Windows component store (DISM)'
Write-Host 'This needs the internet and can take 10-30 minutes. It may look stuck at a percentage - that is normal.'
$dismOk = $false
if (Confirm-Yes 'Run DISM /RestoreHealth now?') {
    & dism.exe /Online /Cleanup-Image /RestoreHealth
    $dismCode = $LASTEXITCODE
    if ($dismCode -eq 0) {
        $dismOk = $true
        Write-Host 'DISM finished successfully.' -ForegroundColor Green
    } else {
        Write-Host "DISM ended with code $dismCode. Note this number - it tells us what to do next." -ForegroundColor Yellow
        Write-Host '(0x800f081f = repair source not found; a Windows ISO is needed. Ask for help.)'
    }
}

# ---------------------------------------------------------------- Step 5
Write-Step 'Step 5 of 6 - Repair protected system files (SFC)'
Write-Host 'This takes 10-20 minutes. Do not close this window.'
$sfcRan = $false
if (Confirm-Yes 'Run sfc /scannow now?') {
    & sfc.exe /scannow
    $sfcRan = $true
    $cbs = Join-Path $env:windir 'Logs\CBS\CBS.log'
    $last = Select-String -Path $cbs -Pattern 'Verify complete|Repair complete|could not repair|Cannot repair' -ErrorAction SilentlyContinue |
        Select-Object -Last 3
    if ($last) {
        Write-Host 'Last SFC results from CBS.log:'
        $last | ForEach-Object { Write-Host "  $($_.Line.Trim())" }
    }
}

if (Test-SettingsFixed) { Finish }

# ---------------------------------------------------------------- Step 6
Write-Step 'Step 6 of 6 - Restart'
if ($dismOk -or $sfcRan) {
    Write-Host 'DISM/SFC repairs often only take effect after a restart.'
} else {
    Write-Host 'A restart finishes any half-installed Windows updates.'
}
Write-Host 'After the restart, press Win + I and check whether Settings shows its categories.'
if (Confirm-Yes 'Restart the PC now? (save your work first)') {
    Stop-Transcript | Out-Null
    Restart-Computer
    exit
}

Write-Host ''
Write-Host 'If Settings is still blank after a restart, the cause is probably one of:' -ForegroundColor Yellow
Write-Host '  graphics driver, fonts, a Start-menu/theme tool, a policy, or your user profile.'
Write-Host '  Send the SettingsDiag_*.txt report from your Desktop and we will continue with the next steps in README.md.'
Finish

<#
.SYNOPSIS
    Read-only diagnostics for "Windows Settings opens as a blank / white window".

.DESCRIPTION
    This script ONLY READS information. It does not repair, delete, re-register,
    restart, or change anything on the PC.

    It checks:
      - Windows version, build, uptime, free disk space and memory
      - The Settings app package (windows.immersivecontrolpanel) and SystemSettings.exe
      - Services the Settings app depends on (AppX, State Repository, licensing)
      - Policies that hide or block Settings pages
      - Recent crash / hang / app-model errors in the event logs
      - Graphics adapter and driver
      - Segoe UI / icon fonts and font substitutions (a common cause of blank XAML windows)
      - Third-party shell / Start menu customizers
      - Recent updates and pending reboots
      - Component store health (DISM /CheckHealth, read-only, admin only)
      - The current user profile and the Settings app's per-user data folder

    Run it in Windows PowerShell 5.1 (powershell.exe), ideally "Run as administrator".
    It still works without admin; a few checks are just skipped.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Diagnose-SettingsBlank.ps1

    "-ExecutionPolicy Bypass" applies only to this one run; it does not change
    your system's execution policy.
#>
[CmdletBinding()]
param(
    [string]$OutFile = (Join-Path ([Environment]::GetFolderPath('Desktop')) ('SettingsDiag_{0:yyyyMMdd_HHmmss}.txt' -f (Get-Date)))
)

$ErrorActionPreference = 'Continue'
$findings = New-Object System.Collections.Generic.List[string]
$since = (Get-Date).AddDays(-14)

function Write-Section([string]$Title) { ''; "==== $Title ====" }
function Add-Finding([string]$Message) { $findings.Add($Message); "  [!] $Message" }
function Get-RegValue([string]$Path, [string]$Name) {
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$report = & {
    "Windows Settings blank-screen diagnostics"
    "Generated : $(Get-Date)"
    "Computer  : $env:COMPUTERNAME   User: $env:USERDOMAIN\$env:USERNAME"
    "Elevated  : $isAdmin"
    "PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    if ($PSVersionTable.PSEdition -eq 'Core') {
        "  NOTE: Run this in Windows PowerShell 5.1 (powershell.exe). AppX checks may fail in PowerShell 7."
    }
    if (-not $isAdmin) {
        "  NOTE: Not elevated. All-users package info, DISM CheckHealth and some logs are skipped."
    }

    # ------------------------------------------------------------------ 1. OS
    Write-Section '1. Windows version and system resources'
    $cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    $ubr = Get-RegValue $cv 'UBR'
    $displayVersion = Get-RegValue $cv 'DisplayVersion'
    $productName = if ($build -ge 22000) { $os.Caption -replace 'Windows 10', 'Windows 11' } else { $os.Caption }
    "  Edition       : $productName"
    "  Version       : $displayVersion  (build $build.$ubr)  $($os.OSArchitecture)"
    "  Last boot     : $($os.LastBootUpTime)"
    $freeMemGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $totalMemGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    "  Memory free   : $freeMemGB GB of $totalMemGB GB"
    $sysDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
    $freeGB = [math]::Round($sysDrive.FreeSpace / 1GB, 2)
    "  $($env:SystemDrive) free      : $freeGB GB of $([math]::Round($sysDrive.Size / 1GB, 2)) GB"
    if ($freeGB -lt 10) { Add-Finding "Low free space on $($env:SystemDrive) ($freeGB GB). Repairs (DISM/updates) need room; app data writes can fail." }
    if ($freeMemGB -lt 0.5) { Add-Finding "Very low free memory ($freeMemGB GB)." }

    # ------------------------------------------------------------------ 2. Settings package
    Write-Section '2. Settings app package (windows.immersivecontrolpanel)'
    $pkg = $null
    try {
        $pkg = Get-AppxPackage -Name 'windows.immersivecontrolpanel' -ErrorAction Stop
    } catch {
        Add-Finding "Get-AppxPackage failed: $($_.Exception.Message)"
    }
    if (-not $pkg) {
        Add-Finding 'Settings package is NOT registered for the current user.'
    } else {
        foreach ($p in @($pkg)) {
            "  Name          : $($p.Name)"
            "  FullName      : $($p.PackageFullName)"
            "  Version       : $($p.Version)"
            "  Status        : $($p.Status)"
            "  InstallLoc    : $($p.InstallLocation)"
            if ("$($p.Status)" -and "$($p.Status)" -ne 'Ok') {
                Add-Finding "Settings package status is '$($p.Status)' (expected 'Ok')."
            }
            if ($p.InstallLocation -and -not (Test-Path (Join-Path $p.InstallLocation 'AppxManifest.xml'))) {
                Add-Finding "AppxManifest.xml missing from $($p.InstallLocation)."
            }
        }
    }
    if ($isAdmin) {
        try {
            $all = Get-AppxPackage -AllUsers -Name 'windows.immersivecontrolpanel' -ErrorAction Stop
            foreach ($p in @($all)) {
                foreach ($u in $p.PackageUserInformation) {
                    "  All users     : $($u.UserSecurityId.Username) -> $($u.InstallState)"
                }
            }
        } catch { "  (All-users query failed: $($_.Exception.Message))" }
    }

    $exe = Join-Path $env:windir 'ImmersiveControlPanel\SystemSettings.exe'
    if (Test-Path $exe) {
        $fi = Get-Item $exe
        "  SystemSettings: $exe  (file version $($fi.VersionInfo.FileVersion), $($fi.Length) bytes)"
    } else {
        Add-Finding "$exe is missing."
    }

    "  Related shell packages:"
    $related = 'Microsoft.Windows.ShellExperienceHost', 'MicrosoftWindows.Client.CBS',
               'MicrosoftWindows.Client.Core', 'Microsoft.UI.Xaml.*', 'Microsoft.VCLibs.*'
    foreach ($name in $related) {
        try {
            foreach ($rp in @(Get-AppxPackage -Name $name -ErrorAction Stop)) {
                "    $($rp.PackageFullName)  [Status: $($rp.Status)]"
                if ("$($rp.Status)" -and "$($rp.Status)" -ne 'Ok') {
                    Add-Finding "Package $($rp.Name) status is '$($rp.Status)'."
                }
            }
        } catch { }
    }

    # ------------------------------------------------------------------ 3. Processes
    Write-Section '3. Settings / Explorer processes right now'
    foreach ($name in 'SystemSettings', 'ApplicationFrameHost', 'explorer', 'StartMenuExperienceHost') {
        $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        if ($procs.Count -eq 0) {
            "  $name : not running"
        } else {
            foreach ($pr in $procs) {
                "  $name : PID $($pr.Id), Responding=$($pr.Responding), WorkingSet=$([math]::Round($pr.WorkingSet64 / 1MB)) MB"
                if (-not $pr.Responding) { Add-Finding "$name (PID $($pr.Id)) is not responding." }
            }
        }
    }
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
        Add-Finding 'explorer.exe is not running.'
    }

    # ------------------------------------------------------------------ 4. Services
    Write-Section '4. Services used by Settings and Store-style apps'
    $svcNames = 'AppXSvc', 'StateRepository', 'ClipSVC', 'LicenseManager', 'TokenBroker',
                'camsvc', 'wuauserv', 'BITS', 'CryptSvc', 'TrustedInstaller', 'Themes', 'FontCache'
    $mustNotBeDisabled = 'AppXSvc', 'StateRepository', 'ClipSVC', 'LicenseManager', 'TokenBroker', 'FontCache', 'Themes'
    foreach ($n in $svcNames) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $s) { "  {0,-18} not present" -f $n; continue }
        "  {0,-18} {1,-8} StartType={2}  ({3})" -f $s.Name, $s.Status, $s.StartType, $s.DisplayName
        if ($mustNotBeDisabled -contains $n -and "$($s.StartType)" -eq 'Disabled') {
            Add-Finding "Service $n ($($s.DisplayName)) is DISABLED. Settings/UWP apps depend on it."
        }
    }

    # ------------------------------------------------------------------ 5. Policies
    Write-Section '5. Policies that hide or block Settings'
    $policyChecks = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'SettingsPageVisibility' },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'SettingsPageVisibility' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoControlPanel' },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoControlPanel' }
    )
    $anyPolicy = $false
    foreach ($c in $policyChecks) {
        $v = Get-RegValue $c.Path $c.Name
        if ($null -ne $v) {
            $anyPolicy = $true
            "  $($c.Path)\$($c.Name) = $v"
            if ($c.Name -eq 'SettingsPageVisibility') {
                Add-Finding "SettingsPageVisibility policy is set to '$v'. 'showonly:' / 'hide:' can make Settings look empty."
            } elseif ("$v" -ne '0') {
                Add-Finding "NoControlPanel policy is set ($($c.Path)). This blocks Control Panel and Settings."
            }
        }
    }
    if (-not $anyPolicy) { '  No Settings-related policies found.' }

    # ------------------------------------------------------------------ 6. Event logs
    Write-Section '6. Event log errors (last 14 days)'
    try {
        $crashes = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1001, 1002; StartTime = $since } -ErrorAction Stop |
            Where-Object { $_.Message -match 'SystemSettings|ImmersiveControlPanel|ApplicationFrameHost' } |
            Select-Object -First 10
        if ($crashes) {
            Add-Finding "$(@($crashes).Count) crash/hang event(s) for SystemSettings.exe or related in the last 14 days."
            foreach ($e in $crashes) {
                $first = ($e.Message -split "`r?`n" | Where-Object { $_ } | Select-Object -First 4) -join ' | '
                "  $($e.TimeCreated)  ID $($e.Id)  $first"
            }
        } else { '  No Application crash/hang events for Settings.' }
    } catch { "  Application log: no matching events ($($_.Exception.Message))" }

    $opLogs = 'Microsoft-Windows-AppModel-Runtime/Admin',
              'Microsoft-Windows-AppXDeploymentServer/Operational',
              'Microsoft-Windows-TWinUI/Operational',
              'Microsoft-Windows-AppReadiness/Admin'
    foreach ($log in $opLogs) {
        try {
            $evts = Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 1, 2; StartTime = $since } -MaxEvents 200 -ErrorAction Stop |
                Where-Object { $_.Message -match 'immersivecontrolpanel|SystemSettings' } |
                Select-Object -First 5
            if ($evts) {
                Add-Finding "Errors mentioning the Settings app in $log."
                foreach ($e in $evts) {
                    $first = ($e.Message -split "`r?`n" | Where-Object { $_ } | Select-Object -First 2) -join ' | '
                    "  [$log] $($e.TimeCreated)  ID $($e.Id)  $first"
                }
            } else { "  [$log] no Settings-related errors." }
        } catch { "  [$log] no matching events or not readable." }
    }

    # ------------------------------------------------------------------ 7. Graphics
    Write-Section '7. Graphics adapter and driver'
    foreach ($gpu in Get-CimInstance Win32_VideoController) {
        $drvDate = if ($gpu.DriverDate) { ([datetime]$gpu.DriverDate).ToString('yyyy-MM-dd') } else { 'unknown' }
        "  $($gpu.Name)  driver $($gpu.DriverVersion) ($drvDate)  status=$($gpu.Status)  $($gpu.CurrentHorizontalResolution)x$($gpu.CurrentVerticalResolution)"
        if ($gpu.Name -match 'Microsoft Basic Display') {
            Add-Finding 'Using "Microsoft Basic Display Adapter" - no proper GPU driver installed. XAML windows can render blank.'
        }
        if ($gpu.Status -and $gpu.Status -ne 'OK') { Add-Finding "GPU '$($gpu.Name)' reports status '$($gpu.Status)'." }
    }

    # ------------------------------------------------------------------ 8. Fonts
    Write-Section '8. System fonts used by Settings'
    $fontDir = Join-Path $env:windir 'Fonts'
    $iconFont = if ($build -ge 22000) { 'SegoeIcons.ttf' } else { 'segmdl2.ttf' }
    foreach ($f in 'segoeui.ttf', 'segoeuib.ttf', 'seguisym.ttf', $iconFont) {
        if (Test-Path (Join-Path $fontDir $f)) { "  $f present" }
        else { Add-Finding "Font file $f is missing from $fontDir." }
    }
    $fontReg = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    $segoeReg = Get-RegValue $fontReg 'Segoe UI (TrueType)'
    if ($segoeReg) { "  Registry 'Segoe UI (TrueType)' = $segoeReg" }
    else { Add-Finding "Registry entry 'Segoe UI (TrueType)' is missing or blank (often from font-changing tweaks)." }
    $subst = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes' 'Segoe UI'
    if ($subst) { Add-Finding "Segoe UI is substituted with '$subst' (system font changed by a tweak/tool)." }
    else { '  No Segoe UI font substitution.' }

    # ------------------------------------------------------------------ 9. Shell customizers
    Write-Section '9. Third-party shell / theme customizers'
    $uninstallKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $pattern = 'StartAllBack|StartIsBack|ExplorerPatcher|Windhawk|Start11|Stardock|WindowBlinds|Open-Shell|Classic Shell|UltraUXThemePatcher|SecureUxTheme|Winaero|TranslucentTB|Rainmeter|Mica For Everyone'
    $hits = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match $pattern } |
        Select-Object -ExpandProperty DisplayName -Unique
    if ($hits) {
        foreach ($h in $hits) { "  Installed: $h" }
        Add-Finding "Shell/theme customizer(s) installed: $($hits -join ', '). These can break Settings rendering."
    } else { '  None of the common customizers found.' }
    $theme = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes' 'CurrentTheme'
    "  Current theme : $theme"
    $hc = Get-RegValue 'HKCU:\Control Panel\Accessibility\HighContrast' 'Flags'
    "  HighContrast flags: $hc"

    # ------------------------------------------------------------------ 10. Updates
    Write-Section '10. Windows Update and pending reboot'
    try {
        Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } |
            Sort-Object InstalledOn -Descending | Select-Object -First 8 |
            ForEach-Object { "  $($_.HotFixID)  $($_.Description)  installed $($_.InstalledOn.ToString('yyyy-MM-dd'))" }
    } catch { "  Could not list hotfixes: $($_.Exception.Message)" }
    $pending = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending += 'CBS' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending += 'Windows Update' }
    if (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations') { $pending += 'PendingFileRename' }
    if ($pending) { Add-Finding "A restart is pending ($($pending -join ', ')). Half-installed updates commonly cause blank Settings." }
    else { '  No pending reboot detected.' }

    # ------------------------------------------------------------------ 11. Component store
    Write-Section '11. Component store health (DISM /CheckHealth, read-only)'
    if ($isAdmin) {
        $dism = & dism.exe /Online /Cleanup-Image /CheckHealth 2>&1
        $dism | Where-Object { $_ -match '\S' } | Select-Object -Last 4 | ForEach-Object { "  $_" }
        $dismText = $dism -join ' '
        if ($dismText -match 'repairable') { Add-Finding 'DISM reports the component store is CORRUPTED but repairable.' }
        elseif ($dismText -match 'not repairable') { Add-Finding 'DISM reports the component store is NOT repairable.' }
    } else { '  Skipped (needs administrator).' }
    $cbsLog = Join-Path $env:windir 'Logs\CBS\CBS.log'
    if (Test-Path $cbsLog) {
        $sfcLast = Select-String -Path $cbsLog -Pattern 'Verify complete|Repair complete|could not repair|Cannot repair' -ErrorAction SilentlyContinue |
            Select-Object -Last 3
        if ($sfcLast) { '  Last SFC lines in CBS.log:'; $sfcLast | ForEach-Object { "    $($_.Line.Trim())" } }
    }

    # ------------------------------------------------------------------ 12. Profile
    Write-Section '12. User profile'
    "  Profile path  : $env:USERPROFILE"
    if ($env:USERPROFILE -match '\\TEMP(\.|$)') { Add-Finding 'You are signed in with a TEMPORARY profile. The real profile failed to load.' }
    try {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $state = Get-RegValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" 'State'
        "  Profile state : $state  (0 = normal)"
        if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid.bak") {
            Add-Finding 'A ".bak" ProfileList entry exists for your account - profile corruption is likely.'
        }
    } catch { }
    $pkgData = Join-Path $env:LOCALAPPDATA 'Packages\windows.immersivecontrolpanel_cw5n1h2txyewy'
    if (Test-Path $pkgData) {
        $size = (Get-ChildItem $pkgData -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        "  Settings data : $pkgData  ($([math]::Round($size / 1MB, 2)) MB)"
    } else {
        Add-Finding "Settings per-user data folder is missing: $pkgData"
    }
    $local = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object Enabled
    if ($local) { "  Enabled local accounts: $(($local | Select-Object -ExpandProperty Name) -join ', ')" }
} 2>&1 | Out-String -Width 220

$summary = @('', '==== SUMMARY: possible causes found ====')
if ($findings.Count -eq 0) {
    $summary += '  No obvious problems detected. Continue with the repair guide (Step 1 onwards).'
} else {
    $i = 1
    foreach ($f in $findings) { $summary += "  $i. $f"; $i++ }
}
$full = $report + ($summary -join [Environment]::NewLine)

$full | Out-File -FilePath $OutFile -Encoding UTF8
$full
''
"Report saved to: $OutFile"
'Nothing was changed on this PC.'

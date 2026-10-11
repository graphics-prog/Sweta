# Fix: Windows Settings opens as a blank / white window

This guide is for Windows 10 and Windows 11. Work through it in order: **diagnose first, then apply one repair at a time and re-test Settings after each one.**

None of these steps deletes personal files, uninstalls apps, resets Windows or disables security software. Each step that needs administrator rights, a restart, or your approval says so.

---

## How Settings works (why it goes blank)

The Settings app is the **`SystemSettings.exe`** program, registered as the built-in app package **`windows.immersivecontrolpanel`**. It draws its window with the same XAML / GPU rendering engine as other modern Windows apps. You get an empty white or blank frame when the window opens but its content can't load or draw. The usual causes, most common first:

| # | Root cause | Typical clue |
|---|------------|--------------|
| A | Settings app **package registration or per-user app data is corrupted** | Package status isn't `Ok`, or AppModel/AppX errors in the event log |
| B | **Corrupted Windows system files or component store** (often after an interrupted update) | DISM says the store is "repairable", SFC finds errors, a restart is pending |
| C | **Half-installed update** waiting for a restart | Pending reboot detected |
| D | **Graphics driver** problem (XAML can't render) | "Microsoft Basic Display Adapter", an old or broken GPU driver, or other modern apps are also blank |
| E | **Font changes**: Segoe UI or the icon font is missing or substituted | Font findings in the report |
| F | **Third-party shell or theme tools** (StartAllBack, ExplorerPatcher, Windhawk, WindowBlinds, UxTheme patchers…) | Customizer findings in the report |
| G | **Policies** that hide all Settings pages (`SettingsPageVisibility`, `NoControlPanel`) | Policy findings in the report |
| H | Required **services are disabled** (AppX Deployment, State Repository, Client License…) | Service findings in the report |
| I | **Corrupted user profile** | Works in another account but not in yours; temporary profile |

---

## Easiest way: one double-click

1. Download this folder to your PC and keep all the files together.
2. Double-click **`Fix-Settings.cmd`** and click **Yes** on the administrator prompt.
3. Answer **Y** or **N** to each question.

It runs Steps 1–5 below for you, one at a time. After each repair it opens Settings and asks if it works now, and it stops as soon as you say **Y**. It never deletes files, uninstalls apps or edits the registry. Logs are saved to your Desktop.

If Settings is still blank afterwards, continue from **Step 6** below.

---

## Step 0: Quick checks (no admin, no risk)

1. **Restart the PC** (Start → Power → *Restart*, not *Shut down*). Fast Startup means "Shut down" doesn't clear a half-installed update. Then test Settings.
2. Press **Win + Ctrl + Shift + B**. This restarts the graphics driver: the screen flickers once. Then open Settings again.
3. Try opening a specific page directly. Press **Win + R** and run:
   ```
   ms-settings:display
   ```
   If individual pages open but the home page is blank, it's more likely a policy (cause G) or a page-specific bug than a broken app.
4. Check whether **other modern apps** (Calculator, Microsoft Store, Photos) are also blank. If they are, the problem is system-wide (causes B, D, E, F, H), not just Settings.

---

## Step 1: Run the read-only diagnostic

`Diagnose-SettingsBlank.ps1` (in this folder) **only reads** information; it changes nothing. It checks your Windows version and build, the Settings package, the services Settings needs, related policies, the event logs, the GPU driver, fonts, shell customizers, updates and pending reboots, component store health and your profile.

1. Copy `Diagnose-SettingsBlank.ps1` to your PC, for example to `C:\Temp\`.
2. Click Start, type **Windows PowerShell**, right-click it and choose **Run as administrator**. Admin is optional but gives a more complete report. Use *Windows PowerShell*, not *PowerShell 7*.
3. Run:
   ```powershell
   cd C:\Temp
   powershell.exe -ExecutionPolicy Bypass -File .\Diagnose-SettingsBlank.ps1
   ```
   `-ExecutionPolicy Bypass` applies to this single run only. It does not change your system policy.
4. The report is saved to your Desktop as `SettingsDiag_<date>.txt`. The **SUMMARY** at the bottom lists the likely causes.

Match the summary to the table above, then **start with the step for that cause**. If nothing is flagged, go in order from Step 2.

---

## Step 2: Restore point (safety net, admin)

Before changing anything, create a restore point. In an **admin** PowerShell:

```powershell
Enable-ComputerRestore -Drive "$env:SystemDrive\"
Checkpoint-Computer -Description "Before Settings blank-screen repair" -RestorePointType MODIFY_SETTINGS
```

If it says a restore point was created recently, that's fine; one already exists.

---

## Step 3: Reset the Settings app's own data (cause A, no admin)

This clears only the Settings app's cache and state for your account, the same as *Apps → Settings → Reset*. Your files and apps aren't touched. Run it in a normal (non-admin) Windows PowerShell:

```powershell
Get-AppxPackage windows.immersivecontrolpanel | Reset-AppxPackage
```

Then open Settings with **Win + I**.

`Reset-AppxPackage` only exists on newer Windows 10 builds and on Windows 11. If you get *"not recognized"*, skip to Step 4.

---

## Step 4: Re-register the Settings app (cause A, admin)

This re-registers the existing Settings package from its own manifest. Nothing is downloaded or removed. In an **admin** Windows PowerShell:

```powershell
Get-AppxPackage -AllUsers windows.immersivecontrolpanel |
    ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppxManifest.xml" -Verbose }
```

Red errors mentioning **0x80073D02** mean Settings was still open: close it and run the command again. Other errors usually point to system file corruption, so go to Step 5.

Test Settings again.

> Avoid the commonly posted command that re-registers **every** app package (`Get-AppxPackage -AllUsers | Foreach {Add-AppxPackage …}`). It's slow, throws hundreds of harmless-looking errors, and can disturb unrelated apps. Re-registering only Settings is enough.

---

## Step 5: Repair Windows system files (causes B and C, admin and a restart)

Run these in an **admin** Command Prompt or PowerShell, **in this order** (DISM repairs the source that SFC copies from):

```cmd
DISM /Online /Cleanup-Image /ScanHealth
DISM /Online /Cleanup-Image /RestoreHealth
sfc /scannow
```

- `ScanHealth` takes 5–15 minutes and only checks.
- `RestoreHealth` downloads clean components from Windows Update, so it needs the internet. It can look stuck at one percentage for a long time. That's normal; don't close it.
- `sfc /scannow` repairs protected system files, including the Settings files and fonts.

Read the SFC result:

| SFC message | Meaning |
|-------------|---------|
| *did not find any integrity violations* | System files are fine. Look at causes D–I. |
| *found corrupt files and successfully repaired them* | **Restart** and test Settings. |
| *found corrupt files but was unable to fix some of them* | Restart, run `sfc /scannow` again (up to 3 times). If it still fails, send me `C:\Windows\Logs\CBS\CBS.log`. |

**Restart is required** after repairs.

If `RestoreHealth` fails with **0x800f081f** (source not found), it needs a Windows ISO of the same version as a repair source. Tell me your version from the diagnostic report and I'll give you the exact command.

---

## Step 6: Graphics driver (cause D)

1. Press **Win + X → Device Manager → Display adapters**.
2. If it shows **Microsoft Basic Display Adapter**, install the proper driver from your PC maker or GPU maker (Intel, AMD or NVIDIA). Use their official download page or Windows Update → Optional updates.
3. If the problem started right after a driver update, right-click the adapter → **Properties → Driver → Roll Back Driver**.
4. Restart and test.

---

## Step 7: Fonts (cause E, admin)

If the report says Segoe UI is missing or substituted, a font-changer tool or registry tweak usually caused it.

- `sfc /scannow` (Step 5) restores missing **font files**.
- A **font substitution** (`FontSubstitutes\Segoe UI`) or a missing `Segoe UI (TrueType)` registry entry needs a registry fix. **I'll only give you that fix with your approval**, after you've shared the report lines and backed up the registry key.

---

## Step 8: Third-party shell / theme tools (cause F)

If the report lists StartAllBack, ExplorerPatcher, Windhawk, Start11, WindowBlinds, a UxTheme patcher or similar:

1. Turn the tool off, or reset it to defaults, using its own settings window or tray icon.
2. Restart Explorer: in an elevated or normal Command Prompt, run `taskkill /f /im explorer.exe & start explorer.exe`.
3. Test Settings. If it works, update the tool to its latest version; these tools often break after a Windows feature update. If an update doesn't help, uninstall the tool through Control Panel → *Programs and Features*.

---

## Step 9: Policies (cause G, your approval needed)

If the report shows `SettingsPageVisibility` or `NoControlPanel`:

- On a **work or school PC**, your IT department set these on purpose. Ask them, and don't change them yourself.
- On a **personal PC**, check Group Policy first (Pro edition): Win + R → `gpedit.msc` →
  *Computer Configuration → Administrative Templates → Control Panel → Settings Page Visibility*, and
  *User Configuration → Administrative Templates → Control Panel → Prohibit access to Control Panel and PC settings*.
  Set them to **Not Configured**, then run `gpupdate /force`.
- If they were set directly in the registry (Home edition, or a "tweak" tool), I'll walk you through backing up the key and removing that single value, **only with your permission**.

---

## Step 10: Services (cause H, admin)

If a service is flagged as **Disabled**, set it back to its Windows default. In an **admin** Command Prompt (the space after `start=` is required):

```cmd
sc config AppXSvc start= demand
sc config StateRepository start= demand
sc config ClipSVC start= demand
sc config LicenseManager start= demand
sc config TokenBroker start= demand
sc config FontCache start= auto
sc config Themes start= auto
```

Only run the lines for services the report flagged, then restart. ("demand" means Manual: Windows starts these services when they're needed.)

> Some services are protected and return *Access is denied*. If that happens, tell me and I'll give you the alternative (it needs your approval because it's a registry change).

---

## Step 11: Test with a new user account (cause I)

This shows whether the problem is in your profile. In an **admin** Command Prompt:

```cmd
net user TestUser * /add
```

It asks you to type a password twice. Sign out, sign in as **TestUser**, wait for setup to finish, then open Settings.

- **Works in TestUser** → your profile is the cause. Sign back into your account and run Steps 3–4 again. If that doesn't fix it, I'll help you move your data to a fresh profile safely. Nothing is deleted until you confirm everything is copied.
- **Also blank in TestUser** → the problem is system-wide. Go back to Steps 5–8.

Remove the test account afterwards with `net user TestUser /delete`. Its leftover folder in `C:\Users\TestUser` can be deleted by hand.

---

## Step 12: Windows Update (causes B and C)

- If a restart is pending, restart first.
- If Settings broke **right after** a specific update, tell me the KB number (it's in section 10 of the report). Uninstalling one update, for example `wusa /uninstall /kb:XXXXXXX`, needs your approval.
- Otherwise, installing the latest cumulative update usually helps. Since Settings is blank, start Windows Update from an admin prompt with:
  ```cmd
  usoclient StartInteractiveScan
  ```
  or use the **Windows Update Assistant** / **Microsoft Update Catalog**.

---

## Last resort: in-place repair upgrade (only with your approval)

If everything above fails, an **in-place repair upgrade** reinstalls Windows system files **while keeping your files, apps and settings**. It is *not* a reset. Run `setup.exe` from a Windows ISO of the **same edition and same or newer version** and choose **"Keep personal files and apps"**. On Windows 11 there's also *Settings → System → Recovery → Fix problems using Windows Update*, though Settings must be open to use it. Back up important files first anyway. **We won't do this without your explicit OK.**

---

## After any fix: verify

1. Press **Win + I**. The home page should show the category list with icons (System, Bluetooth & devices, Network & internet, Personalization, Apps, Accounts, Time & language, Gaming, Accessibility, Privacy & security, Windows Update).
2. Open at least **System → Display**, **Apps → Installed apps** and **Windows Update** to confirm the inner pages also draw correctly.
3. Restart once more and check again to make sure the fix sticks.

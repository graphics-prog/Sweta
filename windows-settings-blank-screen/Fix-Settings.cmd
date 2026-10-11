@echo off
rem Double-click this file to start the guided Settings repair.
rem It asks for administrator permission, then runs Fix-SettingsBlank.ps1 from this folder.
rem "-ExecutionPolicy Bypass" applies to this one run only; it does not change system settings.

set "SCRIPT=%~dp0Fix-SettingsBlank.ps1"
if not exist "%SCRIPT%" (
    echo Fix-SettingsBlank.ps1 was not found next to this file.
    echo Keep all files from the folder together and try again.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%SCRIPT%\"'"

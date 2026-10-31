@echo off
rem Opens the CAKE Switch window without a console window.
rem On Windows 11 the console is hosted by Windows Terminal, which ignores -WindowStyle Hidden,
rem so PowerShell is started through a headless conhost instead (no console window at all).
if exist "%SystemRoot%\System32\conhost.exe" (
    start "" "%SystemRoot%\System32\conhost.exe" --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0CakeSwitch.ps1" -Action Gui %*
) else (
    start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0CakeSwitch.ps1" -Action Gui %*
)

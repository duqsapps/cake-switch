@echo off
rem Opens the CAKE Switch window without a console window.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0CakeSwitch.ps1" -Action Gui %*

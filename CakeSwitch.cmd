@echo off
rem Command line: CakeSwitch.cmd -Action On, Off, Status, List or SetupKey  [-Device name] [-Router 192.168.1.1] [-Interface eth1]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CakeSwitch.ps1" %*
exit /b %ERRORLEVEL%

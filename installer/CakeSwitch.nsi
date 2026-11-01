; CAKE Switch installer (NSIS 3). Build:  makensis installer/CakeSwitch.nsi
; Installs into Program Files, adds a Start menu entry (optional desktop icon) and an uninstaller.
; The device list is kept per user in %APPDATA%\CAKE Switch (see CakeSwitch.installed below).

Unicode true
!include "MUI2.nsh"

; The version comes from $AppVersion in CakeSwitch.ps1 (override with -DVERSION=x.y.z).
!ifndef VERSION
  !searchparse /file "..\CakeSwitch.ps1" "$AppVersion = '" VERSION "'"
!endif
!define APPNAME "CAKE Switch"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\CAKE Switch"
; conhost --headless: start PowerShell without any console window.
!define LAUNCHER "$WINDIR\System32\conhost.exe"
!define LAUNCHARGS '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\CakeSwitch.ps1" -Action Gui'

Name "${APPNAME}"
OutFile "CakeSwitch-Setup-${VERSION}.exe"
InstallDir "$PROGRAMFILES64\${APPNAME}"
InstallDirRegKey HKLM "${UNINSTKEY}" "InstallLocation"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
BrandingText "${APPNAME} ${VERSION}"

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APPNAME}"
VIAddVersionKey "FileDescription" "${APPNAME} setup"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "CompanyName" "DuqsApps"
VIAddVersionKey "LegalCopyright" "Copyright (c) 2026 DuqsApps. MIT License."

!define MUI_ICON "cakeswitch.ico"
!define MUI_UNICON "cakeswitch.ico"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_TEXT "Start ${APPNAME}"
!define MUI_FINISHPAGE_RUN_FUNCTION StartApp

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "..\LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; Running copies keep the old code in memory; stop them first. (Their own command line contains
; CakeSwitch.ps1 too, hence the $PID check.)
!macro StopRunning
  nsExec::Exec `"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $$_.ProcessId -ne $$PID -and $$_.CommandLine -like '*CakeSwitch.ps1*' } | ForEach-Object { Stop-Process -Id $$_.ProcessId -Force -ErrorAction SilentlyContinue }"`
  Pop $0
!macroend

Function StartApp
  ; Through Explorer, so the app runs as the normal user and not elevated like this installer.
  Exec '"$WINDIR\explorer.exe" "$SMPROGRAMS\${APPNAME}.lnk"'
FunctionEnd

Section "${APPNAME}" SecApp
  SectionIn RO
  SetShellVarContext all
  !insertmacro StopRunning
  SetOutPath "$INSTDIR"
  File "..\CakeSwitch.ps1"
  File "..\CakeSwitch.cmd"
  File "..\CakeSwitch-GUI.cmd"
  File "..\README.md"
  File "..\LICENSE"
  File "..\CHANGELOG.md"
  File "..\cake-switch.example.json"
  File "cakeswitch.ico"
  ; Marker: tells CakeSwitch.ps1 to keep the device list in %APPDATA%\CAKE Switch.
  FileOpen $0 "$INSTDIR\CakeSwitch.installed" w
  FileWrite $0 "Installed by the CAKE Switch setup program. Device list: %APPDATA%\CAKE Switch\cake-switch.json$\r$\n"
  FileClose $0

  CreateShortcut "$SMPROGRAMS\${APPNAME}.lnk" "${LAUNCHER}" '${LAUNCHARGS}' "$INSTDIR\cakeswitch.ico" 0 SW_SHOWNORMAL "" "Switch SQM/CAKE on your OpenWrt devices"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNINSTKEY}" "Publisher" "DuqsApps"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\cakeswitch.ico"
  WriteRegStr HKLM "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINSTKEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "${UNINSTKEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoRepair" 1
  WriteRegDWORD HKLM "${UNINSTKEY}" "EstimatedSize" 100

  ; "Start with Windows" is set (again) by the section below only if it's ticked.
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${APPNAME}"
SectionEnd

Section "Start with Windows (in the tray)" SecAutostart
  ; Same entry as the app's "Start with Windows" checkbox, which can turn it off again.
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${APPNAME}" '"${LAUNCHER}" ${LAUNCHARGS} -Tray'
SectionEnd

Section /o "Desktop shortcut" SecDesktop
  SetShellVarContext all
  CreateShortcut "$DESKTOP\${APPNAME}.lnk" "${LAUNCHER}" '${LAUNCHARGS}' "$INSTDIR\cakeswitch.ico" 0 SW_SHOWNORMAL "" "Switch SQM/CAKE on your OpenWrt devices"
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecApp} "The app, a Start menu entry and the uninstaller."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop} "An icon on the desktop."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecAutostart} "Start CAKE Switch minimized to the tray when you sign in to Windows."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Section "Uninstall"
  SetShellVarContext all
  !insertmacro StopRunning
  Delete "$SMPROGRAMS\${APPNAME}.lnk"
  Delete "$DESKTOP\${APPNAME}.lnk"
  Delete "$INSTDIR\CakeSwitch.ps1"
  Delete "$INSTDIR\CakeSwitch.cmd"
  Delete "$INSTDIR\CakeSwitch-GUI.cmd"
  Delete "$INSTDIR\README.md"
  Delete "$INSTDIR\LICENSE"
  Delete "$INSTDIR\CHANGELOG.md"
  Delete "$INSTDIR\cake-switch.example.json"
  Delete "$INSTDIR\cakeswitch.ico"
  Delete "$INSTDIR\CakeSwitch.installed"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  ; "Start with Windows" entry of the user running the uninstaller. The device list in
  ; %APPDATA%\CAKE Switch is kept.
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${APPNAME}"
  DeleteRegKey HKLM "${UNINSTKEY}"
SectionEnd

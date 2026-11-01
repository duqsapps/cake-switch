# Changelog

## 1.4.0 (2026-11-01)

- Follows changes made from other PCs (or LuCI) much sooner: the state is re-checked every 15 seconds instead of every minute, right away when you point at the tray icon or open its menu or the window, and for all devices while the window is open.

## 1.3.0 (2026-11-01)

- Shows the CAKE speed limits (from the SQM settings) when CAKE is on: in the tray tooltip, the Status column and the command line, e.g. "down 200 / up 50 Mbit".
- Clearer error when a device can't be reached: shows ssh's own message instead of "pipe has been ended".

## 1.2.1 (2026-11-01)

- Updating keeps your "Start with Windows" setting: the installer's option is only ticked by default on a fresh install.

## 1.2.0 (2026-11-01)

- New colours: blue = ON, grey = OFF; a hollow grey ring while checking or switching.
- The installer has a "Start with Windows (in the tray)" option, ticked by default. Before, autostart was only off until you ticked it in the app.

## 1.1.0 (2026-11-01)

- Left-click the tray icon to switch CAKE on the main device (green: turn off, red: turn on). Open the window from the right-click menu.

## 1.0.0 (2026-10-31)

First release.

- Switch SQM / CAKE on and off on OpenWrt routers and access points over SSH, from a window or the command line.
- Device list with editable name, IP address, user, port and SQM interface; several devices are switched in parallel.
- Tray icon showing the main device's state (green ON, red OFF), with Turn on / Turn off in its menu.
- "Start with Windows" option that starts the app minimized to the tray.
- One-click SSH key setup per device.
- Windows installer (Program Files, Start menu entry, uninstaller).

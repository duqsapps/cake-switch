# Changelog

## 1.8.0 (2026-11-11)

- Turning CAKE on now saves the firewall's software and hardware flow offloading settings on the device and switches both off, because offloaded traffic bypasses CAKE. Turning CAKE off turns back on only what it turned off, and only if it's still off, so changes you make in LuCI meanwhile are kept. The firewall is only reloaded when a setting actually changes. The saved state is kept on the device (`/etc/cake-switch.offload`), so it works from any PC.
- New **Turn offloading off with CAKE** checkbox in the window (ticked by default) to switch this on or off.
- New columns in the device list: **Flow offloading** (off, sw = software, hw = hardware, and what is on without CAKE), **Packet steering** (off / on / on, all CPUs) and **CAKE RTT** (e.g. "30 ms (regional)"; from the running CAKE, else from the SQM options, default 100 ms). The details and the command line show them too.

## 1.6.1 (2026-11-01)

- The tray dot no longer has a white border.

## 1.6.0 (2026-11-01)

- The tray dot shows a white "?" when the main device's state hasn't been checked in the last 15 seconds, so you can tell a fresh state from an old one. Pointing at the dot checks again and the "?" goes away.
- **Check for changes** now defaults to *Only at start*. If you already picked an interval, it's kept.

## 1.5.0 (2026-11-01)

- New **Check for changes** setting in the window: every 15 seconds, 30 seconds, 1 minute, 5 minutes, 10 minutes, 15 minutes, 1 hour, or only at start (default 10 minutes). Pointing at the tray icon, opening its menu or the window still checks right away.

## 1.4.0 (2026-11-01)

- Follows changes made from other PCs (or LuCI) much sooner: the state is re-checked every 15 seconds instead of every minute, right away when you point at the tray icon or open its menu or the window, and for all devices while the window is open.
- Running a second copy of CakeSwitch (e.g. from a download folder) no longer points "Start with Windows" at that copy; the entry is only updated if the copy it points to was moved or deleted.

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

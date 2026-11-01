# CAKE Switch

Switch **SQM / CAKE** on and off on your OpenWrt router and access points from Windows, with one click or one command.

It's a single PowerShell script. It uses the OpenSSH client built into Windows 10 and 11, so there's nothing to install on the PC. It works with the standard OpenWrt `sqm-scripts` / `luci-app-sqm` setup. It sets `enabled` on your SQM queue(s), commits the change and restarts SQM. CAKE is then removed from (or added back to) the interface, and the setting survives a router reboot.

## Install

Download **`CakeSwitch-Setup-<version>.exe`** from the [Releases](../../releases) page, run it and click through it (Windows asks for admin rights, because the app goes into `C:\Program Files\CAKE Switch`). You get a **CAKE Switch** entry in the Start menu, an optional desktop icon, an uninstaller under *Settings > Apps*, and *Start with Windows*, which starts the app in the tray when you sign in (ticked by default on a fresh install; an update keeps your current setting).

- The installed app keeps its device list per user, in `%APPDATA%\CAKE Switch\cake-switch.json`. To keep a list you already have, copy your old `cake-switch.json` there.
- The setup program isn't code-signed, so Windows SmartScreen may warn about an unknown publisher: click *More info > Run anyway*.
- Uninstalling removes the app, its shortcuts and your "Start with Windows" entry. The device list in `%APPDATA%` is kept.
- To build the setup program yourself: install NSIS 3 and run `makensis installer\CakeSwitch.nsi` (also works on Linux). The version comes from `$AppVersion` in `CakeSwitch.ps1`; `CakeSwitch.cmd -Action Version` prints it, and the window title shows it.

You can also run it without installing, straight from this folder, as described below.

## Files

| File | Purpose |
|---|---|
| `CakeSwitch-GUI.cmd` | Double-click to open the window: the device list with **On / Off / Refresh all / Add / Remove / Setup SSH key** buttons |
| `CakeSwitch.cmd` | Command-line launcher (handy for shortcuts and Task Scheduler) |
| `CakeSwitch.ps1` | The actual script |
| `cake-switch.json` | Your device list. It's created and updated automatically by the GUI. See `cake-switch.example.json` |

## Multiple devices (router + access points)

The window shows one row per OpenWrt device, with **Name, IP address, User, Port, Interface** and the live **Status**.

- **Change an IP address (or anything else) at any time**: double-click the cell (or select it and press F2), type, and press Enter. The change is saved right away, and the device's status is re-read.
- **Add device / Remove**: manage the list. Removing a device only removes it from the list; nothing changes on the device.
- **On / Off** act on the selected row(s). Ctrl-click or Shift-click to switch several devices at once. Devices are contacted in parallel, so an offline AP doesn't hold up the others.
- **Interface**: leave it empty to switch every SQM queue on that device. Set it (e.g. `pppoe-wan` on the router, `br-lan` or `eth0` on an AP) to switch only that queue.
- Double-click a **Status** cell to see details (queues, interfaces, qdisc, errors).

Each access point needs `luci-app-sqm` installed and an SQM queue configured on it, just like the router.

## Tray icon

While the app runs, a dot in the notification area (next to the clock) shows the state of the **first device in the list** (the main one, usually your router):

| Dot | Meaning |
|---|---|
| Blue | CAKE is ON |
| Grey | CAKE is OFF |
| Orange | Error, or SQM enabled but CAKE not active |
| Grey ring (hollow) | Checking or switching |

- **Left-click** the dot to switch CAKE on the main device: blue turns it OFF, grey turns it ON (it shows a hollow ring while switching). If the state is unknown or an error, the click opens the window instead. **Right-click** it for *Turn on / Turn off / Refresh* (for the main device), *Start with Windows*, *Open window* and *Exit*.
- Closing or minimising the window only hides it. The app keeps running in the tray until you choose **Exit**.
- Hover over the dot to see the state and, when CAKE is on, its speed limits (download / upload, as set in SQM). The window's Status column shows them too.
- The main device is re-checked every minute, so the dot also follows changes made in LuCI.
- To make a different device the main one, put it first in `cake-switch.json`.
- **Start with Windows:** tick *Start with Windows* in the window (or in the tray menu). CAKE Switch then starts minimized to the tray when you sign in. Untick it to stop. (It's stored as a "CAKE Switch" entry under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, and it also shows under *Settings > Apps > Startup*.)
- Only one copy runs at a time: opening CAKE Switch again just brings the running window to the front.
- `CakeSwitch-GUI.cmd -Tray` starts it minimized to the tray by hand.

## Setup (once)

1. **Configure SQM** on each device (Network → SQM QoS in LuCI) with queue discipline `cake`.
2. Open **`CakeSwitch-GUI.cmd`**. Fix the IP of the first row and use **Add device** for your APs.
3. **Install your SSH key** on each device so switching works without a password. Select the row, click **Setup SSH key**, and enter that device's root password once in the console window that opens. The key (`%USERPROFILE%\.ssh\id_ed25519`) is created the first time and reused for every device.
   (If `ssh` is missing, enable it under *Settings → Apps → Optional features → OpenSSH Client*.)

## Command line

```
CakeSwitch.cmd -Action List                       # show saved devices
CakeSwitch.cmd -Action Status                     # status of all devices
CakeSwitch.cmd -Action Off -Device "Main router"
CakeSwitch.cmd -Action On -Device "AP*"           # wildcards match name or IP
CakeSwitch.cmd -Action Off -Device *              # all devices
CakeSwitch.cmd -Action Off -Router 192.168.1.9    # any IP, without saving it
CakeSwitch.cmd -Action SetupKey -Device "AP 2"
```
If you have more than one device, `On` / `Off` need `-Device`, so you can't switch everything by accident. On failure the exit code is `1`.

You can open several windows at once. You can also keep separate device lists with `-ConfigFile other.json`.

### One-click desktop shortcuts

Right-click the desktop → *New → Shortcut* and point it to, for example:
```
"C:\path\to\cake-switch\CakeSwitch.cmd" -Action On -Device "AP 1"
```
You can also give a shortcut a keyboard hotkey in its Properties.

## What runs on the router

On each device, for each SQM queue (filtered by `Interface` if you set one):
```sh
uci set sqm.<queue>.enabled=0|1
uci commit sqm
/etc/init.d/sqm restart
```
The status is then read back with `uci` and `tc qdisc show`, so "ON" means a `cake` qdisc is really active.

## Troubleshooting

- **"SSH ... failed: Permission denied"**: select the device and click **Setup SSH key**.
- **"Host key verification failed"**: the router was reinstalled. Remove its line from `%USERPROFILE%\.ssh\known_hosts`, for example with `ssh-keygen -R 192.168.1.1`.
- **"no SQM queues found"**: install and configure `luci-app-sqm` on that device first.
- **"Enabled, not active"**: SQM is enabled but no cake qdisc is installed. Either the queue uses another qdisc (e.g. `fq_codel`) or SQM failed to start. Check `logread | grep SQM` on the router.
- **Very old router firmware** whose dropbear doesn't support ed25519 keys: create an RSA key with `ssh-keygen -t rsa -b 4096 -f %USERPROFILE%\.ssh\id_rsa_router`. Then set `"KeyFile"` in `cake-switch.json` to that path and run the key setup again.

## License

MIT, see [LICENSE](LICENSE). Changes are listed in [CHANGELOG.md](CHANGELOG.md).

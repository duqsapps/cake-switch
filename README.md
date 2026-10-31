# CAKE Switch

Switch **SQM / CAKE** on and off on your OpenWrt router and access points from Windows, with one click or one command.

It's a single PowerShell script. It uses the OpenSSH client built into Windows 10 and 11, so there's nothing to install on the PC. It works with the standard OpenWrt `sqm-scripts` / `luci-app-sqm` setup. It sets `enabled` on your SQM queue(s), commits the change and restarts SQM. CAKE is then removed from (or added back to) the interface, and the setting survives a router reboot.

## Files

| File | Purpose |
|---|---|
| `CakeSwitch-GUI.cmd` | Double-click to open the window: the device list with **On / Off / Toggle / Refresh all / Add / Remove / Setup SSH key** buttons |
| `CakeSwitch.cmd` | Command-line launcher (handy for shortcuts and Task Scheduler) |
| `CakeSwitch.ps1` | The actual script |
| `cake-switch.json` | Your device list. It's created and updated automatically by the GUI. See `cake-switch.example.json` |

## Multiple devices (router + access points)

The window shows one row per OpenWrt device, with **Name, IP address, User, Port, Interface** and the live **Status**.

- **Change an IP address (or anything else) at any time**: double-click the cell (or select it and press F2), type, and press Enter. The change is saved right away, and the device's status is re-read.
- **Add device / Remove**: manage the list. Removing a device only removes it from the list; nothing changes on the device.
- **On / Off / Toggle** act on the selected row(s). Ctrl-click or Shift-click to switch several devices at once. Devices are contacted in parallel, so an offline AP doesn't hold up the others.
- **Interface**: leave it empty to switch every SQM queue on that device. Set it (e.g. `pppoe-wan` on the router, `br-lan` or `eth0` on an AP) to switch only that queue.
- Double-click a **Status** cell to see details (queues, interfaces, qdisc, errors).

Each access point needs `luci-app-sqm` installed and an SQM queue configured on it, just like the router.

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
CakeSwitch.cmd -Action Toggle -Device *           # all devices
CakeSwitch.cmd -Action Off -Router 192.168.1.9    # any IP, without saving it
CakeSwitch.cmd -Action SetupKey -Device "AP 2"
```
If you have more than one device, `On` / `Off` / `Toggle` need `-Device`, so you can't switch everything by accident. On failure the exit code is `1`.

You can open several windows at once. You can also keep separate device lists with `-ConfigFile other.json`.

### One-click desktop shortcuts

Right-click the desktop → *New → Shortcut* and point it to, for example:
```
"C:\path\to\cake-switch\CakeSwitch.cmd" -Action Toggle -Device "AP 1"
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

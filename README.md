# CAKE Switch

Switch **SQM / CAKE** on and off on an OpenWrt router from Windows, with one click or one command.

It's a single PowerShell script. It uses the OpenSSH client built into Windows 10 and 11, so there's nothing to install on the PC. It works with the standard OpenWrt `sqm-scripts` / `luci-app-sqm` setup. It sets `enabled` on your SQM queue(s), commits the change and restarts SQM. CAKE is then removed from (or added back to) the interface, and the setting survives a router reboot.

## Files

| File | Purpose |
|---|---|
| `CakeSwitch-GUI.cmd` | Double-click to open the window with **On / Off / Toggle / Refresh** buttons |
| `CakeSwitch.cmd` | Command-line launcher (handy for shortcuts and Task Scheduler) |
| `CakeSwitch.ps1` | The actual script |
| `cake-switch.example.json` | Copy to `cake-switch.json` to set your router address, etc. |

## Setup (once)

1. **SQM must already be configured** on the router (Network → SQM QoS in LuCI) with queue discipline `cake`.
2. **Optional config:** if your router isn't at `192.168.1.1` or you use a non-default user/port, copy `cake-switch.example.json` to `cake-switch.json` and edit it.
   - `Interface`: leave empty to switch every SQM queue, or set e.g. `eth1` / `pppoe-wan` to switch only that queue.
   - `KeyFile`: leave empty to use `%USERPROFILE%\.ssh\id_ed25519`.
3. **Install an SSH key** so the switch works without typing a password:
   ```
   CakeSwitch.cmd -Action SetupKey
   ```
   This creates `%USERPROFILE%\.ssh\id_ed25519` if it doesn't exist yet and asks for the router's root password once. Then it adds the key to `/etc/dropbear/authorized_keys`.
   (If `ssh` is missing, enable it under *Settings → Apps → Optional features → OpenSSH Client*.)

## Usage

GUI: double-click **`CakeSwitch-GUI.cmd`**.

Command line:
```
CakeSwitch.cmd -Action Status
CakeSwitch.cmd -Action Off
CakeSwitch.cmd -Action On
CakeSwitch.cmd -Action Toggle
CakeSwitch.cmd -Action Off -Router 10.0.0.1 -Interface eth1
```
On failure the exit code is `1`.

### One-click desktop shortcuts

Right-click the desktop → *New → Shortcut* and point it to, for example:
```
"C:\path\to\cake-switch\CakeSwitch.cmd" -Action Toggle
```
Make one each for `On`, `Off` or `Toggle` if you like. You can also give a shortcut a keyboard hotkey in its Properties.

## What runs on the router

For each SQM queue (filtered by `Interface` if you set one):
```sh
uci set sqm.<queue>.enabled=0|1
uci commit sqm
/etc/init.d/sqm restart
```
The status is then read back with `uci` and `tc qdisc show`, so "ON" means a `cake` qdisc is really active.

## Troubleshooting

- **"SSH ... failed: Permission denied"**: run `CakeSwitch.cmd -Action SetupKey`.
- **"Host key verification failed"**: the router was reinstalled. Remove its line from `%USERPROFILE%\.ssh\known_hosts`, for example with `ssh-keygen -R 192.168.1.1`.
- **"no SQM queues found"**: install and configure `luci-app-sqm` first.
- **"Enabled, not active"**: SQM is enabled but no cake qdisc is installed. Either the queue uses another qdisc (e.g. `fq_codel`) or SQM failed to start. Check `logread | grep SQM` on the router.
- **Very old router firmware** whose dropbear doesn't support ed25519 keys: create an RSA key with `ssh-keygen -t rsa -b 4096 -f %USERPROFILE%\.ssh\id_rsa_router`. Then set `"KeyFile"` to that path and run `SetupKey` again.

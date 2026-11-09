<#
.SYNOPSIS
    Switch SQM/CAKE on or off on one or more OpenWrt devices (router, access points) from Windows.

.DESCRIPTION
    Connects to each device with the OpenSSH client built into Windows 10/11 and flips the
    "enabled" flag of its SQM queue(s) (sqm-scripts / luci-app-sqm), then restarts SQM so CAKE
    is actually removed from / added to the interface.

    Devices are stored in cake-switch.json next to this script, or, when installed with the setup
    program, in %APPDATA%\CAKE Switch\cake-switch.json. Run without -Action to open the
    GUI, where devices can be added, removed and edited (name, IP address, user, port, interface)
    at any time.

.EXAMPLE
    .\CakeSwitch.ps1                                   # GUI
.EXAMPLE
    .\CakeSwitch.ps1 -Tray                             # GUI, starting hidden in the notification area
.EXAMPLE
    .\CakeSwitch.ps1 -Action Status                    # status of all devices
.EXAMPLE
    .\CakeSwitch.ps1 -Action Off -Device "Main router"
.EXAMPLE
    .\CakeSwitch.ps1 -Action On -Device AP*            # wildcards match name or address
.EXAMPLE
    .\CakeSwitch.ps1 -Action Off -Router 192.168.1.3 -Interface br-lan      # ad-hoc device, not saved
.EXAMPLE
    .\CakeSwitch.ps1 -Action SetupKey -Device "AP 1"   # one-time: install your SSH key on a device
#>
[CmdletBinding()]
param(
    [ValidateSet('Gui', 'Status', 'On', 'Off', 'List', 'SetupKey', 'Version')]
    [string]$Action = 'Gui',
    # Saved device(s) to act on, by name or address; wildcards allowed. Default for Status/List: all.
    [string[]]$Device,
    # Ad-hoc device instead of a saved one.
    [string]$Router,
    [string]$User = 'root',
    [int]$Port = 22,
    # Only touch SQM queues bound to this interface (e.g. eth1, pppoe-wan, br-lan). Empty = all queues.
    [string]$Interface = '',
    [string]$KeyFile,
    # Default: cake-switch.json next to this script (installed: %APPDATA%\CAKE Switch\cake-switch.json).
    [string]$ConfigFile,
    # GUI only: start hidden, with just the tray icon (e.g. for a Startup-folder shortcut).
    [switch]$Tray
)

$ErrorActionPreference = 'Stop'
# The one place the version is set; the installer (installer/CakeSwitch.nsi) reads it from here.
$AppVersion = '1.7.0'
$ScriptPath = $PSCommandPath
# Not a param() default: with [CmdletBinding()], Windows PowerShell 5.1 leaves $PSScriptRoot empty there.
# The setup program installs a CakeSwitch.installed marker: Program Files isn't writable, so the
# device list then lives in the user's profile.
$DefaultConfigFile = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'CakeSwitch.installed')) {
    Join-Path $env:APPDATA 'CAKE Switch\cake-switch.json'
} else {
    Join-Path $PSScriptRoot 'cake-switch.json'
}
if (-not $ConfigFile) { $ConfigFile = $DefaultConfigFile }
$ConfigFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigFile)

# --- configuration -----------------------------------------------------------------------------
# cake-switch.json:
#   { "KeyFile": "", "Devices": [ { "Name": "Main router", "Address": "192.168.1.1",
#                                   "User": "root", "Port": 22, "Interface": "" }, ... ] }

function New-Device([string]$Name, [string]$Address, [string]$User = 'root', $Port = 22, [string]$Interface = '') {
    [pscustomobject]@{ Name = $Name; Address = $Address; User = $User; Port = $Port; Interface = $Interface }
}

function Get-FieldProblem([string]$Field, [string]$Value) {
    switch ($Field) {
        'Address' { if ($Value -and $Value -notmatch '^[A-Za-z0-9.:\[\]-]+$') { return "Invalid address: $Value" } }
        'User' { if ($Value -notmatch '^[A-Za-z0-9._-]+$') { return "Invalid user name: $Value" } }
        'Port' {
            $p = 0
            if (-not [int]::TryParse($Value, [ref]$p) -or $p -lt 1 -or $p -gt 65535) { return "Invalid port: $Value" }
        }
        'Interface' { if ($Value -notmatch '^[A-Za-z0-9._@-]*$') { return "Invalid interface name: $Value" } }
    }
    return $null
}

function Get-DeviceProblem($d) {
    if (-not $d.Address) { return "No IP address set for $($d.Name)." }
    foreach ($f in @('Address', 'User', 'Port', 'Interface')) {
        $problem = Get-FieldProblem $f "$($d.$f)"
        if ($problem) { return $problem }
    }
    return $null
}

function Read-Config {
    # CheckInterval: seconds between background status checks in the GUI; 0 = only when it starts.
    $cfg = [pscustomobject]@{ KeyFile = ''; CheckInterval = 0; Devices = @() }
    if (Test-Path -LiteralPath $ConfigFile) {
        $json = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
        if ($json.KeyFile) { $cfg.KeyFile = $json.KeyFile }
        $ci = 0
        if ($null -ne $json.CheckInterval -and [int]::TryParse("$($json.CheckInterval)", [ref]$ci) -and $ci -ge 0) { $cfg.CheckInterval = $ci }
        if ($json.Devices) {
            $cfg.Devices = @($json.Devices | ForEach-Object {
                $u = if ($_.User) { $_.User } else { 'root' }
                $p = if ($_.Port) { $_.Port } else { 22 }
                New-Device $_.Name $_.Address $u $p "$($_.Interface)"
            })
        } elseif ($json.Router) {
            # Old single-router format.
            $u = if ($json.User) { $json.User } else { 'root' }
            $p = if ($json.Port) { $json.Port } else { 22 }
            $cfg.Devices = @(New-Device 'Router' $json.Router $u $p "$($json.Interface)")
        }
    }
    if ($cfg.Devices.Count -eq 0) { $cfg.Devices = @(New-Device 'Router' '192.168.1.1') }
    return $cfg
}

function Save-Config($cfg) {
    $ci = 0; [void][int]::TryParse("$($cfg.CheckInterval)", [ref]$ci)
    $data = [ordered]@{
        KeyFile = "$($cfg.KeyFile)"
        CheckInterval = $ci
        Devices = @($cfg.Devices | ForEach-Object {
            $p = 22; [void][int]::TryParse("$($_.Port)", [ref]$p)
            [ordered]@{ Name = "$($_.Name)"; Address = "$($_.Address)"; User = "$($_.User)"; Port = $p; Interface = "$($_.Interface)" }
        })
    }
    $dir = Split-Path -Parent $ConfigFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $data | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ConfigFile -Encoding UTF8
}

$Config = Read-Config
if ($PSBoundParameters.ContainsKey('KeyFile')) { $Config.KeyFile = $KeyFile }

function Get-SshExe {
    $cmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @("$env:WINDIR\System32\OpenSSH\ssh.exe", "$env:WINDIR\Sysnative\OpenSSH\ssh.exe")) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    throw "ssh.exe not found. Install it via Settings > Apps > Optional features > 'OpenSSH Client'."
}

function Get-SshArgs($d) {
    $a = @('-p', "$($d.Port)", '-o', 'ConnectTimeout=6', '-o', 'StrictHostKeyChecking=accept-new')
    if ($Config.KeyFile) { $a += @('-i', $Config.KeyFile) }
    return $a
}

# --- the shell script that runs on the device --------------------------------------------------
# Prints machine-readable lines:
#   QUEUE <section> <interface> <enabled 0|1> <qdisc> <active 0|1> <download kbit/s> <upload kbit/s>
#         (active = a cake qdisc is installed on the interface or its ifb4<interface>; empty fields are '-')
#   OFFLOAD <software 0|1|-> <hardware 0|1|-> <saved software> <saved hardware>
#         (firewall flow offloading now, and what it was before CAKE was turned on; '-' = not set)
#   ERROR <message>
# Flow offloading bypasses the qdiscs, so CAKE can't shape that traffic. Turning CAKE on saves the
# offloading settings in /etc/cake-switch.offload on the device and turns both off; turning CAKE off
# puts them back. The file lives on the device, so every PC sees the same saved state.

$RemoteScript = @'
OFFL=/etc/cake-switch.offload
FW='firewall.@defaults[0]'
fw_apply() {
    if ! uci commit firewall; then echo "ERROR uci commit firewall failed"; exit 3; fi
    # Only reload a firewall that is in use (an AP may have the config but the service disabled).
    /etc/init.d/firewall enabled 2>/dev/null && /etc/init.d/firewall reload >/dev/null 2>&1
}
hasfw=0; uci -q get "$FW" >/dev/null 2>&1 && hasfw=1

secs=""
for s in $(uci -X show sqm 2>/dev/null | sed -n 's/^sqm\.\([^.=]*\)=queue$/\1/p'); do
    if [ -z "$IFACE" ] || [ "$(uci -q get sqm.$s.interface)" = "$IFACE" ]; then
        secs="$secs $s"
    fi
done
if [ -z "$secs" ]; then
    if [ -n "$IFACE" ]; then echo "ERROR no SQM queue for interface $IFACE"
    else echo "ERROR no SQM queues found (is sqm-scripts installed and configured?)"; fi
    exit 2
fi

# On: remember the offloading settings (only the first time, so a second "on" can't overwrite them
# with "off"), then turn both off before starting SQM.
if [ "$ACTION" = "on" ] && [ $hasfw = 1 ]; then
    if [ ! -f "$OFFL" ]; then
        echo "$(uci -q get "$FW.flow_offloading" || echo -) $(uci -q get "$FW.flow_offloading_hw" || echo -)" > "$OFFL"
    fi
    ch=0
    for o in flow_offloading flow_offloading_hw; do
        if [ "$(uci -q get "$FW.$o")" = 1 ]; then uci set "$FW.$o=0"; ch=1; fi
    done
    [ $ch = 1 ] && fw_apply
fi

if [ "$ACTION" = "on" ] || [ "$ACTION" = "off" ]; then
    v=0; [ "$ACTION" = "on" ] && v=1
    for s in $secs; do uci set sqm.$s.enabled=$v; done
    if ! uci commit sqm; then echo "ERROR uci commit sqm failed"; exit 3; fi
    /etc/init.d/sqm restart >/dev/null 2>&1
fi

# Off: undo only our own change: turn a setting back on if it was on before CAKE and is still off
# (0, as we left it). A change made meanwhile, e.g. in LuCI, is kept.
if [ "$ACTION" = "off" ] && [ -f "$OFFL" ]; then
    if [ $hasfw = 1 ]; then
        read sw hw < "$OFFL"
        ch=0
        for pair in "flow_offloading $sw" "flow_offloading_hw $hw"; do
            set -- $pair
            if [ "$2" = 1 ] && [ "$(uci -q get "$FW.$1")" = 0 ]; then uci set "$FW.$1=1"; ch=1; fi
        done
        [ $ch = 1 ] && fw_apply
    fi
    rm -f "$OFFL"
fi

for s in $secs; do
    i=$(uci -q get sqm.$s.interface)
    a=0
    if [ -n "$i" ]; then
        ifb=$(echo "ifb4$i" | cut -c 1-15)
        for dev in "$i" "$ifb"; do
            tc qdisc show dev "$dev" 2>/dev/null | grep -q '^qdisc cake ' && a=1
        done
    fi
    echo "QUEUE $s ${i:--} $(uci -q get sqm.$s.enabled || echo 0) $(uci -q get sqm.$s.qdisc || echo -) $a $(uci -q get sqm.$s.download || echo 0) $(uci -q get sqm.$s.upload || echo 0)"
done
if [ $hasfw = 1 ]; then
    saved="- -"; [ -f "$OFFL" ] && saved=$(cat "$OFFL")
    echo "OFFLOAD $(uci -q get "$FW.flow_offloading" || echo -) $(uci -q get "$FW.flow_offloading_hw" || echo -) $saved"
fi
'@

# --- running it: jobs are started without waiting, so several devices are handled in parallel ---

function Start-CakeJob($d, [ValidateSet('on', 'off', 'status')][string]$Verb) {
    $job = [pscustomobject]@{ Device = $d; Process = $null; Out = $null; Err = $null; Started = Get-Date; Error = $null }
    $problem = Get-DeviceProblem $d
    if ($problem) { $job.Error = $problem; return $job }
    try {
        # The script is fed via stdin to "sh -s", which avoids all Windows command-line quoting issues.
        # BatchMode makes ssh fail instead of hanging on a password prompt nobody can see.
        $argList = @('-o', 'BatchMode=yes') + (Get-SshArgs $d) + @("$($d.User)@$($d.Address)", 'sh', '-s')
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Get-SshExe
        $psi.Arguments = ($argList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $job.Process = [System.Diagnostics.Process]::Start($psi)
        $job.Out = $job.Process.StandardOutput.ReadToEndAsync()
        $job.Err = $job.Process.StandardError.ReadToEndAsync()
        # The leading newline keeps a UTF-8 BOM, which .NET Framework writes to stdin when the console
        # code page is 65001, on a line of its own instead of corrupting "ACTION=...".
        $script = "`nACTION=$Verb`nIFACE=$($d.Interface)`n" + $RemoteScript
        # If ssh fails at once (host down, key refused) it exits before reading its input, and the write
        # fails with "broken pipe" / "pipe has been ended". Ignore that: the exit code and ssh's own
        # error message, reported by Complete-CakeJob, say what really went wrong.
        try {
            $job.Process.StandardInput.Write($script.Replace("`r`n", "`n"))
            $job.Process.StandardInput.Close()
        } catch { }
    } catch {
        $job.Error = $_.Exception.Message
    }
    return $job
}

function Test-CakeJobDone($job) {
    return (-not $job.Process) -or $job.Process.HasExited -or ((Get-Date) - $job.Started).TotalSeconds -gt 45
}

function Complete-CakeJob($job) {
    $d = $job.Device
    $result = [pscustomobject]@{ Device = $d; Active = $false; Enabled = $false; Queues = @(); Offload = $null; Error = $job.Error }
    if (-not $job.Process) { return $result }
    $p = $job.Process
    if (-not $p.HasExited) {
        try { $p.Kill() } catch { }
        $result.Error = "Timed out talking to $($d.Address)."
        return $result
    }
    $p.WaitForExit()
    $out = $job.Out.Result
    $err = $job.Err.Result.Trim()

    foreach ($line in ($out -split "`n")) {
        $f = $line.Trim() -split '\s+'
        switch ($f[0]) {
            'QUEUE' {
                $down = 0; $up = 0
                if ($f.Count -gt 6) { [void][int]::TryParse($f[6], [ref]$down) }
                if ($f.Count -gt 7) { [void][int]::TryParse($f[7], [ref]$up) }
                $q = [pscustomobject]@{ Section = $f[1]; Interface = $f[2]; Enabled = ($f[3] -eq '1'); Qdisc = $f[4]; Active = ($f[5] -eq '1')
                                        Download = $down; Upload = $up }
                $result.Queues += $q
                if ($q.Enabled) { $result.Enabled = $true }
                if ($q.Active) { $result.Active = $true }
            }
            'OFFLOAD' {
                if ($f.Count -ge 5) {
                    $result.Offload = [pscustomobject]@{ Software = ($f[1] -eq '1'); Hardware = ($f[2] -eq '1')
                                                         Saved = ($f[3] -ne '-'); SavedSoftware = ($f[3] -eq '1'); SavedHardware = ($f[4] -eq '1') }
                }
            }
            'ERROR' { $result.Error = ($f[1..($f.Count - 1)] -join ' ') }
        }
    }
    if ($p.ExitCode -ne 0 -and -not $result.Error) {
        if ($p.ExitCode -eq 255) {
            $hint = ''
            if ($err -match 'Host key verification failed') {
                $hint = "  (the device's host key changed: if that is expected, run: ssh-keygen -R $($d.Address))"
            } elseif ($err -match 'Permission denied') {
                $hint = "  (SSH key not installed on this device? use 'Setup SSH key')"
            }
            $result.Error = "SSH to $($d.User)@$($d.Address) failed: $err$hint"
        } else {
            $result.Error = "Command failed (exit $($p.ExitCode)). $err"
        }
    }
    return $result
}

function Get-StateText($r) {
    if ($r.Error) { return 'Error' }
    if ($r.Active) { return 'ON' }
    if ($r.Enabled) { return 'Enabled, not active' }
    return 'OFF'
}

# SQM's download/upload limits are in kbit/s; 0 means that direction isn't shaped.
function Format-Rate([int]$Kbit, [switch]$NoUnit) {
    if ($Kbit -le 0) { return 'unlimited' }
    if ($Kbit -ge 1000) { $n = ($Kbit / 1000).ToString('0.#', [System.Globalization.CultureInfo]::InvariantCulture); $u = 'Mbit' }
    else { $n = "$Kbit"; $u = 'kbit' }
    if ($NoUnit) { return $n } else { return "$n $u" }
}

# "down 200 / up 50 Mbit" for the queues where CAKE is active (several queues: one per interface).
function Get-LimitText($r) {
    $active = @($r.Queues | Where-Object { $_.Active })
    $parts = foreach ($q in $active) {
        $sameUnit = ($q.Download -ge 1000) -eq ($q.Upload -ge 1000) -and $q.Download -gt 0 -and $q.Upload -gt 0
        $t = if ($sameUnit) {
            "down $(Format-Rate $q.Download -NoUnit) / up $(Format-Rate $q.Upload)"
        } else {
            "down $(Format-Rate $q.Download) / up $(Format-Rate $q.Upload)"
        }
        if ($active.Count -gt 1) { "$($q.Interface): $t" } else { $t }
    }
    return (@($parts) -join '; ')
}

function Format-Status($r) {
    $head = "$($r.Device.Name) [$($r.Device.Address)]: $(Get-StateText $r)"
    if ($r.Active -and -not $r.Error) { $limits = Get-LimitText $r; if ($limits) { $head += " ($limits)" } }
    $lines = @($head)
    if ($r.Error) { $lines += "  $($r.Error)" }
    if ($r.Enabled -and -not $r.Active -and -not $r.Error) {
        $lines += '  (qdisc may not be cake, or SQM failed to start - check: logread | grep SQM)'
    }
    foreach ($q in $r.Queues) {
        $lines += "  queue {0,-14} iface {1,-12} enabled={2} qdisc={3} cake active={4} down={5} up={6}" -f $q.Section, $q.Interface, [int]$q.Enabled, $q.Qdisc, [int]$q.Active, (Format-Rate $q.Download), (Format-Rate $q.Upload)
    }
    $o = $r.Offload
    if ($o) {
        $onOff = { param($b) if ($b) { 'on' } else { 'off' } }
        $line = "  flow offloading: software {0}, hardware {1}" -f (& $onOff $o.Software), (& $onOff $o.Hardware)
        if ($o.Saved) { $line += " (before CAKE: software {0}, hardware {1}; restored when CAKE is turned off)" -f (& $onOff $o.SavedSoftware), (& $onOff $o.SavedHardware) }
        $lines += $line
    }
    return $lines -join "`r`n"
}

# --- SSH key setup (interactive, asks for the device password once) -----------------------------

function Install-SshKey($d) {
    $problem = Get-DeviceProblem $d
    if ($problem) { throw $problem }
    $sshDir = Join-Path $env:USERPROFILE '.ssh'
    $key = if ($Config.KeyFile) { $Config.KeyFile } else { Join-Path $sshDir 'id_ed25519' }
    if (-not (Test-Path -LiteralPath $key)) {
        if (-not (Test-Path -LiteralPath $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
        Write-Host "Creating SSH key $key (no passphrase, so switching works without prompting)..."
        $keygen = Join-Path (Split-Path (Get-SshExe)) 'ssh-keygen.exe'
        # Windows PowerShell 5.1 drops empty native arguments, so it needs '""' to pass an empty passphrase.
        # PowerShell 7.0-7.2 drop it too; only 7.3+ (outside Legacy mode) pass '' through.
        $empty = if ($PSVersionTable.PSVersion -ge [version]'7.3' -and $PSNativeCommandArgumentPassing -ne 'Legacy') { '' } else { '""' }
        & $keygen -q -t ed25519 -N $empty -f $key
        if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen failed.' }
    }
    $pub = (Get-Content -LiteralPath "$key.pub" -Raw).Trim()
    if ($pub -match "'") { throw 'Unexpected character in public key.' }
    Write-Host "Installing public key on $($d.Name) ($($d.User)@$($d.Address)). Enter the device's password when asked."
    $remote = "mkdir -p /etc/dropbear && touch /etc/dropbear/authorized_keys && chmod 600 /etc/dropbear/authorized_keys && " +
              "(grep -qxF '$pub' /etc/dropbear/authorized_keys || echo '$pub' >> /etc/dropbear/authorized_keys) && echo KEY_OK"
    $sshArgs = Get-SshArgs $d
    if (-not $Config.KeyFile) { $sshArgs += @('-i', $key) }
    & (Get-SshExe) @sshArgs "$($d.User)@$($d.Address)" $remote
    if ($LASTEXITCODE -ne 0) { throw 'Installing the key failed.' }
    Write-Host 'Done. Testing passwordless connection...'
    $job = Start-CakeJob $d 'status'
    while (-not (Test-CakeJobDone $job)) { Start-Sleep -Milliseconds 100 }
    Write-Host (Format-Status (Complete-CakeJob $job))
}

# --- start with Windows (HKCU Run key, starts hidden in the tray) -------------------------------

$AutostartKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$AutostartName = 'CAKE Switch'

function Get-AutostartCommand {
    # conhost --headless: no console window at logon (see CakeSwitch-GUI.cmd). Kept short because
    # Windows ignores Run entries longer than 260 characters.
    $cmd = "`"$env:SystemRoot\System32\conhost.exe`" --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Action Gui -Tray"
    if ($ConfigFile -ne $DefaultConfigFile) { $cmd += " -ConfigFile `"$ConfigFile`"" }
    return $cmd
}

function Test-Autostart {
    try { return [bool](Get-ItemProperty -LiteralPath $AutostartKey -Name $AutostartName -ErrorAction Stop).$AutostartName } catch { return $false }
}

function Set-Autostart([bool]$Enable) {
    if ($Enable) {
        if (-not (Test-Path -LiteralPath $AutostartKey)) { New-Item -Path $AutostartKey -Force | Out-Null }
        Set-ItemProperty -LiteralPath $AutostartKey -Name $AutostartName -Value (Get-AutostartCommand)
    } elseif (Test-Autostart) {
        Remove-ItemProperty -LiteralPath $AutostartKey -Name $AutostartName
    }
}

# --- GUI ------------------------------------------------------------------------------------------

function Show-Gui {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    # One instance per device list: a second launch (e.g. double-click while it already runs from
    # autostart) just brings the running window to the front and exits.
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $id = 'CakeSwitch-' + ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ConfigFile.ToLowerInvariant()))) -replace '-', '').Substring(0, 16)
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($true, "Local\$id", [ref]$createdNew)
    $showEvent = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, "Local\$id-show")
    if (-not $createdNew) {
        if (-not $Tray) { [void]$showEvent.Set() }
        return
    }

    # Colours for the tray dot and the Status column: blue = ON, grey = OFF, orange = error.
    $StateColors = @{
        ON    = [System.Drawing.Color]::FromArgb(0, 120, 215)
        OFF   = [System.Drawing.Color]::FromArgb(128, 128, 128)
        Error = [System.Drawing.Color]::FromArgb(240, 150, 0)
        Busy  = [System.Drawing.Color]::FromArgb(160, 160, 160)
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "CAKE Switch $AppVersion"
    $form.ClientSize = New-Object System.Drawing.Size(830, 392)
    # Wide enough for the button row and the "Start with Windows" box (about x=810).
    $form.MinimumSize = New-Object System.Drawing.Size(850, 330)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 12)
    $grid.Size = New-Object System.Drawing.Size(806, 250)
    $grid.Anchor = 'Top, Bottom, Left, Right'
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $true
    $grid.EditMode = 'EditOnKeystrokeOrF2'
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
    foreach ($c in @(@('Name', 'Name', 22), @('Address', 'IP address', 18), @('User', 'User', 9), @('Port', 'Port', 7),
                     @('Interface', 'Interface', 12), @('Status', 'Status (double-click for details)', 32))) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $c[0]; $col.HeaderText = $c[1]; $col.FillWeight = $c[2]
        $col.SortMode = 'NotSortable'
        [void]$grid.Columns.Add($col)
    }
    $grid.Columns['Status'].ReadOnly = $true
    $grid.Columns['Status'].DefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

    $info = New-Object System.Windows.Forms.Label
    $info.Location = New-Object System.Drawing.Point(12, 268)
    $info.Size = New-Object System.Drawing.Size(806, 34)
    $info.Anchor = 'Bottom, Left, Right'
    $info.ForeColor = [System.Drawing.Color]::DimGray
    $info.Text = 'Edit a cell (double-click or F2) to change a device''s name, IP address, user, port or SQM interface; changes are saved automatically. Interface empty = all SQM queues on that device. Select several rows to switch them together.'

    $buttons = @{}
    $x = 12
    foreach ($b in @(@('On', 'On'), @('Off', 'Off'), @('Refresh', 'Refresh all'),
                     @('Add', 'Add device'), @('Remove', 'Remove'), @('Key', 'Setup SSH key'))) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $b[1]
        $btn.Location = New-Object System.Drawing.Point($x, 314)
        $btn.Size = New-Object System.Drawing.Size(100, 32)
        $btn.Anchor = 'Bottom, Left'
        $form.Controls.Add($btn)
        $buttons[$b[0]] = $btn
        $gap = 106
        if ($b[0] -eq 'Refresh') { $gap = 120 }
        $x += $gap
    }
    $autoBox = New-Object System.Windows.Forms.CheckBox
    $autoBox.Text = 'Start with Windows'
    $autoBox.AutoSize = $true
    $autoBox.Location = New-Object System.Drawing.Point(($x + 6), 320)
    $autoBox.Anchor = 'Bottom, Left'
    $form.Controls.Add($autoBox)
    (New-Object System.Windows.Forms.ToolTip).SetToolTip($autoBox, 'Start CAKE Switch when you sign in to Windows, minimized to the tray.')

    # How often to re-check in the background (each check is one SSH login, logged by the router).
    $intervalChoices = @(@(15, '15 seconds'), @(30, '30 seconds'), @(60, '1 minute'), @(300, '5 minutes'),
                         @(600, '10 minutes'), @(900, '15 minutes'), @(3600, '1 hour'), @(0, 'Only at start'))
    $intervalLabel = New-Object System.Windows.Forms.Label
    $intervalLabel.Text = 'Check for changes:'
    $intervalLabel.AutoSize = $true
    $intervalLabel.Location = New-Object System.Drawing.Point(12, 362)
    $intervalLabel.Anchor = 'Bottom, Left'
    $form.Controls.Add($intervalLabel)
    $intervalBox = New-Object System.Windows.Forms.ComboBox
    $intervalBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $intervalBox.Location = New-Object System.Drawing.Point(130, 358)
    $intervalBox.Size = New-Object System.Drawing.Size(120, 24)
    $intervalBox.Anchor = 'Bottom, Left'
    foreach ($c in $intervalChoices) { [void]$intervalBox.Items.Add($c[1]) }
    $form.Controls.Add($intervalBox)
    $intervalNote = New-Object System.Windows.Forms.Label
    $intervalNote.Text = 'Pointing at the tray icon (or opening its menu or this window) always checks right away.'
    $intervalNote.AutoSize = $true
    $intervalNote.ForeColor = [System.Drawing.Color]::DimGray
    $intervalNote.Location = New-Object System.Drawing.Point(262, 362)
    $intervalNote.Anchor = 'Bottom, Left'
    $form.Controls.Add($intervalNote)

    # Event handlers run inside the WinForms message loop: an exception escaping one would show .NET's
    # "unhandled exception" dialog (or close the window), so every handler goes through this.
    function Invoke-Safe([scriptblock]$Body) {
        try { & $Body } catch { [void][System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", 'CAKE Switch') }
    }

    function Add-DeviceRow($d) {
        $i = $grid.Rows.Add($d.Name, $d.Address, $d.User, "$($d.Port)", $d.Interface, '')
        # Job = running ssh job; Next = action clicked while busy, started when the job finishes.
        # State = last result (ON / OFF / Error / Enabled, not active), or Working while switching.
        $grid.Rows[$i].Tag = [pscustomobject]@{ Job = $null; Next = $null; Details = ''; State = ''; Limits = ''; CheckedAt = [datetime]::MinValue }
        return $grid.Rows[$i]
    }

    function Get-RowDevice($row) {
        $v = { param($n) $c = $row.Cells[$n].Value; if ($null -eq $c) { '' } else { "$c".Trim() } }
        New-Device (& $v 'Name') (& $v 'Address') (& $v 'User') (& $v 'Port') (& $v 'Interface')
    }

    function Save-Grid {
        $Config.Devices = @($grid.Rows | ForEach-Object { Get-RowDevice $_ })
        try { Save-Config $Config } catch { [void][System.Windows.Forms.MessageBox]::Show("Could not save ${ConfigFile}: $($_.Exception.Message)", 'CAKE Switch') }
    }

    function Set-RowStatus($row, [string]$text, [System.Drawing.Color]$color, [string]$details) {
        $cell = $row.Cells['Status']
        $cell.Value = $text
        $cell.Style.ForeColor = $color
        # Keep the default (white) text on a selected row: green/red on the blue highlight is hard to read.
        $cell.ToolTipText = $details
        $row.Tag.Details = $details
    }

    function Start-Row($row, [string]$verb, [switch]$Quiet) {
        if ($row.Tag.Job) { if (-not $Quiet) { $row.Tag.Next = $verb }; return }
        $d = Get-RowDevice $row
        # Quiet = background status check: keep showing the last status instead of 'Working...'.
        if (-not $Quiet) { Set-RowStatus $row 'Working...' $StateColors.Busy '' }
        if ($verb -ne 'status') { $row.Tag.State = 'Working' }
        $row.Tag.Job = Start-CakeJob $d $verb
    }

    function Start-Selected([string]$verb) {
        if ($grid.IsCurrentCellInEditMode -and -not $grid.EndEdit()) { return }
        $rows = @($grid.SelectedRows)
        if ($rows.Count -eq 0 -and $grid.CurrentRow) { $rows = @($grid.CurrentRow) }
        if ($rows.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Select a device first.', 'CAKE Switch'); return }
        foreach ($r in $rows) { Start-Row $r $verb }
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({
        foreach ($row in $grid.Rows) {
            $job = $row.Tag.Job
            if (-not $job -or -not (Test-CakeJobDone $job)) { continue }
            $row.Tag.Job = $null
            # No message boxes in here: this runs every 200 ms. Errors go into the row's status instead.
            try {
                try { $r = Complete-CakeJob $job } catch { $r = [pscustomobject]@{ Device = $job.Device; Active = $false; Enabled = $false; Error = $_.Exception.Message; Queues = @(); Offload = $null } }
                $state = Get-StateText $r
                $limits = if ($state -eq 'ON') { Get-LimitText $r } else { '' }
                $row.Tag.Limits = $limits
                $text = if ($r.Error) { "Error: $($r.Error)" } elseif ($state -eq 'ON') { if ($limits) { "CAKE is ON ($limits)" } else { 'CAKE is ON' } } elseif ($state -eq 'OFF') { 'CAKE is OFF' } else { $state }
                $color = switch ($state) {
                    'ON' { $StateColors.ON }
                    'OFF' { $StateColors.OFF }
                    default { $StateColors.Error }
                }
                Set-RowStatus $row $text $color (Format-Status $r)
                $row.Tag.State = $state
                $row.Tag.CheckedAt = Get-Date
                if ($row.Tag.Next) {
                    $verb = $row.Tag.Next
                    $row.Tag.Next = $null
                    Start-Row $row $verb
                }
            } catch {
                $row.Tag.Next = $null
                $row.Tag.State = 'Error'
                try { $row.Cells['Status'].Value = "Error: $($_.Exception.Message)" } catch { }
            }
        }
        try { Update-Tray } catch { }
        try { if ($showEvent.WaitOne(0)) { Show-Window } } catch { }
    })

    $grid.Add_CellValidating({
        param($s, $e)
        # Also fires whenever the current cell changes or the grid loses focus; only check real edits.
        if (-not $grid.IsCurrentCellInEditMode) { return }
        $name = $grid.Columns[$e.ColumnIndex].Name
        $problem = Get-FieldProblem $name ("$($e.FormattedValue)".Trim())
        if ($problem) {
            $e.Cancel = $true
            [void][System.Windows.Forms.MessageBox]::Show($problem, 'CAKE Switch')
        }
    })
    $grid.Add_CellEndEdit({
        param($s, $e)
        Invoke-Safe {
            $row = $grid.Rows[$e.RowIndex]
            Save-Grid
            $col = $grid.Columns[$e.ColumnIndex].Name
            if (@('Address', 'User', 'Port', 'Interface') -contains $col -and (Get-RowDevice $row).Address) { Start-Row $row 'status' }
        }
    })
    $grid.Add_CellDoubleClick({
        param($s, $e)
        Invoke-Safe {
            if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
            if ($grid.Columns[$e.ColumnIndex].Name -eq 'Status') {
                $t = $grid.Rows[$e.RowIndex].Tag.Details
                if ($t) { [void][System.Windows.Forms.MessageBox]::Show($t, 'CAKE Switch - details') }
            } else {
                [void]$grid.BeginEdit($true)
            }
        }
    })

    $buttons['On'].Add_Click({ Invoke-Safe { Start-Selected 'on' } })
    $buttons['Off'].Add_Click({ Invoke-Safe { Start-Selected 'off' } })
    $buttons['Refresh'].Add_Click({
        Invoke-Safe {
            if ($grid.IsCurrentCellInEditMode -and -not $grid.EndEdit()) { return }
            foreach ($r in $grid.Rows) { Start-Row $r 'status' }
        }
    })
    $buttons['Add'].Add_Click({
        Invoke-Safe {
            if ($grid.IsCurrentCellInEditMode -and -not $grid.EndEdit()) { return }
            $row = Add-DeviceRow (New-Device "Device $($grid.Rows.Count + 1)" '')
            Save-Grid
            $grid.ClearSelection()
            $grid.CurrentCell = $row.Cells['Address']
            [void]$grid.BeginEdit($true)
        }
    })
    $buttons['Remove'].Add_Click({
        Invoke-Safe {
            if ($grid.IsCurrentCellInEditMode -and -not $grid.EndEdit()) { return }
            $rows = @($grid.SelectedRows)
            if ($rows.Count -eq 0 -and $grid.CurrentRow) { $rows = @($grid.CurrentRow) }
            if ($rows.Count -eq 0) { return }
            $names = ($rows | ForEach-Object { (Get-RowDevice $_).Name }) -join ', '
            if ([System.Windows.Forms.MessageBox]::Show("Remove $names from the list?`n(Nothing is changed on the device.)", 'CAKE Switch', 'YesNo') -eq 'Yes') {
                foreach ($r in $rows) { $grid.Rows.Remove($r) }
                Save-Grid
            }
        }
    })
    $buttons['Key'].Add_Click({
        Invoke-Safe {
            if ($grid.IsCurrentCellInEditMode -and -not $grid.EndEdit()) { return }
            $row = $grid.CurrentRow
            if (-not $row) { [void][System.Windows.Forms.MessageBox]::Show('Select a device first.', 'CAKE Switch'); return }
            $d = Get-RowDevice $row
            $problem = Get-DeviceProblem $d
            if ($problem) { [void][System.Windows.Forms.MessageBox]::Show($problem, 'CAKE Switch'); return }
            # Password prompts need a real console, so run the setup in its own window.
            $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$ScriptPath`"", '-Action', 'SetupKey',
                        '-Router', $d.Address, '-User', $d.User, '-Port', "$($d.Port)", '-ConfigFile', "`"$ConfigFile`"")
            Start-Process powershell.exe -ArgumentList $psArgs
        }
    })

    # --- tray icon: shows the state of the first device in the list ("the main one") ---------------

    # Hollow = only a ring (used for "checking/switching", so it can't be mistaken for OFF's grey dot).
    # Question = a white "?" on the dot: the state shown hasn't been checked for a while.
    function New-DotIcon([System.Drawing.Color]$Color, [switch]$Hollow, [switch]$Question) {
        $bmp = New-Object System.Drawing.Bitmap -ArgumentList 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $brush = New-Object System.Drawing.SolidBrush -ArgumentList $Color
        if ($Hollow) {
            $ring = New-Object System.Drawing.Pen -ArgumentList $Color, 6
            $g.DrawEllipse($ring, 5, 5, 22, 22)
            $ring.Dispose()
        } else {
            $g.FillEllipse($brush, 1, 1, 30, 30)   # no border
        }
        if ($Question) {
            # Drawn as an outline that is filled and also stroked, which makes it extra bold.
            $fmt = New-Object System.Drawing.StringFormat
            $fmt.Alignment = [System.Drawing.StringAlignment]::Center
            $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            $path.AddString('?', (New-Object System.Drawing.FontFamily -ArgumentList 'Segoe UI'), [int][System.Drawing.FontStyle]::Bold, 22,
                            (New-Object System.Drawing.RectangleF -ArgumentList 0, 1, 32, 32), $fmt)
            $qPen = New-Object System.Drawing.Pen -ArgumentList ([System.Drawing.Color]::White), 1.2
            $qPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
            $g.FillPath([System.Drawing.Brushes]::White, $path)
            $g.DrawPath($qPen, $path)
            $qPen.Dispose(); $path.Dispose(); $fmt.Dispose()
        }
        $brush.Dispose(); $g.Dispose()
        return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    }
    $icons = @{
        ON      = New-DotIcon $StateColors.ON
        OFF     = New-DotIcon $StateColors.OFF
        Error   = New-DotIcon $StateColors.Error
        Unknown = New-DotIcon $StateColors.Busy -Hollow
        'ON?'    = New-DotIcon $StateColors.ON -Question
        'OFF?'   = New-DotIcon $StateColors.OFF -Question
        'Error?' = New-DotIcon $StateColors.Error -Question
    }
    # After this many seconds without a fresh status from the main device, its dot gets a "?".
    $StaleSeconds = 15
    # Mutable state shared by the handlers (assigning a plain variable inside a handler would only
    # create a local copy).
    $ui = @{ TrayKey = ''; Exiting = $false; Done = $false; HintShown = $false; Syncing = $false; LastCheck = [datetime]::MinValue }

    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = $icons.Unknown
    $notify.Text = 'CAKE Switch'

    function Get-MainRow { if ($grid.Rows.Count -gt 0) { return $grid.Rows[0] } else { return $null } }

    function Update-Tray {
        $row = Get-MainRow
        $name = ''; $state = ''
        if ($row) { $name = "$($row.Cells['Name'].Value)".Trim(); $state = "$($row.Tag.State)" }
        $key = switch ($state) { 'ON' { 'ON' } 'OFF' { 'OFF' } 'Error' { 'Error' } 'Enabled, not active' { 'Error' } default { 'Unknown' } }
        # Runs every 200 ms (status timer), so the "?" appears on time without a timer of its own.
        if ($key -ne 'Unknown' -and ((Get-Date) - $row.Tag.CheckedAt).TotalSeconds -ge $StaleSeconds) { $key = $key + '?' }
        # Several lines; NotifyIcon.Text allows at most 63 characters in total.
        $tip = if (-not $row) { 'CAKE Switch - no devices' } else {
            switch ($state) {
                'ON' {
                    $lim = "$($row.Tag.Limits)"
                    if ($lim) { "${name}: CAKE ON`n$lim`nClick to turn off" } else { "${name}: CAKE ON`nClick to turn off" }
                }
                'OFF' { "${name}: CAKE OFF`nClick to turn on" }
                'Working' { "${name}: switching..." }
                '' { "${name}: checking..." }
                default { "${name}: $state`nClick to open the window" }
            }
        }
        if ($tip.Length -gt 63) { $tip = ($tip -replace "`nClick to turn (on|off)", '') }
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        if ($ui.TrayKey -eq "$key|$tip") { return }
        $ui.TrayKey = "$key|$tip"
        $notify.Icon = $icons[$key]
        $notify.Text = $tip
        $form.Icon = $icons[$key]
    }

    # Re-read the state in the background (no 'Working...'), e.g. after another PC switched CAKE.
    # -All: every device (when the window is visible), otherwise only the main one.
    function Update-Quietly([switch]$All) {
        $rows = if ($All) { @($grid.Rows) } else { @(Get-MainRow) }
        foreach ($row in $rows) {
            if ($row -and (Get-RowDevice $row).Address) { Start-Row $row 'status' -Quiet }
        }
        $ui.LastCheck = Get-Date
    }

    function Show-Window {
        if (-not $form.Visible) { Update-Quietly -All }
        $form.Show()
        if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $form.WindowState = 'Normal' }
        $form.Activate()
    }

    function Start-Main([string]$verb) {
        $row = Get-MainRow
        if (-not $row) { return }
        if ($grid.IsCurrentCellInEditMode -and -not $grid.EndEdit()) { return }
        Start-Row $row $verb
        Update-Tray
    }

    function Exit-App {
        if ($ui.Done) { return }
        $ui.Done = $true
        $ui.Exiting = $true
        $timer.Stop(); $poll.Stop()
        $notify.Visible = $false
        $notify.Dispose()
        try { $form.Close() } catch { }
        try { $mutex.ReleaseMutex() } catch { }
        $appContext.ExitThread()
    }

    # The "Start with Windows" checkbox and tray menu item both show and change the Run entry.
    function Sync-Autostart {
        $ui.Syncing = $true
        try { $on = Test-Autostart; $autoBox.Checked = $on; $miAuto.Checked = $on } finally { $ui.Syncing = $false }
    }
    function Switch-Autostart([bool]$Enable) {
        if ($ui.Syncing) { return }
        try { Set-Autostart $Enable } finally { Sync-Autostart }
    }

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miOn = $menu.Items.Add('Turn on')
    $miOff = $menu.Items.Add('Turn off')
    $miRefresh = $menu.Items.Add('Refresh')
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miAuto = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList 'Start with Windows'
    [void]$menu.Items.Add($miAuto)
    $miOpen = $menu.Items.Add('Open window')
    $miExit = $menu.Items.Add('Exit')
    $menu.Add_Opening({
        Invoke-Safe {
            $row = Get-MainRow
            $name = if ($row) { "$($row.Cells['Name'].Value)".Trim() } else { '' }
            $miOn.Text = if ($name) { "Turn on ($name)" } else { 'Turn on' }
            $miOff.Text = if ($name) { "Turn off ($name)" } else { 'Turn off' }
            foreach ($mi in @($miOn, $miOff, $miRefresh)) { $mi.Enabled = [bool]$row }
            Sync-Autostart
        }
    })
    $miAuto.Add_Click({ Invoke-Safe { Switch-Autostart (-not $miAuto.Checked) } })
    $autoBox.Add_CheckedChanged({ Invoke-Safe { Switch-Autostart $autoBox.Checked } })
    $miOn.Add_Click({ Invoke-Safe { Start-Main 'on' } })
    $miOff.Add_Click({ Invoke-Safe { Start-Main 'off' } })
    $miRefresh.Add_Click({ Invoke-Safe { Start-Main 'status' } })
    $miOpen.Add_Click({ Invoke-Safe { Show-Window } })
    $miExit.Add_Click({ Invoke-Safe { Exit-App } })
    $notify.ContextMenuStrip = $menu
    # Left-click switches the main device: ON -> off, OFF -> on. While its state is unknown or an
    # error, the click opens the window instead so the problem can be seen.
    function Switch-MainByClick {
        $row = Get-MainRow
        if (-not $row) { Show-Window; return }
        if ($row.Tag.State -eq 'Working') { return }   # already switching: ignore extra clicks
        switch ("$($row.Tag.State)") {
            'ON' { Start-Main 'off' }
            'OFF' { Start-Main 'on' }
            default { Show-Window }
        }
    }
    $notify.Add_MouseClick({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Invoke-Safe { Switch-MainByClick } }
    })

    # Follow changes made elsewhere (another PC running CAKE Switch, LuCI): re-check every
    # CheckInterval seconds (all devices while the window is open, else the main one; 0 = never in the
    # background), and right away when the mouse moves over the tray icon or its menu opens, so the
    # tooltip and menu aren't out of date.
    $poll = New-Object System.Windows.Forms.Timer
    $poll.Add_Tick({ try { Update-Quietly -All:$form.Visible } catch { } })
    function Set-CheckInterval([int]$Seconds) {
        $poll.Stop()
        if ($Seconds -gt 0) { $poll.Interval = $Seconds * 1000; $poll.Start() }
    }
    $sel = 7   # Only at start
    for ($i = 0; $i -lt $intervalChoices.Count; $i++) { if ($intervalChoices[$i][0] -eq [int]$Config.CheckInterval) { $sel = $i } }
    $intervalBox.SelectedIndex = $sel
    $intervalBox.Add_SelectedIndexChanged({
        Invoke-Safe {
            $sec = $intervalChoices[$intervalBox.SelectedIndex][0]
            if ([int]$Config.CheckInterval -eq $sec) { return }
            $Config.CheckInterval = $sec
            Save-Config $Config
            Set-CheckInterval $sec
        }
    })
    $notify.Add_MouseMove({
        try { if (((Get-Date) - $ui.LastCheck).TotalSeconds -ge 3) { Update-Quietly } } catch { }
    })
    $menu.Add_Opening({ try { Update-Quietly } catch { } })

    foreach ($d in $Config.Devices) { [void](Add-DeviceRow $d) }
    $form.Controls.AddRange(@($grid, $info))
    $form.Add_Shown({ try { $grid.ClearSelection() } catch { } })
    # Minimising or closing the window only hides it; the app keeps running in the tray until Exit.
    $form.Add_Resize({
        if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $form.Hide() }
    })
    $form.Add_FormClosing({
        param($s, $e)
        if ($grid.IsCurrentCellInEditMode) { try { [void]$grid.EndEdit() } catch { } }
        if (-not $ui.Exiting -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $e.Cancel = $true
            $form.Hide()
            if (-not $ui.HintShown) {
                $ui.HintShown = $true
                $notify.ShowBalloonTip(4000, 'CAKE Switch', 'Still running in the notification area. Right-click the icon to switch CAKE or to exit.', [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }
    })
    $form.Add_FormClosed({ try { Exit-App } catch { } })   # e.g. Windows shutting down

    # If autostart is on but its entry points at a script that no longer exists (the folder was moved),
    # point it here. Entries that point at another existing copy (e.g. the installed one, while a
    # test copy runs) are left alone.
    try {
        if (Test-Autostart) {
            $current = "$((Get-ItemProperty -LiteralPath $AutostartKey -Name $AutostartName).$AutostartName)"
            $m = [regex]::Match($current, '-File\s+"([^"]+)"')
            if ($m.Success -and -not (Test-Path -LiteralPath $m.Groups[1].Value)) { Set-Autostart $true }
        }
    } catch { }
    Sync-Autostart
    foreach ($r in $grid.Rows) { Start-Row $r 'status' }
    $timer.Start()
    Set-CheckInterval ([int]$Config.CheckInterval)
    Update-Tray
    $notify.Visible = $true
    # An ApplicationContext (instead of ShowDialog) lets the window be hidden without ending the app.
    $appContext = New-Object System.Windows.Forms.ApplicationContext
    if (-not $Tray) { Show-Window }
    [System.Windows.Forms.Application]::Run($appContext)
}

# --- command line ---------------------------------------------------------------------------------

function Get-TargetDevices {
    if ($Router) { return @(New-Device $Router $Router $User $Port $Interface) }
    if (-not $Device) {
        if ($Action -in @('Status', 'List') -or $Config.Devices.Count -eq 1) { return $Config.Devices }
        throw "Several devices are configured; choose with -Device <name> (wildcards allowed, -Device * for all). Devices: $(($Config.Devices | ForEach-Object Name) -join ', ')"
    }
    $found = @($Config.Devices | Where-Object { $d = $_; @($Device | Where-Object { $d.Name -like $_ -or $d.Address -like $_ }).Count -gt 0 })
    if ($found.Count -eq 0) { throw "No saved device matches '$($Device -join ', ')'. Devices: $(($Config.Devices | ForEach-Object Name) -join ', ')" }
    return $found
}

switch ($Action) {
    'Version' { Write-Output "CAKE Switch $AppVersion" }
    'Gui' { Show-Gui }
    'List' {
        Get-TargetDevices | Format-Table Name, Address, User, Port, Interface -AutoSize | Out-String -Width 200 | Write-Output
    }
    'SetupKey' {
        $targets = @(Get-TargetDevices)
        if ($targets.Count -ne 1) { throw 'SetupKey works on one device at a time.' }
        Install-SshKey $targets[0]
    }
    default {
        $jobs = @(Get-TargetDevices | ForEach-Object { Start-CakeJob $_ $Action.ToLower() })
        while (@($jobs | Where-Object { -not (Test-CakeJobDone $_) }).Count -gt 0) { Start-Sleep -Milliseconds 100 }
        $failed = $false
        foreach ($j in $jobs) {
            $r = Complete-CakeJob $j
            Write-Output (Format-Status $r)
            if ($r.Error) { $failed = $true }
        }
        if ($failed) { exit 1 }
    }
}

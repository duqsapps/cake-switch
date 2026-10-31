<#
.SYNOPSIS
    Switch SQM/CAKE on or off on one or more OpenWrt devices (router, access points) from Windows.

.DESCRIPTION
    Connects to each device with the OpenSSH client built into Windows 10/11 and flips the
    "enabled" flag of its SQM queue(s) (sqm-scripts / luci-app-sqm), then restarts SQM so CAKE
    is actually removed from / added to the interface.

    Devices are stored in cake-switch.json next to this script. Run without -Action to open the
    GUI, where devices can be added, removed and edited (name, IP address, user, port, interface)
    at any time.

.EXAMPLE
    .\CakeSwitch.ps1                                   # GUI
.EXAMPLE
    .\CakeSwitch.ps1 -Action Status                    # status of all devices
.EXAMPLE
    .\CakeSwitch.ps1 -Action Off -Device "Main router"
.EXAMPLE
    .\CakeSwitch.ps1 -Action On -Device AP*            # wildcards match name or address
.EXAMPLE
    .\CakeSwitch.ps1 -Action Toggle -Router 192.168.1.3 -Interface br-lan   # ad-hoc device, not saved
.EXAMPLE
    .\CakeSwitch.ps1 -Action SetupKey -Device "AP 1"   # one-time: install your SSH key on a device
#>
[CmdletBinding()]
param(
    [ValidateSet('Gui', 'Status', 'On', 'Off', 'Toggle', 'List', 'SetupKey')]
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
    [string]$ConfigFile = (Join-Path $PSScriptRoot 'cake-switch.json')
)

$ErrorActionPreference = 'Stop'

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
    $cfg = [pscustomobject]@{ KeyFile = ''; Devices = @() }
    if (Test-Path -LiteralPath $ConfigFile) {
        $json = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
        if ($json.KeyFile) { $cfg.KeyFile = $json.KeyFile }
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
    $data = [ordered]@{
        KeyFile = "$($cfg.KeyFile)"
        Devices = @($cfg.Devices | ForEach-Object {
            $p = 22; [void][int]::TryParse("$($_.Port)", [ref]$p)
            [ordered]@{ Name = "$($_.Name)"; Address = "$($_.Address)"; User = "$($_.User)"; Port = $p; Interface = "$($_.Interface)" }
        })
    }
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
#   QUEUE <section> <interface> <enabled 0|1> <qdisc>
#   ACTIVE <0|1>       (1 = a cake qdisc is currently installed)
#   ERROR <message>

$RemoteScript = @'
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

if [ "$ACTION" = "toggle" ]; then
    ACTION=on
    for s in $secs; do
        [ "$(uci -q get sqm.$s.enabled)" = "1" ] && ACTION=off
    done
fi

if [ "$ACTION" = "on" ] || [ "$ACTION" = "off" ]; then
    v=0; [ "$ACTION" = "on" ] && v=1
    for s in $secs; do uci set sqm.$s.enabled=$v; done
    uci commit sqm
    /etc/init.d/sqm restart >/dev/null 2>&1
fi

for s in $secs; do
    echo "QUEUE $s $(uci -q get sqm.$s.interface) $(uci -q get sqm.$s.enabled || echo 0) $(uci -q get sqm.$s.qdisc)"
done
if tc qdisc show 2>/dev/null | grep -q '^qdisc cake '; then echo "ACTIVE 1"; else echo "ACTIVE 0"; fi
'@

# --- running it: jobs are started without waiting, so several devices are handled in parallel ---

function Start-CakeJob($d, [ValidateSet('on', 'off', 'toggle', 'status')][string]$Verb) {
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
        $script = "ACTION=$Verb`nIFACE=$($d.Interface)`n" + $RemoteScript
        $job.Process.StandardInput.Write($script.Replace("`r`n", "`n"))
        $job.Process.StandardInput.Close()
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
    $result = [pscustomobject]@{ Device = $d; Active = $false; Enabled = $false; Queues = @(); Error = $job.Error }
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
                $q = [pscustomobject]@{ Section = $f[1]; Interface = $f[2]; Enabled = ($f[3] -eq '1'); Qdisc = $f[4] }
                $result.Queues += $q
                if ($q.Enabled) { $result.Enabled = $true }
            }
            'ACTIVE' { $result.Active = ($f[1] -eq '1') }
            'ERROR' { $result.Error = ($f[1..($f.Count - 1)] -join ' ') }
        }
    }
    if ($p.ExitCode -ne 0 -and -not $result.Error) {
        if ($p.ExitCode -eq 255) {
            $result.Error = "SSH to $($d.User)@$($d.Address) failed: $err  (key/password problem? use 'Setup SSH key')"
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

function Format-Status($r) {
    $lines = @("$($r.Device.Name) [$($r.Device.Address)]: $(Get-StateText $r)")
    if ($r.Error) { $lines += "  $($r.Error)" }
    if ($r.Enabled -and -not $r.Active -and -not $r.Error) {
        $lines += '  (qdisc may not be cake, or SQM failed to start - check: logread | grep SQM)'
    }
    foreach ($q in $r.Queues) {
        $lines += "  queue {0,-14} iface {1,-12} enabled={2} qdisc={3}" -f $q.Section, $q.Interface, [int]$q.Enabled, $q.Qdisc
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
        $empty = if ($PSVersionTable.PSVersion.Major -ge 7 -and $PSNativeCommandArgumentPassing -ne 'Legacy') { '' } else { '""' }
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

# --- GUI ------------------------------------------------------------------------------------------

function Show-Gui {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'CAKE Switch'
    $form.ClientSize = New-Object System.Drawing.Size(780, 360)
    $form.MinimumSize = New-Object System.Drawing.Size(640, 300)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 12)
    $grid.Size = New-Object System.Drawing.Size(756, 250)
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
    $info.Size = New-Object System.Drawing.Size(756, 34)
    $info.Anchor = 'Bottom, Left, Right'
    $info.ForeColor = [System.Drawing.Color]::DimGray
    $info.Text = 'Edit a cell (double-click or F2) to change a device''s name, IP address, user, port or SQM interface; changes are saved automatically. Interface empty = all SQM queues on that device. Select several rows to switch them together.'

    $buttons = @{}
    $x = 12
    foreach ($b in @(@('On', 'On'), @('Off', 'Off'), @('Toggle', 'Toggle'), @('Refresh', 'Refresh all'),
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

    function Add-DeviceRow($d) {
        $i = $grid.Rows.Add($d.Name, $d.Address, $d.User, "$($d.Port)", $d.Interface, '')
        # Job = running ssh job; Next = action clicked while busy, started when the job finishes.
        $grid.Rows[$i].Tag = [pscustomobject]@{ Job = $null; Next = $null; Details = '' }
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
        $cell.Style.SelectionForeColor = $color
        $cell.ToolTipText = $details
        $row.Tag.Details = $details
    }

    function Start-Row($row, [string]$verb) {
        if ($row.Tag.Job) { $row.Tag.Next = $verb; return }
        $d = Get-RowDevice $row
        Set-RowStatus $row 'Working...' ([System.Drawing.Color]::Gray) ''
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
            try { $r = Complete-CakeJob $job } catch { $r = [pscustomobject]@{ Device = $job.Device; Error = $_.Exception.Message; Queues = @() } }
            $state = Get-StateText $r
            $text = if ($r.Error) { "Error: $($r.Error)" } elseif ($state -eq 'ON') { 'CAKE is ON' } elseif ($state -eq 'OFF') { 'CAKE is OFF' } else { $state }
            $color = switch ($state) {
                'ON' { [System.Drawing.Color]::ForestGreen }
                'OFF' { [System.Drawing.Color]::Firebrick }
                default { [System.Drawing.Color]::DarkOrange }
            }
            Set-RowStatus $row $text $color (Format-Status $r)
            if ($row.Tag.Next) {
                $verb = $row.Tag.Next
                $row.Tag.Next = $null
                Start-Row $row $verb
            }
        }
    })

    $grid.Add_CellValidating({
        param($s, $e)
        $name = $grid.Columns[$e.ColumnIndex].Name
        $problem = Get-FieldProblem $name ("$($e.FormattedValue)".Trim())
        if ($problem) {
            $e.Cancel = $true
            [void][System.Windows.Forms.MessageBox]::Show($problem, 'CAKE Switch')
        }
    })
    $grid.Add_CellEndEdit({
        param($s, $e)
        $row = $grid.Rows[$e.RowIndex]
        Save-Grid
        $col = $grid.Columns[$e.ColumnIndex].Name
        if (@('Address', 'User', 'Port', 'Interface') -contains $col -and (Get-RowDevice $row).Address) { Start-Row $row 'status' }
    })
    $grid.Add_CellDoubleClick({
        param($s, $e)
        if ($e.RowIndex -ge 0 -and $grid.Columns[$e.ColumnIndex].Name -eq 'Status') {
            $t = $grid.Rows[$e.RowIndex].Tag.Details
            if ($t) { [void][System.Windows.Forms.MessageBox]::Show($t, 'CAKE Switch - details') }
        } elseif ($e.RowIndex -ge 0) {
            [void]$grid.BeginEdit($true)
        }
    })

    $buttons['On'].Add_Click({ Start-Selected 'on' })
    $buttons['Off'].Add_Click({ Start-Selected 'off' })
    $buttons['Toggle'].Add_Click({ Start-Selected 'toggle' })
    $buttons['Refresh'].Add_Click({
        if ($grid.IsCurrentCellInEditMode -and -not $grid.EndEdit()) { return }
        foreach ($r in $grid.Rows) { Start-Row $r 'status' }
    })
    $buttons['Add'].Add_Click({
        $row = Add-DeviceRow (New-Device "Device $($grid.Rows.Count + 1)" '')
        Save-Grid
        $grid.ClearSelection()
        $grid.CurrentCell = $row.Cells['Address']
        [void]$grid.BeginEdit($true)
    })
    $buttons['Remove'].Add_Click({
        $rows = @($grid.SelectedRows)
        if ($rows.Count -eq 0) { return }
        $names = ($rows | ForEach-Object { (Get-RowDevice $_).Name }) -join ', '
        if ([System.Windows.Forms.MessageBox]::Show("Remove $names from the list?`n(Nothing is changed on the device.)", 'CAKE Switch', 'YesNo') -eq 'Yes') {
            foreach ($r in $rows) { $grid.Rows.Remove($r) }
            Save-Grid
        }
    })
    $buttons['Key'].Add_Click({
        $row = $grid.CurrentRow
        if (-not $row) { return }
        $d = Get-RowDevice $row
        $problem = Get-DeviceProblem $d
        if ($problem) { [void][System.Windows.Forms.MessageBox]::Show($problem, 'CAKE Switch'); return }
        # Password prompts need a real console, so run the setup in its own window.
        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"", '-Action', 'SetupKey',
                    '-Router', $d.Address, '-User', $d.User, '-Port', $d.Port, '-ConfigFile', "`"$ConfigFile`"")
        Start-Process powershell.exe -ArgumentList $psArgs
    })

    foreach ($d in $Config.Devices) { [void](Add-DeviceRow $d) }
    $form.Controls.AddRange(@($grid, $info))
    $form.Add_Shown({ $grid.ClearSelection(); foreach ($r in $grid.Rows) { Start-Row $r 'status' } ; $timer.Start() })
    $form.Add_FormClosing({ $timer.Stop(); if ($grid.IsCurrentCellInEditMode) { [void]$grid.EndEdit() } })
    [void]$form.ShowDialog()
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
    'Gui' { Show-Gui }
    'List' {
        Get-TargetDevices | Format-Table Name, Address, User, Port, Interface -AutoSize | Out-String | Write-Output
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

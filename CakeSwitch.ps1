<#
.SYNOPSIS
    Switch SQM/CAKE on or off on an OpenWrt router from Windows.

.DESCRIPTION
    Connects to the router with the OpenSSH client built into Windows 10/11 and
    flips the "enabled" flag of the SQM queue(s) (sqm-scripts / luci-app-sqm),
    then restarts SQM so CAKE is actually removed from / added to the interface.

    Run without -Action to open a small GUI window.

.EXAMPLE
    .\CakeSwitch.ps1 -Action Status
.EXAMPLE
    .\CakeSwitch.ps1 -Action Off -Router 192.168.1.1
.EXAMPLE
    .\CakeSwitch.ps1 -Action Toggle -Interface eth1
.EXAMPLE
    .\CakeSwitch.ps1 -Action SetupKey     # one-time: install your SSH key on the router
.EXAMPLE
    .\CakeSwitch.ps1                       # GUI
#>
[CmdletBinding()]
param(
    [ValidateSet('On', 'Off', 'Toggle', 'Status', 'SetupKey', 'Gui')]
    [string]$Action = 'Gui',
    [string]$Router,
    [string]$User,
    [int]$Port,
    [string]$KeyFile,
    # Only touch SQM queues bound to this interface (e.g. eth1, wan, pppoe-wan). Empty = all queues.
    [string]$Interface,
    [string]$ConfigFile = (Join-Path $PSScriptRoot 'cake-switch.json')
)

$ErrorActionPreference = 'Stop'

# --- configuration: defaults < cake-switch.json < command-line parameters ---------------------

$Config = [ordered]@{ Router = '192.168.1.1'; User = 'root'; Port = 22; KeyFile = ''; Interface = '' }
if (Test-Path -LiteralPath $ConfigFile) {
    $json = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
    foreach ($k in @($Config.Keys)) {
        if ($null -ne $json.$k -and "$($json.$k)" -ne '') { $Config[$k] = $json.$k }
    }
}
foreach ($k in @($Config.Keys)) {
    if ($PSBoundParameters.ContainsKey($k)) { $Config[$k] = $PSBoundParameters[$k] }
}

if ($Config.Interface -notmatch '^[A-Za-z0-9._@-]*$') { throw "Invalid interface name: $($Config.Interface)" }
if ($Config.User -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid user name: $($Config.User)" }
if ($Config.Router -notmatch '^[A-Za-z0-9.:\[\]-]+$') { throw "Invalid router address: $($Config.Router)" }

function Get-SshExe {
    $cmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @("$env:WINDIR\System32\OpenSSH\ssh.exe", "$env:WINDIR\Sysnative\OpenSSH\ssh.exe")) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    throw "ssh.exe not found. Install it via Settings > Apps > Optional features > 'OpenSSH Client'."
}

function Get-SshArgs {
    $a = @('-p', "$($Config.Port)", '-o', 'ConnectTimeout=6', '-o', 'StrictHostKeyChecking=accept-new')
    if ($Config.KeyFile) { $a += @('-i', $Config.KeyFile) }
    return $a
}

# --- the shell script that runs on the router ------------------------------------------------
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

function Invoke-Cake([ValidateSet('on', 'off', 'toggle', 'status')][string]$Verb) {
    # The script is fed via stdin to "sh -s", which avoids all Windows command-line quoting issues.
    # BatchMode makes ssh fail instead of hanging on a password prompt nobody can see.
    $argList = @('-o', 'BatchMode=yes') + (Get-SshArgs) + @("$($Config.User)@$($Config.Router)", 'sh', '-s')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Get-SshExe
    $psi.Arguments = ($argList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()
    $script = "ACTION=$Verb`nIFACE=$($Config.Interface)`n" + $RemoteScript
    $p.StandardInput.Write($script.Replace("`r`n", "`n"))
    $p.StandardInput.Close()
    if (-not $p.WaitForExit(45000)) {
        try { $p.Kill() } catch { }
        throw "Timed out talking to $($Config.Router)."
    }
    $p.WaitForExit()
    $out = $stdoutTask.Result
    $err = $stderrTask.Result.Trim()

    $result = [pscustomobject]@{ Active = $false; Enabled = $false; Queues = @(); Error = $null }
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
            $result.Error = "SSH to $($Config.User)@$($Config.Router) failed: $err`nIf this is a key/password issue, run: CakeSwitch.cmd -Action SetupKey"
        } else {
            $result.Error = "Router command failed (exit $($p.ExitCode)). $err"
        }
    }
    return $result
}

function Format-Status($r) {
    if ($r.Error) { return "Error: $($r.Error)" }
    $state = if ($r.Active) { 'ON (cake qdisc active)' } elseif ($r.Enabled) { 'ENABLED, but no cake qdisc is active (qdisc may not be cake, or SQM failed to start)' } else { 'OFF' }
    $lines = @("CAKE/SQM: $state")
    foreach ($q in $r.Queues) {
        $lines += "  queue {0,-14} iface {1,-12} enabled={2} qdisc={3}" -f $q.Section, $q.Interface, [int]$q.Enabled, $q.Qdisc
    }
    return $lines -join "`r`n"
}

function Install-SshKey {
    $sshDir = Join-Path $env:USERPROFILE '.ssh'
    $key = if ($Config.KeyFile) { $Config.KeyFile } else { Join-Path $sshDir 'id_ed25519' }
    if (-not (Test-Path -LiteralPath $key)) {
        if (-not (Test-Path -LiteralPath $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
        Write-Host "Creating SSH key $key (no passphrase, so the switch works without prompting)..."
        $keygen = Join-Path (Split-Path (Get-SshExe)) 'ssh-keygen.exe'
        # Windows PowerShell 5.1 drops empty native arguments, so it needs '""' to pass an empty passphrase.
        $empty = if ($PSVersionTable.PSVersion.Major -ge 7 -and $PSNativeCommandArgumentPassing -ne 'Legacy') { '' } else { '""' }
        & $keygen -q -t ed25519 -N $empty -f $key
        if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen failed.' }
    }
    $pub = (Get-Content -LiteralPath "$key.pub" -Raw).Trim()
    if ($pub -match "'") { throw 'Unexpected character in public key.' }
    Write-Host "Installing public key on $($Config.User)@$($Config.Router). Enter the router's root password when asked."
    $remote = "mkdir -p /etc/dropbear && touch /etc/dropbear/authorized_keys && chmod 600 /etc/dropbear/authorized_keys && " +
              "(grep -qxF '$pub' /etc/dropbear/authorized_keys || echo '$pub' >> /etc/dropbear/authorized_keys) && echo KEY_OK"
    $sshArgs = Get-SshArgs
    if (-not $Config.KeyFile) { $sshArgs += @('-i', $key) }
    & (Get-SshExe) @sshArgs "$($Config.User)@$($Config.Router)" $remote
    if ($LASTEXITCODE -ne 0) { throw 'Installing the key failed.' }
    Write-Host 'Done. Testing passwordless connection...'
    Write-Host (Format-Status (Invoke-Cake 'status'))
}

function Show-Gui {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'CAKE Switch'
    $form.ClientSize = New-Object System.Drawing.Size(460, 250)
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $title = New-Object System.Windows.Forms.Label
    $title.Location = New-Object System.Drawing.Point(12, 10)
    $title.Size = New-Object System.Drawing.Size(436, 20)
    $iface = if ($Config.Interface) { " ($($Config.Interface))" } else { '' }
    $title.Text = "Router: $($Config.User)@$($Config.Router):$($Config.Port)$iface"

    $state = New-Object System.Windows.Forms.Label
    $state.Location = New-Object System.Drawing.Point(12, 34)
    $state.Size = New-Object System.Drawing.Size(436, 36)
    $state.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
    $state.Text = '...'

    $details = New-Object System.Windows.Forms.TextBox
    $details.Location = New-Object System.Drawing.Point(12, 74)
    $details.Size = New-Object System.Drawing.Size(436, 120)
    $details.Multiline = $true
    $details.ReadOnly = $true
    $details.ScrollBars = 'Vertical'
    $details.Font = New-Object System.Drawing.Font('Consolas', 9)

    $buttons = @{}
    $x = 12
    foreach ($name in @('On', 'Off', 'Toggle', 'Refresh')) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $name
        $b.Location = New-Object System.Drawing.Point($x, 206)
        $b.Size = New-Object System.Drawing.Size(102, 32)
        $form.Controls.Add($b)
        $buttons[$name] = $b
        $x += 111
    }

    $run = {
        param([string]$verb)
        foreach ($b in $buttons.Values) { $b.Enabled = $false }
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $state.Text = 'Working...'
        $state.ForeColor = [System.Drawing.Color]::Gray
        $form.Refresh()
        try { $r = Invoke-Cake $verb } catch { $r = [pscustomobject]@{ Error = $_.Exception.Message } }
        if ($r.Error) {
            $state.Text = 'Error'
            $state.ForeColor = [System.Drawing.Color]::DarkOrange
        } elseif ($r.Active) {
            $state.Text = 'CAKE is ON'
            $state.ForeColor = [System.Drawing.Color]::ForestGreen
        } elseif ($r.Enabled) {
            $state.Text = 'Enabled, not active'
            $state.ForeColor = [System.Drawing.Color]::DarkOrange
        } else {
            $state.Text = 'CAKE is OFF'
            $state.ForeColor = [System.Drawing.Color]::Firebrick
        }
        $details.Text = Format-Status $r
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        foreach ($b in $buttons.Values) { $b.Enabled = $true }
    }

    $buttons['On'].Add_Click({ & $run 'on' })
    $buttons['Off'].Add_Click({ & $run 'off' })
    $buttons['Toggle'].Add_Click({ & $run 'toggle' })
    $buttons['Refresh'].Add_Click({ & $run 'status' })
    $form.Add_Shown({ & $run 'status' })

    $form.Controls.AddRange(@($title, $state, $details))
    [void]$form.ShowDialog()
}

switch ($Action) {
    'Gui' { Show-Gui }
    'SetupKey' { Install-SshKey }
    default {
        $r = Invoke-Cake $Action.ToLower()
        Write-Output (Format-Status $r)
        if ($r.Error) { exit 1 }
    }
}

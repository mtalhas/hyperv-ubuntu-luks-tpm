# Boots the finished VM and confirms it unlocks the disk on its own.
# Reaching SSH at all is the proof: the root filesystem is encrypted, so if the
# disk did not unlock from the TPM the machine could not have booted this far.

function Invoke-Ssh {
    param([hashtable]$Creds, [string]$IpAddress, [string]$User, [string]$Command, [int]$ConnectTimeout = 6)
    # Throwaway known_hosts in the temp folder. An absolute path is used on purpose:
    # passing NUL would make ssh create a file named NUL in the current folder, and
    # NUL is a reserved name that git cannot handle.
    $knownHosts = Join-Path ([System.IO.Path]::GetTempPath()) 'hyperv-build-known_hosts'
    $sshArgs = @(
        '-i', $Creds.SshKeyPath,
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=no',
        '-o', "UserKnownHostsFile=$knownHosts",
        '-o', "ConnectTimeout=$ConnectTimeout",
        '-o', 'LogLevel=ERROR',
        "$User@$IpAddress", $Command
    )
    # While the VM is still booting these calls fail. That is expected, so the
    # failures must not stop the build. Quieten errors here and let the caller
    # retry on an empty result.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $out = & ssh.exe @sshArgs 2>$null
    $ErrorActionPreference = $prevEap
    return $out
}

function Wait-ForSsh {
    param([hashtable]$Config, [hashtable]$Creds, [int]$TimeoutSeconds = 600)
    $ip = ($Config.IpCidr -split '/')[0]
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $out = Invoke-Ssh -Creds $Creds -IpAddress $ip -User $Config.Username -Command 'hostname'
        if ($out -and ($out.Trim() -eq $Config.Hostname)) { return $true }
        Start-Sleep -Seconds 10
    }
    return $false
}

function Assert-BootedOrExplain {
    # Wait for the installed system. If it never appears, save the console and give
    # an honest message: the host cannot tell a passphrase prompt apart from a slow
    # boot, so it points at the screenshot rather than blaming one cause.
    param([hashtable]$Config, [hashtable]$Creds, [int]$TimeoutSeconds, [string]$OutDir, [string]$Stage)
    if (Wait-ForSsh -Config $Config -Creds $Creds -TimeoutSeconds $TimeoutSeconds) { return }
    $shot = Save-VmConsole -VMName $Config.VmName -OutPath (Join-Path $OutDir "verify-$Stage-console.png")
    $msg = "The VM did not reach SSH within $TimeoutSeconds seconds on $Stage."
    if ($shot) {
        $msg += " A screenshot of the console is at $shot. If it shows 'Please enter passphrase for disk', the TPM unlock did not take, so the clevis enrollment during install did not work. If it shows a login prompt, the network or SSH is the problem rather than the disk."
    }
    throw $msg
}

function Invoke-Verify {
    param([hashtable]$Config, [hashtable]$Creds)

    $vm = $Config.VmName
    $ip = ($Config.IpCidr -split '/')[0]
    $outDir = Join-Path $Config.OutputDir $vm
    $firstTimeout = if ($Config.ContainsKey('VerifyTimeoutSeconds') -and $Config.VerifyTimeoutSeconds) { [int]$Config.VerifyTimeoutSeconds } else { 600 }
    $coldTimeout = if ($Config.ContainsKey('ColdBootTimeoutSeconds') -and $Config.ColdBootTimeoutSeconds) { [int]$Config.ColdBootTimeoutSeconds } else { 360 }

    Write-BuildLog "Verifying the finished VM" STEP
    Start-VM -Name $vm
    Assert-BootedOrExplain -Config $Config -Creds $Creds -TimeoutSeconds $firstTimeout -OutDir $outDir -Stage 'firstboot'
    Write-BuildLog "Booted to SSH with no passphrase prompt. The disk unlocked from the TPM." INFO

    # Pull the in VM record of the encryption setup and keep a copy with the build.
    # If the marker is missing, the enrollment did not finish and we say so plainly.
    $pw = $Creds.UserPassword
    $log = Invoke-Ssh -Creds $Creds -IpAddress $ip -User $Config.Username -Command "echo '$pw' | sudo -S cat /root/post-install.log 2>/dev/null"
    if ($log) { ($log -join "`n") | Set-Content -Path (Join-Path $outDir 'post-install.log') -Encoding UTF8 }
    if (($log -join "`n") -notmatch 'POST-INSTALL-DONE') {
        Write-BuildLog "post-install.log did not contain the success marker." WARN
        throw "The encryption setup step did not complete during install. The in VM log was saved to $(Join-Path $outDir 'post-install.log'). Check the end of it for the failing command."
    }

    $rootSrc = (Invoke-Ssh -Creds $Creds -IpAddress $ip -User $Config.Username -Command 'findmnt -no SOURCE /')
    $isLuks  = (Invoke-Ssh -Creds $Creds -IpAddress $ip -User $Config.Username -Command 'lsblk -o TYPE,FSTYPE | grep -c crypto_LUKS')
    $clevis  = (Invoke-Ssh -Creds $Creds -IpAddress $ip -User $Config.Username `
            -Command "echo '$pw' | sudo -S sh -c 'clevis luks list -d `$(blkid -t TYPE=crypto_LUKS -o device | head -n1)' 2>/dev/null")
    Write-BuildLog "Root device: $rootSrc" INFO
    Write-BuildLog "Encrypted partitions: $($isLuks.Trim())" INFO
    Write-BuildLog "TPM binding: $clevis" INFO

    # Cold boot, to prove the unlock is repeatable and not a first boot fluke.
    Write-BuildLog "Power cycling to confirm the unlock repeats." INFO
    Stop-VM -Name $vm -Force
    $t = 0; while ((Get-VM -Name $vm).State -ne 'Off' -and $t -lt 120) { Start-Sleep -Seconds 5; $t += 5 }
    if ((Get-VM -Name $vm).State -ne 'Off') { Stop-VM -Name $vm -TurnOff -Force; Start-Sleep 3 }
    Start-VM -Name $vm
    Assert-BootedOrExplain -Config $Config -Creds $Creds -TimeoutSeconds $coldTimeout -OutDir $outDir -Stage 'coldboot'
    Write-BuildLog "Second boot also unlocked with no passphrase. Verified." INFO

    return [pscustomobject]@{
        Hostname   = $Config.Hostname
        IpAddress  = $ip
        RootDevice = ($rootSrc | Out-String).Trim()
        Encrypted  = ($isLuks.Trim() -ne '0')
        TpmBinding = ($clevis | Out-String).Trim()
    }
}

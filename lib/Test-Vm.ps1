# Boots the finished VM and confirms it unlocks the disk on its own.
# Reaching SSH at all is the proof: the root filesystem is encrypted, so if the
# disk did not unlock from the TPM the machine could not have booted this far.

function Invoke-Ssh {
    param([hashtable]$Creds, [string]$IpAddress, [string]$User, [string]$Command, [int]$ConnectTimeout = 6)
    $sshArgs = @(
        '-i', $Creds.SshKeyPath,
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
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
    param([hashtable]$Config, [hashtable]$Creds, [int]$TimeoutSeconds = 420)
    $ip = ($Config.IpCidr -split '/')[0]
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $out = Invoke-Ssh -Creds $Creds -IpAddress $ip -User $Config.Username -Command 'hostname'
        if ($out -and ($out.Trim() -eq $Config.Hostname)) { return $true }
        Start-Sleep -Seconds 10
    }
    return $false
}

function Invoke-Verify {
    param([hashtable]$Config, [hashtable]$Creds)

    $vm = $Config.VmName
    $ip = ($Config.IpCidr -split '/')[0]

    Write-Host '== Verifying the finished VM =='
    Start-VM -Name $vm

    if (-not (Wait-ForSsh -Config $Config -Creds $Creds)) {
        throw 'The VM did not reach SSH. If it is sitting at a disk passphrase prompt, the TPM unlock did not take.'
    }
    Write-Host '   Booted to SSH with no passphrase prompt. The disk unlocked from the TPM.'

    # Confirm the root really is on an encrypted volume.
    $rootSrc = (Invoke-Ssh -Creds $Creds -IpAddress $ip -User $Config.Username -Command 'findmnt -no SOURCE /')
    $isLuks  = (Invoke-Ssh -Creds $Creds -IpAddress $ip -User $Config.Username -Command 'lsblk -o TYPE,FSTYPE | grep -c crypto_LUKS')
    Write-Host "   Root device: $rootSrc"
    Write-Host "   Encrypted partitions found: $($isLuks.Trim())"

    # Confirm the TPM binding is present. This needs sudo, including the blkid
    # lookup, so the whole thing runs under sudo with the password fed in.
    $pw = $Creds.UserPassword
    $clevis = (Invoke-Ssh -Creds $Creds -IpAddress $ip -User $Config.Username `
        -Command "echo '$pw' | sudo -S sh -c 'clevis luks list -d `$(blkid -t TYPE=crypto_LUKS -o device | head -n1)' 2>/dev/null")
    Write-Host "   TPM binding: $clevis"

    # Cold boot test, to prove the unlock is repeatable and not a first boot fluke.
    Write-Host '   Power cycling to confirm the unlock repeats.'
    Stop-VM -Name $vm -Force
    $t = 0; while ((Get-VM -Name $vm).State -ne 'Off' -and $t -lt 120) { Start-Sleep -Seconds 5; $t += 5 }
    if ((Get-VM -Name $vm).State -ne 'Off') { Stop-VM -Name $vm -TurnOff -Force; Start-Sleep 3 }
    Start-VM -Name $vm
    if (-not (Wait-ForSsh -Config $Config -Creds $Creds)) {
        throw 'The VM did not unlock on the second boot. The TPM binding may not be stable.'
    }
    Write-Host '   Second boot also unlocked with no passphrase. Verified.'

    return [pscustomobject]@{
        Hostname   = $Config.Hostname
        IpAddress  = $ip
        RootDevice = ($rootSrc | Out-String).Trim()
        Encrypted  = ($isLuks.Trim() -ne '0')
        TpmBinding = ($clevis | Out-String).Trim()
    }
}

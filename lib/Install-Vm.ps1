# Runs the unattended install and leaves the VM ready to boot from its disk.

function Test-TcpPort {
    param([string]$IpAddress, [int]$Port, [int]$TimeoutMs = 3000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($IpAddress, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $client.EndConnect($iar); return $true
        }
        return $false
    } catch { return $false } finally { $client.Close() }
}

function Get-InstallProgress {
    # Pure decision for one poll of the install. Returns Decision (finished, failed
    # or continue) plus the carried state. The clock and the deadline are passed in
    # so this can be unit tested without sleeping or waiting on real time.
    #
    # The install ends one of two ways. Cleanly it powers the VM off. If the
    # installer is slow to power off, its ssh server stops answering when the
    # machine halts, so a port that was up and then stays down also means done.
    # Reaching the deadline while still running is a failure, not a success.
    param(
        [string]$State,
        [bool]$PortUp,
        [bool]$SeenUp,
        [datetime]$DownSince,   # [datetime]::MinValue means not currently down
        [datetime]$Now,
        [datetime]$Deadline,
        [int]$DownSeconds = 60
    )
    $notDown = [datetime]::MinValue
    if ($State -eq 'Off') {
        return @{ Decision = 'finished'; SeenUp = $SeenUp; DownSince = $DownSince }
    }
    $decision = 'continue'
    if ($PortUp) {
        $SeenUp = $true
        $DownSince = $notDown
    }
    elseif ($SeenUp) {
        if ($DownSince -eq $notDown) { $DownSince = $Now }
        elseif (($Now - $DownSince).TotalSeconds -ge $DownSeconds) { $decision = 'finished' }
    }
    if ($decision -ne 'finished' -and $Now -ge $Deadline) { $decision = 'failed' }
    return @{ Decision = $decision; SeenUp = $SeenUp; DownSince = $DownSince }
}

function Invoke-Install {
    param([hashtable]$Config)

    $vm = $Config.VmName
    $ip = ($Config.IpCidr -split '/')[0]
    $timeoutMin = if ($Config.ContainsKey('InstallTimeoutMinutes') -and $Config.InstallTimeoutMinutes) { [int]$Config.InstallTimeoutMinutes } else { 60 }
    $outDir = Join-Path $Config.OutputDir $vm

    Write-BuildLog "Running the unattended install (timeout $timeoutMin min)" STEP
    Start-VM -Name $vm

    # If the installer hits the random kernel fault it freezes with the network
    # still up, so the disk stops growing. Catching that lets a retry start in
    # minutes instead of waiting out the whole timeout.
    $vhdx = Join-Path $Config.VmDir ("{0}.vhdx" -f $vm)
    $stallMin = if ($Config.ContainsKey('StallMinutes') -and $Config.StallMinutes) { [int]$Config.StallMinutes } else { 15 }
    $lastSize = 0
    $lastGrowth = Get-Date

    $deadline  = (Get-Date).AddMinutes($timeoutMin)
    $seenUp    = $false
    $downSince = [datetime]::MinValue
    $decision  = 'continue'

    while ($decision -eq 'continue') {
        $state = (Get-VM -Name $vm).State
        $up = if ($state -eq 'Off') { $false } else { Test-TcpPort -IpAddress $ip -Port 22 -TimeoutMs 3000 }

        if ($state -ne 'Off') {
            $size = try { (Get-VHD -Path $vhdx -ErrorAction Stop).FileSize } catch { $lastSize }
            if ($size -gt $lastSize) { $lastSize = $size; $lastGrowth = Get-Date }
        }

        $p = Get-InstallProgress -State $state -PortUp $up -SeenUp $seenUp -DownSince $downSince -Now (Get-Date) -Deadline $deadline
        if ($p.SeenUp -and -not $seenUp) { Write-BuildLog "Installer is up and running." INFO }
        $seenUp = $p.SeenUp; $downSince = $p.DownSince; $decision = $p.Decision

        if ($decision -eq 'continue' -and $seenUp -and ((Get-Date) - $lastGrowth).TotalMinutes -ge $stallMin) {
            Write-BuildLog "The disk has not grown for $stallMin minutes while the installer is up. The install looks stalled." WARN
            $decision = 'failed'
        }
        if ($decision -eq 'continue') { Start-Sleep -Seconds 15 }
    }

    if ($decision -eq 'failed') {
        # Booting a half installed disk here would later look like a TPM problem, so
        # stop now and leave a picture of the console so the real cause is visible.
        $shot = Save-VmConsole -VMName $vm -OutPath (Join-Path $outDir 'install-failure-console.png')
        $hint = if ($seenUp) {
            "The installer started but did not finish within $timeoutMin minutes. The install likely failed or stalled."
        } else {
            "The installer never came up on the network. Check the static IP settings and that the source image is the expected Ubuntu Server image."
        }
        if ($shot) { $hint += " A screenshot of the console is at $shot." }
        throw $hint
    }

    Write-BuildLog "Install finished." INFO

    # The installer environment can sit in a half powered off state, so make sure.
    if ((Get-VM -Name $vm).State -ne 'Off') {
        Stop-VM -Name $vm -TurnOff -Force
        Start-Sleep -Seconds 3
    }

    # Remove the install media and boot from the disk from now on.
    Get-VMDvdDrive -VMName $vm | Set-VMDvdDrive -Path $null
    $hd  = Get-VMHardDiskDrive -VMName $vm
    $dvd = Get-VMDvdDrive -VMName $vm
    Set-VMFirmware -VMName $vm -BootOrder $hd, $dvd
    Write-BuildLog "Media removed, boot order set to the disk." INFO
}

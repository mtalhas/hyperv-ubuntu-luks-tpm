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

function Invoke-Install {
    param([hashtable]$Config)

    $vm = $Config.VmName
    $ip = ($Config.IpCidr -split '/')[0]

    Write-Host '== Running the unattended install =='
    Start-VM -Name $vm

    # The installer answers on port 22 while it runs. When the install finishes
    # the machine halts and that port stops answering. Watching for that change
    # is reliable even when the installer environment is slow to power the VM off.
    $deadline   = (Get-Date).AddMinutes(60)
    $seenUp     = $false
    $downSince  = $null

    while ((Get-Date) -lt $deadline) {
        if ((Get-VM -Name $vm).State -eq 'Off') {
            Write-Host '   Installer powered the VM off.'
            $seenUp = $true; break
        }
        $up = Test-TcpPort -IpAddress $ip -Port 22 -TimeoutMs 3000
        if ($up) {
            if (-not $seenUp) { Write-Host '   Installer is up and running.' }
            $seenUp = $true; $downSince = $null
        }
        elseif ($seenUp) {
            if (-not $downSince) { $downSince = Get-Date }
            elseif (((Get-Date) - $downSince).TotalSeconds -ge 60) {
                Write-Host '   Install finished (the machine has halted).'; break
            }
        }
        Start-Sleep -Seconds 15
    }

    if (-not $seenUp) {
        throw 'The installer never came up on the network. Check the static IP settings and the source image.'
    }

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
    Write-Host '   Install media removed, boot order set to the disk.'
}

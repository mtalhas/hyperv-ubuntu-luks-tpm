# Creates the Generation 2 VM in the exact order that keeps Secure Boot working
# for Linux and keeps the virtual TPM usable.
#
# Order matters. Once a virtual TPM is switched on, Hyper-V locks the Secure Boot
# template and refuses to change it. So the Linux template is set first, and the
# TPM is switched on last. Building the VM fresh each time sidesteps that lock.

function Remove-VmIfPresent {
    # Stops and removes a VM if it exists, leaving its disk file alone. Run before
    # rebuilding the install image too, because a leftover running VM keeps the
    # image file mounted and locked, which would fail the rebuild.
    param([string]$Name)
    $existing = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $existing) { return }
    if ($existing.State -ne 'Off') { Stop-VM -Name $Name -TurnOff -Force }
    Get-VMSnapshot -VMName $Name -ErrorAction SilentlyContinue | Remove-VMSnapshot -ErrorAction SilentlyContinue
    Remove-VM -Name $Name -Force
    Start-Sleep -Seconds 2
}

function Remove-FileWithRetry {
    # Right after Remove-VM the disk file can stay locked for a moment. Retry a few
    # times so the build does not fail with a transient "file in use".
    param([string]$Path, [int]$Tries = 10)
    for ($i = 0; $i -lt $Tries; $i++) {
        if (-not (Test-Path $Path)) { return }
        try { Remove-Item $Path -Force -ErrorAction Stop; return } catch { Start-Sleep -Seconds 2 }
    }
    throw "Could not remove '$Path' (still in use after $Tries tries)."
}

function New-EncryptedVm {
    param(
        [hashtable]$Config,
        [string]$IsoPath
    )

    $vm    = $Config.VmName
    $vmDir = $Config.VmDir
    $vhdx  = Join-Path $vmDir ("{0}.vhdx" -f $vm)

    Write-BuildLog "Creating VM '$vm'" STEP

    Remove-VmIfPresent -Name $vm

    if (-not (Test-Path $vmDir)) { New-Item -ItemType Directory -Path $vmDir -Force | Out-Null }
    Remove-FileWithRetry -Path $vhdx

    New-VHD -Path $vhdx -SizeBytes ($Config.DiskSizeGB * 1GB) -Dynamic | Out-Null

    New-VM -Name $vm -Generation 2 -MemoryStartupBytes ($Config.MemoryMB * 1MB) `
        -VHDPath $vhdx -SwitchName $Config.SwitchName | Out-Null

    Set-VMProcessor -VMName $vm -Count $Config.Cpus
    # Fixed memory. Dynamic memory can deadlock a Linux guest, so it stays off.
    Set-VMMemory -VMName $vm -DynamicMemoryEnabled $false -StartupBytes ($Config.MemoryMB * 1MB)

    # Automatic checkpoints would turn the disk into a differencing chain during
    # install, which complicates the encryption work. Turn them off.
    Set-VM -Name $vm -AutomaticCheckpointsEnabled $false `
        -AutomaticStartAction Nothing -AutomaticStopAction ShutDown

    Add-VMDvdDrive -VMName $vm -Path $IsoPath

    # Linux Secure Boot template, set while there is no TPM yet.
    Set-VMFirmware -VMName $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority

    # Boot from the DVD first so the installer runs. No network boot entry, so a
    # failed disk boot never drops to a PXE attempt.
    $dvd = Get-VMDvdDrive -VMName $vm
    $hd  = Get-VMHardDiskDrive -VMName $vm
    Set-VMFirmware -VMName $vm -BootOrder $dvd, $hd

    # Now add the virtual TPM. This is what the disk binds its unlock key to.
    Set-VMKeyProtector -VMName $vm -NewLocalKeyProtector
    Enable-VMTPM -VMName $vm
    Set-VMSecurity -VMName $vm -EncryptStateAndVmMigrationTraffic $true

    Write-BuildLog "VM created with Linux Secure Boot template and virtual TPM enabled." INFO
}

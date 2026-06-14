# Validates the config and the host before a build starts, so problems show up as
# clear messages now instead of cryptic failures deep inside a long run.

function Test-Config {
    param([hashtable]$Config)

    $required = @('VmName', 'Username', 'Hostname', 'SourceIso', 'VmDir', 'SwitchName',
        'IpCidr', 'Gateway', 'Dns', 'Cpus', 'MemoryMB', 'DiskSizeGB', 'OutputDir')
    foreach ($key in $required) {
        if (-not $Config.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$Config[$key])) {
            throw "Config is missing a value for '$key'. Copy config.example.ps1 to config.ps1 and fill it in."
        }
    }

    # Parse the address rather than pattern match it, so impossible octets like
    # 999 or a prefix over 32 are rejected, not just an obviously wrong shape.
    $ip4 = [System.Net.Sockets.AddressFamily]::InterNetwork
    $parsedIp = [System.Net.IPAddress]::None
    $prefix = 0
    $parts = [string]$Config.IpCidr -split '/'
    if ($parts.Count -ne 2 -or
        -not [System.Net.IPAddress]::TryParse($parts[0], [ref]$parsedIp) -or $parsedIp.AddressFamily -ne $ip4 -or
        -not [int]::TryParse($parts[1], [ref]$prefix) -or $prefix -lt 1 -or $prefix -gt 32) {
        throw "IpCidr '$($Config.IpCidr)' is not a valid IPv4 address with a prefix from 1 to 32, for example 192.168.50.10/24."
    }
    $parsedGw = [System.Net.IPAddress]::None
    if (-not [System.Net.IPAddress]::TryParse([string]$Config.Gateway, [ref]$parsedGw) -or $parsedGw.AddressFamily -ne $ip4) {
        throw "Gateway '$($Config.Gateway)' is not a valid IPv4 address."
    }
    if ($Config.VmName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$') {
        throw "VmName '$($Config.VmName)' has characters Hyper-V does not allow. Use letters, numbers, dot, dash, underscore."
    }
    if ([int]$Config.MemoryMB -lt 2048) { throw "MemoryMB is $($Config.MemoryMB). The installer needs at least 2048." }
    if ([int]$Config.Cpus -lt 1) { throw "Cpus must be at least 1." }
    if ([int]$Config.DiskSizeGB -lt 20) { throw "DiskSizeGB is $($Config.DiskSizeGB). Use at least 20." }

    Write-BuildLog "Config looks valid for VM '$($Config.VmName)' at $($Config.IpCidr)." INFO
}

function Invoke-Preflight {
    param([hashtable]$Config)

    Write-BuildLog "Preflight checks" STEP
    Test-Config -Config $Config

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    if (-not $isAdmin) { throw 'Run this build from an elevated PowerShell window (Run as administrator).' }

    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        throw 'The Hyper-V PowerShell module is not available. Enable the Hyper-V feature first.'
    }
    if (-not (Get-VMSwitch -Name $Config.SwitchName -ErrorAction SilentlyContinue)) {
        throw "Virtual switch '$($Config.SwitchName)' was not found. Create it or fix SwitchName in config.ps1."
    }
    if (-not (Test-Path $Config.SourceIso)) {
        throw "Source ISO not found at '$($Config.SourceIso)'. Download the Ubuntu Server image and set SourceIso."
    }

    # If a checksum is given, confirm the source image is exactly the expected one.
    # This keeps a silent point release swap or a partial download from changing the result.
    if ($Config.ContainsKey('IsoSha256') -and -not [string]::IsNullOrWhiteSpace([string]$Config.IsoSha256)) {
        Write-BuildLog "Verifying source ISO checksum" INFO
        $actual = (Get-FileHash -Path $Config.SourceIso -Algorithm SHA256).Hash
        if ($actual -ne $Config.IsoSha256.ToUpper()) {
            throw "Source ISO checksum does not match. Expected $($Config.IsoSha256), got $actual."
        }
        Write-BuildLog "ISO checksum matches." INFO
    }

    # Free space on the drive that will hold the VM disk and the rebuilt image.
    $driveLetter = ($Config.VmDir.Substring(0, 1))
    $free = (Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue).Free
    if ($null -ne $free -and $free -lt 20GB) {
        throw "Drive $($driveLetter): has only $([math]::Round($free/1GB,1)) GB free. The build needs room for the disk and a rebuilt image."
    }

    if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
        throw 'The Windows OpenSSH client (ssh.exe) was not found. Install the OpenSSH Client optional feature.'
    }
    if (-not (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue)) {
        throw 'ssh-keygen.exe was not found. Install the OpenSSH Client optional feature.'
    }

    # The image rebuild step needs xorriso, which runs in WSL. Everything else is native.
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'wsl.exe was not found. Install WSL with an Ubuntu distribution. It is used only for the image rebuild step.'
    }
    $distroArg = if ($Config.ContainsKey('WslDistro') -and $Config.WslDistro) { @('-d', $Config.WslDistro) } else { @() }
    # Confirm the distro is apt based before trying to install xorriso into it.
    if ((Invoke-WslQuery -DistroArgs $distroArg -Command 'command -v apt-get >/dev/null 2>&1 && echo yes || echo no') -ne 'yes') {
        throw 'The WSL distribution is not Debian or Ubuntu based (no apt-get). Set WslDistro in config to an Ubuntu distro.'
    }
    if ((Invoke-WslQuery -DistroArgs $distroArg -Command 'command -v xorriso >/dev/null 2>&1 && echo yes || echo no') -ne 'yes') {
        Write-BuildLog "Installing xorriso inside WSL (one time)." INFO
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        (& wsl.exe @distroArg -u root -e bash -lc 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y xorriso' 2>&1) | Write-NativeOutputToLog
        $ErrorActionPreference = $prev
        if ((Invoke-WslQuery -DistroArgs $distroArg -Command 'command -v xorriso >/dev/null 2>&1 && echo yes || echo no') -ne 'yes') {
            throw 'Could not install xorriso inside WSL.'
        }
    }

    # Confirm WSL has room to extract the image (a few GB). No awk, to avoid the
    # PowerShell dollar sign eating the field reference.
    $wslFreeKb = Invoke-WslQuery -DistroArgs $distroArg -Command 'df -k --output=avail /tmp | tail -1 | tr -d " "'
    if ($wslFreeKb -match '^\d+$' -and [int64]$wslFreeKb -lt 8000000) {
        Write-BuildLog "WSL /tmp has under 8 GB free. The image rebuild may fail if it runs out of room." WARN
    }

    Write-BuildLog "All preflight checks passed." INFO
}

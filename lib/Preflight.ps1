# Checks that the host has everything needed before a build starts.
# Fails early with a clear message rather than partway through a long install.

function Invoke-Preflight {
    param([hashtable]$Config)

    Write-Host '== Preflight =='

    # Administrator rights are required for Hyper-V management.
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    if (-not $isAdmin) { throw 'Run this build from an elevated PowerShell window (Run as administrator).' }

    # Hyper-V management module.
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        throw 'The Hyper-V PowerShell module is not available. Enable the Hyper-V feature first.'
    }

    # Target virtual switch.
    if (-not (Get-VMSwitch -Name $Config.SwitchName -ErrorAction SilentlyContinue)) {
        throw "Virtual switch '$($Config.SwitchName)' was not found. Create it or fix SwitchName in config.ps1."
    }

    # Source install image.
    if (-not (Test-Path $Config.SourceIso)) {
        throw "Source ISO not found at '$($Config.SourceIso)'. Download the Ubuntu Server image and set SourceIso."
    }

    # Native OpenSSH client, used later to verify the finished VM over the network.
    if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
        throw 'The Windows OpenSSH client (ssh.exe) was not found. Install the OpenSSH Client optional feature.'
    }
    if (-not (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue)) {
        throw 'ssh-keygen.exe was not found. Install the OpenSSH Client optional feature.'
    }

    # The image rebuild step uses xorriso. The only supported home for it today is
    # a WSL Ubuntu install. Everything else in this build runs as native Windows.
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) {
        throw 'wsl.exe was not found. Install WSL with an Ubuntu distribution. It is used only for the image rebuild step.'
    }
    $hasXorriso = (wsl.exe -u root -e bash -lc 'command -v xorriso >/dev/null 2>&1 && echo yes || echo no' 2>$null) -join ''
    if ($hasXorriso.Trim() -ne 'yes') {
        Write-Host '   xorriso is not installed in WSL yet. Installing it now.'
        wsl.exe -u root -e bash -lc 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y xorriso' 2>&1 | Out-Null
        $hasXorriso = (wsl.exe -u root -e bash -lc 'command -v xorriso >/dev/null 2>&1 && echo yes || echo no' 2>$null) -join ''
        if ($hasXorriso.Trim() -ne 'yes') { throw 'Could not install xorriso inside WSL.' }
    }

    Write-Host '   All checks passed.'
}

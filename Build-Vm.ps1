<#
.SYNOPSIS
    Builds a Hyper-V Generation 2 Ubuntu Server VM with an encrypted disk that
    unlocks itself from the virtual TPM, with no passphrase prompt at boot.

.DESCRIPTION
    Runs the whole build end to end and leaves a working, verified VM.
      1. Checks the host has what it needs.
      2. Generates a password, a disk passphrase and an SSH key for this VM.
      3. Rebuilds the install image with an unattended answer file.
      4. Creates the VM with the Linux Secure Boot template and a virtual TPM.
      5. Runs the install with no interaction.
      6. Boots the result and confirms it unlocks on its own, twice.

.EXAMPLE
    Copy config.example.ps1 to config.ps1, edit it, then from an elevated prompt:
        .\Build-Vm.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot

# Resolve the config path here, not in the param default. The automatic variable
# that points at the script folder is not reliably set while param defaults run.
if (-not $ConfigPath) { $ConfigPath = Join-Path $repoRoot 'config.ps1' }

if (-not (Test-Path $ConfigPath)) {
    throw "No config found at '$ConfigPath'. Copy config.example.ps1 to config.ps1 and edit it."
}
$Config = & $ConfigPath

. (Join-Path $repoRoot 'lib\Preflight.ps1')
. (Join-Path $repoRoot 'lib\New-AutoinstallIso.ps1')
. (Join-Path $repoRoot 'lib\New-Vm.ps1')
. (Join-Path $repoRoot 'lib\Install-Vm.ps1')
. (Join-Path $repoRoot 'lib\Test-Vm.ps1')

Write-Host ''
Write-Host "Building '$($Config.VmName)' on this host." -ForegroundColor Cyan
Write-Host ''

Invoke-Preflight -Config $Config

$creds  = New-BuildCredentials -Config $Config
$isoPath = New-AutoinstallImage -Config $Config -Creds $creds -RepoRoot $repoRoot
New-EncryptedVm -Config $Config -IsoPath $isoPath
Invoke-Install -Config $Config
$result = Invoke-Verify -Config $Config -Creds $creds

Write-Host ''
Write-Host 'Build complete.' -ForegroundColor Green
Write-Host ('  Host name    : {0}' -f $result.Hostname)
Write-Host ('  Address      : {0}' -f $result.IpAddress)
Write-Host ('  Root device  : {0}' -f $result.RootDevice)
Write-Host ('  Encrypted    : {0}' -f $result.Encrypted)
Write-Host ('  TPM binding  : {0}' -f $result.TpmBinding)
Write-Host ''
Write-Host ('  Credentials  : {0}' -f (Join-Path (Join-Path $Config.OutputDir $Config.VmName) '.env'))
Write-Host ('  Log in with  : ssh -i "{0}" {1}@{2}' -f $creds.SshKeyPath, $Config.Username, $result.IpAddress)
Write-Host ''
Write-Host '  The install image still holds the answer file with the passphrase in it.'
Write-Host ('  Delete it when you no longer need to rebuild: {0}' -f $isoPath)

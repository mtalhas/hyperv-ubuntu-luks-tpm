<#
.SYNOPSIS
    Builds a Hyper-V Generation 2 Ubuntu Server VM with an encrypted disk that
    unlocks itself from the virtual TPM, with no passphrase prompt at boot.

.DESCRIPTION
    Runs the whole build end to end and leaves a working, verified VM.
      1. Checks the config and the host.
      2. Generates a password, a disk passphrase and an SSH key for this VM.
      3. Rebuilds the install image with an unattended answer file.
      4. Creates the VM with the Linux Secure Boot template and a virtual TPM.
      5. Runs the install with no interaction.
      6. Boots the result and confirms it unlocks on its own, twice.
    Everything is logged to a per run file under the output folder.

.PARAMETER ConfigPath
    Path to the config file. Defaults to config.ps1 next to this script.

.PARAMETER KeepRebuildImage
    Keep the rebuilt install image and the staging folder after a successful
    build. By default they are deleted because they hold the disk passphrase in
    clear text. A re-run regenerates them.

.EXAMPLE
    Copy config.example.ps1 to config.ps1, edit it, then from an elevated prompt:
        .\Build-Vm.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$KeepRebuildImage
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

# These two are needed to work out where the log goes, so they are checked before
# anything else. The rest of the config is validated in preflight.
foreach ($k in @('VmName', 'OutputDir')) {
    if (-not $Config.ContainsKey($k) -or [string]::IsNullOrWhiteSpace([string]$Config[$k])) {
        throw "Config is missing '$k'. Copy config.example.ps1 to config.ps1 and fill it in."
    }
}

. (Join-Path $repoRoot 'lib\Common.ps1')
. (Join-Path $repoRoot 'lib\Preflight.ps1')
. (Join-Path $repoRoot 'lib\New-AutoinstallIso.ps1')
. (Join-Path $repoRoot 'lib\New-Vm.ps1')
. (Join-Path $repoRoot 'lib\Install-Vm.ps1')
. (Join-Path $repoRoot 'lib\Test-Vm.ps1')

$outDir = Join-Path $Config.OutputDir $Config.VmName
$logFile = Start-BuildLog -LogDir (Join-Path $outDir 'logs')

$isoPath = $null
try {
    Write-BuildLog "Building '$($Config.VmName)' on this host." STEP
    Write-BuildLog "Log file: $logFile" INFO

    Invoke-Preflight -Config $Config
    $creds   = New-BuildCredentials -Config $Config
    $isoPath = New-AutoinstallImage -Config $Config -Creds $creds -RepoRoot $repoRoot
    New-EncryptedVm -Config $Config -IsoPath $isoPath
    Invoke-Install -Config $Config
    $result = Invoke-Verify -Config $Config -Creds $creds

    # The staging folder and the rebuilt image hold the passphrase in clear text.
    # Remove them once the build has passed, unless the operator asked to keep them.
    if (-not $KeepRebuildImage) {
        $stage = Join-Path (Join-Path $repoRoot 'build') $Config.VmName
        if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
        if ($isoPath -and (Test-Path $isoPath)) { Remove-Item $isoPath -Force -ErrorAction SilentlyContinue }
        Write-BuildLog "Removed the staging folder and the rebuilt image (they held the passphrase). Re-run to recreate them." INFO
    }

    Write-BuildLog "Build complete." STEP
    Write-Host ''
    Write-Host 'Build complete.' -ForegroundColor Green
    Write-Host ('  Host name    : {0}' -f $result.Hostname)
    Write-Host ('  Address      : {0}' -f $result.IpAddress)
    Write-Host ('  Root device  : {0}' -f $result.RootDevice)
    Write-Host ('  Encrypted    : {0}' -f $result.Encrypted)
    Write-Host ('  TPM binding  : {0}' -f $result.TpmBinding)
    Write-Host ''
    Write-Host ('  Credentials  : {0}' -f (Join-Path $outDir '.env'))
    Write-Host ('  Log          : {0}' -f $logFile)
    Write-Host ('  Log in with  : ssh -i "{0}" {1}@{2}' -f $creds.SshKeyPath, $Config.Username, $result.IpAddress)
}
catch {
    Write-BuildLog "BUILD FAILED: $($_.Exception.Message)" ERROR
    Write-BuildLog "At: $($_.InvocationInfo.PositionMessage)" ERROR
    if ($_.ScriptStackTrace) { Write-BuildLog $_.ScriptStackTrace ERROR }
    # A picture of the console is the fastest way to see where it stopped.
    $shot = Save-VmConsole -VMName $Config.VmName -OutPath (Join-Path $outDir 'build-failure-console.png')
    if ($shot) { Write-BuildLog "Console screenshot saved to $shot" ERROR }
    Write-Host ''
    Write-Host "Build failed. See the log at $logFile" -ForegroundColor Red
    throw
}
finally {
    Stop-BuildLog
}

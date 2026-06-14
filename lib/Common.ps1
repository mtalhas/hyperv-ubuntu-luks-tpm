# Shared helpers: logging and console capture.
# Every step writes through Write-BuildLog so a finished or failed run leaves a clear,
# timestamped record on disk. On a failure the build also saves a picture of the
# VM screen, which is the fastest way to see whether it is sitting at a passphrase
# prompt, an installer error, or a login prompt.

$script:BuildLogFile = $null

function Start-BuildLog {
    param([string]$LogDir)
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $script:BuildLogFile = Join-Path $LogDir "build-$stamp.log"
    New-Item -ItemType File -Path $script:BuildLogFile -Force | Out-Null
    # Transcript is a belt and suspenders copy of the whole console. It is optional,
    # so a host that does not support it does not stop the build.
    try { Start-Transcript -Path (Join-Path $LogDir "transcript-$stamp.txt") -Force | Out-Null }
    catch { Write-Verbose "Transcript could not start: $_" }
    return $script:BuildLogFile
}

function Stop-BuildLog {
    try { Stop-Transcript | Out-Null }
    catch { Write-Verbose "No transcript was running: $_" }
}

function Write-BuildLog {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [Parameter(Position = 1)][ValidateSet('INFO', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO'
    )
    $ts   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "$ts [$Level] $Message"
    if ($script:BuildLogFile) {
        Add-Content -Path $script:BuildLogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'STEP'  { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
}

function Invoke-WslQuery {
    # Runs a short WSL command for its output and returns it as a trimmed string.
    # Native command stderr is kept off the error path so a shell profile message
    # or a tool warning never aborts the build, which can happen under a strict
    # error preference even with a redirect.
    param([string[]]$DistroArgs = @(), [string]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & wsl.exe @DistroArgs -u root -e bash -lc $Command 2>$null
    } finally {
        $ErrorActionPreference = $prev
    }
    return (($out -join '').Trim())
}

function Write-NativeOutputToLog {
    # Pipe native command output (with stderr merged in by the caller) through here
    # so it lands in the log instead of aborting the run on a benign stderr line.
    # Stderr lines arrive as error or exception objects, so render their text.
    param([Parameter(ValueFromPipeline)]$Line)
    process {
        if ($null -eq $Line) { return }
        $text = if ($Line -is [System.Management.Automation.ErrorRecord]) { $Line.Exception.Message }
        elseif ($Line -is [System.Exception]) { $Line.Message }
        else { "$Line" }
        if ($text.Trim()) { Write-BuildLog "  $text" INFO }
    }
}

function Save-VmConsole {
    # Saves the current VM screen as a PNG. Best effort: returns the path, or $null
    # if the screen could not be read (for example the VM is off).
    param([string]$VMName, [string]$OutPath, [int]$Width = 800, [int]$Height = 600)
    try {
        Add-Type -AssemblyName System.Drawing
        $vm = Get-WmiObject -Namespace root\virtualization\v2 -Class Msvm_ComputerSystem -Filter "ElementName='$VMName'"
        if (-not $vm) { return $null }
        $mgmt = Get-WmiObject -Namespace root\virtualization\v2 -Class Msvm_VirtualSystemManagementService
        $img = $mgmt.GetVirtualSystemThumbnailImage($vm, $Width, $Height)
        if ($img.ReturnValue -ne 0 -or -not $img.ImageData) { return $null }
        $bytes = $img.ImageData
        $bmp = New-Object System.Drawing.Bitmap($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
        $rect = New-Object System.Drawing.Rectangle(0, 0, $Width, $Height)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
        $rowBytes = $Width * 2
        for ($y = 0; $y -lt $Height; $y++) {
            $srcOffset = $y * $rowBytes
            if ($srcOffset + $rowBytes -le $bytes.Length) {
                [System.Runtime.InteropServices.Marshal]::Copy($bytes, $srcOffset, [IntPtr]::Add($data.Scan0, $y * $data.Stride), $rowBytes)
            }
        }
        $bmp.UnlockBits($data)
        $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        return $OutPath
    } catch { return $null }
}

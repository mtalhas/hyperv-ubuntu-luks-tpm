<#
.SYNOPSIS
    Runs the test suite: unit tests for the pure logic, plus static analysis.

.DESCRIPTION
    Installs Pester 5 and PSScriptAnalyzer for the current user if they are not
    present, then runs the tests under tests\. Exits non zero if anything fails,
    so it can gate a commit or a pipeline.

    Run it with PowerShell 7 (pwsh) for the best Pester 5 experience.

.PARAMETER Tag
    Only run tests with this tag. 'Unit' is fast and needs nothing external.
    'Lint' runs PSScriptAnalyzer and shellcheck. Omit to run everything.

.EXAMPLE
    pwsh -File .\run-tests.ps1
    pwsh -File .\run-tests.ps1 -Tag Unit
#>
[CmdletBinding()]
param([string]$Tag)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

Write-Host 'Checking test tools...' -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 })) {
    Write-Host '  Installing Pester 5...'
    Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck -Scope CurrentUser
}
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Write-Host '  Installing PSScriptAnalyzer...'
    Install-Module PSScriptAnalyzer -Force -Scope CurrentUser
}

Import-Module Pester -MinimumVersion 5.0 -Force

$config = New-PesterConfiguration
$config.Run.Path = (Join-Path $repo 'tests')
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = (Join-Path $repo 'test-results.xml')
if ($Tag) { $config.Filter.Tag = $Tag }

Invoke-Pester -Configuration $config

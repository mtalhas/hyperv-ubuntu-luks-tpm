# Static analysis gates. These need PSScriptAnalyzer for the PowerShell, and
# shellcheck for the one bash script. Each test skips itself cleanly if its tool
# is not installed, so the suite still runs without them.
#
# Tool detection runs in BeforeDiscovery because Pester evaluates the -Skip
# condition during discovery, before BeforeAll would run.

BeforeDiscovery {
    $HasPssa = [bool](Get-Module -ListAvailable PSScriptAnalyzer)
    $ShellcheckNative = [bool](Get-Command shellcheck -ErrorAction SilentlyContinue)
    $ShellcheckWsl = $false
    if (-not $ShellcheckNative -and (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        $probe = (wsl.exe -u root -e bash -lc 'command -v shellcheck >/dev/null 2>&1 && echo yes || echo no' 2>$null) -join ''
        $ShellcheckWsl = ($probe.Trim() -eq 'yes')
    }
    $ShellcheckAvailable = ($ShellcheckNative -or $ShellcheckWsl)
}

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
}

Describe 'PSScriptAnalyzer' -Tag 'Lint' {
    It 'reports no error level findings in the PowerShell sources' -Skip:(-not $HasPssa) {
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        $findings = Invoke-ScriptAnalyzer -Path $script:Repo -Recurse -Severity Error
        if ($findings) { $findings | Format-Table RuleName, ScriptName, Line, Message -AutoSize | Out-String | Write-Host }
        $findings.Count | Should -Be 0
    }
    It 'reports its warnings (informational, does not fail the build)' -Skip:(-not $HasPssa) {
        $warnings = Invoke-ScriptAnalyzer -Path $script:Repo -Recurse -Severity Warning
        if ($warnings) { $warnings | Format-Table RuleName, ScriptName, Line -AutoSize | Out-String | Write-Host }
        $true | Should -BeTrue
    }
}

Describe 'shellcheck' -Tag 'Lint' {
    It 'finds no warning or error level issues in build-iso.sh' -Skip:(-not $ShellcheckAvailable) {
        $sh = Join-Path $script:Repo 'lib\build-iso.sh'
        if (Get-Command shellcheck -ErrorAction SilentlyContinue) {
            & shellcheck --severity=warning --shell=bash $sh
            $code = $LASTEXITCODE
        } else {
            $wslPath = '/mnt/' + ($script:Repo.Substring(0, 1).ToLower()) + ($script:Repo.Substring(2) -replace '\\', '/') + '/lib/build-iso.sh'
            wsl.exe -u root -e bash -lc "shellcheck --severity=warning --shell=bash '$wslPath'"
            $code = $LASTEXITCODE
        }
        $code | Should -Be 0
    }
}

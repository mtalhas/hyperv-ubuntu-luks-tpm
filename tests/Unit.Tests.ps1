# Unit tests for the pure build logic. None of these need Hyper-V, WSL, or a
# network, so they run fast on every commit. Pester v5.

BeforeDiscovery {
    # Decide at discovery time whether the git-ignore tests can run, since -Skip is
    # evaluated during discovery, before BeforeAll.
    $repoRoot = Split-Path $PSScriptRoot -Parent
    git -C $repoRoot rev-parse --is-inside-work-tree *> $null 2>&1
    $InGitRepo = ($LASTEXITCODE -eq 0)
}

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repo 'lib\Common.ps1')
    . (Join-Path $repo 'lib\New-AutoinstallIso.ps1')
    . (Join-Path $repo 'lib\Preflight.ps1')
    . (Join-Path $repo 'lib\Install-Vm.ps1')
    $script:Repo = $repo

    function New-ValidConfig {
        @{
            VmName = 'test-vm'; Username = 'ubuntu'; Hostname = 'test-vm'
            SourceIso = 'C:\iso\ubuntu.iso'; VmDir = 'D:\VMs\test-vm'; SwitchName = 'NatSwitch'
            IpCidr = '192.168.50.10/24'; Gateway = '192.168.50.1'; Dns = '1.1.1.1, 8.8.8.8'
            Cpus = 4; MemoryMB = 4096; DiskSizeGB = 300; OutputDir = '.\out'
        }
    }
}

Describe 'ConvertTo-WslPath' -Tag 'Unit' {
    It 'maps <Win> to <Wsl>' -ForEach @(
        @{ Win = 'C:\Users\me\a.iso'; Wsl = '/mnt/c/Users/me/a.iso' }
        @{ Win = 'D:\VMs\x\y.iso';    Wsl = '/mnt/d/VMs/x/y.iso' }
    ) {
        ConvertTo-WslPath $Win | Should -Be $Wsl
    }
}

Describe 'New-RandomPassword' -Tag 'Unit' {
    It 'has the requested length' {
        (New-RandomPassword -Length 24).Length | Should -Be 24
    }
    It 'uses only safe alphanumeric characters (no quoting or YAML hazards)' {
        New-RandomPassword -Length 200 | Should -Match '^[A-Za-z0-9]+$'
    }
    It 'avoids visually ambiguous characters' {
        # The charset deliberately drops 0 O 1 l I to keep the recovery key readable.
        # MatchExactly is case sensitive, so it does not also reject L or i.
        New-RandomPassword -Length 500 | Should -Not -MatchExactly '[0O1lI]'
    }
    It 'produces a different value each call' {
        (New-RandomPassword) | Should -Not -Be (New-RandomPassword)
    }
}

Describe 'Expand-Template' -Tag 'Unit' {
    It 'replaces every token with its value' {
        $out = Expand-Template -Content 'host=__H__ ip=__I__' -Substitutions @{ '__H__' = 'box'; '__I__' = '10.0.0.5' }
        $out | Should -Be 'host=box ip=10.0.0.5'
    }
    It 'handles values containing slashes and plus signs (an SSH key)' {
        $key = 'ssh-ed25519 AAAA/B+c=='
        Expand-Template -Content '- __K__' -Substitutions @{ '__K__' = $key } | Should -Be "- $key"
    }
}

Describe 'Assert-NoUnfilledTokens' -Tag 'Unit' {
    It 'throws when a placeholder remains' {
        { Assert-NoUnfilledTokens -Content 'a __LEFTOVER__ b' -Where 'x' } | Should -Throw
    }
    It 'passes when nothing is left' {
        { Assert-NoUnfilledTokens -Content 'all filled in' -Where 'x' } | Should -Not -Throw
    }
}

Describe 'Test-Config' -Tag 'Unit' {
    It 'accepts a valid config' {
        { Test-Config -Config (New-ValidConfig) } | Should -Not -Throw
    }
    It 'rejects a missing required key' {
        $c = New-ValidConfig; $c.Remove('Gateway')
        { Test-Config -Config $c } | Should -Throw
    }
    It 'rejects an address with no prefix length' {
        $c = New-ValidConfig; $c.IpCidr = '192.168.50.10'
        { Test-Config -Config $c } | Should -Throw
    }
    It 'rejects too little memory' {
        $c = New-ValidConfig; $c.MemoryMB = 512
        { Test-Config -Config $c } | Should -Throw
    }
    It 'rejects a VM name with illegal characters' {
        $c = New-ValidConfig; $c.VmName = 'bad name/slash'
        { Test-Config -Config $c } | Should -Throw
    }
    It 'rejects an impossible octet in the address' {
        $c = New-ValidConfig; $c.IpCidr = '999.1.1.1/24'
        { Test-Config -Config $c } | Should -Throw
    }
    It 'rejects a prefix length over 32' {
        $c = New-ValidConfig; $c.IpCidr = '10.0.0.1/64'
        { Test-Config -Config $c } | Should -Throw
    }
}

Describe 'Answer file template integrity' -Tag 'Unit' {
    It 'has no placeholder left after a full substitution (catches a renamed token)' {
        $tpl = Get-Content (Join-Path $script:Repo 'templates\user-data.tt') -Raw
        $subs = @{
            '__HOSTNAME__' = 'h'; '__USERNAME__' = 'u'; '__IP_CIDR__' = '10.0.0.5/24'
            '__GATEWAY__' = '10.0.0.1'; '__DNS_LIST__' = '1.1.1.1'; '__SSH_PUBKEY__' = 'ssh-ed25519 AAAA'
            '__USER_PASSWORD__' = 'pw'; '__LUKS_PASSPHRASE__' = 'pp'
        }
        $out = Expand-Template -Content $tpl -Substitutions $subs
        $out | Should -Not -Match '__[A-Z0-9_]+__'
    }
    It 'keeps the no PCR clevis binding (a stricter binding could lock the VM out)' {
        $tpl = Get-Content (Join-Path $script:Repo 'templates\user-data.tt') -Raw
        $tpl | Should -Match "tpm2 '\{\}'"
    }
    It 'forces the clevis module into the initramfs (survives a kernel update)' {
        $tpl = Get-Content (Join-Path $script:Repo 'templates\user-data.tt') -Raw
        $tpl | Should -Match 'add_dracutmodules\+="\s*clevis'
    }
    It 'does not trace the post-install script (would leak secrets into the log)' {
        $tpl = Get-Content (Join-Path $script:Repo 'templates\user-data.tt') -Raw
        $tpl | Should -Not -Match '(?m)^\s*set -eux'
    }
    It 'boots the installer with the overlayfs kernel fault workaround' {
        $grub = Get-Content (Join-Path $script:Repo 'templates\grub.cfg') -Raw
        $grub | Should -Match 'modprobe\.blacklist=zfs'
    }
}

Describe 'Get-InstallProgress (install completion heuristic)' -Tag 'Unit' {
    BeforeAll {
        $script:T0 = Get-Date '2026-01-01T00:00:00'
        $script:Deadline = $script:T0.AddMinutes(60)
        $script:NotDown = [datetime]::MinValue
    }
    It 'finishes when the VM has powered off' {
        $r = Get-InstallProgress -State 'Off' -PortUp $false -SeenUp $true -DownSince $script:NotDown -Now $script:T0 -Deadline $script:Deadline
        $r.Decision | Should -Be 'finished'
    }
    It 'keeps going while the installer is up' {
        $r = Get-InstallProgress -State 'Running' -PortUp $true -SeenUp $true -DownSince $script:NotDown -Now $script:T0 -Deadline $script:Deadline
        $r.Decision | Should -Be 'continue'
        $r.SeenUp   | Should -BeTrue
    }
    It 'marks the down time on the first poll after the installer stops answering' {
        $r = Get-InstallProgress -State 'Running' -PortUp $false -SeenUp $true -DownSince $script:NotDown -Now $script:T0 -Deadline $script:Deadline
        $r.Decision  | Should -Be 'continue'
        $r.DownSince | Should -Be $script:T0
    }
    It 'finishes once the installer has been down for the grace period' {
        $down = $script:T0
        $now  = $script:T0.AddSeconds(65)
        $r = Get-InstallProgress -State 'Running' -PortUp $false -SeenUp $true -DownSince $down -Now $now -Deadline $script:Deadline
        $r.Decision | Should -Be 'finished'
    }
    It 'fails (does not falsely succeed) when the installer is still up at the deadline' {
        $now = $script:Deadline.AddSeconds(1)
        $r = Get-InstallProgress -State 'Running' -PortUp $true -SeenUp $true -DownSince $script:NotDown -Now $now -Deadline $script:Deadline
        $r.Decision | Should -Be 'failed'
    }
    It 'fails when the installer never came up by the deadline' {
        $now = $script:Deadline.AddSeconds(1)
        $r = Get-InstallProgress -State 'Running' -PortUp $false -SeenUp $false -DownSince $script:NotDown -Now $now -Deadline $script:Deadline
        $r.Decision | Should -Be 'failed'
    }
}

Describe 'Secrets are ignored by git' -Tag 'Unit' -Skip:(-not $InGitRepo) {
    BeforeAll { $script:Repo = Split-Path $PSScriptRoot -Parent }
    It 'ignores <Path>' -ForEach @(
        @{ Path = 'out/test-vm/.env' }
        @{ Path = 'out/test-vm/id_ed25519' }
        @{ Path = 'build/test-vm/autoinstall/user-data' }
        @{ Path = 'config.ps1' }
        @{ Path = 'D-test.iso' }
        @{ Path = 'out/test-vm/build-failure-console.png' }
    ) {
        git -C $script:Repo check-ignore -q -- $Path
        $LASTEXITCODE | Should -Be 0
    }
    It 'does NOT ignore tracked source files' {
        git -C $script:Repo check-ignore -q -- 'lib/New-Vm.ps1'
        $LASTEXITCODE | Should -Be 1
    }
}

# Encrypted Ubuntu on Hyper-V that unlocks itself

![tests](https://github.com/mtalhas/hyperv-luks-autounlock/actions/workflows/ci.yml/badge.svg)

Build an Ubuntu Server virtual machine on Hyper-V that keeps its whole disk
encrypted and still boots on its own, with no passphrase to type. One command
creates the VM, installs Ubuntu with no questions asked, seals the disk key
inside the machine's virtual TPM, then power cycles the result to prove it
unlocks before it reports success.

The disk is encrypted with LUKS. The key is sealed to the VM's virtual TPM, so
the machine unlocks itself at boot and only on that machine. A recovery
passphrase is generated and saved in case the TPM binding is ever lost. In
short, it gives an Ubuntu guest the unlock on boot behaviour people expect from
BitLocker, from a single PowerShell command.

## Why this exists

There are good PowerShell scripts that stand up Ubuntu on Hyper-V, and there are
good guides that bind LUKS to a TPM on a machine you already run. Nobody had put
the two together. Doing it means walking through a row of traps that each look
like a different problem: a Secure Boot template that rejects the Ubuntu boot
loader, a virtual TPM that then locks the firmware so you cannot fix it, a NAT
switch that hands out no address so the installer has no network, a recent
Ubuntu that builds its boot image with dracut and quietly drops the unlock hook
on a kernel update, and an intermittent crash in the installer kernel itself.
This project handles all of them, and it checks its own work from install to a
second clean boot, so you are not left guessing.

## What you need

1. Windows 11 or Windows Server with the Hyper-V feature on.
2. An elevated PowerShell window.
3. The Windows OpenSSH client, which is usually already installed.
4. WSL with an Ubuntu distribution. It runs one step, the image rebuild, and
   installs the tool it needs by itself.
5. A Hyper-V virtual switch for the VM. A NAT switch is fine, because the VM uses
   a fixed address rather than asking for one.
6. An Ubuntu Server install image, the live server ISO.

## Quick start

Copy the example config and fill in your paths and network.

```powershell
Copy-Item config.example.ps1 config.ps1
notepad config.ps1
```

Then run the build from an elevated PowerShell window in this folder.

```powershell
.\Build-Vm.ps1
```

That is the whole thing. It creates the VM, installs Ubuntu unattended, binds the
disk to the TPM, and boots and power cycles the VM to confirm it unlocks with no
prompt. When it finishes it prints the address and the command to log in.

## What you get

A running, encrypted VM that reaches a login with no passphrase prompt. The login
password, the recovery passphrase, and an SSH key land in `out\<vmname>\`. Log in
with the line the build prints, for example:

```powershell
ssh -i "out\ubuntu-vm\id_ed25519" ubuntu@192.168.50.10
```

## How it works

The build runs these steps in order, each in its own file under `lib`.

1. Check the config and the host before doing any real work.
2. Generate the password, the recovery passphrase, and an SSH key for this VM.
3. Rebuild the install image with an unattended answer file, reusing the original
   boot files so Secure Boot still trusts them.
4. Create the VM with the Linux Secure Boot template first and the virtual TPM
   last, so the firmware never locks.
5. Install Ubuntu with no interaction, retrying if the installer hits the random
   kernel crash.
6. Boot the result, confirm the disk is encrypted and unlocked with no prompt,
   then power cycle and confirm again.

Every run writes a timestamped log and a console transcript to
`out\<vmname>\logs\`. If a step fails it also saves a picture of the VM screen,
which is the quickest way to tell a passphrase prompt apart from an installer
error or a normal login.

## Reproducing and cleaning up

Run the build again with the same name and it removes the old VM and rebuilds
from scratch. After a clean build it deletes the rebuilt image and the staging
files, since they hold the passphrase in clear text. Pass `-KeepRebuildImage` to
keep them.

## Running the tests

The logic that can be tested without a hypervisor has a unit suite, and the
scripts have static analysis behind them. The same suite runs in CI on every
push.

```powershell
pwsh -File .\run-tests.ps1
pwsh -File .\run-tests.ps1 -Tag Unit
```

## Scope

One LUKS volume over LVM, which is what the guided install produces. The key is
sealed to the VM's own virtual TPM, so an encrypted VM cannot be cloned and still
unlock; build each one fresh. For the design, the tradeoffs, and every failure
mode with its fix, see `PRD.md` and `docs\troubleshooting.md`.

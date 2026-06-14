# Encrypted Ubuntu VM builder for Hyper-V

Build a Hyper-V Generation 2 Ubuntu Server VM whose disk is fully encrypted and
unlocks itself from the virtual TPM, with no passphrase prompt at boot. One
command, no manual steps, and the build checks its own result before it reports
success.

The whole disk is encrypted with LUKS. The key is sealed to the VM's virtual
TPM, so normal boots unlock on their own. A recovery passphrase is generated and
saved in case the TPM binding is ever lost.

## What you need

1. Windows 11 or Windows Server with the Hyper-V feature enabled.
2. An elevated PowerShell window (Run as administrator).
3. The Windows OpenSSH client (an optional feature, usually already present).
4. WSL with an Ubuntu distribution. It is used for one step, the image rebuild.
   The build installs xorriso into it for you if needed.
5. A Hyper-V virtual switch the VM can use. A NAT switch is fine. The VM uses a
   fixed address, so no address server is required.
6. An Ubuntu Server install image, the live server ISO.

## Quick start

1. Copy the example config and edit it for your machine.

   ```powershell
   Copy-Item config.example.ps1 config.ps1
   notepad config.ps1
   ```

   Set at least `SourceIso`, `VmDir`, `SwitchName` and the network values to
   match your switch subnet.

2. From an elevated PowerShell window in this folder, run the build.

   ```powershell
   .\Build-Vm.ps1
   ```

3. Wait. The build creates the VM, installs Ubuntu with no interaction, binds the
   disk to the TPM, then boots and power cycles the VM to prove it unlocks on its
   own. When it finishes it prints the address and how to log in.

## What you get

1. A running, encrypted VM that boots with no passphrase prompt.
2. A credentials file at `out\<vmname>\.env` with the login password, the disk
   recovery passphrase and the path to the SSH key.
3. An SSH key at `out\<vmname>\id_ed25519` for logging in.

Log in with the line the build prints, for example:

```powershell
ssh -i "out\ubuntu-vm\id_ed25519" ubuntu@192.168.50.10
```

## How it works

The build runs these steps in order. Each lives in its own file under `lib`.

1. `Preflight` checks the host has Hyper-V, the switch, the source image, OpenSSH
   and xorriso in WSL.
2. `New-BuildCredentials` generates the password, the passphrase and the SSH key,
   and writes the credentials file.
3. `New-AutoinstallImage` fills the answer file template for this VM and rebuilds
   the install image with it, reusing the original boot files so Secure Boot
   still trusts them.
4. `New-EncryptedVm` creates the VM with the Linux Secure Boot template first and
   the virtual TPM last, so the template never gets locked.
5. `Invoke-Install` runs the install and leaves the VM set to boot from its disk.
6. `Invoke-Verify` boots the VM, confirms the disk is encrypted and unlocked with
   no prompt, confirms the TPM binding, then power cycles and confirms again.

## Repeating and cleaning up

Running the build again with the same name removes the old VM and rebuilds it
fresh. The disk file is recreated each time.

The rebuilt install image holds the answer file, which contains the passphrase
in clear text. It lives in your VM folder, outside the repo. Delete it once you
no longer need to rebuild that VM. The build prints its path at the end.

## Notes

For background on the platform behaviours this build works around, and how to
extend it, see `PRD.md` and `docs/troubleshooting.md`.

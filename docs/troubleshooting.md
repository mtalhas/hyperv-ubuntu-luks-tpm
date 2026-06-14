# Troubleshooting and background

Notes on the platform behaviours this build works around. Useful if you adapt the
build or hit one of these by hand.

## The VM tries to network boot instead of running the installer

Cause. A Generation 2 VM uses Secure Boot. The default template and the shielded
template do not trust the Ubuntu boot loader, so the firmware skips the DVD and
falls back to a network boot attempt.

Fix. Use the Linux Secure Boot template, named MicrosoftUEFICertificateAuthority.
The build sets this on every VM.

## The Secure Boot template will not change

Cause. Once a virtual TPM is switched on and used, Hyper-V locks the Secure Boot
template on that VM. Switching the TPM back off does not release it, because the
firmware state is kept with the VM.

Fix. Set the template before switching the TPM on. The build always creates the
VM fresh and sets the template first, so the lock never gets in the way. To fix
an existing locked VM, recreate it. The disk file can be kept and reattached.

## The installer has no network and package installs fail

Cause. A hand made Hyper-V NAT switch provides a gateway but no address server.
An installer set to ask for an address gets none, so it has no route out and
cannot fetch packages.

Fix. Give the VM a fixed address that routes through the NAT gateway, with public
name servers. The build does this from the config values. The built in Default
Switch does provide addresses if you prefer that for installs.

## The disk asks for a passphrase at boot even though the TPM was set up

Cause. Newer Ubuntu builds the early boot image with dracut, not the older tool.
The older clevis hook package and the old rebuild command do nothing on dracut,
so the unlock hook never makes it into the boot image.

Fix. On dracut, install clevis-dracut and rebuild with dracut. On the older tool,
install clevis-initramfs and rebuild with the older command. The build detects
which generator is present and uses the matching pair.

## The rebuilt install image will not boot

Cause. Editing the image with a simple keep the boot setup option corrupts the
EFI partition layout that Ubuntu images use, and the firmware cannot load it.

Fix. Read the original image's own boot layout, then rebuild from the extracted
contents while replaying that layout. The build does this and uses the name based
reference for the EFI partition so it is recomputed for the new, slightly larger
image. The boot files themselves are reused untouched, so Secure Boot still
trusts them.

## Typing into the VM console drops or scrambles characters

Cause. Sending text to the Hyper-V console programmatically is not reliable for
anything longer than a few characters.

Fix. Never depend on it. The build bakes the unattended trigger into the install
image, so no console typing is needed at any point.

## The installer does not power the VM off cleanly

Symptom. After the install the VM can sit in a half powered off state rather than
reaching the off state.

Fix. The build watches the installer's network service. When that service stops
answering, the install has finished and the machine has halted, so the build
powers the VM off itself and moves on. This does not depend on the installer
reaching a clean off state.

## The VM panics with a memory deadlock after running for a while

Symptom. The guest shows a kernel panic that reads "System is deadlocked on
memory", often after sitting idle.

Cause. Hyper-V dynamic memory inflates a balloon inside the guest to reclaim
unused memory. The Linux balloon driver can get into a state where it cannot
make progress, and the kernel panics.

Fix. Use fixed memory, not dynamic. The build sets fixed memory on every VM. To
fix an existing VM, power it off, turn dynamic memory off with a fixed startup
size, then start it again.

## Checking the result by hand

Log in with the SSH key from the output folder, then:

```bash
# Root should sit on a mapper device backed by a crypto_LUKS partition.
findmnt -no SOURCE /
lsblk -o NAME,TYPE,FSTYPE,MOUNTPOINT

# The encrypted partition should show a TPM binding.
sudo clevis luks list -d "$(blkid -t TYPE=crypto_LUKS -o device | head -n1)"
```

# Product requirements: encrypted Ubuntu VM builder for Hyper-V

## Purpose

Turn a one time, hand driven VM setup into a repeatable build. Anyone with the
repo and an Ubuntu Server image should be able to create a Generation 2 Hyper-V
virtual machine whose disk is fully encrypted and unlocks itself from the
virtual TPM, with no passphrase prompt at boot, in a single command and with no
manual steps.

## Goals

1. One command produces a working, encrypted, self unlocking VM.
2. The build is unattended end to end. No console typing, no clicking.
3. The build verifies its own result, including a power cycle, before it reports
   success.
4. Every machine specific value (name, address, sizing) lives in one config file.
5. No secret is ever written into the repository.
6. The build runs on native Windows tooling as far as possible.

## Non goals

1. Cloning one encrypted image to many machines. A TPM sealed key belongs to one
   specific virtual TPM, so each VM enrolls its own. This build creates each VM
   fresh. That choice is recorded under Design decisions below.
2. Operating system hardening beyond what the encryption work needs. The answer
   file is a clean base that is easy to extend.
3. Anything other than Hyper-V. The approach maps to other hypervisors but this
   repo targets Hyper-V Generation 2.

## Users

A platform or lab engineer on Windows 11 with Hyper-V, who wants a known good,
encrypted Ubuntu VM without learning every sharp edge of the platform first.

## Functional requirements

1. Read all machine specific input from one config file.
2. Generate a login password, a disk recovery passphrase and an SSH key per VM,
   and write them to a per VM output folder that version control ignores.
3. Build an install image that runs the Ubuntu installer with no interaction and
   applies the answer file.
4. Create the VM with Secure Boot on using the Linux template, a virtual TPM on,
   and saved state encryption on.
5. Install Ubuntu with the whole disk encrypted, LVM on top of LUKS.
6. Bind the disk to the virtual TPM so it unlocks during boot with no prompt, and
   keep the generated passphrase as a recovery key.
7. Boot the finished VM, confirm it reaches the network with the encrypted root
   mounted, confirm the encryption and the TPM binding, then power cycle and
   confirm the unlock repeats.
8. Print where the credentials are and how to log in.
9. Validate the config and the host before starting, so mistakes show up as clear
   messages up front rather than cryptic failures deep inside a long run.
10. Write a timestamped log and a console transcript for every run. On a failure,
    save a picture of the VM screen and pull the in VM setup log, so the cause is
    visible after the fact.
11. Remove the answer file and the rebuilt image after a successful build, since
    they hold the passphrase in clear text.
12. Ship a test suite for the pure logic and static analysis for the scripts, run
    on every change, so the bugs that were already fixed cannot come back.

## Guardrails learned from the first manual build

These are the failures the build is designed to never repeat.

1. **Secure Boot template.** A Generation 2 VM with the shielded template refuses
   the Ubuntu boot loader and falls back to a network boot attempt. The build
   always uses the Linux template, named MicrosoftUEFICertificateAuthority.

2. **Virtual TPM locks the template.** Once a virtual TPM is switched on, the
   Secure Boot template can no longer be changed on that VM. The build sets the
   template first and switches the TPM on last, and it always creates the VM
   fresh, so the lock never gets in the way.

3. **NAT switch has no address server.** A hand made Hyper-V NAT switch hands out
   no addresses, so an installer that expects one gets no network and cannot
   fetch packages. The build gives the VM a fixed address from config.

4. **Initramfs generator changed.** Newer Ubuntu builds the early boot image with
   dracut, where the older clevis hook and the old rebuild command do nothing.
   The build detects the generator and uses the matching package and rebuild
   command, so it works on both old and new releases.

5. **Image rebuild can break boot.** A naive image edit corrupts the EFI boot
   layout and the VM will not boot. The build reads the original image's own boot
   layout and replays it, so the rebuilt image still boots under Secure Boot.

6. **Console keyboard is unreliable.** Typing into the VM console can drop or
   scramble characters, so the build never depends on it. The unattended trigger
   is baked into the install image instead.

## Design decisions

1. **Per VM install over golden image.** TPM bound encryption cannot be cloned,
   because the sealed key is tied to one virtual TPM. Building each VM fresh keeps
   the result correct and simple. A golden image with a first boot re enroll step
   is possible but adds moving parts, and is out of scope here.

2. **No PCR policy on the TPM binding by default.** The key is sealed to the TPM
   with no platform measurement policy, so the disk unlocks whenever it runs in
   its VM. This protects data if the disk file is copied off the host, and it can
   never lock the owner out after an update. It is not tied to a measured boot
   state. The binding command is a single line, so a stricter policy is easy to
   switch on later for those who want it.

3. **WSL for one step only.** The image rebuild needs xorriso, which has no
   trustworthy native Windows build worth shipping in a public repo. The native
   alternatives are an unvetted binary or console keyboard typing, both worse.
   So WSL runs that one isolated step. Everything else is native PowerShell. The
   step is written so a native xorriso can replace WSL later with no other change.

## Security and secret handling

1. The repository contains templates and code only. No password, passphrase or
   key is committed.
2. Per VM secrets are generated at build time and written to an output folder
   that version control ignores.
3. The throwaway password hash in the answer file template is for a fixed dummy
   string and is overwritten during install before the first real boot.
4. The rebuilt install image carries the answer file, which holds the passphrase
   in clear text. It lives outside the repo and the build reminds the operator to
   delete it once rebuilds are no longer needed.

## Acceptance criteria

A build passes only when all of these hold for a freshly built VM.

1. The VM boots to the network with no passphrase prompt.
2. The root filesystem sits on a LUKS encrypted volume.
3. The disk shows a TPM binding in its key slots.
4. A power cycle boots again with no passphrase prompt.
5. Credentials are present in the output folder and the printed login works.
6. No secret is present anywhere under version control.

## Future enhancements

1. Optional stricter TPM policy bound to Secure Boot state.
2. Optional remote unlock helper in early boot, to support a golden image and
   clone model.
3. A native xorriso path to remove the last WSL dependency.
4. Optional baseline hardening pass after install.

# Copy this file to config.ps1 and adjust the values for your VM.
# config.ps1 is ignored by git so your paths stay local to your machine.
# None of these values are secrets. The account password, the disk passphrase
# and the SSH key are all generated during the build and written to the output
# folder for the VM, never into this file.

@{
    # Name of the virtual machine to create in Hyper-V.
    VmName            = 'ubuntu-vm'

    # Login account that the build creates inside Ubuntu.
    Username          = 'ubuntu'

    # Hostname set inside Ubuntu.
    Hostname          = 'ubuntu-vm'

    # Full path to the Ubuntu Server install image you downloaded.
    SourceIso         = 'C:\Users\Public\iso\ubuntu-26.04-live-server-amd64.iso'

    # Where the VM disk file lives. The build creates this folder if needed.
    VmDir             = 'D:\VMs\ubuntu-vm'

    # Hyper-V virtual switch the VM connects to.
    SwitchName        = 'NatSwitch'

    # Static network settings that match your NAT switch subnet.
    # Give each VM on the same switch a different IpCidr.
    IpCidr            = '192.168.50.10/24'
    Gateway           = '192.168.50.1'
    Dns               = '1.1.1.1, 8.8.8.8'

    # Sizing. Memory is fixed, not dynamic. The Hyper-V dynamic memory balloon can
    # drive a Linux guest into a memory deadlock, so a fixed size is used instead.
    # Give the installer room. Below about 2048 it struggles.
    Cpus              = 4
    MemoryMB          = 4096
    DiskSizeGB        = 300

    # Where credentials and build files for this VM are written.
    # This whole folder is ignored by git.
    OutputDir         = '.\out'
}

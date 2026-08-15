# Proxmox Scripts

Simple automated deployment scripts for Proxmox VE.

## Ubuntu 24.04 VM installer

`install-ubuntu.sh` is an interactive installer that runs directly on a Proxmox VE host. It downloads the official Ubuntu 24.04 LTS cloud image and creates a virtual machine using Proxmox Cloud-Init.

Run it from a Proxmox VE root shell:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/abeksis/proxmox-scripts/main/install-ubuntu.sh)
```

The installer lets you configure:

- Ubuntu 24.04 LTS
- Cloud-Init
- CPU cores and host CPU type
- RAM
- Disk size
- Active Proxmox storage
- DHCP or a static IPv4 address
- Cloud-Init username and optional password
- Optional SSH public key
- QEMU Guest Agent

It shows a complete configuration summary before making changes and starts the VM after a successful setup.

## Debian 13 VM installer

`install-debian.sh` provides the same interactive deployment workflow for Debian 13 "Trixie" using the official Debian generic cloud image and Proxmox Cloud-Init.

Run it from a Proxmox VE root shell:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/abeksis/proxmox-scripts/main/install-debian.sh)
```

The installer configures CPU, RAM, disk, storage, DHCP or static IPv4 networking, a Cloud-Init user, an optional password and SSH key, serial console access, and the QEMU Guest Agent setting.

## Windows 11 VM installer

`install-windows11.sh` creates a Windows 11-ready VM with OVMF UEFI, Secure Boot, Q35, TPM 2.0, VirtIO SCSI storage, VirtIO networking, and the QEMU Guest Agent setting. It detects a Windows installation ISO already uploaded to Proxmox and downloads the stable VirtIO driver ISO when needed.

Run it from a Proxmox VE root shell:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/abeksis/proxmox-scripts/main/install-windows11.sh)
```

The script starts the VM for a manual Windows installation through the Proxmox console. During Windows Setup, load the storage driver from `vioscsi\w11\amd64` on the VirtIO CD if the system disk is not displayed. If setup requests a network driver, use `NetKVM\w11\amd64`. After installation, run `virtio-win-guest-tools.exe` from the VirtIO CD to install the remaining drivers and QEMU Guest Agent.

Before running the installer, upload a legitimate Windows 11 ISO to an ISO-enabled Proxmox storage. A valid Windows license is required; this repository does not provide licenses or bypass Windows requirements.

## Requirements

- Proxmox VE
- A root shell on the Proxmox host
- Internet access

## Warning

Review scripts before running them as root.

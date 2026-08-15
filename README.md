# Proxmox Scripts

Simple automated deployment scripts for Proxmox VE.

## Quick start

Run the central interactive installer from a Proxmox VE root shell:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/abeksis/proxmox-scripts/main/install.sh)
```

Choose an operating system from the menu:

```text
1) Ubuntu 24.04 LTS
2) Debian 13 Trixie
3) Windows 11
4) Home Assistant OS
5) OPNsense
```

The central installer downloads, validates, and runs the selected operating-system installer. Individual installers can also be run directly using the commands below.

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

## Home Assistant OS installer

`install-home-assistant.sh` detects the latest stable Home Assistant OS release, downloads and verifies the official KVM/Proxmox QCOW2 image, and creates an OVMF UEFI VM without Secure Boot. The VM uses DHCP, starts automatically with the Proxmox host, and can be opened at `http://homeassistant.local:8123` after initial startup.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/abeksis/proxmox-scripts/main/install-home-assistant.sh)
```

## OPNsense installer

`install-opnsense.sh` detects existing OPNsense installation media or downloads the latest official amd64 DVD image, verifies its published SHA-256 checksum, and creates a Q35 VM with separate VirtIO WAN and LAN interfaces. Bridges and optional VLAN tags are validated before the VM is created.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/abeksis/proxmox-scripts/main/install-opnsense.sh)
```

The OPNsense installation continues manually in the Proxmox console. The script assigns `vtnet0` to LAN and `vtnet1` to WAN, matching OPNsense defaults. Carefully verify network placement: an incorrect firewall interface assignment can expose services or interrupt connectivity.

## Requirements

- Proxmox VE
- A root shell on the Proxmox host
- Internet access

## Warning

Review scripts before running them as root.

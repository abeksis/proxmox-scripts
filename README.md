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

## Requirements

- Proxmox VE
- A root shell on the Proxmox host
- Internet access

## Warning

Review scripts before running them as root.

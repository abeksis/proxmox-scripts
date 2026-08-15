#!/usr/bin/env bash

set -Eeuo pipefail

readonly IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"

if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[0;33m'
    readonly BLUE='\033[0;34m'
    readonly BOLD='\033[1m'
    readonly RESET='\033[0m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly BOLD=''
    readonly RESET=''
fi

VM_CREATED=0
VM_CREATE_ATTEMPTED=0
VMID="unknown"
IMAGE_PATH=""

success() { printf "%b✔%b %s\n" "$GREEN" "$RESET" "$*"; }
progress() { printf "%b➜%b %s\n" "$BLUE" "$RESET" "$*"; }
warning() { printf "%b⚠%b %s\n" "$YELLOW" "$RESET" "$*" >&2; }
die() { printf "%b✖ Error:%b %s\n" "$RED" "$RESET" "$*" >&2; exit 1; }

on_error() {
    local exit_code=$?
    local line_number=${1:-unknown}

    printf "\n%b✖ Installation failed on line %s (exit code %s).%b\n" \
        "$RED" "$line_number" "$exit_code" "$RESET" >&2
    if (( VM_CREATED || VM_CREATE_ATTEMPTED )); then
        warning "VM ${VMID} may be partially created. It has not been deleted."
    else
        warning "No automatic VM cleanup was attempted."
    fi
    if [[ -n "$IMAGE_PATH" && -f "$IMAGE_PATH" ]]; then
        warning "The downloaded image remains at: ${IMAGE_PATH}"
    fi
    exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

show_header() {
    clear 2>/dev/null || true
    printf "%b" "$BOLD"
    cat <<'EOF'
╔══════════════════════════════════════════════╗
║       Proxmox Debian VM Installer            ║
║              Debian 13 Trixie                ║
╚══════════════════════════════════════════════╝
EOF
    printf "%b\n" "$RESET"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

prompt_default() {
    local prompt=$1
    local default=$2
    local value

    read -r -p "$prompt [$default]: " value
    printf '%s' "${value:-$default}"
}

prompt_integer() {
    local prompt=$1
    local default=$2
    local minimum=$3
    local value

    while true; do
        value=$(prompt_default "$prompt" "$default")
        if [[ "$value" =~ ^[0-9]+$ ]] && (( 10#$value >= minimum )); then
            printf '%s' "$((10#$value))"
            return
        fi
        warning "$prompt must be a whole number of at least $minimum."
    done
}

prompt_yes_no() {
    local prompt=$1
    local default=${2:-n}
    local hint='y/N'
    local answer

    [[ "$default" == "y" ]] && hint='Y/n'
    while true; do
        read -r -p "$prompt [$hint]: " answer
        answer=${answer:-$default}
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) warning "Please answer yes or no." ;;
        esac
    done
}

valid_ipv4() {
    local ip=$1
    local octet
    local -a octets

    IFS='.' read -r -a octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

valid_ipv4_cidr() {
    local value=$1
    local ip prefix

    [[ "$value" == */* ]] || return 1
    ip=${value%/*}
    prefix=${value##*/}
    valid_ipv4 "$ip" && [[ "$prefix" =~ ^[0-9]+$ ]] && (( 10#$prefix <= 32 ))
}

vm_id_exists() {
    qm status "$1" >/dev/null 2>&1
}

show_header

(( EUID == 0 )) || die "This installer must be run as root."
require_command qm
require_command pvesh
require_command pvesm

if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
else
    die "Either curl or wget is required to download the Debian cloud image."
fi

success "Proxmox commands and root access verified."

progress "Detecting the next available VM ID..."
NEXT_VMID=$(pvesh get /cluster/nextid)
[[ "$NEXT_VMID" =~ ^[0-9]+$ ]] || die "Proxmox returned an invalid next VM ID: $NEXT_VMID"

while true; do
    VMID=$(prompt_integer "VM ID" "$NEXT_VMID" 1)
    if vm_id_exists "$VMID"; then
        warning "VM ID $VMID already exists. Choose another ID."
    else
        break
    fi
done

VM_NAME=$(prompt_default "VM name" "debian-13")
[[ "$VM_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "VM name contains invalid characters."

CPU_CORES=$(prompt_integer "CPU cores" "4" 1)
RAM_MB=$(prompt_integer "RAM (MB)" "4096" 512)
DISK_GB=$(prompt_integer "Disk size (GB)" "32" 8)

progress "Detecting active Proxmox storages..."
mapfile -t STORAGES < <(pvesm status | awk 'NR > 1 && $3 == "active" {print $1}')
(( ${#STORAGES[@]} > 0 )) || die "No active Proxmox storage was detected."

printf "\nAvailable active storages:\n"
for index in "${!STORAGES[@]}"; do
    printf "  %d) %s\n" "$((index + 1))" "${STORAGES[$index]}"
done

while true; do
    read -r -p "Select storage [1]: " STORAGE_CHOICE
    STORAGE_CHOICE=${STORAGE_CHOICE:-1}
    if [[ "$STORAGE_CHOICE" =~ ^[0-9]+$ ]] \
        && (( 10#$STORAGE_CHOICE >= 1 && 10#$STORAGE_CHOICE <= ${#STORAGES[@]} )); then
        STORAGE=${STORAGES[$((10#$STORAGE_CHOICE - 1))]}
        break
    fi
    warning "Select a number between 1 and ${#STORAGES[@]}."
done

printf '%s\n' "${STORAGES[@]}" | grep -Fxq "$STORAGE" \
    || die "Selected storage does not exist or is not active: $STORAGE"

BRIDGE=$(prompt_default "Network bridge" "vmbr0")
[[ "$BRIDGE" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "Network bridge contains invalid characters."

printf "\nNetwork configuration:\n  1) DHCP\n  2) Static IPv4\n"
while true; do
    read -r -p "Select network configuration [1]: " NETWORK_CHOICE
    NETWORK_CHOICE=${NETWORK_CHOICE:-1}
    case "$NETWORK_CHOICE" in
        1)
            NETWORK_MODE="DHCP"
            IP_CONFIG="ip=dhcp"
            break
            ;;
        2)
            NETWORK_MODE="Static IPv4"
            while true; do
                read -r -p "IPv4 address with CIDR (for example 192.168.1.50/24): " STATIC_IP
                valid_ipv4_cidr "$STATIC_IP" && break
                warning "Enter a valid IPv4 address with CIDR prefix."
            done
            while true; do
                read -r -p "IPv4 gateway (router address, not subnet mask): " GATEWAY
                valid_ipv4 "$GATEWAY" && break
                warning "Enter a valid IPv4 gateway."
            done
            IP_CONFIG="ip=${STATIC_IP},gw=${GATEWAY}"
            break
            ;;
        *) warning "Select 1 or 2." ;;
    esac
done

CI_USER=$(prompt_default "Cloud-Init username" "debian")
[[ "$CI_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Cloud-Init username is invalid."

CONFIGURE_PASSWORD=0
CI_PASSWORD=""
if prompt_yes_no "Configure a login password?" "n"; then
    CONFIGURE_PASSWORD=1
    while true; do
        read -r -s -p "Cloud-Init password: " PASSWORD_ONE
        printf '\n'
        read -r -s -p "Confirm password: " PASSWORD_TWO
        printf '\n'
        if [[ -z "$PASSWORD_ONE" ]]; then
            warning "Password cannot be empty."
        elif [[ "$PASSWORD_ONE" != "$PASSWORD_TWO" ]]; then
            warning "Passwords do not match. Try again."
        else
            CI_PASSWORD=$PASSWORD_ONE
            unset PASSWORD_ONE PASSWORD_TWO
            break
        fi
    done
fi

SSH_KEY_FILE=""
if prompt_yes_no "Configure an SSH public key file from this Proxmox host?" "n"; then
    while true; do
        read -r -e -p "SSH public key file path (for example /root/laptop.pub): " SSH_KEY_FILE
        if [[ -f "$SSH_KEY_FILE" && -r "$SSH_KEY_FILE" && -s "$SSH_KEY_FILE" ]]; then
            break
        fi
        warning "The SSH public key file must exist, be readable, and not be empty."
    done
fi

printf "\n%bConfiguration summary%b\n" "$BOLD" "$RESET"
printf "  VM ID:              %s\n" "$VMID"
printf "  VM name:            %s\n" "$VM_NAME"
printf "  CPU:                %s cores (type: host)\n" "$CPU_CORES"
printf "  RAM:                %s MB\n" "$RAM_MB"
printf "  Disk:               %s GB on %s\n" "$DISK_GB" "$STORAGE"
printf "  Network bridge:     %s\n" "$BRIDGE"
printf "  Network mode:       %s\n" "$NETWORK_MODE"
[[ "$NETWORK_MODE" == "Static IPv4" ]] && printf "  Address / gateway:  %s / %s\n" "$STATIC_IP" "$GATEWAY"
printf "  Cloud-Init user:    %s\n" "$CI_USER"
printf "  Login password:     %s\n" "$([[ $CONFIGURE_PASSWORD -eq 1 ]] && echo configured || echo not configured)"
printf "  SSH public key:     %s\n" "${SSH_KEY_FILE:-not configured}"
printf "  QEMU Guest Agent:   enabled\n"
printf "  Start after setup:  yes\n\n"

if ! prompt_yes_no "Create and start this VM?" "n"; then
    warning "Installation cancelled. No VM was created."
    exit 0
fi

# Check again immediately before creating the VM to prevent an ID race or overwrite.
vm_id_exists "$VMID" && die "VM ID $VMID was created by another process. Nothing was changed."

IMAGE_PATH=$(mktemp "/tmp/debian-13-genericcloud-amd64.qcow2.XXXXXX")
progress "Downloading the official Debian 13 cloud image..."
if [[ "$DOWNLOADER" == "curl" ]]; then
    curl -fL --retry 3 --output "$IMAGE_PATH" "$IMAGE_URL"
else
    wget --tries=3 --output-document="$IMAGE_PATH" "$IMAGE_URL"
fi
success "Debian cloud image downloaded."

progress "Creating VM $VMID..."
VM_CREATE_ATTEMPTED=1
qm create "$VMID" \
    --name "$VM_NAME" \
    --ostype l26 \
    --cpu host \
    --cores "$CPU_CORES" \
    --memory "$RAM_MB" \
    --scsihw virtio-scsi-single \
    --net0 "virtio,bridge=${BRIDGE}" \
    --agent enabled=1 \
    --serial0 socket \
    --vga serial0
VM_CREATED=1
success "VM definition created."

progress "Importing the cloud image into storage $STORAGE..."
qm disk import "$VMID" "$IMAGE_PATH" "$STORAGE"

IMPORTED_DISK=$(qm config "$VMID" | awk -F': ' '/^unused[0-9]+:/ {print $2; exit}')
[[ -n "$IMPORTED_DISK" ]] || die "Imported disk was not found in the VM configuration."
success "Imported disk detected: $IMPORTED_DISK"

progress "Attaching and resizing the system disk..."
qm set "$VMID" --scsi0 "${IMPORTED_DISK},discard=on,ssd=1,iothread=1"
qm resize "$VMID" scsi0 "${DISK_GB}G"

progress "Adding and configuring Cloud-Init..."
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --ciuser "$CI_USER"
qm set "$VMID" --ipconfig0 "$IP_CONFIG"

if (( CONFIGURE_PASSWORD )); then
    qm set "$VMID" --cipassword "$CI_PASSWORD"
    unset CI_PASSWORD
fi

if [[ -n "$SSH_KEY_FILE" ]]; then
    qm set "$VMID" --sshkeys "$SSH_KEY_FILE"
fi

qm set "$VMID" --boot order=scsi0
success "Cloud-Init and boot settings configured."

progress "Starting VM $VMID..."
qm start "$VMID"
success "VM $VMID started successfully."

rm -f -- "$IMAGE_PATH"
IMAGE_PATH=""
success "Downloaded cloud image removed."

printf "\n%b✔ Debian 13 VM %s (%s) is ready.%b\n" \
    "$GREEN" "$VMID" "$VM_NAME" "$RESET"

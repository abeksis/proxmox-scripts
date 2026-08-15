#!/usr/bin/env bash

set -Eeuo pipefail

readonly VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

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
VIRTIO_TEMP=""

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
    if [[ -n "$VIRTIO_TEMP" && -f "$VIRTIO_TEMP" ]]; then
        warning "A partial VirtIO download remains at: ${VIRTIO_TEMP}"
    fi
    exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

show_header() {
    clear 2>/dev/null || true
    printf "%b" "$BOLD"
    cat <<'EOF'
╔══════════════════════════════════════════════╗
║      Proxmox Windows 11 VM Installer         ║
║        UEFI · Secure Boot · TPM 2.0          ║
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

select_option() {
    local prompt=$1
    shift
    local -a options=("$@")
    local choice
    local index

    (( ${#options[@]} > 0 )) || die "No options are available for: $prompt"
    for index in "${!options[@]}"; do
        printf "  %d) %s\n" "$((index + 1))" "${options[$index]}" >&2
    done

    while true; do
        read -r -p "$prompt [1]: " choice
        choice=${choice:-1}
        if [[ "$choice" =~ ^[0-9]+$ ]] \
            && (( 10#$choice >= 1 && 10#$choice <= ${#options[@]} )); then
            printf '%s' "${options[$((10#$choice - 1))]}"
            return
        fi
        warning "Select a number between 1 and ${#options[@]}."
    done
}

vm_id_exists() {
    qm status "$1" >/dev/null 2>&1
}

show_header

(( EUID == 0 )) || die "This installer must be run as root."
require_command qm
require_command pvesh
require_command pvesm
require_command awk
require_command dirname
require_command mktemp

DOWNLOADER=""
if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
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

VM_NAME=$(prompt_default "VM name" "windows-11")
[[ "$VM_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "VM name contains invalid characters."

CPU_CORES=$(prompt_integer "CPU cores" "4" 2)
RAM_MB=$(prompt_integer "RAM (MB)" "8192" 4096)
DISK_GB=$(prompt_integer "Disk size (GB)" "80" 64)

progress "Detecting active VM storages..."
mapfile -t VM_STORAGES < <(pvesm status --content images --enabled 1 \
    | awk 'NR > 1 && $3 == "active" {print $1}')
(( ${#VM_STORAGES[@]} > 0 )) || die "No active storage supporting VM images was detected."
printf "\nAvailable VM storages:\n"
VM_STORAGE=$(select_option "Select VM storage" "${VM_STORAGES[@]}")

progress "Detecting active ISO storages and Windows installation media..."
mapfile -t ISO_STORAGES < <(pvesm status --content iso --enabled 1 \
    | awk 'NR > 1 && $3 == "active" {print $1}')
(( ${#ISO_STORAGES[@]} > 0 )) || die "No active storage supporting ISO images was detected."

WINDOWS_ISOS=()
VIRTIO_ISOS=()
for iso_storage in "${ISO_STORAGES[@]}"; do
    while IFS= read -r iso_volume; do
        [[ -n "$iso_volume" ]] || continue
        case "${iso_volume,,}" in
            *virtio-win*.iso) VIRTIO_ISOS+=("$iso_volume") ;;
            *) WINDOWS_ISOS+=("$iso_volume") ;;
        esac
    done < <(pvesm list "$iso_storage" --content iso 2>/dev/null \
        | awk 'NR > 1 && tolower($1) ~ /\.iso$/ {print $1}')
done

if (( ${#WINDOWS_ISOS[@]} == 0 )); then
    die "No Windows installation ISO was found. Upload a Windows 11 ISO to Proxmox storage and run this installer again."
fi

printf "\nAvailable installation ISOs:\n"
WINDOWS_ISO=$(select_option "Select the Windows 11 ISO" "${WINDOWS_ISOS[@]}")

VIRTIO_DOWNLOAD_NEEDED=0
if (( ${#VIRTIO_ISOS[@]} > 0 )); then
    VIRTIO_ISO=${VIRTIO_ISOS[0]}
    success "Existing VirtIO driver ISO detected: $VIRTIO_ISO"
else
    [[ -n "$DOWNLOADER" ]] \
        || die "Either curl or wget is required when the VirtIO driver ISO is not already available."
    VIRTIO_STORAGE=${WINDOWS_ISO%%:*}
    VIRTIO_ISO="${VIRTIO_STORAGE}:iso/virtio-win.iso"
    VIRTIO_DOWNLOAD_NEEDED=1
fi

BRIDGE=$(prompt_default "Network bridge" "vmbr0")
[[ "$BRIDGE" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "Network bridge contains invalid characters."

printf "\n%bConfiguration summary%b\n" "$BOLD" "$RESET"
printf "  VM ID:              %s\n" "$VMID"
printf "  VM name:            %s\n" "$VM_NAME"
printf "  CPU:                %s cores (type: host)\n" "$CPU_CORES"
printf "  RAM:                %s MB\n" "$RAM_MB"
printf "  Disk:               %s GB on %s\n" "$DISK_GB" "$VM_STORAGE"
printf "  Windows ISO:        %s\n" "$WINDOWS_ISO"
printf "  VirtIO ISO:         %s%s\n" "$VIRTIO_ISO" \
    "$([[ $VIRTIO_DOWNLOAD_NEEDED -eq 1 ]] && echo ' (will be downloaded)' || true)"
printf "  Network bridge:     %s\n" "$BRIDGE"
printf "  Firmware:           OVMF UEFI with Secure Boot\n"
printf "  Machine type:       q35\n"
printf "  TPM:                2.0\n"
printf "  QEMU Guest Agent:   enabled after guest tools installation\n"
printf "  Installation mode:  manual through the Proxmox console\n"
printf "  Start after setup:  yes\n\n"

warning "This script does not provide a Windows license or bypass Windows 11 requirements."
if ! prompt_yes_no "Create and start this Windows 11 VM?" "n"; then
    warning "Installation cancelled. No VM was created."
    exit 0
fi

# Check again immediately before making changes to prevent an ID race or overwrite.
vm_id_exists "$VMID" && die "VM ID $VMID was created by another process. Nothing was changed."

if (( VIRTIO_DOWNLOAD_NEEDED )); then
    progress "Preparing the VirtIO driver ISO destination..."
    WINDOWS_ISO_PATH=$(pvesm path "$WINDOWS_ISO")
    VIRTIO_DIRECTORY=$(dirname -- "$WINDOWS_ISO_PATH")
    VIRTIO_PATH="${VIRTIO_DIRECTORY}/virtio-win.iso"
    [[ -d "$VIRTIO_DIRECTORY" && -w "$VIRTIO_DIRECTORY" ]] \
        || die "VirtIO ISO destination is not writable: $VIRTIO_DIRECTORY"

    if [[ -f "$VIRTIO_PATH" ]]; then
        warning "VirtIO ISO appeared during setup; the existing file will be used."
    else
        VIRTIO_TEMP=$(mktemp "${VIRTIO_PATH}.partial.XXXXXX")
        progress "Downloading the stable VirtIO driver ISO (approximately 753 MB)..."
        if [[ "$DOWNLOADER" == "curl" ]]; then
            curl -fL --retry 3 --output "$VIRTIO_TEMP" "$VIRTIO_URL"
        else
            wget --tries=3 --output-document="$VIRTIO_TEMP" "$VIRTIO_URL"
        fi
        chmod 0644 "$VIRTIO_TEMP"
        mv -- "$VIRTIO_TEMP" "$VIRTIO_PATH"
        VIRTIO_TEMP=""
        success "VirtIO driver ISO downloaded: $VIRTIO_ISO"
    fi
fi

progress "Creating Windows 11 VM $VMID..."
VM_CREATE_ATTEMPTED=1
qm create "$VMID" \
    --name "$VM_NAME" \
    --ostype win11 \
    --machine q35 \
    --bios ovmf \
    --cpu host \
    --cores "$CPU_CORES" \
    --memory "$RAM_MB" \
    --scsihw virtio-scsi-single \
    --net0 "virtio,bridge=${BRIDGE}" \
    --agent enabled=1 \
    --tablet 1
VM_CREATED=1
success "VM definition created."

progress "Adding EFI, TPM 2.0, and the system disk..."
qm set "$VMID" --efidisk0 "${VM_STORAGE}:1,efitype=4m,pre-enrolled-keys=1"
qm set "$VMID" --tpmstate0 "${VM_STORAGE}:1,version=v2.0"
qm set "$VMID" --scsi0 "${VM_STORAGE}:${DISK_GB},discard=on,iothread=1,ssd=1"

progress "Attaching Windows and VirtIO installation media..."
qm set "$VMID" --ide2 "${WINDOWS_ISO},media=cdrom"
qm set "$VMID" --ide3 "${VIRTIO_ISO},media=cdrom"
qm set "$VMID" --boot "order=ide2;scsi0"
success "Windows 11 hardware and installation media configured."

progress "Starting VM $VMID..."
qm start "$VMID"
success "VM $VMID started successfully."

printf "\n%b✔ Windows 11 VM %s (%s) is ready for installation.%b\n\n" \
    "$GREEN" "$VMID" "$VM_NAME" "$RESET"
cat <<'EOF'
Next steps:
  1. Open the VM console in Proxmox and start Windows Setup.
  2. If no disk is shown, choose Load driver and browse the VirtIO CD:
       vioscsi\w11\amd64
  3. If Windows asks for a network driver during setup, browse to:
       NetKVM\w11\amd64
  4. After Windows is installed, run this from the VirtIO CD:
       virtio-win-guest-tools.exe
     This installs the remaining VirtIO drivers and QEMU Guest Agent.
  5. Activate Windows with a valid license.
EOF

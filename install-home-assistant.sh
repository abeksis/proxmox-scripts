#!/usr/bin/env bash

set -Eeuo pipefail

readonly RELEASE_API="https://api.github.com/repos/home-assistant/operating-system/releases/latest"

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
COMPRESSED_IMAGE=""
DISK_IMAGE=""

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
    [[ -n "$COMPRESSED_IMAGE" && -f "$COMPRESSED_IMAGE" ]] \
        && warning "The compressed download remains at: $COMPRESSED_IMAGE"
    [[ -n "$DISK_IMAGE" && -f "$DISK_IMAGE" ]] \
        && warning "The extracted disk image remains at: $DISK_IMAGE"
    exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

show_header() {
    clear 2>/dev/null || true
    printf "%b" "$BOLD"
    cat <<'EOF'
╔══════════════════════════════════════════════╗
║    Proxmox Home Assistant OS Installer       ║
║        Latest stable KVM image               ║
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
    local choice index

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
require_command qemu-img
require_command awk
require_command sed
require_command sha256sum
require_command xz
require_command mktemp

if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
else
    die "Either curl or wget is required to download Home Assistant OS."
fi

success "Proxmox commands and root access verified."

progress "Detecting the latest stable Home Assistant OS release..."
if [[ "$DOWNLOADER" == "curl" ]]; then
    RELEASE_JSON=$(curl -fsSL --retry 3 "$RELEASE_API")
else
    RELEASE_JSON=$(wget --tries=3 --quiet --output-document=- "$RELEASE_API")
fi

HAOS_VERSION=$(printf '%s\n' "$RELEASE_JSON" \
    | sed -n 's/^[[:space:]]*"tag_name": "\([^"]*\)",/\1/p' | sed -n '1p')
[[ "$HAOS_VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]] \
    || die "Could not determine the latest stable Home Assistant OS version."

HAOS_ASSET="haos_ova-${HAOS_VERSION}.qcow2.xz"
HAOS_SHA256=$(printf '%s\n' "$RELEASE_JSON" | awk -v asset="$HAOS_ASSET" '
    index($0, "\"name\": \"" asset "\"") { found=1 }
    found && /"digest": "sha256:/ {
        line=$0
        sub(/^.*"digest": "sha256:/, "", line)
        sub(/".*$/, "", line)
        print line
        exit
    }
')
[[ "$HAOS_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "Could not obtain the official SHA-256 digest for $HAOS_ASSET."
HAOS_URL="https://github.com/home-assistant/operating-system/releases/download/${HAOS_VERSION}/${HAOS_ASSET}"
success "Latest stable release detected: Home Assistant OS $HAOS_VERSION"

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

VM_NAME=$(prompt_default "VM name" "home-assistant")
[[ "$VM_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "VM name contains invalid characters."
CPU_CORES=$(prompt_integer "CPU cores" "2" 2)
RAM_MB=$(prompt_integer "RAM (MB)" "4096" 2048)
DISK_GB=$(prompt_integer "Disk size (GB)" "32" 32)

progress "Detecting active VM storages..."
mapfile -t STORAGES < <(pvesm status --content images --enabled 1 \
    | awk 'NR > 1 && $3 == "active" {print $1}')
(( ${#STORAGES[@]} > 0 )) || die "No active storage supporting VM images was detected."
printf "\nAvailable VM storages:\n"
STORAGE=$(select_option "Select VM storage" "${STORAGES[@]}")

BRIDGE=$(prompt_default "Network bridge" "vmbr0")
[[ "$BRIDGE" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "Network bridge contains invalid characters."

printf "\n%bConfiguration summary%b\n" "$BOLD" "$RESET"
printf "  Home Assistant OS:  %s\n" "$HAOS_VERSION"
printf "  VM ID:              %s\n" "$VMID"
printf "  VM name:            %s\n" "$VM_NAME"
printf "  CPU:                %s cores (type: host)\n" "$CPU_CORES"
printf "  RAM:                %s MB\n" "$RAM_MB"
printf "  Disk:               %s GB on %s\n" "$DISK_GB" "$STORAGE"
printf "  Network bridge:     %s (DHCP)\n" "$BRIDGE"
printf "  Firmware:           OVMF UEFI without Secure Boot\n"
printf "  Start at host boot: yes\n"
printf "  Start after setup:  yes\n\n"

if ! prompt_yes_no "Create and start this Home Assistant OS VM?" "n"; then
    warning "Installation cancelled. No VM was created."
    exit 0
fi

vm_id_exists "$VMID" && die "VM ID $VMID was created by another process. Nothing was changed."

COMPRESSED_IMAGE=$(mktemp "/tmp/${HAOS_ASSET}.XXXXXX")
DISK_IMAGE=$(mktemp "/tmp/haos_ova-${HAOS_VERSION}.qcow2.XXXXXX")

progress "Downloading Home Assistant OS $HAOS_VERSION..."
if [[ "$DOWNLOADER" == "curl" ]]; then
    curl -fL --retry 3 --output "$COMPRESSED_IMAGE" "$HAOS_URL"
else
    wget --tries=3 --output-document="$COMPRESSED_IMAGE" "$HAOS_URL"
fi

progress "Verifying the official SHA-256 digest..."
printf '%s  %s\n' "$HAOS_SHA256" "$COMPRESSED_IMAGE" | sha256sum --check --status \
    || die "Home Assistant OS image checksum verification failed."
success "Image checksum verified."

progress "Extracting the KVM disk image..."
xz --decompress --stdout -- "$COMPRESSED_IMAGE" > "$DISK_IMAGE"
[[ -s "$DISK_IMAGE" ]] || die "The extracted Home Assistant OS disk image is empty."

IMAGE_BYTES=$(qemu-img info --output=json "$DISK_IMAGE" \
    | sed -n 's/^[[:space:]]*"virtual-size": \([0-9][0-9]*\),*$/\1/p')
[[ "$IMAGE_BYTES" =~ ^[0-9]+$ ]] || die "Could not determine the Home Assistant OS disk size."
IMAGE_GB=$(( (IMAGE_BYTES + 1073741823) / 1073741824 ))
(( DISK_GB >= IMAGE_GB )) \
    || die "Requested disk size ${DISK_GB} GB is smaller than the ${IMAGE_GB} GB image."

progress "Creating Home Assistant OS VM $VMID..."
VM_CREATE_ATTEMPTED=1
qm create "$VMID" \
    --name "$VM_NAME" \
    --ostype l26 \
    --machine q35 \
    --bios ovmf \
    --cpu host \
    --cores "$CPU_CORES" \
    --memory "$RAM_MB" \
    --scsihw virtio-scsi-single \
    --net0 "virtio,bridge=${BRIDGE}" \
    --agent enabled=1 \
    --onboot 1
VM_CREATED=1

qm set "$VMID" --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0"

progress "Importing and attaching the Home Assistant OS disk..."
qm disk import "$VMID" "$DISK_IMAGE" "$STORAGE"
IMPORTED_DISK=$(qm config "$VMID" | awk -F': ' '/^unused[0-9]+:/ {print $2; exit}')
[[ -n "$IMPORTED_DISK" ]] || die "Imported disk was not found in the VM configuration."
qm set "$VMID" --scsi0 "${IMPORTED_DISK},discard=on,ssd=1,iothread=1"

if (( DISK_GB > IMAGE_GB )); then
    qm resize "$VMID" scsi0 "${DISK_GB}G"
fi
qm set "$VMID" --boot order=scsi0
success "Home Assistant OS VM configured."

progress "Starting VM $VMID..."
qm start "$VMID"
success "VM $VMID started successfully."

rm -f -- "$COMPRESSED_IMAGE" "$DISK_IMAGE"
COMPRESSED_IMAGE=""
DISK_IMAGE=""
success "Downloaded installation files removed."

printf "\n%b✔ Home Assistant OS %s is starting in VM %s (%s).%b\n" \
    "$GREEN" "$HAOS_VERSION" "$VMID" "$VM_NAME" "$RESET"
printf "Open http://homeassistant.local:8123 after the initial startup completes.\n"

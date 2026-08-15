#!/usr/bin/env bash

set -Eeuo pipefail

readonly MIRROR_URL="https://pkg.opnsense.org/releases/mirror"

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
ARCHIVE_TEMP=""
ISO_TEMP=""
STORAGE_TEMP=""

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
    [[ -n "$ARCHIVE_TEMP" && -f "$ARCHIVE_TEMP" ]] && warning "Download remains at: $ARCHIVE_TEMP"
    [[ -n "$ISO_TEMP" && -f "$ISO_TEMP" ]] && warning "Extracted ISO remains at: $ISO_TEMP"
    [[ -n "$STORAGE_TEMP" && -f "$STORAGE_TEMP" ]] && warning "Partial storage copy remains at: $STORAGE_TEMP"
    exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

show_header() {
    clear 2>/dev/null || true
    printf "%b" "$BOLD"
    cat <<'EOF'
╔══════════════════════════════════════════════╗
║       Proxmox OPNsense VM Installer          ║
║       Firewall · Router · VPN                ║
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

prompt_bridge() {
    local prompt=$1
    local default=$2
    local bridge

    while true; do
        bridge=$(prompt_default "$prompt" "$default")
        if [[ "$bridge" =~ ^[A-Za-z0-9_.:-]+$ ]] && ip link show dev "$bridge" >/dev/null 2>&1; then
            printf '%s' "$bridge"
            return
        fi
        warning "Bridge $bridge does not exist on this Proxmox host."
    done
}

prompt_vlan() {
    local prompt=$1
    local vlan

    while true; do
        read -r -p "$prompt [none]: " vlan
        if [[ -z "$vlan" ]]; then
            return
        fi
        if [[ "$vlan" =~ ^[0-9]+$ ]] && (( 10#$vlan >= 1 && 10#$vlan <= 4094 )); then
            printf '%s' "$((10#$vlan))"
            return
        fi
        warning "VLAN tag must be empty or a number between 1 and 4094."
    done
}

vm_id_exists() {
    qm status "$1" >/dev/null 2>&1
}

download_stdout() {
    local url=$1
    if [[ "$DOWNLOADER" == "curl" ]]; then
        curl -fsSL --retry 3 "$url"
    else
        wget --tries=3 --quiet --output-document=- "$url"
    fi
}

show_header

(( EUID == 0 )) || die "This installer must be run as root."
require_command qm
require_command pvesh
require_command pvesm
require_command awk
require_command grep
require_command sort
require_command tail
require_command sha256sum
require_command bzip2
require_command mktemp
require_command dirname
require_command ip

if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
else
    die "Either curl or wget is required to download OPNsense."
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

VM_NAME=$(prompt_default "VM name" "opnsense")
[[ "$VM_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "VM name contains invalid characters."
CPU_CORES=$(prompt_integer "CPU cores" "2" 2)
RAM_MB=$(prompt_integer "RAM (MB)" "4096" 2048)
DISK_GB=$(prompt_integer "Disk size (GB)" "32" 16)

progress "Detecting active VM storages..."
mapfile -t VM_STORAGES < <(pvesm status --content images --enabled 1 \
    | awk 'NR > 1 && $3 == "active" {print $1}')
(( ${#VM_STORAGES[@]} > 0 )) || die "No active storage supporting VM images was detected."
printf "\nAvailable VM storages:\n"
VM_STORAGE=$(select_option "Select VM storage" "${VM_STORAGES[@]}")

progress "Detecting active ISO storages and existing OPNsense media..."
mapfile -t ISO_STORAGES < <(pvesm status --content iso --enabled 1 \
    | awk 'NR > 1 && $3 == "active" {print $1}')
(( ${#ISO_STORAGES[@]} > 0 )) || die "No active storage supporting ISO images was detected."

OPNSENSE_ISOS=()
for iso_storage in "${ISO_STORAGES[@]}"; do
    while IFS= read -r iso_volume; do
        [[ -n "$iso_volume" ]] && OPNSENSE_ISOS+=("$iso_volume")
    done < <(pvesm list "$iso_storage" --content iso 2>/dev/null \
        | awk 'NR > 1 && tolower($1) ~ /opnsense-.*-dvd-amd64[.]iso$/ {print $1}')
done

ISO_DOWNLOAD_NEEDED=0
if (( ${#OPNSENSE_ISOS[@]} > 0 )); then
    printf "\nAvailable OPNsense ISOs:\n"
    OPNSENSE_ISO=$(select_option "Select OPNsense ISO" "${OPNSENSE_ISOS[@]}")
    OPNSENSE_VERSION="existing media"
else
    progress "Detecting the latest official OPNsense installation media..."
    MIRROR_INDEX=$(download_stdout "${MIRROR_URL}/")
    OPNSENSE_ARCHIVE=$(printf '%s\n' "$MIRROR_INDEX" \
        | grep -oE 'OPNsense-[0-9]+([.][0-9]+)*-dvd-amd64[.]iso[.]bz2' \
        | sort -Vu | tail -n 1)
    [[ "$OPNSENSE_ARCHIVE" =~ ^OPNsense-[0-9]+([.][0-9]+)*-dvd-amd64[.]iso[.]bz2$ ]] \
        || die "Could not determine the latest OPNsense DVD image."
    OPNSENSE_VERSION=${OPNSENSE_ARCHIVE#OPNsense-}
    OPNSENSE_VERSION=${OPNSENSE_VERSION%-dvd-amd64.iso.bz2}
    OPNSENSE_ISO_NAME=${OPNSENSE_ARCHIVE%.bz2}

    CHECKSUM_TEXT=$(download_stdout "${MIRROR_URL}/OPNsense-${OPNSENSE_VERSION}-checksums-amd64.sha256")
    EXPECTED_SHA256=$(printf '%s\n' "$CHECKSUM_TEXT" \
        | awk -v file="$OPNSENSE_ARCHIVE" 'index($0, "(" file ")") {print $NF; exit}')
    [[ "$EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]] \
        || die "Could not obtain the official SHA-256 checksum for $OPNSENSE_ARCHIVE."

    printf "\nSelect where the reusable OPNsense ISO should be stored:\n"
    ISO_STORAGE=$(select_option "Select ISO storage" "${ISO_STORAGES[@]}")
    OPNSENSE_ISO="${ISO_STORAGE}:iso/${OPNSENSE_ISO_NAME}"
    ISO_DOWNLOAD_NEEDED=1
    success "Latest installation media detected: OPNsense $OPNSENSE_VERSION"
fi

printf "\nConfigure the OPNsense network interfaces.\n"
WAN_BRIDGE=$(prompt_bridge "WAN bridge" "vmbr0")
WAN_VLAN=$(prompt_vlan "WAN VLAN tag")

while true; do
    LAN_BRIDGE=$(prompt_bridge "LAN bridge" "vmbr1")
    LAN_VLAN=$(prompt_vlan "LAN VLAN tag")
    if [[ "${WAN_BRIDGE}:${WAN_VLAN:-untagged}" != "${LAN_BRIDGE}:${LAN_VLAN:-untagged}" ]]; then
        break
    fi
    warning "WAN and LAN cannot use the same bridge and the same VLAN. Choose a separate LAN network."
done

WAN_NET="virtio,bridge=${WAN_BRIDGE}"
LAN_NET="virtio,bridge=${LAN_BRIDGE}"
[[ -n "$WAN_VLAN" ]] && WAN_NET+=",tag=${WAN_VLAN}"
[[ -n "$LAN_VLAN" ]] && LAN_NET+=",tag=${LAN_VLAN}"

printf "\n%bConfiguration summary%b\n" "$BOLD" "$RESET"
printf "  OPNsense media:     %s\n" "$OPNSENSE_VERSION"
printf "  VM ID:              %s\n" "$VMID"
printf "  VM name:            %s\n" "$VM_NAME"
printf "  CPU:                %s cores (type: host)\n" "$CPU_CORES"
printf "  RAM:                %s MB\n" "$RAM_MB"
printf "  Disk:               %s GB on %s\n" "$DISK_GB" "$VM_STORAGE"
printf "  Installation ISO:  %s%s\n" "$OPNSENSE_ISO" \
    "$([[ $ISO_DOWNLOAD_NEEDED -eq 1 ]] && echo ' (will be downloaded and verified)' || true)"
printf "  LAN (vtnet0):       %s%s\n" "$LAN_BRIDGE" "${LAN_VLAN:+, VLAN $LAN_VLAN}"
printf "  WAN (vtnet1):       %s%s\n" "$WAN_BRIDGE" "${WAN_VLAN:+, VLAN $WAN_VLAN}"
printf "  Machine / firmware: q35 / SeaBIOS\n"
printf "  Installation mode:  manual through the Proxmox console\n"
printf "  Start after setup:  yes\n\n"

warning "Incorrect WAN/LAN placement can disrupt or expose your network. Verify both interfaces carefully."
if ! prompt_yes_no "Create and start this OPNsense VM?" "n"; then
    warning "Installation cancelled. No VM was created."
    exit 0
fi

vm_id_exists "$VMID" && die "VM ID $VMID was created by another process. Nothing was changed."

if (( ISO_DOWNLOAD_NEEDED )); then
    ISO_PATH=$(pvesm path "$OPNSENSE_ISO")
    ISO_DIRECTORY=$(dirname -- "$ISO_PATH")
    [[ -d "$ISO_DIRECTORY" && -w "$ISO_DIRECTORY" ]] \
        || die "OPNsense ISO destination is not writable: $ISO_DIRECTORY"

    if [[ -f "$ISO_PATH" ]]; then
        warning "The OPNsense ISO appeared during setup; the existing file will be used."
    else
        ARCHIVE_TEMP=$(mktemp "/tmp/${OPNSENSE_ARCHIVE}.XXXXXX")
        ISO_TEMP=$(mktemp "/tmp/${OPNSENSE_ISO_NAME}.XXXXXX")
        progress "Downloading OPNsense $OPNSENSE_VERSION..."
        if [[ "$DOWNLOADER" == "curl" ]]; then
            curl -fL --retry 3 --output "$ARCHIVE_TEMP" "${MIRROR_URL}/${OPNSENSE_ARCHIVE}"
        else
            wget --tries=3 --output-document="$ARCHIVE_TEMP" "${MIRROR_URL}/${OPNSENSE_ARCHIVE}"
        fi

        progress "Verifying the official SHA-256 checksum..."
        printf '%s  %s\n' "$EXPECTED_SHA256" "$ARCHIVE_TEMP" | sha256sum --check --status \
            || die "OPNsense image checksum verification failed."
        success "Image checksum verified."

        progress "Extracting and storing the reusable OPNsense ISO..."
        bzip2 -dc "$ARCHIVE_TEMP" > "$ISO_TEMP"
        [[ -s "$ISO_TEMP" ]] || die "The extracted OPNsense ISO is empty."
        STORAGE_TEMP=$(mktemp "${ISO_PATH}.partial.XXXXXX")
        cp -- "$ISO_TEMP" "$STORAGE_TEMP"
        chmod 0644 "$STORAGE_TEMP"
        mv -- "$STORAGE_TEMP" "$ISO_PATH"
        STORAGE_TEMP=""
        rm -f -- "$ARCHIVE_TEMP" "$ISO_TEMP"
        ARCHIVE_TEMP=""
        ISO_TEMP=""
        success "OPNsense ISO stored: $OPNSENSE_ISO"
    fi
fi

progress "Creating OPNsense VM $VMID..."
VM_CREATE_ATTEMPTED=1
qm create "$VMID" \
    --name "$VM_NAME" \
    --ostype other \
    --machine q35 \
    --bios seabios \
    --cpu host \
    --cores "$CPU_CORES" \
    --memory "$RAM_MB" \
    --scsihw virtio-scsi-single \
    --net0 "$LAN_NET" \
    --net1 "$WAN_NET" \
    --agent enabled=1
VM_CREATED=1

qm set "$VMID" --scsi0 "${VM_STORAGE}:${DISK_GB},discard=on,iothread=1,ssd=1"
qm set "$VMID" --ide2 "${OPNSENSE_ISO},media=cdrom"
qm set "$VMID" --boot "order=ide2;scsi0"
success "OPNsense hardware and installation media configured."

progress "Starting VM $VMID..."
qm start "$VMID"
success "VM $VMID started successfully."

printf "\n%b✔ OPNsense VM %s (%s) is ready for installation.%b\n\n" \
    "$GREEN" "$VMID" "$VM_NAME" "$RESET"
cat <<EOF
Next steps:
  1. Open the VM console in Proxmox.
  2. Log in to the live installer with:
       Username: installer
       Password: opnsense
  3. Install OPNsense to the virtual disk and set a new root password.
  4. Keep or assign vtnet0 as LAN and vtnet1 as WAN.
  5. After installation, detach the ISO and boot from disk:
       qm set ${VMID} --delete ide2
       qm set ${VMID} --boot order=scsi0
  6. Install the os-qemu-guest-agent plugin from the OPNsense web interface.
EOF

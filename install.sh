#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_BASE_URL="https://raw.githubusercontent.com/abeksis/proxmox-scripts/main"

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

TEMP_SCRIPT=""
SELECTED_LABEL="installer"

success() { printf "%b✔%b %s\n" "$GREEN" "$RESET" "$*"; }
progress() { printf "%b➜%b %s\n" "$BLUE" "$RESET" "$*"; }
warning() { printf "%b⚠%b %s\n" "$YELLOW" "$RESET" "$*" >&2; }
die() { printf "%b✖ Error:%b %s\n" "$RED" "$RESET" "$*" >&2; exit 1; }

cleanup() {
    if [[ -n "$TEMP_SCRIPT" && -f "$TEMP_SCRIPT" ]]; then
        rm -f -- "$TEMP_SCRIPT"
    fi
}

on_error() {
    local exit_code=$?
    local line_number=${1:-unknown}

    printf "\n%b✖ %s failed on line %s (exit code %s).%b\n" \
        "$RED" "$SELECTED_LABEL" "$line_number" "$exit_code" "$RESET" >&2
    exit "$exit_code"
}

trap cleanup EXIT
trap 'on_error "$LINENO"' ERR

show_header() {
    clear 2>/dev/null || true
    printf "%b" "$BOLD"
    cat <<'EOF'
╔══════════════════════════════════════════════╗
║        Proxmox VM Installer                  ║
║     Choose an operating system               ║
╚══════════════════════════════════════════════╝
EOF
    printf "%b\n" "$RESET"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

show_header

(( EUID == 0 )) || die "This installer must be run as root."
require_command bash
require_command mktemp

if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
else
    die "Either curl or wget is required to download the selected installer."
fi

printf "%bAvailable installers:%b\n\n" "$BOLD" "$RESET"
printf "  1) Ubuntu 24.04 LTS\n"
printf "  2) Debian 13 Trixie\n"
printf "  3) Windows 11\n"
printf "  4) Home Assistant OS\n"
printf "  5) OPNsense\n"
printf "  q) Exit\n\n"

while true; do
    read -r -p "Select an operating system: " SELECTION
    case "${SELECTION,,}" in
        1)
            SELECTED_SCRIPT="install-ubuntu.sh"
            SELECTED_LABEL="Ubuntu 24.04 installer"
            break
            ;;
        2)
            SELECTED_SCRIPT="install-debian.sh"
            SELECTED_LABEL="Debian 13 installer"
            break
            ;;
        3)
            SELECTED_SCRIPT="install-windows11.sh"
            SELECTED_LABEL="Windows 11 installer"
            break
            ;;
        4)
            SELECTED_SCRIPT="install-home-assistant.sh"
            SELECTED_LABEL="Home Assistant OS installer"
            break
            ;;
        5)
            SELECTED_SCRIPT="install-opnsense.sh"
            SELECTED_LABEL="OPNsense installer"
            break
            ;;
        q|quit|exit)
            warning "No installer was run."
            exit 0
            ;;
        *) warning "Select 1, 2, 3, 4, 5, or q." ;;
    esac
done

TEMP_SCRIPT=$(mktemp "/tmp/proxmox-vm-installer.XXXXXX.sh")
SELECTED_URL="${SCRIPT_BASE_URL}/${SELECTED_SCRIPT}"

progress "Downloading the ${SELECTED_LABEL}..."
if [[ "$DOWNLOADER" == "curl" ]]; then
    curl -fL --retry 3 --output "$TEMP_SCRIPT" "$SELECTED_URL"
else
    wget --tries=3 --output-document="$TEMP_SCRIPT" "$SELECTED_URL"
fi

[[ -s "$TEMP_SCRIPT" ]] || die "The downloaded installer is empty."
bash -n "$TEMP_SCRIPT"
chmod 0700 "$TEMP_SCRIPT"
success "Installer downloaded and its Bash syntax verified."

printf '\n'
bash "$TEMP_SCRIPT"

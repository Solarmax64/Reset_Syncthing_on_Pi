#!/usr/bin/env bash
#
# reset-syncthing.sh - Reset and reinstall Syncthing on Debian-based systems
#
# Completely removes any existing Syncthing installation (packages, configs,
# logs, systemd overrides) and performs a clean install from the official
# Syncthing APT repository. By default the Web GUI has NO authentication;
# use --gui-user / --gui-password to secure it during setup.
#
# Supported platforms: Raspberry Pi OS, Debian 11+, Ubuntu 22.04+
#
# Usage: sudo ./reset-syncthing.sh [OPTIONS]
#        Run with --help for full usage information.
#
# Repository: https://github.com/Solarmax64/Reset_Syncthing_on_Pi
# License:    MIT
#
set -euo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_CONFIG_DIR="/etc/reset-syncthing"
readonly DEFAULT_CONFIG_FILE="${DEFAULT_CONFIG_DIR}/config.conf"

# ─── Built-in defaults ───────────────────────────────────────────────────────

PI_USER=""
SHARE_DIR=""
GUI_BIND="0.0.0.0:8384"
ST_TCP_PORT="22000"
ST_UDP_PORT="22000"
ST_DISCOVERY_PORT="21027"
GUI_USER=""
GUI_PASSWORD=""
SKIP_PURGE="false"
SKIP_INSTALL="false"
SKIP_FIREWALL="false"
SKIP_WARNING="false"
AUTO_YES="false"
DRY_RUN="false"
VERBOSE="false"
QUIET="false"
NO_COLOR="false"
NO_LOG="false"
LOG_FILE="/var/log/reset-syncthing.log"
CONFIG_FILE="${DEFAULT_CONFIG_FILE}"
INIT_CONFIG="false"

# Derived paths (computed in derive_paths)
PI_HOME=""
ST_HOME=""
ST_APT_LIST="/etc/apt/sources.list.d/syncthing.list"
ST_APT_KEYRING="/usr/share/keyrings/syncthing-archive-keyring.gpg"
DROPIN_DIR=""
DROPIN_FILE=""

# Platform info (populated by detect_platform)
OS_ID=""
OS_VERSION_CODENAME=""
PLATFORM=""

# Runtime state
USE_COLOR="true"
BACKUP_DIR=""

# ─── Logging ─────────────────────────────────────────────────────────────────

_color_reset=""
_color_red=""
_color_yellow=""
_color_cyan=""
_color_bold=""

setup_colors() {
    if [[ "${NO_COLOR}" == "true" ]] || [[ ! -t 1 ]]; then
        USE_COLOR="false"
    fi
    if [[ "${USE_COLOR}" == "true" ]]; then
        _color_reset=$'\033[0m'
        _color_red=$'\033[31m'
        _color_yellow=$'\033[33m'
        _color_cyan=$'\033[1;36m'
        _color_bold=$'\033[1m'
    fi
}

_log_to_file() {
    [[ "${NO_LOG}" == "true" ]] && return 0
    [[ -n "${LOG_FILE}" ]] && { echo "$1" >> "${LOG_FILE}" 2>/dev/null || true; }
}

log_info() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"
    _log_to_file "${msg}"
    [[ "${QUIET}" != "true" ]] && echo "${msg}" || true
}

log_warn() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*"
    _log_to_file "${msg}"
    [[ "${QUIET}" != "true" ]] && echo "${_color_yellow}${msg}${_color_reset}" || true
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*"
    _log_to_file "${msg}"
    echo "${_color_red}${msg}${_color_reset}" >&2
}

log_step() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [STEP]  $*"
    _log_to_file "${msg}"
    [[ "${QUIET}" != "true" ]] && echo "${_color_cyan}==> ${*}${_color_reset}" || true
}

log_verbose() {
    [[ "${VERBOSE}" != "true" ]] && return 0
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $*"
    _log_to_file "${msg}"
    [[ "${QUIET}" != "true" ]] && echo "${msg}" || true
}

# ─── Utility functions ───────────────────────────────────────────────────────

die() {
    log_error "$@"
    exit 1
}

# Execute a command with logging and dry-run support
run_cmd() {
    local description="$1"; shift
    log_verbose "${description}: $*"
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would execute: $*"
        return 0
    fi
    if [[ "${NO_LOG}" != "true" && -n "${LOG_FILE}" ]]; then
        if ! "$@" >> "${LOG_FILE}" 2>&1; then
            log_error "Failed: ${description}"
            log_error "Command: $*"
            return 1
        fi
    else
        if ! "$@" >/dev/null 2>&1; then
            log_error "Failed: ${description}"
            log_error "Command: $*"
            return 1
        fi
    fi
}

# Prompt for confirmation. Returns 0=proceed, 1=skip.
# Exits the script if user chooses abort.
confirm() {
    local prompt="$1"
    [[ "${AUTO_YES}" == "true" ]] && { log_verbose "Auto-confirmed: ${prompt}"; return 0; }
    [[ "${DRY_RUN}" == "true" ]] && return 0

    while true; do
        read -rp "${_color_bold}${prompt} [y/N/s(kip)] ${_color_reset}" answer
        case "${answer,,}" in
            y|yes)  return 0 ;;
            s|skip) return 1 ;;
            n|no|"")
                log_info "Aborted by user."
                exit 0
                ;;
        esac
    done
}

# Safe config file parser - no eval/source, validates each line
load_config_file() {
    local file="$1"
    [[ ! -f "${file}" ]] && return 0

    log_verbose "Loading config from ${file}"
    local line_num=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line_num=$((line_num + 1))
        # Skip blank lines and comments
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        # Strip inline comments
        line="${line%%#*}"
        # Trim whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        # Validate KEY=VALUE or KEY="VALUE"
        if [[ ! "${line}" =~ ^[A-Z_]+= ]]; then
            log_warn "Config ${file}:${line_num}: Skipping invalid line: ${line}"
            continue
        fi
        local key="${line%%=*}"
        local value="${line#*=}"
        # Strip surrounding quotes
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"

        case "${key}" in
            PI_USER)             PI_USER="${value}" ;;
            SHARE_DIR)           SHARE_DIR="${value}" ;;
            GUI_BIND)            GUI_BIND="${value}" ;;
            ST_TCP_PORT)         ST_TCP_PORT="${value}" ;;
            ST_UDP_PORT)         ST_UDP_PORT="${value}" ;;
            ST_DISCOVERY_PORT)   ST_DISCOVERY_PORT="${value}" ;;
            GUI_USER)            GUI_USER="${value}" ;;
            GUI_PASSWORD)        GUI_PASSWORD="${value}" ;;
            SKIP_PURGE)          SKIP_PURGE="${value}" ;;
            SKIP_INSTALL)        SKIP_INSTALL="${value}" ;;
            SKIP_FIREWALL)       SKIP_FIREWALL="${value}" ;;
            AUTO_YES)            AUTO_YES="${value}" ;;
            LOG_FILE)            LOG_FILE="${value}" ;;
            *)
                log_warn "Config ${file}:${line_num}: Unknown key '${key}', ignoring."
                ;;
        esac
    done < "${file}"
}

# ─── CLI Parsing ─────────────────────────────────────────────────────────────

show_help() {
    cat <<EOF
Usage: sudo ${SCRIPT_NAME} [OPTIONS]

Completely reset and reinstall Syncthing on Debian-based systems.
WARNING: This is destructive - it removes existing Syncthing configs and data.

Options:
  -h, --help              Show this help and exit
  -V, --version           Show version and exit
  -n, --dry-run           Show what would happen without making changes
  -y, --yes               Skip all confirmations (non-interactive)
  -v, --verbose           Show detailed output
  -q, --quiet             Suppress non-error output (log file still written)
  --no-color              Disable colored output

Configuration:
  -c, --config PATH       Use config file at PATH (default: ${DEFAULT_CONFIG_FILE})
  --init-config           Create default config file and exit
  -u, --user USER         Target user (default: auto-detect from SUDO_USER)
  --share-dir DIR         Syncthing shared folder path
  --gui-bind ADDR         GUI bind address (default: 0.0.0.0:8384)

Authentication:
  --gui-user NAME         Set GUI username (enables authentication)
  --gui-password PASS     Set GUI password (requires --gui-user)

Step control:
  --skip-purge            Skip package purge step
  --skip-install          Skip APT install step (use existing binary)
  --skip-firewall         Skip firewall configuration
  --skip-warning          Skip the initial destructive-action warning prompt

Logging:
  -l, --log-file PATH     Log to PATH (default: /var/log/reset-syncthing.log)
  --no-log                Disable file logging

Examples:
  sudo ./${SCRIPT_NAME}                                  # Interactive full reset
  sudo ./${SCRIPT_NAME} -y                               # Non-interactive full reset
  sudo ./${SCRIPT_NAME} --dry-run                        # Preview all actions
  sudo ./${SCRIPT_NAME} -u myuser --skip-purge           # Custom user, skip purge
  sudo ./${SCRIPT_NAME} --gui-user admin --gui-password secret  # With GUI auth
  sudo ./${SCRIPT_NAME} --init-config                    # Create config template
EOF
}

parse_args() {
    # Store CLI overrides to apply after config file loading
    local -a cli_overrides=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help; exit 0 ;;
            -V|--version)
                echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"; exit 0 ;;
            -n|--dry-run)
                DRY_RUN="true"; shift ;;
            -y|--yes)
                cli_overrides+=("AUTO_YES=true"); shift ;;
            -v|--verbose)
                VERBOSE="true"; shift ;;
            -q|--quiet)
                QUIET="true"; shift ;;
            --no-color)
                NO_COLOR="true"; shift ;;
            -c|--config)
                [[ -z "${2:-}" ]] && die "--config requires a PATH argument"
                CONFIG_FILE="$2"; shift 2 ;;
            --init-config)
                INIT_CONFIG="true"; shift ;;
            -u|--user)
                [[ -z "${2:-}" ]] && die "--user requires a USERNAME argument"
                cli_overrides+=("PI_USER=$2"); shift 2 ;;
            --share-dir)
                [[ -z "${2:-}" ]] && die "--share-dir requires a DIR argument"
                cli_overrides+=("SHARE_DIR=$2"); shift 2 ;;
            --gui-bind)
                [[ -z "${2:-}" ]] && die "--gui-bind requires an ADDR argument"
                cli_overrides+=("GUI_BIND=$2"); shift 2 ;;
            --gui-user)
                [[ -z "${2:-}" ]] && die "--gui-user requires a NAME argument"
                cli_overrides+=("GUI_USER=$2"); shift 2 ;;
            --gui-password)
                [[ -z "${2:-}" ]] && die "--gui-password requires a PASS argument"
                cli_overrides+=("GUI_PASSWORD=$2"); shift 2 ;;
            --skip-purge)
                cli_overrides+=("SKIP_PURGE=true"); shift ;;
            --skip-install)
                cli_overrides+=("SKIP_INSTALL=true"); shift ;;
            --skip-firewall)
                cli_overrides+=("SKIP_FIREWALL=true"); shift ;;
            --skip-warning)
                SKIP_WARNING="true"; shift ;;
            -l|--log-file)
                [[ -z "${2:-}" ]] && die "--log-file requires a PATH argument"
                cli_overrides+=("LOG_FILE=$2"); shift 2 ;;
            --no-log)
                NO_LOG="true"; shift ;;
            --)
                shift; break ;;
            -*)
                die "Unknown option: $1 (use --help for usage)" ;;
            *)
                die "Unexpected argument: $1 (use --help for usage)" ;;
        esac
    done

    # Load config file (if it exists), then apply CLI overrides on top
    load_config_file "${CONFIG_FILE}"

    for override in "${cli_overrides[@]+"${cli_overrides[@]}"}"; do
        local key="${override%%=*}"
        local value="${override#*=}"
        case "${key}" in
            PI_USER)        PI_USER="${value}" ;;
            SHARE_DIR)      SHARE_DIR="${value}" ;;
            GUI_BIND)       GUI_BIND="${value}" ;;
            GUI_USER)       GUI_USER="${value}" ;;
            GUI_PASSWORD)   GUI_PASSWORD="${value}" ;;
            SKIP_PURGE)     SKIP_PURGE="${value}" ;;
            SKIP_INSTALL)   SKIP_INSTALL="${value}" ;;
            SKIP_FIREWALL)  SKIP_FIREWALL="${value}" ;;
            AUTO_YES)       AUTO_YES="${value}" ;;
            LOG_FILE)       LOG_FILE="${value}" ;;
        esac
    done
}

# ─── Init config ─────────────────────────────────────────────────────────────

do_init_config() {
    # Find the example config shipped alongside this script
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    local example="${script_dir}/config.conf.example"

    if [[ ! -f "${example}" ]]; then
        die "Cannot find config.conf.example in ${script_dir}. Ensure it is alongside the script."
    fi

    if [[ -f "${DEFAULT_CONFIG_FILE}" ]]; then
        log_warn "Config file already exists at ${DEFAULT_CONFIG_FILE}"
        if ! confirm "Overwrite existing config?"; then
            log_info "Skipped. Existing config preserved."
            exit 0
        fi
    fi

    mkdir -p "${DEFAULT_CONFIG_DIR}"
    cp "${example}" "${DEFAULT_CONFIG_FILE}"
    chmod 0600 "${DEFAULT_CONFIG_FILE}"
    log_info "Config file created at ${DEFAULT_CONFIG_FILE}"
    log_info "Edit it to set your preferred defaults, then run the script normally."
    exit 0
}

# ─── Platform detection ──────────────────────────────────────────────────────

detect_platform() {
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot detect OS: /etc/os-release not found. This script requires Debian, Ubuntu, or Raspberry Pi OS."
    fi

    # shellcheck source=/dev/null
    . /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VERSION_CODENAME="${VERSION_CODENAME:-unknown}"
    local os_id_like="${ID_LIKE:-}"

    case "${OS_ID}" in
        raspbian|debian)
            PLATFORM="debian"
            ;;
        ubuntu)
            PLATFORM="ubuntu"
            ;;
        *)
            if [[ "${os_id_like}" == *debian* ]]; then
                PLATFORM="debian"
                log_warn "Unrecognized Debian derivative '${OS_ID}'. Proceeding as generic Debian."
            else
                die "Unsupported OS: ${OS_ID}. This script supports Debian, Ubuntu, and Raspberry Pi OS."
            fi
            ;;
    esac

    log_verbose "Detected platform: ${OS_ID} (${OS_VERSION_CODENAME}) -> ${PLATFORM}"

    # Warn on untested versions but don't abort
    local known_codenames="bullseye bookworm trixie jammy noble oracular"
    if [[ ! " ${known_codenames} " =~ " ${OS_VERSION_CODENAME} " ]]; then
        log_warn "Codename '${OS_VERSION_CODENAME}' has not been tested. Proceeding anyway."
    fi
}

detect_default_user() {
    # If already set by config or CLI, validate and return
    if [[ -n "${PI_USER}" ]]; then
        if ! id -u "${PI_USER}" >/dev/null 2>&1; then
            die "Specified user '${PI_USER}' does not exist."
        fi
        return 0
    fi

    # Auto-detect: prefer SUDO_USER, then check for 'pi'
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        PI_USER="${SUDO_USER}"
    elif id -u pi >/dev/null 2>&1; then
        PI_USER="pi"
    else
        die "Cannot auto-detect target user. Use --user USERNAME or set PI_USER in config."
    fi

    log_verbose "Auto-detected user: ${PI_USER}"
}

derive_paths() {
    PI_HOME="$(getent passwd "${PI_USER}" | cut -d: -f6)"
    ST_HOME="${PI_HOME}/.config/syncthing"
    DROPIN_DIR="/etc/systemd/system/syncthing@${PI_USER}.service.d"
    DROPIN_FILE="${DROPIN_DIR}/override.conf"

    # Default share dir if not set
    if [[ -z "${SHARE_DIR}" ]]; then
        SHARE_DIR="${PI_HOME}/syncthing"
    fi

    log_verbose "PI_HOME=${PI_HOME} ST_HOME=${ST_HOME} SHARE_DIR=${SHARE_DIR}"
}

# ─── Logging init ────────────────────────────────────────────────────────────

init_logging() {
    setup_colors
    if [[ "${NO_LOG}" != "true" ]]; then
        local log_dir
        log_dir="$(dirname "${LOG_FILE}")"
        mkdir -p "${log_dir}" 2>/dev/null || true
        # Rotate if log > 1MB
        if [[ -f "${LOG_FILE}" ]] && [[ "$(stat -c%s "${LOG_FILE}" 2>/dev/null || echo 0)" -gt 1048576 ]]; then
            mv "${LOG_FILE}" "${LOG_FILE}.old"
        fi
        echo "" >> "${LOG_FILE}" 2>/dev/null || {
            log_warn "Cannot write to ${LOG_FILE}. Disabling file logging."
            NO_LOG="true"
        }
        log_info "--- ${SCRIPT_NAME} v${SCRIPT_VERSION} started at $(date) ---"
    fi
}

# ─── Cleanup trap ────────────────────────────────────────────────────────────

cleanup() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 && ${exit_code} -ne 130 ]]; then
        log_error "Script failed with exit code ${exit_code}"
        [[ "${NO_LOG}" != "true" ]] && log_error "Check log file: ${LOG_FILE}"
    fi
    if [[ -n "${BACKUP_DIR:-}" && -d "${BACKUP_DIR}" ]]; then
        log_info "Backup of previous config preserved at: ${BACKUP_DIR}"
    fi
}

# ─── Step functions ──────────────────────────────────────────────────────────

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Please run as root (use sudo)."
    fi
}

check_env() {
    log_step "Checking environment"

    # Validate user
    if ! id -u "${PI_USER}" >/dev/null 2>&1; then
        die "User '${PI_USER}' not found. Use --user to specify a valid user."
    fi
    if [[ ! -d "${PI_HOME}" ]]; then
        die "Home directory ${PI_HOME} not found for user '${PI_USER}'."
    fi

    # Required commands
    local -a missing=()
    for cmd in curl systemctl apt-get; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            missing+=("${cmd}")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}"
    fi

    # Disk space check (need at least 100MB free on /)
    local avail_kb
    avail_kb="$(df / --output=avail | tail -1 | tr -d ' ')"
    if [[ "${avail_kb}" -lt 102400 ]]; then
        log_warn "Low disk space: only $((avail_kb / 1024))MB free on /. At least 100MB recommended."
        if ! confirm "Continue with low disk space?"; then
            log_info "Skipped environment check due to low disk."
        fi
    fi

    # Network check
    if ! curl -fsS --max-time 5 -o /dev/null "https://apt.syncthing.net/" 2>/dev/null; then
        log_warn "Cannot reach apt.syncthing.net. Installation may fail without network access."
    fi

    # GUI auth validation
    if [[ -n "${GUI_USER}" && -z "${GUI_PASSWORD}" ]]; then
        if [[ "${AUTO_YES}" == "true" ]]; then
            die "--gui-user requires --gui-password in non-interactive mode."
        fi
        read -rsp "Enter GUI password for user '${GUI_USER}': " GUI_PASSWORD
        echo
        if [[ -z "${GUI_PASSWORD}" ]]; then
            die "GUI password cannot be empty."
        fi
    fi
    if [[ -z "${GUI_USER}" && -n "${GUI_PASSWORD}" ]]; then
        die "--gui-password requires --gui-user."
    fi

    log_info "Environment OK: user=${PI_USER}, platform=${OS_ID} (${OS_VERSION_CODENAME})"
}

kill_everything() {
    log_info "Stopping and disabling all Syncthing services..."

    run_cmd "Stop syncthing@${PI_USER}" \
        systemctl stop "syncthing@${PI_USER}.service" || true
    run_cmd "Disable syncthing@${PI_USER}" \
        systemctl disable "syncthing@${PI_USER}.service" || true
    run_cmd "Stop syncthing.service" \
        systemctl stop syncthing.service || true
    run_cmd "Disable syncthing.service" \
        systemctl disable syncthing.service || true

    # Stop any other syncthing@*.service instances
    if [[ "${DRY_RUN}" != "true" ]]; then
        mapfile -t other_units < <(systemctl list-units --all 'syncthing@*.service' --no-legend 2>/dev/null | awk '{print $1}')
        for u in "${other_units[@]+"${other_units[@]}"}"; do
            [[ -z "${u}" ]] && continue
            run_cmd "Stop ${u}" systemctl stop "${u}" || true
            run_cmd "Disable ${u}" systemctl disable "${u}" || true
        done
    fi

    log_info "Killing any leftover syncthing processes..."
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would kill all syncthing processes"
    else
        pkill -f "/usr/bin/syncthing" >/dev/null 2>&1 || true
        sleep 1
        pkill -9 -f "/usr/bin/syncthing" >/dev/null 2>&1 || true
    fi
}

purge_previous() {
    # Backup existing config if present
    if [[ -d "${ST_HOME}" && -f "${ST_HOME}/config.xml" ]]; then
        BACKUP_DIR="/tmp/syncthing-backup-$(date +%s)"
        log_info "Backing up existing config to ${BACKUP_DIR}"
        if [[ "${DRY_RUN}" != "true" ]]; then
            mkdir -p "${BACKUP_DIR}"
            cp -a "${ST_HOME}/config.xml" "${BACKUP_DIR}/" 2>/dev/null || true
            cp -a "${ST_HOME}/cert.pem" "${BACKUP_DIR}/" 2>/dev/null || true
            cp -a "${ST_HOME}/key.pem" "${BACKUP_DIR}/" 2>/dev/null || true
        fi
    fi

    log_info "Purging Syncthing packages and APT repo..."
    run_cmd "Update apt" apt-get update -y
    run_cmd "Purge syncthing" apt-get purge -y syncthing || true
    run_cmd "Autoremove" apt-get autoremove -y

    log_info "Removing APT repo files..."
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would remove: ${ST_APT_LIST}, ${ST_APT_KEYRING}, /usr/local/bin/syncthing"
    else
        rm -f "${ST_APT_LIST}" || true
        rm -f "${ST_APT_KEYRING}" || true
        rm -f /usr/local/bin/syncthing || true
    fi

    log_info "Removing prior configs & systemd overrides..."
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would remove: ${ST_HOME}, /root/.config/syncthing, /var/lib/syncthing, ${DROPIN_DIR}"
    else
        rm -rf "${ST_HOME}" || true
        rm -rf "/root/.config/syncthing" || true
        rm -rf /var/lib/syncthing || true
        rm -rf "${DROPIN_DIR}" || true
        rm -rf "/etc/systemd/system/syncthing@.service.d" || true
        systemctl daemon-reload
    fi

    log_info "Cleaning old logs..."
    if [[ "${DRY_RUN}" != "true" ]]; then
        journalctl --rotate >/dev/null 2>&1 || true
        journalctl --vacuum-time=1s >/dev/null 2>&1 || true
    fi
}

install_latest() {
    log_info "Adding official Syncthing APT repository..."
    run_cmd "Create keyrings dir" install -d -m 0755 /usr/share/keyrings
    run_cmd "Download release key" \
        curl -fsSL https://syncthing.net/release-key.gpg -o "${ST_APT_KEYRING}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would write APT source to ${ST_APT_LIST}"
    else
        chmod 0644 "${ST_APT_KEYRING}"
        cat > "${ST_APT_LIST}" <<EOF
deb [signed-by=${ST_APT_KEYRING}] https://apt.syncthing.net/ syncthing stable
EOF
    fi

    log_info "Installing Syncthing..."
    run_cmd "Update apt" apt-get update -y
    run_cmd "Install syncthing" apt-get install -y syncthing curl ca-certificates
}

prepare_dirs() {
    log_info "Preparing share and config directories..."
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would create: ${SHARE_DIR}, ${ST_HOME}"
        return 0
    fi

    mkdir -p "${SHARE_DIR}"
    chown -R "${PI_USER}:${PI_USER}" "${SHARE_DIR}"
    chmod 0755 "${SHARE_DIR}"

    install -d -m 0700 -o "${PI_USER}" -g "${PI_USER}" "${ST_HOME}"
}

# Hash a password for Syncthing GUI auth using bcrypt
hash_gui_password() {
    local password="$1"

    # Method 1: Use syncthing's built-in hashing (v1.20+)
    if command -v syncthing >/dev/null 2>&1; then
        local hash
        hash="$(syncthing generate --gui-password="${password}" 2>/dev/null || true)"
        if [[ -n "${hash}" ]]; then
            echo "${hash}"
            return 0
        fi
    fi

    # Method 2: Use Python3 bcrypt
    if command -v python3 >/dev/null 2>&1; then
        local hash
        hash="$(python3 -c "
import bcrypt, sys
print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt()).decode())
" "${password}" 2>/dev/null || true)"
        if [[ -n "${hash}" ]]; then
            echo "${hash}"
            return 0
        fi
    fi

    # Method 3: Use htpasswd (apache2-utils)
    if command -v htpasswd >/dev/null 2>&1; then
        local hash
        hash="$(htpasswd -bnBC 10 "" "${password}" 2>/dev/null | tr -d ':' || true)"
        if [[ -n "${hash}" ]]; then
            echo "${hash}"
            return 0
        fi
    fi

    die "Cannot hash GUI password. Install python3-bcrypt or apache2-utils, or use a newer Syncthing version."
}

generate_config() {
    log_info "Generating fresh Syncthing config for ${PI_USER}..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would generate config at ${ST_HOME}"
        [[ -n "${GUI_USER}" ]] && log_info "[DRY-RUN] Would configure GUI auth for user '${GUI_USER}'"
        return 0
    fi

    # Generate keys & default config
    if ! sudo -u "${PI_USER}" syncthing generate --config="${ST_HOME}" >/dev/null 2>&1; then
        log_warn "syncthing generate returned non-zero (may be normal for existing config)"
    fi

    local config="${ST_HOME}/config.xml"
    if [[ ! -f "${config}" ]]; then
        die "${config} was not created. Check Syncthing installation and permissions on ${ST_HOME}."
    fi

    cp -a "${config}" "${config}.bak"

    # Build the <gui> block
    local gui_block
    if [[ -n "${GUI_USER}" && -n "${GUI_PASSWORD}" ]]; then
        log_info "Configuring GUI authentication for user '${GUI_USER}'..."
        local password_hash
        password_hash="$(hash_gui_password "${GUI_PASSWORD}")"
        gui_block="  <gui enabled=\"true\" tls=\"false\" debugging=\"false\">\\
    <address>${GUI_BIND}</address>\\
    <user>${GUI_USER}</user>\\
    <password>${password_hash}</password>\\
  </gui>"
    else
        gui_block="  <gui enabled=\"true\" tls=\"false\" debugging=\"false\">\\
    <address>${GUI_BIND}</address>\\
  </gui>"
    fi

    # Replace existing <gui> block with our configured one
    sed -i '/<gui[[:space:]]*[^/]*>/,/<\/gui>/d' "${config}"
    sed -i "/<\/configuration>/i ${gui_block}" "${config}"

    # Point the default folder to SHARE_DIR
    if grep -q 'folder id="default"' "${config}"; then
        sed -i -E "s#(<folder[^>]*id=\"default\"[^>]*path=\")[^\"]*(\"[^>]*>)#\1${SHARE_DIR}\2#g" "${config}"
    else
        sed -i -E "s#</configuration>#  <folder id=\"default\" label=\"Shared\" path=\"${SHARE_DIR}\" type=\"sendreceive\" rescanIntervalS=\"3600\">\\
    <filesystemType>basic</filesystemType>\\
  </folder>\\
</configuration>#g" "${config}"
    fi

    chown -R "${PI_USER}:${PI_USER}" "${ST_HOME}"
    chmod 0600 "${ST_HOME}/config.xml"
}

setup_systemd() {
    log_info "Creating systemd drop-in override..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would create ${DROPIN_FILE} and start syncthing@${PI_USER}"
        return 0
    fi

    mkdir -p "${DROPIN_DIR}"
    cat > "${DROPIN_FILE}" <<EOF
[Service]
User=${PI_USER}
Group=${PI_USER}
Environment=STGUIADDRESS=${GUI_BIND}
ExecStart=
ExecStart=/usr/bin/syncthing serve --no-browser --home=${ST_HOME} --gui-address=${GUI_BIND}
EOF

    log_info "Enabling and starting syncthing@${PI_USER}.service..."
    systemctl daemon-reload
    systemctl enable "syncthing@${PI_USER}.service"
    systemctl restart "syncthing@${PI_USER}.service"

    log_info "Waiting for Syncthing to start..."
    local attempts=0
    while [[ ${attempts} -lt 15 ]]; do
        if systemctl is-active --quiet "syncthing@${PI_USER}.service" 2>/dev/null; then
            log_info "Syncthing service is active."
            return 0
        fi
        sleep 1
        attempts=$((attempts + 1))
    done

    log_warn "Service did not become active within 15 seconds. Check 'systemctl status syncthing@${PI_USER}.service'."
}

configure_firewall() {
    if ! command -v ufw >/dev/null 2>&1; then
        log_info "ufw not installed; skipping firewall configuration."
        return 0
    fi

    log_info "Configuring ufw firewall rules..."
    local gui_port="${GUI_BIND##*:}"

    run_cmd "Allow GUI port ${gui_port}/tcp" ufw allow "${gui_port}/tcp" || log_warn "Failed to add ufw rule for ${gui_port}/tcp"
    run_cmd "Allow sync ${ST_TCP_PORT}/tcp" ufw allow "${ST_TCP_PORT}/tcp" || log_warn "Failed to add ufw rule for ${ST_TCP_PORT}/tcp"
    run_cmd "Allow sync ${ST_UDP_PORT}/udp" ufw allow "${ST_UDP_PORT}/udp" || log_warn "Failed to add ufw rule for ${ST_UDP_PORT}/udp"
    run_cmd "Allow discovery ${ST_DISCOVERY_PORT}/udp" ufw allow "${ST_DISCOVERY_PORT}/udp" || log_warn "Failed to add ufw rule for ${ST_DISCOVERY_PORT}/udp"
}

verify_and_summary() {
    log_step "Verification & Summary"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] All steps previewed successfully. No changes were made."
        return 0
    fi

    echo
    systemctl --no-pager --full status "syncthing@${PI_USER}.service" 2>/dev/null || true
    echo
    ss -tulpn 2>/dev/null | grep -E "(:${GUI_BIND##*:}\s)|(:${ST_TCP_PORT}\s)" || true

    local device_id ip_addrs
    device_id="$(sudo -u "${PI_USER}" syncthing -home="${ST_HOME}" -device-id 2>/dev/null || true)"
    ip_addrs="$(hostname -I 2>/dev/null || echo "your-IP")"
    local gui_port="${GUI_BIND##*:}"

    echo
    echo "${_color_bold}======================================================================${_color_reset}"
    echo "${_color_bold}Syncthing installation complete!${_color_reset}"
    echo
    echo "  Web UI:          http://${ip_addrs%% *}:${gui_port}"
    if [[ -n "${GUI_USER}" ]]; then
        echo "  Auth:            Enabled (user: ${GUI_USER})"
    else
        echo "  Auth:            ${_color_yellow}NONE${_color_reset} (set a password in the GUI!)"
    fi
    [[ -n "${device_id}" ]] && echo "  Device ID:       ${device_id}"
    echo "  Shared folder:   ${SHARE_DIR}"
    echo "  Service:         syncthing@${PI_USER}.service (enabled & running)"
    echo "  Config:          ${ST_HOME}/config.xml"
    [[ -n "${BACKUP_DIR:-}" ]] && echo "  Config backup:   ${BACKUP_DIR}/"
    echo
    echo "  Ports:"
    echo "   - ${gui_port}/tcp  (Web UI)"
    echo "   - ${ST_TCP_PORT}/tcp  (Sync TCP)"
    echo "   - ${ST_UDP_PORT}/udp  (Sync QUIC/UDP)"
    echo "   - ${ST_DISCOVERY_PORT}/udp  (Local discovery)"
    echo
    if [[ -z "${GUI_USER}" ]]; then
        echo "${_color_red}  SECURITY WARNING: GUI has no password set.${_color_reset}"
        echo "  Go to Actions -> Settings -> GUI to set a username/password."
    fi
    echo "${_color_bold}======================================================================${_color_reset}"
}

# ─── Step runner ─────────────────────────────────────────────────────────────

run_step() {
    local label="$1"
    local skip="$2"
    shift 2

    if [[ "${skip}" == "true" ]]; then
        log_info "Skipping: ${label} (--skip flag)"
        return 0
    fi

    log_step "${label}"

    if confirm "Proceed with: ${label}?"; then
        "$@"
    else
        log_info "User skipped: ${label}"
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    # Handle --init-config early (before root check, so help works for anyone)
    if [[ "${INIT_CONFIG}" == "true" ]]; then
        require_root
        do_init_config
    fi

    require_root
    setup_colors
    detect_platform
    detect_default_user
    derive_paths
    init_logging

    log_info "Starting Syncthing reset (v${SCRIPT_VERSION})"
    log_info "Target user: ${PI_USER}, Platform: ${OS_ID} (${OS_VERSION_CODENAME})"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "*** DRY-RUN MODE: No changes will be made ***"
    fi

    # Destructive-action warning gate
    if [[ "${SKIP_WARNING}" != "true" && "${DRY_RUN}" != "true" ]]; then
        echo
        echo "${_color_red}${_color_bold}╔══════════════════════════════════════════════════════════════════╗${_color_reset}"
        echo "${_color_red}${_color_bold}║                          WARNING                               ║${_color_reset}"
        echo "${_color_red}${_color_bold}║  This is destructive - it removes existing Syncthing configs,  ║${_color_reset}"
        echo "${_color_red}${_color_bold}║  packages, data, and logs. This action cannot be fully undone.  ║${_color_reset}"
        echo "${_color_red}${_color_bold}╚══════════════════════════════════════════════════════════════════╝${_color_reset}"
        echo
        echo "  Target user:   ${PI_USER}"
        echo "  Config dir:    ${ST_HOME}"
        echo "  Shared folder: ${SHARE_DIR}"
        echo

        if [[ "${AUTO_YES}" == "true" ]]; then
            log_verbose "Auto-confirmed: destructive warning (--yes)"
        else
            local answer
            read -rp "${_color_bold}Do you want to continue? [y/N] ${_color_reset}" answer
            if [[ "${answer,,}" != "y" && "${answer,,}" != "yes" ]]; then
                log_info "Aborted by user."
                exit 0
            fi

            read -rp "${_color_bold}Are you really sure? Type 'yes' to confirm: ${_color_reset}" answer
            if [[ "${answer,,}" != "yes" ]]; then
                log_info "Aborted by user at confirmation."
                exit 0
            fi
        fi
        echo
    fi

    check_env

    run_step "Stop all Syncthing services"     "false"              kill_everything
    run_step "Purge previous installation"      "${SKIP_PURGE}"     purge_previous
    run_step "Install latest Syncthing"         "${SKIP_INSTALL}"   install_latest
    run_step "Prepare directories"              "false"              prepare_dirs
    run_step "Generate configuration"           "false"              generate_config
    run_step "Configure systemd service"        "false"              setup_systemd
    run_step "Configure firewall"               "${SKIP_FIREWALL}"  configure_firewall

    verify_and_summary

    log_info "--- ${SCRIPT_NAME} completed successfully ---"
}

trap cleanup EXIT
trap 'log_error "Interrupted."; exit 130' INT TERM

main "$@"

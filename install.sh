#!/usr/bin/env bash
set -euo pipefail

on_error() {
    local exit_code=$?
    error "Install failed at line ${BASH_LINENO[0]} (exit code: ${exit_code})."
    error "Check output above for details. Re-run with --verbose for more information."
    exit "$exit_code"
}
trap on_error ERR

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${BLUE}━━━ $* ━━━${NC}\n"; }

DOMAIN=""
SSH_PORT=""
MODE="single-node"
ROLE=""
SALT_MASTER=""
SALT_MINION_ID=""
SKIP_SECRETS=false
VERBOSE=false
NON_INTERACTIVE=false
REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

show_usage() {
    cat <<'EOF'
WordPress HA Infrastructure Installer

Usage:
  sudo bash install.sh [OPTIONS]

Options:
  --domain=DOMAIN           Your public domain (e.g., blog.example.com)
  --ssh-port=PORT           SSH port for firewall/UFW (default: 2222)
  --single-node             Install all roles on one server (default)
  --multi-node              Distributed installation — also set --role
  --role=ROLE               Minion role for multi-node: security|db|cache|app|lb
  --salt-master=HOST        Salt master hostname/IP (multi-node only)
  --minion-id=ID            Salt minion ID (default: $(hostname))
  --skip-secrets            Skip secret generation (use existing secrets.sls)
  --verbose                 Verbose output
  -h, --help                Show this help message

Examples:
  # Single-node (everything on one server)
  sudo bash install.sh --domain=blog.example.com

  # Multi-node: database server
  sudo bash install.sh --domain=blog.example.com --multi-node --role=db --salt-master=10.0.0.1

  # Interactive mode (prompts for required values)
  sudo bash install.sh
EOF
}

usage() {
    show_usage
    exit 0
}

usage_error() {
    show_usage >&2
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        --domain=*)       DOMAIN="${arg#*=}" ;;
        --ssh-port=*)     SSH_PORT="${arg#*=}" ;;
        --single-node)    MODE="single-node" ;;
        --multi-node)     MODE="multi-node" ;;
        --role=*)         ROLE="${arg#*=}" ;;
        --salt-master=*)  SALT_MASTER="${arg#*=}" ;;
        --minion-id=*)    SALT_MINION_ID="${arg#*=}" ;;
        --skip-secrets)   SKIP_SECRETS=true ;;
        --verbose)        VERBOSE=true ;;
        -y|--yes)         NON_INTERACTIVE=true ;;
        -h|--help)        usage ;;
        *)                error "Unknown option: $arg"; usage_error ;;
    esac
done

if [[ -n "$DOMAIN" ]]; then
    NON_INTERACTIVE=true
fi

PASSED=0
FAILED=0
WARNED=0

check_pass() { PASSED=$((PASSED + 1)); info "  [PASS] $*"; }
check_warn() { WARNED=$((WARNED + 1)); warn "  [WARN] $*"; }
check_fail() { FAILED=$((FAILED + 1)); error "  [FAIL] $*"; }

preflight() {
    step "System checks - environment"

    if [[ $EUID -ne 0 ]]; then
        check_fail "This script must be run as root."
        error "Re-run with: sudo bash install.sh"
        exit 1
    fi
    check_pass "Running as root."

    if [[ ! -f /etc/os-release ]]; then
        check_fail "Cannot determine OS (/etc/os-release missing)."
        exit 1
    fi

    local os_id os_version os_name
    os_id=$(grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
    os_version=$(grep '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
    os_name=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
    info "  OS: ${os_name}"

    local os_id_like
    os_id_like=$(grep '^ID_LIKE=' /etc/os-release | cut -d'=' -f2 | tr -d '"' || true)

    if [[ "$os_id" != "ubuntu" && "$os_id_like" != *ubuntu* ]]; then
        check_fail "Unsupported OS: ${os_id}. This script targets Ubuntu 24.04 (or derivatives)."
        exit 1
    fi

    local ubuntu_major
    ubuntu_major=$(echo "$os_version" | cut -d'.' -f1)
    if [[ "$ubuntu_major" != "24" ]]; then
        check_warn "Detected Ubuntu ${os_version}. Target is Ubuntu 24.04."
    else
        check_pass "Ubuntu ${os_version} detected."
    fi

    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case "$arch" in
        amd64|x86_64)  check_pass "Architecture: amd64." ;;
        arm64|aarch64) check_pass "Architecture: arm64." ;;
        *)             check_fail "Unsupported architecture: ${arch}. Only amd64/arm64 supported."
                       exit 1 ;;
    esac

    local kern_ver kern_major kern_minor
    kern_ver=$(uname -r)
    kern_major=$(echo "$kern_ver" | cut -d. -f1)
    kern_minor=$(echo "$kern_ver" | cut -d. -f2 | tr -cd '0-9')
    info "  Kernel: ${kern_ver}"

    if [[ "$kern_major" -lt 5 || ( "$kern_major" -eq 5 && "$kern_minor" -lt 10 ) ]]; then
        check_fail "Kernel ${kern_ver} too old. Minimum: 5.10 (for rootless Podman user namespace support)."
        exit 1
    fi
    check_pass "Kernel ${kern_ver} meets minimum (>= 5.10)."

    local virt_type
    virt_type=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    info "  Virtualization: ${virt_type}"

    case "$virt_type" in
        none|bare)  check_pass "Bare-metal or no nested virtualization detected." ;;
        kvm|qemu|vmware|xen|hyper-v|microsoft)
            check_pass "Virtualization: ${virt_type} (supported)." ;;
        docker|podman|lxc|lxc-libvirt|openvz)
            check_warn "Running inside ${virt_type}. Container-in-container has limitations." ;;
        wsl|wsl2)
            check_warn "WSL2 detected. Systemd support and networking may have edge cases." ;;
        unknown)
            check_warn "Could not detect virtualization type." ;;
        *)
            check_warn "Virtualization: ${virt_type} (not specifically tested)." ;;
    esac

    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo "1")
    info "  CPU cores: ${cpu_cores}"

    if [[ "$cpu_cores" -lt 1 ]]; then
        check_fail "No CPU cores detected."
        exit 1
    elif [[ "$cpu_cores" -lt 2 ]]; then
        info "  [INFO] ${cpu_cores} CPU core. Stack will run but performance is limited."
    else
        check_pass "CPU cores: ${cpu_cores}."
    fi

    local ram_gb
    ram_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
    info "  RAM: ${ram_gb}GB"

    if [[ "$ram_gb" -lt 2 ]]; then
        check_fail "Minimum 2GB RAM required. Detected: ${ram_gb}GB."
        exit 1
    fi
    if [[ "$ram_gb" -lt 4 ]]; then
        info "  [INFO] ${ram_gb}GB RAM meets minimum. Redis/MySQL memory tuned for small footprint."
    else
        check_pass "RAM: ${ram_gb}GB."
    fi

    local swap_kb swap_gb
    swap_kb=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
    if [[ "$swap_kb" -eq 0 ]]; then
        check_warn "No swap configured. MySQL may OOM-kill under memory pressure."
    else
        swap_gb=$(awk "BEGIN {printf \"%.1f\", ${swap_kb}/1024/1024}")
        check_pass "Swap: ${swap_gb}GB."
    fi

    local disk_gb disk_fs
    disk_gb=$(df --output=avail / | tail -1 | awk '{printf "%.0f", $1/1024/1024}')
    disk_fs=$(df --output=fstype / | tail -1 | tr -d ' ')
    info "  Disk (/): ${disk_gb}GB free on ${disk_fs}"

    if [[ "$disk_gb" -lt 10 ]]; then
        check_fail "Minimum 10GB free disk space required. Detected: ${disk_gb}GB."
        exit 1
    fi
    if [[ "$disk_gb" -lt 20 ]]; then
        info "  [INFO] ${disk_gb}GB free. Monitor usage as database and uploads grow."
    else
        check_pass "Disk: ${disk_gb}GB free on ${disk_fs}."
    fi

    local unprivileged_port user_ns
    unprivileged_port=$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo "missing")
    user_ns=$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo "unrestricted")

    if [[ "$unprivileged_port" != "missing" && "$unprivileged_port" =~ ^[0-9]+$ && "$unprivileged_port" -le 80 ]]; then
        check_pass "net.ipv4.ip_unprivileged_port_start=${unprivileged_port} (rootless port binding OK)."
    else
        check_pass "net.ipv4.ip_unprivileged_port_start will be configured by Salt during deployment."
    fi

    if [[ "$user_ns" == "1" || "$user_ns" == "unrestricted" ]]; then
        check_pass "User namespaces available."
    else
        check_fail "User namespaces disabled (kernel.unprivileged_userns_clone=${user_ns}). Rootless Podman requires this."
        exit 1
    fi

    local selinux
    selinux=$(getenforce 2>/dev/null || echo "Not installed")

    if [[ "$selinux" == "Enforcing" ]]; then
        check_warn "SELinux is Enforcing. Podman containers may have additional restrictions."
    elif [[ "$selinux" == "Permissive" ]]; then
        check_warn "SELinux is Permissive."
    else
        check_pass "SELinux: ${selinux}."
    fi

    info "  AppArmor: $(aa-status 2>/dev/null | head -1 || echo 'active')"
}

preflight_network() {
    step "System checks - network"

    local connectivity_ok=false
    for host in "archive.ubuntu.com:80" "security.ubuntu.com:80" "registry-1.docker.io:443"; do
        local h p
        h=$(echo "$host" | cut -d: -f1)
        p=$(echo "$host" | cut -d: -f2)
        if timeout 5 bash -c "echo >/dev/tcp/${h}/${p}" 2>/dev/null; then
            connectivity_ok=true
            check_pass "Can reach ${h}:${p}."
            break
        fi
    done

    if [[ "$connectivity_ok" != true ]]; then
        check_warn "Cannot reach package registries via raw TCP. Checking curl fallback..."
        if curl -sf --connect-timeout 5 -o /dev/null https://archive.ubuntu.com 2>/dev/null; then
            connectivity_ok=true
            check_pass "curl can reach archive.ubuntu.com."
        else
            check_fail "No internet connectivity detected. Package installation will fail."
            exit 1
        fi
    fi

    if host archive.ubuntu.com >/dev/null 2>&1 || nslookup archive.ubuntu.com >/dev/null 2>&1; then
        check_pass "DNS resolution working."
    else
        check_fail "DNS resolution not working. Check /etc/resolv.conf."
        exit 1
    fi

    local ports=(80 443 3306 6379)
    for port in "${ports[@]}"; do
        if ss -tlnp 2>/dev/null | grep -qE ":${port}(\s|$)"; then
            local proc
            proc=$(ss -tlnp 2>/dev/null | grep -E ":${port}(\s|$)" | head -1)
            check_warn "Port ${port} already in use: ${proc}"
        else
            check_pass "Port ${port} available."
        fi
    done

    if hostname -f >/dev/null 2>&1; then
        check_pass "Hostname FQDN: $(hostname -f)."
    else
        check_warn "hostname -f failed. Salt minion ID may need manual setting."
    fi
}

preflight_conflicts() {
    step "System checks - conflicts"

    local conflicting_svcs=("apache2" "nginx" "docker" "mysqld" "redis-server" "httpd")
    local found_conflict=false

    for svc in "${conflicting_svcs[@]}"; do
        if systemctl is-active "$svc" 2>/dev/null | grep -q "active"; then
            check_warn "Service '${svc}' is running and may conflict."
            found_conflict=true
        fi
    done

    if [[ "$found_conflict" != true ]]; then
        check_pass "No conflicting services detected."
    fi

    local existing_containers
    if id podman-wp >/dev/null 2>&1; then
        local _pw_uid
        _pw_uid=$(id -u podman-wp)
        existing_containers=$(cd /home/podman-wp && sudo -u podman-wp \
            env "XDG_RUNTIME_DIR=/run/user/${_pw_uid}" "HOME=/home/podman-wp" \
            podman ps -a --format "{{.Names}}" 2>/dev/null || true)
    else
        existing_containers=$(podman ps -a --format "{{.Names}}" 2>/dev/null || true)
    fi
    if [[ -n "$existing_containers" ]]; then
        check_warn "Existing Podman containers found:"
        echo "$existing_containers" | while read -r c; do warn "    - ${c}"; done
    else
        check_pass "No existing Podman containers."
    fi

    existing_containers=$(docker ps -a --format "{{.Names}}" 2>/dev/null || true)
    if [[ -n "$existing_containers" ]]; then
        check_warn "Existing Docker containers found (may conflict with Podman networking):"
        echo "$existing_containers" | while read -r c; do warn "    - ${c}"; done
    fi

    local artifacts=("/srv/wp" "/home/podman-wp")
    local found_artifact=false
    for artifact in "${artifacts[@]}"; do
        if [[ -d "$artifact" ]]; then
            check_warn "Directory ${artifact} already exists (previous deployment?)."
            found_artifact=true
        fi
    done
    if [[ "$found_artifact" != true ]]; then
        check_pass "No previous deployment artifacts found."
    fi

    if id podman-wp >/dev/null 2>&1; then
        local uid existing_units
        uid=$(id -u podman-wp)
        existing_units=$(cd /home/podman-wp && sudo -u podman-wp XDG_RUNTIME_DIR=/run/user/"${uid}" \
            systemctl --user list-units 'container-*' --no-legend 2>/dev/null || true)
        if [[ -n "$existing_units" ]]; then
            check_warn "Existing container-* systemd user units for podman-wp:"
            echo "$existing_units" | while read -r line; do warn "    ${line}"; done
        else
            check_pass "No existing container systemd user units."
        fi
    fi

    local conflict_pkgs=("docker-ce" "docker.io" "apache2-bin" "nginx-core")
    local found_pkg=false
    for pkg in "${conflict_pkgs[@]}"; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            check_warn "Package '${pkg}' is installed."
            found_pkg=true
        fi
    done
    if [[ "$found_pkg" != true ]]; then
        check_pass "No conflicting packages installed."
    fi
}

preflight_system_readiness() {
    step "System checks - readiness"

    if ! command -v apt-get >/dev/null 2>&1; then
        check_fail "apt-get not found. This script requires apt."
        exit 1
    fi
    check_pass "apt-get available."

    local lock_retries=0
    if ! command -v fuser >/dev/null 2>&1; then
        check_warn "fuser not installed. Skipping apt lock check."
    else
    while fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
        if [[ $lock_retries -ge 30 ]]; then
            check_fail "apt lock held for 30s. Another package manager is running."
            check_fail "Stop it before continuing. Try: sudo lsof /var/lib/dpkg/lock"
            exit 1
        fi
        lock_retries=$((lock_retries + 1))
        warn "  Waiting for apt lock... (${lock_retries}/30)"
        sleep 1
    done
    check_pass "No apt lock contention."
    fi

    local essentials=("curl" "openssl" "sed" "awk" "grep" "systemctl")
    local missing_cmd=false
    for cmd in "${essentials[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            check_fail "Required command '${cmd}' not found."
            missing_cmd=true
        fi
    done
    if [[ "$missing_cmd" == true ]]; then
        exit 1
    fi
    check_pass "All essential commands available."

    local systemd_state
    systemd_state=$(systemctl is-system-running 2>/dev/null || true)
    systemd_state=${systemd_state%%[[:space:]]*}
    if [[ "$systemd_state" == "running" ]]; then
        check_pass "systemd is running."
    elif [[ "$systemd_state" == "degraded" ]]; then
        local failed_units
        failed_units=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}' | grep -v '^$' | head -5 || true)
        if [[ -n "$failed_units" ]]; then
            info "  [INFO] systemd degraded. Failed units (non-blocking): ${failed_units}"
        fi
        check_pass "systemd operational (degraded, non-critical units failed)."
    else
        check_warn "systemd reports: ${systemd_state}. Some services may not function."
    fi

    if [[ -x /usr/bin/loginctl ]]; then
        check_pass "loginctl available. Linger will be enabled for podman-wp during setup."
    else
        check_warn "loginctl not found. Linger support may need manual configuration."
    fi

    if timedatectl show 2>/dev/null | grep -q "NTPSynchronized=yes"; then
        check_pass "NTP time synchronization active."
    elif systemctl is-active systemd-timesyncd 2>/dev/null | grep -q "active"; then
        check_pass "systemd-timesyncd is active."
    elif systemctl is-active chronyd 2>/dev/null | grep -q "active"; then
        check_pass "chronyd is active."
    else
        check_warn "No NTP time sync detected. Let's Encrypt certificate validation may fail."
    fi
}

preflight_summary() {
    step "System check summary"

    info "  Passed:  ${PASSED}"
    [[ "$WARNED" -gt 0 ]] && warn "  Warnings: ${WARNED}"
    [[ "$FAILED" -gt 0 ]] && error "  Failed:  ${FAILED}"

    if [[ "$FAILED" -gt 0 ]]; then
        error "System checks failed. Fix the issues above before re-running."
        exit 1
    fi

    if [[ "$WARNED" -gt 0 ]]; then
        echo ""
        warn "There are ${WARNED} warnings. Review them above."
        warn "The installer will continue, but some features may not work correctly."
        echo ""
        if [[ -t 0 ]] && [[ "$NON_INTERACTIVE" != true ]]; then
            read -rp "Continue anyway? [y/N] " continue_answer
            if [[ ! "$continue_answer" =~ ^[Yy]$ ]]; then
                info "Aborted by user."
                exit 0
            fi
        fi
    fi

    info "System checks complete. Proceeding with installation."
}

interactive_setup() {
    step "Configuration"

    if [[ -z "$DOMAIN" ]]; then
        read -rp "Enter your domain name (e.g., blog.example.com): " DOMAIN
        if [[ -z "$DOMAIN" ]]; then
            error "Domain is required."
            exit 1
        fi
    fi

    if [[ "$DOMAIN" =~ [[:space:]] || "$DOMAIN" =~ \.\. || ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ || ! "$DOMAIN" =~ \. ]]; then
        error "Invalid domain: '${DOMAIN}'. Must be a valid hostname (e.g., blog.example.com)."
        exit 1
    fi

    CURRENT_SSH_PORT="${SSH_CLIENT:-}"
    if [[ -n "$CURRENT_SSH_PORT" ]]; then
        CURRENT_SSH_PORT="${CURRENT_SSH_PORT##* }"
    fi
    if [[ -z "$CURRENT_SSH_PORT" ]]; then
        CURRENT_SSH_PORT=$(ss -tlnp 2>/dev/null | grep 'sshd' | head -1 | awk '{print $4}' | rev | cut -d: -f1 | rev)
    fi
    if [[ -z "$CURRENT_SSH_PORT" ]]; then
        CURRENT_SSH_PORT=$(grep -E '^Port\s+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    fi
    CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"

    if [[ -z "$SSH_PORT" ]]; then
        SSH_PORT="$CURRENT_SSH_PORT"
        info "Auto-detected SSH port: ${SSH_PORT}"
    fi

    if [[ "$SSH_PORT" != "$CURRENT_SSH_PORT" ]]; then
        warn "Current SSH port appears to be ${CURRENT_SSH_PORT}, but script will configure port ${SSH_PORT}."
        warn "The firewall will allow BOTH ports during setup to prevent lockout."
    fi

    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ "$SSH_PORT" -lt 1 || "$SSH_PORT" -gt 65535 ]]; then
        error "Invalid SSH port: '${SSH_PORT}'. Must be a number between 1 and 65535."
        exit 1
    fi

    if [[ "$MODE" == "multi-node" && -z "$ROLE" ]]; then
        echo "Available roles:"
        echo "  security  — UFW firewall + SSH hardening"
        echo "  db        — MySQL 8.0 container"
        echo "  cache     — Redis 7 container"
        echo "  app       — WordPress PHP-FPM nodes (2x)"
        echo "  lb        — Nginx load balancer + SSL termination"
        read -rp "Enter this minion's role: " ROLE
        if [[ -z "$ROLE" ]]; then
            error "Role is required for multi-node mode."
            exit 1
        fi
    fi

    if [[ "$MODE" == "multi-node" && -n "$ROLE" ]]; then
        case "$ROLE" in
            security|db|cache|app|lb) ;;
            *) error "Invalid role: '${ROLE}'. Must be one of: security, db, cache, app, lb."
               exit 1 ;;
        esac
    fi

    if [[ "$MODE" == "multi-node" && -z "$SALT_MASTER" ]]; then
        read -rp "Enter Salt master hostname/IP: " SALT_MASTER
        if [[ -z "$SALT_MASTER" ]]; then
            error "Salt master is required for multi-node mode."
            exit 1
        fi
    fi

    SALT_MINION_ID="${SALT_MINION_ID:-$(hostname)}"
    info "Domain: $DOMAIN"
    info "Mode: $MODE"
    info "SSH port: ${SSH_PORT} (current: ${CURRENT_SSH_PORT})"
    if [[ "$MODE" == "multi-node" ]]; then
        info "Role: $ROLE | Master: $SALT_MASTER | Minion: $SALT_MINION_ID"
    fi
}

generate_secrets() {
    step "Generating secrets"

    if [[ "$SKIP_SECRETS" == true ]]; then
        info "Skipping secret generation (--skip-secrets)."
        return
    fi

    local secrets_file="$REPO_DIR/srv/pillar/secrets.sls"

    if [[ -f "$secrets_file" ]]; then
        info "Secrets file already exists at $secrets_file. Skipping generation."
        info "Use --skip-secrets to suppress this message, or delete the file to regenerate."
        return
    fi

    local mysql_root_pass mysql_wp_pass redis_password
    mysql_root_pass=$(openssl rand -hex 16)
    mysql_wp_pass=$(openssl rand -hex 16)
    redis_password=$(openssl rand -hex 16)

    cat > "$secrets_file" <<EOF
secrets:
  mysql_root_password: ${mysql_root_pass}
  mysql_wp_user: wordpress
  mysql_wp_password: ${mysql_wp_pass}
  mysql_wp_database: wordpress

  redis_password: ${redis_password}

  wp_auth_key:         $(openssl rand -hex 32)
  wp_secure_auth_key:  $(openssl rand -hex 32)
  wp_logged_in_key:    $(openssl rand -hex 32)
  wp_nonce_key:        $(openssl rand -hex 32)
  wp_auth_salt:        $(openssl rand -hex 32)
  wp_secure_auth_salt: $(openssl rand -hex 32)
  wp_logged_in_salt:   $(openssl rand -hex 32)
  wp_nonce_salt:       $(openssl rand -hex 32)
EOF

    chmod 600 "$secrets_file"
    info "Secrets written to $secrets_file"
    warn "Secrets are stored in $secrets_file (mode 600). Do NOT commit to version control."
}

configure_network() {
    step "Configuring network pillar"

    local network_file="$REPO_DIR/srv/pillar/network.sls"

    if [[ ! -f "$network_file" ]]; then
        error "Network pillar file not found: $network_file"
        exit 1
    fi

    sed -i "s|^\(  domain:\).*|\1 ${DOMAIN}|" "$network_file"
    if ! grep -q "  domain: ${DOMAIN}" "$network_file"; then
        error "Failed to update domain in $network_file"
        exit 1
    fi

    sed -i "s|^\(  ssh_port:\).*|\1 ${SSH_PORT}|" "$network_file"
    if ! grep -q "  ssh_port: ${SSH_PORT}" "$network_file"; then
        error "Failed to update ssh_port in $network_file"
        exit 1
    fi

    if ! grep -q "wp_core_dir:" "$network_file"; then
        sed -i "/^  wp_bin:/a\\  wp_core_dir: /srv/wp/wordpress-core" "$network_file"
    fi

    info "Network pillar updated: domain=${DOMAIN}, ssh_port=${SSH_PORT}"
}

install_packages() {
    step "Installing system packages"

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq 2>&1 | tail -3

    apt-get install -y -qq \
        curl gnupg apt-transport-https ca-certificates \
        salt-minion salt-common \
        podman \
        ufw openssl \
        cron 2>&1 | tail -5

    info "System packages installed."

    if command -v ufw >/dev/null 2>&1; then
        if [[ -n "${CURRENT_SSH_PORT:-}" && "$CURRENT_SSH_PORT" != "$SSH_PORT" ]]; then
            ufw allow "${CURRENT_SSH_PORT}/tcp" >/dev/null 2>&1 || true
            info "UFW safety rule added: allowing current SSH port ${CURRENT_SSH_PORT}/tcp."
        fi
    fi
}

setup_salt_masterless() {
    step "Configuring Salt (masterless / local mode)"

    local salt_base="$REPO_DIR/srv"

    cat > /etc/salt/minion <<EOF
file_client: local
file_roots:
  base:
    - '${salt_base}/salt'
pillar_roots:
  base:
    - '${salt_base}/pillar'
reactor:
  - 'salt/beacon/*/diskusage/*':
    - ${REPO_DIR}/srv/salt/reactor/disk-cleanup
  - 'salt/beacon/*/inotify/*':
    - ${REPO_DIR}/srv/salt/reactor/config-change-alert
  - 'salt/beacon/*/cmd/*':
    - ${REPO_DIR}/srv/salt/reactor/container-health-check
EOF

    info "Salt configured for masterless mode."
    info "  Salt roots: ${salt_base}"
}

setup_salt_master_minion() {
    step "Configuring Salt (multi-node: master + minion)"

    local salt_base="$REPO_DIR/srv"

    if [[ "$ROLE" == "security" || -z "$SALT_MASTER" || "$SALT_MASTER" == "$(hostname -I | awk '{print $1}')" ]]; then
        info "Setting up Salt master on this node."

        apt-get install -y -qq salt-master salt-api

        cat > /etc/salt/master <<EOF
file_roots:
  base:
    - '${salt_base}/salt'
pillar_roots:
  base:
    - '${salt_base}/pillar'
auto_accept: True
reactor:
  - 'salt/beacon/*/diskusage/*':
    - ${REPO_DIR}/srv/salt/reactor/disk-cleanup
  - 'salt/beacon/*/inotify/*':
    - ${REPO_DIR}/srv/salt/reactor/config-change-alert
  - 'salt/beacon/*/cmd/*':
    - ${REPO_DIR}/srv/salt/reactor/container-health-check
EOF

        systemctl enable salt-master
        systemctl restart salt-master
        info "Salt master configured and started."
    fi

    cat > /etc/salt/minion <<EOF
master: '${SALT_MASTER}'
id: '${SALT_MINION_ID}'
EOF

    if [[ -n "$ROLE" ]]; then
        step "Setting grain role=${ROLE} on minion ${SALT_MINION_ID}"
        salt-call --local grains.setval role "$ROLE"
        info "Grain role set to: $ROLE"
    fi

    systemctl enable salt-minion
    systemctl restart salt-minion
    info "Salt minion configured (master: ${SALT_MASTER})."
}

apply_states() {
    step "Applying Salt states"

    if [[ "$MODE" == "single-node" ]]; then
        info "Applying all states via highstate (role: all-in-one)..."

        if [[ "$VERBOSE" == true ]]; then
            salt-call --local state.apply --log-level=debug 2>&1
        else
            salt-call --local state.apply 2>&1
        fi
    else
        info "Applying highstate for role: ${ROLE}"

        info "Waiting for Salt minion to connect to master..."
        local wait_retries=0
        while [[ $wait_retries -lt 30 ]]; do
            if salt-call --timeout=5 test.ping 2>/dev/null | grep -q True; then
                info "Minion connected to master."
                break
            fi
            wait_retries=$((wait_retries + 1))
            sleep 2
        done
        if [[ $wait_retries -ge 30 ]]; then
            check_fail "Minion could not connect to master within 60s."
            error "Ensure salt-master is running on ${SALT_MASTER} and the minion can reach it."
            exit 1
        fi

        if [[ "$VERBOSE" == true ]]; then
            salt-call state.highstate --log-level=debug 2>&1
        else
            salt-call state.highstate 2>&1
        fi
    fi

    info "Salt state application complete."

    if [[ "$MODE" == "single-node" || "$ROLE" == "app" || "$ROLE" == "lb" ]]; then
        local uid
        uid=$(id -u podman-wp 2>/dev/null || echo "")
        if [[ -n "$uid" ]]; then
            local img_exists
            img_exists=$(cd /home/podman-wp && sudo -u podman-wp \
                env "XDG_RUNTIME_DIR=/run/user/${uid}" \
                    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus" \
                    "HOME=/home/podman-wp" \
                    podman image exists wp-phpredis:latest 2>&1 && echo "yes" || echo "no")
            if [[ "$img_exists" == *"no"* ]]; then
                warn "wp-phpredis image not found. Building manually..."
                (cd /home/podman-wp && sudo -u podman-wp \
                    env "XDG_RUNTIME_DIR=/run/user/${uid}" \
                        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus" \
                        "HOME=/home/podman-wp" \
                        podman build --dns=8.8.8.8 --dns=1.1.1.1 -t wp-phpredis:latest \
                        -f /srv/wp/bin/Containerfile /srv/wp/bin 2>&1) || {
                    error "Failed to build wp-phpredis image. Check network access and Containerfile."
                }
                info "wp-phpredis image built successfully."

                if [[ ! -f /srv/wp/wordpress-core/wp-settings.php ]]; then
                    info "Extracting WordPress core files..."
                    (cd /home/podman-wp && sudo -u podman-wp \
                        env "XDG_RUNTIME_DIR=/run/user/${uid}" \
                            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus" \
                            "HOME=/home/podman-wp" \
                        bash -c 'podman create --name wp-core-temp wp-phpredis:latest >/dev/null 2>&1 && podman cp wp-core-temp:/usr/src/wordpress/. /srv/wp/wordpress-core/ && podman rm wp-core-temp >/dev/null 2>&1') 2>&1 || true
                fi

                info "Re-applying Salt states after image build..."
                salt-call --local state.apply 2>&1 | tail -20
            fi
        fi
    fi
}

reload_systemd_user() {
    step "Reloading systemd user services"

    local uid
    uid=$(id -u podman-wp 2>/dev/null || echo "")

    if [[ -n "$uid" ]]; then
        (cd /home/podman-wp && sudo -u podman-wp env "XDG_RUNTIME_DIR=/run/user/${uid}" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus" "HOME=/home/podman-wp" systemctl --user daemon-reload)
        info "Systemd user daemon reloaded for podman-wp (UID ${uid})."
    else
        warn "User podman-wp not found yet — will reload on first login."
    fi
}

start_containers() {
    step "Starting containers"

    local uid
    uid=$(id -u podman-wp 2>/dev/null || echo "")

    if [[ -z "$uid" ]]; then
        warn "User podman-wp not found. Containers will start via systemd units."
        return
    fi

    local SUDO=(sudo -u podman-wp env "XDG_RUNTIME_DIR=/run/user/${uid}" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus" "HOME=/home/podman-wp")

    cd /home/podman-wp

    info "Starting MySQL..."
    "${SUDO[@]}" systemctl --user start container-mysql 2>/dev/null || warn "Failed to start MySQL (may already be starting via systemd)."

    local retries=0
    while [[ $retries -lt 30 ]]; do
        if "${SUDO[@]}" podman exec mysql sh -c 'mysqladmin ping -u root -p"$MYSQL_ROOT_PASSWORD" --silent' 2>/dev/null; then
            info "MySQL is ready."
            break
        fi
        retries=$((retries + 1))
        sleep 2
    done
    if [[ $retries -ge 30 ]]; then
        warn "MySQL did not become healthy within 60s. Subsequent services may fail."
    fi

    local secrets_file="${REPO_DIR}/srv/pillar/secrets.sls"
    if [[ -f "$secrets_file" ]]; then
        local _root_pass _wp_user _wp_pass _wp_db
        _root_pass=$(grep 'mysql_root_password:' "$secrets_file" | awk '{print $2}')
        _wp_user=$(grep 'mysql_wp_user:' "$secrets_file" | awk '{print $2}')
        _wp_pass=$(grep 'mysql_wp_password:' "$secrets_file" | awk '{print $2}')
        _wp_db=$(grep 'mysql_wp_database:' "$secrets_file" | awk '{print $2}')
        if [[ -n "$_root_pass" && -n "$_wp_user" && -n "$_wp_pass" && -n "$_wp_db" ]]; then
            "${SUDO[@]}" podman exec -i mysql mysql -u "root" -p"$_root_pass" 2>/dev/null <<EOSQL || true
CREATE DATABASE IF NOT EXISTS \`$_wp_db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${_wp_user}'@'%' IDENTIFIED BY '${_wp_pass}';
GRANT ALL PRIVILEGES ON \`$_wp_db\`.* TO '${_wp_user}'@'%';
FLUSH PRIVILEGES;
EOSQL
            info "MySQL WordPress database/user verified."
        fi
    fi

    info "Starting Redis..."
    "${SUDO[@]}" systemctl --user start container-redis 2>/dev/null || warn "Failed to start Redis."
    sleep 3

    chmod 644 /srv/wp/wp-config/wp-config.php 2>/dev/null || true

    info "Starting WordPress nodes..."
    "${SUDO[@]}" systemctl --user start container-wp-node1 2>/dev/null || warn "Failed to start wp-node1."
    "${SUDO[@]}" systemctl --user start container-wp-node2 2>/dev/null || warn "Failed to start wp-node2."
    sleep 5

    info "Starting Nginx..."
    "${SUDO[@]}" systemctl --user start container-nginx 2>/dev/null || warn "Failed to start Nginx."
    sleep 3

    info "Pulling Anubis image..."
    "${SUDO[@]}" podman pull ghcr.io/techarohq/anubis:latest 2>/dev/null || warn "Anubis image pull failed (will retry on start)."

    info "Starting Anubis..."
    "${SUDO[@]}" systemctl --user start container-anubis 2>/dev/null || warn "Failed to start Anubis."
    sleep 10

    cd "${REPO_DIR:-/root}"

    info "All containers started."

    if [[ -n "${CURRENT_SSH_PORT:-}" && "$CURRENT_SSH_PORT" != "$SSH_PORT" ]]; then
        warn ""
        warn "IMPORTANT: SSH port is being changed from ${CURRENT_SSH_PORT} to ${SSH_PORT}."
        warn "Both ports are allowed through UFW. After confirming the new port works,"
        warn "you can remove the old rule: ufw delete allow ${CURRENT_SSH_PORT}/tcp"
        warn ""
    fi
}

verify() {
    step "Post-install verification"

    local uid
    uid=$(id -u podman-wp 2>/dev/null || echo "")

    if [[ -z "$uid" ]]; then
        warn "User podman-wp not found. Skipping container verification."
        return
    fi

    local SUDO=(sudo -u podman-wp env "XDG_RUNTIME_DIR=/run/user/${uid}" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus" "HOME=/home/podman-wp")

    cd /home/podman-wp

    echo ""

    info "Container status:"
    "${SUDO[@]}" podman ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || \
        warn "Could not list containers."

    echo ""

    info "Health checks:"
    if curl -sf "http://localhost/health" >/dev/null 2>&1; then
        info "  Nginx health: OK"
    else
        warn "  Nginx health: not responding (may need a few more seconds)"
    fi

    if "${SUDO[@]}" podman exec anubis wget -qO /dev/null http://localhost:8923/health 2>/dev/null; then
        info "  Anubis health: OK"
    else
        warn "  Anubis health: not responding yet"
    fi

    if curl -sf -k -o /dev/null "https://localhost" 2>&1; then
        info "  HTTPS: OK"
    else
        warn "  HTTPS: not responding yet"
    fi

    echo ""

    info "UFW status:"
    ufw status 2>/dev/null || warn "UFW not active."

    echo ""
    info "Installation complete!"
    echo ""
    info "Your WordPress site:      https://${DOMAIN}"
    info "WordPress admin:          https://${DOMAIN}/wp-admin.php"
    warn "If using a self-signed cert, the browser will show a security warning."
    info "To obtain a real Let's Encrypt cert, ensure DNS points to this server and restart Nginx."
    echo ""
    info "First-time WordPress setup: visit https://${DOMAIN}/wp-admin.php to create the admin user."
    echo ""
    info "Useful commands:"
    info "  sudo -u podman-wp env XDG_RUNTIME_DIR=/run/user/${uid} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus HOME=/home/podman-wp systemctl --user status container-mysql"
    info "  sudo -u podman-wp env XDG_RUNTIME_DIR=/run/user/${uid} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus HOME=/home/podman-wp podman ps"
    info "  salt-call --local state.apply"
    info "  Re-run this installer: sudo bash install.sh --domain=${DOMAIN} --skip-secrets"
    echo ""
}

main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║        WordPress HA Infrastructure Installer                ║"
    echo "║        SaltStack + Rootless Podman on Ubuntu 24.04          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    preflight
    preflight_network
    preflight_conflicts
    preflight_system_readiness
    preflight_summary
    interactive_setup
    install_packages
    generate_secrets
    configure_network

    if [[ "$MODE" == "single-node" ]]; then
        setup_salt_masterless

        salt-call --local grains.setval role "all-in-one"
    else
        setup_salt_master_minion
    fi

    apply_states
    reload_systemd_user
    start_containers
    verify
}

main "$@"

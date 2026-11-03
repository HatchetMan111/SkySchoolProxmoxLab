#!/usr/bin/env bash
# =============================================================================
#  SkyLab Installer for Proxmox VE
#  ---------------------------------------------------------------------------
#  Creates a Debian LXC container on a Proxmox VE host, installs Docker and
#  deploys SkyLab (https://github.com/SkyLab-tw/SkyLab) with Docker Compose.
#
#  Usage (on the Proxmox VE host, as root):
#      bash skylab-install.sh
#      bash skylab-install.sh --ip 10.0.0.50/24 --gw 10.0.0.1
#
#  License: MIT (this installer). SkyLab itself is AGPL-3.0.
# =============================================================================
set -Eeuo pipefail

APP="SkyLab"
APP_VERSION="1.0.0"
REPO_URL="https://github.com/SkyLab-tw/SkyLab.git"
DEFAULT_HOSTNAME="skylab"

# ---------------------------------------------------------------------------
# Colours / helpers
# ---------------------------------------------------------------------------
CL="\033[0m"
BL="\033[36m"
GN="\033[1;92m"
RD="\033[01;31m"
YW="\033[33m"
BOLD="\033[1m"

msg_info() { printf " ${BL}>>${CL} %s" "$1"; }
msg_ok() { printf " ${GN}OK${CL}\n"; }
msg_warn() { printf " ${YW}!!${CL} %s\n" "$1"; }
msg_error() { printf " ${RD}XX${CL} %s\n" "$1" >&2; }

die() {
  msg_error "$1"
  exit 1
}

header_info() {
  printf '\n\033[1;36m  %s Installer %s\033[0m\n' "${APP}" "${APP_VERSION}"
  printf '  Self-hosted campus cloud on Proxmox VE\n\n'
}

usage() {
  cat <<EOF
${BOLD}${APP} installer ${APP_VERSION}${CL}

Creates a Debian LXC on this Proxmox VE host and installs ${APP} in it.

Usage: bash $0 [options]

Options:
  --ctid <id>              Container ID (default: next free ID)
  --hostname <name>        Container hostname (default: ${DEFAULT_HOSTNAME})
  --ip <dhcp|CIDR>         Network config (default: dhcp), e.g. 10.0.0.50/24
  --gw <ip>                Gateway for a static IP
  --bridge <bridge>        Network bridge (default: vmbr0)
  --dns <ip>               DNS server for the container (default: 1.1.1.1)
  --storage <storage>      Storage for the root filesystem (default: auto)
  --disk <gb>              Disk size in GB (default: 20)
  --cores <n>              CPU cores (default: 2)
  --memory <mb>            RAM in MB (default: 4096)
  --swap <mb>              Swap in MB (default: 512)
  --port <port>            SkyLab web port (default: 8082)
  --admin-email <email>    Bootstrap admin e-mail (default: admin@example.com)
  --admin-password <pw>    Bootstrap admin password (default: generated)
  --root-password <pw>     Container root password (default: generated)
  --privileged             Create a privileged container (default: unprivileged)
  -h, --help               Show this help

Examples:
  bash $0
  bash $0 --ip 10.0.0.50/24 --gw 10.0.0.1 --disk 40 --memory 8192
EOF
}

# ---------------------------------------------------------------------------
# Defaults / arguments
# ---------------------------------------------------------------------------
CTID=""
CT_HOSTNAME="${DEFAULT_HOSTNAME}"
IP="dhcp"
GATEWAY=""
BRIDGE="vmbr0"
DNS="1.1.1.1"
STORAGE=""
DISK="20"
CORES="2"
MEMORY="4096"
SWAP="512"
NGINX_PORT="8082"
ADMIN_EMAIL="admin@example.com"
ADMIN_PASSWORD=""
ROOT_PASSWORD=""
UNPRIVILEGED="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)             CTID="${2:?missing value}"; shift 2 ;;
    --hostname)         CT_HOSTNAME="${2:?missing value}"; shift 2 ;;
    --ip)               IP="${2:?missing value}"; shift 2 ;;
    --gw)               GATEWAY="${2:?missing value}"; shift 2 ;;
    --bridge)           BRIDGE="${2:?missing value}"; shift 2 ;;
    --dns)              DNS="${2:?missing value}"; shift 2 ;;
    --storage)          STORAGE="${2:?missing value}"; shift 2 ;;
    --disk)             DISK="${2:?missing value}"; shift 2 ;;
    --cores)            CORES="${2:?missing value}"; shift 2 ;;
    --memory)           MEMORY="${2:?missing value}"; shift 2 ;;
    --swap)             SWAP="${2:?missing value}"; shift 2 ;;
    --port)             NGINX_PORT="${2:?missing value}"; shift 2 ;;
    --admin-email)      ADMIN_EMAIL="${2:?missing value}"; shift 2 ;;
    --admin-password)   ADMIN_PASSWORD="${2:?missing value}"; shift 2 ;;
    --root-password)    ROOT_PASSWORD="${2:?missing value}"; shift 2 ;;
    --privileged)       UNPRIVILEGED="0"; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                  die "Unknown option: $1 (see --help)" ;;
  esac
done

on_error() {
  local rc=$?
  if [[ -n "${CTID:-}" ]] && pct status "${CTID}" >/dev/null 2>&1; then
    msg_error "Installation failed (exit ${rc}). Container ${CTID} was kept for debugging: pct enter ${CTID}"
  else
    msg_error "Installation failed (exit ${rc})."
  fi
  exit "${rc}"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
header_info
[[ "${EUID}" -eq 0 ]] || die "This script must run as root on the Proxmox VE host."

for cmd in pct pveam pvesm pvesh pveversion; do
  command -v "${cmd}" >/dev/null 2>&1 || die "'${cmd}' not found. Run this on a Proxmox VE host."
done

PVE_MAJOR="$(pveversion 2>/dev/null | awk -F'[ /]' '{print $2}' | cut -d. -f1)"
[[ "${PVE_MAJOR:-0}" =~ ^[0-9]+$ ]] || die "Could not determine the Proxmox VE version."
(( PVE_MAJOR >= 8 )) || die "Proxmox VE 8 or newer is required (found ${PVE_MAJOR})."

[[ "${IP}" == "dhcp" || "${IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] \
  || die "Invalid --ip value '${IP}'. Use 'dhcp' or CIDR notation like 10.0.0.50/24."
if [[ "${IP}" != "dhcp" && -z "${GATEWAY}" ]]; then
  die "--gw is required with a static --ip."
fi
[[ "${NGINX_PORT}" =~ ^[0-9]+$ ]] || die "Invalid --port value '${NGINX_PORT}'."
(( NGINX_PORT >= 1 && NGINX_PORT <= 65535 )) || die "--port must be between 1 and 65535."
for value in "${DISK}" "${CORES}" "${MEMORY}" "${SWAP}"; do
  [[ "${value}" =~ ^[0-9]+$ ]] || die "Disk, cores, memory and swap must be numbers."
done

[[ "${ADMIN_EMAIL}" == *@*.* ]] || die "Invalid --admin-email '${ADMIN_EMAIL}'."
if [[ -n "${ADMIN_PASSWORD}" ]]; then
  (( ${#ADMIN_PASSWORD} >= 8 && ${#ADMIN_PASSWORD} <= 128 )) \
    || die "--admin-password must be 8 to 128 characters long."
  [[ "${ADMIN_PASSWORD}" == *[A-Z]* && "${ADMIN_PASSWORD}" == *[a-z]* \
     && "${ADMIN_PASSWORD}" == *[0-9]* && "${ADMIN_PASSWORD}" == *[^A-Za-z0-9]* ]] \
    || die "--admin-password must contain upper case, lower case, a digit and a symbol."
fi

if ! ip link show "${BRIDGE}" >/dev/null 2>&1; then
  msg_warn "Bridge '${BRIDGE}' was not found on this host. Continuing anyway."
fi

# ---------------------------------------------------------------------------
# Storage / template
# ---------------------------------------------------------------------------
pick_storage() {
  local content="$1" preferred="$2"
  if [[ -n "${preferred}" ]] && pvesm status --content "${content}" 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "${preferred}"; then
    printf '%s' "${preferred}"
    return 0
  fi
  pvesm status --content "${content}" 2>/dev/null | awk 'NR>1{print $1}' | head -n1
}

TEMPLATE_STORAGE="$(pick_storage vztmpl local)"
[[ -n "${TEMPLATE_STORAGE}" ]] || die "No storage with 'vztmpl' content found. Enable it under Datacenter > Storage."

ROOTFS_STORAGE="$(pick_storage rootdir "${STORAGE:-local-lvm}")"
[[ -n "${ROOTFS_STORAGE}" ]] || die "No storage with 'rootdir' content found. Enable it under Datacenter > Storage."

msg_info "Refreshing appliance list"
pveam update >/dev/null 2>&1 || true
msg_ok

template_list() {
  pveam available --section system 2>/dev/null \
    | awk '{print $2}' \
    | grep -E "^debian-${1}-standard_.*_amd64\.tar\.zst$" \
    | sort -V || true
}

TEMPLATE="$(template_list 13 | tail -n1)"
if [[ -z "${TEMPLATE}" ]]; then
  TEMPLATE="$(template_list 12 | tail -n1)"
fi
[[ -n "${TEMPLATE}" ]] || die "No Debian 13 or 12 template available. Check 'pveam update' and your template storage."

if ! pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | grep -Fq "${TEMPLATE}"; then
  msg_info "Downloading ${TEMPLATE}"
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}" || die "Template download failed."
  msg_ok
fi
OSTEMPLATE="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"

# ---------------------------------------------------------------------------
# Container ID / name checks
# ---------------------------------------------------------------------------
if [[ -z "${CTID}" ]]; then
  CTID="$(pvesh get /cluster/nextid 2>/dev/null | tr -dc '0-9' || true)"
  [[ -n "${CTID}" ]] || die "Could not determine the next free container ID. Use --ctid."
fi

if pct status "${CTID}" >/dev/null 2>&1; then
  die "Container ID ${CTID} already exists."
fi

if pct list | awk 'NR>1{print $NF}' | grep -qx "${CT_HOSTNAME}"; then
  die "A container named '${CT_HOSTNAME}' already exists. Use --hostname."
fi

# ---------------------------------------------------------------------------
# Passwords
# ---------------------------------------------------------------------------
gen_pw() { openssl rand -hex "${1:-12}"; }
[[ -n "${ROOT_PASSWORD}" ]] || ROOT_PASSWORD="$(gen_pw 12)"

# ---------------------------------------------------------------------------
# Create container
# ---------------------------------------------------------------------------
FEATURES="nesting=1,keyctl=1,fuse=1"
if [[ "${IP}" == "dhcp" ]]; then
  NET0="name=eth0,bridge=${BRIDGE},ip=dhcp,type=veth"
else
  NET0="name=eth0,bridge=${BRIDGE},ip=${IP},type=veth"
  [[ -n "${GATEWAY}" ]] && NET0="${NET0},gw=${GATEWAY}"
fi

msg_info "Creating container ${CTID} (${CT_HOSTNAME})"
pct create "${CTID}" "${OSTEMPLATE}" \
  --hostname "${CT_HOSTNAME}" \
  --cores "${CORES}" \
  --memory "${MEMORY}" \
  --swap "${SWAP}" \
  --rootfs "${ROOTFS_STORAGE}:${DISK}" \
  --net0 "${NET0}" \
  --nameserver "${DNS}" \
  --ostype debian \
  --arch amd64 \
  --unprivileged "${UNPRIVILEGED}" \
  --features "${FEATURES}" \
  --onboot 1 \
  --password "${ROOT_PASSWORD}" \
  --description "SkyLab campus cloud - installed by skylab-install.sh ${APP_VERSION}" \
  >/dev/null
msg_ok

msg_info "Starting container"
pct start "${CTID}" >/dev/null || die "Could not start container ${CTID}."
msg_ok

# ---------------------------------------------------------------------------
# Wait for network
# ---------------------------------------------------------------------------
msg_info "Waiting for the container network"
NET_OK="0"
for _ in $(seq 1 60); do
  if pct exec "${CTID}" -- bash -c 'getent hosts deb.debian.org >/dev/null 2>&1' >/dev/null 2>&1; then
    NET_OK="1"
    break
  fi
  sleep 2
done
if [[ "${NET_OK}" != "1" ]]; then
  msg_error "No network/DNS inside the container. Keep it with 'pct enter ${CTID}' for debugging, or remove it with 'pct destroy ${CTID}'."
  exit 1
fi
msg_ok

# ---------------------------------------------------------------------------
# Provisioning script (runs inside the container)
# ---------------------------------------------------------------------------
PROV_TMP="$(mktemp /tmp/skylab-provision.XXXXXX.sh)"
cleanup() { rm -f "${PROV_TMP}"; }
trap cleanup EXIT
trap on_error ERR

cat > "${PROV_TMP}" <<'PROVISION_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

ADMIN_EMAIL="${1:-admin@example.com}"
ADMIN_PASSWORD="${2:-}"
NGINX_PORT="${3:-8082}"
ROOT_PASSWORD="${4:-}"
REPO_URL="${5:-https://github.com/SkyLab-tw/SkyLab.git}"

log() { printf '\033[36m[skyLab]\033[0m %s\n' "$*"; }

apt_get() {
  apt-get -y -qq \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$@"
}

log "Updating base system"
apt-get update -qq
apt_get upgrade
apt_get install curl ca-certificates gnupg git openssl jq

log "Installing Docker"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

for _ in $(seq 1 15); do
  docker info >/dev/null 2>&1 && break
  sleep 2
done

if ! docker info >/dev/null 2>&1; then
  log "Docker needs the vfs storage driver in this container; applying it"
  mkdir -p /etc/docker
  printf '{\n  "storage-driver": "vfs"\n}\n' > /etc/docker/daemon.json
  systemctl restart docker
  sleep 5
  docker info >/dev/null 2>&1 || { log "Docker could not be started"; exit 1; }
fi

log "Fetching SkyLab"
if [[ -d /opt/skylab/.git ]]; then
  git -C /opt/skylab pull --ff-only || log "Warning: could not update the existing checkout"
else
  rm -rf /opt/skylab
  git clone --depth 1 "${REPO_URL}" /opt/skylab
fi
cd /opt/skylab

cp -n .env.example .env
cp -n vllm-service/litellm/.env.example vllm-service/litellm/.env

set_env() {
  local key="$1" value="$2" file="${3:-.env}" escaped
  escaped="$(printf '%s' "${value}" | sed -e 's/[\\&|]/\\&/g')"
  if grep -q "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

CT_IP="$(hostname -I 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i !~ /:/) {print $i; exit}}')"
[[ -n "${CT_IP}" ]] || CT_IP="127.0.0.1"

read_env() {
  grep -E "^${1}=" "${2:-.env}" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

EXISTING_SECRET="$(read_env SECRET_KEY)"
if [[ -z "${EXISTING_SECRET}" || "${EXISTING_SECRET}" == "changethis" ]]; then
  set_env SECRET_KEY "$(openssl rand -hex 32)"
fi

EXISTING_DB_PASSWORD="$(read_env POSTGRES_PASSWORD)"
if [[ -z "${EXISTING_DB_PASSWORD}" || "${EXISTING_DB_PASSWORD}" == "changethis" ]]; then
  set_env POSTGRES_PASSWORD "$(openssl rand -hex 16)"
fi

if [[ -z "${ADMIN_PASSWORD}" ]]; then
  EXISTING_ADMIN_PASSWORD="$(read_env FIRST_SUPERUSER_PASSWORD)"
  if [[ -n "${EXISTING_ADMIN_PASSWORD}" && "${EXISTING_ADMIN_PASSWORD}" != "changethis" ]]; then
    ADMIN_PASSWORD="${EXISTING_ADMIN_PASSWORD}"
  else
    ADMIN_PASSWORD="Sk$(openssl rand -hex 10)9"
    ADMIN_PASSWORD="${ADMIN_PASSWORD}!"
  fi
fi

FRONTEND_HOST="http://${CT_IP}:${NGINX_PORT}"

log "Writing configuration"
set_env FIRST_SUPERUSER "${ADMIN_EMAIL}"
set_env FIRST_SUPERUSER_PASSWORD "${ADMIN_PASSWORD}"
set_env ENVIRONMENT "production"
set_env ENABLE_SIGNUP "false"
set_env FRONTEND_HOST "${FRONTEND_HOST}"
set_env NGINX_HOST_PORT "${NGINX_PORT}"
set_env BACKEND_CORS_ORIGINS ""
set_env LOG_JSON "true"

log "Building and starting SkyLab (this can take 5-15 minutes)"
docker compose up -d --build --scale litellm=0

log "Waiting for the backend health check"
READY="0"
for _ in $(seq 1 180); do
  if curl -fsS "http://127.0.0.1:${NGINX_PORT}/api/v1/utils/health-check/ready" >/dev/null 2>&1; then
    READY="1"
    break
  fi
  sleep 5
done

if [[ "${READY}" != "1" ]]; then
  log "Backend did not become ready. Recent logs:"
  docker compose ps || true
  docker compose logs --tail=80 backend || true
  exit 1
fi

cat > /root/skylab.creds <<CREDS
SkyLab URL:     ${FRONTEND_HOST}
Setup wizard:   ${FRONTEND_HOST}/setup
Admin e-mail:   ${ADMIN_EMAIL}
Admin password: ${ADMIN_PASSWORD}
Root password:  ${ROOT_PASSWORD}
Web port:       ${NGINX_PORT}
Created:        $(date -Is)
CREDS
chmod 600 /root/skylab.creds

cat > /usr/local/bin/skylab-update <<'UPD'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/skylab
git pull --ff-only
docker compose up -d --build --scale litellm=0
UPD
chmod +x /usr/local/bin/skylab-update

log "SkyLab is ready at ${FRONTEND_HOST}"
PROVISION_EOF

msg_info "Installing SkyLab inside the container"
printf '\n'
pct push "${CTID}" "${PROV_TMP}" /root/skylab-provision.sh --perms 700 >/dev/null
pct exec "${CTID}" -- bash /root/skylab-provision.sh \
  "${ADMIN_EMAIL}" "${ADMIN_PASSWORD}" "${NGINX_PORT}" "${ROOT_PASSWORD}" "${REPO_URL}"
msg_ok

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
CT_IP="$(pct exec "${CTID}" -- hostname -I 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i !~ /:/) {print $i; exit}}' || true)"
[[ -n "${CT_IP}" ]] || CT_IP="<container-ip>"

CREDS_HOST="/root/skylab-${CTID}.creds"
if pct exec "${CTID}" -- test -f /root/skylab.creds >/dev/null 2>&1; then
  pct pull "${CTID}" /root/skylab.creds "${CREDS_HOST}" >/dev/null 2>&1 || true
  [[ -f "${CREDS_HOST}" ]] && chmod 600 "${CREDS_HOST}"
fi
if [[ ! -f "${CREDS_HOST}" ]]; then
  msg_warn "Credentials could not be copied to this host. Read them with: pct exec ${CTID} -- cat /root/skylab.creds"
fi

printf '\n%b\n' "${GN}${APP} ${APP_VERSION} installed successfully.${CL}"
printf '  %-16s %s\n' "URL:"         "http://${CT_IP}:${NGINX_PORT}"
printf '  %-16s %s\n' "Setup wizard:" "http://${CT_IP}:${NGINX_PORT}/setup"
printf '  %-16s %s\n' "Container:"   "${CTID} (${CT_HOSTNAME})"
printf '  %-16s %s\n' "Shell:"       "pct enter ${CTID}"
printf '  %-16s %s\n' "Credentials:" "${CREDS_HOST}"
printf '  %-16s %s\n' "Updates:"     "pct exec ${CTID} -- skylab-update"
printf '\nNext step: open the setup wizard and add your Proxmox connection, IP subnet and gateway.\n\n'

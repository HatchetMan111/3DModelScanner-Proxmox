#!/usr/bin/env bash
#
# 3D Model Anything - Proxmox LXC Installer
#
# App:     3D Model Anything (Three.js-Raumviewer aus iPhone-LiDAR-Scans)
# Upstream: https://github.com/wesbos/3d-model-anything
# Stack:   Node.js 22, Vite-Build auf dem Host, statischer Viewer im LXC
# Laeuft:  vollstaendig lokal im LXC, Port 5188, keine Cloud zur Laufzeit
# Host:    DIESES SKRIPT LAEUFT AUF DEM PROXMOX-HOST (nicht im Container!)
#
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/3DModelScanner-Proxmox/main/install/3d-model-anything.sh)"
#   bash 3d-model-anything.sh --ctid 150 --cores 2 --memory 1024 --disk 8
#   bash 3d-model-anything.sh --ctid 150 --local-src /root/3d-model-anything --local-repo .
#   bash 3d-model-anything.sh --ctid 150 --reboot-test
#   bash 3d-model-anything.sh --help
#
set -euo pipefail
umask 077

# ---------------------------------------------------------------------------
# Variablen (Community-Scripts-konform - hier anpassen)
# ---------------------------------------------------------------------------
APP="3d-model-anything"
APP_PORT="5188"
APP_USER="modelanything"
APP_DIR="/opt/3d-model-anything"
DATA_DIR="/var/lib/3d-model-anything"
APP_VERSION="1.0.0"

UPSTREAM_REPO="https://github.com/wesbos/3d-model-anything"
UPSTREAM_REF="31b2dc9da3fb541e501f2f0936e55b32afb70ee8"
INSTALLER_REPO="https://github.com/HatchetMan111/3DModelScanner-Proxmox"
INSTALLER_REF="main"
INSTALLER_RAW="https://raw.githubusercontent.com/HatchetMan111/3DModelScanner-Proxmox/${INSTALLER_REF}"

DEFAULT_CORES="2"
DEFAULT_RAM="1024"
DEFAULT_SWAP="512"
DEFAULT_DISK="8"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"
DEFAULT_OS="debian-12-standard"
NODE_MAJOR="22"
NODE_MIN_VERSION="22.12.0"
UNPRIVILEGED="1"
FEATURES="nesting=1"

CT_ID="${CT_ID:-${CTID:-}}"
CT_HOSTNAME="${CT_HOSTNAME:-$APP}"
CORES="${CORES:-$DEFAULT_CORES}"
RAM="${RAM:-$DEFAULT_RAM}"
DISK="${DISK:-$DEFAULT_DISK}"
BRIDGE="${BRIDGE:-$DEFAULT_BRIDGE}"
TEMPLATE_STORE="${TEMPLATE_STORE:-$DEFAULT_TEMPLATE_STORE}"
STORAGE_ARG="${STORAGE:-}"
PASSWORD_ARG="${PASSWORD:-}"
SSH_KEY_ARG="${SSH_KEY:-}"
DNS_ARG="${DNS:-}"
PORT_ARG="${PORT:-$APP_PORT}"
UPSTREAM_REPO="${UPSTREAM_REPO_ARG:-$UPSTREAM_REPO}"
UPSTREAM_REF="${UPSTREAM_REF_ARG:-$UPSTREAM_REF}"
INSTALLER_REF="${INSTALLER_REF_ARG:-$INSTALLER_REF}"
LOCAL_SRC="${LOCAL_SRC:-}"
LOCAL_REPO="${LOCAL_REPO:-}"
REBOOT_TEST="${REBOOT_TEST:-0}"
DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"

BUILD_DIR=""
CT_IP=""

# ---------------------------------------------------------------------------
# Logging / Farben
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m'
else
  C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"

cleanup() {
  if [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]]; then
    rm -rf "$BUILD_DIR" || true
  fi
}

diagnose() {
  [[ -n "$CT_ID" ]] || return 0
  pct status "$CT_ID" >/dev/null 2>&1 || return 0
  msg_warn "--- systemctl status ${APP} ---"
  pct exec "$CT_ID" -- systemctl status "$APP" --no-pager 2>&1 | tail -n 60 || true
  msg_warn "--- journalctl -u ${APP} (letzte 100 Zeilen) ---"
  pct exec "$CT_ID" -- journalctl -u "$APP" --no-pager -n 100 2>&1 || true
  msg_warn "--- Listening sockets ---"
  pct exec "$CT_ID" -- ss -ltnp 2>&1 || true
  msg_warn "--- Deploy-Verzeichnis ---"
  pct exec "$CT_ID" -- bash -c "ls -la '${APP_DIR}' '${APP_DIR}/dist' 2>&1 | head -n 40" || true
  msg_warn "--- Node / Service-User ---"
  pct exec "$CT_ID" -- bash -c "id ${APP_USER} 2>&1; /opt/node/bin/node -v 2>&1" || true
}

on_error() {
  local ec=$?
  if [[ -n "${PASSWORD_ARG:-}" && "${BASH_COMMAND}" == *"${PASSWORD_ARG}"* ]]; then
    msg_error "FEHLER: Befehl mit Root-Passwort scheiterte in Zeile ${LINENO} (Exit ${ec}); Passwort wird nicht geloggt."
  else
    msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."
  fi
  msg_error "Vollstaendiges Log: ${LOG_FILE}"
  msg_error "--- letzte 40 Logzeilen ---"
  tail -n 40 "$LOG_FILE" 2>/dev/null || true
  diagnose || true
  if [[ "$DEBUG" != "1" ]]; then
    msg_error "Fuer bash -x erneut mit --debug starten."
  fi
  exit "$ec"
}
trap on_error ERR
trap cleanup EXIT

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer (Port ${APP_PORT})

Usage:
  bash ${APP}.sh [OPTIONEN]
  bash -c "\$(wget -qLO - ${INSTALLER_RAW}/install/${APP}.sh)"

Optionen:
  --ctid ID              Container-ID (Default: naechste freie ID)
  --hostname NAME        Hostname (Default: ${APP})
  --cores N              vCPU (Default: ${DEFAULT_CORES})
  --memory MB            RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB              Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME         RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store NAME  Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME          Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --dns IP               DNS-Server im Container (Default: automatisch)
  --password PW          Root-Passwort (Default: zufaellig, wird angezeigt)
  --ssh-key PATH         SSH Public Key fuer root (optional)
  --port N               Web-UI-Port (Default: ${APP_PORT})
  --upstream-repo URL    Upstream-Repository (Default: ${UPSTREAM_REPO})
  --upstream-ref REF     Commit/Tag/Branch des Upstreams (Default: gepinnt)
  --installer-ref REF    Ref dieses Repos fuer server/ und systemd/ (Default: ${INSTALLER_REF})
  --local-src PATH       Lokaler Upstream-Checkout statt GitHub-Archiv
  --local-repo PATH      Lokaler Checkout DIESES Repos (server/, systemd/)
  --reboot-test          Nach der Installation CT rebooten und erneut pruefen
  --debug                bash -x und ausfuehrliche Fehlerkette
  -h, --help             diese Hilfe

Umgebung:
  CT_ID, CORES, RAM, DISK, BRIDGE, DNS, STORAGE, PASSWORD, SSH_KEY, PORT,
  UPSTREAM_REPO_ARG, UPSTREAM_REF_ARG, INSTALLER_REF_ARG, LOCAL_SRC, LOCAL_REPO,
  REBOOT_TEST, DEBUG
EOF
}

require_value() {
  if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == -* ]]; then
    msg_error "Option $1 benoetigt einen Wert."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)           require_value "$1" "${2:-}"; CT_ID="$2"; shift 2;;
    --hostname)       require_value "$1" "${2:-}"; CT_HOSTNAME="$2"; shift 2;;
    --cores)          require_value "$1" "${2:-}"; CORES="$2"; shift 2;;
    --memory)         require_value "$1" "${2:-}"; RAM="$2"; shift 2;;
    --disk)           require_value "$1" "${2:-}"; DISK="$2"; shift 2;;
    --storage)        require_value "$1" "${2:-}"; STORAGE_ARG="$2"; shift 2;;
    --template-store) require_value "$1" "${2:-}"; TEMPLATE_STORE="$2"; shift 2;;
    --bridge)         require_value "$1" "${2:-}"; BRIDGE="$2"; shift 2;;
    --dns)            require_value "$1" "${2:-}"; DNS_ARG="$2"; shift 2;;
    --password)       require_value "$1" "${2:-}"; PASSWORD_ARG="$2"; shift 2;;
    --ssh-key)        require_value "$1" "${2:-}"; SSH_KEY_ARG="$2"; shift 2;;
    --port)           require_value "$1" "${2:-}"; PORT_ARG="$2"; shift 2;;
    --upstream-repo)  require_value "$1" "${2:-}"; UPSTREAM_REPO="$2"; shift 2;;
    --upstream-ref)   require_value "$1" "${2:-}"; UPSTREAM_REF="$2"; shift 2;;
    --installer-ref)  require_value "$1" "${2:-}"; INSTALLER_REF="$2"; shift 2;;
    --local-src)      require_value "$1" "${2:-}"; LOCAL_SRC="$2"; shift 2;;
    --local-repo)     require_value "$1" "${2:-}"; LOCAL_REPO="$2"; shift 2;;
    --reboot-test)    REBOOT_TEST="1"; shift;;
    --debug)          DEBUG="1"; shift;;
    -h|--help)        usage; exit 0;;
    *)                msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

APP_PORT="$PORT_ARG"
INSTALLER_RAW="https://raw.githubusercontent.com/HatchetMan111/3DModelScanner-Proxmox/${INSTALLER_REF}"

if [[ "$DEBUG" == "1" ]]; then
  export PS4='+ ${BASH_SOURCE[0]##*/}:${LINENO}: '
  set -x
fi

# ---------------------------------------------------------------------------
# Host-Pruefung / Validierung
# ---------------------------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausfuehren."; exit 1; }
for cmd in pct pvesh pveam pvesm openssl tar sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || { msg_error "$cmd nicht gefunden - ist das ein Proxmox-Host?"; exit 1; }
done
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
  || { msg_error "Weder curl noch wget auf dem Host gefunden."; exit 1; }
if [[ "$REBOOT_TEST" == "1" ]] && ! command -v curl >/dev/null 2>&1; then
  msg_error "--reboot-test benoetigt curl auf dem Host."
  exit 1
fi

[[ "$CORES" =~ ^[0-9]+$ && "$CORES" -ge 1 ]] || { msg_error "--cores muss eine positive Zahl sein."; exit 1; }
[[ "$RAM" =~ ^[0-9]+$ && "$RAM" -ge 512 ]] || { msg_error "--memory muss mindestens 512 MB sein."; exit 1; }
[[ "$DISK" =~ ^[0-9]+$ && "$DISK" -ge 4 ]] || { msg_error "--disk muss mindestens 4 GB sein."; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ && "$APP_PORT" -ge 1024 && "$APP_PORT" -le 65535 ]] \
  || { msg_error "--port muss zwischen 1024 und 65535 liegen (Service laeuft ohne root)."; exit 1; }
[[ "$CT_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ && ${#CT_HOSTNAME} -le 63 ]] \
  || { msg_error "Ungueltiger Hostname: $CT_HOSTNAME"; exit 1; }
if [[ -n "$DNS_ARG" && ! "$DNS_ARG" =~ ^[0-9A-Fa-f:.]+$ ]]; then
  msg_error "Ungueltiger DNS-Server: $DNS_ARG"
  exit 1
fi

case "$(uname -m)" in
  x86_64|amd64) NODE_ARCH="x64"; TEMPLATE_ARCH="amd64";;
  aarch64|arm64) NODE_ARCH="arm64"; TEMPLATE_ARCH="arm64";;
  *) msg_error "Nicht unterstuetzte Host-Architektur: $(uname -m)"; exit 1;;
esac

if [[ -n "$LOCAL_SRC" ]]; then
  LOCAL_SRC="$(cd "$LOCAL_SRC" && pwd)" || { msg_error "Lokales Upstream-Verzeichnis nicht gefunden."; exit 1; }
  [[ -f "$LOCAL_SRC/package.json" && -f "$LOCAL_SRC/apps/room-viewer/vite.config.ts" ]] \
    || { msg_error "--local-src zeigt nicht auf 3d-model-anything: $LOCAL_SRC"; exit 1; }
fi

if [[ -n "$LOCAL_REPO" ]]; then
  LOCAL_REPO="$(cd "$LOCAL_REPO" && pwd)" || { msg_error "Lokales Installer-Repo nicht gefunden."; exit 1; }
  [[ -f "$LOCAL_REPO/server/server.js" && -f "$LOCAL_REPO/server/package.json" && -f "$LOCAL_REPO/systemd/${APP}.service" ]] \
    || { msg_error "--local-repo zeigt nicht auf dieses Installer-Repo: $LOCAL_REPO"; exit 1; }
fi

if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid | tr -d '[:space:]"')"
  msg_info "Naechste freie CT-ID: $CT_ID"
fi
[[ "$CT_ID" =~ ^[0-9]+$ ]] || { msg_error "Ungueltige CT-ID: $CT_ID"; exit 1; }
if command -v qm >/dev/null 2>&1 && qm status "$CT_ID" >/dev/null 2>&1; then
  msg_error "ID ${CT_ID} ist bereits eine VM - bitte eine andere CT-ID waehlen."
  exit 1
fi

storage_is_active() {
  pvesm status --storage "$1" 2>/dev/null \
    | awk 'NR>1 && $3=="active" {found=1} END{exit !found}'
}

if [[ -z "$STORAGE_ARG" ]]; then
  if storage_is_active local-lvm; then
    STORAGE_ARG="local-lvm"
  else
    STORAGE_LIST="$(pvesm status -content rootdir 2>/dev/null || true)"
    STORAGE_ARG="$(printf '%s\n' "$STORAGE_LIST" | awk 'NR>1 && $3=="active" {print $1; exit}')"
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein aktiver RootFS-Storage gefunden."; exit 1; }
if ! storage_is_active "$STORAGE_ARG"; then
  msg_warn "Storage '${STORAGE_ARG}' ist nicht als aktiv gemeldet - pct create kann scheitern."
fi

FREE_KB="$(df -Pk /tmp | awk 'NR==2 {print $4}')"
if [[ "${FREE_KB:-0}" -lt 2097152 ]]; then
  msg_error "Zu wenig freier Platz in /tmp: $((FREE_KB / 1024)) MB, benoetigt mindestens 2 GB fuer den Build."
  exit 1
fi

msg_info "Storage: ${STORAGE_ARG} | Template-Store: ${TEMPLATE_STORE} | Bridge: ${BRIDGE}"
msg_info "Quelle: ${LOCAL_SRC:-${UPSTREAM_REPO} @ ${UPSTREAM_REF}}"

# ---------------------------------------------------------------------------
# Template sicherstellen
# ---------------------------------------------------------------------------
msg_info "Pruefe LXC-Template ..."
pveam update >/dev/null 2>&1 || msg_warn "pveam update scheiterte - nutze vorhandene Templates."
AVAILABLE_TEMPLATES="$(pveam available --section system 2>/dev/null || true)"
TEMPLATE="$(printf '%s\n' "$AVAILABLE_TEMPLATES" | grep -oP "${DEFAULT_OS}[^ ]*${TEMPLATE_ARCH}[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_warn "Kein ${DEFAULT_OS}-Template - suche neuestes Debian-Standard-Template ..."
  TEMPLATE="$(printf '%s\n' "$AVAILABLE_TEMPLATES" | grep -oP "debian-[0-9]+-standard[^ ]*${TEMPLATE_ARCH}[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
fi
[[ -n "${TEMPLATE:-}" ]] || { msg_error "Kein Debian-Standard-Template gefunden. Bitte 'pveam update' pruefen."; exit 1; }
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Lade Template ${TEMPLATE} ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE"
fi
msg_ok "Template bereit: ${TEMPLATE_STORE}:vztmpl/${TEMPLATE}"

# ---------------------------------------------------------------------------
# Container erstellen / Update-Modus
# ---------------------------------------------------------------------------
CT_CREATED="0"
CT_HOSTNAME_ACTUAL="$CT_HOSTNAME"
CT_CORES_ACTUAL="$CORES"
CT_RAM_ACTUAL="$RAM"
CT_DISK_ACTUAL="${DISK}G"
CT_UNPRIV_ACTUAL="1"
if pct status "$CT_ID" >/dev/null 2>&1; then
  msg_warn "CT ${CT_ID} existiert - Update-Modus (keine Neuerstellung)."
  msg_warn "Update-Modus: --cores, --memory, --disk, --hostname und --password werden nicht angewendet."
  pct set "$CT_ID" --onboot 1
  if [[ -n "$DNS_ARG" ]]; then
    pct set "$CT_ID" --nameserver "$DNS_ARG"
    msg_ok "DNS im CT gesetzt: ${DNS_ARG}"
  fi
  CT_CONFIG="$(pct config "$CT_ID")"
  CT_HOSTNAME_ACTUAL="$(printf '%s\n' "$CT_CONFIG" | awk -F': ' '/^hostname:/ {print $2; exit}')"
  CT_CORES_ACTUAL="$(printf '%s\n' "$CT_CONFIG" | awk -F': ' '/^cores:/ {print $2; exit}')"
  CT_RAM_ACTUAL="$(printf '%s\n' "$CT_CONFIG" | awk -F': ' '/^memory:/ {print $2; exit}')"
  CT_DISK_ACTUAL="$(printf '%s\n' "$CT_CONFIG" | sed -n 's/^rootfs:.*size=\([0-9]*[GTP]\).*/\1/p' | head -n1)"
  CT_UNPRIV_ACTUAL="$(printf '%s\n' "$CT_CONFIG" | awk -F': ' '/^unprivileged:/ {print $2; exit}')"
  CT_HOSTNAME_ACTUAL="${CT_HOSTNAME_ACTUAL:-$CT_HOSTNAME}"
  CT_CORES_ACTUAL="${CT_CORES_ACTUAL:-1}"
  CT_RAM_ACTUAL="${CT_RAM_ACTUAL:-$RAM}"
  CT_DISK_ACTUAL="${CT_DISK_ACTUAL:-?}"
  CT_UNPRIV_ACTUAL="${CT_UNPRIV_ACTUAL:-0}"
else
  CT_CREATED="1"
  if [[ -z "$PASSWORD_ARG" ]]; then
    if [[ "$DEBUG" == "1" ]]; then set +x; fi
    PASSWORD_ARG="$(openssl rand -hex 12)"
  fi
  NS_ARGS=()
  [[ -n "$DNS_ARG" ]] && NS_ARGS=(--nameserver "$DNS_ARG")
  msg_info "Erstelle CT ${CT_ID} (${CT_HOSTNAME}): ${CORES} vCPU / ${RAM} MB / ${DISK} GB ..."
  if [[ "$DEBUG" == "1" ]]; then set +x; fi
  pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
    --rootfs "${STORAGE_ARG}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" \
    --onboot 1 \
    "${NS_ARGS[@]}" \
    --password "$PASSWORD_ARG"
  if [[ "$DEBUG" == "1" ]]; then set -x; fi
  msg_ok "CT ${CT_ID} erstellt (unprivilegiert, nesting=1, onboot=1)."
  msg_warn "Root-Passwort CT ${CT_ID}: ${PASSWORD_ARG} (nur jetzt angezeigt - sicher notieren!)"
fi

if [[ "$(pct status "$CT_ID" | awk '{print $2}')" != "running" ]]; then
  pct start "$CT_ID"
fi

msg_info "Warte auf Container-Netz ..."
for _ in $(seq 1 30); do
  sleep 2
  CT_IP="$(pct exec "$CT_ID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}' || true)"
  [[ -n "$CT_IP" ]] || CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "$CT_IP" ]] && break
done
[[ -n "$CT_IP" ]] || { msg_error "Keine Container-IP - Netzwerk/Bridge pruefen."; exit 1; }
msg_ok "Container-IP: ${CT_IP}"

if [[ -n "$SSH_KEY_ARG" ]]; then
  [[ -f "$SSH_KEY_ARG" ]] || { msg_error "SSH-Key nicht gefunden: $SSH_KEY_ARG"; exit 1; }
  SSH_KEY_TYPE="$(awk 'NF {print $1; exit}' "$SSH_KEY_ARG")"
  case "$SSH_KEY_TYPE" in
    ssh-*|ecdsa-*|sk-*) ;;
    *) msg_error "Das sieht nicht nach einem SSH-Public-Key aus: $SSH_KEY_ARG"; exit 1;;
  esac
  pct push "$CT_ID" "$SSH_KEY_ARG" "/tmp/${APP}-authorized-key.pub"
  pct exec "$CT_ID" -- bash -c "
    set -euo pipefail
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    if ! grep -qxFf '/tmp/${APP}-authorized-key.pub' /root/.ssh/authorized_keys; then
      cat '/tmp/${APP}-authorized-key.pub' >> /root/.ssh/authorized_keys
    fi
    rm -f '/tmp/${APP}-authorized-key.pub'
  "
  msg_ok "SSH-Key installiert (bestehende Keys bleiben erhalten)."
fi

# ---------------------------------------------------------------------------
# Build auf dem Host (kein apt/npm/DNS im Container noetig)
# ---------------------------------------------------------------------------
fetch_file() {
  local url="$1" dest="$2"
  if [[ "$dest" == "-" ]]; then
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --retry 5 --retry-delay 2 "$url"
    else
      wget -qO- "$url"
    fi
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 5 --retry-delay 2 -o "$dest" "$url"
  else
    wget -qO "$dest" "$url"
  fi
}

BUILD_DIR="$(mktemp -d "/tmp/${APP}-build-XXXXXX")"
NODE_DIR="${BUILD_DIR}/node"
SRC_DIR="${BUILD_DIR}/src"
mkdir -p "$NODE_DIR" "$SRC_DIR"

msg_info "Lade Node.js ${NODE_MAJOR} (linux-${NODE_ARCH}) auf den Host ..."
NODE_DIST_URL="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/"
NODE_TARBALL_NAME="$(fetch_file "$NODE_DIST_URL" - | sed -n "s/.*\(node-v${NODE_MAJOR}\.[0-9][0-9]*\.[0-9][0-9]*-linux-${NODE_ARCH}\.tar\.gz\).*/\1/p" | head -n1)"
[[ -n "$NODE_TARBALL_NAME" ]] || { msg_error "Node.js-Tarball konnte nicht ermittelt werden."; exit 1; }
fetch_file "${NODE_DIST_URL}${NODE_TARBALL_NAME}" "${BUILD_DIR}/${NODE_TARBALL_NAME}"
fetch_file "${NODE_DIST_URL}SHASUMS256.txt" "${BUILD_DIR}/SHASUMS256.txt"
NODE_EXPECTED_SHA="$(awk -v name="$NODE_TARBALL_NAME" '$2 == name {print $1}' "${BUILD_DIR}/SHASUMS256.txt" | head -n1)"
[[ -n "$NODE_EXPECTED_SHA" ]] || { msg_error "Keine Pruefsumme fuer ${NODE_TARBALL_NAME} gefunden."; exit 1; }
printf '%s  %s\n' "$NODE_EXPECTED_SHA" "${BUILD_DIR}/${NODE_TARBALL_NAME}" | sha256sum -c - \
  || { msg_error "SHA256-Pruefsumme des Node.js-Tarballs stimmt nicht."; exit 1; }
tar -xzf "${BUILD_DIR}/${NODE_TARBALL_NAME}" -C "$NODE_DIR" --strip-components=1
export PATH="${NODE_DIR}/bin:${PATH}"
HOST_NODE_VERSION="$(node --version | sed 's/^v//')"
if [[ "$(printf '%s\n' "$NODE_MIN_VERSION" "$HOST_NODE_VERSION" | sort -V | head -n1)" != "$NODE_MIN_VERSION" ]]; then
  msg_error "Node.js ${HOST_NODE_VERSION} ist zu alt - benoetigt >= ${NODE_MIN_VERSION}."
  exit 1
fi
msg_ok "Host-Build-Node: $(node --version) / npm $(npm --version)"

msg_info "Hole Upstream-Quelle ..."
if [[ -n "$LOCAL_SRC" ]]; then
  tar -C "$LOCAL_SRC" \
    --exclude=.git --exclude=node_modules --exclude=dist --exclude=.superpowers \
    -czf "${BUILD_DIR}/src.tar.gz" .
else
  fetch_file "${UPSTREAM_REPO%/}/archive/${UPSTREAM_REF}.tar.gz" "${BUILD_DIR}/src.tar.gz"
fi
tar -xzf "${BUILD_DIR}/src.tar.gz" -C "$SRC_DIR" --strip-components=1
[[ -f "${SRC_DIR}/package.json" ]] || { msg_error "Upstream-Quelle unvollstaendig (package.json fehlt)."; exit 1; }

msg_info "Baue Viewer (npm ci && npm run build) - das dauert ein bis drei Minuten ..."
export npm_config_cache="${BUILD_DIR}/npm-cache"
export npm_config_update_notifier=false
(
  cd "$SRC_DIR"
  npm ci --no-audit --no-fund
  npm run build
)
DIST_DIR="${SRC_DIR}/apps/room-viewer/dist"
[[ -f "${DIST_DIR}/index.html" ]] || {
  msg_error "Build unvollstaendig: ${DIST_DIR}/index.html fehlt."
  ls -la "$DIST_DIR" 2>&1 || true
  exit 1
}
msg_ok "Build fertig: $(du -sh "$DIST_DIR" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# Deployment in den Container
# ---------------------------------------------------------------------------
msg_info "Deploye Node.js ${NODE_MAJOR} in den Container ..."
NODE_EXISTING=""
if pct exec "$CT_ID" -- test -x /opt/node/bin/node 2>/dev/null; then
  NODE_EXISTING="$(pct exec "$CT_ID" -- /opt/node/bin/node -v 2>/dev/null || true)"
fi
NODE_EXISTING_VERSION="${NODE_EXISTING#v}"
if [[ "$NODE_EXISTING" == v"${NODE_MAJOR}".* ]] \
  && [[ "$(printf '%s\n' "$NODE_MIN_VERSION" "$NODE_EXISTING_VERSION" | sort -V | head -n1)" == "$NODE_MIN_VERSION" ]]; then
  msg_ok "Node.js ${NODE_EXISTING} bereits vorhanden - ueberspringe."
else
  tar -czf "${BUILD_DIR}/node-runtime.tar.gz" -C "$NODE_DIR" .
  pct push "$CT_ID" "${BUILD_DIR}/node-runtime.tar.gz" "/tmp/${APP}-node.tar.gz"
  pct exec "$CT_ID" -- bash -c "
    set -euo pipefail
    rm -rf /opt/node
    mkdir -p /opt/node
    tar -xzf '/tmp/${APP}-node.tar.gz' -C /opt/node
    rm -f '/tmp/${APP}-node.tar.gz'
    chown -R root:root /opt/node
    chmod 755 /opt/node
    chmod -R a+rX /opt/node
    ln -sfn /opt/node/bin/node /usr/bin/node
    /opt/node/bin/node --version
  "
  msg_ok "Node.js $(pct exec "$CT_ID" -- /opt/node/bin/node --version) installiert."
fi
pct exec "$CT_ID" -- ln -sfn /opt/node/bin/node /usr/bin/node

msg_info "Erstelle Service-User und Verzeichnisse ..."
pct exec "$CT_ID" -- bash -s -- "$APP_USER" "$APP_DIR" "$DATA_DIR" <<'EOF'
set -euo pipefail
APP_USER="$1"
APP_DIR="$2"
DATA_DIR="$3"
getent group "$APP_USER" >/dev/null 2>&1 || groupadd --system "$APP_USER"
id -u "$APP_USER" >/dev/null 2>&1 || useradd --system --gid "$APP_USER" --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$APP_USER"
mkdir -p "$APP_DIR/server" "$DATA_DIR"
chown -R "$APP_USER:$APP_USER" "$DATA_DIR"
chmod 750 "$DATA_DIR"
EOF

if [[ "$CT_CREATED" == "0" ]]; then
  msg_info "Stoppe bestehenden Dienst fuer das Update ..."
  pct exec "$CT_ID" -- systemctl stop "$APP" 2>/dev/null || true
fi

msg_info "Deploye Viewer-Build ..."
tar -czf "${BUILD_DIR}/dist.tar.gz" -C "$DIST_DIR" .
pct push "$CT_ID" "${BUILD_DIR}/dist.tar.gz" "/tmp/${APP}-dist.tar.gz"
pct exec "$CT_ID" -- bash -c "
  set -euo pipefail
  rm -rf '${APP_DIR}/dist'
  mkdir -p '${APP_DIR}/dist'
  tar -xzf '/tmp/${APP}-dist.tar.gz' -C '${APP_DIR}/dist'
  rm -f '/tmp/${APP}-dist.tar.gz'
  test -f '${APP_DIR}/dist/index.html'
"

msg_info "Deploye Static-Server und systemd-Unit ..."
if [[ -n "$LOCAL_REPO" ]]; then
  SERVER_SRC="${LOCAL_REPO}/server/server.js"
  SERVER_PKG="${LOCAL_REPO}/server/package.json"
  UNIT_SRC="${LOCAL_REPO}/systemd/${APP}.service"
else
  fetch_file "${INSTALLER_RAW%/}/server/server.js" "${BUILD_DIR}/server.js"
  fetch_file "${INSTALLER_RAW%/}/server/package.json" "${BUILD_DIR}/server-package.json"
  fetch_file "${INSTALLER_RAW%/}/systemd/${APP}.service" "${BUILD_DIR}/${APP}.service"
  SERVER_SRC="${BUILD_DIR}/server.js"
  SERVER_PKG="${BUILD_DIR}/server-package.json"
  UNIT_SRC="${BUILD_DIR}/${APP}.service"
fi
grep -q 'createServer' "$SERVER_SRC" || { msg_error "server.js ist ungueltig (createServer fehlt)."; exit 1; }
grep -q '"type"[[:space:]]*:[[:space:]]*"module"' "$SERVER_PKG" \
  || { msg_error "server/package.json ist ungueltig (type=module fehlt)."; exit 1; }

grep -q "^User=${APP_USER}$" "$UNIT_SRC" \
  || { msg_error "systemd-Unit ist inkonsistent (User=${APP_USER} fehlt)."; exit 1; }
grep -qF "ExecStart=/opt/node/bin/node ${APP_DIR}/server/server.js" "$UNIT_SRC" \
  || { msg_error "systemd-Unit ist inkonsistent (ExecStart fehlt)."; exit 1; }
sed -e "s|^Environment=PORT=.*|Environment=PORT=${APP_PORT}|" \
    -e "s|^Environment=APP_VERSION=.*|Environment=APP_VERSION=${APP_VERSION}|" \
    "$UNIT_SRC" > "${BUILD_DIR}/unit.service"
grep -q "^Environment=PORT=${APP_PORT}$" "${BUILD_DIR}/unit.service" \
  || { msg_error "Port konnte nicht in die systemd-Unit geschrieben werden."; exit 1; }
grep -q "^Environment=APP_VERSION=${APP_VERSION}$" "${BUILD_DIR}/unit.service" \
  || { msg_error "Version konnte nicht in die systemd-Unit geschrieben werden."; exit 1; }

pct push "$CT_ID" "$SERVER_SRC" "${APP_DIR}/server/server.js"
pct push "$CT_ID" "$SERVER_PKG" "${APP_DIR}/server/package.json"
pct push "$CT_ID" "${BUILD_DIR}/unit.service" "/etc/systemd/system/${APP}.service"

pct exec "$CT_ID" -- bash -c "
  set -euo pipefail
  chown -R root:${APP_USER} '${APP_DIR}'
  find '${APP_DIR}' -type d -exec chmod 755 {} +
  find '${APP_DIR}' -type f -exec chmod 644 {} +
  chmod 0644 '/etc/systemd/system/${APP}.service'
"
msg_ok "App-Dateien bereit: ${APP_DIR}"

# ---------------------------------------------------------------------------
# Firewall (nur falls im Container aktiv)
# ---------------------------------------------------------------------------
pct exec "$CT_ID" -- bash -c "
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow ${APP_PORT}/tcp >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
    firewall-cmd --permanent --add-port=${APP_PORT}/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
" || msg_warn "Firewall-Konfiguration im Container uebersprungen."

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------
msg_info "Aktiviere systemd-Service ..."
pct exec "$CT_ID" -- systemctl daemon-reload
pct exec "$CT_ID" -- systemctl enable "$APP"
pct exec "$CT_ID" -- systemctl restart "$APP"
msg_ok "Service ${APP} aktiviert und (neu) gestartet."

# ---------------------------------------------------------------------------
# Verifikation
# ---------------------------------------------------------------------------
msg_info "Verifiziere Service ..."
SERVICE_ACTIVE="0"
for _ in $(seq 1 20); do
  if pct exec "$CT_ID" -- systemctl is-active --quiet "$APP"; then
    SERVICE_ACTIVE="1"
    break
  fi
  sleep 1
done
if [[ "$SERVICE_ACTIVE" != "1" ]]; then
  msg_error "Service ${APP} ist nicht active."
  diagnose || true
  exit 1
fi
msg_ok "Service läuft (systemctl is-active ${APP} = active)."

msg_info "Verifiziere Web UI im Container (localhost:${APP_PORT}) ..."
LOCAL_CODE="0"
for _ in $(seq 1 30); do
  LOCAL_CODE="$(pct exec "$CT_ID" -- /opt/node/bin/node -e "fetch('http://127.0.0.1:${APP_PORT}/api/health').then(r=>{console.log(r.status);process.exit(0)}).catch(()=>{console.log(0);process.exit(0)})" 2>/dev/null || echo 0)"
  [[ "$LOCAL_CODE" == "200" ]] && break
  sleep 2
done
if [[ "$LOCAL_CODE" != "200" ]]; then
  msg_error "Web UI antwortet im Container nicht (HTTP ${LOCAL_CODE})."
  diagnose || true
  exit 1
fi
msg_ok "Container-interner Health-Check: HTTP ${LOCAL_CODE}."

msg_info "Verifiziere Web UI von aussen (${CT_IP}:${APP_PORT}) ..."
HEALTH_CODE="000"
ROOT_CODE="000"
for _ in $(seq 1 30); do
  if command -v curl >/dev/null 2>&1; then
    HEALTH_CODE="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 "http://${CT_IP}:${APP_PORT}/api/health" 2>/dev/null || true)"
    ROOT_CODE="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 "http://${CT_IP}:${APP_PORT}/" 2>/dev/null || true)"
  elif command -v wget >/dev/null 2>&1; then
    HEALTH_CODE="$(wget -qO /dev/null -S "http://${CT_IP}:${APP_PORT}/api/health" 2>&1 | awk '/HTTP\// {print $2; exit}')"
    ROOT_CODE="$(wget -qO /dev/null -S "http://${CT_IP}:${APP_PORT}/" 2>&1 | awk '/HTTP\// {print $2; exit}')"
  fi
  HEALTH_CODE="${HEALTH_CODE:-000}"
  ROOT_CODE="${ROOT_CODE:-000}"
  [[ "$HEALTH_CODE" == "200" && "$ROOT_CODE" == "200" ]] && break
  sleep 2
done

if [[ "$HEALTH_CODE" != "200" || "$ROOT_CODE" != "200" ]]; then
  msg_error "App antwortet nicht (Health: ${HEALTH_CODE}, Startseite: ${ROOT_CODE})."
  diagnose || true
  exit 1
fi
msg_ok "Health-Endpunkt: HTTP ${HEALTH_CODE} | Startseite: HTTP ${ROOT_CODE}."

# ---------------------------------------------------------------------------
# Optionaler Reboot-Test
# ---------------------------------------------------------------------------
if [[ "$REBOOT_TEST" == "1" ]]; then
  msg_info "Reboot-Test: CT ${CT_ID} wird neu gestartet ..."
  pct reboot "$CT_ID"
  sleep 5
  CT_IP=""
  for _ in $(seq 1 30); do
    CT_IP="$(pct exec "$CT_ID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}' || true)"
    [[ -n "$CT_IP" ]] && break
    sleep 2
  done
  [[ -n "$CT_IP" ]] || { msg_error "Keine Container-IP nach Reboot."; diagnose || true; exit 1; }

  REBOOT_CODE="000"
  for _ in $(seq 1 60); do
    REBOOT_CODE="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 "http://${CT_IP}:${APP_PORT}/api/health" 2>/dev/null || true)"
    REBOOT_CODE="${REBOOT_CODE:-000}"
    [[ "$REBOOT_CODE" == "200" ]] && break
    sleep 2
  done
  if [[ "$REBOOT_CODE" != "200" ]]; then
    msg_error "Web UI nach Reboot nicht erreichbar (HTTP ${REBOOT_CODE})."
    diagnose || true
    exit 1
  fi
  msg_ok "Reboot-Test erfolgreich: Web UI nach Reboot erreichbar (HTTP ${REBOOT_CODE})."
  msg_info "Letzte Journal-Zeilen nach Reboot:"
  pct exec "$CT_ID" -- journalctl -u "$APP" --no-pager -n 20 || true
fi

# ---------------------------------------------------------------------------
# Abschluss
# ---------------------------------------------------------------------------
if [[ "$DEBUG" == "1" ]]; then set +x; fi
echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App           : 3D Model Anything"
echo "  Upstream      : ${UPSTREAM_REPO} @ ${UPSTREAM_REF}"
echo "  Installer     : ${INSTALLER_REPO} @ ${INSTALLER_REF}"
MODE_LABEL="neu erstellt"
[[ "$CT_CREATED" == "0" ]] && MODE_LABEL="Update"
echo "  Container     : CT ${CT_ID} (${CT_HOSTNAME_ACTUAL}, unprivileged=${CT_UNPRIV_ACTUAL}, onboot=1, ${MODE_LABEL})"
echo "  Ressourcen    : ${CT_CORES_ACTUAL} vCPU / ${CT_RAM_ACTUAL} MB RAM / ${CT_DISK_ACTUAL} Disk"
echo "  Endpoint      : http://${CT_IP}:${APP_PORT}"
echo "  Health        : http://${CT_IP}:${APP_PORT}/api/health"
echo "  Daten         : ${DATA_DIR}"
if [[ "$CT_CREATED" == "1" ]]; then
  echo "  Root-Passwort : ${PASSWORD_ARG} (nur jetzt angezeigt!)"
else
  echo "  Root-Passwort : <bestehender CT, unveraendert>"
fi
echo "  Service       : systemctl status ${APP}  (im Container: pct enter ${CT_ID})"
echo "  Update        : Installer erneut mit --ctid ${CT_ID} ausfuehren"
echo "  Reboot-Test   : pct reboot ${CT_ID} && sleep 30 && curl -fsS http://${CT_IP}:${APP_PORT}/api/health"
echo "  Deinstall     : pct stop ${CT_ID} && pct destroy ${CT_ID}   (loescht auch ${DATA_DIR}!)"
echo "  Log           : ${LOG_FILE}"
echo "══════════════════════════════════════════════════════════"
echo ""
msg_warn "Kein Login: nur im vertrauenswuerdigen LAN/VPN betreiben, nicht ins Internet stellen."

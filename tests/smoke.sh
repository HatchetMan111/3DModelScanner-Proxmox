#!/usr/bin/env bash
#
# Lokaler End-to-End-Smoke-Test fuer den 3D-Model-Anything-Viewer.
#
# Simuliert den Installer ohne Proxmox:
#   1. Upstream-Quelle laden und bauen (npm ci && npm run build)
#   2. dist/ mit dem Static-Server aus diesem Repo ausliefern
#   3. Health und Startseite pruefen
#   4. Prozess stoppen und neu starten (Reboot-Simulation)
#   5. Health und Startseite erneut pruefen
#
# Usage:
#   bash tests/smoke.sh
#   UPSTREAM_REF=<commit> PORT=5199 bash tests/smoke.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/wesbos/3d-model-anything}"
UPSTREAM_REF="${UPSTREAM_REF:-31b2dc9da3fb541e501f2f0936e55b32afb70ee8}"
PORT="${PORT:-5199}"
BASE_URL="http://127.0.0.1:${PORT}"

TMP_DIR="$(mktemp -d /tmp/3dma-smoke-XXXXXX)"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

info() { echo -e "\e[34m[SMOKE]\e[0m $*"; }
ok()   { echo -e "\e[32m[OK]\e[0m    $*"; }
fail() { echo -e "\e[31m[FAIL]\e[0m  $*" >&2; exit 1; }

command -v node >/dev/null 2>&1 || fail "node fehlt"
command -v npm >/dev/null 2>&1 || fail "npm fehlt"
command -v curl >/dev/null 2>&1 || fail "curl fehlt"

NODE_VERSION="$(node -p 'process.versions.node')"
if [[ "$(printf '%s\n' '22.12.0' "$NODE_VERSION" | sort -V | head -n1)" != '22.12.0' ]]; then
  fail "Node.js >= 22.12 noetig, gefunden: $(node --version)"
fi

start_server() {
  APP_DIR="${TMP_DIR}/site" PORT="$PORT" HOST=127.0.0.1 \
    node "${TMP_DIR}/app/server/server.js" >>"${TMP_DIR}/server.log" 2>&1 &
  SERVER_PID=$!
}

wait_for_http() {
  local url="$1" attempts="${2:-60}"
  for _ in $(seq 1 "$attempts"); do
    if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "--- Server-Log ---" >&2
      cat "${TMP_DIR}/server.log" >&2 || true
      return 1
    fi
    sleep 1
  done
  return 1
}

verify() {
  local phase="$1" asset
  wait_for_http "${BASE_URL}/api/health" || fail "${phase}: Health nicht erreichbar"
  curl -fsS "${BASE_URL}/api/health" | grep -q '"status":"ok"' \
    || fail "${phase}: Health-Status ungueltig"
  curl -fsS "${BASE_URL}/" | grep -q '3D Model Anything' \
    || fail "${phase}: Startseite ohne Viewer-Marker"
  curl -fsS "${BASE_URL}/play.html" | grep -q 'play' \
    || fail "${phase}: play.html nicht erreichbar"
  asset="$(cd "${TMP_DIR}/site" && find assets -maxdepth 1 -name '*.js' -print -quit)"
  [[ -n "$asset" ]] || fail "${phase}: kein JavaScript-Bundle gefunden"
  curl -fsS "${BASE_URL}/${asset}" >/dev/null \
    || fail "${phase}: Bundle ${asset} nicht erreichbar"
  ok "${phase}: /api/health = 200, Startseite + play.html + Bundle erreichbar"
}

info "Baue Upstream ${UPSTREAM_REF} ..."
mkdir -p "${TMP_DIR}/src"
curl -fsSL --retry 3 "${UPSTREAM_REPO%/}/archive/${UPSTREAM_REF}.tar.gz" -o "${TMP_DIR}/src.tar.gz"
tar -xzf "${TMP_DIR}/src.tar.gz" -C "${TMP_DIR}/src" --strip-components=1
(
  cd "${TMP_DIR}/src"
  export npm_config_cache="${TMP_DIR}/npm-cache"
  npm ci --no-audit --no-fund
  npm run build
)
[[ -f "${TMP_DIR}/src/apps/room-viewer/dist/index.html" ]] || fail "Build ohne dist/index.html"
cp -a "${TMP_DIR}/src/apps/room-viewer/dist" "${TMP_DIR}/site"
[[ -f "${TMP_DIR}/site/play.html" ]] || fail "Build ohne play.html"
grep -q '/assets/' "${TMP_DIR}/site/index.html" || fail "index.html referenziert keine Bundles"
[[ -n "$(find "${TMP_DIR}/site/assets" -maxdepth 1 -name '*.js' -print -quit)" ]] \
  || fail "Build ohne JavaScript-Bundles"
mkdir -p "${TMP_DIR}/app/server"
cp "${REPO_ROOT}/server/server.js" "${REPO_ROOT}/server/package.json" "${TMP_DIR}/app/server/"
ok "Build fertig ($(du -sh "${TMP_DIR}/site" | awk '{print $1}'))"

info "Starte Static-Server auf ${BASE_URL} ..."
start_server
verify "Erststart"

info "Stoppe Prozess (Reboot-Simulation) ..."
kill -TERM "$SERVER_PID"
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
sleep 1
curl -fsS --max-time 2 "${BASE_URL}/api/health" >/dev/null 2>&1 \
  && fail "Server laeuft nach dem Stoppen noch"

info "Starte Prozess neu ..."
start_server
verify "Nach Neustart"

echo ""
ok "SMOKE-TEST BESTANDEN (Build + Serve + Neustart)"
echo "--- Server-Log (letzte 20 Zeilen) ---"
tail -n 20 "${TMP_DIR}/server.log"

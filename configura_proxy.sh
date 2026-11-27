#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Davide Marino
# SPDX-License-Identifier: GPL-3.0-or-later
## DAVE
# =============================================================================
# configura_proxy.sh — uscita internet SOLO tramite proxy: configura i tre nodi.
#   Si lancia da node01, come root, PRIMA di 00/run_all, dopo configura_topologia.sh.
#
#   Per ogni nodo scrive (idempotente):
#     /etc/environment                          http(s)_proxy + NO_PROXY (nodi, VIP, subnet del cluster)
#     /etc/apt/apt.conf.d/95proxy               proxy esplicito per apt
#     /etc/systemd/system/docker.service.d/http-proxy.conf   proxy del daemon Docker (pull da quay.io)
#   e, se Docker e' gia' attivo, lo riavvia. NO_PROXY e' indispensabile: senza, il traffico
#   interno (API OpenStack sul VIP, Ceph, CLI) passerebbe dal proxy e si romperebbe.
#
#   USO
#     bash configura_proxy.sh --proxy http://IP:PORTA [--dry-run]
#     bash configura_proxy.sh                  # usa PROXY_URL di topology.conf o http_proxy dell'ambiente
#     bash configura_proxy.sh --verify         # prova gli endpoint del deploy via proxy, su ogni nodo
#   --dry-run  non tocca i nodi: scrive i file in ./dry-run-proxy/<nodo>/ e li mostra.
#   Aggiungere voci a NO_PROXY: NO_PROXY_EXTRA="a,b" in topology.conf.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export LAB_MODE="${LAB_MODE:-0}"
# shellcheck disable=SC1091
source "$HERE/lib_topology.sh" >/dev/null 2>&1 || { echo "[ERRORE] lib_topology.sh non leggibile"; exit 1; }

PX_ARG=""; DRY=0; VERIFY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --proxy)   PX_ARG="${2:-}"; shift 2;;
    --dry-run) DRY=1; shift;;
    --verify)  VERIFY=1; shift;;
    -h|--help) sed -n '3,20p' "$0"; exit 0;;
    *) echo "[ERRORE] opzione sconosciuta: $1"; exit 1;;
  esac
done
PROXY="${PX_ARG:-$(topo_proxy_url)}"
[[ "$PROXY" =~ ^https?://[^[:space:]\"\'\\$\`]+$ ]] || { echo "[ERRORE] proxy non valido o assente (atteso http://IP:PORTA): '${PROXY}'"; exit 1; }
NOPROXY="$(topo_no_proxy)"
SSHO=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -i "$DEPLOY_KEY")

echo "Proxy:    $PROXY"
echo "NO_PROXY: $NOPROXY"

env_block() {
  cat <<EOT
http_proxy="${PROXY}"
https_proxy="${PROXY}"
HTTP_PROXY="${PROXY}"
HTTPS_PROXY="${PROXY}"
no_proxy="${NOPROXY}"
NO_PROXY="${NOPROXY}"
EOT
}
apt_block()    { printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$PROXY" "$PROXY"; }
docker_block() { printf '[Service]\nEnvironment="HTTP_PROXY=%s"\nEnvironment="HTTPS_PROXY=%s"\nEnvironment="NO_PROXY=%s"\n' "$PROXY" "$PROXY" "$NOPROXY"; }

if [ "$VERIFY" = 1 ]; then
  rc=0
  for n in "${ALL_NODES[@]}"; do
    echo "== $n ($(mgmt_ip "$n"))"
    ssh "${SSHO[@]}" "root@$(mgmt_ip "$n")" bash -s -- "$VIP" <<'EOF' || rc=1
px="${https_proxy:-${http_proxy:-}}"; r=0
[ -n "$px" ] || { echo "  [FAIL] nessun proxy in ambiente (rientra dal login o: set -a; . /etc/environment; set +a)"; exit 1; }
case ",${no_proxy:-}," in *",$1,"*) echo "  [OK] no_proxy contiene il VIP";; *) echo "  [FAIL] no_proxy senza VIP"; r=1;; esac
  ## DAVE
  for u in http://archive.ubuntu.com/ubuntu/dists/noble/InRelease http://security.ubuntu.com/ubuntu/dists/noble-security/InRelease https://quay.io/v2/ https://download.docker.com/linux/ubuntu/gpg https://pypi.org/simple/ https://files.pythonhosted.org/ https://download.cirros-cloud.net/; do
  ## DAVE
  c="$(curl -sS -o /dev/null -I -m25 -w '%{http_code}' --proxy "$px" "$u" 2>/dev/null)"
  case "$c" in 000|"") echo "  [FAIL] $u"; r=1;; *) echo "  [OK] $u (HTTP $c)";; esac
done
[ -f /etc/systemd/system/docker.service.d/http-proxy.conf ] && echo "  [OK] drop-in Docker presente" || echo "  [WARN] drop-in Docker assente"
exit $r
EOF
  done
  exit $rc
fi

if [ "$DRY" = 1 ]; then
  OUT="$HERE/dry-run-proxy"; rm -rf "$OUT"
  for n in "${ALL_NODES[@]}"; do
    mkdir -p "$OUT/$n"
    env_block    > "$OUT/$n/environment.proxy"
    apt_block    > "$OUT/$n/95proxy"
    docker_block > "$OUT/$n/http-proxy.conf"
  done
  echo "--dry-run: nessuna modifica. File in $OUT"; echo; cat "$OUT/${ALL_NODES[0]}/environment.proxy"
  exit 0
fi

fail=0
for n in "${ALL_NODES[@]}"; do
  ip="$(mgmt_ip "$n")"
  if ssh "${SSHO[@]}" "root@$ip" bash -s <<EOF
set -e
# /etc/environment: togli le righe proxy precedenti e riscrivile (le altre righe restano)
sed -i -E '/^[[:space:]]*(http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|no_proxy|NO_PROXY)=/d' /etc/environment
cat >> /etc/environment <<'ENVB'
$(env_block)
ENVB
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/95proxy <<'APTB'
$(apt_block)
APTB
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/http-proxy.conf <<'DOCKB'
$(docker_block)
DOCKB
systemctl daemon-reload
if systemctl is-active --quiet docker; then systemctl restart docker; fi
EOF
  then echo "  [OK] $n: proxy e NO_PROXY configurati"
  else echo "  [FAIL] $n: configurazione fallita"; fail=1; fi
done
echo
if [ "$fail" = 0 ]; then
  echo "Fatto. Nella shell corrente carica le nuove variabili (oppure riapri la sessione/tmux):"
  echo "  set -a; . /etc/environment; set +a"
  echo "Poi verifica:  bash configura_proxy.sh --verify"
fi
exit "$fail"
## DAVE

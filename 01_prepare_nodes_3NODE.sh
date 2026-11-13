#!/usr/bin/env bash
# =============================================================================
# 01_prepare_nodes_3NODE.sh — 3 nodi iperconvergenti (OpenStack + Ceph)
#   Server bare-metal. Prepara i nodi per il deploy Kolla-Ansible 2025.1.
#   Gira DALL'HOST di deploy (stessa deploy key del 00).
#
#   PRESUPPONE che il 00 abbia gia' chiuso [OK]:
#     - accesso root a chiave su tutti i nodi (IP finali 10.0.10.11-13)
#     - rete (bond+VLAN), NTP (chrony), /etc/hosts, egress internet verificati
#
#   Cosa fa (rispetto al lab 6-nodi, molto e' gia' nel 00):
#     1. precheck            — nodi a chiave + prerequisiti del 00 presenti
#     2. install_docker      — Docker Engine su tutti e 3 i nodi
#     3. install_python      — python3 + modulo docker (richiesto da Kolla)
#     4. mask_host_libvirt   — spegne/mask il libvirt installato sull'host: su ferro tutti i
#                              nodi sono compute e Kolla usa il PROPRIO libvirt
#                              in container (nova_libvirt); quello host farebbe
#                              contesa sul socket.
#     5. setup_kolla         — venv + kolla-ansible + /etc/kolla sul nodo deploy
#     6. node_key            — chiave SSH generata SUL nodo deploy, distribuita a
#                              tutti (kolla-ansible gira su node01 e SSH-a i 3)
#     7. gen_inventory       — inventory multinode a 3 nodi (iniettato nel template)
#     8. ansible_cfg         — /etc/ansible/ansible.cfg
#     9. verify              — kolla-ansible --version + ansible ping su tutti
#
#   NON fa: bootstrap-servers, pull, deploy (sono nel 02). NON tocca lo storage
#   (Ceph e' nel 01b). Il loopback Cinder LVM del lab e' RIMOSSO (backend = Ceph).
#
#   USO (dall'host di deploy):
#     sudo bash 01_prepare_nodes_3NODE.sh
#     sudo bash 01_prepare_nodes_3NODE.sh --node node02   # limita a un nodo
# =============================================================================
set -uo pipefail

# ============================ CONFIG ========================================
# Topologia (nodi, ruoli, IP, VLAN) centralizzata: SORGENTE UNICA.
source "$(dirname "$0")/lib_topology.sh"

VENV_PATH="/opt/kolla-venv"
KOLLA_VERSION="2025.1"
NODE_KOLLA_KEY="/root/.ssh/id_ed25519_kolla"      # chiave generata SU node01

# vincoli versione (allineati a OpenStack 2025.1 / Epoxy)
KOLLA_PIP='kolla-ansible>=20.0,<21.0'
ANSIBLE_PIP='ansible-core>=2.17,<2.19'
# =============================================================================
# compat: le funzioni usano NODE_IPS[...]; deriva dalla topologia
declare -A NODE_IPS; for _k in "${ALL_NODES[@]}"; do NODE_IPS[$_k]="${NODE_MGMT_IP[$_k]}"; done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}=== $* ===${NC}"; }
log_ok()    { echo -e "  ${GREEN}[OK]${NC} $*"; }
log_fail()  { echo -e "  ${RED}[FAIL]${NC} $*"; }

ALL_NODES=("${ALL_NODES[@]}")   # dalla topologia (lib_topology.sh)
NODES=("${ALL_NODES[@]}")
FAILURES=0

next_is_node=0
for arg in "$@"; do
  if [ "$next_is_node" = 1 ]; then NODES=("$arg"); next_is_node=0; continue; fi
  case "$arg" in
    --node)    next_is_node=1 ;;
    --help|-h) sed -n '2,40p' "$0"; exit 0 ;;
    *) log_error "Opzione sconosciuta: $arg"; exit 1 ;;
  esac
done

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15)
ssh_key() { local ip="$1"; shift; ssh "${SSH_OPTS[@]}" -i "$DEPLOY_KEY" "root@${ip}" "$@"; }

# blocco remoto riusabile: attende cloud-init + lock dpkg, poi apt-get update.
# E' la lezione del fix NTP: senza update, la cache stantia della ISO da' 404.
APT_PREP='
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait >/dev/null 2>&1 || true
for i in $(seq 1 60); do
  fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1 || break
  [ "$i" = 60 ] && { echo "APT_LOCK_TIMEOUT"; exit 1; }
  sleep 10
done
apt-get update -q || { echo "APT_UPDATE_FAIL"; exit 1; }
'

# ------------------------- FASE 1: precheck ---------------------------------
phase_precheck() {
  log_step "FASE 1 — Precheck (il 00 deve aver gia' chiuso [OK])"
  if [ ! -f "$DEPLOY_KEY" ]; then
    log_error "Deploy key assente: ${DEPLOY_KEY}. Esegui prima il 00."
    exit 1
  fi
  for n in "${NODES[@]}"; do
    local ip="${NODE_IPS[$n]}"
    if ! ssh_key "$ip" true >/dev/null 2>&1; then
      log_fail "$n (${ip}): non raggiungibile a chiave. Il 00 e' andato a buon fine?"
      exit 1
    fi
    # verifica leggera dei prerequisiti del 00 (NTP)
    if ! ssh_key "$ip" "systemctl is-active --quiet chrony"; then
      log_fail "$n: chrony non attivo. Rilancia:  00_bootstrap_baremetal.sh --ntp-only"
      exit 1
    fi
    log_ok "$n (${ip}): raggiungibile, chrony attivo"
  done
}

# ------------------------- FASE 2: Docker -----------------------------------
install_docker() {
  log_step "FASE 2 — Docker Engine sui nodi"
  for n in "${NODES[@]}"; do
    local ip="${NODE_IPS[$n]}"
    if ssh_key "$ip" "systemctl is-active --quiet docker"; then
      log_ok "$n: Docker gia' attivo"; continue
    fi
    log_info "  installo Docker su $n..."
    local out rc
    ## DAVE - con proxy il daemon Docker (che scarica da quay.io) non legge /etc/environment: drop-in systemd
    local _px _np DOCKER_PROXY_SNIPPET=""
    _px="$(topo_proxy_url)"; _np="$(topo_no_proxy)"
    if [ -n "$_px" ]; then
      DOCKER_PROXY_SNIPPET="mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/http-proxy.conf <<'DP'
[Service]
Environment=\"HTTP_PROXY=${_px}\"
Environment=\"HTTPS_PROXY=${_px}\"
Environment=\"NO_PROXY=${_np}\"
DP
systemctl daemon-reload"
    fi
    ## DAVE
    out="$(ssh_key "$ip" "bash -s" <<EOF 2>&1
set -e
${APT_PREP}
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -q
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
${DOCKER_PROXY_SNIPPET}
systemctl enable --now docker
docker --version
echo "__DOCKER_OK__"
EOF
)"
    rc=$?
    if [ "$rc" -ne 0 ] || ! echo "$out" | grep -q "__DOCKER_OK__"; then
      log_fail "$n: installazione Docker fallita:"
      echo "$out" | tail -8 | sed 's/^/      | /'
      case "$out" in
        *APT_UPDATE_FAIL*|*download.docker.com*) log_fail "  -> egress verso download.docker.com? (verifica col 00 --verify-only)";;
      esac
      FAILURES=$((FAILURES+1)); continue
    fi
    log_ok "$n: Docker installato ($(echo "$out" | grep -oE 'Docker version [0-9.]+' | head -1))"
  done
}

# ------------------------- FASE 3: Python + modulo docker -------------------
install_python() {
  log_step "FASE 3 — Python3 + modulo docker sui nodi"
  for n in "${NODES[@]}"; do
    local ip="${NODE_IPS[$n]}"
    local out rc
    out="$(ssh_key "$ip" "bash -s" <<EOF 2>&1
set -e
${APT_PREP}
apt-get install -y python3 python3-pip python3-venv
# il modulo docker per python e' richiesto dai moduli Ansible di Kolla
pip3 install --break-system-packages docker >/dev/null 2>&1 || apt-get install -y python3-docker
python3 -c 'import docker; print("docker-py", docker.__version__)'
echo "__PY_OK__"
EOF
)"
    rc=$?
    if [ "$rc" -ne 0 ] || ! echo "$out" | grep -q "__PY_OK__"; then
      log_fail "$n: setup Python fallito:"; echo "$out" | tail -8 | sed 's/^/      | /'
      FAILURES=$((FAILURES+1)); continue
    fi
    log_ok "$n: Python + modulo docker ok ($(echo "$out" | grep -oE 'docker-py [0-9.]+'))"
  done
}

# ------------------------- FASE 4: neutralizza libvirt host -----------------
mask_host_libvirt() {
  log_step "FASE 4 — Neutralizzo libvirt dell'host (Kolla usa il proprio in container)"
  for n in "${NODES[@]}"; do
    local ip="${NODE_IPS[$n]}"
    ssh_key "$ip" "bash -s" <<'EOF' >/dev/null 2>&1
# Se una libvirt host e' presente e attiva, contende il socket a nova_libvirt.
# Non la installiamo: se c'e' la spegniamo e mascheriamo; se non c'e', nulla.
for u in libvirtd.service libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket; do
  systemctl stop "$u" 2>/dev/null || true
  systemctl disable "$u" 2>/dev/null || true
  systemctl mask "$u" 2>/dev/null || true
done
EOF
    log_ok "$n: libvirt host neutralizzato (se presente)"
  done
}

# ------------------------- FASE 5: Kolla-Ansible sul nodo deploy -------------
setup_kolla() {
  log_step "FASE 5 — Kolla-Ansible ${KOLLA_VERSION} su ${DEPLOY_NODE}"
  local ip="${NODE_IPS[$DEPLOY_NODE]}"
  local out rc
  out="$(ssh_key "$ip" "bash -s" <<EOF 2>&1
set -e
${APT_PREP}
apt-get install -y python3-dev python3-venv libffi-dev gcc libssl-dev git
python3 -m venv ${VENV_PATH}
source ${VENV_PATH}/bin/activate
pip install -U pip >/dev/null
pip install '${ANSIBLE_PIP}' >/dev/null
pip install '${KOLLA_PIP}' >/dev/null
kolla-ansible --version
mkdir -p /etc/kolla
cp -r ${VENV_PATH}/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/ 2>/dev/null || true
## DAVE - dopo il passaggio di un rilascio a "unmaintained" il ramo stable/<rel> della collezione viene
## rinominato unmaintained/<rel>: il requirements.yml del pacchetto pip punta ancora a stable/<rel> e
## install-deps fallisce ("pathspec ... did not match"). Se il ramo non esiste piu' e quello unmaintained si, lo uso.
KREQ=${VENV_PATH}/share/kolla-ansible/requirements.yml
for br in \$(grep -oE 'version: *stable/[0-9.]+' "\$KREQ" | awk '{print \$2}'); do
  if ! git ls-remote --exit-code --heads https://opendev.org/openstack/ansible-collection-kolla "\$br" >/dev/null 2>&1; then
    alt="unmaintained/\${br#stable/}"
    if git ls-remote --exit-code --heads https://opendev.org/openstack/ansible-collection-kolla "\$alt" >/dev/null 2>&1; then
      sed -i "s#\$br#\$alt#" "\$KREQ"
      echo "requirements.yml: \$br non esiste piu', uso \$alt"
    fi
  fi
done
## DAVE
kolla-ansible install-deps
echo "__KOLLA_OK__"
EOF
)"
  rc=$?
  if [ "$rc" -ne 0 ] || ! echo "$out" | grep -q "__KOLLA_OK__"; then
    log_fail "${DEPLOY_NODE}: installazione Kolla-Ansible fallita:"
    echo "$out" | tail -12 | sed 's/^/      | /'
    case "$out" in
      *pypi*|*APT_UPDATE_FAIL*) log_fail "  -> egress verso pypi.org / files.pythonhosted.org?";;
    esac
    FAILURES=$((FAILURES+1)); return 1
  fi
  log_ok "${DEPLOY_NODE}: kolla-ansible $(echo "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) installato + collezioni"
}

# ------------------------- FASE 6: chiave SSH del nodo deploy ----------------
# kolla-ansible gira su node01 e SSH-a root@ verso node01/02/03 (incluso se
# stesso). Serve una chiave DI node01 autorizzata su tutti e tre.
distribute_node_key() {
  log_step "FASE 6 — Chiave SSH di ${DEPLOY_NODE} verso tutti i nodi"
  local dep_ip="${NODE_IPS[$DEPLOY_NODE]}"
  ssh_key "$dep_ip" "bash -s" <<EOF >/dev/null 2>&1
[ -f ${NODE_KOLLA_KEY} ] || ssh-keygen -t ed25519 -N "" -f ${NODE_KOLLA_KEY} -C "kolla@${DEPLOY_NODE}"
EOF
  local pub; pub="$(ssh_key "$dep_ip" "cat ${NODE_KOLLA_KEY}.pub")"
  [ -z "$pub" ] && { log_fail "impossibile leggere la chiave pubblica di ${DEPLOY_NODE}"; FAILURES=$((FAILURES+1)); return 1; }

  for n in "${ALL_NODES[@]}"; do          # SEMPRE tutti e 3 (kolla li tocca tutti)
    local ip="${NODE_IPS[$n]}"
    ssh_key "$ip" "bash -s" <<EOF >/dev/null 2>&1
mkdir -p /root/.ssh; chmod 700 /root/.ssh
grep -qF "${pub}" /root/.ssh/authorized_keys 2>/dev/null || echo "${pub}" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
EOF
    # verifica: node01 raggiunge n con la SUA chiave?
    if ssh_key "$dep_ip" "ssh ${SSH_OPTS[*]} -i ${NODE_KOLLA_KEY} root@${ip} 'echo OK'" 2>/dev/null | grep -q OK; then
      log_ok "${DEPLOY_NODE} -> $n: OK"
    else
      log_fail "${DEPLOY_NODE} -> $n: FALLITO"; FAILURES=$((FAILURES+1))
    fi
  done
}

# ------------------------- FASE 7: inventory (topologia) --------------------
generate_inventory() {
  log_step "FASE 7 — Inventory multinode dalla topologia"
  local ip="${NODE_IPS[$DEPLOY_NODE]}"
  # blocchi @@GROUP derivati dai ruoli (control/network/compute/storage/monitoring)
  local groups; groups="$(topo_emit_inventory)"
  # invia i blocchi e splicia nel template kolla, lasciando intatte le [*:children]
  printf '%s\n' "$groups" | ssh_key "$ip" "cat > /tmp/os_groups.txt"
  local out rc
  out="$(ssh_key "$ip" "VENV_PATH='${VENV_PATH}' bash -s" <<'ENDSSH' 2>&1
set -e
SRC="${VENV_PATH}/share/kolla-ansible/ansible/inventory/multinode"
[ -f "$SRC" ] || { echo "TEMPLATE_MANCANTE: $SRC"; exit 1; }
python3 - "$SRC" /etc/kolla/multinode /tmp/os_groups.txt <<'PY'
import sys
src, dst, gf = sys.argv[1:4]
blocks={}; cur=None
for line in open(gf):
    line=line.rstrip('\n')
    if line.startswith('@@GROUP '):
        cur=line.split(' ',1)[1].strip(); blocks[cur]=[]
    elif cur is not None and line.strip():
        blocks[cur].append(line)
lines=open(src).read().splitlines()
out,i=[],0
while i<len(lines):
    s=lines[i].strip()
    if s.startswith('[') and s.endswith(']') and s[1:-1] in blocks:
        g=s[1:-1]; out.append(lines[i]); out.extend(blocks[g]); out.append('')
        i+=1
        while i<len(lines) and not (lines[i].strip().startswith('[') and lines[i].strip().endswith(']')): i+=1
        continue
    out.append(lines[i]); i+=1
open(dst,'w').write('\n'.join(out)+'\n')
print("inventory scritto")
PY
echo "__INV_OK__"
ENDSSH
)"
  rc=$?
  if [ "$rc" -ne 0 ] || ! echo "$out" | grep -q "__INV_OK__"; then
    log_fail "generazione inventory fallita:"; echo "$out" | sed 's/^/      | /'
    FAILURES=$((FAILURES+1)); return 1
  fi
  log_ok "inventory /etc/kolla/multinode: control=${#CONTROL_NODES[@]} compute=${#COMPUTE_NODES[@]} storage=${#STORAGE_NODES[@]}"
}

# ------------------------- FASE 8: ansible.cfg ------------------------------
configure_ansible_cfg() {
  log_step "FASE 8 — /etc/ansible/ansible.cfg"
  local ip="${NODE_IPS[$DEPLOY_NODE]}"
  ssh_key "$ip" "bash -s" <<EOF >/dev/null 2>&1
mkdir -p /etc/ansible
cat > /etc/ansible/ansible.cfg <<CFG
[defaults]
host_key_checking = False
pipelining = True
forks = 100
private_key_file = ${NODE_KOLLA_KEY}

[ssh_connection]
ssh_args = -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
retries = 3
CFG
EOF
  log_ok "ansible.cfg scritto (chiave ${NODE_KOLLA_KEY}, forks 100)"
}

# ------------------------- FASE 9: verifica ---------------------------------
verify() {
  log_step "FASE 9 — Verifica (kolla-ansible + raggiungibilita' Ansible)"
  local ip="${NODE_IPS[$DEPLOY_NODE]}"
  local out
  out="$(ssh_key "$ip" "bash -s" <<EOF 2>&1
source ${VENV_PATH}/bin/activate
echo "--- versioni ---"
kolla-ansible --version 2>/dev/null | head -1
ansible --version 2>/dev/null | head -1
echo "--- ansible ping sui nodi (gruppo baremetal, no localhost) ---"
ansible -i /etc/kolla/multinode baremetal -m ping -o 2>&1 | grep -E "SUCCESS|UNREACHABLE|FAILED" || true
EOF
)"
  echo "$out" | sed 's/^/  /'
  local reached; reached="$(echo "$out" | grep -c "SUCCESS")"
  if [ "$reached" -eq "${#ALL_NODES[@]}" ]; then
    log_ok "Ansible raggiunge tutti e ${#ALL_NODES[@]} i nodi"
  else
    log_fail "Ansible raggiunge ${reached}/${#ALL_NODES[@]} nodi — controlla la chiave ${NODE_KOLLA_KEY}"
    FAILURES=$((FAILURES+1))
  fi
}

print_summary() {
  echo ""
  if [ "$FAILURES" -eq 0 ]; then
    cat <<EOF
+--------------------------------------------------------------+
   [OK] 01_prepare_nodes_3NODE completato
+--------------------------------------------------------------+
  Docker + Python       : su ${#ALL_NODES[@]} nodi (${ALL_NODES[*]})
  libvirt host          : neutralizzato (Kolla usa nova_libvirt in container)
  Kolla-Ansible ${KOLLA_VERSION}   : su ${DEPLOY_NODE} (${VENV_PATH})
  Inventory             : /etc/kolla/multinode (control=${#CONTROL_NODES[@]} compute=${#COMPUTE_NODES[@]} storage=${#STORAGE_NODES[@]})
  Chiave kolla          : ${NODE_KOLLA_KEY} (${DEPLOY_NODE} -> tutti)

  PROSSIMO PASSO: 01b_setup_ceph_3NODE.sh   (MON x3, OSD x7/nodo, public+cluster)
  poi:            02_deploy_openstack_3NODE.sh (globals: OVN + Barbican + Ceph)
EOF
  else
    cat <<EOF
+--------------------------------------------------------------+
   [FAIL] 01 incompleto — ${FAILURES} problema/i
+--------------------------------------------------------------+
  Cause tipiche:
    - Docker/pip falliti  -> egress (rilancia 00_bootstrap_baremetal.sh --verify-only)
    - ansible ping incompleto -> chiave ${NODE_KOLLA_KEY} non distribuita bene
  Correggi e rilancia (lo script e' idempotente).
EOF
  fi
}

main() {
  log_step "01 Preparazione nodi (Kolla ${KOLLA_VERSION})"
  topo_validate || { log_error "Topologia non valida (vedi lib_topology.sh)"; exit 1; }
  topo_summary
  phase_precheck
  install_docker
  install_python
  mask_host_libvirt
  # dalla fase 5 in poi si opera sul nodo deploy: ha senso solo su tutti i nodi
  if [ "${#NODES[@]}" -eq "${#ALL_NODES[@]}" ]; then
    setup_kolla
    distribute_node_key
    generate_inventory
    configure_ansible_cfg
    verify
  else
    log_warn "Esecuzione limitata a un nodo: salto setup Kolla/inventory (richiedono tutti i nodi)"
  fi
  print_summary
  [ "$FAILURES" -eq 0 ] || exit 1
}

main

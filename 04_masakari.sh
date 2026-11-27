#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Davide Marino
# SPDX-License-Identifier: GPL-3.0-or-later
## DAVE
# =============================================================================
# 04_masakari.sh — Masakari (Instance HA) — FASE A: rilevamento
#   ed evacuazione. Gira DALL'HOST di deploy. Topologia da lib_topology.sh.
#
#   ORDINE: 00 -> 01 -> 01b -> 02 -> 03 -> [ QUESTO ]
#
#   COSA FA
#     1. precheck: cluster sano, hostname corti (bug Masakari+Pacemaker con FQDN)
#     2. abilita enable_masakari nel globals.yml (il 02 non lo sovrascrive piu')
#     3. adatta l'inventory alla topologia:
#          - nodi control = compute (3 nodi, iperconvergenti): TUTTI membri pieni
#            del cluster Corosync/Pacemaker, [hacluster-remote] vuoto,
#            restrict_to_remotes=false nel monitor host
#          - control isolato dai compute (6/9 nodi): default Kolla
#            (compute = pacemaker-remote, restrict_to_remotes=true)
#     4. override: evacuate_all_instances / process_all_instances
#     5. kolla-ansible deploy --tags common,haproxy,hacluster,masakari
#     6. verifica: quorum Corosync, nodi online, container, API sul VIP
#     7. registra il segmento e gli host compute in Masakari
#     8. stima prudente della capacita' per assorbire il guasto di un nodo
#
#   FASE A = SENZA FENCING. Kolla non configura le credenziali IPMI in
#   Pacemaker e forza disable_ipmi_check=true: se un nodo e' solo ISOLATO in
#   rete (non spento) e Masakari evacua le sue VM, la stessa VM puo' girare due
#   volte sullo stesso disco RBD. Per questo sul FERRO (LAB_MODE=0) lo script
#   si rifiuta di procedere senza --accept-no-fencing. La Fase B (fence_ipmilan
#   sulla VLAN BMC) e' una procedura dedicata, mai testata su questo hardware.
#
#   USO
#     sudo LAB_MODE=1 bash 04_masakari.sh                  # deploy completo (lab)
#     sudo LAB_MODE=0 bash 04_masakari.sh --accept-no-fencing   # ferro, ambiente di test senza fencing
#     sudo bash 04_masakari.sh --config-only      # solo globals+inventory+override
#     sudo bash 04_masakari.sh --verify           # solo verifiche (read-only)
#     sudo bash 04_masakari.sh --register         # solo segmento+host
#     sudo bash 04_masakari.sh --test-instance    # kill qemu di una VM HA: riavvio automatico
#     sudo bash 04_masakari.sh --watch [nodo]     # osserva un test di guasto host (manuale)
#
#   VARIABILI (opzionali)
#     MASAKARI_SEGMENT=os-compute     nome del segmento
#     MASAKARI_RECOVERY=auto           auto | reserved_host | auto_priority | rh_priority
#     MASAKARI_PROTECT_ALL=yes         yes = tutte le VM; no = solo con metadata HA_Enabled=True
# =============================================================================
set -uo pipefail

# ============================ CONFIG ========================================
source "$(dirname "$0")/lib_topology.sh"

VENV_PATH="/opt/kolla-venv"
INVENTORY="/etc/kolla/multinode"
SEGMENT_NAME="${MASAKARI_SEGMENT:-os-compute}"
RECOVERY_METHOD="${MASAKARI_RECOVERY:-auto}"
PROTECT_ALL="${MASAKARI_PROTECT_ALL:-yes}"
TEST_NET_NAME="os-test-net"            # creata dal 03b (test funzionali)
TEST_FLAVOR="m1.tiny"
DEPLOY_TAGS="common,haproxy,hacluster,masakari"
DEPLOY_TIMEOUT=1800
MASAKARI_API_PORT=15868                 # masakari_api_port di Kolla

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}=== $* ===${NC}"; }
log_ok()    { echo -e "  ${GREEN}[OK]${NC} $*"; }
log_fail()  { echo -e "  ${RED}[FAIL]${NC} $*"; }

MODE="deploy"; ACCEPT_NOFENCE=0; WATCH_NODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config-only)        MODE="config" ;;
    --verify)             MODE="verify" ;;
    --register)           MODE="register" ;;
    --test-instance)      MODE="test-instance" ;;
    --watch)              MODE="watch"; if [ -n "${2:-}" ] && [ "${2#--}" = "$2" ]; then WATCH_NODE="$2"; shift; fi ;;
    --accept-no-fencing)  ACCEPT_NOFENCE=1 ;;
    --help|-h)            sed -n '2,45p' "$0"; exit 0 ;;
    *) log_error "Opzione sconosciuta: $1"; exit 1 ;;
  esac
  shift
done

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=30)
ssh_dep()  { ssh "${SSH_OPTS[@]}" -i "$DEPLOY_KEY" "root@${DEPLOY_NODE_IP}" "$@"; }
ssh_node() { local ip="$1"; shift; ssh "${SSH_OPTS[@]}" -i "$DEPLOY_KEY" "root@${ip}" "$@"; }
# openstack CLI sul nodo di deploy, con venv e credenziali admin
osc() { ssh_dep "source ${VENV_PATH}/bin/activate; source /root/admin-openrc.sh; $*"; }

# ------------------------- topologia -> modalita' ---------------------------
# iperconvergente = almeno un nodo e' sia control sia compute (caso dei 3 nodi)
topo_overlap() {
  local n
  for n in "${CONTROL_NODES[@]}"; do _in_array "$n" "${COMPUTE_NODES[@]}" && return 0; done
  return 1
}
if topo_overlap; then HA_MODE="hyperconverged"; else HA_MODE="isolated"; fi

# nodi su cui girano i container, per il controllo finale
hacluster_members() {  # membri pieni del cluster Corosync/Pacemaker
  printf '%s\n' "${CONTROL_NODES[@]}"
}
hacluster_remotes() {  # pacemaker-remote (solo con control isolato)
  [ "$HA_MODE" = isolated ] && printf '%s\n' "${COMPUTE_NODES[@]}"
}

# ------------------------- 0. Precheck --------------------------------------
precheck() {
  log_step "Precheck (modalita' ${HA_MODE})"

  # guardia sul ferro: niente fencing => niente Masakari "in produzione"
  if [ "${LAB_MODE:-0}" != 1 ] && [ "$ACCEPT_NOFENCE" != 1 ]; then
    log_error "Sul ferro Masakari parte senza fencing (STONITH): se un nodo e' solo isolato"
    log_error "in rete e non spento, le sue VM verrebbero avviate anche altrove."
    log_error "Per un ambiente di test accettando questo rischio:  --accept-no-fencing"
    log_error "Per produzione: prima la Fase B (fence_ipmilan sulla VLAN BMC)."
    exit 1
  fi
  [ "$ACCEPT_NOFENCE" = 1 ] && log_warn "Senza fencing: la Fase A NON protegge dallo split-brain (accettato con --accept-no-fencing)"

  ssh_dep "true" 2>/dev/null || { log_error "Nodo di deploy ${DEPLOY_NODE} (${DEPLOY_NODE_IP}) non raggiungibile"; exit 1; }
  ssh_dep "test -x ${VENV_PATH}/bin/kolla-ansible" || { log_error "kolla-ansible assente: esegui prima 01/02"; exit 1; }
  ssh_dep "test -f /root/admin-openrc.sh" || { log_error "admin-openrc.sh assente: esegui prima il 03"; exit 1; }
  ssh_dep "test -f /etc/kolla/globals.yml" || { log_error "globals.yml assente: esegui prima il 02"; exit 1; }

  # servizi compute tutti up
  local down
  down="$(osc "openstack compute service list --service nova-compute -f value -c Host -c State" 2>/dev/null | awk '$2!="up"{print $1}')"
  if [ -n "$down" ]; then log_error "nova-compute non up su: ${down//$'\n'/ }"; exit 1; fi
  log_ok "nova-compute up su tutti i compute"

  # hostname corti: Masakari+Pacemaker falliscono se Pacemaker usa il nome corto
  # e Nova/Masakari un FQDN (bug Kolla-Ansible #1959668). Il 02 impone i corti.
  local n hn bad=0
  for n in "${ALL_NODES[@]}"; do
    hn="$(ssh_node "$(mgmt_ip "$n")" "hostname" 2>/dev/null)"
    case "$hn" in
      *.*) log_fail "${n}: hostname '${hn}' contiene un punto (FQDN)"; bad=1 ;;
      "")  log_fail "${n}: hostname non leggibile"; bad=1 ;;
    esac
  done
  [ "$bad" = 0 ] || { log_error "Servono hostname corti su tutti i nodi (stessi del nome Nova)."; exit 1; }
  log_ok "hostname corti su tutti i nodi"

  # hypervisor Nova = nomi corti
  local hyp
  hyp="$(osc "openstack hypervisor list -f value -c 'Hypervisor Hostname'" 2>/dev/null)"
  if echo "$hyp" | grep -q '\.'; then
    log_error "Gli hypervisor Nova hanno nomi con punto: Masakari non li abbinerebbe agli host."
    echo "$hyp" | sed 's/^/    /'; exit 1
  fi
  log_ok "hypervisor Nova con nomi corti"
}

# ------------------------- 1. globals: enable_masakari ----------------------
set_globals_flag() {
  log_step "globals.yml: enable_masakari: yes"
  ssh_dep "grep -q '^enable_masakari:' /etc/kolla/globals.yml \
    && sed -i 's/^enable_masakari:.*/enable_masakari: \"yes\"/' /etc/kolla/globals.yml \
    || printf '%s\n' 'enable_masakari: \"yes\"' >> /etc/kolla/globals.yml"
  ssh_dep "grep -q '^enable_masakari: \"yes\"' /etc/kolla/globals.yml" \
    && log_ok "enable_masakari: yes (host/instance monitor e hacluster seguono il default Kolla)" \
    || { log_error "impossibile scrivere enable_masakari nel globals.yml"; exit 1; }
}

# ------------------------- 2. inventory -------------------------------------
# Kolla: [hacluster:children] = control, [hacluster-remote:children] = compute.
# Con nodi control=compute lo stesso host finirebbe in ENTRAMBI i gruppi
# (corosync + pacemaker-remote sulla stessa macchina): non funziona. Nel caso
# iperconvergente [hacluster-remote] va svuotato (tutti membri pieni).
patch_inventory() {
  log_step "Inventory: [hacluster-remote:children] per modalita' ${HA_MODE}"
  local res
  res="$(ssh_dep "python3 - '${INVENTORY}' '${HA_MODE}'" << 'PY'
import sys, shutil, os
path, mode = sys.argv[1:3]
lines = open(path).read().split('\n')
out = []; i = 0; found = False; changed = False
while i < len(lines):
    out.append(lines[i])
    if lines[i].strip() == '[hacluster-remote:children]':
        found = True
        j = i + 1; body = []
        while j < len(lines) and lines[j].strip() and not lines[j].startswith('['):
            body.append(lines[j]); j += 1
        want = [] if mode == 'hyperconverged' else ['compute']
        if [b.strip() for b in body] != want:
            changed = True
        out.extend(want)
        i = j
        continue
    i += 1
if not found:
    print('NOSECTION'); sys.exit(2)
if changed:
    bak = path + '.pre-masakari'
    if not os.path.exists(bak):
        shutil.copy(path, bak)
    open(path, 'w').write('\n'.join(out))
    print('CHANGED')
else:
    print('UNCHANGED')
PY
)"
  case "$res" in
    *UNCHANGED*) log_ok "inventory gia' corretto" ;;
    *CHANGED*)   log_ok "[hacluster-remote:children] aggiornato (copia: ${INVENTORY}.pre-masakari)" ;;
    *NOSECTION*) log_error "sezione [hacluster-remote:children] assente nell'inventory (template Kolla diverso?)"; exit 1 ;;
    *)           log_error "patch inventory fallita: ${res}"; exit 1 ;;
  esac
}

# ------------------------- 3. override --------------------------------------
generate_overrides() {
  log_step "Override Masakari (/etc/kolla/config)"
  local all_inst="true"; [ "$PROTECT_ALL" = "no" ] && all_inst="false"

  ssh_dep "mkdir -p /etc/kolla/config/masakari && cat > /etc/kolla/config/masakari.conf" << EOF
# GENERATO da 04_masakari.sh
[host_failure]
# true  = evacua TUTTE le VM del nodo guasto (prima quelle con HA_Enabled=True)
# false = evacua solo le VM con metadata HA_Enabled=True
evacuate_all_instances = ${all_inst}

[instance_failure]
# true  = riavvia qualunque VM che perde il processo qemu
# false = solo le VM con metadata HA_Enabled=True (default Masakari)
process_all_instances = ${all_inst}
EOF
  log_ok "masakari.conf: evacuate_all_instances=process_all_instances=${all_inst}"

  if [ "$HA_MODE" = hyperconverged ]; then
    # Kolla imposta restrict_to_remotes=true: il monitor guarderebbe SOLO i
    # pacemaker-remote. Qui non ce ne sono (tutti membri pieni): senza questo
    # override il host monitor non vedrebbe nessun nodo e non notificherebbe nulla.
    ssh_dep "cat > /etc/kolla/config/masakari/masakari-monitors.conf" << 'EOF'
# GENERATO da 04_masakari.sh — topologia iperconvergente (control = compute)
[host]
# false: monitora i membri pieni del cluster (via cibadmin), non i pacemaker-remote
restrict_to_remotes = false
# Fase A: nessun fencing configurato in Pacemaker -> controllo IPMI disattivo.
# Passare a false SOLO dopo la Fase B (fence_ipmilan verificato).
disable_ipmi_check = true
EOF
    log_ok "masakari-monitors.conf: restrict_to_remotes=false (nodi = membri pieni del cluster)"
  else
    # control isolato: valgono i default Kolla (compute = pacemaker-remote,
    # restrict_to_remotes=true). Se c'e' un override nostro precedente, via.
    ssh_dep "grep -q 'GENERATO da 04_masakari.sh' /etc/kolla/config/masakari/masakari-monitors.conf 2>/dev/null \
             && rm -f /etc/kolla/config/masakari/masakari-monitors.conf; true"
    log_ok "control isolato: default Kolla (compute = pacemaker-remote)"
  fi
}

# ------------------------- 4. password + client -----------------------------
ensure_passwords_and_client() {
  log_step "Password Masakari e client"
  if ! ssh_dep "grep -Eq '^masakari_keystone_password: *[^ ]+' /etc/kolla/passwords.yml"; then
    log_info "password masakari mancanti: kolla-genpwd (non tocca quelle esistenti)"
    ssh_dep "source ${VENV_PATH}/bin/activate; kolla-genpwd -p /etc/kolla/passwords.yml" >/dev/null 2>&1 || true
  fi
  ssh_dep "grep -Eq '^masakari_keystone_password: *[^ ]+' /etc/kolla/passwords.yml" \
    && log_ok "password masakari presenti" \
    || { log_error "masakari_keystone_password assente in passwords.yml"; return 1; }

  if ssh_dep "${VENV_PATH}/bin/pip show python-masakariclient >/dev/null 2>&1"; then
    log_ok "python-masakariclient gia' installato"
  else
    ssh_dep "${VENV_PATH}/bin/pip install -q python-masakariclient" >/dev/null 2>&1 \
      && log_ok "python-masakariclient installato nel venv Kolla" \
      || { log_error "installazione python-masakariclient fallita (egress pip?)"; return 1; }
  fi
}

# ------------------------- 5. deploy ----------------------------------------
run_deploy() {
  log_step "kolla-ansible deploy --tags ${DEPLOY_TAGS}"
  log_info "Aggiunge hacluster + masakari e ricarica HAProxy (porta ${MASAKARI_API_PORT}). Non tocca gli altri servizi."
  local log_file="/var/log/os-masakari-deploy.log" rc
  ssh_dep "source ${VENV_PATH}/bin/activate; timeout ${DEPLOY_TIMEOUT} kolla-ansible deploy -i ${INVENTORY} --configdir /etc/kolla --tags ${DEPLOY_TAGS} > ${log_file} 2>&1"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log_warn "primo tentativo fallito (rc=${rc}): riprovo una volta"
    ssh_dep "source ${VENV_PATH}/bin/activate; timeout ${DEPLOY_TIMEOUT} kolla-ansible deploy -i ${INVENTORY} --configdir /etc/kolla --tags ${DEPLOY_TAGS} > ${log_file}.retry 2>&1"
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    log_error "deploy Masakari fallito. Ultime righe:"
    ssh_dep "tail -25 ${log_file}.retry 2>/dev/null || tail -25 ${log_file}" | sed 's/^/    /'
    log_error "Log sul nodo di deploy: ${log_file}(.retry)"
    exit 1
  fi
  log_ok "deploy completato"
}

# ------------------------- 6. verifica --------------------------------------
verify() {
  log_step "Verifica Masakari + HAcluster"
  local fails=0 n ip out

  # container
  for n in $(hacluster_members); do
    ip="$(mgmt_ip "$n")"
    out="$(ssh_node "$ip" "docker ps --format '{{.Names}}'" 2>/dev/null)"
    for c in hacluster_corosync hacluster_pacemaker masakari_api masakari_engine masakari_hostmonitor; do
      echo "$out" | grep -qx "$c" || { log_fail "${n}: container ${c} assente"; fails=$((fails+1)); }
    done
  done
  for n in "${COMPUTE_NODES[@]}"; do
    ip="$(mgmt_ip "$n")"
    out="$(ssh_node "$ip" "docker ps --format '{{.Names}}'" 2>/dev/null)"
    echo "$out" | grep -qx masakari_instancemonitor || { log_fail "${n}: container masakari_instancemonitor assente"; fails=$((fails+1)); }
  done
  for n in $(hacluster_remotes); do
    ip="$(mgmt_ip "$n")"
    ssh_node "$ip" "docker ps --format '{{.Names}}'" 2>/dev/null | grep -qx hacluster_pacemaker_remote \
      || { log_fail "${n}: container hacluster_pacemaker_remote assente"; fails=$((fails+1)); }
  done
  [ "$fails" = 0 ] && log_ok "container attesi presenti"

  # quorum Corosync + nodi online
  local first; first="$(mgmt_ip "$(hacluster_members | head -1)")"
  out="$(ssh_node "$first" "docker exec hacluster_corosync corosync-quorumtool -s" 2>/dev/null)"
  if echo "$out" | grep -qE 'Quorate:[[:space:]]+Yes'; then
    log_ok "Corosync: quorum raggiunto ($(echo "$out" | awk '/Nodes:/{print $2}') nodi)"
  else
    log_fail "Corosync senza quorum"; echo "$out" | sed 's/^/    /'; fails=$((fails+1))
  fi
  out="$(ssh_node "$first" "docker exec hacluster_pacemaker crm_mon -1 -r" 2>/dev/null)"
  local want=${#CONTROL_NODES[@]}
  if echo "$out" | grep -E 'Online:' | grep -q .; then
    for n in "${CONTROL_NODES[@]}"; do
      echo "$out" | grep -E 'Online:' | grep -qw "$n" || { log_fail "Pacemaker: ${n} non online"; fails=$((fails+1)); }
    done
    [ "$fails" = 0 ] && log_ok "Pacemaker: ${want} membri online"
  else
    log_fail "crm_mon non leggibile"; fails=$((fails+1))
  fi
  for n in $(hacluster_remotes); do
    echo "$out" | grep -qE "RemoteOnline:.*\b${n}\b" || { log_fail "Pacemaker remote: ${n} non online"; fails=$((fails+1)); }
  done

  # API Masakari (sul VIP, dietro HAProxy)
  if ssh_dep "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://${VIP}:${MASAKARI_API_PORT}/" 2>/dev/null | grep -qE '^(200|300)'; then
    log_ok "API Masakari raggiungibile su ${VIP}:${MASAKARI_API_PORT}"
  else
    log_fail "API Masakari non risponde su ${VIP}:${MASAKARI_API_PORT} (HAProxy non ricaricato?)"
    log_info "  prova: kolla-ansible reconfigure -i ${INVENTORY} --tags haproxy"
    fails=$((fails+1))
  fi
  osc "openstack segment list" >/dev/null 2>&1 \
    && log_ok "openstack segment list risponde" \
    || { log_fail "openstack segment list fallisce (endpoint/keystone)"; fails=$((fails+1)); }

  # hostmonitor: la configurazione effettiva deve corrispondere alla modalita'
  local hm; hm="$(ssh_node "$first" "docker exec masakari_hostmonitor grep -E '^(restrict_to_remotes|pacemaker_node_type|disable_ipmi_check)' /etc/masakari-monitors/masakari-monitors.conf" 2>/dev/null)"
  if [ "$HA_MODE" = hyperconverged ]; then
    echo "$hm" | grep -qE 'restrict_to_remotes *= *[Ff]alse' \
      && log_ok "hostmonitor: restrict_to_remotes=false" \
      || { log_fail "hostmonitor ha restrict_to_remotes diverso da false: non vedrebbe nessun nodo"; fails=$((fails+1)); }
  else
    echo "$hm" | grep -qE 'restrict_to_remotes *= *[Tt]rue' \
      && log_ok "hostmonitor: restrict_to_remotes=true (compute = pacemaker-remote)" \
      || log_warn "hostmonitor: restrict_to_remotes non true (atteso con control isolato)"
  fi
  echo "$hm" | grep -qE 'disable_ipmi_check *= *[Tt]rue' \
    && log_warn "disable_ipmi_check=true: FENCING NON ATTIVO (Fase A)"

  if [ "$fails" = 0 ]; then log_ok "Masakari operativo"; return 0; fi
  log_error "${fails} verifiche fallite"; return 1
}

# ------------------------- 7. segmento + host -------------------------------
register_hosts() {
  log_step "Segmento '${SEGMENT_NAME}' e host compute"
  local seg_id n
  seg_id="$(osc "openstack segment list -f value -c uuid -c name" 2>/dev/null | awk -v s="$SEGMENT_NAME" '$2==s{print $1}')"
  if [ -z "$seg_id" ]; then
    seg_id="$(osc "openstack segment create ${SEGMENT_NAME} ${RECOVERY_METHOD} COMPUTE -f value -c uuid" 2>/dev/null | tail -1)"
    [ -n "$seg_id" ] && log_ok "segmento creato (${RECOVERY_METHOD}): ${seg_id}" \
                     || { log_error "creazione segmento fallita"; return 1; }
  else
    log_ok "segmento gia' presente: ${seg_id}"
  fi

  local present; present="$(osc "openstack segment host list ${seg_id} -f value -c name" 2>/dev/null)"
  for n in "${COMPUTE_NODES[@]}"; do
    if echo "$present" | grep -qx "$n"; then
      log_ok "host ${n} gia' nel segmento"
    else
      osc "openstack segment host create ${n} COMPUTE SSH ${seg_id}" >/dev/null 2>&1 \
        && log_ok "host ${n} registrato" \
        || { log_fail "registrazione host ${n} fallita (il nome deve coincidere con l'hypervisor Nova)"; return 1; }
    fi
  done
}

# ------------------------- 8. capacita' -------------------------------------
# Stima PRUDENTE, senza overcommit: per ogni nodo, la RAM delle VM che ospita
# (somma dei flavor) deve entrare nello spazio libero degli altri nodi
# (MemTotal - reserved_host_memory_mb - RAM delle loro VM).
# NB: non usa 'hypervisor list --long': nelle versioni recenti di OpenStack non
# riporta piu' la memoria (restituiva 0 e il controllo risultava sempre "OK").
capacity_check() {
  log_step "Capacita' per assorbire il guasto di un nodo (stima prudente)"
  local tmp nodes="" n ip tot res rc
  tmp="$(mktemp -d)"
  osc "openstack server list --all-projects --long -f json" > "$tmp/servers.json" 2>/dev/null
  osc "openstack flavor list --all -f json" > "$tmp/flavors.json" 2>/dev/null
  if [ ! -s "$tmp/servers.json" ] || [ ! -s "$tmp/flavors.json" ]; then
    log_warn "elenco VM/flavor non leggibile: stima di capacita' saltata"; rm -rf "$tmp"; return 0
  fi
  for n in "${COMPUTE_NODES[@]}"; do
    ip="$(mgmt_ip "$n")"
    tot="$(ssh_node "$ip" "awk '/^MemTotal/{print int(\$2/1024)}' /proc/meminfo" 2>/dev/null)"
    res="$(ssh_node "$ip" "docker exec nova_compute sh -c \"grep -E '^reserved_host_memory_mb' /etc/nova/nova.conf | tail -1 | cut -d= -f2 | tr -d ' '\"" 2>/dev/null)"
    nodes+="${n}:${tot:-0}:${res:-512} "
  done
  python3 -I - "$tmp/servers.json" "$tmp/flavors.json" "$nodes" << 'PY'
import json, sys
srv = json.load(open(sys.argv[1])); fl = json.load(open(sys.argv[2]))
by_name = {f["Name"]: int(f["RAM"]) for f in fl}
by_id = {str(f.get("ID")): int(f["RAM"]) for f in fl}
nodes = {}
for t in sys.argv[3].split():
    n, tot, res = t.split(":"); nodes[n] = [int(tot), int(res), 0]
unknown = 0
for s in srv:
    h = s.get("Host")
    if h not in nodes or s.get("Status") not in ("ACTIVE", "SHUTOFF", "PAUSED", "SUSPENDED"):
        continue
    r = by_id.get(str(s.get("Flavor ID"))) or by_name.get(s.get("Flavor"))
    if r is None: unknown += 1; continue
    nodes[h][2] += r
if all(v[0] == 0 for v in nodes.values()):
    print("  [WARN] memoria dei nodi non leggibile"); sys.exit(3)
bad = 0
for n, (tot, res, used) in nodes.items():
    free_others = sum(max(t - r, 0) - u for m, (t, r, u) in nodes.items() if m != n)
    ok = used <= free_others
    bad += (not ok)
    print("  [%s] %s: VM da evacuare ~%d MB, liberi sugli altri %d MB" % ("OK" if ok else "WARN", n, used, free_others))
if unknown:
    print("  [WARN] %d VM con flavor non riconosciuto: non conteggiate" % unknown)
sys.exit(1 if bad else 0)
PY
  rc=$?
  rm -rf "$tmp"
  case "$rc" in
    0) log_ok "ogni nodo e' assorbibile dagli altri (senza overcommit)" ;;
    1) log_warn "con il carico attuale non tutte le VM di un nodo rientrerebbero sugli altri" ;;
    *) log_warn "stima di capacita' non disponibile (dati mancanti): non e' un via libera" ;;
  esac
}

# ------------------------- 9. test: guasto di istanza -----------------------
# Uccide il processo qemu di una VM protetta: l'instance monitor lo rileva,
# Masakari ferma e riavvia la VM. Non tocca il nodo ne' gli altri servizi.
test_instance() {
  log_step "Test Fase A — guasto di istanza (kill qemu) -> riavvio automatico"
  osc "openstack segment list -f value -c name" 2>/dev/null | grep -qx "$SEGMENT_NAME" \
    || { log_error "segmento assente: lancia prima il deploy o --register"; return 1; }
  osc "openstack image show cirros >/dev/null 2>&1 && openstack network show ${TEST_NET_NAME} >/dev/null 2>&1" \
    || { log_error "servono immagine 'cirros' e rete '${TEST_NET_NAME}' (le crea il 03b del pacchetto test funzionali; oppure vanno create a mano)"; return 1; }

  local vm="os-ha-test" host inst nbefore nafter st i
  osc "openstack server delete --wait ${vm}" >/dev/null 2>&1
  if ! osc "openstack server create --image cirros --flavor ${TEST_FLAVOR} --network ${TEST_NET_NAME} --property HA_Enabled=True --wait ${vm}" >/dev/null 2>&1; then
    log_error "creazione della VM di test fallita"; return 1
  fi
  host="$(osc "openstack server show ${vm} -f value -c OS-EXT-SRV-ATTR:host" 2>/dev/null | tail -1)"
  inst="$(osc "openstack server show ${vm} -f value -c OS-EXT-SRV-ATTR:instance_name" 2>/dev/null | tail -1)"
  log_info "VM ${vm} su ${host} (${inst})"
  [ -n "${NODE_MGMT_IP[$host]:-}" ] || { log_error "host '${host}' non in topologia"; osc "openstack server delete ${vm}" >/dev/null 2>&1; return 1; }

  nbefore="$(osc "openstack notification list -f value" 2>/dev/null | grep -c .)"
  # la parentesi quadra nel pattern evita che pkill -f uccida la propria shell
  if ! ssh_node "$(mgmt_ip "$host")" "pkill -9 -f '[g]uest=${inst},'" >/dev/null 2>&1; then
    log_error "processo qemu di ${inst} non trovato su ${host}"
    osc "openstack server delete ${vm}" >/dev/null 2>&1; return 1
  fi
  log_info "qemu di ${inst} terminato: attendo rilevamento e recupero (max 5 min)"

  for i in $(seq 1 60); do
    sleep 5
    nafter="$(osc "openstack notification list -f value" 2>/dev/null | grep -c .)"
    st="$(osc "openstack server show ${vm} -f value -c status" 2>/dev/null | tail -1)"
    if [ "${nafter:-0}" -gt "${nbefore:-0}" ] && [ "$st" = ACTIVE ] && [ "$i" -gt 2 ]; then
      log_ok "notifica registrata e VM di nuovo ACTIVE dopo ~$((i*5))s (OS_MASAKARI_VM_OK)"
      osc "openstack notification list -f value" 2>/dev/null | tail -1 | sed 's/^/    ultima notifica: /'
      osc "openstack server delete --wait ${vm}" >/dev/null 2>&1
      return 0
    fi
  done
  log_fail "nessun recupero entro 5 minuti (OS_MASAKARI_VM_FAIL): stato VM=${st:-?}, notifiche ${nbefore}->${nafter:-?}"
  log_info "  controlla: docker logs masakari_instancemonitor (su ${host}) e docker logs masakari_engine"
  osc "openstack server delete ${vm}" >/dev/null 2>&1
  return 1
}

# ------------------------- 10. test guasto host: guida + osservazione -------
watch_host_failure() {
  local target="${WATCH_NODE:-}"
  log_step "Test Fase A — guasto di un nodo compute (procedura manuale guidata)"
  if [ -z "$target" ]; then
    local c
    for c in "${COMPUTE_NODES[@]}"; do [ "$c" != "$DEPLOY_NODE" ] && { target="$c"; break; }; done
  fi
  [ "$target" = "$DEPLOY_NODE" ] && { log_error "Non spegnere ${DEPLOY_NODE}: e' il nodo di deploy (Kolla, cephadm, questo script)."; return 1; }
  _in_array "$target" "${COMPUTE_NODES[@]}" || { log_error "'${target}' non e' un compute della topologia"; return 1; }

  cat << EOF

  PROCEDURA (nodo bersaglio: ${target})
   1. Crea una VM protetta sul nodo bersaglio:
        openstack server create --image cirros --flavor ${TEST_FLAVOR} \\
          --network ${TEST_NET_NAME} --property HA_Enabled=True \\
          --availability-zone nova:${target} --wait os-ha-host
   2. Lancia questa osservazione in un secondo terminale:
        sudo bash 04_masakari.sh --watch ${target}
   3. SPEGNI ${target} (spegnimento brusco, non shutdown pulito):
        lab KVM:    virsh destroy ${target}
        lab VMware: Power Off dalla console della VM
   4. Attesi, nell'ordine: nodo OFFLINE in Pacemaker -> notifica COMPUTE_HOST ->
      nova-compute disabilitato -> evacuazione della VM su un altro nodo.

  ATTENZIONE: con 3 nodi iperconvergenti lo spegnimento toglie anche un membro di
  Galera, RabbitMQ, Ceph (MON+OSD) e del cluster Corosync. Restano tutti in quorum
  (2 su 3) ma degradati; riaccendi il nodo a fine test e attendi HEALTH_OK.
  Nel lab senza fencing questo e' lo spegnimento VERO, quindi non c'e' rischio di
  doppia scrittura: e' il caso "pulito". Il caso "isolato ma vivo" NON e' coperto.

EOF
  log_info "Osservazione per ${target} (Ctrl+C per uscire; timeout 15 min)"
  local start now first; first="$(mgmt_ip "$DEPLOY_NODE")"
  start=$(date +%s)
  while :; do
    now=$(date +%s); [ $((now-start)) -gt 900 ] && { log_warn "timeout osservazione"; return 1; }
    echo "--- $(date +%H:%M:%S) ---"
    ssh_node "$first" "docker exec hacluster_pacemaker crm_mon -1 2>/dev/null | grep -E 'Online|OFFLINE|Offline|RemoteOnline'" 2>/dev/null | sed 's/^/  pacemaker: /'
    osc "openstack notification list -f value 2>/dev/null | tail -3" | sed 's/^/  notifiche: /'
    osc "openstack server list --all-projects --long -f value -c Name -c Status -c Host 2>/dev/null" | sed 's/^/  vm: /'
    sleep 15
  done
}

# ------------------------- riepilogo ----------------------------------------
print_summary() {
  cat << EOF

============================================================
  [OK] 04_masakari completato  (modalita' ${HA_MODE})
============================================================
  Segmento      : ${SEGMENT_NAME} (${RECOVERY_METHOD}) — host: ${COMPUTE_NODES[*]}
  Protezione VM : $( [ "$PROTECT_ALL" = no ] && echo "solo VM con metadata HA_Enabled=True" || echo "tutte le VM" )
  FENCING       : NON ATTIVO (Fase A). Non e' protezione da split-brain.

  Prossimi passi:
    sudo bash 04_masakari.sh --test-instance      # guasto di istanza (automatico)
    sudo bash 04_masakari.sh --watch              # guasto di nodo (guidato)
  Fase B (fencing reale su BMC, VLAN 99): procedura dedicata, solo sul ferro.
EOF
}

# ------------------------- main ---------------------------------------------
main() {
  log_step "04 Masakari (Fase A: rilevamento + evacuazione)"
  topo_validate || { log_error "Topologia non valida (lib_topology.sh)"; exit 1; }
  topo_summary
  case "$MODE" in
    verify)         precheck; verify; exit $? ;;
    register)       precheck; register_hosts; exit $? ;;
    test-instance)  test_instance; exit $? ;;
    watch)          watch_host_failure; exit $? ;;
  esac
  precheck
  set_globals_flag
  patch_inventory
  generate_overrides
  if [ "$MODE" = config ]; then
    log_warn "--config-only: generati globals, inventory e override, mi fermo qui."
    exit 0
  fi
  ensure_passwords_and_client || exit 1
  run_deploy
  verify || exit 1
  register_hosts || exit 1
  capacity_check
  print_summary
}

main
## DAVE

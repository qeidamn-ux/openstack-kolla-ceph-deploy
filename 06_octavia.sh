#!/usr/bin/env bash
## DAVE
# =============================================================================
# 06_octavia.sh — Octavia (LBaaS) con SOLO provider OVN, su un cloud gia' in
#   esercizio. Gira DALL'HOST di deploy. Topologia da lib_topology.sh.
#
#   ORDINE: 00 -> 01 -> 01b -> 02 -> 03 -> [03b] -> [04] -> [ QUESTO ]
#
#   PERCHE' SOLO OVN
#     Il provider OVN bilancia in modo distribuito dentro OVN (nessuna VM
#     amphora): niente rete lb-mgmt, VLAN dedicata, immagine, flavor,
#     certificati o jobboard. Limiti: solo L4 (TCP/UDP/SCTP), algoritmo
#     SOURCE_IP_PORT, niente listener HTTP/L7 ne' terminazione TLS, health
#     monitor solo TCP/UDP-CONNECT. Per L7/TLS servono le amphora (fuori scope).
#
#   COSA FA
#     1. precheck: deploy node, venv, openrc, globals con neutron_plugin_agent ovn
#     2. password octavia_* presenti in passwords.yml (non le genera: vedi sotto)
#     3. globals.yml: enable_octavia yes + driver/agent solo OVN
#        (il 02 conserva questi valori ai rilanci: octavia_flag)
#     4. override /etc/kolla/config/octavia.conf: default_provider_driver = ovn
#        (Kolla non lo imposta: senza, un 'loadbalancer create' senza --provider
#        cerca 'amphora', che non e' abilitato, e fallisce)
#     5. kolla-ansible deploy --tags common,haproxy,horizon,octavia[,skyline]
#     6. python-octaviaclient nel venv Kolla
#     7. verifica: container, API sul VIP, provider list, provider di default
#     8. prova: LB + listener TCP + pool su os-test-net (creata dal 03b), poi
#        cancellato. Saltata se la rete non esiste.
#
#   USO
#     sudo bash 06_octavia.sh                 # configurazione + deploy + verifica + prova
#     sudo bash 06_octavia.sh --config-only   # solo globals + override, nessun deploy
#     sudo bash 06_octavia.sh --verify        # solo verifiche (read-only)
#     sudo bash 06_octavia.sh --test-lb       # solo la prova LB (crea e cancella)
#
#   VARIABILI (opzionali)
#     OCTAVIA_TEST_NET=os-test-net    rete tenant su cui creare il LB di prova
# =============================================================================
set -uo pipefail

# ============================ CONFIG ========================================
source "$(dirname "$0")/lib_topology.sh"

VENV_PATH="/opt/kolla-venv"
INVENTORY="/etc/kolla/multinode"
GLOBALS="/etc/kolla/globals.yml"
OVERRIDE="/etc/kolla/config/octavia.conf"
TEST_NET_NAME="${OCTAVIA_TEST_NET:-os-test-net}"   # creata dal 03b (test funzionali)
TEST_LB="os-lb-test"
DEPLOY_TIMEOUT=1800
OCTAVIA_API_PORT=9876                   # octavia_api_port di Kolla
# chiavi che Kolla usa per DB e utente Keystone di Octavia
REQUIRED_PASSWORDS="octavia_database_password octavia_keystone_password"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}=== $* ===${NC}"; }
log_ok()    { echo -e "  ${GREEN}[OK]${NC} $*"; }
log_fail()  { echo -e "  ${RED}[FAIL]${NC} $*"; }

MODE="deploy"
while [ $# -gt 0 ]; do
  case "$1" in
    --config-only) MODE="config" ;;
    --verify)      MODE="verify" ;;
    --test-lb)     MODE="test-lb" ;;
    --help|-h)     sed -n '2,39p' "$0"; exit 0 ;;
    *) log_error "Opzione sconosciuta: $1"; exit 1 ;;
  esac
  shift
done

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=30)
ssh_dep()  { ssh "${SSH_OPTS[@]}" -i "$DEPLOY_KEY" "root@${DEPLOY_NODE_IP}" "$@"; }
ssh_node() { local ip="$1"; shift; ssh "${SSH_OPTS[@]}" -i "$DEPLOY_KEY" "root@${ip}" "$@"; }
# openstack CLI sul nodo di deploy, con venv e credenziali admin
osc() { ssh_dep "source ${VENV_PATH}/bin/activate; source /root/admin-openrc.sh; $*"; }

# tag del deploy: skyline solo se attivo (il suo template elenca load-balancer
# solo con enable_octavia yes, quindi va riconfigurato anche lui)
deploy_tags() {
  local t="common,haproxy,horizon,octavia"
  ssh_dep "grep -Eq '^enable_skyline: *\"yes\"' ${GLOBALS}" </dev/null 2>/dev/null && t="${t},skyline"
  echo "$t"
}

# ------------------------- 0. Precheck --------------------------------------
precheck() {
  log_step "Precheck"
  ssh_dep "true" 2>/dev/null || { log_error "Nodo di deploy ${DEPLOY_NODE} (${DEPLOY_NODE_IP}) non raggiungibile"; exit 1; }
  ssh_dep "test -x ${VENV_PATH}/bin/kolla-ansible" || { log_error "kolla-ansible assente: esegui prima 01/02"; exit 1; }
  ssh_dep "test -f /root/admin-openrc.sh" || { log_error "admin-openrc.sh assente: esegui prima il 03"; exit 1; }
  ssh_dep "test -f ${GLOBALS}" || { log_error "globals.yml assente: esegui prima il 02"; exit 1; }
  ssh_dep "grep -Eq '^neutron_plugin_agent: *\"ovn\"' ${GLOBALS}" \
    || { log_error "neutron_plugin_agent non e' ovn: il provider OVN di Octavia richiede Neutron/OVN"; exit 1; }
  log_ok "globals.yml presente, Neutron su OVN"
  osc "openstack token issue -f value -c id" >/dev/null 2>&1 \
    || { log_error "Keystone non risponde con le credenziali admin: cloud non sano, non procedo"; exit 1; }
  log_ok "API Keystone raggiungibili"
}

# ------------------------- 1. password --------------------------------------
# kolla-genpwd valorizza solo le chiavi PRESENTI e vuote: non aggiunge chiavi
# mancanti. Il passwords.yml viene dal template della stessa kolla-ansible (01),
# quindi le chiavi octavia_* ci sono gia'. Se mancano, va usato kolla-mergepwd.
check_passwords() {
  log_step "Password Octavia in passwords.yml"
  local k miss=""
  for k in $REQUIRED_PASSWORDS; do
    ssh_dep "grep -Eq '^${k}: *[^ ]+' /etc/kolla/passwords.yml" || miss="${miss} ${k}"
  done
  if [ -z "$miss" ]; then log_ok "password octavia presenti"; return 0; fi
  log_error "password mancanti o vuote:${miss}"
  log_error "Se la chiave e' presente ma vuota (sul nodo di deploy):"
  log_error "  sudo bash -c 'source ${VENV_PATH}/bin/activate; kolla-genpwd -p /etc/kolla/passwords.yml'"
  log_error "Se la chiave manca del tutto, fondere con il template (backup prima):"
  log_error "  sudo cp /etc/kolla/passwords.yml /etc/kolla/passwords.yml.bak-\$(date +%F)"
  log_error "  sudo bash -c 'source ${VENV_PATH}/bin/activate; cp ${VENV_PATH}/share/kolla-ansible/etc_examples/kolla/passwords.yml /tmp/pw.new && kolla-genpwd -p /tmp/pw.new && kolla-mergepwd --old /etc/kolla/passwords.yml --new /tmp/pw.new --final /etc/kolla/passwords.yml'"
  return 1
}

# ------------------------- 2. globals ----------------------------------------
# imposta (o aggiunge) una chiave nel globals.yml con valore fra virgolette
set_globals_kv() {
  local key="$1" val="$2"
  ssh_dep "K='${key}' V='${val}' F='${GLOBALS}' bash -s" <<'ENDSSH'
if grep -q "^${K}:" "$F"; then
  sed -i "s|^${K}:.*|${K}: \"${V}\"|" "$F"
else
  printf '%s: "%s"\n' "$K" "$V" >> "$F"
fi
grep -qx "${K}: \"${V}\"" "$F"
ENDSSH
}

set_globals() {
  log_step "globals.yml: Octavia con provider OVN"
  set_globals_kv octavia_provider_drivers "ovn:OVN provider" \
    && set_globals_kv octavia_provider_agents "ovn" \
    && set_globals_kv enable_octavia "yes" \
    || { log_error "impossibile scrivere le chiavi Octavia nel globals.yml"; exit 1; }
  ssh_dep "grep -E '^octavia_provider_drivers:' ${GLOBALS}" | grep -q amphora \
    && { log_error "octavia_provider_drivers contiene ancora amphora"; exit 1; }
  log_ok "enable_octavia: yes, driver e agent solo ovn (il 02 li conserva)"
}

# ------------------------- 3. override octavia.conf --------------------------
# Kolla scrive solo enabled_provider_drivers; il default di Octavia resta
# 'amphora'. L'override non viene toccato dal 02 (come neutron.conf).
generate_override() {
  log_step "Override ${OVERRIDE}: provider di default ovn"
  if ssh_dep "test -s ${OVERRIDE}"; then
    if ssh_dep "grep -Eq '^default_provider_driver *= *ovn *$' ${OVERRIDE}"; then
      log_ok "override gia' presente"; return 0
    fi
    log_error "${OVERRIDE} esiste gia' con altro contenuto: aggiungere a mano"
    log_error "  [api_settings]"
    log_error "  default_provider_driver = ovn"
    exit 1
  fi
  ssh_dep "mkdir -p /etc/kolla/config && cat > ${OVERRIDE}" << 'EOF'
# GENERATO da 06_octavia.sh — provider OVN unico (nessuna amphora)
[api_settings]
default_provider_driver = ovn
EOF
  ssh_dep "grep -Eq '^default_provider_driver *= *ovn' ${OVERRIDE}" \
    && log_ok "override scritto" || { log_error "scrittura override fallita"; exit 1; }
}

# ------------------------- 4. deploy ----------------------------------------
run_deploy() {
  local tags; tags="$(deploy_tags)"
  log_step "kolla-ansible deploy --tags ${tags}"
  log_info "Crea DB, utente ed endpoint Octavia, i container e la voce HAProxy (porta ${OCTAVIA_API_PORT})."
  local log_file="/var/log/os-octavia-deploy.log" rc
  ssh_dep "source ${VENV_PATH}/bin/activate; timeout ${DEPLOY_TIMEOUT} kolla-ansible deploy -i ${INVENTORY} --configdir /etc/kolla --tags ${tags} > ${log_file} 2>&1"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log_warn "primo tentativo fallito (rc=${rc}): riprovo una volta"
    ssh_dep "source ${VENV_PATH}/bin/activate; timeout ${DEPLOY_TIMEOUT} kolla-ansible deploy -i ${INVENTORY} --configdir /etc/kolla --tags ${tags} > ${log_file}.retry 2>&1"
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    log_error "deploy Octavia fallito. Ultime righe:"
    ssh_dep "tail -25 ${log_file}.retry 2>/dev/null || tail -25 ${log_file}" | sed 's/^/    /'
    log_error "Log sul nodo di deploy: ${log_file}(.retry)"
    exit 1
  fi
  log_ok "deploy completato"
}

# ------------------------- 5. client ----------------------------------------
ensure_client() {
  log_step "python-octaviaclient"
  if ssh_dep "${VENV_PATH}/bin/pip show python-octaviaclient >/dev/null 2>&1"; then
    log_ok "python-octaviaclient gia' installato"
  else
    ssh_dep "${VENV_PATH}/bin/pip install -q python-octaviaclient" >/dev/null 2>&1 \
      && log_ok "python-octaviaclient installato nel venv Kolla" \
      || { log_error "installazione python-octaviaclient fallita (egress pip? proxy?)"; return 1; }
  fi
}

# ------------------------- 6. verifica --------------------------------------
verify() {
  log_step "Verifica Octavia (provider OVN)"
  local fails=0 n ip out c

  for n in "${CONTROL_NODES[@]}"; do
    ip="$(mgmt_ip "$n")"
    out="$(ssh_node "$ip" "docker ps --format '{{.Names}}'" 2>/dev/null)"
    for c in octavia_api octavia_driver_agent; do
      echo "$out" | grep -qx "$c" || { log_fail "${n}: container ${c} assente"; fails=$((fails+1)); }
    done
  done
  [ "$fails" = 0 ] && log_ok "octavia_api e octavia_driver_agent su ${CONTROL_NODES[*]}"

  # provider di default dentro il container (override applicato?)
  ip="$(mgmt_ip "${CONTROL_NODES[0]}")"
  if ssh_node "$ip" "docker exec octavia_api grep -Eq '^default_provider_driver *= *ovn' /etc/octavia/octavia.conf" 2>/dev/null; then
    log_ok "octavia.conf: default_provider_driver = ovn"
  else
    log_fail "octavia.conf senza default_provider_driver = ovn (override non applicato?)"; fails=$((fails+1))
  fi

  # API sul VIP, dietro HAProxy
  if ssh_dep "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://${VIP}:${OCTAVIA_API_PORT}/" 2>/dev/null | grep -qE '^(200|300)'; then
    log_ok "API Octavia raggiungibile su ${VIP}:${OCTAVIA_API_PORT}"
  else
    log_fail "API Octavia non risponde su ${VIP}:${OCTAVIA_API_PORT} (HAProxy non ricaricato?)"
    log_info "  prova: kolla-ansible reconfigure -i ${INVENTORY} --tags haproxy"
    fails=$((fails+1))
  fi

  out="$(osc "openstack loadbalancer provider list -f value -c name" 2>/dev/null)"
  if echo "$out" | grep -qx ovn; then
    log_ok "provider ovn abilitato"
  else
    log_fail "provider ovn assente in 'loadbalancer provider list' (client installato?)"; fails=$((fails+1))
  fi
  echo "$out" | grep -qx amphora && { log_fail "provider amphora abilitato: non previsto"; fails=$((fails+1)); }

  if [ "$fails" = 0 ]; then log_ok "Octavia operativo"; return 0; fi
  log_error "${fails} verifiche fallite"; return 1
}

# ------------------------- 7. prova LB --------------------------------------
# rc: 0 ok, 1 fallita, 2 saltata (rete di prova assente)
test_lb() {
  log_step "Prova: load balancer TCP su ${TEST_NET_NAME} (creato e cancellato)"
  local sub st
  sub="$(osc "openstack subnet list --network ${TEST_NET_NAME} -f value -c ID" 2>/dev/null | head -1)"
  if [ -z "$sub" ]; then
    log_warn "rete '${TEST_NET_NAME}' assente (la crea il 03b): prova saltata"
    return 2
  fi
  osc "openstack loadbalancer delete --cascade --wait ${TEST_LB}" >/dev/null 2>&1
  if ! osc "openstack loadbalancer create --name ${TEST_LB} --vip-subnet-id ${sub} --wait" >/dev/null 2>&1; then
    log_fail "creazione del load balancer fallita"
    osc "openstack loadbalancer delete --cascade ${TEST_LB}" >/dev/null 2>&1
    return 1
  fi
  st="$(osc "openstack loadbalancer show ${TEST_LB} -f value -c provider -c provisioning_status" 2>/dev/null | tr '\n' ' ')"
  case "$st" in
    *ovn*ACTIVE*|*ACTIVE*ovn*) log_ok "LB creato senza --provider: provider ovn, ACTIVE" ;;
    *) log_fail "LB in stato inatteso: ${st}"; osc "openstack loadbalancer delete --cascade ${TEST_LB}" >/dev/null 2>&1; return 1 ;;
  esac
  if osc "openstack loadbalancer listener create --name ${TEST_LB}-l1 --protocol TCP --protocol-port 80 --wait ${TEST_LB}" >/dev/null 2>&1 \
     && osc "openstack loadbalancer pool create --name ${TEST_LB}-p1 --listener ${TEST_LB}-l1 --protocol TCP --lb-algorithm SOURCE_IP_PORT --wait" >/dev/null 2>&1; then
    log_ok "listener TCP e pool SOURCE_IP_PORT creati (OS_OCTAVIA_LB_OK)"
  else
    log_fail "listener o pool non creati (OS_OCTAVIA_LB_FAIL)"
    osc "openstack loadbalancer delete --cascade ${TEST_LB}" >/dev/null 2>&1
    return 1
  fi
  osc "openstack loadbalancer delete --cascade --wait ${TEST_LB}" >/dev/null 2>&1 \
    && log_ok "LB di prova cancellato" || log_warn "cancellazione LB di prova non confermata: openstack loadbalancer delete --cascade ${TEST_LB}"
  return 0
}

# ------------------------- riepilogo ----------------------------------------
print_summary() {
  cat << EOF

============================================================
  [OK] 06_octavia completato  (provider OVN)
============================================================
  API           : http://${VIP}:${OCTAVIA_API_PORT}  (openstack loadbalancer ...)
  Provider      : ovn (unico, di default). Nessuna amphora.
  Limiti        : solo L4 TCP/UDP/SCTP, algoritmo SOURCE_IP_PORT,
                  niente HTTP/L7 ne' terminazione TLS.
  Rilanci del 02: enable_octavia resta yes; l'override octavia.conf resta.

  Prossimi passi:
    sudo bash 06_octavia.sh --verify
    sudo bash 06_octavia.sh --test-lb
EOF
}

# ------------------------- main ---------------------------------------------
main() {
  log_step "06 Octavia (provider OVN)"
  topo_validate || { log_error "Topologia non valida (lib_topology.sh)"; exit 1; }
  topo_summary
  case "$MODE" in
    verify)   precheck; verify; exit $? ;;
    test-lb)  precheck; test_lb; rc=$?; [ "$rc" = 2 ] && exit 0; exit "$rc" ;;
  esac
  precheck
  check_passwords || exit 1
  set_globals
  generate_override
  if [ "$MODE" = config ]; then
    log_warn "--config-only: scritti globals e override, nessun deploy."
    exit 0
  fi
  run_deploy
  ensure_client || exit 1
  verify || exit 1
  test_lb; [ $? = 1 ] && exit 1
  print_summary
}

main
## DAVE

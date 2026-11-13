#!/usr/bin/env bash
# =============================================================================
# 03_configure_openstack_3NODE.sh — Post-deploy: configurazione del cloud.
#   Gira DALL'HOST di deploy. Topologia da lib_topology.sh.
#
#   ORDINE: 00 -> 01 -> 01b -> 02 -> [ QUESTO ] -> (04 opzionale)
#
#   Cosa fa:
#     1. openrc (kolla-ansible post-deploy) + client OpenStack nel venv
#     2. rete external/provider (flat, physnet1) — SOLO configurazione:
#        per impostazione di progetto i floating IP NON escono su internet
#     3. progetto demo, flavor, keypair, regole del security group di default
#     4. riepilogo con gli indirizzi di accesso
#
#   Le VERIFICHE FUNZIONALI (HA, servizi, OVN, Ceph, Barbican, Skyline, smoke test
#   East-West, volume Ceph) NON stanno piu' qui: sono nel pacchetto "test
#   funzionali" (03b_functional_tests_3NODE.sh), da lanciare dopo questo.
#
#   NB: con OVN NON si configura br-ex a mano (lo fa Kolla via ovn-bridge-mappings).
#
#   USO:
#     sudo bash 03_configure_openstack_3NODE.sh
# =============================================================================
set -uo pipefail

# ============================ CONFIG ========================================
source "$(dirname "$0")/lib_topology.sh"
## DAVE
# Password dell'utente 'demo'. Il default e' SOLO da laboratorio: sul campo si imposta in secrets.conf
# (accanto agli script, chmod 600; modello: secrets.conf.example).
DEMO_PASS="demo"
SECRETS_CONF="${SECRETS_CONF:-$(cd "$(dirname "$0")" && pwd)/secrets.conf}"
[ -f "$SECRETS_CONF" ] && source "$SECRETS_CONF"
# Le password finiscono dentro comandi shell e YAML: niente apici, virgolette, backslash, $, backtick,
# spazi; almeno 8 caratteri.
secret_ok() { [ "${#1}" -ge 8 ] && case "$1" in *[\'\"\\\$\`\ ]*) return 1 ;; esac; }
if [ "$DEMO_PASS" != "demo" ] && ! secret_ok "$DEMO_PASS"; then
  echo "ERRORE: DEMO_PASS non valida (almeno 8 caratteri, senza apici, virgolette, backslash, \$, backtick, spazi). Controlla ${SECRETS_CONF}." >&2; exit 1
fi
## DAVE

## DAVE
# --- rete EXTERNAL/PROVIDER ---------------------------------------------------
# La subnet pubblica, il gateway e il pool di floating IP NON si ricavano dai nodi:
# li fornisce il referente di rete. Si impostano con configura_topologia.sh (che li scrive
# in topology.conf) oppure da ambiente. Se NON sono tutti definiti la rete external
# non viene creata e lo script lo segnala: nessun valore di ripiego.
EXT_NET_NAME="${EXT_NET_NAME:-provider-ext}"
EXT_SUBNET_CIDR="${EXT_SUBNET_CIDR:-}"
EXT_GATEWAY="${EXT_GATEWAY:-}"
EXT_FIP_START="${EXT_FIP_START:-}"
EXT_FIP_END="${EXT_FIP_END:-}"
EXT_DNS="${EXT_DNS:-${DNS_SERVERS%%,*}}"; EXT_DNS="${EXT_DNS:-8.8.8.8}"
ext_defined() { [ -n "$EXT_SUBNET_CIDR" ] && [ -n "$EXT_GATEWAY" ] && [ -n "$EXT_FIP_START" ] && [ -n "$EXT_FIP_END" ]; }
## DAVE

# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}=== $* ===${NC}"; }
log_ok()    { echo -e "  ${GREEN}[OK]${NC} $*"; }
log_fail()  { echo -e "  ${RED}[FAIL]${NC} $*"; }

for arg in "$@"; do
  case "$arg" in
    --help|-h)  sed -n '2,23p' "$0"; exit 0 ;;
    *) log_error "Opzione sconosciuta: $arg"; exit 1 ;;
  esac
done

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=30)
ssh_dep()  { ssh "${SSH_OPTS[@]}" -i "$DEPLOY_KEY" "root@${DEPLOY_NODE_IP}" "$@"; }
ssh_node() { local ip="$1"; shift; ssh "${SSH_OPTS[@]}" -i "$DEPLOY_KEY" "root@${ip}" "$@"; }

# ------------------------- 0. Precheck --------------------------------------
precheck() {
  log_step "Precheck (02 deve aver deployato)"
  ssh_dep true >/dev/null 2>&1 || { log_error "${DEPLOY_NODE} irraggiungibile."; exit 1; }
  ssh_dep "test -f /etc/kolla/globals.yml" || { log_error "globals.yml assente: esegui il 02."; exit 1; }
  log_ok "nodo di deploy raggiungibile"
}

# ------------------------- 1. openrc + client -------------------------------
generate_openrc() {
  log_step "openrc (kolla-ansible post-deploy) + client OpenStack"
  local out
  out="$(ssh_dep bash << 'ENDSSH'
source /opt/kolla-venv/bin/activate
# Con KVM il 02 finisce in fretta: attendo RabbitMQ e ritento post-deploy.
for i in $(seq 1 30); do
  docker exec rabbitmq rabbitmqctl await_startup --timeout 10 >/dev/null 2>&1 && break
  sleep 5
done
ok=0
for i in $(seq 1 5); do
  if kolla-ansible post-deploy -i /etc/kolla/multinode --configdir /etc/kolla >/tmp/pd.log 2>&1; then ok=1; break; fi
  echo "  post-deploy tentativo $i fallito, ritento tra 15s..."; sleep 15
done
[ "$ok" = 1 ] || { echo "[FAIL] post-deploy fallito:"; tail -15 /tmp/pd.log; exit 1; }
[ -f /etc/kolla/admin-openrc.sh ] || { echo "[FAIL] admin-openrc.sh non generato"; exit 1; }
cp -f /etc/kolla/admin-openrc.sh /root/admin-openrc.sh

# client OpenStack nel venv: NON deve determinare l'esito (un pip fallito non
# invalida openrc). Provo, e segnalo se manca, ma non blocco.
if ! python -c 'import openstackclient' 2>/dev/null; then
  pip install python-openstackclient python-barbicanclient python-heatclient >/tmp/pip.log 2>&1 || true
fi
python -c 'import openstackclient' 2>/dev/null && echo "[OK] client OpenStack presente" \
  || echo "[WARN] client OpenStack non installato (pip fallito? egress pypi). openrc comunque pronto."

echo "__OPENRC_OK__"   # marker esplicito: il successo NON dipende dall'ultimo comando
ENDSSH
)"
  echo "$out" | sed 's/^/      /'
  if echo "$out" | grep -q "__OPENRC_OK__"; then
    log_ok "openrc in /root/admin-openrc.sh"
  else
    log_fail "post-deploy fallito"; exit 1
  fi
}

# ------------------------- 4. Rete external/provider ------------------------
# NB: i floating IP non escono su internet (fuori scope). La rete external valida la
# configurazione provider, ma NON e' sul percorso dello smoke test.
create_external_network() {
  log_step "Rete external/provider (flat su physnet1) — validazione config"
## DAVE
  if ! ext_defined; then
    echo -e "${YELLOW}[WARN] Rete External NON definita (subnet, gateway o pool floating IP mancanti): la rete '${EXT_NET_NAME}' NON viene creata.${NC}"
    echo -e "${YELLOW}       Chiedere i valori al referente di rete, lanciare configura_topologia.sh e poi rilanciare il 03.${NC}"
    EXT_SKIPPED=1
    return 0
  fi
  EXT_SKIPPED=0
## DAVE
  ssh_dep "EXT_NET_NAME='${EXT_NET_NAME}' EXT_SUBNET_CIDR='${EXT_SUBNET_CIDR}' \
           EXT_GATEWAY='${EXT_GATEWAY}' EXT_FIP_START='${EXT_FIP_START}' \
           EXT_FIP_END='${EXT_FIP_END}' EXT_DNS='${EXT_DNS}' bash -s" << 'ENDSSH'
source /opt/kolla-venv/bin/activate; source /root/admin-openrc.sh
if openstack network show "$EXT_NET_NAME" >/dev/null 2>&1; then
## DAVE
  cur="$(openstack subnet list --network "$EXT_NET_NAME" -f value -c Subnet 2>/dev/null | head -1)"
  if [ -n "$cur" ] && [ "$cur" != "$EXT_SUBNET_CIDR" ]; then
    echo "[WARN] rete $EXT_NET_NAME gia' presente con subnet $cur, diversa da quella configurata ($EXT_SUBNET_CIDR): NON modificata."
    echo "       Per cambiarla: cancellare prima floating IP, router e subnet su quella rete, poi rilanciare il 03."
  else
    echo "[OK] rete $EXT_NET_NAME gia' presente"
  fi
## DAVE
else
  # PROVIDER FLAT (non 'vlan'): il tag VLAN external NON lo applica OpenStack,
  # lo applica gia' l'HOST tramite la sub-interfaccia netplan (bond0.<VID>, creata
  # dal 00) che viene inglobata in br-ex. Sul filo i frame escono gia' taggati col
  # VID external, quindi lo switch li mappa sulla rete external corretta
  # esattamente come si aspetta. Da OpenStack la rete e' "flat" su physnet1, ma
  # fisicamente e' sul VID. Con bond0 condiviso (mgmt+overlay+external) questo e'
  # l'approccio pulito: 'vlan provider' richiederebbe un'interfaccia dedicata a br-ex.
  openstack network create --external --share \
    --provider-physical-network physnet1 --provider-network-type flat \
    "$EXT_NET_NAME" >/dev/null
  # provider esterno: niente DHCP, pool di floating IP nel range fornito
  openstack subnet create --network "$EXT_NET_NAME" --no-dhcp \
    --subnet-range "$EXT_SUBNET_CIDR" --gateway "$EXT_GATEWAY" \
    --allocation-pool "start=${EXT_FIP_START},end=${EXT_FIP_END}" \
    --dns-nameserver "$EXT_DNS" "${EXT_NET_NAME}-subnet" >/dev/null
  echo "[OK] rete $EXT_NET_NAME creata (pool ${EXT_FIP_START}-${EXT_FIP_END})"
fi
ENDSSH
## DAVE
  [ "${EXT_SKIPPED:-0}" = 1 ] || log_ok "rete external pronta"
## DAVE
}

# ------------------------- 5. demo, flavor, immagine, key, secgroup ---------
create_demo_and_flavors() {
  log_step "Progetto demo, flavor, keypair, security group"
## DAVE
  ssh_dep "DEMO_PASS='${DEMO_PASS}' bash -s" << 'ENDSSH'
## DAVE
source /opt/kolla-venv/bin/activate; source /root/admin-openrc.sh
# progetto/utente demo (per l'handover)
openstack project show demo >/dev/null 2>&1 || openstack project create --description "Demo project" demo >/dev/null
openstack user show demo >/dev/null 2>&1 || openstack user create --project demo --password "$DEMO_PASS" demo >/dev/null
openstack role assignment list --user demo --project demo -f value 2>/dev/null | grep -q . || \
  openstack role add --project demo --user demo member >/dev/null
# flavor
for f in "m1.tiny:1024:1:10" "m1.small:2048:1:20" "m1.medium:4096:2:40" "m1.large:8192:4:80"; do
  name=${f%%:*}; rest=${f#*:}; ram=${rest%%:*}; rest=${rest#*:}; vcpu=${rest%%:*}; disk=${rest##*:}
  openstack flavor show "$name" >/dev/null 2>&1 || \
    openstack flavor create --ram "$ram" --vcpus "$vcpu" --disk "$disk" --public "$name" >/dev/null
done
# keypair
if ! openstack keypair show os-key >/dev/null 2>&1; then
  [ -f /root/os-key ] || ssh-keygen -t ed25519 -N "" -f /root/os-key >/dev/null
  openstack keypair create --public-key /root/os-key.pub os-key >/dev/null
fi
# security group: ICMP + SSH sul default del progetto admin
openstack security group rule list default -f value 2>/dev/null | grep -qi icmp || \
  openstack security group rule create --proto icmp default >/dev/null 2>&1 || true
openstack security group rule list default -f value 2>/dev/null | grep -q "22:22" || \
  openstack security group rule create --proto tcp --dst-port 22 default >/dev/null 2>&1 || true
echo "[OK] demo, flavor, keypair, security group pronti"
ENDSSH
  log_ok "demo/flavor/keypair/secgroup pronti"
}

print_summary() {
  local admin_pass; admin_pass="$(ssh_dep 'cat /root/admin-openrc-password.txt 2>/dev/null' || echo 'N/A')"
## DAVE
  local EXT_DESC
  if ext_defined; then EXT_DESC="${EXT_NET_NAME} (${EXT_SUBNET_CIDR}, FIP ${EXT_FIP_START}-${EXT_FIP_END})"
  else EXT_DESC="NON DEFINITA: rete external non creata (vedi configura_topologia.sh)"; fi
## DAVE
  cat << EOF

+--------------------------------------------------------------+
   [OK] 03 — Configurazione completata
+--------------------------------------------------------------+
  Horizon   : http://${VIP}          (admin / ${admin_pass})
  Skyline   : http://${VIP}:9999     (stesse credenziali; solo se enable_skyline=yes)
  Utente demo: demo / ${DEMO_PASS}   (progetto demo)
  Topologia : ${#ALL_NODES[@]} nodi | control=${#CONTROL_NODES[@]} compute=${#COMPUTE_NODES[@]}
  External  : ${EXT_DESC}
  Nota      : floating IP verso internet FUORI SCOPE.

  Verifiche funzionali (HA, servizi, Barbican, smoke test East-West, volume Ceph):
  pacchetto "test funzionali" -> 03b_functional_tests_3NODE.sh
EOF
}

main() {
  log_step "03 Configurazione post-deploy"
  topo_validate || { log_error "Topologia non valida (lib_topology.sh)"; exit 1; }
  precheck
  generate_openrc
  create_external_network
  create_demo_and_flavors
  print_summary
}

main

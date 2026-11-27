#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Davide Marino
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
# 00_bootstrap_baremetal.sh — v2 — 3 nodi iperconvergenti (OpenStack + Ceph)
#   Server bare-metal — Ubuntu 24.04 LTS gia' installato.
#
#   Porta i 3 baremetal da "IP temporaneo + password" a "root a chiave + rete
#   definitiva (2 bond LACP + VLAN) verificata". Gate d'ingresso: se non chiude
#   [OK], non si prosegue col 01.
#
#   CHANGELOG v2 (da code review):
#     - CHIAVI Ed25519 (era RSA-4096): chiave ~68 byte invece di ~750, firma piu'
#          veloce (contano le centinaia di connessioni di Kolla con forks:100),
#          dimensione fissa (niente -b da sbagliare) e fuori dalla deprecazione
#          di ssh-rsa/SHA-1 (disabilitato di default da OpenSSH 8.8+).
#     - #5 ROLLBACK A PROVA DI LOCKOUT: il backup dei netplan preesistenti viene
#          VERIFICATO prima di armare; in piu' il rollback ha un netplan di
#          EMERGENZA generato dallo stato di rete attuale (iface + IP temporaneo),
#          usato se il backup e' vuoto/inutilizzabile. Il nodo non resta mai al buio.
#     - #6 NOMI NIC PER NODO: override per-nodo (BOND0_OVERRIDE/BOND1_OVERRIDE) e
#          VALIDAZIONE PRE-CUTOVER che le 4 interfacce esistano DAVVERO su quel
#          nodo (fail-fast invece di affidarsi al rollback).
#     - #3 GUARDIA CHIAVE: se si salta la fase chiavi (--verify-only) e la deploy
#          key non c'e', si esce con un messaggio chiaro invece di "irraggiungibile".
#     - #2 DIAGNOSTICI: l'output di ssh/sudo non viene piu' soppresso: in caso di
#          errore viene mostrato (password errata? sudo NOPASSWD assente?).
#
#   FASI:  1 precheck  2 chiavi SSH  3 discover NIC  4 cutover  4b NTP  5 verifiche
#
#   NOTA NTP: Kolla 2025.1 NON gestisce piu' la sincronizzazione oraria (il
#   container chrony e' stato deprecato in Wallaby e rimosso in Xena) e i suoi
#   prechecks FALLISCONO se non trovano un demone NTP sull'host. In piu' il 01b
#   (Ceph) gira PRIMA del 02: cephadm verifica il clock nei propri pre-flight e i
#   MON vanno in HEALTH_WARN oltre ~50ms di deriva. Percio' l'NTP e' QUI, nel gate
#   fondazionale, e non nel 01.
#
#   USO (dall'host di deploy):
#     sudo bash 00_bootstrap_baremetal.sh --discover     # chiavi + inventario NIC
#     sudo bash 00_bootstrap_baremetal.sh                # cutover + NTP + verifiche
#     sudo bash 00_bootstrap_baremetal.sh --verify-only  # solo verifiche
#     sudo bash 00_bootstrap_baremetal.sh --ntp-only     # solo chrony
#     sudo bash 00_bootstrap_baremetal.sh --node node02  # limita a un nodo
## DAVE
#     sudo bash 00_bootstrap_baremetal.sh --from-node    # lanciato DA UN NODO del cluster
#         (bond/VLAN gia' configurati): niente cutover, solo chiavi + NTP + verifiche.
#         Il cutover riconfigura la rete via SSH e farebbe cadere la sessione: da un
#         nodo il 00 senza --from-node si rifiuta di partire.
#     sudo bash 00_bootstrap_baremetal.sh --detect-ifaces  # legge dai nodi i NOMI di bond e VLAN
#         (sola lettura sui nodi) e li salva in ifaces.conf accanto a lib_topology.sh.
#         Serve quando i bond/VLAN sono stati creati da altri con nomi diversi da
#         bond0/bond1/vlan<ID>. Con --from-node il rilevamento parte da solo.
## DAVE
# =============================================================================
set -uo pipefail   # NB: niente -e: il cutover fa cadere SSH di proposito.

# ============================ CONFIG DA COMPILARE ============================
# Topologia (nodi, IP, VLAN, DEPLOY_KEY, DNS, VIP...) dalla SORGENTE UNICA.
source "$(dirname "$0")/lib_topology.sh"

# IP con cui i nodi rispondono DOPO L'INSTALLAZIONE, prima del cutover.
# Caso normale sul ferro: l'installazione li ha gia' messi sull'IP di
# management definitivo (una scheda singola) -> LASCIA VUOTO: si usa lo stesso
# IP di management e il cutover cambia solo il modo in cui ci si arriva
# (bond + VLAN), non l'indirizzo.
# Compila solo se i nodi sono stati installati su una rete DIVERSA (es. una
# rete di provisioning): in quel caso l'IP cambia al cutover.
declare -A TEMP_IPS=()
## DAVE - nel lab KVM le VM nascono gia' con IP di management, bond e VLAN (come
## consegnate dal team di installazione): nessun IP temporaneo, TEMP_IPS resta vuoto.
## DAVE

SSH_USER="ubuntu"                  # utente con sudo creato dall'installer
SSH_PASS="ChangeMe!"               # password temporanea (usata SOLO in fase 2)

# --- membri dei bond: COMPILA DOPO --discover ---
# Default validi per TUTTI i nodi (stesso modello/slot => nomi in genere identici).
# Ogni bond = 1 porta OCP + 1 porta PCIe, con un link su ciascun ToR.
BOND0_IFACES="REPLACE_OCP0 REPLACE_PCIE0"   # OpenStack: mgmt/API + overlay + external
BOND1_IFACES="REPLACE_OCP1 REPLACE_PCIE1"   # Ceph: public + cluster
# Nel LAB KVM i nomi sono fissi (li crea lab_create_vms.sh): se qui sopra ci
# sono ancora i segnaposto, usa quelli. Il file NON viene mai riscritto.
# Lab su altri hypervisor (LAB_KVM=0): nomi da compilare come sul ferro.
if [ "${LAB_KVM:-0}" = 1 ]; then
  [[ "$BOND0_IFACES" == REPLACE_* ]] && BOND0_IFACES="e0a e0b"
  [[ "$BOND1_IFACES" == REPLACE_* ]] && BOND1_IFACES="e1a e1b"
fi

# --- override PER-NODO, se un nodo enumera le NIC diversamente ---
declare -A BOND0_OVERRIDE=()
declare -A BOND1_OVERRIDE=()

# piano IP: NODE_OCTET derivato dalla topologia (ultimo ottetto dell'IP mgmt)
declare -A NODE_OCTET; for _k in "${ALL_NODES[@]}"; do NODE_OCTET[$_k]="$(node_octet "$_k")"; done
# MGMT_NET/VLAN_*/CEPH*/DNS_SERVERS/VIP/DOMAIN arrivano dalla lib

ROLLBACK_SECONDS=240
## DAVE
# Numero di dischi dati per nodo: "auto" = qualsiasi, purche' ce ne sia almeno uno; oppure un
# numero esatto (es. EXPECTED_DATA_DISKS=7 sudo bash 00_...). Taglia minima per contare un disco.
EXPECTED_DATA_DISKS="${EXPECTED_DATA_DISKS:-auto}"
DATA_DISK_MIN_BYTES="${DATA_DISK_MIN_BYTES:-100000000000}"   # 100 GB
## DAVE

# --- NTP: prerequisito CRITICO (Ceph MON tollera ~50ms di deriva) -----------
# Kolla 2025.1 NON gestisce piu' l'NTP (container chrony rimosso in Xena) e i
# suoi prechecks FALLISCONO se non trovano un demone NTP sull'host. Inoltre il
# 01b (Ceph) gira PRIMA del 02: cephadm fa un proprio pre-flight sul clock.
# => la sincronizzazione va garantita QUI.
# Metti i server NTP interni dell'infrastruttura (preferibili: piu' vicini = piu' stabili).
## DAVE
# Default: server pubblici di Ubuntu. Per NTP interni (nodi senza uscita su internet) basta mettere in
# topology.conf:  NTP_LOCAL_MASTER="node01"   (nessun NTP raggiungibile: node01 fa da sorgente per gli altri)
# topology.conf:  NTP_SERVERS_CSV="ntp1.esempio.lan,ntp2.esempio.lan"   (separati da virgola)
NTP_SERVERS=("ntp.ubuntu.com" "0.ubuntu.pool.ntp.org" "1.ubuntu.pool.ntp.org")
[ -n "${NTP_SERVERS_CSV:-}" ] && IFS=',' read -r -a NTP_SERVERS <<< "${NTP_SERVERS_CSV// /}"
## DAVE
NTP_MAX_OFFSET="0.05"                        # 50 ms: soglia allineata a mon_clock_drift_allowed
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}=== $* ===${NC}"; }
log_ok()    { echo -e "  ${GREEN}[OK]${NC} $*"; }
log_fail()  { echo -e "  ${RED}[FAIL]${NC} $*"; }

NODES=("${ALL_NODES[@]}")            # dalla topologia (lib_topology.sh)
DO_KEYS=1; DO_DISCOVER=0; DO_CUTOVER=1; DO_NTP=1; DO_VERIFY=1
## DAVE
FROM_NODE=0
DETECT_ONLY=0
## DAVE
FAILURES=0

next_is_node=0
for arg in "$@"; do
  if [ "$next_is_node" = 1 ]; then NODES=("$arg"); next_is_node=0; continue; fi
  case "$arg" in
    --keys-only)   DO_DISCOVER=0; DO_CUTOVER=0; DO_NTP=0; DO_VERIFY=0 ;;
    --discover)    DO_DISCOVER=1; DO_CUTOVER=0; DO_NTP=0; DO_VERIFY=0 ;;
    --verify-only) DO_KEYS=0; DO_CUTOVER=0; DO_NTP=0; DO_VERIFY=1 ;;
    --ntp-only)    DO_KEYS=0; DO_CUTOVER=0; DO_NTP=1; DO_VERIFY=0 ;;
    --skip-verify) DO_VERIFY=0 ;;
## DAVE
    --from-node)   FROM_NODE=1 ;;
    --detect-ifaces) DETECT_ONLY=1; DO_DISCOVER=0; DO_CUTOVER=0; DO_NTP=0; DO_VERIFY=0 ;;
## DAVE
    --node)        next_is_node=1 ;;
    --help|-h)     sed -n '2,40p' "$0"; exit 0 ;;
    *) log_error "Opzione sconosciuta: $arg"; exit 1 ;;
  esac
done

## DAVE
# ------------------- guardia: sto girando su un nodo del cluster? -------------
if [ -n "${SELF:-}" ]; then
  if [ "$FROM_NODE" != 1 ] && [ "$DO_CUTOVER" = 1 ]; then
    log_error "Sto girando sul nodo ${SELF} del cluster."
    log_error "La fase 4 (cutover) riconfigura bond e VLAN via SSH: da un nodo farebbe cadere la sessione."
    log_error "  - bond/VLAN GIA' configurati:  sudo bash $0 --from-node   (salta il cutover)"
    log_error "  - rete ancora da configurare:  lancia il 00 da un host ESTERNO ai nodi"
    exit 1
  fi
  if [ "$FROM_NODE" = 1 ]; then
    DO_CUTOVER=0
    log_warn "--from-node: lancio da ${SELF}. Cutover di rete SALTATO (i bond devono essere gia' configurati)."
  fi
elif [ "$FROM_NODE" = 1 ]; then
  log_error "--from-node ha senso solo su un nodo del cluster: nessun IP di management locale corrisponde a ${ALL_NODES[*]}."
  log_error "Se gli IP reali dei nodi sono diversi da quelli di lib_topology.sh, lancia prima:  sudo bash configura_topologia.sh"
  log_error "Da un host esterno lancia il 00 normale (con cutover)."
  exit 1
fi
## DAVE

## DAVE - IP dalla topologia (anche se non segue lo schema "stesso ultimo ottetto")
final_ip() { mgmt_ip "$1"; }
## DAVE

# TEMP_IPS non compilato per un nodo = stesso IP di management (caso normale)
for _n in "${ALL_NODES[@]}"; do
  [ -n "${TEMP_IPS[$_n]:-}" ] || TEMP_IPS[$_n]="$(final_ip "$_n")"
done; unset _n

# Il nodo e' GIA' sulla rete nuova? Vero solo se l'IP di management sta sulla
# VLAN sopra bond0. NON basta che risponda sull'IP di management: se
# l'installazione l'ha gia' messo li', risponde anche PRIMA del cutover.
on_new_net() {
  ssh_key "$1" "ip -o -4 addr show dev ${IF_MGMT} 2>/dev/null | grep -qF ' ${1}/'"
}

# #6: risolve i membri dei bond per uno specifico nodo (override o default)
bond0_of() { echo "${BOND0_OVERRIDE[$1]:-$BOND0_IFACES}"; }
bond1_of() { echo "${BOND1_OVERRIDE[$1]:-$BOND1_IFACES}"; }

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15)
ssh_key()  { local ip="$1"; shift; ssh "${SSH_OPTS[@]}" -o BatchMode=yes -i "$DEPLOY_KEY" "root@${ip}" "$@"; }
ssh_pass() { local ip="$1"; shift; sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "$@"; }

wait_ssh_up() {
  local ip="$1" timeout="${2:-200}" i=0
  while [ "$i" -lt "$timeout" ]; do
    timeout 4 bash -c "echo > /dev/tcp/${ip}/22" >/dev/null 2>&1 && return 0
    sleep 5; i=$((i+5))
  done
  return 1
}

# Ritorna l'IP su cui il nodo risponde ORA: prima il finale (a chiave), poi il
# temporaneo. Rende lo script rieseguibile a cutover gia' fatto.
# #3: se la deploy key non esiste ancora, il test sul finale viene saltato del
# tutto (evita di confondere "chiave assente" con "nodo irraggiungibile").
current_ip() {
  local n="$1" fip; fip="$(final_ip "$n")"
  if [ -f "$DEPLOY_KEY" ] && ssh_key "$fip" true >/dev/null 2>&1; then echo "$fip"; return 0; fi
  if wait_ssh_up "${TEMP_IPS[$n]}" 5; then echo "${TEMP_IPS[$n]}"; return 0; fi
  return 1
}

# ------------------------- FASE 1: precheck ---------------------------------
phase_precheck() {
  log_step "FASE 1 — Raggiungibilita' dei nodi"
  command -v sshpass >/dev/null 2>&1 || { log_info "installo sshpass sull'host..."; apt-get install -y sshpass >/dev/null 2>&1 || true; }

  # #3: se saltiamo la fase chiavi, la deploy key DEVE esserci gia'.
  if [ "$DO_KEYS" = 0 ] && [ ! -f "$DEPLOY_KEY" ]; then
    log_error "Deploy key assente: ${DEPLOY_KEY}"
    log_error "Non posso operare a chiave. Lancia prima:  sudo bash $0 --keys-only"
    exit 1
  fi

  local ip
  for n in "${NODES[@]}"; do
    if ip="$(current_ip "$n")"; then
      if [ "$ip" = "$(final_ip "$n")" ]; then log_ok "$n su ${ip} (IP finale, a chiave)"
      else log_ok "$n su ${ip} (IP temporaneo)"; fi
    else
      log_fail "$n: irraggiungibile su ${TEMP_IPS[$n]} e su $(final_ip "$n")"
      exit 1
    fi
  done
}

# ------------------------- FASE 2: chiavi SSH -------------------------------
phase_keys() {
  log_step "FASE 2 — Deploy key SSH e accesso root senza password"

  if [ -f "$DEPLOY_KEY" ]; then
    log_ok "deploy key gia' presente: ${DEPLOY_KEY} ($(ssh-keygen -l -f "${DEPLOY_KEY}.pub" 2>/dev/null | awk '{print $NF, $2"bit"}'))"
  else
    mkdir -p "$(dirname "$DEPLOY_KEY")"; chmod 700 "$(dirname "$DEPLOY_KEY")"
    # Ed25519: dimensione fissa (niente -b da sbagliare), firma veloce — utile
    # con le centinaia di connessioni che apre Kolla-Ansible (forks: 100).
    ssh-keygen -t ed25519 -N "" -f "$DEPLOY_KEY" -C "os-3node-deploy" >/dev/null
    log_ok "deploy key Ed25519 generata: ${DEPLOY_KEY}"
  fi
  local pubkey; pubkey="$(cat "${DEPLOY_KEY}.pub")"

  for n in "${NODES[@]}"; do
    local ip; ip="$(current_ip "$n")" || { log_fail "$n irraggiungibile"; exit 1; }

    if ssh_key "$ip" true >/dev/null 2>&1; then log_ok "$n (${ip}): root a chiave gia' attivo"; continue; fi

    log_info "  installo la chiave su $n (${ip}) via password (uso unico)..."
    # #2: NON sopprimiamo l'output: se fallisce vogliamo sapere PERCHE'.
    local out rc payload
    # NB: il payload va costruito PRIMA. Un heredoc dentro $( ... ) con la
    # parentesi sulla stessa riga produce "unterminated here-document".
    payload="$(cat <<EOF
set -e
mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
grep -qF "${pubkey}" /root/.ssh/authorized_keys || echo "${pubkey}" >> /root/.ssh/authorized_keys
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
echo "__KEY_INSTALLED__"
EOF
)"
    out="$(printf '%s\n' "$payload" | ssh_pass "$ip" "sudo -n bash -s" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ] || ! echo "$out" | grep -q "__KEY_INSTALLED__"; then
      log_fail "$n (${ip}): installazione chiave fallita (rc=${rc})."
      echo "$out" | sed 's/^/      | /'
      case "$out" in
        *"sudo: a password is required"*|*"a terminal is required"*)
          log_fail "  -> l'utente '${SSH_USER}' non ha sudo NOPASSWD. Correggi il kickstart." ;;
        *"Permission denied"*)
          log_fail "  -> credenziali errate: verifica SSH_USER='${SSH_USER}' / SSH_PASS." ;;
      esac
      exit 1
    fi

    if ssh_key "$ip" "echo OK" 2>/dev/null | grep -q OK; then
      log_ok "$n (${ip}): accesso root a chiave attivo"
    else
      log_fail "$n (${ip}): chiave installata ma l'accesso root a chiave non funziona."
      log_fail "  -> controlla PermitRootLogin / AllowUsers in /etc/ssh/sshd_config"
      exit 1
    fi
  done
  log_info "Da qui in poi: nessuna password, solo ${DEPLOY_KEY}"
}

# ------------------------- FASE 3: discover NIC -----------------------------
phase_discover() {
  log_step "FASE 3 — Inventario porte 25GbE (compila BOND0_IFACES / BOND1_IFACES)"
  for n in "${NODES[@]}"; do
    local ip; ip="$(current_ip "$n")" || continue
    echo -e "\n${BLUE}--- $n (${ip}) ---${NC}"
    ssh_key "$ip" bash <<'EOF'
printf "  %-14s %-8s %-6s %-18s %s\n" IFACE SPEED LINK MAC PCI
for i in /sys/class/net/*; do
  ifc=$(basename "$i"); [ "$ifc" = "lo" ] && continue; [ -e "$i/device" ] || continue
  speed=$(cat "$i/speed" 2>/dev/null || echo "?")
  [ "$speed" = "25000" ] || continue          # solo le 4 porte SFP28
  oper=$(cat "$i/operstate" 2>/dev/null || echo "?")
  mac=$(cat "$i/address" 2>/dev/null || echo "?")
  pci=$(basename "$(readlink -f "$i/device")" 2>/dev/null || echo "?")
  printf "  %-14s %-8s %-6s %-18s %s\n" "$ifc" "$speed" "$oper" "$mac" "$pci"
done
echo "  --- slot fisici (per distinguere OCP da PCIe) ---"
dmidecode -t slot 2>/dev/null | grep -E "Designation:|Current Usage:|Bus Address:" | sed 's/^/    /' || true
EOF
  done
  cat <<EOF

${YELLOW}Assegna a ciascun bond 1 porta OCP + 1 porta PCIe, coerentemente col
cablaggio verso i due ToR e coi LAG configurati in MLAG/VLT:${NC}
  BOND0_IFACES="<ocp_a> <pcie_a>"   # OpenStack
  BOND1_IFACES="<ocp_b> <pcie_b>"   # Ceph
${YELLOW}Se un nodo enumera le NIC con nomi diversi, usa gli override per-nodo:${NC}
  BOND0_OVERRIDE[node02]="..." ; BOND1_OVERRIDE[node02]="..."
EOF
}

# ------------------------- #6: validazione pre-cutover -----------------------
# Verifica che le 4 interfacce esistano DAVVERO su quel nodo e siano a 25G,
# PRIMA di scrivere qualsiasi cosa. Fail-fast invece di affidarsi al rollback.
validate_ifaces() {
  local n="$1" ip="$2" ifaces; ifaces="$(bond0_of "$n") $(bond1_of "$n")"
  local out rc
  out="$(ssh_key "$ip" "bash -s" <<EOF 2>&1
missing=""; slow=""
for i in ${ifaces}; do
  if [ ! -e "/sys/class/net/\$i" ]; then missing="\$missing \$i"; continue; fi
  sp=\$(cat "/sys/class/net/\$i/speed" 2>/dev/null || echo "?")
  [ "\$sp" = "25000" ] || slow="\$slow \$i(\${sp})"
done
[ -n "\$missing" ] && { echo "MISSING:\$missing"; exit 1; }
[ -n "\$slow" ] && echo "SLOW:\$slow"
echo "IFACES_OK"
EOF
)"
  rc=$?
  if [ "$rc" -ne 0 ] || ! echo "$out" | grep -q "IFACES_OK"; then
    log_fail "${n}: interfacce non valide su questo nodo:"
    echo "$out" | sed 's/^/      | /'
    log_fail "  -> i nomi NIC di ${n} differiscono dai default."
    log_fail "     Lancia --discover e imposta BOND0_OVERRIDE[${n}] / BOND1_OVERRIDE[${n}]"
    return 1
  fi
  echo "$out" | grep -q "^SLOW:" && log_warn "  ${n}: porte non a 25G (link giu'? transceiver?): $(echo "$out" | grep '^SLOW:')"
  log_ok "${n}: le 4 interfacce esistono ($(bond0_of "$n") | $(bond1_of "$n"))"
  return 0
}

# ------------------------- generazione netplan ------------------------------
generate_netplan() {
  local n="$1" oct="${NODE_OCTET[$1]}" eth_block="" b0 b1
  local if0 if1; if0="$(bond0_of "$n")"; if1="$(bond1_of "$n")"
  for ifc in $if0 $if1; do
    eth_block+="    ${ifc}:
      mtu: 9000
"
  done
  b0="$(echo "$if0" | sed 's/ /, /g')"
  b1="$(echo "$if1" | sed 's/ /, /g')"
  ## DAVE - lab KVM: il bond deve usare il MAC della sua prima NIC. Senza, systemd
  ## gli assegna un MAC proprio e il filtro anti-spoofing di libvirt (clean-traffic)
  ## scarta i frame in uscita dalla VM: la VLAN non risponde.
  local mac0="" mac1=""
  if [ "${LAB_KVM:-0}" = 1 ]; then
    mac0="      macaddress: 52:54:00:70:${oct}:01"
    mac1="      macaddress: 52:54:00:70:${oct}:03"
  fi
  ## DAVE
  ## DAVE - lab con VM esistenti (LAB_KVM=0): configura_rete_locale.sh passa il MAC della prima porta
  ## di ogni bond (BOND0_MAC / BOND1_MAC), per lo stesso motivo del blocco sopra. Sul ferro non e' impostato.
  [ -n "${BOND0_MAC:-}" ] && mac0="      macaddress: ${BOND0_MAC}"
  [ -n "${BOND1_MAC:-}" ] && mac1="      macaddress: ${BOND1_MAC}"
  ## DAVE
  cat <<EOF
# /etc/netplan/60-openstack.yaml — generato da 00_bootstrap_baremetal.sh
# Nodo: ${n}   —   NON modificare a mano: rigenerato dallo script.
network:
  version: 2
  renderer: networkd
  ethernets:
${eth_block}  bonds:
    ${IF_BOND0}:                                   # OpenStack: mgmt/API + overlay + external
      interfaces: [${b0}]
${mac0}
      mtu: 9000                              # deve reggere i jumbo della VLAN ${VLAN_OVERLAY}
      parameters: ${BOND_PARAMS}
    ${IF_BOND1}:                                   # Ceph: public + cluster
      interfaces: [${b1}]
${mac1}
      mtu: 9000
      parameters: ${BOND_PARAMS}
  vlans:
    ${IF_MGMT}:                                # Management / API (+ default route)
      id: ${VLAN_MGMT}
      link: ${IF_BOND0}
      mtu: 1500
      addresses: [$(mgmt_ip "$n")/${MGMT_PREFIX}]
      routes: [{to: default, via: ${MGMT_GW}}]
      nameservers: {addresses: [${DNS_SERVERS}]}
    ${IF_OVERLAY}:                                # Tenant / Overlay Geneve (jumbo)
      id: ${VLAN_OVERLAY}
      link: ${IF_BOND0}
      mtu: 9000
      addresses: [$(overlay_ip "$n")/${OVERLAY_PREFIX}]
    ${IF_EXT}:                                # External / Provider -> br-ex
      id: ${VLAN_EXT}
      link: ${IF_BOND0}
      mtu: 1500
      # volutamente SENZA indirizzo: la prende Kolla come neutron_external_interface
    ${IF_CEPHPUB}:                                # Ceph PUBLIC (client OpenStack -> Ceph)
      id: ${VLAN_CEPHPUB}
      link: ${IF_BOND1}
      mtu: 9000
      addresses: [$(cephpub_ip "$n")/${CEPHPUB_PREFIX}]
    ${IF_CEPHCLU}:                                # Ceph CLUSTER (replica OSD-OSD)
      id: ${VLAN_CEPHCLU}
      link: ${IF_BOND1}
      mtu: 9000
      addresses: [$(cephclu_ip "$n")/${CEPHCLU_PREFIX}]
EOF
}

# ------------------------- FASE 4: cutover sicuro ---------------------------
phase_cutover() {
  log_step "FASE 4 — Cutover rete (bond + VLAN) con rollback a prova di lockout"
  for n in "${NODES[@]}"; do
    local fip tip; fip="$(final_ip "$n")"; tip="${TEMP_IPS[$n]}"

    if [ -f "$DEPLOY_KEY" ] && on_new_net "$fip" >/dev/null 2>&1; then
      # gia' su bond+VLAN. Se un lancio precedente si e' interrotto prima della
      # conferma, il rollback sarebbe ancora armato: lo disarmo ora.
      ssh_key "$fip" "systemctl stop netplan-rollback.timer 2>/dev/null; systemctl reset-failed netplan-rollback.service netplan-rollback.timer 2>/dev/null; true" >/dev/null 2>&1
      log_ok "$n gia' su bond + VLAN ${VLAN_MGMT} (${fip}): cutover non necessario"; continue
    fi
    if ! wait_ssh_up "$tip" 5; then log_fail "$n: irraggiungibile su ${tip}"; FAILURES=$((FAILURES+1)); continue; fi

    # #6: fail-fast se i nomi NIC non esistono su questo nodo
    validate_ifaces "$n" "$tip" || { FAILURES=$((FAILURES+1)); continue; }

    if [ "$tip" = "$fip" ]; then
      log_info "  ${n}: stesso IP ${fip}, da scheda singola a bond + VLAN ${VLAN_MGMT}  (rollback automatico fra ${ROLLBACK_SECONDS}s)"
    else
      log_info "  ${n}: ${tip} -> ${fip}  (rollback automatico fra ${ROLLBACK_SECONDS}s)"
    fi

    # 1) push del netplan generato
    if ! generate_netplan "$n" | ssh_key "$tip" "cat > /etc/netplan/60-openstack.yaml"; then
      log_fail "$n: impossibile scrivere il netplan"; FAILURES=$((FAILURES+1)); continue
    fi

    # 2) #5: prepara backup + NETPLAN DI EMERGENZA + arma il rollback.
    #    Il rollback prova, in ordine: (a) i netplan preesistenti salvati,
    #    (b) il netplan di emergenza ricostruito dallo stato di rete attuale.
    #    Cosi' anche con backup vuoto il nodo NON resta mai senza rete.
    local out rc
    out="$(ssh_key "$tip" "bash -s" <<EOF 2>&1
set -e
chmod 600 /etc/netplan/60-openstack.yaml

# --- cattura lo stato di rete ATTUALE (che ci sta reggendo questa sessione) ---
## DAVE
# L'interfaccia di gestione e' quella che PORTA l'IP ${tip}. NON usare 'ip route get ${tip}':
# eseguito sul nodo stesso restituisce 'local ... dev lo' e il netplan di emergenza
# ripristinerebbe 127.0.0.1 (inutile se il backup dei netplan fosse vuoto).
CUR_IF="\$(ip -o -4 addr show | awk '\$4 ~ /^${tip}\// {print \$2; exit}')"
[ -z "\$CUR_IF" ] && CUR_IF="\$(ip -o route get ${tip} 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i=="dev"){print \$(i+1); exit}}')"
[ "\$CUR_IF" = lo ] && CUR_IF=""
## DAVE
CUR_CIDR="\$(ip -o -4 addr show dev "\$CUR_IF" 2>/dev/null | awk '{print \$4; exit}')"
CUR_GW="\$(ip -o -4 route show default 2>/dev/null | awk '{print \$3; exit}')"
[ -z "\$CUR_IF" ] && { echo "PREP_FAIL: interfaccia di gestione attuale non rilevata"; exit 1; }
[ -z "\$CUR_CIDR" ] && { echo "PREP_FAIL: IP attuale non rilevato su \$CUR_IF"; exit 1; }

# --- netplan di EMERGENZA: riporta ESATTAMENTE lo stato attuale ---
mkdir -p /root/netplan-backup
cat > /root/netplan-emergency.yaml <<EM
# Rete di emergenza: ripristina l'accesso su \${CUR_IF} = \${CUR_CIDR}
# Generato automaticamente prima del cutover da 00_bootstrap_baremetal.sh
network:
  version: 2
  renderer: networkd
  ethernets:
    \${CUR_IF}:
      dhcp4: false
      addresses: [\${CUR_CIDR}]
EM
if [ -n "\$CUR_GW" ]; then
cat >> /root/netplan-emergency.yaml <<EM
      routes: [{to: default, via: \${CUR_GW}}]
      nameservers: {addresses: [8.8.8.8, 1.1.1.1]}
EM
fi
python3 -c "import yaml,sys; yaml.safe_load(open('/root/netplan-emergency.yaml'))" 2>/dev/null \
  || { echo "PREP_FAIL: netplan di emergenza non valido"; exit 1; }

# --- backup dei netplan preesistenti (li togliamo di mezzo: configurano la NIC grezza) ---
for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
  [ -e "\$f" ] || continue
  [ "\$(basename "\$f")" = "60-openstack.yaml" ] && continue
  mv -f "\$f" /root/netplan-backup/ 2>/dev/null || true
done
BK_COUNT=\$(ls -1 /root/netplan-backup/ 2>/dev/null | wc -l)
echo "BACKUP_FILES=\$BK_COUNT  EMERGENCY_IF=\$CUR_IF  EMERGENCY_IP=\$CUR_CIDR"

# cloud-init non deve riscrivere la rete al reboot
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

# --- script di rollback (a) backup, (b) emergenza; verifica di aver applicato qualcosa ---
cat > /usr/local/sbin/netplan-rollback.sh <<'RB'
#!/bin/bash
# Ripristina la rete precedente al cutover. Non deve MAI lasciare il nodo senza config.
rm -f /etc/netplan/60-openstack.yaml
restored=0
if ls /root/netplan-backup/*.y*ml >/dev/null 2>&1; then
  cp -af /root/netplan-backup/*.y*ml /etc/netplan/ 2>/dev/null && restored=1
fi
if [ "\$restored" = 0 ] || ! netplan generate 2>/dev/null; then
  # backup assente o non valido -> rete di emergenza
  rm -f /etc/netplan/*.yaml /etc/netplan/*.yml 2>/dev/null
  cp -af /root/netplan-emergency.yaml /etc/netplan/00-emergency.yaml
  chmod 600 /etc/netplan/00-emergency.yaml
fi
netplan apply 2>/dev/null || { netplan generate; netplan apply; }
logger -t netplan-rollback "ROLLBACK ESEGUITO (backup restored=\$restored)"
RB
chmod +x /usr/local/sbin/netplan-rollback.sh

# prova a secco: il rollback produrrebbe una config valida?
netplan generate >/dev/null 2>&1 || true

systemctl stop netplan-rollback.timer 2>/dev/null || true
systemctl reset-failed netplan-rollback.service netplan-rollback.timer 2>/dev/null || true
systemd-run --unit=netplan-rollback --on-active=${ROLLBACK_SECONDS} /usr/local/sbin/netplan-rollback.sh >/dev/null 2>&1

# valida il netplan NUOVO prima di applicarlo
netplan generate || { echo "PREP_FAIL: netplan nuovo non valido"; exit 1; }
echo "__ARMED__"
# applica DETACHED: la caduta di SSH non aborta l'apply a meta'
# dopo l'apply: ping al gateway. Se l'IP resta lo stesso ma passa da una scheda
# al bond, il traffico in uscita fa aggiornare subito allo switch la
# posizione dell'indirizzo, senza aspettare la scadenza della cache ARP.
systemd-run --unit=netplan-apply --on-active=2 /bin/sh -c '/usr/sbin/netplan apply; sleep 3; ping -c 5 -W 1 ${MGMT_GW} >/dev/null 2>&1; true' >/dev/null 2>&1
EOF
)"
    rc=$?
    echo "$out" | grep -E "^BACKUP_FILES=" | sed 's/^/      /'
    if [ "$rc" -ne 0 ] || ! echo "$out" | grep -q "__ARMED__"; then
      log_fail "${n}: preparazione cutover fallita, NIENTE e' stato applicato:"
      echo "$out" | sed 's/^/      | /'
      FAILURES=$((FAILURES+1)); continue
    fi
    echo "$out" | grep -q "BACKUP_FILES=0" && \
      log_warn "  ${n}: nessun netplan preesistente da salvare -> il rollback usera' la rete di EMERGENZA (${tip})"

    # 3) attendo il nodo sulla RETE NUOVA: risponde sull'IP di management E
    #    l'IP sta sulla VLAN sopra il bond. Il solo "risponde" non basta: con lo
    #    stesso IP di prima risponderebbe anche PRIMA che la rete nuova sia
    #    applicata, e disarmeremmo il rollback troppo presto.
    log_info "  attendo ${n} su ${fip} via bond + VLAN ${VLAN_MGMT}..."
    local up=0 i=0
    while [ "$i" -lt "$((ROLLBACK_SECONDS - 30))" ]; do
      if on_new_net "$fip" >/dev/null 2>&1; then up=1; break; fi
      sleep 5; i=$((i+5))
    done

    if [ "$up" = 0 ]; then
      log_fail "${n}: nuovo IP non risalito -> AUTO-ROLLBACK verso ${tip} in corso."
      log_fail "  Cause tipiche: LAG/MLAG assente sui ToR, VLAN non in trunk, cablaggio bond errato."
      log_fail "  Il nodo tornera' raggiungibile da solo: correggi e rilancia."
      FAILURES=$((FAILURES+1)); continue
    fi

    # 4) confermo: disarmo il rollback
    ssh_key "$fip" bash <<'EOF' >/dev/null 2>&1
systemctl stop netplan-rollback.timer 2>/dev/null || true
systemctl reset-failed netplan-rollback.service netplan-rollback.timer 2>/dev/null || true
rm -f /usr/local/sbin/netplan-rollback.sh
EOF
    log_ok "${n}: cutover confermato su ${fip}, rollback disarmato"

    # 5) hostname + /etc/hosts (tutti i nodi, dalla topologia)
    local hosts_block=""
    local hn; for hn in "${ALL_NODES[@]}"; do
      hosts_block+="$(mgmt_ip "$hn") ${hn} ${hn}.${DOMAIN}"$'\n'
    done
    ssh_key "$fip" bash <<EOF >/dev/null 2>&1
hostnamectl set-hostname ${n}
cat > /etc/hosts <<H
127.0.0.1 localhost
::1       localhost ip6-localhost ip6-loopback
${hosts_block}${VIP} api.${DOMAIN}
H
EOF
  done
}

# ------------------------- FASE 4b: NTP (chrony) ----------------------------
# Perche' QUI e non nel 01: cephadm (01b) verifica il clock nei suoi pre-flight e
# i MON entrano in HEALTH_WARN oltre ~50ms di skew; inoltre i prechecks di Kolla
# (02) falliscono senza un demone NTP sull'host. Serve la rete su -> dopo il cutover.
phase_ntp() {
  log_step "FASE 4b — Sincronizzazione oraria (chrony) — prerequisito Ceph/Kolla"
  ## DAVE
  if [ -n "${NTP_LOCAL_MASTER:-}" ]; then
    _in_array "$NTP_LOCAL_MASTER" "${ALL_NODES[@]}" || { log_fail "NTP_LOCAL_MASTER='${NTP_LOCAL_MASTER}' non e' un nodo di topology.conf"; FAILURES=$((FAILURES+1)); return 0; }
    log_info "NTP: ${NTP_LOCAL_MASTER} fa da sorgente locale (local stratum 10) per gli altri nodi"
  fi
  ## DAVE
  local servers_conf=""
  for s in "${NTP_SERVERS[@]}"; do
    # iburst: converge in secondi invece che minuti. Utile al primo avvio.
    servers_conf+="server ${s} iburst
"
  done

  for n in "${NODES[@]}"; do
    local fip; fip="$(final_ip "$n")"
    if ! ssh_key "$fip" true >/dev/null 2>&1; then
      log_fail "${n}: irraggiungibile, salto NTP"; FAILURES=$((FAILURES+1)); continue
    fi

    ## DAVE - NTP_LOCAL_MASTER=<nodo> (in topology.conf): nessun server NTP raggiungibile (es. rete senza
    ## UDP 123 verso l'esterno). Il nodo indicato fa da sorgente (local stratum 10) per gli altri due,
    ## cosi' i nodi restano d'accordo fra loro (quello che serve a Ceph). Se NTP_SERVERS_CSV e' valorizzato,
    ## il master lo usa come sorgente a monte e 'local' resta solo come ripiego.
    local node_conf="$servers_conf"
    if [ -n "${NTP_LOCAL_MASTER:-}" ]; then
      if [ "$n" = "$NTP_LOCAL_MASTER" ]; then
        node_conf=""
        [ -n "${NTP_SERVERS_CSV:-}" ] && node_conf="$servers_conf"
        node_conf+="local stratum 10
allow ${MGMT_NET}.0/${MGMT_PREFIX}
"
      else
        node_conf="server $(mgmt_ip "$NTP_LOCAL_MASTER") iburst
"
      fi
    fi
    ## DAVE
    local out rc
    out="$(ssh_key "$fip" "bash -s" <<EOF 2>&1
set -e
export DEBIAN_FRONTEND=noninteractive

# UN SOLO demone di sincronizzazione: timesyncd (default su Ubuntu 24.04) va
# spento PRIMA di chrony, o i due si contendono il clock ("multiple time sync
# daemons hell" — il motivo per cui Kolla ha smesso di gestirlo).
systemctl stop systemd-timesyncd 2>/dev/null || true
systemctl disable systemd-timesyncd 2>/dev/null || true
systemctl mask systemd-timesyncd 2>/dev/null || true

# --- installazione chrony ---------------------------------------------------
# Check pacchetto (non del binario): risponde alla domanda giusta ed e' immune
# al PATH. Lo stato deve essere esattamente "install ok installed": 'dpkg -s'
# da solo tornerebbe 0 anche per un pacchetto rimosso con config residui (rc).
if dpkg-query -W -f='\${Status}' chrony 2>/dev/null | grep -q "install ok installed"; then
  echo "chrony gia' installato"
else
  # Il lock dpkg puo' essere tenuto da cloud-init/unattended-upgrades appena
  # dopo il provisioning: attendiamo invece di fallire.
  cloud-init status --wait >/dev/null 2>&1 || true
  for i in \$(seq 1 60); do
    fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1 || break
    [ "\$i" = 60 ] && { echo "TIMEOUT: lock dpkg occupato da 10 minuti"; exit 1; }
    sleep 10
  done

  # CRITICO: 'apt-get update' PRIMA dell'install. I nodi arrivano da una ISO che
  # puo' avere settimane: la loro cache punta a versioni gia' rimosse dal pool e
  # l'install fallirebbe con 404 (non con "pacchetto non trovato" — 404 sul .deb).
  apt-get update -q || { echo "APT_UPDATE_FAIL: i nodi raggiungono i repo Ubuntu (o un mirror interno)?"; exit 1; }
  apt-get install -y chrony || { echo "APT_INSTALL_FAIL: chrony non installabile"; exit 1; }
fi
command -v chronyd >/dev/null 2>&1 || { echo "chronyd assente dopo l'install"; exit 1; }

# UTC su tutti i nodi: evita ambiguita' nei log correlati fra i 3 host.
timedatectl set-timezone UTC 2>/dev/null || true

mkdir -p /etc/chrony/conf.d
cat > /etc/chrony/conf.d/00-ntp.conf <<'CH'
# Server NTP del progetto — gestito da 00_bootstrap_baremetal.sh
${node_conf}
# Consenti uno step (salto) del clock nelle prime 3 correzioni se lo scarto e'
# oltre 1s: al primo boot il ferro puo' partire molto sfasato, e una correzione
# lenta (slew) impiegherebbe ore, bloccando il bootstrap dei MON Ceph.
makestep 1.0 3
# Registra la deriva dell'RTC: dopo un reboot riparte gia' vicino.
rtcsync
CH

systemctl enable chrony >/dev/null 2>&1
systemctl restart chrony
sleep 2
# forza subito l'allineamento invece di aspettare la convergenza naturale
chronyc makestep >/dev/null 2>&1 || true
echo "__NTP_CONFIGURED__"
EOF
)"
    rc=$?
    if [ "$rc" -ne 0 ] || ! echo "$out" | grep -q "__NTP_CONFIGURED__"; then
      log_fail "${n}: configurazione chrony fallita:"
      echo "$out" | tail -12 | sed 's/^/      | /'
      case "$out" in
        *APT_UPDATE_FAIL*)
          log_fail "  -> i repo Ubuntu non sono raggiungibili dalla VLAN ${VLAN_MGMT}."
          log_fail "     Verifica default gw ${MGMT_GW}, DNS, proxy, o configura un mirror interno." ;;
        *APT_INSTALL_FAIL*)
          log_fail "  -> apt update ok ma chrony non installabile: repo 'main' abilitato?" ;;
        *"TIMEOUT: lock dpkg"*)
          log_fail "  -> cloud-init/unattended-upgrades tengono il lock: attendi e rilancia --ntp-only" ;;
      esac
      FAILURES=$((FAILURES+1)); continue
    fi
    log_ok "${n}: chrony configurato (timesyncd disattivato, TZ=UTC)"
  done

  # Attesa convergenza: senza questa, il 01b puo' partire su un clock ancora storto.
  log_info "  attendo la convergenza del clock (max ~2 min per nodo)..."
  for n in "${NODES[@]}"; do
    local fip; fip="$(final_ip "$n")"
    ## DAVE - il makestep subito dopo il riavvio di chrony non ha effetto (le sorgenti non
    ## sono ancora raggiungibili): lo ripeto durante l'attesa, finche' il clock non e' sincronizzato
    ## (Kolla controlla 'timedatectl': "System clock synchronized: yes").
    local waitcmd="for i in 1 2 3 4 5 6; do chronyc waitsync 4 ${NTP_MAX_OFFSET} 0 5 >/dev/null 2>&1 && timedatectl 2>/dev/null | grep -q 'synchronized: yes' && exit 0; chronyc makestep >/dev/null 2>&1; done; exit 1"
    ## DAVE
    ssh_key "$fip" "$waitcmd" >/dev/null 2>&1 \
      && log_ok "${n}: clock sincronizzato (offset < ${NTP_MAX_OFFSET}s)" \
      || { log_warn "${n}: non ancora convergente, verifico nella fase 5"; }
  done
}

# ------------------------- FASE 5: verifiche --------------------------------
phase_verify() {
  log_step "FASE 5 — Verifica rete e prerequisiti storage"
  for n in "${NODES[@]}"; do
    local fip; fip="$(final_ip "$n")"
    echo -e "\n${BLUE}--- ${n} (${fip}) ---${NC}"
    if ! ssh_key "$fip" true >/dev/null 2>&1; then
      log_fail "${n}: non raggiungibile a chiave sull'IP finale ${fip}"
      FAILURES=$((FAILURES+1)); continue
    fi

    # le VLAN da verificare vengono dalla topologia (VLAN ID reali), non scritte a mano
    local vlans="${IF_MGMT}:1500 ${IF_OVERLAY}:9000 ${IF_EXT}:1500 ${IF_CEPHPUB}:9000 ${IF_CEPHCLU}:9000"
    ssh_key "$fip" "LAB_MODE=${LAB_MODE} VLANS='${vlans}' BONDS='${IF_BOND0} ${IF_BOND1}' bash -s" <<'EOF'
rc=0
for b in $BONDS; do
  f="/proc/net/bonding/$b"
  if [ ! -f "$f" ]; then echo "  [FAIL] $b assente"; rc=1; continue; fi
  mii=$(awk -F': ' '/MII Status/{print $2; exit}' "$f")
  slaves=$(grep -c "Slave Interface" "$f")
  partner=$(awk -F': ' '/Partner Mac Address/{print $2; exit}' "$f")
  echo "  $b: MII=${mii} slaves=${slaves} partner=${partner}"
  [ "$slaves" -ge 2 ] || { echo "    [WARN] meno di 2 slave attivi"; rc=1; }
  if [ "${LAB_MODE:-0}" = 1 ]; then
    echo "    [OK] bond attivo (LAB_MODE: active-backup, LACP non atteso)"
  else
    case "$partner" in
      ""|"00:00:00:00:00:00")
        echo "    [FAIL] LACP NON formato: lo switch non risponde al 802.3ad"
        echo "           -> verifica il LAG sui ToR (MLAG/VLT) per queste porte"; rc=1 ;;
      *) echo "    [OK] LACP formato con lo switch" ;;
    esac
  fi
done
for v in $VLANS; do
  ifc=${v%%:*}; exp=${v##*:}
  cur=$(cat /sys/class/net/$ifc/mtu 2>/dev/null || echo "assente")
  if [ "$cur" = "$exp" ]; then echo "  [OK] $ifc MTU=$cur"
  else echo "  [FAIL] $ifc MTU=$cur (atteso $exp)"; rc=1; fi
done
exit $rc
EOF
    [ $? -ne 0 ] && FAILURES=$((FAILURES+1))

    for peer in "${ALL_NODES[@]}"; do
      [ "$peer" = "$n" ] && continue
      ## DAVE - IP dei peer dalla topologia
      local pov pcp pcc; pov="$(overlay_ip "$peer")"; pcp="$(cephpub_ip "$peer")"; pcc="$(cephclu_ip "$peer")"
      ## DAVE
      ## DAVE - il jumbo che non passa ora CONTA (prima era solo stampato e il gate passava lo stesso);
      ## 3 tentativi da 2 ping: un collegamento che perde pacchetti non deve dare un falso FAIL.
      ssh_key "$fip" bash <<EOF
# payload 8972 + 20 (IP) + 8 (ICMP) = 9000, don't-fragment
bad=0
for t in "${pov}:overlay" "${pcp}:ceph-public" "${pcc}:ceph-cluster"; do
  tip=\${t%%:*}; name=\${t##*:}
  good=0
  for a in 1 2 3; do ping -M do -s 8972 -c2 -W2 "\$tip" >/dev/null 2>&1 && { good=1; break; }; done
  if [ "\$good" = 1 ]; then
    echo "  [OK] jumbo ${n}->${peer} \$name (\$tip)"
    if [ "\$a" -gt 1 ]; then echo "  [WARN] jumbo ${n}->${peer} \$name: riuscito solo al tentativo \$a di 3 (perdita di pacchetti?)"; fi
  else
    echo "  [FAIL] jumbo ${n}->${peer} \$name (\$tip): MTU 9000 non passa (trunk/MTU switch?)"; bad=1
  fi
done
exit \$bad
EOF
      [ $? -ne 0 ] && FAILURES=$((FAILURES+1))
      ## DAVE
    done

    ssh_key "$fip" bash <<EOF
echo "  --- dischi ---"
lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null | sed 's/^/    /'
## DAVE
# Dischi dati = dischi interi, non rimovibili, >= ${DATA_DISK_MIN_BYTES} byte, NESSUNA parte montata
# (il disco di root e' escluso anche se ha la stessa taglia). Il numero NON e' fisso:
# con EXPECTED_DATA_DISKS=auto basta ne esista almeno uno; con un numero, deve coincidere.
cnt=0; lst=""
for d in \$(lsblk -dnbo NAME,SIZE,TYPE,RM 2>/dev/null | awk -v lo=${DATA_DISK_MIN_BYTES} '\$3=="disk" && \$2>=lo && \$4==0 {print \$1}'); do
  lsblk -nr -o MOUNTPOINT "/dev/\$d" 2>/dev/null | grep -q . && continue
  cnt=\$((cnt+1)); lst="\$lst \$d"
done
echo "    dischi dati (non montati):\${lst:- nessuno}"
if [ "${EXPECTED_DATA_DISKS}" = "auto" ]; then
  if [ "\$cnt" -ge 1 ]; then ok=1; else ok=0; fi
  want="almeno 1"
else
  if [ "\$cnt" -eq "${EXPECTED_DATA_DISKS}" ]; then ok=1; else ok=0; fi
  want="${EXPECTED_DATA_DISKS}"
fi
if [ "\$ok" = 1 ]; then
  echo "  [OK] \$cnt dischi dati visibili grezzi (controller in Non-RAID/passthrough)"
else
  echo "  [FAIL] visti \$cnt dischi dati (attesi \$want)"
  echo "         Se vedi solo il disco di root, i dischi dati sono in modalita' RAID o 'Ready' (invisibili al sistema)."
  echo "         Convertili in Non-RAID dal BMC o dall'utility del controller (procedura specifica del produttore)."
  exit 1
fi
## DAVE
EOF
## DAVE
    [ $? -ne 0 ] && FAILURES=$((FAILURES+1))
## DAVE

    # NTP: gate esplicito. Clock storto qui = MON Ceph in clock skew nel 01b
    # e prechecks Kolla falliti nel 02.
    ssh_key "$fip" bash <<EOF
echo "  --- sincronizzazione oraria ---"
if ! systemctl is-active --quiet chrony 2>/dev/null; then
  echo "  [FAIL] chrony non attivo"; exit 1
fi
if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
  echo "  [FAIL] systemd-timesyncd ANCORA attivo: due demoni si contendono il clock"; exit 1
fi
src=\$(chronyc tracking 2>/dev/null | awk -F': *' '/Reference ID/{print \$2}')
off=\$(chronyc tracking 2>/dev/null | awk -F': *' '/System time/{print \$2}' | awk '{print \$1}')
leap=\$(chronyc tracking 2>/dev/null | awk -F': *' '/Leap status/{print \$2}')
echo "    sorgente=\${src:-?}  offset=\${off:-?}s  stato=\${leap:-?}"
case "\$leap" in
  *Normal*) : ;;
  *) echo "  [FAIL] chrony non sincronizzato (Leap status: \${leap:-?})"; exit 1 ;;
esac
ok=\$(awk -v o="\${off:-99}" -v m=${NTP_MAX_OFFSET} 'BEGIN{o=(o<0?-o:o); print (o<m)?1:0}')
if [ "\$ok" = "1" ]; then
  echo "  [OK] clock entro ${NTP_MAX_OFFSET}s (limite skew MON Ceph)"
else
  echo "  [FAIL] offset \${off}s oltre ${NTP_MAX_OFFSET}s: i MON Ceph andrebbero in clock skew"
  exit 1
fi
EOF
    [ $? -ne 0 ] && FAILURES=$((FAILURES+1))
  done

  # Deriva RELATIVA fra i nodi: e' questa che conta per il quorum MON, non
  # l'offset assoluto verso l'upstream.
  log_info "Scarto orario fra i nodi (rilevante per il quorum MON Ceph):"
  ## DAVE - misura dello scarto compensata: ogni nodo e' confrontato con l'orologio LOCALE nello stesso
  ## istante (punto medio fra invio e risposta, campione con RTT minimo su connessione SSH gia' aperta).
  ## Prima si confrontava l'ora letta in momenti diversi: includeva il tempo passato fra una lettura e l'altra
  ## (secondi su un collegamento lento) e segnalava scarti che non esistevano.
  local off_ref="" off_n delta SKCP="/tmp/.os-skew-$$-%C"
  for n in "${NODES[@]}"; do
    local fip; fip="$(final_ip "$n")"
    off_n="$(
      best=""; bestrtt=999
      for k in 1 2 3 4 5 6; do
        t0="$(date +%s.%N)"
        r="$(ssh "${SSH_OPTS[@]}" -o BatchMode=yes -i "$DEPLOY_KEY" -o ControlMaster=auto -o "ControlPath=$SKCP" -o ControlPersist=20 "root@${fip}" "date +%s.%N" 2>/dev/null)" || continue
        t1="$(date +%s.%N)"
        [ "$k" -eq 1 ] && continue   # il primo campione paga la connessione: scartato
        read -r rtt off <<<"$(awk -v a="$t0" -v b="$t1" -v r="$r" 'BEGIN{printf "%.6f %.6f", b-a, r-(a+b)/2}')"
        if awk -v x="$rtt" -v y="$bestrtt" 'BEGIN{exit !(x<y)}'; then bestrtt="$rtt"; best="$off"; fi
      done
      printf '%s' "$best"
    )"
    ssh "${SSH_OPTS[@]}" -o BatchMode=yes -i "$DEPLOY_KEY" -o "ControlPath=$SKCP" -O exit "root@${fip}" >/dev/null 2>&1 || true
    [ -n "$off_n" ] || continue
    if [ -z "$off_ref" ]; then off_ref="$off_n"; log_ok "${n}: preso come riferimento"; continue; fi
    delta="$(awk -v a="$off_ref" -v b="$off_n" 'BEGIN{d=b-a; printf "%.3f", (d<0?-d:d)}')"
    if awk -v d="$delta" 'BEGIN{exit !(d<0.25)}'; then
      log_ok "${n}: scarto ~${delta}s dal riferimento (misura compensata; chrony verifica <0.05s)"
    else
      log_fail "${n}: scarto ~${delta}s dal riferimento — troppo per Ceph"
      FAILURES=$((FAILURES+1))
    fi
  done
  ## DAVE

  # Egress internet: verifichiamo QUI gli endpoint che serviranno a 01/02/03.
  # Scoprire un firewall chiuso a meta' del pull delle immagini Kolla costa ore.
  log_info "Egress verso gli endpoint necessari al deploy:"
  for n in "${NODES[@]}"; do
    local fip; fip="$(final_ip "$n")"
    ## DAVE - con proxy il test e' fatto passando dal proxy (curl), non con connessioni dirette
    ssh_key "$fip" bash -s -- "${VIP}" <<'EOF'
fail=0
VIPX="$1"
px="${https_proxy:-${http_proxy:-}}"
if [ -n "$px" ]; then
  echo "  [INFO] proxy in uso: $px"
  # Il proxy deve lasciare FUORI le reti del cluster, altrimenti API e Ceph passano dal proxy.
  case ",${no_proxy:-}," in
    *",${VIPX},"*) : ;;
    *) echo "  [FAIL] no_proxy non contiene il VIP ${VIPX}: lancia configura_proxy.sh"; fail=1 ;;
  esac
  pcheck() {  # url descrizione modo(any|ok): any = basta il tunnel (https), ok = servono 2xx/3xx (http)
    ## DAVE - fino a 3 tentativi: un collegamento che perde pacchetti (cavo/ottica difettosi) fa saltare
    ## singole richieste; un blocco vero del proxy fallisce tutte le volte.
    local code att good=0
    for att in 1 2 3; do
      code="$(curl -sS -o /dev/null -I -m25 -w '%{http_code}' --proxy "$px" "$1" 2>/dev/null)"
      if { [ "$3" = any ] && [ "$code" != 000 ] && [ -n "$code" ]; } || { [ "$3" = ok ] && [[ "$code" =~ ^[23] ]]; }; then good=1; break; fi
    done
    if [ "$good" = 1 ]; then
      echo "  [OK] $1  via proxy, HTTP $code  ($2)"
      if [ "$att" -gt 1 ]; then echo "  [WARN] $1: riuscito solo al tentativo $att di 3 — collegamento instabile (perdita di pacchetti?)"; fi
      return 0
    else
      echo "  [FAIL] $1 non raggiungibile via proxy dopo 3 tentativi (HTTP ${code:-000})  ($2)"; return 1
    fi
    ## DAVE
  }
  pcheck "http://archive.ubuntu.com/ubuntu/dists/noble/InRelease"          "pacchetti Ubuntu (chrony, docker, python)" ok  || fail=1
  pcheck "http://security.ubuntu.com/ubuntu/dists/noble-security/InRelease" "aggiornamenti di sicurezza"                ok  || fail=1
  pcheck "https://quay.io/v2/"                         "immagini container OpenStack (02: ~GB)" any || fail=1
  pcheck "https://download.docker.com/linux/ubuntu/gpg" "Docker CE repo (01)"                   any || fail=1
  pcheck "https://pypi.org/simple/"                     "kolla-ansible via pip (01)"            any || fail=1
  pcheck "https://files.pythonhosted.org/"              "wheel pip (01)"                        any || fail=1
  ## DAVE
  # CirrOS serve solo al 03b (smoke test): se manca il 03b salta lo smoke, il deploy non si ferma.
  pcheck "https://download.cirros-cloud.net/" "cirros non raggiungibile: serve solo al 03b" any \
    || echo "  [WARN] cirros non raggiungibile: serve solo al 03b (smoke test saltato)"
  ## DAVE
else
# DNS: se non risolve, tutto il resto e' rumore
if ! getent hosts quay.io >/dev/null 2>&1; then
  echo "  [FAIL] DNS non risolve quay.io -> nameserver/VLAN mgmt"; fail=1
fi
# Endpoint indispensabili, con il ruolo di ciascuno
check() {  # host porta descrizione
  if timeout 8 bash -c "echo > /dev/tcp/$1/$2" 2>/dev/null; then
    echo "  [OK] $1:$2  ($3)"
  else
    echo "  [FAIL] $1:$2 irraggiungibile  ($3)"; return 1
  fi
}
check archive.ubuntu.com     80  "pacchetti Ubuntu (chrony, docker, python)" || fail=1
check security.ubuntu.com    80  "aggiornamenti di sicurezza"                || fail=1
check quay.io               443  "immagini container OpenStack (02: ~GB)"    || fail=1
check download.docker.com   443  "Docker CE repo (01)"                       || fail=1
check pypi.org              443  "kolla-ansible via pip (01)"                || fail=1
check files.pythonhosted.org 443 "wheel pip (01)"                            || fail=1
  ## DAVE
  # CirrOS serve solo al 03b: avviso non bloccante, senza incrementare 'fail'.
  if timeout 8 bash -c 'echo > /dev/tcp/download.cirros-cloud.net/443' 2>/dev/null; then
    echo '  [OK] https://download.cirros-cloud.net/ (cirros non raggiungibile: serve solo al 03b)'
  else
    echo '  [WARN] cirros non raggiungibile: serve solo al 03b (smoke test saltato)'
  fi
  ## DAVE
fi
exit $fail
EOF
    ## DAVE
    if [ $? -ne 0 ]; then
      log_fail "${n}: egress incompleto — 01/02 falliranno"
      FAILURES=$((FAILURES+1))
    else
      log_ok "${n}: egress completo"
    fi
  done
}

print_summary() {
  echo ""
  if [ "$FAILURES" -eq 0 ]; then
    cat <<EOF
+--------------------------------------------------------------+
   [OK] BOOTSTRAP BAREMETAL COMPLETATO — gate superato
+--------------------------------------------------------------+
  Accesso   : root a chiave -> ${DEPLOY_KEY}  (nessuna password)
  Nodi      : $(for _n in "${ALL_NODES[@]}"; do printf "%s=%s  " "$_n" "$(mgmt_ip "$_n")"; done)
  ${IF_BOND0}: mgmt ${IF_MGMT} v${VLAN_MGMT} (1500) | overlay ${IF_OVERLAY} v${VLAN_OVERLAY} (9000) | external ${IF_EXT} v${VLAN_EXT} (br-ex)
  ${IF_BOND1}: ceph-public ${IF_CEPHPUB} v${VLAN_CEPHPUB} (9000) | ceph-cluster ${IF_CEPHCLU} v${VLAN_CEPHCLU} (9000)
  VIP API   : ${VIP}  (configurato piu' avanti da Kolla/Keepalived)

  Prova rapida:
    ssh -i ${DEPLOY_KEY} root@$(mgmt_ip "${ALL_NODES[0]}") "hostname; ip -br a"

  PROSSIMO PASSO: 01_prepare_nodes_3NODE.sh
EOF
  else
    cat <<EOF
+--------------------------------------------------------------+
   [FAIL] BOOTSTRAP INCOMPLETO — ${FAILURES} problema/i rilevato/i
+--------------------------------------------------------------+
  NON proseguire col 01 finche' non e' tutto [OK].
  Controlli tipici:
    - interfacce non trovate -> nomi NIC diversi: usa BOND0_OVERRIDE[nodeXX]
    - LACP non formato       -> LAG/MLAG mancante o errato sui ToR
    - jumbo non passa        -> MTU 9000 non abilitata sul trunk/switch
    - VLAN assenti           -> VLAN non in trunk verso le porte del nodo
    - dischi mancanti        -> controller RAID ancora in modalita' RAID (converti in Non-RAID)
  Se un cutover e' fallito, il nodo e' tornato da solo all'IP temporaneo.
EOF
  fi
}

## DAVE
# --from-node: il cutover e' saltato, quindi OGNI nodo deve essere gia' su bond+VLAN.
# Se un nodo non lo e', fermarsi qui con un messaggio chiaro (meglio che scoprirlo
# a meta' catena, quando il 01 non trova le reti Ceph).
## DAVE - rilevamento dei NOMI di bond e VLAN dai nodi (sola lettura). Cerca: l'interfaccia che
## porta l'IP di management / overlay / Ceph public / Ceph cluster, il suo bond padre, e la
## VLAN con l'ID di external (senza IP). I nomi devono essere uguali su tutti i nodi (Kolla usa
## un solo nome per interfaccia). Se diversi dai default li salva in ifaces.conf.
phase_detect() {
  log_step "Rilevamento nomi interfacce (bond/VLAN) sui nodi"
  local n oct fip out k v keys="IF_MGMT IF_OVERLAY IF_CEPHPUB IF_CEPHCLU IF_BOND0 IF_BOND1 IF_EXT" bad=0
  declare -A DET=() CNT=()
  for n in "${NODES[@]}"; do
    fip="$(final_ip "$n")"
    out="$(ssh_key "$fip" bash -s -- "$fip" "$(overlay_ip "$n")" "$(cephpub_ip "$n")" "$(cephclu_ip "$n")" "$VLAN_EXT" <<'EOF' 2>/dev/null
ifof()   { ip -o -4 addr show 2>/dev/null | awk -v ip="$1" '{split($4,a,"/"); if (a[1]==ip) {print $2; exit}}'; }
parent() { [ -n "$1" ] && ip -o link show dev "$1" 2>/dev/null | awk '{n=$2; sub(/:$/,"",n); if (n ~ /@/) {split(n,a,"@"); print a[2]}}'; }
extif()  { ip -d -o link show type vlan 2>/dev/null | awk -v id="$1" '$0 ~ ("vlan protocol 802.1Q id " id "( |$)") {n=$2; sub(/:$/,"",n); sub(/@.*/,"",n); print n; exit}'; }
m=$(ifof "$1"); o=$(ifof "$2"); cp=$(ifof "$3"); cc=$(ifof "$4")
echo "IF_MGMT=$m"; echo "IF_OVERLAY=$o"; echo "IF_CEPHPUB=$cp"; echo "IF_CEPHCLU=$cc"
echo "IF_BOND0=$(parent "$m")"; echo "IF_BOND1=$(parent "$cp")"; echo "IF_EXT=$(extif "$5")"
EOF
)"
    for k in $keys; do
      v="$(sed -n "s/^${k}=//p" <<<"$out" | head -n1)"
      if [ -z "$v" ]; then continue; fi
      if ! [[ "$v" =~ ^[A-Za-z0-9._-]+$ ]]; then log_fail "$n: nome non valido per ${k}: '${v}'"; bad=1; continue; fi
      CNT[$k]=$(( ${CNT[$k]:-0} + 1 ))
      if [ -z "${DET[$k]:-}" ]; then DET[$k]="$v"
      elif [ "${DET[$k]}" != "$v" ]; then
        log_fail "${k}: $n usa '${v}', gli altri '${DET[$k]}' (Kolla vuole lo stesso nome su tutti i nodi)"; bad=1
      fi
    done
  done
  for k in $keys; do
    if [ "${CNT[$k]:-0}" -lt "${#NODES[@]}" ]; then
      if [ "$k" = IF_EXT ]; then
        log_warn "${k}: nessuna VLAN con ID ${VLAN_EXT} trovata su tutti i nodi: uso '${!k}'"
      else
        log_fail "${k}: non trovato su tutti i nodi (controlla che l'IP atteso sia sull'interfaccia e che il VLAN ID in lib_topology.sh sia quello reale)"; bad=1
      fi
    fi
  done
  [ "$bad" = 1 ] && return 1
  local changed=0
  for k in $keys; do
    [ -n "${DET[$k]:-}" ] || continue
    printf -v "$k" '%s' "${DET[$k]}"
    log_ok "${k} = ${DET[$k]}"
  done
  # confronto coi default: se tutti uguali, ifaces.conf non serve (e uno vecchio va tolto)
  [ "$IF_MGMT" != "vlan${VLAN_MGMT}" ] || [ "$IF_OVERLAY" != "vlan${VLAN_OVERLAY}" ] || [ "$IF_EXT" != "vlan${VLAN_EXT}" ] || \
  [ "$IF_CEPHPUB" != "vlan${VLAN_CEPHPUB}" ] || [ "$IF_CEPHCLU" != "vlan${VLAN_CEPHCLU}" ] || \
  [ "$IF_BOND0" != "bond0" ] || [ "$IF_BOND1" != "bond1" ] && changed=1
  local conf; conf="${IFACES_CONF:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ifaces.conf}"
  if [ "$changed" = 1 ]; then
    {
      echo "# Nomi delle interfacce rilevati da 00_bootstrap_baremetal_v2.sh il $(date '+%Y-%m-%d %H:%M')."
      echo "# File generato: non modificare a mano (si rigenera con 00 --detect-ifaces)."
      for k in $keys; do echo "${k}=\"\${${k}:-${!k}}\""; done
    } > "$conf"
    log_ok "nomi diversi dai default: salvati in ${conf}"
  else
    rm -f "$conf"; log_ok "nomi uguali ai default (bond0/bond1/vlan<ID>): nessun ifaces.conf necessario"
  fi
  return 0
}
## DAVE

phase_from_node_check() {
  log_step "Lancio da ${SELF}: verifico che tutti i nodi siano gia' su bond + VLAN ${VLAN_MGMT}"
  phase_detect || exit 1
  local n fip bad=0
  for n in "${NODES[@]}"; do
    fip="$(final_ip "$n")"
    if on_new_net "$fip" >/dev/null 2>&1; then log_ok "$n: ${IF_MGMT} con ${fip}"
    else log_fail "$n: nessun IP ${fip} su ${IF_MGMT} (rete non ancora configurata)"; bad=1; fi
  done
  if [ "$bad" = 1 ]; then
    log_error "Cutover di rete necessario: va fatto da un host ESTERNO ai nodi (sudo bash $0 senza --from-node)."
    exit 1
  fi
}
## DAVE

## DAVE - hostname + /etc/hosts su TUTTI i nodi, sempre (anche con bond/VLAN gia' configurati
## o con --from-node, dove il cutover non gira): senza, i prechecks Kolla/RabbitMQ non
## risolvono i nomi degli altri nodi ("getent ahostsv4 node02" fallisce). Idempotente.
phase_hosts() {
  log_step "Nomi dei nodi — hostname e /etc/hosts"
  local hosts_block="" hn n fip
  for hn in "${ALL_NODES[@]}"; do
    hosts_block+="$(mgmt_ip "$hn") ${hn} ${hn}.${DOMAIN}"$'\n'
  done
  for n in "${NODES[@]}"; do
    fip="$(final_ip "$n")"
    if ssh_key "$fip" bash <<EOF >/dev/null 2>&1
hostnamectl set-hostname ${n}
cat > /etc/hosts <<H
127.0.0.1 localhost
::1       localhost ip6-localhost ip6-loopback
${hosts_block}${VIP} api.${DOMAIN}
H
getent hosts ${NODES[0]} >/dev/null
EOF
    then log_ok "${n}: hostname e /etc/hosts aggiornati"
    else log_fail "${n}: impossibile aggiornare /etc/hosts su ${fip}"; FAILURES=$((FAILURES+1)); fi
  done
}
## DAVE

main() {
  log_step "Bootstrap ${#ALL_NODES[@]} nodi (chiavi SSH + bond/VLAN) — v2"
  topo_validate || { log_error "Topologia non valida (vedi lib_topology.sh)"; exit 1; }

  if [ "$DO_CUTOVER" = 1 ] && echo "$BOND0_IFACES $BOND1_IFACES" | grep -q REPLACE_; then
    log_error "BOND0_IFACES / BOND1_IFACES non compilati."
    log_error "Lancia prima:  sudo bash $0 --discover"
    exit 1
  fi

  phase_precheck
  [ "$DO_KEYS" = 1 ]     && phase_keys
## DAVE
  [ "$FROM_NODE" = 1 ] && [ "$DO_DISCOVER" = 0 ] && phase_from_node_check
## DAVE
  ## DAVE
  [ "$DETECT_ONLY" = 1 ] && { phase_detect; exit $?; }
  ## DAVE
  [ "$DO_DISCOVER" = 1 ] && { phase_discover; exit 0; }
  [ "$DO_CUTOVER" = 1 ]  && phase_cutover
  ## DAVE
  { [ "$DO_CUTOVER" = 1 ] || [ "$FROM_NODE" = 1 ]; } && phase_hosts
  ## DAVE
  [ "$DO_NTP" = 1 ]      && phase_ntp
  [ "$DO_VERIFY" = 1 ]   && phase_verify
  print_summary
  [ "$FAILURES" -eq 0 ] || exit 1
}

main

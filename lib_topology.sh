#!/usr/bin/env bash
# shellcheck disable=SC2034  # variabili consumate dagli script che fanno source di questa lib
# =============================================================================
# lib_topology.sh — SORGENTE UNICA della topologia.
#   Sourced da 00/01/01b/02/03. Definisce QUALI nodi esistono e CHE RUOLO hanno,
#   e deriva da qui IP, inventory Kolla, host-map cephadm, reservation Nova.
#
#   SCALARE = modificare SOLO questo file: aggiungi righe a NODE_MGMT_IP e
#   aggiorna gli elenchi dei ruoli. Nessun valore hardcoded sparso negli script.
#
#   DECISIONI DI PROGETTO:
#     - control plane e MON restano DISPARI (quorum): 3 fino a 6 nodi, 5 a 9 nodi.
#     - "control isolato" dai 6 nodi: i nodi di controllo NON fanno compute
#       (ma restano OSD/storage). A 3 nodi e' l'eccezione: fanno tutto per forza.
#     - storage/OSD = SEMPRE tutti i nodi.
# =============================================================================

# ============================================================================
# >>> FASE ATTIVA: scegli UN blocco. Attivo = FASE 1 (3 nodi, novembre). <<<
# ============================================================================

# -------- FASE 1 — 3 nodi (novembre) — ATTIVA -------------------------------
declare -A NODE_MGMT_IP=(
  [node01]="10.0.10.11" [node02]="10.0.10.12" [node03]="10.0.10.13"
)
CONTROL_NODES=(node01 node02 node03)   # control plane (Galera/RabbitMQ/OVN DB) + VIP
MON_NODES=(node01 node02 node03)       # Ceph MON  (dispari, >=3)
MGR_NODES=(node01 node02)              # Ceph MGR  (attivo + standby)
COMPUTE_NODES=(node01 node02 node03)   # Nova. A 3 nodi = control (servono compute!)

# -------- FASE 2 — 6 nodi (dicembre) — decommenta e sostituisci -------------
# declare -A NODE_MGMT_IP=(
#   [node01]="10.0.10.11" [node02]="10.0.10.12" [node03]="10.0.10.13"
#   [node04]="10.0.10.14" [node05]="10.0.10.15" [node06]="10.0.10.16"
# )
# CONTROL_NODES=(node01 node02 node03)   # control ISOLATO: NON compute
# MON_NODES=(node01 node02 node03)
# MGR_NODES=(node01 node02)
# COMPUTE_NODES=(node04 node05 node06)   # compute dedicati
#                                        # storage = tutti e 6 (derivato)

# -------- FASE 3 — 9 nodi (febbraio 2027) — decommenta e sostituisci --------
# declare -A NODE_MGMT_IP=(
#   [node01]="10.0.10.11" [node02]="10.0.10.12" [node03]="10.0.10.13"
#   [node04]="10.0.10.14" [node05]="10.0.10.15" [node06]="10.0.10.16"
#   [node07]="10.0.10.17" [node08]="10.0.10.18" [node09]="10.0.10.19"
# )
# CONTROL_NODES=(node01 node02 node03 node04 node05)   # 5 control
# MON_NODES=(node01 node02 node03 node04 node05)        # 5 MON
# MGR_NODES=(node01 node02 node03)                      # 3 MGR
# COMPUTE_NODES=(node06 node07 node08 node09)           # 4 compute dedicati
#                                                       # storage = tutti e 9

# ============================================================================
# COSTANTI DI RETE (uguali in tutte le fasi)
# ============================================================================
DEPLOY_KEY="/root/.ssh/id_ed25519_os_3node"

# --- VLAN ID: devono COMBACIARE con quelli configurati sullo switch di rete. ---
# Questi sono solo valori di ripiego (placeholder 'xxN', ordine:
# overlay=..2, external=..3, ceph-public=..4, ceph-cluster=..5). Appena il
# Quando si hanno i VID reali, si cambiano QUI: il tag netplan, i nomi interfaccia
# (vlanNNNN) e i riferimenti in globals si aggiornano tutti di conseguenza.
# I valori sotto sono PROVVISORI finche' non arrivano i VID definitivi.
MGMT_NET="10.0.10";    VLAN_MGMT=10;     MGMT_GW="10.0.10.1"   # <-- VID mgmt (VRF di management) DA CONFERMARE
OVERLAY_NET="10.0.20"; VLAN_OVERLAY=20                          # <-- VID overlay (..2) DA CONFERMARE
VLAN_EXT=30                                       # external/provider: nessun IP host <-- VID external (..3) DA CONFERMARE
CEPHPUB_NET="10.0.40"; VLAN_CEPHPUB=40                          # <-- VID ceph-public (..4) DA CONFERMARE
CEPHCLU_NET="10.0.50"; VLAN_CEPHCLU=50                          # <-- VID ceph-cluster (..5) DA CONFERMARE
DNS_SERVERS="8.8.8.8, 1.1.1.1"
VIP="10.0.10.100"
## DAVE
# Router id VRRP di keepalived (1-255): deve essere unico nella VLAN di management. Cambialo in
# topology.conf se un altro cluster nella stessa VLAN usa gia' 51 (vedi la procedura).
VRRP_ROUTER_ID="${VRRP_ROUTER_ID:-51}"
## DAVE
DOMAIN="openstack.local"

## DAVE - PIANO IP DA FILE. Gli IP reali dei nodi (e la rete) possono non essere quelli sopra e non
## seguire lo schema "stesso ultimo ottetto, /24". topology.conf (accanto a questo file) li
## sovrascrive: lo scrive "configura_topologia.sh" guardando i nodi, non va modificato a mano.
## Puo' contenere: NODE_MGMT_IP e NODE_OVERLAY_IP / NODE_CEPHPUB_IP / NODE_CEPHCLU_IP (un IP per nodo),
## MGMT_NET, MGMT_GW, VIP, DNS_SERVERS, VLAN_*, *_PREFIX, CEPH_PUBLIC_CIDR, CEPH_CLUSTER_CIDR.
## Senza il file valgono i valori di default sopra (IP per nodo = rete + ultimo ottetto dell'IP di management).
MGMT_PREFIX=24; OVERLAY_PREFIX=24; CEPHPUB_PREFIX=24; CEPHCLU_PREFIX=24
declare -gA NODE_OVERLAY_IP=() NODE_CEPHPUB_IP=() NODE_CEPHCLU_IP=()
_TOPOLOGY_CONF="${TOPOLOGY_CONF:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/topology.conf}"
# shellcheck disable=SC1090
[ -f "$_TOPOLOGY_CONF" ] && source "$_TOPOLOGY_CONF"
CEPH_PUBLIC_CIDR="${CEPH_PUBLIC_CIDR:-${CEPHPUB_NET}.0/24}"
CEPH_CLUSTER_CIDR="${CEPH_CLUSTER_CIDR:-${CEPHCLU_NET}.0/24}"
## DAVE

## DAVE - NOMI delle interfacce di rete (bond e VLAN). I VLAN ID sono sopra; qui i NOMI, che
## sul sistema possono essere qualunque (vlan10, bond0.10, mgmt, ...). Default: bond0/bond1 e
## vlan<ID>. Priorita': variabile d'ambiente > ifaces.conf > default. Il file ifaces.conf
## (accanto a questo) lo scrive da solo "00_bootstrap_baremetal_v2.sh --detect-ifaces" (e il
## lancio con --from-node) guardando i nodi: non va modificato a mano.
_IFACES_CONF="${IFACES_CONF:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ifaces.conf}"
# shellcheck disable=SC1090
[ -f "$_IFACES_CONF" ] && source "$_IFACES_CONF"
IF_BOND0="${IF_BOND0:-bond0}"                     # OpenStack: mgmt + overlay + external
IF_BOND1="${IF_BOND1:-bond1}"                     # Ceph: public + cluster
IF_MGMT="${IF_MGMT:-vlan${VLAN_MGMT}}"            # management / API (porta l'IP del nodo)
IF_OVERLAY="${IF_OVERLAY:-vlan${VLAN_OVERLAY}}"   # tenant / Geneve
IF_EXT="${IF_EXT:-vlan${VLAN_EXT}}"               # external / provider (senza IP)
IF_CEPHPUB="${IF_CEPHPUB:-vlan${VLAN_CEPHPUB}}"   # Ceph public
IF_CEPHCLU="${IF_CEPHCLU:-vlan${VLAN_CEPHCLU}}"   # Ceph cluster
## DAVE

# ============================================================================
# LAB_MODE — 1 = lab con VM annidate (non baremetal). Attiva con:  LAB_MODE=1 ...
#   Sul ferro (default 0): bond LACP 802.3ad, Nova virt_type kvm, reservation piena.
#   In lab: bond active-backup (i bridge Linux NON negoziano LACP), virt_type qemu
#   (se manca la virt annidata), reservation ridotta (le VM di lab hanno poca RAM).
# ============================================================================
LAB_MODE="${LAB_MODE:-0}"
# LAB_KVM — solo con LAB_MODE=1: 1 = lab creato da lab_create_vms.sh su KVM
# (VM nate con bond+VLAN gia' configurati, schede e0a/e0b...); 0 = VM gia' esistenti
# su un altro hypervisor (es. VMware): si comporta come il ferro per IP e
# schede, ma con le taglie da lab. Default: uguale a LAB_MODE.
LAB_KVM="${LAB_KVM:-$LAB_MODE}"
if [ "$LAB_MODE" = 1 ]; then
  BOND_PARAMS='{mode: active-backup, mii-monitor-interval: 100}'
else
  ## DAVE - lacp-rate: default 'slow' (funziona con lo switch sia a 'slow' che a 'fast'; con 'fast' sul
  ## server e 'slow' sullo switch il bond puo' flappare). LACP_RATE=fast in topology.conf se lo switch e' a fast.
  LACP_RATE="${LACP_RATE:-slow}"
  case "$LACP_RATE" in slow|fast) ;; *) echo "[WARN] LACP_RATE='$LACP_RATE' non valido: uso slow" >&2; LACP_RATE=slow ;; esac
  BOND_PARAMS="{mode: 802.3ad, lacp-rate: ${LACP_RATE}, mii-monitor-interval: 100, transmit-hash-policy: layer3+4}"
  ## DAVE
fi

# ============================================================================
# DERIVATI (non modificare)
# ============================================================================
# ultimo ottetto dell'IP mgmt -> deriva gli IP sulle altre VLAN
node_octet()   { echo "${NODE_MGMT_IP[$1]##*.}"; }
mgmt_ip()      { echo "${NODE_MGMT_IP[$1]}"; }
overlay_ip()   { echo "${NODE_OVERLAY_IP[$1]:-${OVERLAY_NET}.$(node_octet "$1")}"; }
cephpub_ip()   { echo "${NODE_CEPHPUB_IP[$1]:-${CEPHPUB_NET}.$(node_octet "$1")}"; }
cephclu_ip()   { echo "${NODE_CEPHCLU_IP[$1]:-${CEPHCLU_NET}.$(node_octet "$1")}"; }

# topo_derive: ricalcola gli array/valori derivati dagli elenchi di ruolo.
# E' una funzione (non codice inline) cosi' un test puo' sovrascrivere i ruoli
# e ri-derivare, esercitando la stessa logica del deploy reale.
topo_derive() {
  ALL_NODES=("${!NODE_MGMT_IP[@]}")
  IFS=$'\n' ALL_NODES=($(sort <<<"${ALL_NODES[*]}")); unset IFS
  STORAGE_NODES=("${ALL_NODES[@]}")     # OSD sempre su tutti i nodi
  NETWORK_NODES=("${CONTROL_NODES[@]}") # OVN gateway + HAProxy/Keepalived sul control
  DEPLOY_NODE="${CONTROL_NODES[0]}"     # dove girano Kolla e cephadm
  DEPLOY_NODE_IP="$(mgmt_ip "$DEPLOY_NODE")"
  BOOTSTRAP_MON_IP="$(cephpub_ip "${MON_NODES[0]}")"   # IP ceph-public del MON di bootstrap
}
topo_derive

_in_array() { local x="$1"; shift; for e in "$@"; do [ "$e" = "$x" ] && return 0; done; return 1; }
_is_odd()   { [ $(( $1 % 2 )) -eq 1 ]; }

## DAVE
# ============================================================================
# "STO GIRANDO SU UN NODO DEL CLUSTER?" — SELF
#   SELF = nome del nodo su cui gira lo script ("" = host esterno / bastion).
#   Si riconosce dall'IP di management presente sull'host (poi dall'hostname).
#   Serve a 00 e 05: sono le due fasi che possono tagliare il ramo su cui si
#   siedono (00 riconfigura la rete, 05 ripulisce i nodi). Con --from-node lo
#   script dichiara di sapere che parte da un nodo e adotta le protezioni.
#   TOPO_FORCE_SELF=<nodo> forza il risultato ("" = forza host esterno): solo test.
# ============================================================================
topo_detect_self() {
  SELF=""
  if [ "${TOPO_FORCE_SELF+x}" = x ]; then SELF="$TOPO_FORCE_SELF"; return 0; fi
  local n ips h
  ips=" $(ip -o -4 addr show 2>/dev/null | awk '{sub(/\/.*/,"",$4); printf "%s ", $4}') "
  for n in "${ALL_NODES[@]}"; do
    case "$ips" in *" $(mgmt_ip "$n") "*) SELF="$n"; return 0 ;; esac
  done
  h="$(hostname -s 2>/dev/null)"
  if [ -n "$h" ] && _in_array "$h" "${ALL_NODES[@]}"; then SELF="$h"; fi
  return 0
}
topo_detect_self

# La cartella del pacchetto NON deve stare dove un reset cancella (/etc/kolla,
# dati Docker/Ceph, venv): su un nodo del cluster il 05 si taglierebbe il ramo.
topo_pkg_dir_safe() {
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  case "$d/" in
    /etc/kolla/*|/etc/ceph/*|/var/lib/docker/*|/var/lib/ceph/*|/var/lib/kolla/*|/var/log/kolla/*|/var/log/ceph/*|/opt/kolla-venv/*)
      echo "$d"; return 1 ;;
  esac
  return 0
}

# Sessione che sopravvive alla caduta della console (tmux, screen, nohup, no tty)?
# Si risale la catena dei processi padre: sudo ripulisce $TMUX, ma non il processo.
topo_in_persistent_session() {
  [ -n "${TMUX:-}${STY:-}" ] && return 0
  [ ! -t 0 ] && return 0
  local p=$$ c i=0
  while [ "$p" -gt 1 ] && [ "$i" -lt 30 ]; do
    c="$(ps -o comm= -p "$p" 2>/dev/null | tr -d ' ')"
    case "$c" in tmux*|screen|SCREEN|nohup|tmux:*) return 0 ;; esac
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"; [ -n "$p" ] || break; i=$((i+1))
  done
  return 1
}
## DAVE

# ============================================================================
# VALIDAZIONE — chiamala all'inizio di ogni script (topo_validate)
# ============================================================================
topo_validate() {
  local err=0 n
  # ogni nodo di ruolo deve esistere in NODE_MGMT_IP
  for n in "${CONTROL_NODES[@]}" "${MON_NODES[@]}" "${MGR_NODES[@]}" "${COMPUTE_NODES[@]}"; do
    _in_array "$n" "${ALL_NODES[@]}" || { echo "[TOPO][ERR] '$n' in un ruolo ma assente da NODE_MGMT_IP"; err=1; }
  done
  # control plane e MON dispari e >=3 (quorum)
  _is_odd "${#CONTROL_NODES[@]}" || { echo "[TOPO][ERR] CONTROL_NODES=${#CONTROL_NODES[@]}: dev'essere dispari (3 o 5)"; err=1; }
  _is_odd "${#MON_NODES[@]}"     || { echo "[TOPO][ERR] MON_NODES=${#MON_NODES[@]}: dev'essere dispari (3 o 5)"; err=1; }
  [ "${#CONTROL_NODES[@]}" -ge 3 ] || { echo "[TOPO][ERR] servono >=3 control"; err=1; }
  [ "${#MON_NODES[@]}"     -ge 3 ] || { echo "[TOPO][ERR] servono >=3 MON"; err=1; }
  [ "${#MGR_NODES[@]}"     -ge 1 ] || { echo "[TOPO][ERR] serve >=1 MGR"; err=1; }
  [ "${#COMPUTE_NODES[@]}" -ge 1 ] || { echo "[TOPO][ERR] serve >=1 nodo compute"; err=1; }

  # policy "control isolato": oltre i 3 nodi, control e compute NON si sovrappongono
  if [ "${#ALL_NODES[@]}" -gt 3 ]; then
    for n in "${CONTROL_NODES[@]}"; do
      _in_array "$n" "${COMPUTE_NODES[@]}" && { echo "[TOPO][WARN] '$n' e' sia control sia compute: 'control isolato' previsto dai 6 nodi"; }
    done
  fi
  return $err
}

topo_summary() {
  echo "  Nodi totali : ${#ALL_NODES[@]}  (${ALL_NODES[*]})"
  echo "  control     : ${CONTROL_NODES[*]}"
  echo "  MON / MGR   : ${MON_NODES[*]}  /  ${MGR_NODES[*]}"
  echo "  compute     : ${COMPUTE_NODES[*]}"
  echo "  storage/OSD : tutti (${#STORAGE_NODES[@]})"
  echo "  deploy node : ${DEPLOY_NODE} (${DEPLOY_NODE_IP})"
}

# ============================================================================
# EMISSIONE GRUPPI INVENTORY — consumato dal 01 (splice nel template Kolla)
#   Formato: '@@GROUP <nome>' seguito dalle righe host complete.
# ============================================================================
topo_emit_inventory() {
  _emit() {
    local g="$1"; shift; echo "@@GROUP $g"
    local n; for n in "$@"; do
      echo "$n ansible_host=$(mgmt_ip "$n") ansible_user=root ansible_python_interpreter=/usr/bin/python3"
    done
  }
  _emit control    "${CONTROL_NODES[@]}"
  _emit network    "${NETWORK_NODES[@]}"
  _emit compute    "${COMPUTE_NODES[@]}"
  _emit storage    "${STORAGE_NODES[@]}"
  _emit monitoring "${CONTROL_NODES[@]}"
}

# ============================================================================
# HOST-MAP cephadm — consumato dal 01b (declare -A H nei blocchi remoti).
#   Stampa: declare -A H=( [node01]=10.0.10.11 ... )
# ============================================================================
topo_emit_cephadm_hostmap() {
  local out="declare -A H=("
  local n; for n in "${ALL_NODES[@]}"; do out+=" [$n]=$(mgmt_ip "$n")"; done
  echo "$out )"
}

# lista CSV dei MON/MGR per 'ceph orch apply' (es. "node01,node02,node03")
topo_mon_csv() { local IFS=,; echo "${MON_NODES[*]}"; }
topo_mgr_csv() { local IFS=,; echo "${MGR_NODES[*]}"; }

## DAVE
# ============================================================================
# PROXY (uscita internet solo tramite proxy)
#   PROXY_URL (topology.conf) oppure http(s)_proxy gia' presenti nell'ambiente.
#   topo_no_proxy: elenco NO_PROXY che tiene FUORI dal proxy tutto il traffico del cluster
#   (nodi, VIP, subnet): senza, API OpenStack, Ceph e CLI passerebbero dal proxy e si rompono.
#   NO_PROXY_EXTRA (topology.conf) aggiunge voci (es. un registry interno).
# ============================================================================
topo_proxy_url() { echo "${PROXY_URL:-${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}}"; }
topo_no_proxy() {
  local l="localhost,127.0.0.1,::1,.local,${DOMAIN}" n
  [ -n "${VIP:-}" ] && l+=",${VIP}"
  for n in "${ALL_NODES[@]}"; do
    l+=",${n},$(mgmt_ip "$n"),$(overlay_ip "$n"),$(cephpub_ip "$n"),$(cephclu_ip "$n")"
  done
  l+=",${MGMT_NET}.0/${MGMT_PREFIX:-24},${OVERLAY_NET}.0/${OVERLAY_PREFIX:-24},${CEPHPUB_NET}.0/${CEPHPUB_PREFIX:-24},${CEPHCLU_NET}.0/${CEPHCLU_PREFIX:-24}"
  [ -n "${NO_PROXY_EXTRA:-}" ] && l+=",${NO_PROXY_EXTRA}"
  echo "$l"
}
## DAVE

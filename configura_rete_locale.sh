#!/usr/bin/env bash
# =============================================================================
# configura_rete_locale.sh — Configura bond e VLAN SU QUESTO NODO (da console).
#
# Serve quando i nodi NON sono stati consegnati con bond/VLAN/IP gia' pronti e
# l'unico accesso e' la console. Si lancia su ogni nodo, come root:
#     sudo bash configura_rete_locale.sh
#
# Cosa fa (nell'ordine):
#   1. elenca le schede fisiche (nome, link, velocita') e chiede quali formano
#      bond0 (OpenStack: mgmt + overlay + external) e bond1 (Ceph);
#   2. chiede il piano (VLAN ID, subnet, IP dei 3 nodi, gateway, DNS) oppure
#      riusa un topology.conf gia' presente (--usa-piano), cosi' sui nodi 2 e 3
#      si risponde quasi a niente;
#   3. genera il netplan con la STESSA funzione del 00 (generate_netplan), salva
#      i netplan esistenti, applica con rollback automatico (se non si conferma entro
#      il timeout torna da solo alla rete precedente);
#   4. imposta l'hostname (node01/02/03) e controlla bond, IP e gateway;
#   5. scrive topology.conf e ifaces.conf accanto allo script: sono quelli che
#      usa poi il deploy.
#
# Opzioni:
#   --usa-piano   usa topology.conf (+ifaces.conf) gia' presenti: chiede solo
#                 il numero del nodo (e le porte, se non le riconosce)
#   --dry-run     non tocca il sistema: scrive il netplan in ./dry-run/ e basta
#   --help
#
# Variabili (facoltative): BOND0_PORTS="a b"  BOND1_PORTS="c d"  NODE_NUM=1|2|3
#                          TRY_TIMEOUT=180
# NB: va lanciato dalla CONSOLE. Da SSH la sessione cadrebbe durante l'applicazione.
# =============================================================================
## DAVE
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USA_PIANO=0; DRY=0
for a in "$@"; do
  case "$a" in
    --usa-piano) USA_PIANO=1 ;;
    --dry-run)   DRY=1 ;;
    --help|-h)   sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "Opzione sconosciuta: $a" >&2; exit 1 ;;
  esac
done

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'
say(){ echo -e "$*"; }; ok(){ say "  ${G}[OK]${N} $*"; }; warn(){ say "  ${Y}[ATTENZIONE]${N} $*"; }
err(){ say "  ${R}[ERRORE]${N} $*" >&2; }
py(){ python3 -I -c "$@"; }

[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || { err "serve root: sudo bash $0"; exit 1; }
command -v python3 >/dev/null || { err "python3 mancante"; exit 1; }
[ -f "$HERE/lib_topology.sh" ] && [ -f "$HERE/00_bootstrap_baremetal_v2.sh" ] || { err "lancia lo script dalla cartella del pacchetto deploy (manca lib_topology.sh o il 00)"; exit 1; }

OUT_DIR="$HERE"; [ "$DRY" = 1 ] && { OUT_DIR="$HERE/dry-run"; mkdir -p "$OUT_DIR"; }
EOF_N=0
ask() {  # ask "domanda" "default" -> $REPLY_V
  local q="$1" def="${2:-}" r
  if [ -n "$def" ]; then printf '%s [%s]: ' "$q" "$def"; else printf '%s: ' "$q"; fi
  IFS= read -r r || { EOF_N=$((EOF_N+1)); [ "$EOF_N" -gt 3 ] && { err "input terminato"; exit 1; }; r=""; }
  REPLY_V="${r:-$def}"
}
valid_ip()   { py 'import ipaddress,sys
try: ipaddress.IPv4Address(sys.argv[1]); print(1)
except Exception: print(0)' "$1"; }
valid_cidr() { py 'import ipaddress,sys
try: n=ipaddress.ip_network(sys.argv[1],strict=True); print(1 if n.version==4 and n.prefixlen<=29 else 0)
except Exception: print(0)' "$1"; }
in_net()     { py 'import ipaddress,sys; print(int(ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2])))' "$1" "$2"; }
prefix_of()  { py 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1]).prefixlen)' "$1"; }
base3()      { py 'import ipaddress,sys; print(".".join(str(ipaddress.ip_network(sys.argv[1]).network_address).split(".")[:3]))' "$1"; }
# stesso "numero di host" del management, dentro un'altra subnet (vuoto se non ci sta)
same_host()  { py 'import ipaddress as i,sys
m=i.ip_address(sys.argv[1]); mn=i.ip_network(sys.argv[2]); t=i.ip_network(sys.argv[3])
a=t.network_address+(int(m)-int(mn.network_address))
print(a if a in t and a not in (t.network_address,t.broadcast_address) else "")' "$1" "$2" "$3"; }

say ""
say "${B}=== Configurazione di rete locale del nodo (bond + VLAN) ===${N}"
[ -n "${SSH_CONNECTION:-}" ] && [ "$DRY" = 0 ] && warn "sei collegato in SSH: durante l'applicazione la sessione puo' cadere. Meglio la console."
## DAVE
# Su una VM senza LAB_MODE=1 il bond nascerebbe 802.3ad (i bridge Linux non fanno LACP) e la rete non
# funzionerebbe. Succede facilmente aprendo una nuova shell: le variabili 'export' non ci sono piu'.
if [ "$DRY" = 0 ] && [ "${LAB_MODE:-0}" != 1 ] && command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -q 2>/dev/null; then
  warn "questo nodo e' una VM ($(systemd-detect-virt)) ma LAB_MODE non e' 1: i bond sarebbero 802.3ad (LACP) e in lab la rete non funzionerebbe."
  warn "Se e' un lab, esci ed esegui prima:  export LAB_MODE=1 LAB_KVM=0"
  ask "Continuo comunque (nodo virtuale con LACP)? (s/N)" "N"; [[ "$REPLY_V" =~ ^[sSyY]$ ]] || { say "Annullato: nessuna modifica."; exit 1; }
fi
## DAVE

# ----------------------------- 1. schede fisiche ---------------------------
say ""
say "Schede di rete fisiche:"
printf '  %-16s %-8s %-10s %s\n' NOME LINK VELOCITA MAC
PHYS=()
for d in /sys/class/net/*; do
  n="$(basename "$d")"
  [ -e "$d/device" ] || continue          # solo schede reali
  [ -d "$d/bonding" ] && continue
  PHYS+=("$n")
  st="$(cat "$d/carrier" 2>/dev/null || echo 0)"; sp="$(cat "$d/speed" 2>/dev/null || echo '')"
  mac="$(ethtool -P "$n" 2>/dev/null | awk '{print $NF}')"; [ -z "$mac" ] && mac="$(cat "$d/address" 2>/dev/null)"
  printf '  %-16s %-8s %-10s %s\n' "$n" "$([ "$st" = 1 ] && echo SU || echo GIU)" "${sp:+${sp}M}" "$mac"
done
[ "${#PHYS[@]}" -gt 0 ] || [ "$DRY" = 1 ] || { err "nessuna scheda fisica trovata"; exit 1; }
cur0="$(cat /sys/class/net/bond0/bonding/slaves 2>/dev/null || true)"
def0="${BOND0_PORTS:-$cur0}"
# ipotesi per bond1: le schede con suffisso 'npN' (multiporta) non gia' in bond0
def1="${BOND1_PORTS:-}"
if [ -z "$def1" ]; then
  c=(); for n in "${PHYS[@]}"; do [[ "$n" =~ np[0-9]+$ ]] && ! grep -qw "$n" <<<"$def0" && c+=("$n"); done
  [ "${#c[@]}" = 2 ] && def1="${c[*]}"
fi
say ""
say "bond0 = OpenStack (management, overlay, external). bond1 = Ceph (public, cluster)."
ask "Porte di bond0 (due nomi separati da spazio)" "$def0"; B0="$REPLY_V"
ask "Porte di bond1 (due nomi separati da spazio)" "$def1"; B1="$REPLY_V"
for p in $B0 $B1; do
  [ "$DRY" = 1 ] || [ -e "/sys/class/net/$p/device" ] || { err "la scheda '$p' non esiste"; exit 1; }
done
[ "$(wc -w <<<"$B0")" = 2 ] && [ "$(wc -w <<<"$B1")" = 2 ] || { err "servono esattamente due porte per ciascun bond"; exit 1; }
for p in $B0; do grep -qw "$p" <<<"$B1" && { err "la porta $p e' in entrambi i bond"; exit 1; }; done
[ "$DRY" = 1 ] || for p in $B1; do [ "$(cat /sys/class/net/$p/carrier 2>/dev/null)" = 1 ] || warn "porta $p di bond1 senza link: le VLAN Ceph non funzioneranno finche' non e' collegata/abilitata sullo switch"; done

# ----------------------------- 2. piano ------------------------------------
NN="${NODE_NUM:-}"
PLAN="$OUT_DIR/topology.conf"
if [ "$USA_PIANO" = 1 ]; then
  PLAN="$HERE/topology.conf"
  [ -s "$PLAN" ] || { err "con --usa-piano serve $PLAN (copialo dal nodo dove e' stato creato)"; exit 1; }
  ok "uso il piano in $PLAN"
else
  say ""
  say "${B}Piano di rete${N} (i valori li fornisce il referente di rete)"
  while true; do ask "VLAN ID management" ""; VM="$REPLY_V"; [[ "$VM" =~ ^[0-9]+$ ]] && [ "$VM" -ge 1 ] && [ "$VM" -le 4094 ] && break; echo "  numero tra 1 e 4094"; done
  while true; do ask "VLAN ID overlay (tenant)" ""; VO="$REPLY_V"; [[ "$VO" =~ ^[0-9]+$ ]] && [ "$VO" -ge 1 ] && [ "$VO" -le 4094 ] && break; echo "  numero tra 1 e 4094"; done
  while true; do ask "VLAN ID external" ""; VE="$REPLY_V"; [[ "$VE" =~ ^[0-9]+$ ]] && [ "$VE" -ge 1 ] && [ "$VE" -le 4094 ] && break; echo "  numero tra 1 e 4094"; done
  while true; do ask "VLAN ID Ceph public" ""; VP="$REPLY_V"; [[ "$VP" =~ ^[0-9]+$ ]] && [ "$VP" -ge 1 ] && [ "$VP" -le 4094 ] && break; echo "  numero tra 1 e 4094"; done
  while true; do ask "VLAN ID Ceph cluster" ""; VC="$REPLY_V"; [[ "$VC" =~ ^[0-9]+$ ]] && [ "$VC" -ge 1 ] && [ "$VC" -le 4094 ] && break; echo "  numero tra 1 e 4094"; done
  ids="$VM $VO $VE $VP $VC"; [ "$(tr ' ' '\n' <<<"$ids" | sort -u | wc -l)" = 5 ] || { err "i cinque VLAN ID devono essere diversi tra loro"; exit 1; }
  for spec in "CM|management|" "CO|overlay|" "CP|Ceph public|" "CC|Ceph cluster|"; do
    IFS='|' read -r var lbl _ <<<"$spec"
    while true; do ask "Subnet $lbl (es. 10.1.2.0/24)" ""; [ "$(valid_cidr "$REPLY_V")" = 1 ] && break; echo "  subnet non valida (serve l'indirizzo di rete, es. 10.1.2.0/24)"; done
    printf -v "$var" '%s' "$REPLY_V"
  done
  while true; do ask "Gateway della management" ""; GW="$REPLY_V"; [ "$(valid_ip "$GW")" = 1 ] && [ "$(in_net "$GW" "$CM")" = 1 ] && break; echo "  deve essere un IPv4 dentro $CM"; done
  ask "Server DNS (separati da spazio)" "8.8.8.8 1.1.1.1"; DNS="$REPLY_V"; DNS_CSV="$(tr -s ' ' <<<"$DNS" | sed 's/ /, /g')"
  declare -A AM AO AP AC
  for k in 1 2 3; do
    while true; do ask "IP di management di node0$k" ""; AM[$k]="$REPLY_V"; [ "$(valid_ip "${AM[$k]}")" = 1 ] && [ "$(in_net "${AM[$k]}" "$CM")" = 1 ] && break; echo "  deve essere dentro $CM"; done
  done
  [ "$(printf '%s\n' "${AM[@]}" | sort -u | wc -l)" = 3 ] || { err "i tre IP di management devono essere diversi"; exit 1; }
  for k in 1 2 3; do
    for spec in "AO|$CO|overlay" "AP|$CP|Ceph public" "AC|$CC|Ceph cluster"; do
      IFS='|' read -r arr cidr lbl <<<"$spec"
      d="$(same_host "${AM[$k]}" "$CM" "$cidr")"
      while true; do ask "IP $lbl di node0$k" "$d"; v="$REPLY_V"; [ "$(valid_ip "$v")" = 1 ] && [ "$(in_net "$v" "$cidr")" = 1 ] && break; echo "  deve essere dentro $cidr"; done
      eval "$arr[$k]=\"$v\""
    done
  done
  say ""
  say "VIP: indirizzo LIBERO della management riservato alle API."
  while true; do
    ask "VIP" ""; VIP="$REPLY_V"
    { [ "$(valid_ip "$VIP")" = 1 ] && [ "$(in_net "$VIP" "$CM")" = 1 ]; } || { echo "  deve essere un IPv4 dentro $CM"; continue; }
    if [ "$VIP" = "${AM[1]}" ] || [ "$VIP" = "${AM[2]}" ] || [ "$VIP" = "${AM[3]}" ]; then echo "  coincide con l'IP di un nodo"; continue; fi
    break
  done

  say ""
  say "${B}=== Riepilogo ===${N}"
  printf '  %-14s %-6s %-20s %-15s %-15s %-15s\n' RETE VLAN SUBNET node01 node02 node03
  printf '  %-14s %-6s %-20s %-15s %-15s %-15s\n' management "$VM" "$CM" "${AM[1]}" "${AM[2]}" "${AM[3]}"
  printf '  %-14s %-6s %-20s %-15s %-15s %-15s\n' overlay "$VO" "$CO" "${AO[1]}" "${AO[2]}" "${AO[3]}"
  printf '  %-14s %-6s %-20s %-15s %-15s %-15s\n' ceph-public "$VP" "$CP" "${AP[1]}" "${AP[2]}" "${AP[3]}"
  printf '  %-14s %-6s %-20s %-15s %-15s %-15s\n' ceph-cluster "$VC" "$CC" "${AC[1]}" "${AC[2]}" "${AC[3]}"
  printf '  %-14s %-6s\n' external "$VE"
  say "  bond0: $B0   |   bond1: $B1"
  say "  gateway $GW   DNS $DNS_CSV   VIP $VIP"
  ask "Il piano e' corretto? (s/N)" "N"; [[ "$REPLY_V" =~ ^[sSyY]$ ]] || { say "Annullato: nessuna modifica."; exit 0; }

  mapl(){ local a="$1" out="" k; for k in 1 2 3; do eval "out+=\"[node0$k]=\\\"\${$a[$k]}\\\" \""; done; echo "(${out% })"; }
  {
    echo "# Piano di rete inserito a mano da configura_rete_locale.sh il $(date '+%Y-%m-%d %H:%M')."
    echo "# File generato: non modificare a mano (si rigenera lanciando di nuovo lo script)."
    echo "declare -gA NODE_MGMT_IP=$(mapl AM)"
    echo "declare -gA NODE_OVERLAY_IP=$(mapl AO)"
    echo "declare -gA NODE_CEPHPUB_IP=$(mapl AP)"
    echo "declare -gA NODE_CEPHCLU_IP=$(mapl AC)"
    echo "MGMT_NET=\"$(base3 "$CM")\"; OVERLAY_NET=\"$(base3 "$CO")\""
    echo "CEPHPUB_NET=\"$(base3 "$CP")\"; CEPHCLU_NET=\"$(base3 "$CC")\""
    echo "MGMT_PREFIX=$(prefix_of "$CM"); OVERLAY_PREFIX=$(prefix_of "$CO")"
    echo "CEPHPUB_PREFIX=$(prefix_of "$CP"); CEPHCLU_PREFIX=$(prefix_of "$CC")"
    echo "CEPH_PUBLIC_CIDR=\"$CP\"; CEPH_CLUSTER_CIDR=\"$CC\""
    echo "VLAN_MGMT=$VM; VLAN_OVERLAY=$VO; VLAN_EXT=$VE; VLAN_CEPHPUB=$VP; VLAN_CEPHCLU=$VC"
    echo "MGMT_GW=\"$GW\"; VIP=\"$VIP\"; DNS_SERVERS=\"$DNS_CSV\""
  } > "$PLAN.new" && mv -f "$PLAN.new" "$PLAN"
  ok "scritto $PLAN"
fi

# ifaces.conf coerente con il piano (nomi = vlan<ID>, bond0, bond1)
## DAVE
# Il piano si carica con LAB_MODE=0 (niente default da lab per IP e nomi), ma il TIPO DI BOND
# deve seguire il LAB_MODE scelto dall'operatore: in lab i bridge Linux non negoziano LACP.
_LAB_ORIG="${LAB_MODE:-0}"
## DAVE
export TOPOLOGY_CONF="$PLAN" IFACES_CONF=/nonexistent LAB_MODE=0
unset IF_MGMT IF_OVERLAY IF_EXT IF_CEPHPUB IF_CEPHCLU IF_BOND0 IF_BOND1
# shellcheck disable=SC1091
source "$HERE/lib_topology.sh" >/dev/null 2>&1 || { err "lib_topology.sh non leggibile con questo piano"; exit 1; }
## DAVE
if [ "$_LAB_ORIG" = 1 ]; then
  BOND_PARAMS='{mode: active-backup, mii-monitor-interval: 100}'; warn "LAB_MODE=1: bond active-backup (solo lab, niente LACP)"
  # Lab su KVM/libvirt: il filtro anti-spoofing scarta i frame con un MAC diverso da quello della NIC.
  # Il bond deve quindi usare il MAC permanente della sua prima porta (sul ferro NON si fa).
  BOND0_MAC="$(ethtool -P "${B0%% *}" 2>/dev/null | awk '{print $NF}')"; BOND1_MAC="$(ethtool -P "${B1%% *}" 2>/dev/null | awk '{print $NF}')"
  [[ "$BOND0_MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || BOND0_MAC=""
  [[ "$BOND1_MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || BOND1_MAC=""
  [ -n "$BOND0_MAC$BOND1_MAC" ] && warn "LAB_MODE=1: i bond usano il MAC della prima porta (${BOND0_MAC:--} / ${BOND1_MAC:--})"
fi
## DAVE
{
  { echo "# Nomi delle interfacce creati da configura_rete_locale.sh il $(date '+%Y-%m-%d %H:%M')."
    echo "# File generato: non modificare a mano."
    for k in IF_MGMT IF_OVERLAY IF_EXT IF_CEPHPUB IF_CEPHCLU IF_BOND0 IF_BOND1; do echo "${k}=\"\${${k}:-${!k}}\""; done
  } > "$OUT_DIR/ifaces.conf"
  ok "scritto $OUT_DIR/ifaces.conf  (${IF_MGMT} ${IF_OVERLAY} ${IF_EXT} ${IF_CEPHPUB} ${IF_CEPHCLU})"
}

# numero del nodo
while [ -z "$NN" ] || ! [[ "$NN" =~ ^[123]$ ]]; do ask "Quale nodo e' QUESTO (1, 2 o 3)" ""; NN="$REPLY_V"; done
NODE="node0$NN"

# ----------------------------- 3. netplan ----------------------------------
declare -A NODE_OCTET=(); for k in "${ALL_NODES[@]}"; do NODE_OCTET[$k]="$(node_octet "$k")"; done
BOND0_IFACES="$B0"; BOND1_IFACES="$B1"; declare -A BOND0_OVERRIDE=() BOND1_OVERRIDE=()
bond0_of() { echo "${BOND0_OVERRIDE[$1]:-$BOND0_IFACES}"; }; bond1_of() { echo "${BOND1_OVERRIDE[$1]:-$BOND1_IFACES}"; }
eval "$(sed -n '/^generate_netplan()/,/^}/p' "$HERE/00_bootstrap_baremetal_v2.sh")"
NP="$OUT_DIR/60-openstack.yaml"
generate_netplan "$NODE" > "$NP.tmp" && mv -f "$NP.tmp" "$NP" || { err "generazione del netplan fallita"; exit 1; }
chmod 600 "$NP"
py 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$NP" 2>/dev/null || warn "controllo YAML non eseguito/non riuscito (PyYAML assente?)"
ok "netplan generato per $NODE: $NP"
if [ "$DRY" = 1 ]; then say ""; say "--dry-run: nessuna modifica al sistema. File in $OUT_DIR"; exit 0; fi

say ""
say "Sto per applicare la rete su ${B}${NODE}${N}: ${IF_BOND0} = ${B0}, ${IF_BOND1} = ${B1}, IP management $(mgmt_ip "$NODE")"
## DAVE
say "Si applica con 'netplan apply' e un rollback automatico: se non confermi entro ${TRY_TIMEOUT:-180} secondi la rete precedente viene ripristinata."
## DAVE
ask "Procedo? (s/N)" "N"; [[ "$REPLY_V" =~ ^[sSyY]$ ]] || { say "Annullato: nessuna modifica."; exit 0; }

BK="/root/netplan-backup-locale-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"
for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do [ -e "$f" ] && cp -a "$f" "$BK/" && rm -f "$f"; done
cp -a "$NP" /etc/netplan/60-openstack.yaml; chmod 600 /etc/netplan/60-openstack.yaml
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg 2>/dev/null || true
restore() { rm -f /etc/netplan/60-openstack.yaml; cp -a "$BK"/. /etc/netplan/ 2>/dev/null; netplan generate 2>/dev/null; netplan apply 2>/dev/null; }
if ! netplan generate 2>"$OUT_DIR/netplan.err"; then
  err "netplan non valido: $(head -3 "$OUT_DIR/netplan.err" | tr '\n' ' ')"; restore; err "ripristinata la configurazione precedente (backup in $BK)"; exit 1
fi
# se esiste una VLAN di management provvisoria creata a mano con 'ip', la tolgo (solo da console)
[ -z "${SSH_CONNECTION:-}" ] && ip link del "${IF_MGMT}" 2>/dev/null || true
## DAVE
# Da console: tolgo anche le VLAN preesistenti con uno dei NOSTRI ID sui nostri bond (es. la VLAN di
# management consegnata da chi installa, con lo stesso ID ma un altro nome): il kernel non ammette
# due VLAN con lo stesso ID sullo stesso bond, e verranno ricreate dal nuovo piano.
if [ -z "${SSH_CONNECTION:-}" ]; then
  for _v in $(ip -o link show type vlan 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//'); do
    _id="$(ip -d link show "$_v" 2>/dev/null | grep -o 'vlan protocol 802.1Q id [0-9]*' | awk '{print $NF}')"
    _lk="$(ip -o link show "$_v" 2>/dev/null | sed -n 's/^[0-9]*: [^@]*@\([^:]*\):.*/\1/p')"
    case " $VLAN_MGMT $VLAN_OVERLAY $VLAN_EXT $VLAN_CEPHPUB $VLAN_CEPHCLU " in *" $_id "*) ;; *) continue ;; esac
    case "$_lk" in "$IF_BOND0"|"$IF_BOND1") ;; *) continue ;; esac
    ip link del "$_v" 2>/dev/null && warn "tolta la VLAN preesistente ${_v} (ID ${_id} su ${_lk}): viene ricreata dal nuovo piano"
  done
fi
# 'netplan try' NON e' utilizzabile: rifiuta di partire se un bond ha 'parameters' ("reverting custom
# parameters for bridges and bonds is not supported"). Rollback fatto a mano: un timer systemd
# ripristina i vecchi netplan se non si conferma; poi 'netplan apply' e conferma con INVIO.
TRY_T="${TRY_TIMEOUT:-180}"
RBS=/usr/local/sbin/netplan-rollback-locale.sh
cat > "$RBS" <<RB
#!/bin/sh
rm -f /etc/netplan/60-openstack.yaml
cp -a "$BK"/. /etc/netplan/ 2>/dev/null
netplan generate 2>/dev/null; netplan apply 2>/dev/null
logger -t netplan-rollback-locale "ROLLBACK ESEGUITO"
RB
chmod +x "$RBS"
rb_disarm() { systemctl stop netplan-rollback-locale.timer 2>/dev/null; systemctl reset-failed netplan-rollback-locale.service netplan-rollback-locale.timer 2>/dev/null; true; }
rb_disarm
if ! systemd-run --unit=netplan-rollback-locale --on-active="$((TRY_T + 10))" "$RBS" >/dev/null 2>&1; then
  err "impossibile armare il rollback automatico (systemd-run): non applico nulla"; restore; exit 1
fi
# Da console: tolgo anche i bond preesistenti (verranno ricreati dal nuovo piano). Un bond che esiste
# gia' NON cambia modalita' ne' parametri con 'netplan apply' (es. lacp-rate, hash): ricrearlo li fa
# applicare davvero. Il rollback armato sopra copre un eventuale errore.
if [ -z "${SSH_CONNECTION:-}" ]; then
  for _b in "$IF_BOND0" "$IF_BOND1"; do
    if [ -d "/sys/class/net/$_b" ] && ip link del "$_b" 2>/dev/null; then warn "tolto il bond preesistente ${_b}: viene ricreato dal nuovo piano"; fi
  done
fi
netplan apply 2>"$OUT_DIR/netplan-apply.err" || warn "netplan apply ha segnalato errori: $(head -3 "$OUT_DIR/netplan-apply.err" | tr '\n' ' ')"
say "Attendo che la rete risalga (fino a 90 s: con un LACP vero servono anche 30-60 s)..."
GWOK=0
for _i in $(seq 1 18); do
  if ping -c1 -W2 "$MGMT_GW" >/dev/null 2>&1; then GWOK=1; break; fi
  sleep 3
done
if [ "$GWOK" = 1 ]; then ok "gateway $MGMT_GW raggiungibile"; else warn "gateway $MGMT_GW NON raggiungibile: NON confermare (lascia scadere il timeout)"; fi
say "Rete applicata. Se e' tutto a posto premi INVIO entro ${TRY_T} secondi per CONFERMARE;"
say "altrimenti (o se non rispondi) la rete di prima viene ripristinata da sola."
CONF=0; if read -r -t "$TRY_T" _ans; then CONF=1; fi
if [ "$CONF" = 1 ]; then
  rb_disarm
  ok "rete applicata e confermata (backup dei vecchi netplan in $BK)"
else
  rb_disarm
  err "rete NON confermata: ripristinata la configurazione precedente (backup in $BK)"; restore; exit 1
fi
## DAVE

# ----------------------------- 4. hostname e controlli ---------------------
hostnamectl set-hostname "$NODE" 2>/dev/null && ok "hostname: $NODE"
sleep 5
say ""
say "${B}=== Controlli ===${N}"
ip -br addr show | grep -E "^(${IF_BOND0}|${IF_BOND1}|vlan)"
for b in "$IF_BOND0" "$IF_BOND1"; do
  [ -r "/proc/net/bonding/$b" ] || { warn "$b non presente"; continue; }
  nsl="$(grep -c '^Slave Interface' "/proc/net/bonding/$b")"
  nup="$(awk '/^Slave Interface/{s=$3} /MII Status/&&s{ if($3=="up") u++; s=""} END{print u+0}' "/proc/net/bonding/$b")"
  nag="$(grep -E 'Aggregator ID' "/proc/net/bonding/$b" | awk '{print $NF}' | sort -u | wc -l)"
  [ "$nup" = 2 ] && ok "$b: 2 link su" || warn "$b: $nup link su su $nsl (collegare/abilitare le porte sullo switch)"
  [ "$nag" -le 1 ] || warn "$b: i due link NON sono nello stesso aggregato LACP (Aggregator ID diversi): controllare la configurazione del port-channel/MLAG sullo switch"
done
if ping -c2 -W2 "$MGMT_GW" >/dev/null 2>&1; then ok "gateway $MGMT_GW raggiungibile"; else warn "gateway $MGMT_GW NON raggiungibile (VLAN $VLAN_MGMT non trunkata su bond0, IP o gateway errati?)"; fi
say ""
say "Fatto su ${NODE}. Ripeti su ogni nodo (sui nodi 2 e 3: copia prima topology.conf e ifaces.conf da questo e usa --usa-piano)."
say "Quando i 3 nodi sono a posto: chiavi SSH, poi configura_topologia.sh e run_all.sh --from-node."
## DAVE

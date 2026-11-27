#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Davide Marino
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
# configura_topologia.sh — scopre dai nodi IP, VLAN e nomi delle interfacce e scrive
#   topology.conf e ifaces.conf (accanto a lib_topology.sh).
#
#   Serve quando i nodi arrivano GIA' configurati da altri (bond, VLAN, IP) e non si
#   conoscono in anticipo ne' gli IP ne' i VLAN ID ne' i nomi delle interfacce.
#   SOLA LETTURA sui nodi: non modifica nulla su nessun server. Scrive solo i due file
#   di configurazione del pacchetto (con copia di sicurezza di quelli esistenti).
#
#   USO (da root, su node01, dopo aver messo la chiave SSH di deploy su tutti i nodi):
#     sudo bash configura_topologia.sh
#         legge le interfacce di questo nodo, chiede quale rete e' quale, chiede gli IP di
#         management degli altri nodi e li legge via SSH (a chiave).
#
#   SENZA SSH (le chiavi non ci sono ancora):
#     su OGNI nodo:   sudo bash configura_topologia.sh --facts > node0X.facts
#     poi in una cartella con i 3 file:   sudo bash configura_topologia.sh --facts-dir <cartella>
#
#   Dopo: bash ../OPENSTACK_tests_*/test_render.sh deve dare tutti PASS, poi run_all.sh --from-node.
# =============================================================================
## DAVE
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${TOPOLOGY_OUT_DIR:-$HERE}"
DEPLOY_KEY="${DEPLOY_KEY:-/root/.ssh/id_ed25519_os_3node}"
NODE_NAMES=(node01 node02 node03)
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR)

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'
say()  { echo -e "$*"; }
err()  { echo -e "${R}[ERRORE]${N} $*" >&2; }
warn() { echo -e "${Y}[ATTENZIONE]${N} $*"; }
ok()   { echo -e "  ${G}[OK]${N} $*"; }

# -----------------------------------------------------------------------------
# facts_here — stampa i fatti di rete di QUESTO host (sola lettura). Righe:
#   HOST|nome
#   IFACE|nome|ip/prefisso|mtu|vlan-id|padre      (interfacce con un IPv4 globale)
#   VLAN|nome|vlan-id|padre                        (tutte le interfacce VLAN, con o senza IP)
#   DEFROUTE|interfaccia|gateway
#   DNS|ip ip ...
# E' una funzione: la stessa viene mandata ai nodi remoti via SSH.
# -----------------------------------------------------------------------------
facts_here() {
  local n cidr line mtu vid par
  echo "HOST|$(hostname -s 2>/dev/null)"
  for n in $(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2}' | sort -u); do
    case "$n" in docker*|veth*|br-*|virbr*|lo|tailscale*|tun*) continue ;; esac
    cidr="$(ip -o -4 addr show dev "$n" scope global 2>/dev/null | awk '{print $4; exit}')"
    line="$(ip -d -o link show dev "$n" 2>/dev/null | head -n1)"
    mtu="$(sed -n 's/.* mtu \([0-9]*\).*/\1/p' <<<"$line" | head -n1)"
    vid="$(sed -n 's/.*vlan protocol 802.1Q id \([0-9]*\).*/\1/p' <<<"$line" | head -n1)"
    par="$(awk '{x=$2; sub(/:$/,"",x); if (x ~ /@/) {split(x,a,"@"); print a[2]}}' <<<"$line")"
    echo "IFACE|$n|$cidr|$mtu|$vid|$par"
  done
  ip -d -o link show type vlan 2>/dev/null | awk '
    { x=$2; sub(/:$/,"",x); par=""; if (x ~ /@/) {split(x,a,"@"); x=a[1]; par=a[2]}
      id=""; if (match($0, /vlan protocol 802.1Q id [0-9]+/)) { id=substr($0, RSTART, RLENGTH); sub(/.* id /, "", id) }
      print "VLAN|" x "|" id "|" par }'
  ip -o route show default 2>/dev/null | awk '{d="";v=""; for(i=1;i<=NF;i++){if($i=="dev")d=$(i+1); if($i=="via")v=$(i+1)} print "DEFROUTE|" d "|" v; exit}'
  local dns=""
  if command -v resolvectl >/dev/null 2>&1; then
    dns="$(resolvectl dns 2>/dev/null | sed 's/^[^:]*: *//' | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | awk '!s[$0]++' | head -n3 | tr '\n' ' ')"
  fi
  [ -z "$dns" ] && dns="$(awk '/^nameserver/ && $2 !~ /^127\./ {print $2}' /etc/resolv.conf 2>/dev/null | head -n3 | tr '\n' ' ')"
  echo "DNS|${dns% }"
}

if [ "${1:-}" = "--facts" ]; then facts_here; exit 0; fi
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then sed -n '2,22p' "$0"; exit 0; fi

FACTS_DIR=""
if [ "${1:-}" = "--facts-dir" ]; then FACTS_DIR="${2:-}"; [ -d "$FACTS_DIR" ] || { err "cartella non trovata: '$FACTS_DIR'"; exit 1; }; fi

[ "$(id -u)" = 0 ] || [ -n "$FACTS_DIR" ] || { err "esegui come root (sudo)"; exit 1; }
command -v python3 >/dev/null 2>&1 || { err "serve python3"; exit 1; }

# ----------------------------- calcoli di rete (python) ----------------------
py() { python3 -I -c "$@"; }
net_of()     { py 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$1"; }
ip_of()      { echo "${1%%/*}"; }
prefix_of()  { echo "${1##*/}"; }
first3()     { local a b c d; IFS=. read -r a b c d <<<"$1"; echo "$a.$b.$c"; }
same_net()   { py 'import ipaddress,sys; print(int(ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_interface(sys.argv[2]).network))' "$1" "$2"; }
valid_ip()   { py 'import ipaddress,sys
try: ipaddress.IPv4Address(sys.argv[1]); print(1)
except Exception: print(0)' "$1"; }

# ----------------------------- caricamento fatti -----------------------------
declare -A CIDR=() MTU=() VID=() PAR=() HOSTN=() DEFDEV=() DEFVIA=() DNSL=() VLANID=() VLANPAR=()
declare -A IFLIST=()      # nodo -> nomi delle interfacce con IP (separati da spazio)
declare -A VLLIST=()      # nodo -> nomi delle VLAN
parse_facts() {  # parse_facts NODO  (fatti su stdin)
  local node="$1" t a b c d e
  IFLIST[$node]=""; VLLIST[$node]=""
  while IFS='|' read -r t a b c d e; do
    case "$t" in
      HOST)     HOSTN[$node]="$a" ;;
      IFACE)    CIDR["$node:$a"]="$b"; MTU["$node:$a"]="$c"; VID["$node:$a"]="$d"; PAR["$node:$a"]="$e"; IFLIST[$node]+="$a " ;;
      VLAN)     VLANID["$node:$a"]="$b"; VLANPAR["$node:$a"]="$c"; VLLIST[$node]+="$a " ;;
      DEFROUTE) DEFDEV[$node]="$a"; DEFVIA[$node]="$b" ;;
      DNS)      DNSL[$node]="$a" ;;
    esac
  done
}
load_node() {  # load_node NODO IP  -> da file, ssh o locale
  local node="$1" ip="$2" txt
  if [ -n "$FACTS_DIR" ]; then
    [ -r "$FACTS_DIR/$node.facts" ] || { err "manca $FACTS_DIR/$node.facts"; return 1; }
    parse_facts "$node" < "$FACTS_DIR/$node.facts"
  elif [ -z "$ip" ]; then
    txt="$(facts_here)"; parse_facts "$node" <<<"$txt"
  else
    [ -r "$DEPLOY_KEY" ] || { err "chiave SSH di deploy assente: $DEPLOY_KEY (vedi la guida, passo chiavi SSH)"; return 1; }
    txt="$(ssh "${SSH_OPTS[@]}" -i "$DEPLOY_KEY" "root@${ip}" bash -s <<<"$(declare -f facts_here); facts_here" 2>/dev/null)" \
      || { err "$node: impossibile leggere via SSH su $ip. Controlla la chiave oppure usa --facts / --facts-dir."; return 1; }
    [ -n "$txt" ] || { err "$node: nessun dato da $ip"; return 1; }
    parse_facts "$node" <<<"$txt"
  fi
}

EOF_N=0
ask() {  # ask "domanda" "default"  -> risposta in $REPLY_V
  local q="$1" def="${2:-}" r
  if [ -n "$def" ]; then printf '%s [%s]: ' "$q" "$def"; else printf '%s: ' "$q"; fi
  IFS= read -r r || { EOF_N=$((EOF_N+1)); [ "$EOF_N" -gt 3 ] && { err "input terminato prima della fine delle domande"; exit 1; }; r=""; }
  REPLY_V="${r:-$def}"
}

# ----------------------------- 1. nodo di riferimento ------------------------
say ""
say "${B}=== Configurazione della topologia dai nodi ===${N}"
say "Sola lettura sui server. Scrive solo topology.conf e ifaces.conf in: $OUT_DIR"
say ""

REF=""
if [ -n "$FACTS_DIR" ]; then
  REF="${NODE_NAMES[0]}"; load_node "$REF" "" || exit 1
else
  me="$(hostname -s 2>/dev/null)"
  for n in "${NODE_NAMES[@]}"; do [ "$me" = "$n" ] && REF="$n"; done
  if [ -z "$REF" ]; then
    warn "questo host si chiama '$me', non node01/node02/node03."
    ask "Quale nodo e' questo?" "${NODE_NAMES[0]}"; REF="$REPLY_V"
  fi
  load_node "$REF" "" || exit 1
fi
say "Nodo di riferimento: ${REF}"

# elenco interfacce con IP, ordinate per VLAN ID (le senza VLAN in fondo)
mapfile -t CAND < <(for i in ${IFLIST[$REF]}; do printf '%s\t%s\n' "${VID[$REF:$i]:-99999}" "$i"; done | sort -n | cut -f2)
[ "${#CAND[@]}" -ge 4 ] || { err "servono almeno 4 interfacce con IP (management, overlay, Ceph public, Ceph cluster): ne ho trovate ${#CAND[@]}."; for i in "${CAND[@]}"; do echo "   $i ${CIDR[$REF:$i]}"; done; exit 1; }

say ""
printf '  %-3s %-16s %-20s %-6s %-6s %s\n' N NOME IP/PREFISSO MTU VLAN PADRE
for k in "${!CAND[@]}"; do i="${CAND[$k]}"
  printf '  %-3s %-16s %-20s %-6s %-6s %s\n' "$((k+1))" "$i" "${CIDR[$REF:$i]}" "${MTU[$REF:$i]}" "${VID[$REF:$i]:--}" "${PAR[$REF:$i]:--}"
done
say ""

idx_of() { local k; for k in "${!CAND[@]}"; do [ "${CAND[$k]}" = "$1" ] && { echo "$((k+1))"; return; }; done; }
pick() {  # pick "etichetta" default_index -> nome interfaccia in $PICKED
  local q="$1" def="$2" v
  while true; do
    ask "$q (numero)" "$def"; v="$REPLY_V"
    if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le "${#CAND[@]}" ]; then PICKED="${CAND[$((v-1))]}"; return; fi
    echo "  numero non valido"
  done
}

# management: l'interfaccia della rotta di default
mdef=""; [ -n "${DEFDEV[$REF]:-}" ] && mdef="$(idx_of "${DEFDEV[$REF]}")"
[ -n "$mdef" ] || mdef=1
pick "Quale e' la rete di MANAGEMENT (quella con la rotta di default)" "$mdef"; IF_MGMT="$PICKED"
used=" $IF_MGMT "
nextdef() { local k; for k in "${!CAND[@]}"; do case "$used" in *" ${CAND[$k]} "*) ;; *) echo "$((k+1))"; return ;; esac; done; }
pick "Quale e' la rete OVERLAY (tenant, tunnel)" "$(nextdef)";             IF_OVERLAY="$PICKED"; used+="$IF_OVERLAY "
pick "Quale e' la rete CEPH PUBLIC (client -> Ceph)" "$(nextdef)";         IF_CEPHPUB="$PICKED"; used+="$IF_CEPHPUB "
pick "Quale e' la rete CEPH CLUSTER (replica tra OSD)" "$(nextdef)";       IF_CEPHCLU="$PICKED"; used+="$IF_CEPHCLU "
for a in IF_OVERLAY IF_CEPHPUB IF_CEPHCLU; do
  [ "${!a}" != "$IF_MGMT" ] || { err "$a coincide con la management"; exit 1; }
done
[ "$IF_OVERLAY" != "$IF_CEPHPUB" ] && [ "$IF_OVERLAY" != "$IF_CEPHCLU" ] && [ "$IF_CEPHPUB" != "$IF_CEPHCLU" ] || { err "due reti diverse hanno la stessa interfaccia"; exit 1; }

# external: VLAN senza IP
EXTC=(); for v in ${VLLIST[$REF]}; do case "$used" in *" $v "*) continue ;; esac; [ -z "${CIDR[$REF:$v]:-}" ] && EXTC+=("$v"); done
IF_EXT=""; VLAN_EXT=""
if [ "${#EXTC[@]}" -gt 0 ]; then
  say ""; say "VLAN senza indirizzo IP (candidate per la rete EXTERNAL/provider, che non ha IP sul nodo):"
  for k in "${!EXTC[@]}"; do printf '  %-3s %-16s VLAN %s\n' "$((k+1))" "${EXTC[$k]}" "${VLANID[$REF:${EXTC[$k]}]:-?}"; done
  while true; do
    ask "Quale e' la rete EXTERNAL (numero, 0 = nessuna / la indico a mano)" "1"; v="$REPLY_V"
    if [ "$v" = 0 ]; then break; fi
    if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le "${#EXTC[@]}" ]; then IF_EXT="${EXTC[$((v-1))]}"; VLAN_EXT="${VLANID[$REF:$IF_EXT]}"; break; fi
    echo "  numero non valido"
  done
fi
if [ -z "$IF_EXT" ]; then
  warn "nessuna VLAN external individuata sul nodo."
  ask "ID VLAN della rete external (numero)" ""; VLAN_EXT="$REPLY_V"
  [[ "$VLAN_EXT" =~ ^[0-9]+$ ]] || { err "ID VLAN non valido"; exit 1; }
  ask "Nome dell'interfaccia external sui nodi" "vlan${VLAN_EXT}"; IF_EXT="$REPLY_V"
fi

# bond: il padre di management e di ceph public (se la rete e' senza VLAN, il bond e' l'interfaccia stessa)
IF_BOND0="${PAR[$REF:$IF_MGMT]:-$IF_MGMT}"
IF_BOND1="${PAR[$REF:$IF_CEPHPUB]:-$IF_CEPHPUB}"

# ----------------------------- 2. altri nodi ---------------------------------
declare -A MG=() OV=() CP=() CC=()
c_ref_m="${CIDR[$REF:$IF_MGMT]}"; c_ref_o="${CIDR[$REF:$IF_OVERLAY]}"; c_ref_p="${CIDR[$REF:$IF_CEPHPUB]}"; c_ref_c="${CIDR[$REF:$IF_CEPHCLU]}"
MG[$REF]="$(ip_of "$c_ref_m")"; OV[$REF]="$(ip_of "$c_ref_o")"; CP[$REF]="$(ip_of "$c_ref_p")"; CC[$REF]="$(ip_of "$c_ref_c")"

say ""
bad=0
for n in "${NODE_NAMES[@]}"; do
  [ "$n" = "$REF" ] && continue
  if [ -n "$FACTS_DIR" ]; then
    load_node "$n" "" || exit 1
  else
    ask "IP di management di $n" ""; ip="$REPLY_V"
    [ "$(valid_ip "$ip")" = 1 ] || { err "'$ip' non e' un indirizzo IPv4"; exit 1; }
    load_node "$n" "$ip" || exit 1
  fi
  for pair in "IF_MGMT:MG" "IF_OVERLAY:OV" "IF_CEPHPUB:CP" "IF_CEPHCLU:CC"; do
    vn="${pair%%:*}"; arr="${pair##*:}"; ifn="${!vn}"
    c="${CIDR[$n:$ifn]:-}"
    if [ -z "$c" ]; then err "$n: l'interfaccia '$ifn' non ha un IP (stesso nome richiesto su tutti i nodi)"; bad=1; continue; fi
    refc="${CIDR[$REF:$ifn]}"
    [ "$(prefix_of "$c")" = "$(prefix_of "$refc")" ] || { err "$n: $ifn ha prefisso /$(prefix_of "$c"), il riferimento /$(prefix_of "$refc")"; bad=1; }
    [ "${VID[$n:$ifn]:-}" = "${VID[$REF:$ifn]:-}" ] || { err "$n: $ifn ha VLAN ID '${VID[$n:$ifn]:-nessuno}', il riferimento '${VID[$REF:$ifn]:-nessuno}'"; bad=1; }
    [ "$(same_net "$(ip_of "$c")" "$refc")" = 1 ] || { err "$n: $ifn ($c) non e' nella stessa subnet del riferimento ($refc)"; bad=1; }
    case "$arr" in MG) MG[$n]="$(ip_of "$c")" ;; OV) OV[$n]="$(ip_of "$c")" ;; CP) CP[$n]="$(ip_of "$c")" ;; CC) CC[$n]="$(ip_of "$c")" ;; esac
  done
  if [ -n "$IF_EXT" ] && [ -z "${VLANID[$n:$IF_EXT]:-}" ]; then warn "$n: nessuna VLAN '$IF_EXT' trovata (external)"; fi
  [ "$bad" = 0 ] && ok "$n: ${MG[$n]} / ${OV[$n]} / ${CP[$n]} / ${CC[$n]}"
done
[ "$bad" = 0 ] || { err "Le interfacce non sono coerenti tra i nodi: va corretto lato nodi (stessi nomi, stessi VLAN ID, stesse subnet)."; exit 1; }

# ----------------------------- 3. gateway, DNS, VIP --------------------------
GW="${DEFVIA[$REF]:-}"
ask "Gateway della rete di management" "$GW"; GW="$REPLY_V"
[ "$(valid_ip "$GW")" = 1 ] || { err "gateway non valido"; exit 1; }
DNS="${DNSL[$REF]:-8.8.8.8 1.1.1.1}"
ask "Server DNS (separati da spazio)" "$DNS"; DNS="$REPLY_V"
DNS_CSV="$(echo "$DNS" | tr -s ' ' | sed 's/ /, /g')"

say ""
say "Il VIP e' un indirizzo LIBERO della rete di management ($c_ref_m), riservato alle API di OpenStack."
say "Va chiesto al referente di rete: non deve essere usato da nessun altro."
while true; do
  ask "VIP" ""; VIP="$REPLY_V"
  [ "$(valid_ip "$VIP")" = 1 ] || { echo "  non e' un IPv4"; continue; }
  [ "$(same_net "$VIP" "$c_ref_m")" = 1 ] || { echo "  il VIP deve stare nella subnet di management ($(net_of "$c_ref_m"))"; continue; }
  dup=0; for n in "${NODE_NAMES[@]}"; do [ "${MG[$n]}" = "$VIP" ] && dup=1; done
  [ "$dup" = 0 ] || { echo "  coincide con l'IP di un nodo"; continue; }
  if ping -c1 -W1 "$VIP" >/dev/null 2>&1; then
    warn "$VIP RISPONDE al ping: potrebbe essere gia' in uso."
    ask "Lo uso lo stesso? (s/N)" "N"; [[ "$REPLY_V" =~ ^[sSyY]$ ]] || continue
  fi
  break
done

# ----------------------------- 3b. rete External pubblica (facoltativa) -----
EXT_C=""; EXT_G=""; EXT_S=""; EXT_E=""
ext_check() {  # ext_check CIDR GW START END -> "OK" oppure il motivo
  py 'import ipaddress as i,sys
try:
    n=i.ip_network(sys.argv[1],strict=True); g=i.ip_address(sys.argv[2]); a=i.ip_address(sys.argv[3]); b=i.ip_address(sys.argv[4])
except Exception as e:
    print("valore non valido: %s" % e); sys.exit(0)
if n.version!=4: print("serve una subnet IPv4")
elif g not in n or a not in n or b not in n: print("gateway e pool devono stare dentro %s" % n)
elif a>b: print("l inizio del pool e maggiore della fine")
elif a<=g<=b: print("il gateway cade dentro il pool")
else: print("OK")' "$1" "$2" "$3" "$4"
}
say ""
say "${B}Rete EXTERNAL (indirizzi pubblici per i floating IP delle VM)${N}"
say "Non si ricava dai nodi: va chiesta al referente di rete. Se non la si ha ancora, premere Invio:"
say "la rete external NON verra' creata (si potra' definire dopo, rilanciando questo script)."
while true; do
  ask "Subnet External (es. 203.0.113.0/27, Invio = non definita)" ""; EXT_C="$REPLY_V"
  [ -z "$EXT_C" ] && break
  ask "  Gateway della subnet External" ""; EXT_G="$REPLY_V"
  ask "  Primo IP del pool floating IP" ""; EXT_S="$REPLY_V"
  ask "  Ultimo IP del pool floating IP" ""; EXT_E="$REPLY_V"
  r="$(ext_check "$EXT_C" "$EXT_G" "$EXT_S" "$EXT_E")"
  [ "$r" = OK ] && break
  echo "  $r"; EXT_C=""; EXT_G=""; EXT_S=""; EXT_E=""
done
[ -z "$EXT_C" ] && warn "rete External non definita: il 03 non la creera' e lo segnalera'."

# ----------------------------- 4. riepilogo e scrittura ----------------------
vm="${VID[$REF:$IF_MGMT]:-0}"; vo="${VID[$REF:$IF_OVERLAY]:-0}"; vp="${VID[$REF:$IF_CEPHPUB]:-0}"; vc="${VID[$REF:$IF_CEPHCLU]:-0}"
[ "$vm" = 0 ] && warn "la management non e' una VLAN (nessun tag): alcune verifiche sui tag VLAN non si applicano."
say ""
say "${B}=== Riepilogo ===${N}"
printf '  %-12s %-14s %-6s %-20s' RETE INTERFACCIA VLAN SUBNET; for n in "${NODE_NAMES[@]}"; do printf ' %-15s' "$n"; done; echo
row() { local label="$1" ifn="$2" vid="$3" cidr="$4" arr="$5" n; printf '  %-12s %-14s %-6s %-20s' "$label" "$ifn" "$vid" "$(net_of "$cidr")"
        for n in "${NODE_NAMES[@]}"; do eval "printf ' %-15s' \"\${${arr}[$n]}\""; done; echo; }
row management "$IF_MGMT" "$vm" "$c_ref_m" MG
row overlay "$IF_OVERLAY" "$vo" "$c_ref_o" OV
row ceph-public "$IF_CEPHPUB" "$vp" "$c_ref_p" CP
row ceph-cluster "$IF_CEPHCLU" "$vc" "$c_ref_c" CC
printf '  %-12s %-14s %-6s\n' external "$IF_EXT" "$VLAN_EXT"
say "  bond        : $IF_BOND0 (management/overlay/external)  |  $IF_BOND1 (Ceph)"
say "  gateway     : $GW   DNS: $DNS_CSV   VIP: $VIP"
if [ -n "$EXT_C" ]; then say "  external    : subnet $EXT_C  gateway $EXT_G  pool floating IP $EXT_S - $EXT_E"
else say "  external    : ${Y}NON DEFINITA${N} (la rete external non verra' creata dal 03)"; fi
say ""
ask "Scrivo topology.conf e ifaces.conf? (s/N)" "N"
[[ "$REPLY_V" =~ ^[sSyY]$ ]] || { say "Annullato: nessun file scritto."; exit 0; }

ts="$(date +%Y%m%d-%H%M%S)"
for f in topology.conf ifaces.conf; do [ -f "$OUT_DIR/$f" ] && cp -a "$OUT_DIR/$f" "$OUT_DIR/$f.bak-$ts"; done

map_line() {  # map_line NOME_ARRAY_BASH_SORGENTE
  local arr="$1" n out=""
  for n in "${NODE_NAMES[@]}"; do eval "out+=\"[$n]=\\\"\${${arr}[$n]}\\\" \""; done
  echo "(${out% })"
}
{
  echo "# Piano IP rilevato dai nodi il $(date '+%Y-%m-%d %H:%M') da configura_topologia.sh."
  echo "# File generato: non modificare a mano (si rigenera lanciando di nuovo lo script)."
  echo "declare -gA NODE_MGMT_IP=$(map_line MG)"
  echo "declare -gA NODE_OVERLAY_IP=$(map_line OV)"
  echo "declare -gA NODE_CEPHPUB_IP=$(map_line CP)"
  echo "declare -gA NODE_CEPHCLU_IP=$(map_line CC)"
  echo "MGMT_NET=\"$(first3 "${MG[$REF]}")\"; OVERLAY_NET=\"$(first3 "${OV[$REF]}")\""
  echo "CEPHPUB_NET=\"$(first3 "${CP[$REF]}")\"; CEPHCLU_NET=\"$(first3 "${CC[$REF]}")\""
  echo "MGMT_PREFIX=$(prefix_of "$c_ref_m"); OVERLAY_PREFIX=$(prefix_of "$c_ref_o")"
  echo "CEPHPUB_PREFIX=$(prefix_of "$c_ref_p"); CEPHCLU_PREFIX=$(prefix_of "$c_ref_c")"
  echo "CEPH_PUBLIC_CIDR=\"$(net_of "$c_ref_p")\"; CEPH_CLUSTER_CIDR=\"$(net_of "$c_ref_c")\""
  echo "VLAN_MGMT=$vm; VLAN_OVERLAY=$vo; VLAN_EXT=$VLAN_EXT; VLAN_CEPHPUB=$vp; VLAN_CEPHCLU=$vc"
  echo "MGMT_GW=\"$GW\"; VIP=\"$VIP\"; DNS_SERVERS=\"$DNS_CSV\""
  if [ -n "$EXT_C" ]; then
    echo "EXT_SUBNET_CIDR=\"\${EXT_SUBNET_CIDR:-$EXT_C}\"; EXT_GATEWAY=\"\${EXT_GATEWAY:-$EXT_G}\""
    echo "EXT_FIP_START=\"\${EXT_FIP_START:-$EXT_S}\"; EXT_FIP_END=\"\${EXT_FIP_END:-$EXT_E}\""
  else
    echo "# Rete External non definita: il 03 non la crea. Per definirla rilanciare configura_topologia.sh."
  fi
} > "$OUT_DIR/topology.conf"
{
  echo "# Nomi delle interfacce rilevati da configura_topologia.sh il $(date '+%Y-%m-%d %H:%M')."
  echo "# File generato: non modificare a mano."
  for k in IF_MGMT IF_OVERLAY IF_EXT IF_CEPHPUB IF_CEPHCLU IF_BOND0 IF_BOND1; do echo "${k}=\"\${${k}:-${!k}}\""; done
} > "$OUT_DIR/ifaces.conf"

ok "scritto $OUT_DIR/topology.conf"
ok "scritto $OUT_DIR/ifaces.conf"
say ""
say "Prossimi passi:"
say "  1. bash ../OPENSTACK_tests_*/test_render.sh </dev/null 2>/dev/null | tail -3    # deve dare FAIL=0"
say "  2. LAB_MODE=0 ./run_all.sh --from-node"
say ""
if [ -z "$EXT_C" ]; then
  say "${Y}Rete External non definita${N}: il 03 non creera' la rete provider e lo segnalera'."
  say "Quando il referente di rete fornisce subnet, gateway e pool, rilanciare questo script e poi il 03."
fi
## DAVE

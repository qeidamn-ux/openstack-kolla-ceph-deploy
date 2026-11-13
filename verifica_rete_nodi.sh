#!/usr/bin/env bash
## DAVE
# =============================================================================
# verifica_rete_nodi.sh — controllo di rete tra tutti i nodi (ping, MTU, porte TCP, stato fisico).
#   Si lancia da node01, come root, dopo configura_topologia.sh. Non modifica nulla.
#
#   Per OGNI nodo sorgente verso OGNI altro nodo e per OGNI rete (mgmt, overlay, ceph-public,
#   ceph-cluster) misura la perdita di pacchetti con:
#     - ping piccolo (100 byte)
#     - ping a pieno MTU 1500 (1472 byte, DF)         [tutte le reti]
#     - ping jumbo     (8972 byte, DF)                [reti overlay e ceph; JUMBO_NETS per cambiare]
#   poi controlla le porte TCP (default 22; --porte "22 9090") sull'IP di management e,
#   per ogni nodo, lo stato fisico dei bond: slave, Aggregator ID, errori CRC (prima/dopo il test:
#   se crescono durante la prova la porta e' difettosa) e potenza ottica Rx (se il modulo la espone).
#
#   USO
#     bash verifica_rete_nodi.sh [--count N] [--porte "22 9090"] [--solo-fisico] [--no-jumbo]
#   Esito: 0 = tutto OK; 1 = almeno una prova KO. Il riepilogo finale elenca solo i problemi.
#   Segnalati come KO anche: Rx ottico < -7 dBm (RX_MIN_DBM), bond con porte in aggregatori diversi (vPC).
#   Una perdita casuale (non legata alla dimensione) indica un problema di bond/cavo, non di MTU:
#   guardare le righe "FISICO" per vedere quale porta ha CRC o Rx basso.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export LAB_MODE="${LAB_MODE:-0}"
# shellcheck disable=SC1091
source "$HERE/lib_topology.sh" >/dev/null 2>&1 || { echo "[ERRORE] lib_topology.sh non leggibile"; exit 1; }

COUNT=10; PORTS="22"; ONLY_PHY=0; JUMBO=1
JUMBO_NETS="${JUMBO_NETS:-overlay cephpub cephclu}"
while [ $# -gt 0 ]; do
  case "$1" in
    --count)       COUNT="${2:-}"; shift 2;;
    --porte)       PORTS="${2:-}"; shift 2;;
    --solo-fisico) ONLY_PHY=1; shift;;
    --no-jumbo)    JUMBO=0; shift;;
    -h|--help)     sed -n '3,21p' "$0"; exit 0;;
    *) echo "[ERRORE] opzione sconosciuta: $1"; exit 1;;
  esac
done
[[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -ge 3 ] && [ "$COUNT" -le 200 ] || { echo "[ERRORE] --count deve essere un numero tra 3 e 200"; exit 1; }
[[ "$PORTS" =~ ^[0-9\ ]+$ ]] || { echo "[ERRORE] --porte: solo numeri separati da spazio"; exit 1; }
SSHO=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -i "$DEPLOY_KEY")

net_ip() {  # net_ip <rete> <nodo>
  case "$1" in
    mgmt) mgmt_ip "$2";; overlay) overlay_ip "$2";; cephpub) cephpub_ip "$2";; cephclu) cephclu_ip "$2";;
  esac
}
NETS="mgmt overlay cephpub cephclu"
BAD=0; PROBLEMI=()

# ---- script eseguito su ogni nodo sorgente (stesso testo per tutti) --------------------------------
remote_probe() {
  local mode="$1" count="$2" ports="$3"; shift 3
  ssh "${SSHO[@]}" "root@${SRC_IP}" env RX_MIN_DBM="${RX_MIN_DBM:--7}" bash -s -- "$mode" "$count" "$ports" "$@" <<'EOF'
mode="$1"; count="$2"; ports="$3"; shift 3
crc() { for i in $(awk '/Slave Interface/{print $3}' /proc/net/bonding/bond* 2>/dev/null); do
          printf '%s=%s ' "$i" "$(ethtool -S "$i" 2>/dev/null | awk '/rx_crc_errors/{s+=$2} END{print s+0}')"; done; }
if [ "$mode" = "phy-start" ]; then crc; exit 0; fi
if [ "$mode" = "phy-report" ]; then
  before="$1"; shift
  for b in /proc/net/bonding/bond*; do [ -r "$b" ] || continue
    echo "FISICO $(basename "$b"): $(awk '/Bonding Mode/{m=$0} END{sub(/^[^:]*: /,"",m); print m}' "$b") | partner $(awk '/Partner Mac/{print $NF; exit}' "$b")"
    ags=""
    for i in $(awk '/Slave Interface/{print $3}' "$b"); do
      st="$(awk -v i="$i" '$0 ~ "Slave Interface: "i{f=1;next} /Slave Interface/{f=0} f&&/MII Status/{print $3; exit}' "$b")"
      ag="$(awk -v i="$i" '$0 ~ "Slave Interface: "i{f=1;next} /Slave Interface/{f=0} f&&/Aggregator ID/{print $3; exit}' "$b")"
      c1="$(ethtool -S "$i" 2>/dev/null | awk '/rx_crc_errors/{s+=$2} END{print s+0}')"
      c0="$(printf '%s' "$before" | tr ' ' '\n' | awk -F= -v i="$i" '$1==i{print $2}')"; c0="${c0:-$c1}"
      rx="$(ethtool -m "$i" 2>/dev/null | awk -F': ' '/Receiver signal average/{print $2}' | sed 's/.*\/ //')"
      d=$((c1-c0)); flag=OK
      [ "$st" = up ] || flag="KO(link $st)"
      [ "$d" -gt 0 ] && flag="KO(CRC +$d durante il test)"
      [ "$flag" = OK ] && [ "$c1" -gt 0 ] && flag="OK(CRC storici: $c1)"
      ## segnale ricevuto troppo basso (default < -7 dBm; RX_MIN_DBM per cambiare): fibra/connettore/ottica
      rxn="$(printf '%s' "$rx" | awk '{print $1}')"
      if [ -n "$rxn" ] && awk -v v="$rxn" -v m="${RX_MIN_DBM:--7}" 'BEGIN{exit !(v+0 < m+0)}'; then flag="KO(Rx basso: $rx, soglia ${RX_MIN_DBM:--7} dBm)"; fi
      ags="$ags ${ag:-?}"
      echo "FISICO   $i: link=$st aggregatore=${ag:-?} crc=$c1 rx=${rx:--} -> $flag"
    done
    if [ "$(printf '%s\n' $ags | sort -u | wc -l)" -gt 1 ]; then
      echo "FISICO   $(basename "$b"): aggregatori diversi ($ags ) -> KO(vPC non coerente: una porta e' in un aggregato separato, senza ridondanza)"
    fi
  done
  exit 0
fi
# mode=probe: argomenti = rete:nome:ip:jumbo
for t in "$@"; do
  IFS=: read -r net name ip jumbo <<<"$t"
  out=""; r=0
  sizes="100 1472"; [ "$jumbo" = 1 ] && sizes="100 1472 8972"
  for s in $sizes; do
    l="$(ping -M do -s "$s" -c "$count" -i 0.2 -W 2 "$ip" 2>/dev/null | awk -F'[ ,%]+' '/packet loss/{for(i=1;i<=NF;i++) if($i=="received") print $(i-1)}')"
    l="${l:-0}"; lost=$((count-l)); out="$out ${s}B:${lost}/${count}"
    [ "$lost" -gt 0 ] && r=1
  done
  [ "$r" = 0 ] && echo "PING ok  $net -> $name ($ip) perse:$out" || echo "PING KO  $net -> $name ($ip) perse:$out"
done
for t in "$@"; do
  IFS=: read -r net name ip jumbo <<<"$t"
  [ "$net" = mgmt ] || continue
  for p in $ports; do
    if timeout 4 bash -c ">/dev/tcp/$ip/$p" 2>/dev/null; then echo "PORTA ok $name:$p"; else echo "PORTA KO $name:$p"; fi
  done
done
exit 0
EOF
}

consume() {  # legge le righe dal nodo remoto, le stampa e conta i KO
  local from="$1" line
  while IFS= read -r line; do
    echo "  $line"
    case "$line" in
      PING\ KO*|PORTA\ KO*|*"-> KO"*) BAD=1; PROBLEMI+=("$from: $line");;
    esac
  done
}

echo "Verifica rete nodi — $(date '+%F %T') — ${#ALL_NODES[@]} nodi, $COUNT ping per prova, porte TCP: $PORTS"
declare -A CRC0
for src in "${ALL_NODES[@]}"; do
  SRC_IP="$(mgmt_ip "$src")"
  CRC0[$src]="$(remote_probe phy-start 0 "" 2>/dev/null)" || { echo "== $src: SSH non raggiungibile"; BAD=1; PROBLEMI+=("$src: ssh non raggiungibile"); }
done

if [ "$ONLY_PHY" = 0 ]; then
  for src in "${ALL_NODES[@]}"; do
    SRC_IP="$(mgmt_ip "$src")"
    targets=()
    for dst in "${ALL_NODES[@]}"; do
      [ "$dst" = "$src" ] && continue
      for net in $NETS; do
        j=0; [ "$JUMBO" = 1 ] && case " $JUMBO_NETS " in *" $net "*) j=1;; esac
        targets+=("$net:$dst:$(net_ip "$net" "$dst"):$j")
      done
    done
    echo "== da $src ($SRC_IP)"
    consume "$src" < <(remote_probe probe "$COUNT" "$PORTS" "${targets[@]}" 2>&1)
  done
else
  sleep 15
fi

echo
echo "== stato fisico dei bond"
for src in "${ALL_NODES[@]}"; do
  SRC_IP="$(mgmt_ip "$src")"
  echo " $src"
  consume "$src" < <(remote_probe phy-report 0 "" "${CRC0[$src]:-}" 2>&1)
done

echo
if [ "$BAD" = 0 ]; then echo "ESITO: OK — nessuna perdita, porte raggiungibili, nessun errore fisico nuovo."; exit 0; fi
echo "ESITO: PROBLEMI RILEVATI (${#PROBLEMI[@]}):"
printf '  - %s\n' "${PROBLEMI[@]}"
echo
echo "Come leggerli: perdita che dipende dalla dimensione (OK a 100B, KO a 1472B/8972B) = MTU lungo il percorso;"
echo "perdita casuale su tutte le dimensioni = bond/cavo (guarda le righe FISICO: CRC in crescita o Rx basso)."
exit 1
## DAVE

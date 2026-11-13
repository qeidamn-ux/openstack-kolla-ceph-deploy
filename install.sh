#!/usr/bin/env bash
# =============================================================================
# install.sh — Front-end TUI per il deploy.
#   Mostra un BANNER elegante con l'avanzamento per fasi (spinner + tempi).
#   ↑ = mostra la CONSOLE (output live)   ↓ = torna al BANNER   q = esci
#
#   Sotto lancia run_all.sh (stessa catena). Auto-eleva a root (una sola
#   richiesta sudo), cosi' i sotto-comandi non chiedono password durante il run.
#
#   USO:  ./install.sh            (equivale a ./run_all.sh, ma con il banner)
#         ./install.sh --no-vms
## DAVE
#         ./install.sh --from-node   # lanciato DA UN NODO (es. console web di node01): vedi run_all.sh
## DAVE
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")" || exit 1

# LAB_MODE deve essere ESPLICITO: nessun default silenzioso. Un fallback a "1"
# applicherebbe impostazioni da laboratorio (bond active-backup, reservation
# ridotta) anche su un lancio accidentale sul ferro reale.
if [ -z "${LAB_MODE+x}" ] || { [ "$LAB_MODE" != 0 ] && [ "$LAB_MODE" != 1 ]; }; then
  echo "ERRORE: esporta LAB_MODE esplicitamente prima di lanciare questo script." >&2
  echo "  export LAB_MODE=1   # laboratorio (VM annidate)" >&2
  echo "  export LAB_MODE=0   # hardware reale (baremetal)" >&2
  exit 1
fi

# auto-elevazione: tutta la catena gira da root (nessun prompt sudo a meta' run)
# NB: niente '-E' (alcune sudoers lo vietano). LAB_MODE lo ripristina l'export sotto.
if [ "$(id -u)" != 0 ]; then exec sudo LAB_MODE="${LAB_MODE}" LAB_KVM="${LAB_KVM:-$LAB_MODE}" RUN_FUNCTIONAL="${RUN_FUNCTIONAL:-1}" TESTS_DIR="${TESTS_DIR:-}" bash "$0" "$@"; fi
export LAB_MODE
export LAB_KVM="${LAB_KVM:-$LAB_MODE}"

# se non c'e' un terminale (output rediretto), niente TUI: esegui e basta
if [ ! -t 1 ]; then exec bash run_all.sh "$@"; fi

LOG="./install-$(date +%Y%m%d-%H%M%S).log"

# ---- fasi: chiave-nel-log | etichetta ---------------------------------------
PHASES=(
  "test_render|Sanity check offline"
  "lab_create_vms|Creazione VM (lab)"
  "attendo SSH|Attesa boot nodi"
  "00_bootstrap|Bootstrap rete · bond/VLAN"
  "01_prepare|Preparazione nodi"
  "01b_ceph|Ceph · storage distribuito"
  "02_deploy|Deploy OpenStack · OVN"
  "03_configure|Configurazione cloud"
  "03b_functional|Test funzionali"
)
## DAVE
# Masakari e' opzionale: compare nel banner solo se richiesto (export ENABLE_MASAKARI=1)
[ "${ENABLE_MASAKARI:-0}" = 1 ] && PHASES+=("04_masakari|Masakari · HA istanze")
## DAVE
NP=${#PHASES[@]}
# Pacchetto TEST FUNZIONALI (opzionale): cerco, nell'ordine, $TESTS_DIR, questa cartella,
# una cartella sorella OPENSTACK_tests_*. Se manca, le sue fasi non compaiono nel banner.
if [ -z "${TESTS_DIR:-}" ]; then
  if [ -f ./test_render.sh ]; then TESTS_DIR="$PWD"
  else TESTS_DIR="$(ls -d ../OPENSTACK_tests_*/ 2>/dev/null | sort | tail -1)"; fi
fi
[ -n "${TESTS_DIR:-}" ] && [ -d "$TESTS_DIR" ] && TESTS_DIR="$(cd "$TESTS_DIR" && pwd)"
HAVE_TESTS=0; [ -n "${TESTS_DIR:-}" ] && [ -f "$TESTS_DIR/test_render.sh" ] && HAVE_TESTS=1
[ -n "${TESTS_DIR:-}" ] && export TESTS_DIR
_p=()
for _x in "${PHASES[@]}"; do
  case "${_x%%|*}" in
    test_render)    [ "$HAVE_TESTS" = 1 ] && _p+=("$_x") ;;
    03b_functional) { [ "$HAVE_TESTS" = 1 ] && [ "${RUN_FUNCTIONAL:-1}" = 1 ]; } && _p+=("$_x") ;;
    *) _p+=("$_x") ;;
  esac
done
PHASES=("${_p[@]}"); NP=${#PHASES[@]}; unset _p _x
# Sul ferro, o in un lab con VM gia esistenti (LAB_KVM=0), le VM non si creano: tolgo
# queste due fasi dal banner, altrimenti comparirebbero come completate
# (spunta verde) pur non essendo mai state eseguite.
if [ "$LAB_KVM" = 0 ]; then
  _p=()
  for _x in "${PHASES[@]}"; do
    case "${_x%%|*}" in lab_create_vms|"attendo SSH") ;; *) _p+=("$_x") ;; esac
  done
  PHASES=("${_p[@]}"); NP=${#PHASES[@]}; unset _p _x
fi
declare -A PSTART PEND     # epoch prima-vista / fine per indice

SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'; SPN=${#SPIN}
E=$'\033'   # ESC

# ---- stato di una fase leggendo il LOG --------------------------------------
seen()  { grep -qF "######## " "$LOG" 2>/dev/null && grep -q "########.*$1" "$LOG" 2>/dev/null; }
okd()   { grep -qE "\[OK\].*$1" "$LOG" 2>/dev/null; }
faild() { grep -qE "(FALLITO|FAILED).*$1" "$LOG" 2>/dev/null; }

# stato fase i: done|run|fail|wait  (usa anche "una fase dopo e' iniziata" = done)
phase_state() {
  local i="$1"; local key="${PHASES[$i]%%|*}"; local j later=0
  for ((j=i+1;j<NP;j++)); do seen "${PHASES[$j]%%|*}" && { later=1; break; }; done
  if faild "$key"; then echo "fail"
  elif okd "$key" || [ "$later" = 1 ]; then echo "done"
  elif seen "$key"; then echo "run"
  else echo "wait"; fi
}

fmt() { printf '%02d:%02d' $(( $1/60 )) $(( $1%60 )); }

# ---- disegno ----------------------------------------------------------------
TW=62                         # larghezza box (ricalcolata a runtime sui cols)
frame=0

draw_banner() {
  local cols; cols=$(tput cols 2>/dev/null || echo 80)
  TW=$(( cols<64 ? (cols<44?44:cols) : 64 )); local CW=$(( TW-4 ))
  local now; now=$(date +%s)
  local g="${E}[32m" w="${E}[97m" r="${E}[31m" c="${E}[36m" d="${E}[2m" b="${E}[1m" x="${E}[0m"
  local dsh; dsh=$(printf '─%.0s' $(seq 1 $((TW-2)) ))

  local out=""
  # _row: calcola il riempimento sulla LARGHEZZA VISIBILE (senza codici ANSI),
  # non sulla lunghezza grezza della stringa — altrimenti righe con colori
  # embedded (titolo, footer) risultano "piu' lunghe" del reale e il bordo
  # destro del box si disallinea.
  _row(){
    local content="$2" plain pad sp
    plain="$(printf '%s' "$content" | sed 's/\x1b\[[0-9;]*m//g')"
    pad=$(( CW - ${#plain} )); (( pad < 0 )) && pad=0
    sp="$(printf '%*s' "$pad" '')"
    out+="│ ${1}${content}${sp}${x} │"$'\n'
  }
  out+="╭${dsh}╮"$'\n'
  _row "" "$(printf '%sO P E N S T A C K%s' "$b" "$x")"
  _row "$d" "provisioning automatizzato"
  out+="├${dsh}┤"$'\n'

  local i st key lbl icon col dur t0 t1
  for ((i=0;i<NP;i++)); do
    key="${PHASES[$i]%%|*}"; lbl="${PHASES[$i]#*|}"; st=$(phase_state "$i")
    # timing
    [ -z "${PSTART[$i]:-}" ] && { [ "$st" != wait ] && PSTART[$i]=$now; }
    { [ "$st" = "done" ] || [ "$st" = "fail" ]; } && [ -z "${PEND[$i]:-}" ] && [ -n "${PSTART[$i]:-}" ] && PEND[$i]=$now
    t0="${PSTART[$i]:-}"; t1="${PEND[$i]:-$now}"; dur=""
    [ -n "$t0" ] && dur=$(fmt $(( t1-t0 )))
    case "$st" in
      done) icon="✓"; col="$g" ;;
      fail) icon="✗"; col="$r" ;;
      run)  icon="${SPIN:$(( frame%SPN )):1}"; col="$c" ;;
      *)    icon="○"; col="$d" ;;
    esac
    printf -v line "%s  %-30s %5s" "$icon" "$lbl" "$dur"
    _row "$col" "$line"
  done

  out+="├${dsh}┤"$'\n'
  local tot; tot=$(fmt $(( now - START_EPOCH )))
  _row "$d" "$(printf 'totale %s        %s↑%s console  %s↓%s banner  %sq%s esci' "$tot" "$w" "$d" "$w" "$d" "$w" "$d")"
  out+="╰${dsh}╯"

  printf '%s%s%s' "${E}[H" "$out" "${E}[J"
}

draw_console() {
  local cols lines; cols=$(tput cols 2>/dev/null||echo 80); lines=$(tput lines 2>/dev/null||echo 24)
  local d="${E}[2m" x="${E}[0m" w="${E}[97m"
  printf '%s' "${E}[H"
  printf '%s── Console · output live %s%s\n' "$w" "$(printf '─%.0s' $(seq 1 $((cols-25)) ))" "$x"
  # ultime righe del log, senza codici colore, tagliate alla larghezza
  tail -n $(( lines-3 )) "$LOG" 2>/dev/null | sed -u 's/\x1b\[[0-9;]*m//g' | cut -c1-"$cols" | \
    while IFS= read -r l; do printf '%s%s\n' "$l" "${E}[K"; done
  printf '%s' "${E}[J"
  printf '\n%s%s↑%s/%s↓%s cambia vista · %sq%s esci   (log: %s)%s' "$d" "$w" "$d" "$w" "$d" "$w" "$d" "$LOG" "$x"
}

# ---- terminale ---------------------------------------------------------------
cleanup() { tput rmcup 2>/dev/null; tput cnorm 2>/dev/null; stty echo 2>/dev/null; }
trap cleanup EXIT INT TERM
tput smcup 2>/dev/null; tput civis 2>/dev/null; stty -echo 2>/dev/null; printf '%s' "${E}[2J"

START_EPOCH=$(date +%s)
# lancia la catena; nohup+redirect: sopravvive e non intercetta i tasti
nohup bash run_all.sh "$@" >"$LOG" 2>&1 &
INSTALL_PID=$!

VIEW=banner; RC=""; done_shown=0
while :; do
  frame=$((frame+1))
  if [ "$VIEW" = banner ]; then draw_banner; else draw_console; fi

  # catena finita?
  if [ -z "$RC" ] && ! kill -0 "$INSTALL_PID" 2>/dev/null; then
    wait "$INSTALL_PID" 2>/dev/null; RC=$?
  fi
  if [ -n "$RC" ] && [ "$done_shown" = 0 ] && [ "$VIEW" = banner ]; then
    done_shown=1
## DAVE
    _vip="$( ( source ./lib_topology.sh >/dev/null 2>&1; echo "${VIP:-}" ) 2>/dev/null )"
    if [ "$RC" = 0 ]; then printf '\n  %s✓ Deploy completato%s — Horizon http://%s\n' "${E}[32m" "${E}[0m" "${_vip:-<VIP>}"
    else printf '\n  %s✗ Deploy interrotto%s (codice %s) — vedi il log\n' "${E}[31m" "${E}[0m" "$RC"; fi
## DAVE
    printf '  premi %sq%s per uscire\n' "${E}[97m" "${E}[0m"
  fi

  IFS= read -rsn1 -t 0.4 k || true
  if [ "$k" = "$E" ]; then IFS= read -rsn2 -t 0.005 k2 || true; k+=$k2; fi
  case "$k" in
    "${E}[A"|"$E"OA) VIEW=console ;;
    "${E}[B"|"$E"OB) VIEW=banner ;;
    q|Q)
      if [ -z "$RC" ] && kill -0 "$INSTALL_PID" 2>/dev/null; then
        cleanup
        echo "L'installazione CONTINUA in background (PID ${INSTALL_PID})."
        echo "  segui:  tail -f ${LOG}"
        exit 0
      fi
      exit "${RC:-0}" ;;
  esac
done

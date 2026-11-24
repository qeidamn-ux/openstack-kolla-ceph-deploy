#!/usr/bin/env bash
# =============================================================================
# run_all.sh — Lancia l'intera catena in un colpo solo (LAB_MODE).
## DAVE
#   Ordine: [test_render -> lab_create_vms] -> 00 -> 01 -> 01b -> 02 -> 03 [-> 03b] [-> 04 se ENABLE_MASAKARI=1]
#           [-> 06 se ENABLE_OCTAVIA=1]
## DAVE
#   Le fasi tra [ ] e 03b vengono dal pacchetto TEST FUNZIONALI (opzionale): se non c'e'
#   vengono saltate (le VM del lab, pero', senza quel pacchetto non si creano: usa --no-vms).
#   Il pacchetto test si cerca in $TESTS_DIR, in questa cartella, in ../OPENSTACK_tests_*.
#   RUN_FUNCTIONAL=0 salta i test funzionali (03b) anche se il pacchetto c'e'.
#   - sanity check OFFLINE prima di toccare l'host
#   - un log per fase in ./logs-<data>/
#   - STOP al primo errore (niente fase successiva se una fallisce)
#
#   USO (LAB_MODE ora OBBLIGATORIO, nessun default silenzioso):
#     export LAB_MODE=1 ; ./run_all.sh              # lab (VM annidate)
#     export LAB_MODE=1 ; ./run_all.sh --no-vms     # lab, NON ricrea le VM (gia' esistenti)
#     export LAB_MODE=0 ; ./run_all.sh --no-vms     # ferro (richiede BOND ifaces gia' compilate nel 00)
## DAVE
#     export LAB_MODE=0 ; ./run_all.sh --from-node  # lanciato DA UN NODO (es. node01, console web):
#         bond/VLAN gia' configurati -> il 00 salta il cutover (solo chiavi+NTP+verifiche),
#         niente creazione VM. Da un nodo SENZA --from-node la catena si rifiuta di partire.
#         Consigliato dentro tmux/screen (o via install.sh, che usa nohup).
## DAVE
#
#   NB: la catena e' lunga (~2-3 h per 02+03). Segui i log da un altro terminale.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")" || exit 1

# LAB_MODE deve essere ESPLICITO: nessun default silenzioso (vedi install.sh
# per la motivazione — evitare che un lancio sul ferro erediti impostazioni lab).
if [ -z "${LAB_MODE+x}" ] || { [ "$LAB_MODE" != 0 ] && [ "$LAB_MODE" != 1 ]; }; then
  echo "ERRORE: esporta LAB_MODE esplicitamente prima di lanciare questo script." >&2
  echo "  export LAB_MODE=1   # laboratorio (VM annidate)" >&2
  echo "  export LAB_MODE=0   # hardware reale (baremetal)" >&2
  exit 1
fi
LAB_KVM="${LAB_KVM:-$LAB_MODE}"   # 0 = lab su VM gia' esistenti (es. VMware)
DO_VMS=1; [ "${1:-}" = "--no-vms" ] && DO_VMS=0
## DAVE
FROM_NODE=0
for _a in "$@"; do [ "$_a" = "--from-node" ] && FROM_NODE=1; [ "$_a" = "--no-vms" ] && DO_VMS=0; done; unset _a
# SELF = nodo su cui gira questo script ("" = host esterno), dalla lib di topologia
# shellcheck disable=SC1091
source ./lib_topology.sh >/dev/null 2>&1
if [ -n "${SELF:-}" ] && [ "$FROM_NODE" != 1 ]; then
  echo "ERRORE: sto girando sul nodo ${SELF} del cluster." >&2
  echo "  La catena parte dal 00, che riconfigura la rete via SSH e farebbe cadere questa sessione." >&2
  echo "  Bond/VLAN gia' configurati:  ./run_all.sh --from-node   (00 senza cutover, niente VM)" >&2
  echo "  Rete da configurare:         lancia la catena da un host esterno ai nodi." >&2
  exit 1
fi
if [ "$FROM_NODE" = 1 ]; then
  if [ -z "${SELF:-}" ]; then
    echo "ERRORE: --from-node ha senso solo su un nodo del cluster (nessun IP di management locale corrisponde a ${ALL_NODES[*]})." >&2
    echo "  Se gli IP reali dei nodi sono diversi da quelli di lib_topology.sh, lancia prima:  sudo bash configura_topologia.sh" >&2
    exit 1
  fi
  DO_VMS=0
  topo_in_persistent_session || echo "ATTENZIONE: non risulti in tmux/screen/nohup: se la console web cade, la catena (2-3 h) si interrompe. Meglio ./install.sh (usa nohup) o tmux." >&2
fi
## DAVE
LOG_DIR="./logs-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$LOG_DIR"

# --- pacchetto TEST FUNZIONALI (opzionale) ------------------------------------
DEPLOY_DIR="$PWD"; export DEPLOY_DIR      # i test lo usano per trovare lib_topology.sh
if [ -z "${TESTS_DIR:-}" ]; then
  if [ -f ./test_render.sh ]; then TESTS_DIR="$PWD"
  else TESTS_DIR="$(ls -d ../OPENSTACK_tests_*/ 2>/dev/null | sort | tail -1)"; fi
fi
[ -n "${TESTS_DIR:-}" ] && [ -d "$TESTS_DIR" ] && TESTS_DIR="$(cd "$TESTS_DIR" && pwd)"
HAVE_TESTS=0; [ -n "${TESTS_DIR:-}" ] && [ -f "$TESTS_DIR/test_render.sh" ] && HAVE_TESTS=1

B='\033[0;34m'; G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; N='\033[0m'
phase() { echo -e "\n${B}######## $* ########${N}"; }

# esegue uno step come root passando LAB_MODE; logga e si ferma se fallisce
run_root() {
  local label="$1"; shift
  phase "$label"
  if sudo LAB_MODE="$LAB_MODE" LAB_KVM="$LAB_KVM" DEPLOY_DIR="$DEPLOY_DIR" bash "$@" 2>&1 | tee "${LOG_DIR}/${label}.log"; then
    echo -e "${G}[OK] ${label}${N}"
  else
    echo -e "${R}[FALLITO] ${label} — vedi ${LOG_DIR}/${label}.log${N}"; exit 1
  fi
}

# --- 0. sanity offline: se i generatori non rendono, inutile partire ---------
if [ "$HAVE_TESTS" = 1 ]; then
  phase "test_render (sanity offline)"
  if LAB_MODE="$LAB_MODE" DEPLOY_DIR="$DEPLOY_DIR" bash "$TESTS_DIR/test_render.sh" </dev/null > "${LOG_DIR}/test_render.log" 2>&1; then
    echo -e "${G}[OK] test_render${N}"
  else
## DAVE
    echo -e "${R}[FALLITO] test_render — controlli offline falliti: vedi ${LOG_DIR}/test_render.log (le righe [FAIL] dicono cosa)${N}"
## DAVE
    tail -5 "${LOG_DIR}/test_render.log"; exit 1
  fi
else
  echo -e "${Y}[SALTATO] test_render: pacchetto test funzionali non trovato${N}"
fi

# --- guardia BOND ifaces (solo ferro) -----------------------------------------
# Nel lab il 00 usa da solo i nomi fissi delle VM: il file NON viene mai
# modificato (prima veniva riscritto con sed, sporcando il repository).
if [ "$LAB_KVM" = 0 ] && [ "$FROM_NODE" != 1 ] && grep -q '^BOND0_IFACES="REPLACE_' 00_bootstrap_baremetal_v2.sh; then
  echo -e "${R}ERRORE: membri dei bond non compilati nel 00 (ancora REPLACE_*).${N}"
  echo    "  Sul ferro: 'sudo LAB_MODE=0 bash 00_bootstrap_baremetal_v2.sh --discover' e compila BOND0/1_IFACES."
  exit 1
fi

# --- 1. VM del lab (idempotente; salta le VM gia' esistenti) ------------------
if [ "$LAB_KVM" = 1 ] && [ "$DO_VMS" = 1 ]; then
  if [ "$HAVE_TESTS" != 1 ] || [ ! -f "$TESTS_DIR/lab_create_vms.sh" ]; then
    echo -e "${R}ERRORE: lab_create_vms.sh sta nel pacchetto TEST FUNZIONALI, non trovato.${N}"
    echo    "  Metti OPENSTACK_tests_* accanto a questa cartella, esporta TESTS_DIR, oppure usa --no-vms."
    exit 1
  fi
  run_root "lab_create_vms" "$TESTS_DIR/lab_create_vms.sh"
  # attendi il primo boot (cloud-init) sui 3 IP di management (VM gia' su bond+VLAN)
  phase "attendo SSH sui nodi (cloud-init)"
  for ip in 10.0.10.11 10.0.10.12 10.0.10.13; do
    printf "  %s " "$ip"
    for i in $(seq 1 60); do
      if timeout 3 bash -c "echo > /dev/tcp/${ip}/22" 2>/dev/null; then echo "OK"; break; fi
      printf "."; sleep 5
      [ "$i" = 60 ] && { echo -e "\n${R}  timeout: ${ip} non risponde su :22${N}"; exit 1; }
    done
  done
fi

# --- 2. catena di deploy -----------------------------------------------------
## DAVE
FN_ARGS=(); [ "$FROM_NODE" = 1 ] && FN_ARGS+=(--from-node)
run_root "00_bootstrap"  00_bootstrap_baremetal_v2.sh ${FN_ARGS[@]+"${FN_ARGS[@]}"}
## DAVE
run_root "01_prepare"    01_prepare_nodes_3NODE.sh
run_root "01b_ceph"      01b_setup_ceph_3NODE.sh
run_root "02_deploy"     02_deploy_openstack_3NODE.sh
run_root "03_configure"  03_configure_openstack_3NODE.sh

# --- 2b. test funzionali (pacchetto test, opzionale) --------------------------
# HA, servizi, Barbican, Skyline, smoke test East-West. Stanno PRIMA di Masakari:
# Masakari si abilita solo dopo che il cloud e' sano. RUN_FUNCTIONAL=0 per saltarli.
if [ "$HAVE_TESTS" = 1 ] && [ "${RUN_FUNCTIONAL:-1}" = 1 ] && [ -f "$TESTS_DIR/03b_functional_tests_3NODE.sh" ]; then
  run_root "03b_functional" "$TESTS_DIR/03b_functional_tests_3NODE.sh"
else
  echo -e "${Y}[SALTATO] test funzionali (pacchetto test assente o RUN_FUNCTIONAL=0)${N}"
fi

## DAVE
# --- 3. opzionale: Masakari (Instance HA, Fase A senza fencing) ---------------
# ENABLE_MASAKARI=1 per includerlo. Sul ferro serve anche MASAKARI_ACCEPT_NOFENCING=1
# (presa d'atto che la Fase A non protegge dallo split-brain). Il 02 NON riceve
# ENABLE_MASAKARI di proposito: Masakari si abilita solo dopo che il cloud e' sano.
if [ "${ENABLE_MASAKARI:-0}" = 1 ]; then
  MK_ARGS=()
  [ "$LAB_MODE" = 0 ] && [ "${MASAKARI_ACCEPT_NOFENCING:-0}" = 1 ] && MK_ARGS+=(--accept-no-fencing)
  run_root "04_masakari" 04_masakari.sh ${MK_ARGS[@]+"${MK_ARGS[@]}"}
fi
## DAVE

## DAVE
# --- 4. opzionale: Octavia (LBaaS, solo provider OVN) -------------------------
# ENABLE_OCTAVIA=1 per includerlo. Come Masakari, il 02 non lo riceve: Octavia si
# abilita solo a cloud sano (il 06 scrive globals + override e fa il deploy mirato).
if [ "${ENABLE_OCTAVIA:-0}" = 1 ]; then
  run_root "06_octavia" 06_octavia.sh
fi
## DAVE

echo -e "\n${G}============================================================${N}"
echo -e "${G}  Catena completata. Log in ${LOG_DIR}/${N}"
## DAVE
echo -e "${G}  Horizon: http://${VIP}   (admin in /root/admin-openrc-password.txt sul nodo)${N}"
## DAVE
echo -e "${G}============================================================${N}"

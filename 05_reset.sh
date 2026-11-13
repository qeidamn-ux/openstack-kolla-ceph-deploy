#!/usr/bin/env bash
# =============================================================================
# 05_reset.sh — RESET / preparazione al REDEPLOY (DISTRUTTIVO)
#   Gira DALLA MACCHINA DI DEPLOY (come gli altri script). Topologia da
#   lib_topology.sh. NON e' una fase della catena: si lancia solo quando si
#   vuole ripartire.
#
#   LIVELLI (--level e' OBBLIGATORIO: nessun default, si sceglie a mente fredda)
#     openstack  Distrugge OpenStack (kolla-ansible destroy: container + volumi
#                Docker, quindi DB, code, chiavi Keystone) e i residui sui nodi.
#                CEPH RESTA SU, con i suoi dati. Con --wipe-pools cancella anche
#                i pool RBD (VM, volumi, immagini): senza, restano dati orfani.
#                Ripartenza:  [01b se --wipe-pools] -> 02 -> 03 -> [04]
#     ceph       Come openstack + smonta il cluster Ceph (cephadm rm-cluster),
#                azzera SOLO i dischi che erano OSD e toglie keyring/config Kolla.
#                Ripartenza:  01b -> 02 -> 03 -> [04]
#     all        Come ceph + svuota /etc/kolla sul nodo di deploy (globals,
#                inventory, password, override). Ripartenza:  01 -> 01b -> 02 -> 03
#
#   COSA NON TOCCA MAI
#     rete (bond, VLAN, IP), utenti, chiavi SSH di deploy, NTP, /etc/hosts,
#     Docker, venv Kolla, il sistema operativo e i dischi che non erano OSD.
#     Se serve rifare anche quello: 00 (rete) o reinstallazione dell'OS.
#
#   USO
#     sudo LAB_MODE=0 bash 05_reset.sh --level openstack --dry-run   # sola lettura
#     sudo LAB_MODE=0 bash 05_reset.sh --level openstack
#     sudo LAB_MODE=0 bash 05_reset.sh --level ceph
#     sudo LAB_MODE=1 bash 05_reset.sh --level all --yes             # --yes solo in lab
#
#   OPZIONI
#     --dry-run         mostra stato e piano, non cambia nulla
#     --wipe-pools      (openstack) cancella anche i pool images/volumes/vms/backups
#     --new-passwords   rigenera passwords.yml (utile per un redeploy "pulito")
#     --purge-images    rimuove anche le immagini Docker (il redeploy riscarica tutto)
#     --yes             salta la conferma (SOLO con LAB_MODE=1; sul ferro e' ignorato)
## DAVE
#     --from-node       obbligatorio se lo lanci DA UN NODO del cluster (es. node01):
#                       il nodo di lancio viene ripulito come gli altri. Rifiutato se il
#                       pacchetto sta in una cartella che il reset cancella (/etc/kolla,
#                       /var/lib/{docker,ceph}, ...). Consigliato dentro tmux/screen.
#                       (--dry-run, sola lettura, e' ammesso anche senza il flag)
## DAVE
#
#   SUL FERRO la conferma e' una frase da digitare per intero, che contiene il
#   livello e i nomi dei nodi. Nel lab KVM e' piu' veloce ricreare le VM
#   (lab_create_vms.sh) che fare il reset a livello "all".
# =============================================================================
set -uo pipefail

# LAB_MODE esplicito, come tutti gli altri script: nessun default silenzioso.
# DEVE stare PRIMA del source di lib_topology.sh, che lo imposta a 0 se manca.
if [ -z "${LAB_MODE+x}" ] || { [ "$LAB_MODE" != 0 ] && [ "$LAB_MODE" != 1 ]; }; then
  echo "[ERROR] Esporta LAB_MODE esplicitamente (0 = ferro, 1 = lab): un reset non ha default." >&2
  exit 1
fi

# ============================ CONFIG ========================================
source "$(dirname "$0")/lib_topology.sh"

VENV_PATH="/opt/kolla-venv"
INVENTORY="/etc/kolla/multinode"
DESTROY_TIMEOUT=1800
RBD_POOLS="images volumes vms backups"      # gli stessi che crea 01b

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}=== $* ===${NC}"; }
log_ok()    { echo -e "  ${GREEN}[OK]${NC} $*"; }
log_fail()  { echo -e "  ${RED}[FAIL]${NC} $*"; }

LEVEL=""; DRY=0; WIPE_POOLS=0; NEW_PASSWORDS=0; PURGE_IMAGES=0; ASSUME_YES=0
## DAVE
FROM_NODE=0
## DAVE
while [ $# -gt 0 ]; do
  case "$1" in
    --level)         LEVEL="${2:-}"; shift ;;
    --dry-run)       DRY=1 ;;
    --wipe-pools)    WIPE_POOLS=1 ;;
    --new-passwords) NEW_PASSWORDS=1 ;;
    --purge-images)  PURGE_IMAGES=1 ;;
    --yes)           ASSUME_YES=1 ;;
## DAVE
    --from-node)     FROM_NODE=1 ;;
## DAVE
    --help|-h)       sed -n '2,45p' "$0"; exit 0 ;;
    *) log_error "Opzione sconosciuta: $1"; exit 1 ;;
  esac
  shift
done

case "$LEVEL" in
  openstack|ceph|all) ;;
  "") log_error "Manca --level openstack|ceph|all (vedi --help)"; exit 1 ;;
  *)  log_error "Livello '${LEVEL}' non valido: usa openstack, ceph o all"; exit 1 ;;
esac
if [ "$WIPE_POOLS" = 1 ] && [ "$LEVEL" != openstack ]; then
  log_warn "--wipe-pools e' implicito nei livelli ceph/all (il cluster viene smontato): ignoro l'opzione"
  WIPE_POOLS=0
fi

# -n: ssh non legge lo stdin (altrimenti si mangia la frase di conferma digitata).
# clean_node, che passa uno script via stdin, usa ssh_node_in (senza -n).
SSH_OPTS=(-n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=30)
ssh_dep()  { ssh "${SSH_OPTS[@]}" -i "$DEPLOY_KEY" "root@${DEPLOY_NODE_IP}" "$@"; }
ssh_node() { local ip="$1"; shift; ssh "${SSH_OPTS[@]}" -i "$DEPLOY_KEY" "root@${ip}" "$@"; }
ssh_node_in() { local ip="$1"; shift; ssh "${SSH_OPTS[@]:1}" -i "$DEPLOY_KEY" "root@${ip}" "$@"; }
osc() { ssh_dep "source ${VENV_PATH}/bin/activate; source /root/admin-openrc.sh 2>/dev/null; $*"; }

## DAVE
# ------------------- guardia: sto girando su un nodo del cluster? -------------
# Il reset pulisce TUTTI i nodi, quello di lancio compreso. E' sicuro solo se la
# sessione e il pacchetto non dipendono da cio' che viene cancellato.
if [ -n "${SELF:-}" ]; then
  if [ "$FROM_NODE" != 1 ] && [ "$DRY" != 1 ]; then
    log_error "Sto girando sul nodo ${SELF} del cluster: il reset pulirebbe anche questo nodo."
    log_error "Se e' quello che vuoi, rilancia con --from-node (consigliato dentro tmux/screen)."
    log_error "Per solo guardare cosa verrebbe distrutto:  --dry-run  (ammesso anche senza il flag)."
    exit 1
  fi
  if [ "$FROM_NODE" = 1 ]; then
    if ! _pkgdir="$(topo_pkg_dir_safe)"; then
      log_error "Il pacchetto sta in ${_pkgdir}, cartella che il reset cancella: spostalo (es. in /root) e rilancia."
      exit 1
    fi
    topo_in_persistent_session || log_warn "Non risulti in tmux/screen/nohup: se la console web cade a meta', il reset si interrompe e lascia uno stato misto."
    log_warn "--from-node: ${SELF} e' il nodo di lancio e sara' ripulito come gli altri."
  fi
elif [ "$FROM_NODE" = 1 ]; then
  log_error "--from-node ha senso solo su un nodo del cluster: nessun IP di management locale corrisponde a ${ALL_NODES[*]}."
  log_error "Se gli IP reali dei nodi sono diversi da quelli di lib_topology.sh, lancia prima:  sudo bash configura_topologia.sh"
  exit 1
fi
## DAVE

LOG_DIR="$(cd "$(dirname "$0")" && pwd)/logs-reset-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR" && exec > >(tee -a "$LOG_DIR/reset.log") 2>&1

declare -A OSD_PVS=()     # nodo -> elenco PV che appartengono a VG ceph-*
declare -A CEPH_FSIDS=()  # nodo -> fsid trovati in /var/lib/ceph

# ------------------------- 0. Precheck e fotografia -------------------------
precheck() {
  log_step "Precheck (livello: ${LEVEL}$([ "$DRY" = 1 ] && echo ', DRY-RUN'))"
  local n bad=0
  for n in "${ALL_NODES[@]}"; do
    if ssh_node "$(mgmt_ip "$n")" "true" 2>/dev/null; then log_ok "${n} raggiungibile"
    else log_fail "${n} (${NODE_MGMT_IP[$n]}) NON raggiungibile"; bad=1; fi
  done
  if [ "$bad" = 1 ]; then
    log_error "Un reset a meta' lascia il cluster in uno stato misto: tutti i nodi devono rispondere."
    exit 1
  fi
}

snapshot_state() {
  log_step "Stato attuale (cosa verrebbe distrutto)"
  local f="$LOG_DIR/stato_prima.txt"
  {
    echo "# $(date -Is)  livello=${LEVEL}  LAB_MODE=${LAB_MODE}"
    echo "## OpenStack"
    osc "echo -n 'istanze: '; openstack server list --all-projects -f value -c ID 2>/dev/null | wc -l;
         echo -n 'volumi : '; openstack volume list --all-projects -f value -c ID 2>/dev/null | wc -l;
         echo -n 'immagini: '; openstack image list -f value -c ID 2>/dev/null | wc -l" 2>/dev/null \
      || echo "(API non raggiungibile o gia' distrutta)"
    echo "## Ceph"
    ssh_dep "ceph -s 2>/dev/null | sed -n '1,14p'; ceph df 2>/dev/null | sed -n '1,14p'" 2>/dev/null \
      || echo "(Ceph non raggiungibile)"
  } > "$f" 2>&1
  cat "$f"

  if [ "$LEVEL" != openstack ]; then
    echo; log_info "Dischi OSD che verrebbero AZZERATI (PV in VG ceph-*):"
    local n pvs fs
    for n in "${ALL_NODES[@]}"; do
      pvs="$(ssh_node "$(mgmt_ip "$n")" "pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk '\$2 ~ /^ceph-/ {print \$1}'" 2>/dev/null | xargs)"
      fs="$(ssh_node "$(mgmt_ip "$n")" "ls /var/lib/ceph 2>/dev/null | grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-' | xargs" 2>/dev/null)"
      OSD_PVS[$n]="$pvs"; CEPH_FSIDS[$n]="$fs"
      echo "  ${n}: dischi=[${pvs:-nessuno}]  fsid=[${fs:-nessuno}]" | tee -a "$f"
    done
  fi
}

# ------------------------- conferma -----------------------------------------
confirm_or_exit() {
  [ "$DRY" = 1 ] && return 0
  echo
  log_warn "OPERAZIONE DISTRUTTIVA E IRREVERSIBILE (livello: ${LEVEL})."
  case "$LEVEL" in
    openstack) log_warn "Tutte le VM, i DB, le code e gli utenti OpenStack vengono cancellati. Ceph resta." ;;
    ceph)      log_warn "Come sopra, piu' TUTTI i dati Ceph e l'azzeramento dei dischi OSD elencati." ;;
    all)       log_warn "Come ceph, piu' globals/inventory/password/override in /etc/kolla del nodo di deploy." ;;
  esac
  [ "$WIPE_POOLS" = 1 ] && log_warn "--wipe-pools: i pool ${RBD_POOLS} vengono cancellati."
## DAVE
  [ -n "${SELF:-}" ] && log_warn "Il nodo di lancio (${SELF}) e' tra quelli ripuliti: la sessione resta, ma container, volumi Docker$([ "$LEVEL" != openstack ] && echo ' e dati Ceph') di ${SELF} vengono distrutti."
## DAVE
  if [ "$LAB_MODE" = 1 ]; then
    if [ "$ASSUME_YES" = 1 ]; then log_warn "--yes: conferma saltata (lab)"; return 0; fi
    local a; read -r -p "Scrivi RESET per procedere: " a
    [ "$a" = RESET ] || { log_info "Annullato."; exit 0; }
    return 0
  fi
  [ "$ASSUME_YES" = 1 ] && log_warn "--yes ignorato sul ferro: serve la frase di conferma."
  local want="DISTRUGGI ${LEVEL} ${ALL_NODES[*]}" a
  echo "Per confermare scrivi ESATTAMENTE:  ${want}"
  read -r -p "> " a
  [ "$a" = "$want" ] || { log_info "Frase diversa: annullato, non e' stato toccato nulla."; exit 0; }
  log_warn "Parto fra 10 secondi (Ctrl+C per fermarti)"; sleep 10
}

# ------------------------- 1. OpenStack -------------------------------------
destroy_openstack() {
  log_step "OpenStack: kolla-ansible destroy"
  if [ "$DRY" = 1 ]; then log_info "[DRY] kolla-ansible destroy$([ "$PURGE_IMAGES" = 1 ] && echo ' --include-images')"; return 0; fi
  local extra=""; [ "$PURGE_IMAGES" = 1 ] && extra="--include-images"
  local rc=1 try
  for try in 1 2; do
    ssh_dep "source ${VENV_PATH}/bin/activate; timeout ${DESTROY_TIMEOUT} kolla-ansible destroy \
      -i ${INVENTORY} --configdir /etc/kolla --yes-i-really-really-mean-it ${extra} \
      > /var/log/os-reset-destroy.log 2>&1"
    rc=$?
    [ "$rc" = 0 ] && break
    log_warn "destroy tentativo ${try} fallito (rc=${rc}); ultime righe:"
    ssh_dep "tail -8 /var/log/os-reset-destroy.log" 2>/dev/null
  done
  [ "$rc" = 0 ] && log_ok "kolla-ansible destroy completato" \
                || log_warn "destroy non riuscito: la pulizia per nodo qui sotto prosegue comunque"
}

# pulizia per nodo: container e volumi non-ceph, residui di rete OVS, config Kolla
clean_node() {
  local n="$1" ip is_dep=0
  ip="$(mgmt_ip "$n")"; [ "$n" = "$DEPLOY_NODE" ] && is_dep=1
  ssh_node_in "$ip" "IS_DEP=${is_dep} PURGE=${PURGE_IMAGES} bash -s" <<'REMOTE'
set -u
# container NON ceph (cephadm li chiama ceph-<fsid>-*): tutto il resto e' Kolla
docker ps -a --format '{{.ID}} {{.Names}}' 2>/dev/null | awk '$2 !~ /^ceph-/ {print $1}' | xargs -r docker rm -f >/dev/null 2>&1
docker volume ls -q 2>/dev/null | xargs -r docker volume rm -f >/dev/null 2>&1
[ "$PURGE" = 1 ] && docker image prune -af >/dev/null 2>&1
# residui di rete OVS/OVN lasciati nel kernel dai container distrutti
for l in genev_sys_6081 br-ex br-int; do ip link del dev "$l" 2>/dev/null; done
rm -rf /var/log/kolla/* 2>/dev/null
if [ "$IS_DEP" = 1 ]; then
  find /etc/kolla -mindepth 1 -maxdepth 1 -type d ! -name config -exec rm -rf {} + 2>/dev/null
  rm -f /root/admin-openrc.sh /root/admin-openrc-password.txt /etc/kolla/admin-openrc.sh /etc/kolla/clouds.yaml 2>/dev/null
else
  rm -rf /etc/kolla 2>/dev/null
fi
left=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -vc '^ceph-')
echo "container non-ceph residui: ${left}"
ip -br link 2>/dev/null | grep -E 'br-ex|br-int|genev' && echo "[WARN] interfacce OVS residue (spariscono al riavvio)" || true
REMOTE
}

clean_all_nodes() {
  log_step "Pulizia residui su ogni nodo"
  if [ "$DRY" = 1 ]; then log_info "[DRY] rimozione container/volumi non-ceph, br-ex/br-int/genev, /etc/kolla sui nodi"; return 0; fi
  local n
  for n in "${ALL_NODES[@]}"; do
    log_info "${n}"
    clean_node "$n" | sed 's/^/    /'
  done
}

wipe_pools() {
  log_step "Cancellazione pool RBD (${RBD_POOLS})"
  if [ "$DRY" = 1 ]; then log_info "[DRY] ceph osd pool rm ${RBD_POOLS}"; return 0; fi
  ssh_dep "ceph config set mon mon_allow_pool_delete true; \
    for p in ${RBD_POOLS}; do ceph osd pool rm \$p \$p --yes-i-really-really-mean-it 2>&1 | tail -1; done; \
    ceph config set mon mon_allow_pool_delete false"
  log_ok "pool cancellati: dopo il reset rilancia 01b (li ricrea con keyring e config Kolla)"
}

new_passwords() {
  log_step "Nuove password Kolla"
  if [ "$DRY" = 1 ]; then log_info "[DRY] passwords.yml -> passwords.yml.old-<data> + kolla-genpwd"; return 0; fi
  ssh_dep "set -e; source ${VENV_PATH}/bin/activate; ts=\$(date +%Y%m%d-%H%M%S)
    [ -f /etc/kolla/passwords.yml ] && cp -p /etc/kolla/passwords.yml /etc/kolla/passwords.yml.old-\$ts
    cp ${VENV_PATH}/share/kolla-ansible/etc_examples/kolla/passwords.yml /etc/kolla/passwords.yml
    kolla-genpwd" >/dev/null && log_ok "passwords.yml rigenerato (la vecchia e' salvata accanto, con data)" \
                              || log_warn "rigenerazione password non riuscita: il 02 la rifara' se serve"
}

# ------------------------- 2. Ceph ------------------------------------------
destroy_ceph() {
  log_step "Ceph: smontaggio del cluster e azzeramento dei dischi OSD"
  if [ "$DRY" = 1 ]; then
    log_info "[DRY] ceph mgr module disable cephadm; cephadm rm-cluster --force --zap-osds su ogni nodo"
    log_info "[DRY] verifica dischi OSD azzerati (solo quelli elencati sopra)"
    return 0
  fi
  ssh_dep "ceph mgr module disable cephadm 2>&1 | tail -1" || true     # evita che riparta a ridistribuire
  local n f order=() ip
  for n in "${ALL_NODES[@]}"; do [ "$n" != "$DEPLOY_NODE" ] && order+=("$n"); done
  order+=("$DEPLOY_NODE")                                              # il nodo con la CLI per ultimo
  for n in "${order[@]}"; do
    ip="$(mgmt_ip "$n")"
    if [ -z "${CEPH_FSIDS[$n]:-}" ]; then log_info "${n}: nessun cluster Ceph da smontare"; continue; fi
    for f in ${CEPH_FSIDS[$n]}; do
      log_info "${n}: cephadm rm-cluster ${f}"
      ssh_node "$ip" "command -v cephadm >/dev/null && cephadm rm-cluster --fsid ${f} --force --zap-osds 2>&1 | tail -2 \
                      || echo '[WARN] cephadm assente'"
    done
  done

  log_step "Verifica/azzeramento dischi OSD"
  local dev left bad=0
  for n in "${ALL_NODES[@]}"; do
    ip="$(mgmt_ip "$n")"
    [ -z "${OSD_PVS[$n]:-}" ] && continue
    for dev in ${OSD_PVS[$n]}; do
      left="$(ssh_node "$ip" "pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v d='${dev}' '\$1==d && \$2 ~ /^ceph-/ {print \$2}'")"
      if [ -n "$left" ]; then
        log_warn "${n}:${dev} ha ancora ${left}: rimozione manuale (solo questo disco)"
        ssh_node "$ip" "for v in ${left}; do vgremove -fy \$v >/dev/null 2>&1; done;
                        dmsetup ls 2>/dev/null | awk '/^ceph--/{print \$1}' | xargs -r -n1 dmsetup remove --force 2>/dev/null;
                        pvremove -ffy ${dev} >/dev/null 2>&1; wipefs -a ${dev} >/dev/null 2>&1; true"
      fi
      if ssh_node "$ip" "lsblk -no FSTYPE ${dev} 2>/dev/null | grep -q LVM2_member"; then
        log_fail "${n}:${dev} risulta ancora LVM: controlla a mano (lsblk -f ${dev})"; bad=1
      else
        log_ok "${n}:${dev} pulito"
      fi
    done
  done

  log_step "Residui Ceph sui nodi e nel nodo di deploy"
  for n in "${ALL_NODES[@]}"; do
    ssh_node "$(mgmt_ip "$n")" "rm -rf /etc/ceph/* /var/lib/ceph/* /var/log/ceph/* 2>/dev/null;
      sed -i '/ceph-[0-9a-f]\{8\}-/d' /root/.ssh/authorized_keys 2>/dev/null; true"
  done
  ssh_dep "rm -f /etc/kolla/config/glance/ceph.* /etc/kolla/config/cinder/ceph.conf \
             /etc/kolla/config/cinder/cinder-volume/ceph.* /etc/kolla/config/cinder/cinder-backup/ceph.* \
             /etc/kolla/config/nova/ceph.* 2>/dev/null; true"
  [ "$bad" = 0 ] && log_ok "Ceph rimosso" || log_warn "Ceph rimosso, ma con dischi da controllare (vedi sopra)"
}

# ------------------------- 3. all -------------------------------------------
clear_kolla_state() {
  log_step "Livello all: svuoto /etc/kolla sul nodo di deploy"
  if [ "$DRY" = 1 ]; then log_info "[DRY] rm -rf /etc/kolla/* (globals, multinode, passwords, config)"; return 0; fi
  ssh_dep "rm -rf /etc/kolla/* /etc/kolla/.[!.]* 2>/dev/null; ls -A /etc/kolla | wc -l"
  log_ok "/etc/kolla vuoto: lo ricostruisce il 01"
}

# ------------------------- riepilogo ----------------------------------------
summary() {
  log_step "Fatto"
  if [ "$DRY" = 1 ]; then
    log_info "DRY-RUN: nessuna modifica fatta. Log in ${LOG_DIR}"
    return 0
  fi
  echo "  Log e stato precedente: ${LOG_DIR}"
  echo "  Rete, utenti, chiavi, NTP, Docker e venv Kolla NON sono stati toccati."
  echo
  echo "  RIPARTENZA ($(case "$LEVEL" in openstack) [ "$WIPE_POOLS" = 1 ] && echo "01b -> 02 -> 03" || echo "02 -> 03" ;; ceph) echo "01b -> 02 -> 03" ;; all) echo "01 -> 01b -> 02 -> 03" ;; esac)):"
  [ "$LEVEL" = all ] && echo "    sudo LAB_MODE=${LAB_MODE} bash 01_prepare_nodes_3NODE.sh"
  { [ "$LEVEL" != openstack ] || [ "$WIPE_POOLS" = 1 ]; } && echo "    sudo LAB_MODE=${LAB_MODE} bash 01b_setup_ceph_3NODE.sh"
  echo "    sudo LAB_MODE=${LAB_MODE} bash 02_deploy_openstack_3NODE.sh"
  echo "    sudo LAB_MODE=${LAB_MODE} bash 03_configure_openstack_3NODE.sh"
  ## DAVE
  echo "    (opzionale) ENABLE_MASAKARI: sudo LAB_MODE=${LAB_MODE} bash 04_masakari.sh$([ "$LAB_MODE" = 0 ] && echo ' --accept-no-fencing')"
  [ "$LEVEL" = all ] && echo "  Dopo 'all' il globals.yml riparte da zero: enable_masakari torna 'no' e si riattiva col 04."
  ## DAVE
}

main() {
  topo_validate >/dev/null 2>&1 || true
  precheck
  snapshot_state
  confirm_or_exit
  destroy_openstack
  clean_all_nodes
  [ "$WIPE_POOLS" = 1 ] && wipe_pools
  [ "$NEW_PASSWORDS" = 1 ] && [ "$LEVEL" != all ] && new_passwords
  case "$LEVEL" in
    ceph|all) destroy_ceph ;;
  esac
  [ "$LEVEL" = all ] && clear_kolla_state
  summary
}
main

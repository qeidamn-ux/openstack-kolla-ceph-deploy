#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Davide Marino
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
# 01b_setup_ceph_3NODE.sh — Ceph Squid (cephadm) su 3 nodi
#   iperconvergenti, integrato con Kolla come "External Ceph".
#   Gira DALL'HOST di deploy (stessa deploy key del 00).
#
#   Topologia (tutto sullo stesso ferro):
#     MON : node01, node02, node03          (quorum a 3)
#     MGR : node01, node02                   (attivo + standby)
#     OSD : node01, node02, node03           (default 7 SSD 1.92TB/nodo; altri dischi: rilevati)
#   Reti Ceph (bond1, MTU 9000):
#     public  = 10.0.40.0/24 (VLAN 40) — client OpenStack <-> Ceph, MON
#     cluster = 10.0.50.0/24 (VLAN 50) — replica/heartbeat OSD<->OSD
#   Management cephadm/SSH: rete mgmt 10.0.10.0/24 (percorso gia' validato dal 00).
#
#   ORDINE: 00 -> 01 -> [ QUESTO ] -> 02 -> 03
#
#   PRESUPPONE (gate dei passi precedenti):
#     - 00: dischi in Non-RAID (7x ~1.92TB grezzi), reti Ceph su/jumbo ok, NTP ok
#     - 01: Docker attivo su tutti i nodi (cephadm usa Docker come container engine)
#
#   NOTA 3-NODI: size=3/min_size=2, failure domain=host. Un nodo giu' = cluster
#   UP ma DEGRADATO senza poter ricostruire la 3a copia (manca un 4o dominio).
#   Durante un reboot pianificato si e' a min_size: accettabile in lab, va a verbale.
#
## DAVE
#   CIFRATURA OSD: attiva di default (OSD_ENCRYPT=yes). Disattiva con:
#         sudo OSD_ENCRYPT=no bash 01b_setup_ceph_3NODE.sh
## DAVE
#
#   USO:  sudo bash 01b_setup_ceph_3NODE.sh
#         sudo bash 01b_setup_ceph_3NODE.sh --discover-disks  # solo analisi dischi
#         sudo bash 01b_setup_ceph_3NODE.sh --zap-osd   # riusa anche dischi con dati (li CANCELLA)
#
#   DISCHI: di default cerca gli SSD da ~1.92TB del progetto. Se i nodi ne hanno
#   di diversi, mostra cosa trova, propone i gruppi uguali su tutti i nodi e
#   salva la scelta in osd_disks.conf (riusata dai lanci successivi).
# =============================================================================
set -uo pipefail

# ============================ CONFIG ========================================
source "$(dirname "$0")/lib_topology.sh"

CEPH_NODE_MGMT="${DEPLOY_NODE_IP}"           # node di deploy: qui gira cephadm
## DAVE
# Password della dashboard Ceph. Il default e' SOLO da laboratorio: sul campo si imposta in secrets.conf
# (accanto agli script, chmod 600; modello: secrets.conf.example).
DASHBOARD_PASS="Ceph@Lab2026!"
SECRETS_CONF="${SECRETS_CONF:-$(cd "$(dirname "$0")" && pwd)/secrets.conf}"
[ -f "$SECRETS_CONF" ] && source "$SECRETS_CONF"
# Le password finiscono dentro comandi shell e YAML: niente apici, virgolette, backslash, $, backtick,
# spazi; almeno 8 caratteri.
secret_ok() { [ "${#1}" -ge 8 ] && case "$1" in *[\'\"\\\$\`\ ]*) return 1 ;; esac; }
if ! secret_ok "$DASHBOARD_PASS"; then
  echo "ERRORE: DASHBOARD_PASS non valida (almeno 8 caratteri, senza apici, virgolette, backslash, \$, backtick, spazi). Controlla ${SECRETS_CONF}." >&2; exit 1
fi
## DAVE

# derivati dalla topologia
declare -A MGMT_IPS; for _k in "${ALL_NODES[@]}"; do MGMT_IPS[$_k]="${NODE_MGMT_IP[$_k]}"; done
MON_HOSTS="$(topo_mon_csv)"                   # es. node01,node02,node03
MGR_HOSTS="$(topo_mgr_csv)"
OSD_NODES=("${STORAGE_NODES[@]}")             # OSD su tutti i nodi
# CEPH_PUBLIC_CIDR / CEPH_CLUSTER_CIDR / BOOTSTRAP_MON_IP arrivano dalla lib
CEPH_PUBLIC_NET="${CEPH_PUBLIC_CIDR}"
CEPH_CLUSTER_NET="${CEPH_CLUSTER_CIDR}"

# scoperta OSD per DIMENSIONE (non 'rotational': i RAID controller riportano
# spesso gli SSD Non-RAID come rotazionali -> il filtro rotational fallirebbe).
# Default = SSD da 1.92TB del progetto. Se i nodi hanno dischi diversi, lo
# script lo rileva, propone i dischi che trova e salva la scelta in
# osd_disks.conf (accanto agli script). Priorita': variabile d'ambiente >
# osd_disks.conf > default qui sotto.
OSD_DISKS_CONF="$(cd "$(dirname "$0")" && pwd)/osd_disks.conf"
# shellcheck disable=SC1090
[ -f "$OSD_DISKS_CONF" ] && source "$OSD_DISKS_CONF"
DATA_DISK_MIN="${DATA_DISK_MIN:-1700000000000}"   # ~1.7 TB
DATA_DISK_MAX="${DATA_DISK_MAX:-2100000000000}"   # ~2.1 TB

# Numero di dischi OSD per nodo:
#   "auto"  -> scopre quanti dischi (nel range di dimensione) ci sono davvero.
#             Fase 1 con 1 disco/nodo = N OSD; a regime con 7 = 7*nodi.
#             Ri-lanciare dopo aver aggiunto dischi ne aggiunge di nuovi
#             (i dischi gia' OSD vengono saltati) e Ceph ribilancia da solo.
#   <numero> -> gate stretto: pretende ESATTAMENTE quel numero (es. 7 a regime).
OSD_DISKS_PER_NODE="auto"
MIN_OSDS_PER_NODE=1                          # sotto questo su un nodo -> errore
OSD_TOTAL=0                                  # calcolato a runtime in deploy_osd
## DAVE
declare -A OSD_SELECTED=()                  # nodo -> dischi OSD scelti (per verify_osd_encryption)
## DAVE

# CAP dischi OSD per nodo: usa solo i PRIMI N dischi scoperti (vuoto = nessun cap).
# In LAB_MODE le VM hanno poca RAM: 7 OSD/nodo (21 totali) non salgono. 1/nodo
# (3 OSD) e' un cluster valido e sano per questo ambiente. Sul ferro: nessun cap, tutti i 7.
OSD_MAX_PER_NODE="${OSD_MAX_PER_NODE:-}"
[ "${LAB_MODE:-0}" = 1 ] && OSD_MAX_PER_NODE="${OSD_MAX_PER_NODE:-1}"

## DAVE
# CIFRATURA OSD a riposo (dm-crypt/LUKS2 via ceph-volume, spec cephadm 'encrypted: true').
#   yes (default) -> ogni OSD NUOVO viene creato cifrato.
#   no            -> comportamento precedente (OSD in chiaro).
# Le chiavi LUKS stanno nel config-key store dei MON (non sul nodo): un OSD si
# sblocca da solo al boot ma il disco, estratto dal server, e' illeggibile.
# LIMITI: gli OSD GIA' esistenti non vengono convertiti (vanno ricreati: zap +
# rebalance, uno alla volta); chi ha accesso ai MON ha le chiavi; nessun KMS
# esterno (Vault) -> in PRODUZIONE annotare come debito tecnico.
OSD_ENCRYPT="${OSD_ENCRYPT:-yes}"
case "$OSD_ENCRYPT" in
  yes|no) ;;
  *) echo "[WARN]  OSD_ENCRYPT='${OSD_ENCRYPT}' non valido: uso yes"; OSD_ENCRYPT=yes ;;
esac
## DAVE

ZAP_OSD=0
DISCOVER_DISKS=0
for arg in "$@"; do
  case "$arg" in
    --zap-osd) ZAP_OSD=1 ;;
    --discover-disks) DISCOVER_DISKS=1 ;;
    --help|-h) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Opzione sconosciuta: $arg"; exit 1 ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}=== $* ===${NC}"; }

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=30)
# esegue ceph/cephadm sul nodo di deploy (node01)
ssh_ceph()  { ssh "${SSH_OPTS[@]}" -i "$DEPLOY_KEY" "root@${CEPH_NODE_MGMT}" "$@"; }
# esegue un comando su un nodo qualsiasi (per IP mgmt)
node_exec() { local ip="$1"; shift; ssh "${SSH_OPTS[@]}" -i "$DEPLOY_KEY" "root@${ip}" "$@"; }

# -----------------------------------------------------------------------------
# 0. Precheck
# -----------------------------------------------------------------------------
precheck() {
  log_step "Precheck (00 e 01 devono aver chiuso [OK])"
  if ! ssh_ceph "true" &>/dev/null; then
    log_error "node01 (${CEPH_NODE_MGMT}) non raggiungibile a chiave. Esegui 00 e 01."
    exit 1
  fi
  # Docker (cephadm lo usa come engine)
  ssh_ceph "systemctl is-active --quiet docker" || { log_error "Docker non attivo su node01 (serve il 01)."; exit 1; }
  # rete ceph-public up su node01 (l'IP del MON di bootstrap deve esistere)
  if ! ssh_ceph "ip -o -4 addr show | grep -q ${BOOTSTRAP_MON_IP}"; then
    log_error "IP ceph-public ${BOOTSTRAP_MON_IP} assente su node01: la VLAN 40 e' su? (rilancia 00 --verify-only)"
    exit 1
  fi
  log_info "[OK] node01 raggiungibile, Docker attivo, ceph-public presente"
}

# -----------------------------------------------------------------------------
# 0b. Scoperta dischi dati (SOLA LETTURA: nessun disco viene toccato qui).
#     Per ogni disco del nodo produce una riga:  nome|byte|tipo|modello|stato
#       tipo : nvme | ssd | rot  ('rot' = rotazionale SECONDO IL CONTROLLER:
#              dietro un controller RAID anche gli SSD possono risultare rotazionali,
#              fa fede il modello)
#       stato: libero | osd (gia' OSD Ceph) | sistema (OS, BOSS, montato) |
#              dati (partizioni/filesystem presenti) | piccolo (<100 GB) |
#              rimovibile
# -----------------------------------------------------------------------------
scan_node_disks() {
  node_exec "$1" python3 - <<'PY'
import json, subprocess
raw = subprocess.run(["lsblk", "-J", "-b", "-o",
                      "NAME,SIZE,TYPE,ROTA,TRAN,MODEL,RM,MOUNTPOINTS,FSTYPE"],
                     capture_output=True, text=True).stdout
def walk(n):
    yield n
    for c in n.get("children") or []:
        yield from walk(c)
def true(v):
    return v in (True, 1, "1", "true")
for d in json.loads(raw).get("blockdevices", []):
    if d.get("type") != "disk":
        continue
    name  = d["name"]
    size  = int(d.get("size") or 0)
    model = (d.get("model") or "-").strip().replace("|", "/") or "-"
    tree  = list(walk(d))
    mnts  = [m for n in tree for m in (n.get("mountpoints") or []) if m]
    fs    = [n.get("fstype") for n in tree if n.get("fstype")]
    if name.startswith("nvme") or (d.get("tran") or "") == "nvme":
        tipo = "nvme"
    elif not true(d.get("rota")):
        tipo = "ssd"
    else:
        tipo = "rot"
    if true(d.get("rm")):
        stato = "rimovibile"
    elif mnts or "BOSS" in model.upper():
        stato = "sistema"
    elif any("ceph--" in n["name"] for n in tree):
        stato = "osd"
    elif len(tree) > 1 or fs:
        stato = "dati"
    elif size < 100 * 10**9:
        stato = "piccolo"
    else:
        stato = "libero"
    print(f"{name}|{size}|{tipo}|{model}|{stato}")
PY
}

# dischi da usare come OSD su un nodo (dal file di scansione): nella finestra di
# dimensione, liberi o gia' OSD. Quelli con dati vecchi SOLO con --zap-osd.
select_osd_devs() {
  awk -F'|' -v lo="$DATA_DISK_MIN" -v hi="$DATA_DISK_MAX" -v zap="$ZAP_OSD" '
    $2+0 >= lo && $2+0 <= hi && ($5=="libero" || $5=="osd" || (zap==1 && $5=="dati")) {print "/dev/"$1}' "$1"
}

tb() { awk -v b="$1" 'BEGIN{printf "%.2f", b/1e12}'; }

print_node_disks() {
  awk -F'|' -v lo="$DATA_DISK_MIN" -v hi="$DATA_DISK_MAX" -v zap="$ZAP_OSD" '
    BEGIN { printf "      %-3s %-10s %9s  %-5s %-26s %s\n", "", "DISCO", "TB", "TIPO", "MODELLO", "STATO" }
    { sel = ($2+0>=lo && $2+0<=hi && ($5=="libero"||$5=="osd"||(zap==1&&$5=="dati"))) ? "->" : ""
      printf "      %-3s %-10s %9.2f  %-5s %-26.26s %s\n", sel, $1, $2/1e12, $3, $4, $5 }' "$1"
}

# gruppi di dischi liberi (stessa taglia a +-10GB e stesso tipo) presenti su
# TUTTI i nodi. Output: tipo|byte|quanti_per_nodo, ordinati flash prima,
# poi per capacita' totale.
disk_groups() {
  local n
  for n in "${OSD_NODES[@]}"; do sed "s/^/${n}|/" "$SCAN_DIR/$n"; done |
  awk -F'|' -v list="${OSD_NODES[*]}" '
    BEGIN { nn = split(list, N, " ") }
    $6=="libero" || $6=="osd" {
      k = $4 ":" int($3/1e10 + 0.5)
      c[k, $1]++; K[k] = 1; t[k] = $4
      if (!(k in sz) || $3+0 < sz[k]) sz[k] = $3+0
    }
    END {
      for (k in K) {
        m = -1
        for (i = 1; i <= nn; i++) { v = c[k, N[i]] + 0; if (m < 0 || v < m) m = v }
        if (m > 0) {
          r = (t[k]=="nvme") ? 0 : (t[k]=="ssd") ? 1 : 2
          printf "%d|%.0f|%s|%.0f|%d\n", r, m*sz[k], t[k], sz[k], m
        }
      }
    }' | sort -t'|' -k1,1n -k2,2nr | cut -d'|' -f3-
}

save_disk_choice() {   # $1 = byte del disco scelto -> finestra +-5%
  local lo hi
  lo="$(awk -v b="$1" 'BEGIN{printf "%.0f", b*0.95}')"
  hi="$(awk -v b="$1" 'BEGIN{printf "%.0f", b*1.05}')"
  cat > "$OSD_DISKS_CONF" <<EOF
# Dischi OSD scelti con 01b_setup_ceph_3NODE.sh il $(date '+%Y-%m-%d %H:%M')
# Finestra di dimensione (byte) dei dischi dati: $(tb "$lo")–$(tb "$hi") TB
# Le variabili d'ambiente, se impostate, hanno la precedenza su questo file.
DATA_DISK_MIN="\${DATA_DISK_MIN:-${lo}}"
DATA_DISK_MAX="\${DATA_DISK_MAX:-${hi}}"
EOF
  DATA_DISK_MIN="$lo"; DATA_DISK_MAX="$hi"
  log_info "Scelta salvata in ${OSD_DISKS_CONF} (verra' riusata ai prossimi lanci)"
}

# $1 = report (solo analisi, --discover-disks) | gate (prima del deploy)
check_disks() {
  local mode="$1" n ok=1 cnt raw=0
  SCAN_DIR="$(mktemp -d)"; trap 'rm -rf "$SCAN_DIR"' EXIT
  log_step "Analisi dischi sui nodi (sola lettura) — finestra attuale $(tb "$DATA_DISK_MIN")–$(tb "$DATA_DISK_MAX") TB"
  for n in "${OSD_NODES[@]}"; do
    if ! scan_node_disks "${MGMT_IPS[$n]}" > "$SCAN_DIR/$n" 2>/dev/null || [ ! -s "$SCAN_DIR/$n" ]; then
      log_error "  $n: analisi dischi non riuscita (nodo raggiungibile? python3 presente?)"
      exit 1
    fi
    cnt="$(select_osd_devs "$SCAN_DIR/$n" | grep -c . || true)"
    echo; log_info "$n — ${cnt} disco/hi utilizzabili come OSD (segnati con ->)"
    print_node_disks "$SCAN_DIR/$n"
    [ "$cnt" -lt "$MIN_OSDS_PER_NODE" ] && ok=0
    raw=$(( raw + $(awk -F'|' -v lo="$DATA_DISK_MIN" -v hi="$DATA_DISK_MAX" -v zap="$ZAP_OSD" \
      '$2+0>=lo && $2+0<=hi && ($5=="libero"||$5=="osd"||(zap==1&&$5=="dati")) {s+=$2} END{printf "%.0f", s+0}' "$SCAN_DIR/$n") ))
  done
  if grep -qh '|dati$' "$SCAN_DIR"/* 2>/dev/null && [ "$ZAP_OSD" = 0 ]; then
    echo; log_warn "Ci sono dischi con partizioni o dati esistenti: NON verranno usati."
    log_warn "  Se sono da riutilizzare, rilancia con --zap-osd (CANCELLA il loro contenuto)."
  fi

  if [ "$ok" = 1 ]; then
    echo; log_info "[OK] dischi dati presenti su tutti i nodi: grezzo $(tb "$raw") TB," \
                   "utile ~$(tb $((raw / 3))) TB con replica 3 (tenersi sotto l'80%)"
    return 0
  fi

  echo; log_warn "Su almeno un nodo non ci sono i dischi attesi nella finestra $(tb "$DATA_DISK_MIN")–$(tb "$DATA_DISK_MAX") TB."
  local -a G=(); mapfile -t G < <(disk_groups)
  if [ "${#G[@]}" -eq 0 ]; then
    log_error "Non trovo un gruppo di dischi liberi uguale su tutti i nodi (hardware diverso tra i nodi o dischi occupati)."
    log_error "  Guarda le tabelle sopra. Per forzare una finestra a mano:"
    log_error "    sudo DATA_DISK_MIN=<byte> DATA_DISK_MAX=<byte> bash $(basename "$0")"
    [ "$mode" = report ] && return 0 || exit 1
  fi

  echo; log_info "Ecco cosa ho trovato di utilizzabile, uguale su tutti i nodi:"
  local i=1 g t b c
  for g in "${G[@]}"; do
    IFS='|' read -r t b c <<< "$g"
    printf "      [%d] %d x %s TB (%s) per nodo -> %d OSD, utile ~%s TB con replica 3\n" \
      "$i" "$c" "$(tb "$b")" "$t" "$((c * ${#OSD_NODES[@]}))" "$(tb $(( (b * c * ${#OSD_NODES[@]}) / 3 )) )"
    i=$((i + 1))
  done
  [ "$(printf '%s\n' "${G[@]}" | cut -d'|' -f1 | sort -u | wc -l)" -gt 1 ] && \
    log_warn "  Tipi diversi disponibili: meglio non mischiarli nello stesso pool (prestazioni). La [1] e' quella consigliata."

  if [ -t 0 ] && [ -t 1 ]; then
    local ch
    read -r -p "  Quale uso? [1-${#G[@]}, invio = nessuna]: " ch
    if [[ "$ch" =~ ^[0-9]+$ ]] && [ "$ch" -ge 1 ] && [ "$ch" -le "${#G[@]}" ]; then
      IFS='|' read -r t b c <<< "${G[$((ch - 1))]}"
      save_disk_choice "$b"
      [ "$mode" = gate ] && log_info "Proseguo con ${c} disco/hi da $(tb "$b") TB per nodo."
      return 0
    fi
    log_warn "Nessuna scelta fatta."
  else
    log_warn "Nessun terminale interattivo (es. lanciato da run_all/install): non posso chiederti quale usare."
    log_warn "  Scegli una volta con:  sudo bash $(basename "$0") --discover-disks"
    log_warn "  poi rilancia la catena: la scelta viene salvata in osd_disks.conf."
  fi
  [ "$mode" = report ] && return 0 || exit 1
}

# -----------------------------------------------------------------------------
# 1. lvm2 su tutti i nodi (ceph-volume gestisce gli OSD come LV)
# -----------------------------------------------------------------------------
prep_ceph_hosts() {
  log_step "Prerequisito lvm2 sui 3 nodi"
  for n in "${ALL_NODES[@]}"; do
    node_exec "${MGMT_IPS[$n]}" \
      "dpkg-query -W -f='\${Status}' lvm2 2>/dev/null | grep -q 'install ok installed' || \
       (export DEBIAN_FRONTEND=noninteractive; apt-get install -y lvm2 >/dev/null 2>&1)" \
      && log_info "  $n: lvm2 ok" || log_warn "  $n: lvm2 non installato (verifica manuale)"
  done

  ## DAVE
  # Cifratura OSD: servono cryptsetup e il modulo kernel dm_crypt (caricato anche al boot).
  if [ "$OSD_ENCRYPT" = yes ]; then
    log_step "Prerequisiti cifratura OSD (cryptsetup + dm_crypt)"
    for n in "${ALL_NODES[@]}"; do
      if node_exec "${MGMT_IPS[$n]}" \
        "dpkg-query -W -f='\${Status}' cryptsetup 2>/dev/null | grep -q 'install ok installed' || \
         (export DEBIAN_FRONTEND=noninteractive; apt-get install -y cryptsetup >/dev/null 2>&1); \
         modprobe dm_crypt && echo dm_crypt > /etc/modules-load.d/dm_crypt.conf && \
         dpkg-query -W -f='\${Status}' cryptsetup 2>/dev/null | grep -q 'install ok installed'"; then
        log_info "  $n: cryptsetup + dm_crypt ok"
      else
        log_error "  $n: cryptsetup/dm_crypt non disponibili: gli OSD cifrati non si possono creare"
        exit 1
      fi
    done
  fi
  ## DAVE
}

# -----------------------------------------------------------------------------
# 2. cephadm + ceph-common su node01 dai REPO UBUNTU.
#    download.ceph.com/debian-squid NON pubblica 'noble' -> 'cephadm add-repo'
#    darebbe 404. Ubuntu 24.04 fornisce gia' cephadm/ceph-common Squid (19.2.x).
# -----------------------------------------------------------------------------
install_cephadm() {
  log_step "Installazione cephadm + ceph-common su node01 (repo Ubuntu)"
  ssh_ceph bash << 'ENDSSH'
set -e
export DEBIAN_FRONTEND=noninteractive
# rimuovi un eventuale repo upstream rotto (noble assente -> 404 su apt update)
rm -f /etc/apt/sources.list.d/ceph.list
if command -v cephadm >/dev/null 2>&1 && command -v ceph >/dev/null 2>&1; then
  echo "cephadm/ceph gia' presenti"; ceph --version || true; exit 0
fi
# lock/cache (lezione del 00): update PRIMA dell'install
for i in $(seq 1 60); do fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break; sleep 10; done
apt-get update -q
apt-get install -y cephadm ceph-common
ceph --version
ENDSSH
  log_info "[OK] cephadm installato"
}

# -----------------------------------------------------------------------------
# 3. Bootstrap MON+MGR su node01, con public E cluster network.
# -----------------------------------------------------------------------------
bootstrap_cluster() {
  log_step "Bootstrap cluster Ceph (MON+MGR su node01, public+cluster net)"
  ssh_ceph "BOOTSTRAP_MON_IP='${BOOTSTRAP_MON_IP}' DASHBOARD_PASS='${DASHBOARD_PASS}' \
            CEPH_PUBLIC_NET='${CEPH_PUBLIC_NET}' CEPH_CLUSTER_NET='${CEPH_CLUSTER_NET}' bash" << 'ENDSSH'
set -e
# CRITICO: fissa l'immagine container alla STESSA versione del ceph-common
# dell'host. Il tag 'v19' fluttuante di quay.io puo' essere piu' recente e
# generare il keyring admin in un formato che il 'ceph' dell'host (piu' vecchio)
# non sa parsare -> "Malformed input [buffer:3]", e ogni comando ceph fallisce.
# Allineando le versioni, host-ceph, container e (a valle) i client Ceph di Kolla
# parlano lo stesso formato di chiave.
HOST_VER="$(ceph --version 2>/dev/null | awk '{print $3}')"    # es. 19.2.3
IMG="quay.io/ceph/ceph:v${HOST_VER}"
echo "[INFO] immagine Ceph fissata a ${IMG} (allineata al ceph-common host ${HOST_VER})"
if ceph -s >/dev/null 2>&1; then echo "Cluster gia' attivo, skip bootstrap"; exit 0; fi
cephadm --image "${IMG}" bootstrap \
  --mon-ip "${BOOTSTRAP_MON_IP}" \
  --cluster-network "${CEPH_CLUSTER_NET}" \
  --initial-dashboard-user admin \
  --initial-dashboard-password "${DASHBOARD_PASS}" \
  --dashboard-password-noupdate \
  --skip-monitoring-stack \
  --allow-overwrite
# fissa l'immagine anche per i daemon successivi (MON/OSD aggiunti dopo)
ceph config set global container_image "${IMG}"
ceph config set global public_network  "${CEPH_PUBLIC_NET}"
ceph config set global cluster_network "${CEPH_CLUSTER_NET}"
# Con poca RAM (lab: 16GB, 7 OSD/nodo) evita che gli OSD saturino la memoria:
# cephadm dimensiona osd_memory_target sulla RAM disponibile. Innocuo sul ferro.
ceph config set osd osd_memory_target_autotune true
echo "[OK] bootstrap completato (public=${CEPH_PUBLIC_NET} cluster=${CEPH_CLUSTER_NET})"
ENDSSH
}

# -----------------------------------------------------------------------------
# 4. Autorizza ceph.pub sui nodi e li aggiunge all'orchestratore per IP MGMT.
#    Subito dopo il bootstrap il mgr si RICONFIGURA e puo' scartare host appena
#    aggiunti: add VERIFICATO e RITENTATO finche' tutti e 3 restano stabili.
# -----------------------------------------------------------------------------
add_hosts() {
  log_step "Aggiunta dei ${#ALL_NODES[@]} nodi all'orchestratore (add verificato + retry)"
  # antepone la host-map e le variabili derivate dalla topologia allo script remoto
  { topo_emit_cephadm_hostmap
    echo "ALL='${ALL_NODES[*]}'"
    echo "NNODES=${#ALL_NODES[@]}"
    cat << 'ENDSSH'
set -e
CEPH_PUB="$(cat /etc/ceph/ceph.pub)"

# 1) autorizza la chiave del cluster su root@ di ogni nodo
for h in "${!H[@]}"; do
  # autorizza ceph.pub su root@ di ogni nodo. Serve una chiave GIA' funzionante:
  # id_ed25519_kolla, distribuita dal 01 su tutti i nodi (compreso node01 stesso).
  # Senza '-i' l'ssh userebbe le identita' di default (assenti) -> Permission denied.
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -i /root/.ssh/id_ed25519_kolla "root@${H[$h]}" \
    "mkdir -p /root/.ssh && chmod 700 /root/.ssh; \
     grep -qF \"${CEPH_PUB}\" /root/.ssh/authorized_keys 2>/dev/null || echo \"${CEPH_PUB}\" >> /root/.ssh/authorized_keys; \
     chmod 600 /root/.ssh/authorized_keys" \
    || { echo "ERRORE: chiave non distribuita a $h"; exit 1; }
done

# 2) attendi orchestratore pronto e STABILE (no add durante il riavvio del mgr)
echo "Attendo orchestratore stabile..."
stable=0
for i in $(seq 1 60); do
  if ceph orch status >/dev/null 2>&1 && ceph orch host ls >/dev/null 2>&1; then stable=$((stable+1)); else stable=0; fi
  [ "$stable" -ge 3 ] && break; sleep 3
done
[ "$stable" -ge 3 ] || { echo "ERRORE: orchestratore non stabile"; exit 1; }

host_present() { ceph orch host ls 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$1"; }

# 3) aggiungi e MANTIENI: il mgr in reconcile puo' rimuovere host appena aggiunti
stable=0; present=0
for round in $(seq 1 60); do
  for h in $ALL; do host_present "$h" || ceph orch host add "$h" "${H[$h]}" 2>/dev/null || true; done
  present=0; for h in $ALL; do host_present "$h" && present=$((present+1)); done
  echo "  host presenti: ${present}/${NNODES} (stabile ${stable}/3, giro ${round})"
  if [ "$present" -ge "$NNODES" ]; then stable=$((stable+1)); else stable=0; fi
  [ "$stable" -ge 3 ] && break; sleep 10
done
ceph orch host ls
[ "$stable" -ge 3 ] || { echo "ERRORE: host non stabili (${present}/${NNODES})"; ceph log last 40 cephadm 2>/dev/null || true; exit 1; }
echo "[OK] ${NNODES} host presenti e stabili"
ENDSSH
  } | ssh_ceph "bash -s"
}

# -----------------------------------------------------------------------------
# 5. Placement MON (3) e MGR (2), con attesa host online e retry su "Unknown hosts".
# -----------------------------------------------------------------------------
place_mon_mgr() {
  log_step "Placement MON (${#MON_NODES[@]} nodi) e MGR (${#MGR_NODES[@]} nodi)"
  { topo_emit_cephadm_hostmap
    echo "ALL='${ALL_NODES[*]}'"
    echo "NNODES=${#ALL_NODES[@]}"
    echo "MON_HOSTS='${MON_HOSTS}'"
    echo "MGR_HOSTS='${MGR_HOSTS}'"
    cat << 'ENDSSH'
set -e
host_present() { ceph orch host ls 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$1"; }
host_status() {
  ceph orch host ls --format json 2>/dev/null | python3 -c '
import sys,json
h=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: d=[]
for x in d:
    if x.get("hostname")==h: print((x.get("status") or "").lower()); break
' "$1" 2>/dev/null || echo ""
}
wait_all_hosts_ready() {
  local ok i h st
  for i in $(seq 1 90); do
    ok=0
    for h in $ALL; do
      host_present "$h" || { ceph orch host add "$h" "${H[$h]}" 2>/dev/null || true; continue; }
      st="$(host_status "$h")"
      case "$st" in offline|maintenance) : ;; *) ok=$((ok+1)) ;; esac
    done
    echo "  host pronti: ${ok}/${NNODES} (giro ${i})"
    [ "$ok" -ge "$NNODES" ] && { echo "[OK] host online"; return 0; }
    sleep 10
  done
  echo "ERRORE: host non tutti pronti"; ceph orch host ls; return 1
}
apply_retry() {
  local kind="$1" placement="$2" i h
  for i in $(seq 1 40); do
    for h in $ALL; do host_present "$h" || ceph orch host add "$h" "${H[$h]}" 2>/dev/null || true; done
    if ceph orch apply "$kind" --placement="$placement" 2>/tmp/aerr; then echo "[OK] apply $kind ($placement)"; return 0; fi
    if grep -q "Unknown hosts" /tmp/aerr; then echo "  $kind: host non schedulabili, attendo ($i/40)"; sleep 15; continue; fi
    echo "  errore apply $kind:"; cat /tmp/aerr; return 1
  done
  echo "  TIMEOUT apply $kind"; return 1
}
wait_all_hosts_ready || { ceph log last 40 cephadm 2>/dev/null || true; exit 1; }
apply_retry mon "${MON_HOSTS}"
apply_retry mgr "${MGR_HOSTS}"
echo "Attendo formazione MON..."; sleep 30
ceph -s || true
echo "[OK] placement completato"
ENDSSH
  } | ssh_ceph "bash -s"
}

# -----------------------------------------------------------------------------
# 6. OSD: scoperti per dimensione (numero flessibile). Salta i dischi gia' OSD
#    (ri-esecuzione = espansione), zap opzionale + add per-device con retry.
# -----------------------------------------------------------------------------
## DAVE
# Spec OSD cifrato per UN nodo (YAML su stdout). 'devs' = elenco /dev/... (uno per
# riga): TUTTI i dischi scelti, anche quelli gia' OSD, cosi' lo spec resta
# cumulativo fra le ri-esecuzioni (cephadm salta i dischi non disponibili).
render_osd_spec() {
  local node="$1" devs="$2" d
  echo "service_type: osd"
  echo "service_id: osd_enc_${node}"
  echo "placement:"
  echo "  hosts:"
  echo "    - ${node}"
  echo "spec:"
  echo "  data_devices:"
  echo "    paths:"
  while IFS= read -r d; do [ -n "$d" ] && echo "      - ${d}"; done <<< "$devs"
  echo "  encrypted: true"
}

# Applica lo spec cifrato di un nodo (copia su node01 + 'ceph orch apply -i', con retry).
apply_encrypted_osd_spec() {
  local node="$1" devs="$2" i ok=0
  render_osd_spec "$node" "$devs" | ssh_ceph "cat > /tmp/osd-spec-${node}.yaml" || {
    log_error "    ${node}: impossibile scrivere lo spec OSD su ${CEPH_NODE_MGMT}"; exit 1; }
  for i in $(seq 1 8); do
    if ssh_ceph "ceph orch apply -i /tmp/osd-spec-${node}.yaml" 2>/tmp/oerr; then ok=1; break; fi
    sleep 10
  done
  [ "$ok" = 1 ] && log_info "    OSD cifrati richiesti su ${node} (spec osd_enc_${node})" \
                || { log_error "    apply spec OSD cifrato ${node} fallito"; sed 's/^/        /' /tmp/oerr 2>/dev/null; exit 1; }
}

# Verifica che ogni disco OSD scelto abbia un mapping dm-crypt (lsblk TYPE=crypt).
# Va chiamata a OSD su: se la cifratura e' richiesta e un disco non e' cifrato, ferma.
verify_osd_encryption() {
  [ "$OSD_ENCRYPT" = yes ] || return 0
  log_step "Verifica cifratura OSD (dm-crypt)"
  local n dev bad=0 tot=0
  for n in "${OSD_NODES[@]}"; do
    local ip="${MGMT_IPS[$n]}"
    while IFS= read -r dev <&3; do
      [ -z "$dev" ] && continue
      tot=$((tot + 1))
      if node_exec "$ip" "lsblk -ln -o TYPE '$dev' 2>/dev/null | grep -qx crypt"; then
        log_info "  ${n}:${dev} cifrato (crypt)"
      else
        log_warn "  ${n}:${dev} NON risulta cifrato (OSD creato prima della cifratura? vedi README)"
        bad=$((bad + 1))
      fi
    done 3<<< "${OSD_SELECTED[$n]:-}"
  done
  if [ "$bad" -gt 0 ]; then
    log_error "${bad}/${tot} dischi OSD non cifrati con OSD_ENCRYPT=yes."
    log_error "  Se sono OSD pre-esistenti vanno ricreati (uno alla volta: out -> zap -> rebalance)."
    exit 1
  fi
  log_info "[OK] ${tot}/${tot} dischi OSD cifrati"
}
## DAVE

deploy_osd() {
  log_step "Deploy OSD — dischi $(tb "$DATA_DISK_MIN")–$(tb "$DATA_DISK_MAX") TB (modo: ${OSD_DISKS_PER_NODE})"
  ## DAVE
  log_info "Cifratura OSD (dm-crypt/LUKS): ${OSD_ENCRYPT}"
  ## DAVE
  ssh_ceph "ceph orch device ls --refresh >/dev/null 2>&1 || true"
  sleep 10

  OSD_TOTAL=0
  local -A NODE_DISK_COUNT=()

  for n in "${OSD_NODES[@]}"; do
    local ip="${MGMT_IPS[$n]}"
    # dischi dati: stessa analisi del gate (finestra di dimensione + stato).
    # Esclude sistema/BOSS e i dischi con dati vecchi (salvo --zap-osd).
    local devs; scan_node_disks "$ip" > "$SCAN_DIR/$n.now" 2>/dev/null
    devs="$(select_osd_devs "$SCAN_DIR/$n.now")"
    local cnt; cnt="$(echo "$devs" | grep -c '^/dev/' || true)"

    # CAP (LAB_MODE): tieni solo i PRIMI N dischi, gli altri restano inutilizzati.
    if [ -n "$OSD_MAX_PER_NODE" ] && [ "$cnt" -gt "$OSD_MAX_PER_NODE" ]; then
      devs="$(echo "$devs" | head -n "$OSD_MAX_PER_NODE")"
      log_warn "  $n: cap OSD attivo -> uso ${OSD_MAX_PER_NODE}/${cnt} dischi ($(echo "$devs" | tr '\n' ' '))"
      cnt="$OSD_MAX_PER_NODE"
    fi
    NODE_DISK_COUNT[$n]=$cnt
    ## DAVE
    OSD_SELECTED[$n]="$devs"
    ## DAVE

    # validazione conteggio: fissa o "auto"
    if [ "$OSD_DISKS_PER_NODE" != "auto" ]; then
      if [ "$cnt" -ne "$OSD_DISKS_PER_NODE" ]; then
        log_error "  $n: trovati ${cnt} dischi dati (attesi ${OSD_DISKS_PER_NODE}). controller in RAID? (vedi 00)"
        node_exec "$ip" "lsblk -dn -o NAME,SIZE,TYPE,MODEL" | sed 's/^/      /'
        exit 1
      fi
    elif [ "$cnt" -lt "$MIN_OSDS_PER_NODE" ]; then
      log_error "  $n: ${cnt} dischi dati (minimo ${MIN_OSDS_PER_NODE}). Nessuno storage su questo nodo."
      node_exec "$ip" "lsblk -dn -o NAME,SIZE,TYPE,MODEL" | sed 's/^/      /'
      exit 1
    fi
    log_info "  $n: ${cnt} disco/hi dati: $(echo "$devs" | tr '\n' ' ')"

    # attendi enrollment + scan dischi da parte di cephadm
    local ready=0 i
    for i in $(seq 1 40); do
      if ssh_ceph "ceph orch device ls $n 2>/dev/null | awk 'NR>1 && NF>0'" | grep -q .; then ready=1; break; fi
      sleep 15
    done
    [ "$ready" = 1 ] || { log_error "  $n: cephadm non ha scansionato i dischi"; exit 1; }

    # NB: i dischi si leggono da fd 3: ssh dentro il ciclo consumerebbe lo stdin e salterebbe i dischi dopo il primo
    ## DAVE
    local new_devs=()
    ## DAVE
    while IFS= read -r dev <&3; do
      [ -z "$dev" ] && continue
      # SALTA i dischi gia' OSD (Ceph crea un LV 'ceph--...'): rende la
      # ri-esecuzione un'espansione idempotente invece di un errore.
      if node_exec "$ip" "lsblk -ln -o NAME '$dev' 2>/dev/null | grep -q 'ceph--'"; then
        log_info "    ${n}:${dev} gia' OSD, salto"
        continue
      fi
      [ "$ZAP_OSD" = 1 ] && ssh_ceph "ceph orch device zap $n $dev --force" >/dev/null 2>&1 || true
      ## DAVE
      # cifrato: 'daemon add osd' non ha l'opzione -> si raccoglie il disco e si applica uno spec per nodo
      if [ "$OSD_ENCRYPT" = yes ]; then new_devs+=("$dev"); continue; fi
      ## DAVE
      local ok=0
      for i in $(seq 1 8); do
        if ssh_ceph "ceph orch daemon add osd ${n}:${dev}" 2>/tmp/oerr; then ok=1; break; fi
        if grep -qiE "already|exists|prepared" /tmp/oerr 2>/dev/null; then ok=1; break; fi
        if grep -qiE "not available|Unable" /tmp/oerr 2>/dev/null; then
          ssh_ceph "ceph orch device zap $n $dev --force" >/dev/null 2>&1 || true
        fi
        sleep 10
      done
      [ "$ok" = 1 ] && log_info "    OSD richiesto ${n}:${dev}" \
                    || { log_error "    add osd ${n}:${dev} fallito"; ssh_ceph "cat /tmp/oerr" 2>/dev/null | sed 's/^/        /'; exit 1; }
    done 3<<< "$devs"

    ## DAVE
    if [ "$OSD_ENCRYPT" = yes ]; then
      if [ "${#new_devs[@]}" -gt 0 ]; then apply_encrypted_osd_spec "$n" "$devs"
      else log_info "    ${n}: nessun disco nuovo da cifrare"; fi
    fi
    ## DAVE

    OSD_TOTAL=$((OSD_TOTAL + cnt))
  done

  # controllo simmetria: OSD sbilanciati fra i nodi -> CRUSH con size=3 usa la
  # capacita' del nodo piu' piccolo. Non blocca (utile in fase di espansione), avvisa.
  local first="${NODE_DISK_COUNT[${OSD_NODES[0]}]}"
  for n in "${OSD_NODES[@]}"; do
    [ "${NODE_DISK_COUNT[$n]}" != "$first" ] && {
      log_warn "Dischi sbilanciati fra i nodi ($(for x in "${OSD_NODES[@]}"; do echo -n "$x=${NODE_DISK_COUNT[$x]} "; done)): con size=3 vince il nodo piu' piccolo."
      break
    }
  done

  log_info "Attendo che gli OSD salgano (atteso ${OSD_TOTAL} up)..."
  local up=0 i
  for i in $(seq 1 60); do
    up="$(ssh_ceph "ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '[0-9]+' | head -1" 2>/dev/null || echo 0)"
    echo "  OSD up: ${up:-0}/${OSD_TOTAL} (giro ${i})"
    [ "${up:-0}" -ge "$OSD_TOTAL" ] && break
    sleep 10
  done
  [ "${up:-0}" -ge "$OSD_TOTAL" ] \
    && log_info "[OK] ${up} OSD up" \
    || log_warn "solo ${up}/${OSD_TOTAL} OSD up: attendi o controlla 'ceph orch device ls'"
}

# -----------------------------------------------------------------------------
# 7. Pool RBD, utenti/keyring e config Kolla (external ceph).
# -----------------------------------------------------------------------------
create_pools_and_kolla_config() {
  log_step "Pool RBD, keyring e config Kolla (external ceph)"
  ssh_ceph bash << 'ENDSSH'
set -e
# pool: images (glance), volumes (cinder), vms (nova), backups (cinder-backup)
# pg_autoscale (default on in Squid) aggiusta i PG con 21 OSD.
for p in images volumes vms backups; do
  ceph osd pool create "$p" 2>/dev/null || true
  rbd pool init "$p" 2>/dev/null || true
done

ceph auth get-or-create client.glance \
  mon 'profile rbd' osd 'profile rbd pool=images' >/dev/null
ceph auth get-or-create client.cinder \
  mon 'profile rbd' osd 'profile rbd pool=volumes, profile rbd pool=vms, profile rbd pool=images' >/dev/null
ceph auth get-or-create client.cinder-backup \
  mon 'profile rbd' osd 'profile rbd pool=backups' >/dev/null
ceph auth get-or-create client.nova \
  mon 'profile rbd' osd 'profile rbd pool=volumes, profile rbd pool=vms, profile rbd pool=images' >/dev/null

mkdir -p /etc/kolla/config/glance
mkdir -p /etc/kolla/config/cinder/cinder-volume
mkdir -p /etc/kolla/config/cinder/cinder-backup
mkdir -p /etc/kolla/config/nova

# ceph.conf minimale. NB: 'generate-minimal-conf' indenta le chiavi con un TAB,
# che il parser INI di oslo.config (Kolla) rifiuta come "continuation line".
# Rimuoviamo l'indentazione iniziale.
ceph config generate-minimal-conf | sed 's/^[[:space:]]\+//' > /tmp/ceph.conf
cp /tmp/ceph.conf /etc/kolla/config/glance/ceph.conf
cp /tmp/ceph.conf /etc/kolla/config/cinder/ceph.conf
cp /tmp/ceph.conf /etc/kolla/config/nova/ceph.conf

ceph auth get client.glance        -o /etc/kolla/config/glance/ceph.client.glance.keyring
ceph auth get client.cinder        -o /etc/kolla/config/cinder/cinder-volume/ceph.client.cinder.keyring
ceph auth get client.cinder        -o /etc/kolla/config/cinder/cinder-backup/ceph.client.cinder.keyring
ceph auth get client.cinder-backup -o /etc/kolla/config/cinder/cinder-backup/ceph.client.cinder-backup.keyring
ceph auth get client.nova          -o /etc/kolla/config/nova/ceph.client.nova.keyring
ceph auth get client.cinder        -o /etc/kolla/config/nova/ceph.client.cinder.keyring

echo "[OK] /etc/kolla/config popolato:"
find /etc/kolla/config -maxdepth 3 -type f | sort
ENDSSH
}

# -----------------------------------------------------------------------------
# 8. Abilita i target Ceph al boot su tutti i nodi.
#    CRITICO: 'bootstrap-servers' del 02 riavvia il daemon Docker; se i target
#    non sono enabled, i daemon cephadm (systemd) restano spenti dopo il riavvio.
# -----------------------------------------------------------------------------
enable_ceph_at_boot() {
  log_step "Abilito i target Ceph al boot (resistono al riavvio Docker del 02)"
  local fsid; fsid="$(ssh_ceph "ceph fsid" 2>/dev/null | tr -d '[:space:]')"
  [ -z "$fsid" ] && { log_warn "fsid non leggibile, salto (abilita a mano se serve)"; return 0; }
  log_info "  fsid: ${fsid}"
  for n in "${ALL_NODES[@]}"; do
    node_exec "${MGMT_IPS[$n]}" \
      "systemctl enable ceph.target >/dev/null 2>&1; systemctl enable ceph-${fsid}.target >/dev/null 2>&1; true" \
      && log_info "  $n: target Ceph abilitati al boot" \
      || log_warn "  $n: enable non riuscito (verifica a mano)"
  done
}

# -----------------------------------------------------------------------------
# 9. Salute e riepilogo.
# -----------------------------------------------------------------------------
wait_health_and_summary() {
  log_step "Stato cluster"
  ssh_ceph "OSD_TOTAL='${OSD_TOTAL}' bash" << 'ENDSSH'
for i in $(seq 1 30); do
  up=$(ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '[0-9]+' | head -1 || echo 0)
  [ "${up:-0}" -ge "${OSD_TOTAL}" ] && break
  sleep 10
done
echo ""; ceph -s
echo ""; ceph osd tree
echo ""; ceph df
echo ""; ceph osd pool autoscale-status 2>/dev/null || true
ENDSSH

  local per_node=$(( OSD_TOTAL / ${#OSD_NODES[@]} ))
  cat << EOF

+--------------------------------------------------------------+
   Ceph Squid pronto — External Ceph per Kolla (3 nodi)
+--------------------------------------------------------------+
  MON     : ${MON_HOSTS}      (public ${CEPH_PUBLIC_NET})
  MGR     : ${MGR_HOSTS}
  OSD     : ${OSD_TOTAL} totali (~${per_node}/nodo)
  Cifratura OSD: ${OSD_ENCRYPT} (dm-crypt/LUKS; chiavi nel config-key store dei MON)
  Reti    : public ${CEPH_PUBLIC_NET} | cluster ${CEPH_CLUSTER_NET}
  Pool    : images, volumes, vms, backups
  Config  : /etc/kolla/config/{glance,cinder,nova}/ (ceph.conf + keyring)
  Dashboard: https://${CEPH_NODE_MGMT}:8443  (admin / ${DASHBOARD_PASS})

  GATE prima del 02: 'ceph -s' deve dare HEALTH_OK, mon 3 in quorum,
  ${OSD_TOTAL} osds up/in. (HEALTH_WARN transitorio sui PG e' ok.)

  ESPANSIONE (fase 2): dopo aver reso disponibili altri dischi (Non-RAID),
  ri-lancia QUESTO script: aggiunge solo i dischi nuovi (quelli gia' OSD sono
  saltati) e Ceph ribilancia da solo. L'autoscaler aumentera' i PG di conseguenza
  (comporta rebalance: normale, si fa a caldo).

  PROSSIMO PASSO: 02_deploy_openstack_3NODE.sh
  I target Ceph sono ABILITATI al boot: sopravvivono al riavvio Docker che
  'bootstrap-servers' fa nel 02. Dopo il 02, ricontrolla comunque 'ceph -s'.
EOF
}

main() {
  log_step "Ceph Squid + External Ceph per Kolla (${#ALL_NODES[@]} nodi)"
  topo_validate || { log_error "Topologia non valida (vedi lib_topology.sh)"; exit 1; }
  if [ "$DISCOVER_DISKS" = 1 ]; then   # solo analisi: non tocca Ceph ne' i dischi
    check_disks report
    exit 0
  fi
  precheck
  check_disks gate                    # prima di creare qualsiasi cosa
  prep_ceph_hosts
  install_cephadm
  bootstrap_cluster
  add_hosts
  place_mon_mgr
  deploy_osd
  ## DAVE
  verify_osd_encryption
  ## DAVE
  create_pools_and_kolla_config
  enable_ceph_at_boot
  wait_health_and_summary
}

main "$@"

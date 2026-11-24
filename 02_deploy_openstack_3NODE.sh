#!/usr/bin/env bash
# =============================================================================
# 02_deploy_openstack_3NODE.sh — Deploy OpenStack 2025.1 (Epoxy)
#   su nodi iperconvergenti, con OVN, Barbican ed External Ceph.
#   Gira DALL'HOST di deploy. Topologia da lib_topology.sh.
#
#   ORDINE: 00 -> 01 -> 01b -> [ QUESTO ] -> 03
#
#   PRESUPPONE (gate precedenti chiusi [OK]):
#     - 00: rete (bond/VLAN), NTP, egress internet
#     - 01: Docker, Python, Kolla-Ansible su DEPLOY_NODE, inventory
#     - 01b: Ceph HEALTH_OK, keyring in /etc/kolla/config/{glance,cinder,nova}
#
#   Cosa fa:
#     1. genera /etc/kolla/globals.yml  (OVN + Barbican + Ceph, dalla topologia)
#     2. genera gli override: reservation Nova PER RUOLO + path_mtu ml2
#     3. kolla-genpwd (password)
#     4. prechecks
#     5. bootstrap-servers
#     6. ensure_ceph_running  <-- CRITICO: bootstrap-servers riavvia Docker
#     7. pull immagini
#     8. deploy (con retry e pulizia container falliti)
#     9. verifica servizi + Ceph
#
#   USO:
#     sudo bash 02_deploy_openstack_3NODE.sh
#     sudo bash 02_deploy_openstack_3NODE.sh --config-only   # solo globals+override
#     sudo bash 02_deploy_openstack_3NODE.sh --skip-pull     # immagini gia' scaricate
# =============================================================================
set -uo pipefail

# ============================ CONFIG ========================================
source "$(dirname "$0")/lib_topology.sh"
## DAVE
if ! [[ "${VRRP_ROUTER_ID}" =~ ^[0-9]+$ ]] || [ "$VRRP_ROUTER_ID" -lt 1 ] || [ "$VRRP_ROUTER_ID" -gt 255 ]; then
  echo "ERRORE: VRRP_ROUTER_ID deve essere un numero tra 1 e 255 (valore: '${VRRP_ROUTER_ID}'; si imposta in topology.conf)" >&2; exit 1
fi
## DAVE

VENV_PATH="/opt/kolla-venv"
INVENTORY="/etc/kolla/multinode"
OPENSTACK_RELEASE="2025.1"

# --- Nomi interfaccia (sub-interfacce VLAN create dal 00) --------------------
## DAVE - nomi interfaccia dalla topologia (IF_*), non piu' "vlan<ID>" fisso
IFACE_MGMT="${IF_MGMT}"          # network_interface / api_interface
IFACE_TUNNEL="${IF_OVERLAY}"     # tunnel_interface (Geneve)
IFACE_STORAGE="${IF_CEPHPUB}"    # storage_interface (client -> Ceph public)
IFACE_EXTERNAL="${IF_EXT}"       # neutron_external_interface -> br-ex
## DAVE

# --- RESERVATION NOVA (iperconvergenza): protegge Ceph e control plane -------
# Budget RAM per nodo (512 GB):
#   OS+Docker ~8 | OSD 7x4GB = 28 | MON+MGR ~6 | control plane ~64  => ~112 GB
# Un nodo SOLO compute (fase 2/3) non ha control plane: riserva molto meno.
RESERVED_MEM_CONTROL_MB=114688         # 112 GB — nodi che fanno anche control
RESERVED_MEM_COMPUTE_MB=49152          #  48 GB — compute puri (OS + OSD)
RESERVED_CPUS_CONTROL=16               # core sottratti: OSD + control plane
RESERVED_CPUS_COMPUTE=8                # core sottratti: OSD
CPU_ALLOCATION_RATIO="4.0"             # default Nova = 16.0: troppo con Ceph colocato
RAM_ALLOCATION_RATIO="1.0"             # NIENTE overcommit RAM: un OOM ucciderebbe un OSD
DISK_ALLOCATION_RATIO="1.0"            # il disco e' Ceph: non si sovralloca

# --- MTU tenant --------------------------------------------------------------
# Obiettivo: reti tenant Geneve a 1500 netti (allineate all'external), sfruttando
# l'overlay fisico jumbo (VLAN 20 a 9000).
# MECCANICA (imparata sul campo):
#   - MTU tenant Geneve = path_mtu - 58  (overhead Geneve di OVN: 58 byte, non 38).
#   - path_mtu NON puo' superare global_physnet_mtu: se global=1500, path_mtu=1558
#     viene CLAMPATO a 1500 -> tenant 1442. Quindi global va ALZATO a 1558.
#   - ma il provider flat su physnet1 (external, VLAN 30 a 1500) NON deve ereditare
#     1558: lo si cappa a 1500 con physical_network_mtus (override ml2, sotto).
# Risultato: tenant 1558-58=1500, provider 1500. L'overlay a 9000 assorbe i 1558.
NEUTRON_GLOBAL_PHYSNET_MTU=1558        # alzato: permette path_mtu=1558 (overlay jumbo)
NEUTRON_PATH_MTU=1558                  # 1558 - 58 (overhead Geneve OVN) = 1500 tenant
NEUTRON_PHYSNET1_MTU=1500              # cappa il provider physnet1 all'external (VLAN 30)

## DAVE
# --- Barbican ---------------------------------------------------------------
# simple_crypto: la KEK sta in passwords.yml (gestita da Kolla). Adeguato a un lab.
# In PRODUZIONE -> HSM (PKCS#11) o Vault: annotare come debito tecnico.
BARBICAN_CRYPTO_PLUGIN="simple_crypto"
## DAVE

# --- Backend di coordinamento (lock distribuito) ----------------------------
# RICHIESTO da Cinder quando il backend e' Ceph e cinder-volume gira su >1 nodo
# (HA active-active RBD: il nostro caso). Cambia SOLO questa riga per switchare.
#   redis  -> funziona su 2025.1 (Epoxy). Scelta attuale.
#   valkey -> successore di Redis (fork Linux Foundation, niente nodi di licenza
#             Redis). Default dal 2025.2; PREFERIBILE in PRODUZIONE. Per
#             migrare un cluster esistente: 'kolla-ansible migrate-valkey'.
#   etcd   -> terza opzione (piu' pesante).
# NB: sul ferro/prod valuta 'valkey' se la release lo supporta come ruolo.
COORD_BACKEND="redis"     # redis | valkey | etcd

# --- LAB_MODE: adatta al lab con VM annidate --------------------------------
# In lab: reservation minima (le VM hanno poca RAM) e virt_type RILEVATO a runtime
# da detect_virt_type() -> kvm se i compute espongono /dev/kvm (virt annidata),
# altrimenti qemu emulato (lento). NON piu' assunto: si verifica. Sul ferro: kvm.
if [ "${LAB_MODE:-0}" = 1 ]; then
  NOVA_VIRT_TYPE="qemu"          # solo FALLBACK: detect_virt_type() lo alza a kvm se possibile
  RESERVED_MEM_CONTROL_MB=2048; RESERVED_MEM_COMPUTE_MB=1024
  RESERVED_CPUS_CONTROL=1;      RESERVED_CPUS_COMPUTE=1
  RAM_ALLOCATION_RATIO="1.5"    # un po' di overcommit per far stare le VM di test
else
  NOVA_VIRT_TYPE="kvm"
fi
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}=== $* ===${NC}"; }
log_ok()    { echo -e "  ${GREEN}[OK]${NC} $*"; }
log_fail()  { echo -e "  ${RED}[FAIL]${NC} $*"; }

DO_PULL=1; CONFIG_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --skip-pull)  DO_PULL=0 ;;
    --config-only) CONFIG_ONLY=1 ;;
    --help|-h)    sed -n '2,32p' "$0"; exit 0 ;;
    *) log_error "Opzione sconosciuta: $arg"; exit 1 ;;
  esac
done

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=30)
ssh_dep()  { ssh "${SSH_OPTS[@]}" -i "$DEPLOY_KEY" "root@${DEPLOY_NODE_IP}" "$@"; }
ssh_node() { local ip="$1"; shift; ssh "${SSH_OPTS[@]}" -i "$DEPLOY_KEY" "root@${ip}" "$@"; }

_in_list() { local x="$1"; shift; for e in "$@"; do [ "$e" = "$x" ] && return 0; done; return 1; }

# ------------------------- 0. Precheck --------------------------------------
# rileva la virt annidata in lab: se i compute hanno /dev/kvm, Nova usa kvm
# (veloce) invece di qemu emulato. Sul ferro (non-LAB) resta kvm senza check.
detect_virt_type() {
  [ "${LAB_MODE:-0}" = 1 ] || return 0
  local n="${COMPUTE_NODES[0]}"
  if ssh_node "$(mgmt_ip "$n")" "test -e /dev/kvm" >/dev/null 2>&1; then
    NOVA_VIRT_TYPE="kvm"
    log_ok "virt annidata rilevata (/dev/kvm sui compute) -> Nova virt_type=kvm (accelerato)"
  else
    NOVA_VIRT_TYPE="qemu"
    log_warn "nessun /dev/kvm sui compute -> virt_type=qemu (emulato, LENTO)."
    log_warn "  per accelerare: sull'host 'echo options kvm_amd nested=1 > /etc/modprobe.d/kvm-nested.conf' + reload modulo + ricrea le VM."
  fi
}
precheck() {
  log_step "Precheck (00/01/01b devono aver chiuso [OK])"
  ssh_dep true >/dev/null 2>&1 || { log_error "${DEPLOY_NODE} (${DEPLOY_NODE_IP}) irraggiungibile. Esegui 00/01."; exit 1; }
  ssh_dep "test -f ${INVENTORY}" || { log_error "inventory ${INVENTORY} assente: esegui il 01."; exit 1; }
  ssh_dep "test -d ${VENV_PATH}" || { log_error "venv Kolla assente: esegui il 01."; exit 1; }

  # Ceph deve essere sano PRIMA di partire: senza, Glance/Cinder/Nova falliranno
  local health; health="$(ssh_dep "ceph health 2>/dev/null" || echo "")"
  case "$health" in
    HEALTH_OK*)   log_ok "Ceph: ${health}" ;;
    HEALTH_WARN*) log_warn "Ceph: ${health} — accettabile se transitorio sui PG" ;;
    *)            log_error "Ceph non sano o non raggiungibile ('${health}'). Esegui/verifica il 01b."; exit 1 ;;
  esac
  # keyring generati dal 01b
  ssh_dep "test -f /etc/kolla/config/glance/ceph.client.glance.keyring && \
           test -f /etc/kolla/config/cinder/cinder-volume/ceph.client.cinder.keyring && \
           test -f /etc/kolla/config/nova/ceph.client.nova.keyring" \
    || { log_error "keyring Ceph mancanti in /etc/kolla/config: rilancia il 01b."; exit 1; }
  log_ok "keyring Ceph presenti"
}

# ------------------------- 1. globals.yml -----------------------------------
## DAVE
# Masakari lo abilita SOLO il 04 (che prima adatta l'inventory). Il 02 rigenera il
# globals da zero: senza questa funzione un rilancio del 02 spegnerebbe
# enable_masakari. Qui si CONSERVA il valore gia' presente; la prima volta e' "no".
# (Volutamente nessuna variabile d'ambiente che lo forzi a "yes": con l'inventory
# non ancora adattato il deploy fallirebbe.)
masakari_flag() {
  if ssh_dep "grep -Eq '^enable_masakari: *\"yes\"' /etc/kolla/globals.yml" </dev/null 2>/dev/null; then
    echo yes
  else
    echo no
  fi
}
## DAVE

## DAVE
# Octavia (provider OVN) lo abilita SOLO il 06_octavia.sh, a cloud sano. Come per
# Masakari il 02 CONSERVA il valore gia' presente nel globals; la prima volta e' "no".
octavia_flag() {
  if ssh_dep "grep -Eq '^enable_octavia: *\"yes\"' /etc/kolla/globals.yml" </dev/null 2>/dev/null; then
    echo yes
  else
    echo no
  fi
}
## DAVE

generate_globals() {
  log_step "Generazione /etc/kolla/globals.yml (OVN + Barbican + External Ceph)"
  ## DAVE
  local MASAKARI_YN; MASAKARI_YN="$(masakari_flag)"
  # Skyline (dashboard): attivo di default; ENABLE_SKYLINE=no per spegnerlo.
  local SKYLINE_YN="${ENABLE_SKYLINE:-yes}"
  case "$SKYLINE_YN" in yes|no) ;; *) log_warn "ENABLE_SKYLINE='${SKYLINE_YN}' non valido: uso yes"; SKYLINE_YN=yes ;; esac
  [ "$MASAKARI_YN" = yes ] && log_info "enable_masakari: yes conservato (gestito dal 04)"
  local OCTAVIA_YN; OCTAVIA_YN="$(octavia_flag)"
  [ "$OCTAVIA_YN" = yes ] && log_info "enable_octavia: yes conservato (gestito dal 06)"
  ## DAVE
  ## DAVE - NTP_LOCAL_MASTER: il nodo master usa chrony con 'local stratum' (nessuna sorgente esterna), quindi
  ## timedatectl lo dichiara "non sincronizzato" anche se gli altri nodi seguono lui. Il precheck NTP di Kolla
  ## fallirebbe su quel nodo: in questa modalita' (e solo in questa) lo si disattiva. La sincronia fra i nodi
  ## e' verificata dal 00 (offset chrony e scarto compensato).
  local NTP_PRECHECK_BLOCK=""
  if [ -n "${NTP_LOCAL_MASTER:-}" ]; then
    NTP_PRECHECK_BLOCK='# NTP_LOCAL_MASTER attivo: il master usa solo il proprio orologio, timedatectl lo vede non sincronizzato.
prechecks_enable_host_ntp_checks: "false"'
    log_info "NTP_LOCAL_MASTER=${NTP_LOCAL_MASTER}: precheck NTP di Kolla disattivato (nessun NTP esterno)"
  fi
  ## DAVE
  ssh_dep "cat > /etc/kolla/globals.yml" << EOF
---
# =============================================================================
# Kolla-Ansible globals.yml — OpenStack ${OPENSTACK_RELEASE} (Epoxy)
# GENERATO da 02_deploy_openstack_3NODE.sh — non modificare a mano.
# Topologia: ${#ALL_NODES[@]} nodi | control=${#CONTROL_NODES[@]} compute=${#COMPUTE_NODES[@]} storage=${#STORAGE_NODES[@]}
# =============================================================================

kolla_base_distro: "ubuntu"
openstack_release: "${OPENSTACK_RELEASE}"
# NB: 'kolla_install_type' non e' piu' significativo: dal ciclo Zed esistono solo
# immagini "source" e il tag ha perso il suffisso di tipo. Volutamente omesso.

docker_registry: "quay.io"
docker_namespace: "openstack.kolla"
${NTP_PRECHECK_BLOCK}

###############################################################################
# Rete — sub-interfacce VLAN create dal 00 sui due bond LACP
#   bond0 -> ${IFACE_MGMT} (mgmt/API) | ${IFACE_TUNNEL} (overlay) | ${IFACE_EXTERNAL} (external)
#   bond1 -> ${IFACE_STORAGE} (Ceph public)
###############################################################################

network_interface: "${IFACE_MGMT}"
api_interface: "{{ network_interface }}"
tunnel_interface: "${IFACE_TUNNEL}"
# storage_interface = rete con cui i servizi OpenStack parlano a Ceph (public).
# La rete CLUSTER di Ceph (VLAN ${VLAN_CEPHCLU}) e' nota solo a cephadm: Kolla non la usa.
storage_interface: "${IFACE_STORAGE}"
# Interfaccia SENZA IP host: viene inglobata in br-ex da Neutron/OVN.
neutron_external_interface: "${IFACE_EXTERNAL}"

kolla_internal_vip_address: "${VIP}"
keepalived_virtual_router_id: "${VRRP_ROUTER_ID}"

enable_haproxy: "yes"
enable_keepalived: "{{ enable_haproxy | bool }}"
haproxy_max_connections: 40000

###############################################################################
# Servizi core in scope
###############################################################################

enable_openstack_core: "yes"     # keystone, glance, nova, neutron, heat, horizon
enable_keystone: "yes"
enable_glance: "yes"
enable_nova: "yes"
enable_neutron: "yes"
enable_placement: "yes"
enable_cinder: "yes"
enable_heat: "yes"
enable_horizon: "yes"
## DAVE
enable_barbican: "yes"
# Skyline: dashboard (richiesta dell'infrastruttura). Horizon resta attivo. Console su VIP:9999, API su VIP:9998.
# Servono DB 'skyline' e utente Keystone 'skyline': li crea il deploy (password da kolla-genpwd).
enable_skyline: "${SKYLINE_YN}"
## DAVE

# Fuori scope
enable_magnum: "no"              # nessun cluster Kubernetes previsto
## DAVE
# enable_octavia: non piu' fuori scope, vedi il blocco Octavia piu' sotto (06_octavia.sh)
## DAVE
enable_designate: "no"
enable_manila: "no"
enable_trove: "no"
## DAVE
enable_masakari: "${MASAKARI_YN}"   # abilitato dal 04_masakari.sh; il 02 non lo spegne
## DAVE
## DAVE
# Octavia (LBaaS) solo con provider OVN: bilanciamento L4 distribuito in OVN, senza
# amphora. Niente lb-mgmt-net, immagine, flavor, certificati ne' jobboard: Kolla
# ricava octavia_auto_configure e i controlli sui certificati dalla presenza di
# 'amphora' nei driver. Le due chiavi provider restano scritte anche con Octavia
# spento, cosi' un'accensione a mano non attiva le amphora di default.
# Il provider di default (ovn) sta nell'override /etc/kolla/config/octavia.conf (06).
enable_octavia: "${OCTAVIA_YN}"     # abilitato dal 06_octavia.sh; il 02 non lo spegne
octavia_provider_drivers: "ovn:OVN provider"
octavia_provider_agents: "ovn"
## DAVE
enable_ironic: "no"

###############################################################################
# Neutron — OVN (niente piu' agent L3/DHCP: ovn-northd + ovn-controller)
###############################################################################

neutron_plugin_agent: "ovn"

# Provider network FLAT su physnet1: il tag VLAN ${VLAN_EXT} lo toglie gia' la
# sub-interfaccia Linux ${IFACE_EXTERNAL}, quindi a Neutron arriva traffico untagged.
enable_neutron_provider_networks: "yes"
neutron_bridge_name: "br-ex"
neutron_physical_networks: "physnet1"

# Floating IP distribuiti: il traffico N-S esce dal nodo che ospita la VM invece
# di transitare tutto dai gateway node. Con OVN e' il comportamento consigliato.
neutron_ovn_distributed_fip: "yes"

# MTU: valore dichiarativo (documenta l'intento); l'applicazione REALE a
# neutron.conf avviene via override esplicito in generate_neutron_override()
# (/etc/kolla/config/neutron.conf) — su Kolla 2025.1 questa chiave del globals
# NON risulta propagata automaticamente al container (verificato empiricamente:
# 'kolla-ansible reconfigure --tags neutron' non la scrive in neutron.conf).
neutron_global_physnet_mtu: ${NEUTRON_GLOBAL_PHYSNET_MTU}

###############################################################################
# Storage — External Ceph (RBD). Pool e keyring creati dal 01b.
###############################################################################

# Glance
glance_backend_ceph: "yes"
glance_backend_file: "no"
ceph_glance_user: "glance"
ceph_glance_pool_name: "images"

# Cinder
cinder_backend_ceph: "yes"
enable_cinder_backend_lvm: "no"
ceph_cinder_user: "cinder"
ceph_cinder_pool_name: "volumes"
# HA active-active: con piu' cinder-volume (il nostro caso, [storage]=tutti i nodi)
# Kolla vuole un nome di cluster che li raggruppi. Insieme al coordinatore
# (${COORD_BACKEND}) e' il secondo requisito dell'RBD active-active. Nome libero
# ma stabile: NON cambiarlo dopo il deploy (i volumi restano associati al cluster).
cinder_cluster_name: "os-ceph"
# Backup su Ceph (pool 'backups' gia' creato dal 01b)
enable_cinder_backup: "yes"
cinder_backup_driver: "ceph"
ceph_cinder_backup_user: "cinder-backup"
ceph_cinder_backup_pool_name: "backups"

# Nova (dischi effimeri su RBD -> live migration senza storage locale)
nova_backend_ceph: "yes"
ceph_nova_user: "nova"
ceph_nova_pool_name: "vms"

external_ceph_cephx_enabled: "yes"

###############################################################################
# Compute — Nova
###############################################################################

# Sul ferro: virtualizzazione hardware vera. In LAB_MODE (VM annidate): qemu.
nova_compute_virt_type: "${NOVA_VIRT_TYPE}"
# Le reservation (memoria/CPU) sono in /etc/kolla/config/nova/<host>/nova.conf,
# differenziate per ruolo: vedi 02, funzione generate_nova_reservation.

###############################################################################
# Control plane HA
###############################################################################

enable_mariadb: "yes"            # Galera su ${#CONTROL_NODES[@]} nodi
enable_rabbitmq: "yes"           # cluster su ${#CONTROL_NODES[@]} nodi
enable_memcached: "yes"

# Coordinamento (lock distribuito) — RICHIESTO da Cinder quando il backend e'
# Ceph E cinder-volume gira su >1 nodo (HA active-active RBD, il nostro caso:
# [storage] = tutti i ${#STORAGE_NODES[@]} nodi). Senza, il precheck fallisce con
# "Please enable valkey or redis or etcd". Backend scelto: ${COORD_BACKEND}.
# NB: il lab a 6 nodi non lo richiedeva perche' aveva un solo cinder-volume.
enable_${COORD_BACKEND}: "yes"
cinder_coordination_backend: "${COORD_BACKEND}"

###############################################################################
# TLS — DISABILITATO in lab.
# DEBITO TECNICO per la produzione: abilitare almeno kolla_enable_tls_external
# (e internal) con certificati dell'infrastruttura prima dell'esercizio.
###############################################################################

kolla_enable_tls_internal: "no"
kolla_enable_tls_external: "no"

###############################################################################
## DAVE
# Barbican
###############################################################################

# simple_crypto: KEK gestita da Kolla (passwords.yml). Adeguato a un lab.
# PRODUZIONE: p11_crypto con HSM, oppure backend Vault.
barbican_crypto_plugin: "${BARBICAN_CRYPTO_PLUGIN}"
## DAVE

###############################################################################
# Logging
###############################################################################

openstack_logging_debug: "False"
EOF
  log_ok "globals.yml generato"
}

# ------------------------- 2a. Reservation Nova per ruolo -------------------
# Kolla legge /etc/kolla/config/nova/<inventory_hostname>/nova.conf e lo fonde
# nella config del nodo: e' il modo pulito per differenziare per ruolo.
generate_nova_reservation() {
  log_step "Reservation Nova per ruolo (protegge OSD e control plane)"
  local n role mem cpus totmb totcpu
  for n in "${COMPUTE_NODES[@]}"; do
    if _in_list "$n" "${CONTROL_NODES[@]}"; then
      role="control+compute+storage"; mem=$RESERVED_MEM_CONTROL_MB; cpus=$RESERVED_CPUS_CONTROL
    else
      role="compute+storage";          mem=$RESERVED_MEM_COMPUTE_MB;  cpus=$RESERVED_CPUS_COMPUTE
    fi
    # CLAMP: la reservation non deve MAI superare le risorse reali del nodo,
    # altrimenti Nova calcola disponibilita' negativa e NON pubblica l'inventory
    # a Placement -> lo scheduler non trova host -> NoValidHost. Leggo RAM/CPU
    # reali a runtime e limito la reservation a una frazione sicura (lascio
    # almeno ~2GB e 1 CPU alle VM). Cosi' e' robusto anche se LAB_MODE non
    # propaga o se il nodo ha meno RAM del previsto.
    totmb="$(ssh_node "$(mgmt_ip "$n")" "awk '/MemTotal/{print int(\$2/1024)}' /proc/meminfo" 2>/dev/null || echo 0)"
    totcpu="$(ssh_node "$(mgmt_ip "$n")" "nproc" 2>/dev/null || echo 0)"
    if [ "${totmb:-0}" -gt 0 ] && [ "$mem" -ge "$((totmb - 2048))" ]; then
      local newmem=$(( totmb > 4096 ? totmb - 2048 : totmb / 2 ))
      log_warn "  ${n}: reservation ${mem}MB >= RAM reale ${totmb}MB — riduco a ${newmem}MB (lascio spazio alle VM)"
      mem=$newmem
    fi
    if [ "${totcpu:-0}" -gt 0 ] && [ "$cpus" -ge "$totcpu" ]; then
      local newcpu=$(( totcpu > 2 ? totcpu - 1 : 1 ))
      log_warn "  ${n}: reserved_host_cpus ${cpus} >= CPU reali ${totcpu} — riduco a ${newcpu}"
      cpus=$newcpu
    fi
    ssh_dep "mkdir -p /etc/kolla/config/nova/${n} && cat > /etc/kolla/config/nova/${n}/nova.conf" << EOF
# Nodo ${n} — ruolo: ${role}
# GENERATO da 02_deploy_openstack_3NODE.sh (reservation clampata alla RAM reale)
[DEFAULT]
# RAM sottratta alle VM: OS+Docker, OSD Ceph, MON/MGR$( _in_list "$n" "${CONTROL_NODES[@]}" && echo ", control plane" ).
reserved_host_memory_mb = ${mem}
reserved_host_cpus = ${cpus}

[compute]
ram_allocation_ratio = ${RAM_ALLOCATION_RATIO}
cpu_allocation_ratio = ${CPU_ALLOCATION_RATIO}
disk_allocation_ratio = ${DISK_ALLOCATION_RATIO}
EOF
    log_ok "${n}: riservati $((mem/1024)) GB RAM, ${cpus} CPU (${role})"
  done
}

# ------------------------- 2b. Override ml2 (MTU tenant) --------------------
generate_neutron_override() {
  log_step "Override Neutron (neutron.conf: global_physnet_mtu; ml2: path_mtu)"
  # CRITICO: 'neutron_global_physnet_mtu' nel globals.yml NON risulta propagata
  # a neutron.conf da Kolla 2025.1 (verificato: ne' al deploy ne' con un
  # 'reconfigure --tags neutron' dedicato). Senza global_physnet_mtu=1558 in
  # neutron.conf, path_mtu (ml2) viene clampato al default 1500 -> tenant 1442.
  # Va scritto come override esplicito, che Kolla fonde sempre nel container.
  ssh_dep "cat > /etc/kolla/config/neutron.conf" << EOF
# GENERATO da 02_deploy_openstack_3NODE.sh
[DEFAULT]
global_physnet_mtu = ${NEUTRON_GLOBAL_PHYSNET_MTU}
EOF
  ssh_dep "mkdir -p /etc/kolla/config/neutron && cat > /etc/kolla/config/neutron/ml2_conf.ini" << EOF
# GENERATO da 02_deploy_openstack_3NODE.sh
[ml2]
# Reti tenant Geneve: MTU = path_mtu - 58 (overhead Geneve OVN) = 1500 netti.
# path_mtu (${NEUTRON_PATH_MTU}) <= global_physnet_mtu (${NEUTRON_GLOBAL_PHYSNET_MTU}), altrimenti clampa.
# L'overlay fisico (VLAN ${VLAN_OVERLAY}) e' a 9000 e assorbe i ${NEUTRON_PATH_MTU} byte incapsulati.
path_mtu = ${NEUTRON_PATH_MTU}
# Cappa il provider su physnet1 alla MTU reale dell'external (VLAN ${VLAN_EXT} = 1500),
# cosi' NON eredita i ${NEUTRON_GLOBAL_PHYSNET_MTU} del global.
physical_network_mtus = physnet1:${NEUTRON_PHYSNET1_MTU}
# VERIFICA dopo il deploy:
#   openstack network show <tenant-net> -c mtu   -> ${NEUTRON_PHYSNET1_MTU} (Geneve)
#   openstack network show provider-ext -c mtu   -> ${NEUTRON_PHYSNET1_MTU} (flat)
EOF
  log_ok "neutron.conf: global_physnet_mtu=${NEUTRON_GLOBAL_PHYSNET_MTU}; ml2: path_mtu=${NEUTRON_PATH_MTU} -> tenant ${NEUTRON_PHYSNET1_MTU}"
}

# ------------------------- 3. Password --------------------------------------
generate_passwords() {
  log_step "Generazione password (kolla-genpwd)"
  ssh_dep bash << 'ENDSSH'
set -e
source /opt/kolla-venv/bin/activate
# idempotente: non rigenerare se le password sono gia' popolate (romperebbe
# un cluster gia' deployato)
if grep -qE '^keystone_admin_password:\s*\S' /etc/kolla/passwords.yml 2>/dev/null; then
  echo "password gia' generate, skip"
else
  kolla-genpwd
fi
admin_pass=$(awk '/^keystone_admin_password:/{print $2}' /etc/kolla/passwords.yml)
echo "$admin_pass" > /root/admin-openrc-password.txt
chmod 600 /root/admin-openrc-password.txt
echo "[OK] password pronte"
ENDSSH
  log_ok "password in /etc/kolla/passwords.yml (admin in /root/admin-openrc-password.txt)"
}

# ------------------------- 4. Prechecks -------------------------------------
run_prechecks() {
  log_step "Prechecks Kolla"
  local out rc
  out="$(ssh_dep "source ${VENV_PATH}/bin/activate; kolla-ansible prechecks -i ${INVENTORY} --configdir /etc/kolla" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log_fail "prechecks falliti. Task/messaggio che ha fallito davvero:"
    # estrai il messaggio reale del fatal (non indovinare dai nomi delle task,
    # che compaiono nell'output anche quando passano)
    echo "$out" | grep -iE "fatal:|FAILED!" | sed 's/^/      >> /' | head -5
    echo "$out" | tail -20 | sed 's/^/      | /'
    # hint SOLO se il fatale (non una task elencata) parla di coordinamento
    if echo "$out" | grep -iE "fatal:|FAILED!" | grep -qi "coordination\|valkey\|redis\|etcd"; then
      log_fail "  -> Cinder+Ceph in HA: manca il coordinatore. Verifica enable_${COORD_BACKEND} e cinder_coordination_backend nel globals."
    fi
    exit 1
  fi
  log_ok "prechecks superati"
}

# ------------------------- 5. Bootstrap servers -----------------------------
run_bootstrap() {
  log_step "bootstrap-servers (riconfigura Docker sui nodi)"
  ssh_dep "source ${VENV_PATH}/bin/activate; kolla-ansible bootstrap-servers -i ${INVENTORY} --configdir /etc/kolla" \
    || { log_error "bootstrap-servers fallito"; exit 1; }
  log_ok "bootstrap-servers completato"
}

# ------------------------- 6. SAFEGUARD Ceph --------------------------------
# 'bootstrap-servers' RIAVVIA il daemon Docker. I daemon Ceph di cephadm sono
# container ma supervisionati da systemd: dopo quel riavvio possono restare
# spenti (o ri-scaricare l'immagine). Se Ceph e' giu' qui, Glance/Cinder/Nova
# falliranno nel deploy. Li risolleviamo e verifichiamo PRIMA di proseguire.
ensure_ceph_running() {
  log_step "Verifica/ripristino Ceph dopo bootstrap-servers"
  # NB: dopo il riavvio di Docker le ISTANZE cephadm (mon/mgr/osd, systemd)
  # muoiono, ma 'ceph.target' resta 'active' -> 'systemctl start ceph.target' e'
  # un no-op e NON le rialza. Bisogna far ripartire le singole unit ceph-*@*.
  # reset-failed sblocca anche l'eventuale start-limit.
  local kick="systemctl reset-failed 'ceph-*' 2>/dev/null; \
systemctl list-units 'ceph-*@*' --all --no-legend | grep -oE 'ceph-[^ ]+@[^ ]+[.]service' | xargs -r -n1 systemctl start 2>/dev/null; true"
  local n
  for n in "${ALL_NODES[@]}"; do
    ssh_node "$(mgmt_ip "$n")" "$kick" >/dev/null 2>&1 && log_info "  daemon Ceph risollecitati su ${n}"
  done

  log_info "Attendo che il MON risponda (sotto qemu puo' essere lento)..."
  local i health
  for i in $(seq 1 45); do   # ~11 min: copre ri-pull immagine + MON lento a rispondere
    health="$(ssh_dep "timeout 30 ceph health 2>/dev/null" || echo "")"
    case "$health" in HEALTH_OK*|HEALTH_WARN*) break ;; esac
    # ogni 5 giri ri-solletica le istanze (Docker potrebbe non essere stato pronto al 1o giro)
    if [ $(( i % 5 )) -eq 0 ]; then
      for n in "${ALL_NODES[@]}"; do ssh_node "$(mgmt_ip "$n")" "$kick" >/dev/null 2>&1 || true; done
    fi
    sleep 15
  done
  case "$health" in
    HEALTH_OK*)   log_ok "Ceph operativo: ${health}" ;;
    HEALTH_WARN*) log_warn "Ceph: ${health} (procedo: WARN sui PG e' tollerabile)" ;;
    *)            log_error "Ceph non risponde dopo bootstrap-servers ('${health}')."
                  log_error "Il MON e' 'inactive dead'? Da un altro terminale, sui nodi:"
                  log_error "  systemctl list-units 'ceph-*@*' --all | grep -oE 'ceph-[^ ]+@[^ ]+[.]service' | xargs -r -n1 systemctl start"
                  exit 1 ;;
  esac
}

# ------------------------- 7. Pull immagini ---------------------------------
run_pull() {
  [ "$DO_PULL" = 0 ] && { log_warn "pull saltato (--skip-pull)"; return 0; }
  log_step "Pull immagini container (15-30 min, diversi GB)"
  ssh_dep "source ${VENV_PATH}/bin/activate; kolla-ansible pull -i ${INVENTORY} --configdir /etc/kolla" \
    || { log_error "pull fallito — egress verso quay.io? (00 --verify-only)"; exit 1; }
  log_ok "pull completato"
}

# ------------------------- 8. Deploy ----------------------------------------
cleanup_failed_containers() {
  log_info "Pulizia container falliti sui nodi control (mariadb/rabbitmq)..."
  local n
  for n in "${CONTROL_NODES[@]}"; do
    ssh_node "$(mgmt_ip "$n")" bash << 'ENDSSH' >/dev/null 2>&1 || true
if docker ps -a --format "{{.Names}}\t{{.Status}}" | grep -qE "^mariadb\s+Created"; then
  docker rm mariadb 2>/dev/null || true
fi
if docker ps -a --format "{{.Names}}\t{{.Status}}" | grep -qE "^rabbitmq\s+Exited"; then
  docker rm -f rabbitmq 2>/dev/null || true
  docker volume rm rabbitmq 2>/dev/null || true
fi
ENDSSH
  done
}

# SAFEGUARD RabbitMQ: il cold-start del cluster RabbitMQ 4.x sotto Kolla puo'
# andare in DEADLOCK. Kolla riavvia i nodi in modo SERIALE: parte node01 e lo
# aspetta 'healthy' PRIMA di toccare gli altri; ma con peer_discovery
# 'classic_config' node01 (virgin) aspetta i peer che non sono ancora partiti
# -> resta unhealthy per sempre, gli altri non vengono mai creati. Sintomo:
# solo il container rabbit del PRIMO control esiste, ed e' 'unhealthy'.
# Cura (deterministica): azzerare i volumi rabbit su TUTTI i control e
# ridispiegarli in un'unica passata -> partono insieme, virgin, e il peer
# discovery li fa vedere a vicenda. NB: reale anche sul ferro al primo deploy.
ensure_rabbitmq_cluster() {
  log_step "Verifica/ripristino cluster RabbitMQ"
  local nctrl=${#CONTROL_NODES[@]} running
  # quanti rabbit@ risultano nel cluster (dal primo control che risponde)
  running="$(ssh_dep "docker exec rabbitmq rabbitmqctl cluster_status --formatter json 2>/dev/null | grep -oE 'rabbit@[a-z0-9]+' | sort -u | wc -l" 2>/dev/null || echo 0)"
  if [ "${running:-0}" -ge "$nctrl" ]; then
    log_ok "RabbitMQ: cluster a ${running}/${nctrl} nodi gia' formato"
    return 0
  fi
  log_warn "RabbitMQ: solo ${running:-0}/${nctrl} nodi nel cluster — applico la cura (reset volumi + redeploy insieme)"
  local n
  for n in "${CONTROL_NODES[@]}"; do
    ssh_node "$(mgmt_ip "$n")" "docker rm -f rabbitmq 2>/dev/null; docker volume rm rabbitmq 2>/dev/null; true" >/dev/null 2>&1 \
      && log_info "  ${n}: container+volume rabbit azzerati"
  done
  log_info "Redeploy RabbitMQ (common+haproxy+rabbitmq, tutti i control insieme, timeout 15 min)..."
  # CRITICO: il redeploy DEVE includere 'common' e 'haproxy', non solo 'rabbitmq':
  #  - 'common' crea /etc/kolla/haproxy/services.d (senza cui haproxy-config fallisce)
  #    e rigenera la lista peer cluster_formation.classic_config.nodes in rabbitmq.conf;
  #  - con solo '--tags rabbitmq' la config esce SENZA i peer -> ogni nodo resta
  #    'virgin' e il cluster non si forma. Con common+haproxy la config e' completa.
  if ssh_dep "source ${VENV_PATH}/bin/activate; timeout 900 kolla-ansible deploy -i ${INVENTORY} --configdir /etc/kolla --tags common,haproxy,rabbitmq" >/dev/null 2>&1; then
    log_ok "redeploy RabbitMQ completato"
  else
    log_warn "redeploy RabbitMQ interrotto/timeout, verifico lo stato comunque"
  fi
  # attendi la formazione del cluster
  local i
  for i in $(seq 1 24); do   # ~4 min
    running="$(ssh_dep "docker exec rabbitmq rabbitmqctl cluster_status --formatter json 2>/dev/null | grep -oE 'rabbit@[a-z0-9]+' | sort -u | wc -l" 2>/dev/null || echo 0)"
    [ "${running:-0}" -ge "$nctrl" ] && break
    sleep 10
  done
  if [ "${running:-0}" -ge "$nctrl" ]; then
    log_ok "RabbitMQ: cluster a ${running}/${nctrl} nodi formato"
  else
    log_error "RabbitMQ non ha formato il cluster (${running:-0}/${nctrl})."
    log_error "  Da un altro terminale, azzera i volumi sui control e rilancia:"
    log_error "    docker rm -f rabbitmq; docker volume rm rabbitmq   (su ogni control)"
    log_error "    kolla-ansible deploy -i ${INVENTORY} --configdir /etc/kolla --tags common,haproxy,rabbitmq"
    exit 1
  fi
}

# SAFEGUARD OVN: i chassis OVN devono registrarsi col nome CORTO (node01), lo
# stesso che usa Nova come binding:host_id. Se il nodo risolve un FQDN (l'alias
# in /etc/hosts fa restituire 'node01.openstack.local' a hostname -f), ovn-controller
# registra il chassis col FQDN -> il binding porta fallisce con "no OVN chassis
# for host: node01" e nessuna VM parte. Forziamo external_ids:hostname al nome
# corto su OGNI nodo e riavviamo ovn_controller. Fix provato sul campo.
ensure_ovn_chassis_shortname() {
  log_step "Allineamento chassis OVN al nome corto (evita PortBindingFailed)"
  local n changed=0
  for n in "${ALL_NODES[@]}"; do
    if ssh_node "$(mgmt_ip "$n")" bash -s <<'ENDSSH' >/dev/null 2>&1
s="$(hostname -s)"
cur="$(docker exec openvswitch_vswitchd ovs-vsctl get open . external_ids:hostname 2>/dev/null | tr -d '\"')"
if [ "$cur" != "$s" ]; then
  docker exec openvswitch_vswitchd ovs-vsctl set open . external_ids:hostname="$s" 2>/dev/null
  docker restart ovn_controller >/dev/null 2>&1
fi
ENDSSH
    then log_info "  ${n}: chassis allineato al nome corto"; changed=$((changed+1)); fi
  done
  # attendo la ri-registrazione e verifico che nessun chassis sia FQDN
  sleep 15
  local fqdn
  fqdn="$(ssh_dep "docker exec ovn_sb_db ovn-sbctl --columns=hostname list Chassis 2>/dev/null | grep -c '[.]'" 2>/dev/null || echo 0)"
  if [ "${fqdn:-0}" -eq 0 ]; then
    log_ok "chassis OVN tutti col nome corto"
  else
    log_warn "alcuni chassis risultano ancora FQDN (${fqdn}) — verifica 'ovn-sbctl list Chassis'"
  fi
}

run_deploy() {
  log_step "Deploy OpenStack (30-60 min)"
  local log_file="/var/log/kolla-deploy-os-$(date +%Y%m%d-%H%M%S).log"
  log_info "  log sul nodo: ${log_file}"
  log_info "  da un altro terminale:  ssh -i ${DEPLOY_KEY} root@${DEPLOY_NODE_IP} 'tail -f ${log_file}'"

  local res
  res="$(ssh_dep "bash -s" << ENDSSH
source ${VENV_PATH}/bin/activate
kolla-ansible deploy -i ${INVENTORY} --configdir /etc/kolla > ${log_file} 2>&1
echo "KOLLA_EXIT=\$?"
ENDSSH
)"
  echo "$res"
  if echo "$res" | grep -q "KOLLA_EXIT=0"; then
    log_ok "deploy completato al primo tentativo"
    return 0
  fi

  log_warn "deploy fallito: pulizia e retry..."
  ssh_dep "tail -30 ${log_file}" | sed 's/^/      | /'
  cleanup_failed_containers
  local retry_log="/var/log/kolla-deploy-os-retry-$(date +%Y%m%d-%H%M%S).log"
  res="$(ssh_dep "bash -s" << ENDSSH
source ${VENV_PATH}/bin/activate
kolla-ansible deploy -i ${INVENTORY} --configdir /etc/kolla > ${retry_log} 2>&1
echo "KOLLA_EXIT=\$?"
ENDSSH
)"
  if echo "$res" | grep -q "KOLLA_EXIT=0"; then
    log_ok "deploy completato al secondo tentativo"
  else
    log_fail "deploy fallito anche al retry. Ultime righe:"
    ssh_dep "tail -40 ${retry_log}" | sed 's/^/      | /'
    log_fail "  RabbitMQ bloccato su 'Waiting for rabbitmq to start'? Da un altro terminale:"
    log_fail "    kolla-ansible deploy -i ${INVENTORY} --tags common,haproxy,rabbitmq --limit '<control>'"
    exit 1
  fi
}

# ------------------------- 9. Verifica --------------------------------------
verify() {
  log_step "Verifica post-deploy"
  ssh_dep bash << 'ENDSSH'
source /opt/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh 2>/dev/null || true

echo "--- MariaDB Galera (atteso: cluster_size = n. control) ---"
DBPASS=$(awk '/^database_password:/{print $2}' /etc/kolla/passwords.yml)
docker exec mariadb mysql -uroot -p"$DBPASS" -e "SHOW STATUS LIKE 'wsrep_cluster_size'" 2>/dev/null || echo "  mariadb non pronto"

echo ""
echo "--- RabbitMQ ---"
docker exec rabbitmq rabbitmqctl cluster_status 2>/dev/null | grep -iA4 "running nodes" || echo "  rabbitmq non pronto"

echo ""
echo "--- OVN (northd + controller) ---"
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E "ovn" || echo "  nessun container OVN"

echo ""
echo "--- VIP Keepalived ---"
ip -o addr show | grep -q "$(awk '/^kolla_internal_vip_address:/{gsub(/"/,"",$2); print $2}' /etc/kolla/globals.yml)" \
  && echo "  VIP attivo su questo nodo" || echo "  VIP su un altro nodo (normale)"

echo ""
echo "--- Ceph ---"
ceph health 2>/dev/null || echo "  ceph non raggiungibile"

## DAVE
if grep -Eq '^enable_skyline: *"yes"' /etc/kolla/globals.yml; then
  echo ""
  echo "--- Skyline ---"
  VIPA=$(awk '/^kolla_internal_vip_address:/{gsub(/"/,"",$2); print $2}' /etc/kolla/globals.yml)
  docker ps --format '{{.Names}}\t{{.Status}}' | grep -E "skyline" || echo "  [WARN] nessun container skyline su questo nodo"
  code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "http://${VIPA}:9999/" 2>/dev/null)
  case "$code" in 200|301|302) echo "  [OK] console risponde su http://${VIPA}:9999 (HTTP $code)" ;;
                  *) echo "  [WARN] console non risponde su http://${VIPA}:9999 (HTTP ${code:-nessuna risposta})" ;; esac
fi
## DAVE
ENDSSH

  # servizi OpenStack (richiede openrc, generato da post-deploy nel 03; qui best effort)
  local svc
  svc="$(ssh_dep "source ${VENV_PATH}/bin/activate; source /etc/kolla/admin-openrc.sh 2>/dev/null && openstack service list -f value -c Name 2>/dev/null" || echo "")"
  if [ -n "$svc" ]; then
    echo ""
    log_info "Servizi registrati: $(echo "$svc" | tr '\n' ' ')"
    local missing=""
    for s in keystone glance nova neutron cinderv3 placement barbican; do
      echo "$svc" | grep -qi "^${s}$" || missing+="$s "
    done
    [ -n "$missing" ] && log_warn "non ancora visibili: ${missing}(il 03 esegue post-deploy e li rende interrogabili)"
  else
    log_info "openrc non ancora presente: lo genera il 03 (kolla-ansible post-deploy)"
  fi
}

print_summary() {
  cat << EOF

+--------------------------------------------------------------+
   02 — OpenStack ${OPENSTACK_RELEASE} deployato (OVN + Barbican + Ceph)
+--------------------------------------------------------------+
  Topologia   : ${#ALL_NODES[@]} nodi | control=${#CONTROL_NODES[@]} compute=${#COMPUTE_NODES[@]} storage=${#STORAGE_NODES[@]}
  VIP API     : ${VIP}   (Horizon: http://${VIP}$([ "${ENABLE_SKYLINE:-yes}" = yes ] && echo "  |  Skyline: http://${VIP}:9999"))
  Rete        : mgmt=${IFACE_MGMT} overlay=${IFACE_TUNNEL} storage=${IFACE_STORAGE} external=${IFACE_EXTERNAL}
  Neutron     : OVN (FIP distribuiti), provider flat su physnet1
  Storage     : External Ceph — glance/cinder/nova su RBD, backup su 'backups'
  Barbican    : ${BARBICAN_CRYPTO_PLUGIN}  (PROD: HSM/Vault — debito tecnico)
  Reservation : $((RESERVED_MEM_CONTROL_MB/1024)) GB su control+compute, $((RESERVED_MEM_COMPUTE_MB/1024)) GB su compute puri

  DA VERIFICARE dopo il 03:
    openstack network show <tenant-net> -c mtu     # atteso ${NEUTRON_GLOBAL_PHYSNET_MTU}
    openstack hypervisor list                       # ${#COMPUTE_NODES[@]} hypervisor
    openstack secret list                           # Barbican risponde
    ceph -s                                         # ancora HEALTH_OK

  PROSSIMO PASSO: 03_configure_openstack_3NODE.sh
EOF
}

main() {
  log_step "02 Deploy OpenStack ${OPENSTACK_RELEASE} (OVN + Barbican + Ceph)"
  topo_validate || { log_error "Topologia non valida (lib_topology.sh)"; exit 1; }
  topo_summary
  precheck
  detect_virt_type
  generate_globals
  generate_nova_reservation
  generate_neutron_override
  if [ "$CONFIG_ONLY" = 1 ]; then
    log_warn "--config-only: generati globals e override, mi fermo qui."
    exit 0
  fi
  generate_passwords
  run_prechecks
  run_bootstrap
  ensure_ceph_running
  run_pull
  ensure_rabbitmq_cluster   # pre-forma il cluster: evita il deadlock cold-start nel deploy
  run_deploy
  ensure_ovn_chassis_shortname
  verify
  print_summary
}

main

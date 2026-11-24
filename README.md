# OpenStack — Automation Suite (Consolidated Release)

**Package date:** 2026-10-15 · **Release:** `v1.7` · **Package type:** DEPLOY

This package contains everything required to deploy the cloud. Functional tests (offline gates, functional checks, KVM lab VM provisioning) live in the **FUNCTIONAL TESTS** package of the same `v1.7` release. That package is optional: if placed in a sibling directory next to this one (`OPENSTACK_tests_*`), `run_all.sh` and `install.sh` find it automatically (otherwise set `TESTS_DIR=/path`).

## Table of Contents

- [Execution Order](#execution-order)
- [Lab Usage (KVM host with nested virtualization)](#lab-usage-kvm-host-with-nested-virtualization)
- [Lab Usage (VMware, pre-installed Ubuntu VMs)](#lab-usage-vmware-pre-installed-ubuntu-vms)
- [Bare-Metal Usage (the 3 real nodes)](#bare-metal-usage-the-3-real-nodes)
- [Proxy, Internal NTP and Network Diagnostics](#proxy-internal-ntp-and-network-diagnostics-bare-metal)
- [Masakari — Instance HA (optional, Phase A)](#masakari--instance-ha-optional-phase-a)
- [Octavia — Load Balancer (optional, OVN provider)](#octavia--load-balancer-optional-ovn-provider)
- [Cluster Shutdown and Startup (MariaDB Galera)](#cluster-shutdown-and-startup-mariadb-galera)
- [Reset and Redeploy (`05_reset.sh`)](#reset-and-redeploy-05_resetsh--destructive)
- [Skyline — Dashboard](#skyline--dashboard)
- [Ceph OSD Encryption (dm-crypt / LUKS)](#ceph-osd-encryption-dm-crypt--luks)
- [Consolidated Fixes in This Release](#consolidated-fixes-in-this-release)
- [Production Technical Debt (from LLD)](#production-technical-debt-from-lld)
- [Endorsers & Adopters](#-endorsers--adopters)

---

## Execution Order

```text
lib_topology.sh        Single source of truth for topology (sourced by all)
00_bootstrap_*.sh      Network (bonding/VLAN, rollback), NTP, egress
01_prepare_*.sh        Docker, Python, Kolla, inventory
01b_setup_ceph_*.sh    Ceph Squid (cephadm), OSDs, pools, keyring
02_deploy_*.sh         globals.yml + OpenStack deploy (OVN, Barbican, Ceph)
03_configure_*.sh      Post-deploy: openrc, external network, demo project, flavor, keypair
04_masakari.sh         [OPTIONAL] Masakari, Instance HA, Phase A (without fencing)
06_octavia.sh          [OPTIONAL] Octavia load balancer, OVN provider only (no amphora)
05_reset.sh            [UTILITY] Reset/redeploy, DESTRUCTIVE (openstack | ceph | all)
run_all.sh             "One-shot" wrapper (00..03, + functional tests if package present)
install.sh             TUI front-end (phase banners) on top of run_all
```

**In the FUNCTIONAL TESTS package (not included here):**

- `test_render.sh` — offline gate
- `lab_create_vms.sh` — nested VMs on KVM
- `03b_functional_tests_3NODE.sh` — HA, services, Barbican, Skyline, East-West smoke test, Ceph volume

---

## Lab Usage (KVM host with nested virtualization)

The FUNCTIONAL TESTS package is required, as it includes `lab_create_vms.sh`. The complete procedure (VM creation, cleanup, deployment, verification) is documented in its own `README_TESTS.md`. With both packages in sibling directories, run from this folder:

```bash
export LAB_MODE=1
./install.sh                         # Creates VMs + 00..03 + functional tests with banner
```

---

## Lab Usage (VMware, pre-installed Ubuntu VMs)

Run from your workstation just like on bare metal (see [Deployment Machine](#where-to-start-the-deployment-machine)), but with lab-sizing parameters:

- `LAB_MODE=1` — active-backup bonding, 1 OSD per node, reduced reserved RAM, nested KVM detection
- `LAB_KVM=0` — VMs already exist: no VM creation, existing IP addresses and interface names are kept

### vSphere prerequisites (for each of the 3 VMs, while powered off)

| Item | Requirement |
|------|-------------|
| NICs | 4 additional **vmxnet3** adapters for the two bonds (2+2). The original NIC used for OS installation can stay where it is; it is not needed after cutover. |
| Port Groups | Trunk Port Groups for the 4 NICs: VLAN ID 4095 on standard vSwitches, or "VLAN trunking" with all 5 VLANs on vDS. Ubuntu handles the tagging. |
| Port Group Security | Accept: **Promiscuous mode**, **MAC address changes**, **Forged transmits** (or MAC learning on vDS 6.7+). Required for bonding and especially for `br-ex`, which forwards traffic using OpenStack router MAC addresses. |
| MTU | **9000** on vSwitch/vDS, and on the physical switches between ESXi hosts if VMs reside on different hosts. Step 00 verifies this with a full-packet ping. |
| Nested virtualization | Enable "Expose hardware-assisted virtualization to the guest OS". Without it Nova falls back to emulation (extremely slow). Check: `ls /dev/kvm` inside the VM. |
| Disks | At least 40 GB for the OS, plus at least one additional disk (thin provisioning is fine) for Ceph. If it is not ~1.92 TB, `--discover-disks` will prompt you. |
| Resources | At least 16 GB RAM and 8 vCPUs per VM. |
| Time sync | Disable VMware Tools time synchronization (managed via chrony instead). |
| Internet | Direct internet breakout, as on bare metal. |

> **Tip:** take a snapshot of the 3 VMs before starting. If anything goes wrong you can revert in a minute instead of reinstalling.

### On your workstation

Linux or WSL2 with Ubuntu on Windows. It must reach the node management network (even via VPN). Deployment takes **2–3 hours**: run it inside `tmux` and disable system standby so the session does not drop midway.

```bash
export LAB_MODE=1 LAB_KVM=0
# 1. Edit lib_topology.sh (lab VLAN IDs and management IPs of the 3 VMs)
#    Edit 00_bootstrap_baremetal_v2.sh: SSH_USER/SSH_PASS (leave TEMP_IPS empty if VMs already have management IPs)
# (Optional, test package) bash ../OPENSTACK_tests_v1.7_20261015/test_render.sh </dev/null 2>/dev/null | tail -3   # PASS=77 FAIL=0
sudo LAB_MODE=1 LAB_KVM=0 bash 00_bootstrap_baremetal_v2.sh --discover
# 2. Populate BOND0_IFACES / BOND1_IFACES in step 00 (e.g., ens224 ens256 / ens161 ens193)
sudo LAB_MODE=1 LAB_KVM=0 bash 00_bootstrap_baremetal_v2.sh      # Cutover
sudo LAB_MODE=1 LAB_KVM=0 bash 01b_setup_ceph_3NODE.sh --discover-disks
tmux new -s os
./install.sh                                                     # Inherits LAB_MODE/LAB_KVM from environment
```

---

## Bare-Metal Usage (the 3 real nodes)

### Where to start: the Deployment Machine

In the lab, the KVM host handles everything. On bare metal, a separate **deployment machine** (Linux laptop, VM, or jump host) triggers and coordinates the scripts over SSH. Heavy lifting (cephadm, Kolla-Ansible) executes on `node01`; the deployment machine acts as orchestrator and log collector.

Avoid using one of the cluster nodes as the deployment machine: step 00 reconfigures network interfaces, including the one you might be launching from. If your only access is a node web console (no direct SSH from your workstation), see [Launching from a Cluster Node](#launching-from-a-cluster-node---from-node).

### Launching from a Cluster Node (`--from-node`)

Possible when bonds and VLANs are already configured (manually or during OS provisioning). Work inside a session on `node01`:

```bash
cd /root/OPENSTACK_deploy_v1.7_20261015        # DO NOT run from /etc/kolla, /var/lib/docker, or /var/lib/ceph
tmux new -s deploy                              # The chain takes 2-3 hours; a dropped web console would kill it
export LAB_MODE=0
./run_all.sh --from-node                        # Or ./install.sh --from-node (uses nohup)
```

**What changes with `--from-node`:**

- Step 00 skips the cutover: it sets up SSH keys, NTP, checks, and verifies that each node already has its management IP on `vlan<VLAN_MGMT>`.
- No VMs are created.
- The rest of the chain (01..04) runs identically, since it talks to nodes over SSH (including `node01`).

**Safeguards** (scripts detect whether they run on a node via the local management IP):

- `00`, `05` and `run_all.sh` executed on a node **without** `--from-node` abort.
- Using `--from-node` on a host that is not a node is an error.
- `05_reset.sh --from-node` also cleans up the launch node: it is rejected if the package resides inside a directory targeted for deletion by the reset. `05 --dry-run` is always permitted (read-only).

### Unknown IPs, VLANs and interface names

If network parameters are assigned by infrastructure teams and only discoverable once connected:

1. Set up deployment SSH keys across all nodes.
2. On `node01`, run `sudo bash configura_topologia.sh`. The script:
   - reads `node01` interfaces (read-only) and prompts for network classifications (management, overlay, Ceph public, Ceph cluster, external);
   - queries management IPs of `node02` and `node03` via SSH;
   - asks for the Virtual IP (a free management IP);
   - generates `topology.conf` (node IPs, subnets, prefixes, VLAN IDs, gateway, DNS, VIP) alongside `ifaces.conf`, next to `lib_topology.sh`.

   IP addresses do not need to follow a strict sequential-octet schema.
3. **Without SSH access:** run `sudo bash configura_topologia.sh --facts > nodeXX.facts` on each node, then `sudo bash configura_topologia.sh --facts-dir <folder_with_3_files>`.
4. Follow up with `test_render.sh` and `./run_all.sh --from-node`.

Public external subnets, gateways and floating IP pools are requested interactively (optional) and written to `topology.conf`. If omitted, step 03 will not create the `provider-ext` network and prints a warning; to add them later, re-run `configura_topologia.sh` followed by step 03.

### Bond and VLAN naming

Network bonds can be named arbitrarily (`bond0`, `team0`, `bond0.10`, `mgmt`, etc.). With `--from-node`, step 00 inspects the nodes to identify which interface handles management, overlay and Ceph networks, matching the underlying bonds and external VLAN IDs. Discovered non-standard names are saved to `ifaces.conf` (next to `lib_topology.sh`), which is parsed by subsequent scripts (02, testing, validation).

Interface discovery can also run on its own, in read-only mode:

```bash
sudo LAB_MODE=0 bash 00_bootstrap_baremetal_v2.sh --detect-ifaces
```

**Rules**

- Interface names must be consistent across all nodes (Kolla enforces a single interface naming convention).
- VLAN IDs and subnets remain in `lib_topology.sh` and must match real values, because discovery initializes from expected IPs (`10.0.x.<last_octet>`).
- To override names manually without auto-discovery:
  `IF_MGMT=... IF_BOND0=... ./run_all.sh --from-node`
  (environment variables override `ifaces.conf`; available names: `IF_BOND0 IF_BOND1 IF_MGMT IF_OVERLAY IF_EXT IF_CEPHPUB IF_CEPHCLU`).
- If networking is unconfigured, the cutover must be performed from an **external host** (`00` without flags); it cannot be done from inside a node.

### Deployment machine requirements

- Linux with `bash`, `ssh`, `python3` (PyYAML recommended; used by the test package gate). `sshpass` is installed automatically on Ubuntu/Debian; otherwise install it manually.
- Root access (sudo): deployment SSH keys are generated under `/root/.ssh/`.
- Access to the node management networks before and after cutover (IP addresses remain unchanged, see below). The deployment machine must reside on, or be routed to, that VLAN.

### Node prerequisites before initialization

- Ubuntu 24.04 installed on the boot device.
- Final management IP already assigned during provisioning on a single network interface. IPs must match `lib_topology.sh` (`NODE_MGMT_IP`); update `lib_topology.sh` beforehand if different IPs were used.
- A user with passwordless sudo and password-based SSH access (default `ubuntu`, see `SSH_USER`/`SSH_PASS` in step 00). Needed only for initial contact; step 00 then switches to root key authentication.
- Direct outbound internet connectivity and working DNS: `archive.ubuntu.com`, `download.docker.com`, `pypi.org`, `quay.io`. Verified by step 00. Proxies are currently flagged rather than configured automatically (they require settings in apt, Docker and pip); proxy environments must be handled beforehand.
- Upstream/ToR switches configured: LACP port-channels on node ports, VLAN trunking, MTU 9000 on overlay and Ceph VLANs.

### What changes at cutover (and what doesn't)

IP addresses remain identical. The management IP moves from the provisioning single interface to a tagged VLAN on top of the LACP bond; additional VLANs (overlay, external, Ceph) are created. Coordinate with network administrators:

- **Before cutover**, the single interface must reach management as during provisioning. If LACP port-channels are already active on the switch, disable "suspend individual" in the LACP policy so the single port isn't dropped, or adjust switch configuration within the cutover window.
- **After cutover**, the management VLAN must arrive **tagged** on the port-channel.
- If connectivity fails, step 00 detects unreachable management VLANs and **automatically reverts** to provisioning settings after 4 minutes, preventing lockouts. If management must remain untagged (native VLAN) on the bond, script modifications are currently required.

### Quick first-contact check

From the deployment machine, one node at a time:

```bash
ssh ubuntu@<MANAGEMENT_IP> 'sudo -n true && echo "sudo OK" && lsb_release -ds'
```

It must return `sudo OK` and `Ubuntu 24.04.…`. If a sudo password is requested, the user lacks `NOPASSWD` configuration and step 00 will abort.

> **`LAB_MODE`:** scripts fail if it is unset. On bare metal it is always `0`. Since `sudo` strips environment variables, prefix commands with `sudo LAB_MODE=0 bash ...`.

### Nodes without full network access (console only)

- **Internet only via proxy:** run `bash configura_proxy.sh --proxy http://IP:PORT` (dry-run with `--dry-run`, validation with `--verify`) before step 00. Details in `PROCEDURA_INSTALLAZIONE_BAREMETAL.md` (E.1b).
- **No pre-configured bonds, VLANs and IPs, console access only:** follow `PROCEDURA_RETE_DA_CONSOLE.md` (full procedure: `PROCEDURA_INSTALLAZIONE_BAREMETAL.md`) to set temporary IPs with 4 commands, run `configura_rete_locale.sh` on each node, then continue with the sequence below.

### Execution sequence

#### 0. Prerequisites (run ONCE before anything else)

VLAN IDs, subnets, IPs and interface names must not be hardcoded by hand: run `configura_topologia.sh` on configured nodes to generate `topology.conf` and `ifaces.conf`. `lib_topology.sh` contains fallback values only.

**External network** (public subnet, gateway, floating IP pool): provided by the network team and passed to `configura_topologia.sh`. If omitted, step 03 will not create the `provider-ext` network and warns accordingly; define it later by re-running the script and step 03.

**`00_bootstrap_baremetal_v2.sh`:** set `SSH_USER` and `SSH_PASS` (provisioning user credentials). `TEMP_IPS` must stay empty if nodes already have their management IPs (standard scenario); use it only if provisioning placed them on a separate network.

If using the test package, `bash test_render.sh </dev/null` must output `PASS=77 FAIL=0` **after** these adjustments and **before** touching the hardware.

#### 1. Network interface discovery (once per node model)

```bash
sudo LAB_MODE=0 bash 00_bootstrap_baremetal_v2.sh --discover
```

Distributes SSH keys and lists the available NICs per node.

#### 2. Populate the bonds in `00_bootstrap_baremetal_v2.sh`

Use the discovered names:

```bash
BOND0_IFACES="<nic_a1> <nic_a2>"   # OpenStack: mgmt/API + overlay + external
BOND1_IFACES="<nic_b1> <nic_b2>"   # Ceph: public + cluster
```

If a node enumerates NICs differently, use `BOND0_OVERRIDE[nodeXX]` / `BOND1_OVERRIDE[nodeXX]` instead of the global defaults. As long as names remain on the `REPLACE_*` placeholders, execution halts before touching the network, to prevent misconfiguration.

> `install.sh` supports bare metal with `export LAB_MODE=0`: it skips VM creation automatically and shows only the real phases in the banner.

#### 3. Network cutover

```bash
sudo LAB_MODE=0 bash 00_bootstrap_baremetal_v2.sh   # Real 802.3ad bond, VLANs, NTP, egress
```

#### 4. Disk inspection (read-only, requires active management network)

```bash
sudo LAB_MODE=0 bash 01b_setup_ceph_3NODE.sh --discover-disks
```

Shows discovered disks and their state (free, system/boot, existing OSD, data-bearing). If the target 1.92 TB SSDs are absent, it proposes identical free disk groups across nodes and prompts for a selection. Choices are saved to `osd_disks.conf` and reused in subsequent runs, including `run_all.sh` and `install.sh`.

- Disks containing partitions or data are **never** touched unless `--zap-osd` is specified.
- `osd_disks.conf` defines site-specific hardware and is excluded via `.gitignore`.

#### 5. Full deployment

```bash
export LAB_MODE=0
./install.sh        # Uses banner; or ./run_all.sh --no-vms
  # Step 00 re-runs, detects migrated nodes, and skips cutover
  # Alternatively step-by-step:
  sudo LAB_MODE=0 bash 01_prepare_nodes_3NODE.sh
  sudo LAB_MODE=0 bash 01b_setup_ceph_3NODE.sh
  sudo LAB_MODE=0 bash 02_deploy_openstack_3NODE.sh
  sudo LAB_MODE=0 bash 03_configure_openstack_3NODE.sh
  # Then, with test package: sudo LAB_MODE=0 bash ../OPENSTACK_tests_*/03b_functional_tests_3NODE.sh
```

#### 6. Periodic post-deployment verification (skips cutover, runs checks only)

```bash
sudo LAB_MODE=0 bash 00_bootstrap_baremetal_v2.sh --verify-only   # LACP/jumbo/NTP
sudo LAB_MODE=0 bash 00_bootstrap_baremetal_v2.sh --ntp-only       # Chrony only, if needed
```

---

## Proxy, Internal NTP and Network Diagnostics (Bare Metal)

### Internet via proxy only

If nodes have no direct outbound internet access:

```bash
bash configura_proxy.sh --proxy http://IP:PORT --dry-run     # Shows generated writes
bash configura_proxy.sh --proxy http://IP:PORT               # Updates /etc/environment, apt, Docker drop-in across nodes
set -a; . /etc/environment; set +a
bash configura_proxy.sh --verify                              # Tests deployment endpoints via proxy node-by-node
```

- `NO_PROXY` is built from the topology (nodes, VIP, subnet) and can be extended via `NO_PROXY_EXTRA`. The URL can be declared in `topology.conf` as `PROXY_URL`.
- Step 00 checks endpoints via the proxy if proxy environment variables are present, and falls back to direct checks otherwise.
- Step 01 writes the Docker drop-in if a proxy is defined.
- The scripts do not run standalone proxies: `configura_proxy.sh` must run **before** step 00.

### NTP

Proxies do not carry UDP 123. Options:

1. Internal NTP servers: `NTP_SERVERS_CSV="ip1,ip2"` in `topology.conf`.
2. A firewall rule allowing UDP 123.
3. `NTP_LOCAL_MASTER="node01"`: the specified node acts as source (local stratum 10) for the others, and step 02 disables Kolla's NTP precheck (the master appears "unsynchronized" to `timedatectl`). Nodes stay synchronized with each other; the absolute time must be set manually on the master before step 00 (`date -u -s`).

### LACP

The default `lacp-rate` is `slow` (compatible with slow or fast switches). Set `LACP_RATE=fast` in `topology.conf` to change it.

### Inter-node network diagnostics

```bash
bash verifica_rete_nodi.sh [--count N] [--porte "22 9090"] [--solo-fisico]
```

Evaluates packet loss across node pairs and networks using pings of 100 / 1472 / 8972 bytes (DF), TCP ports, and physical bond status (aggregator, pre/post CRC errors, Rx optical power). Exits with `1` on failure.

- Random packet loss across **all** sizes points to bonds/cables.
- Loss isolated to **large** packets indicates MTU issues.

---

## Masakari — Instance HA (optional, Phase A)

Automatic VM recovery after instance or compute-node failures. Must run **after step 03**, on a healthy cloud. Step 02 never enables it; subsequent re-runs preserve the values step 04 wrote into `globals.yml`.

```bash
sudo LAB_MODE=1 bash 04_masakari.sh                        # Lab
sudo LAB_MODE=0 bash 04_masakari.sh --accept-no-fencing    # Bare metal, test environment without fencing
sudo bash 04_masakari.sh --verify                          # Verifications only
sudo bash 04_masakari.sh --test-instance                   # Automated test: QEMU kill
sudo bash 04_masakari.sh --watch [node]                    # Guided node failure test
# Via chain: ENABLE_MASAKARI=1 (+ MASAKARI_ACCEPT_NOFENCING=1 on bare metal) ./run_all.sh
```

### 3-node vs 6/9-node topologies

Kolla assigns control nodes to the Corosync/Pacemaker cluster and compute nodes as `pacemaker-remote`. In 3-node setups, nodes fulfill both roles, but a host cannot be a full member and a remote node at the same time. Step 04 handles this by evaluating `lib_topology.sh`:

| Topology | `[hacluster-remote]` | Host Monitor |
|----------|----------------------|--------------|
| 3 nodes (control = compute) | Empty: all are full cluster members | `restrict_to_remotes = false` (override) |
| 6/9 nodes (isolated control) | Compute nodes (Kolla default) | `restrict_to_remotes = true` (Kolla default) |

Without this override, the 3-node monitor would fail to detect hosts and never register failures. Step 04 creates an inventory backup (`multinode.pre-masakari`).

### What Phase A is NOT

- **No fencing:** Kolla does not configure IPMI credentials in Pacemaker and forces `disable_ipmi_check = true`.
- Covered scenarios include **powered-off** nodes. **Isolated-but-alive nodes are unsupported**, because their VMs could run concurrently on the same RBD disks.
- For this reason step 04 aborts on bare metal without `--accept-no-fencing`.
- Phase B (`fence_ipmilan` over the BMC VLAN) is an independent procedure requiring a dedicated maintenance window.

### Verified components

Containers (`hacluster_*`, `masakari_*`), Corosync quorum, online nodes in Pacemaker, VIP API bindings (port 15868), host monitor configuration, `os-compute` segments covering all computes, and capacity estimation (checks that surviving nodes retain enough free RAM if one fails).

### Testing

- `--test-instance` provisions a VM with `HA_Enabled=True`, kills its QEMU process, and waits for Masakari to restore it to `ACTIVE` (`OS_MASAKARI_VM_OK`).
- Node failure testing is manual (`--watch`): abruptly power off a node **other than the deployment node**.
- In 3-node hyperconverged clusters, quorum members for Galera, RabbitMQ, Ceph and Corosync are temporarily degraded: power the node back on and wait for `HEALTH_OK` before repeating.

### Deployment policy options

- `MASAKARI_PROTECT_ALL` — default `yes` (all VMs); set to `no` to target only VMs tagged with metadata `HA_Enabled=True`.
- `MASAKARI_RECOVERY` — default `auto` (no spare hosts are available in 3-node layouts).

## Octavia — Load Balancer (optional, OVN provider)

Load Balancer as a Service with the **OVN provider only**: load balancing is implemented inside OVN and distributed across the chassis, with no amphora VMs. Like Masakari, it is added **after step 03**, on a healthy cloud, with a dedicated script. Step 02 never enables it, and later re-runs keep what step 06 wrote (`enable_octavia`, OVN-only drivers, `octavia.conf` override).

```bash
sudo bash 06_octavia.sh                 # Configuration + deploy + verification + test LB
sudo bash 06_octavia.sh --config-only   # Only globals.yml + override, no deploy
sudo bash 06_octavia.sh --verify        # Verifications only (read-only)
sudo bash 06_octavia.sh --test-lb       # Test LB on os-test-net (created by 03b), then deleted
# Via chain: ENABLE_OCTAVIA=1 ./run_all.sh
```

What step 06 does:

- checks that the `octavia_*` passwords exist in `passwords.yml` (they come from the Kolla template copied by step 01; if a key is missing entirely, use `kolla-mergepwd`: `kolla-genpwd` only fills keys that already exist);
- sets `enable_octavia: "yes"`, `octavia_provider_drivers: "ovn:OVN provider"`, `octavia_provider_agents: "ovn"` in `globals.yml`;
- writes `/etc/kolla/config/octavia.conf` with `[api_settings] default_provider_driver = ovn`. Kolla only sets the enabled drivers, and Octavia's built-in default is `amphora`: without this override, `openstack loadbalancer create` without `--provider` fails;
- runs `kolla-ansible deploy --tags common,haproxy,horizon,octavia` (plus `skyline` when Skyline is enabled, so the dashboard shows load balancers);
- installs `python-octaviaclient` in the Kolla venv;
- verifies `octavia_api` / `octavia_driver_agent` on the control nodes, the API on the VIP (port 9876), the provider list (`ovn` present, `amphora` absent) and the effective default provider, then creates and deletes a test LB with a TCP listener and a `SOURCE_IP_PORT` pool.

With only `ovn` in the drivers, Kolla turns off `octavia_auto_configure` and the certificate checks: no `lb-mgmt-net`, no dedicated VLAN, no amphora image, no flavor, no certificates.

### OVN provider limits

- Layer 4 only: TCP, UDP, SCTP listeners. **No HTTP/HTTPS listeners, L7 policies or TLS termination.**
- Only the `SOURCE_IP_PORT` algorithm (no `ROUND_ROBIN` / `LEAST_CONNECTIONS`).
- Health monitors: TCP and UDP-CONNECT only.
- No amphora failover (`openstack loadbalancer failover` does not apply).
- A floating IP can be associated with the VIP port (requires the External network, see step 03).

If L7 or TLS termination is needed, the amphora provider requires a dedicated `lb-mgmt` VLAN, a second physnet and a host interface on the controllers: a separate project.

---

## Cluster Shutdown and Startup (MariaDB Galera)

Galera does **not** auto-recover after a full shutdown of all nodes: nodes write `safe_to_bootstrap: 0` and `seqno: -1` if stopped ungracefully. Bootstrapping sequentially after an ungraceful shutdown is the most frequent cause of "OpenStack down after reboot".

### BEFORE shutdown (graceful)

```bash
# From a node with active Kolla venv
# 1. Verify no critical VMs are migrating/evacuating
openstack server list --all-projects --status BUILD,REBUILD,MIGRATING
# 2. Silence Ceph alerts during stop
ceph osd set noout
# 3. Check Galera state: record which node holds the highest seqno
for n in node01 node02 node03; do ssh $n "docker exec mariadb cat /var/lib/mysql/grastate.dat"; done
# 4. Stop user VMs (optional, they restart automatically), then nodes ONE BY ONE.
#    The last node to shut down will be the first to power on.
ssh node03 "docker stop mariadb && shutdown -h now"
ssh node02 "docker stop mariadb && shutdown -h now"
ssh node01 "docker stop mariadb && shutdown -h now"
```

### AFTER startup

```bash
# 1. Power on all nodes, wait ~3 mins, check Galera status
for n in node01 node02 node03; do ssh $n "docker ps -a --filter name=mariadb --format '{{.Status}}'"; done
# 2. If MariaDB enters a restart loop (seqno -1 / safe_to_bootstrap 0):
kolla-ansible mariadb-recovery -i /etc/kolla/multinode --configdir /etc/kolla   # HYPHEN, not underscore
# 3. Restart API containers holding stale DB connections (ProxySQL, error 9001)
for n in node01 node02 node03; do
  ssh $n "docker restart placement_api nova_api nova_metadata nova_conductor nova_scheduler cinder_api"
done
# 4. Verify
docker exec mariadb mysql -uroot -p"$(awk '/^database_password:/{print $2}' /etc/kolla/passwords.yml)" \
  -e "SHOW STATUS LIKE 'wsrep_cluster_size'; SHOW STATUS LIKE 'wsrep_local_state_comment'"   # 3 / Synced
ceph osd unset noout ; ceph -s                              # HEALTH_OK
openstack compute service list ; openstack network agent list
docker ps --format '{{.Names}} {{.Status}}' | grep -E 'unhealthy|starting|Restarting'
```

After the failure of a **single** node (e.g. during Masakari testing) no recovery is needed: the node rejoins Galera automatically. However, Masakari leaves that node's `nova-compute` **disabled**; re-enable it with:

```bash
openstack compute service set --enable <node> nova-compute
```

---

## Reset and Redeploy (`05_reset.sh`) — DESTRUCTIVE

Wipes environments clean without OS re-provisioning. Excluded from the standard pipeline: it must be triggered manually, and a level (`--level`) is mandatory (no default).

| Level | Destroyed | Preserved | Recovery path |
|-------|-----------|-----------|---------------|
| `openstack` | Kolla containers and volumes (DB, message queues, users, Keystone keys) and node remnants | Ceph cluster and data (use `--wipe-pools` to purge RBD pools too) | `02 → 03` (with `--wipe-pools`: `01b → 02 → 03`) |
| `ceph` | Same as `openstack` + Ceph cluster; purges only disks mapped as OSDs; drops Kolla keyrings and configs | OS, network, deployment keys | `01b → 02 → 03` |
| `all` | Same as `ceph` + deployment node `/etc/kolla` (globals, inventory, passwords, overrides) | OS, network, deployment keys | `01 → 01b → 02 → 03` |

**Untouched components:** bonds/VLANs/IPs, users, SSH keys, NTP, `/etc/hosts`, Docker, Kolla venv, and non-OSD disks. To reset networking run step 00; otherwise an OS reinstall is required.

```bash
sudo LAB_MODE=0 bash 05_reset.sh --level openstack --dry-run    # Read-only: status and plan
sudo LAB_MODE=0 bash 05_reset.sh --level openstack
sudo LAB_MODE=0 bash 05_reset.sh --level ceph
sudo LAB_MODE=1 bash 05_reset.sh --level all --yes              # --yes allowed in lab mode only
```

**Options**

- `--wipe-pools` (for the `openstack` level)
- `--new-passwords` — regenerates `passwords.yml`, archiving the old version with a timestamp
- `--purge-images` — removes Docker images, forcing a redownload on redeploy

**Safety guarantees**

- All nodes must respond before execution (prevents partial resets).
- Prompts show instances, volumes, images, Ceph health and targeted OSD disks before asking for confirmation.
- On bare metal, confirmation requires typing a full sentence (`DISTRUGGI <level> node01 node02 node03`) and **ignores `--yes`**.
- Logs and prior state snapshots are archived to `logs-reset-<date>/` (added to `.gitignore`).
- Disks are wiped only if confirmed as PVs of a `ceph-*` VG before the reset.
- After `--level all`, `globals.yml` reverts to defaults: `enable_masakari` returns to `no` and must be re-enabled via step 04.

**Validation status:** safeguards, dry-runs, execution order and levels were tested via simulated SSH (`test_render.sh`, test package). On real hardware, reset steps were verified individually (`mariadb-recovery`, etc.), but a full `05` run on a KVM lab should be verified before bare-metal deployment.

---

## Skyline — Dashboard

Skyline is enabled by default from step 02 (`enable_skyline: "yes"`); Horizon remains active.

- Console: `http://<VIP>:9999` (standard Horizon admin credentials)
- Skyline API: port `9998`, behind the same HAProxy
- To disable: `sudo LAB_MODE=0 ENABLE_SKYLINE=no bash 02_deploy_openstack_3NODE.sh`

**Network requirements:** TCP ports `9999` (console) and `9998` (API) on the VIP must be reachable from client workstations, alongside Horizon on port `80`.

The deployment automatically provisions the `skyline` database and Keystone user; passwords (`skyline_*`) are generated by `kolla-genpwd` during step 02. Steps 02 (end of deploy) and 03 (verification) validate console responsiveness on the VIP.

**On pre-deployed clusters** (without re-running step 02, which regenerates globals):

```bash
# On the deployment node with active Kolla venv
sed -i 's/^enable_skyline:.*/enable_skyline: "yes"/' /etc/kolla/globals.yml
kolla-ansible deploy -i /etc/kolla/multinode --configdir /etc/kolla --tags common,haproxy,skyline
curl -s -o /dev/null -w '%{http_code}\n' http://<VIP>:9999/        # Expected: 200
```

**With Masakari:** Skyline configuration lists the services active during deployment. If step 04 runs afterwards, trigger:

```bash
kolla-ansible reconfigure -i /etc/kolla/multinode --configdir /etc/kolla --tags skyline
```

> **Hardware validation pending:** offline testing validates the generated globals. Skyline API server and console images for 2025.1 are pulled from registries; missing images cause immediate failures during the step 02 pull phase.

---

## Ceph OSD Encryption (dm-crypt / LUKS)

Step 01b provisions OSDs with encryption-at-rest **enabled by default** (`OSD_ENCRYPT=yes`): `ceph-volume` prepares them via dm-crypt/LUKS, so extracted physical drives remain unreadable.

To disable (only if strictly necessary):

```bash
sudo OSD_ENCRYPT=no bash 01b_setup_ceph_3NODE.sh
```

- **Mechanism:** `ceph orch daemon add osd` has no native encryption flag, so step 01b applies an OSD spec per node (`osd_enc_<node>`, `encrypted: true`, target disk list). Specs are cumulative: re-running 01b after adding disks encrypts the newly added units.
- **Prerequisites:** `cryptsetup` and the `dm_crypt` kernel module on all nodes. Step 01b installs and persists them (it aborts before OSD creation if missing).
- **Automated verification:** after creation, step 01b validates crypt mappings (`lsblk`) and aborts if any disk remains unencrypted. Manual check: `lsblk -o NAME,TYPE /dev/sdX` must show a `crypt` entry beneath the `ceph--...` volumes.
- **Keys:** LUKS keys reside in the MON config-key store rather than on local node disks, allowing unattended OSD unlock at boot. Back up the MON cluster state accordingly: encrypted data is unrecoverable without the keys.
- **Overhead:** minor CPU cost, offset by AES-NI instructions.
- **Existing OSDs are not converted.** Unencrypted clusters require sequential recreation: `ceph osd out <id>`, wait for `HEALTH_OK`, `ceph orch osd rm <id> --zap`, then re-run step 01b (or the specs) to recreate them encrypted. In single-OSD lab footprints it is simpler to reset with `05_reset.sh --level ceph` and re-run 01b.
- **Scope:** does not replace Cinder volume encryption (Barbican + LUKS volume types), which operates at a separate tenant tier.

---

## Consolidated Fixes in This Release

- **Lib:** centralized 3/6/9-node topologies, `LAB_MODE`, `BOND_PARAMS`, `topo_derive`.
- **00:** lab active-backup bonding, softened LACP gates, topology-driven `/etc/hosts`. Jumbo frame failures counted in gate rules (3 retries); clock-skew compensation; `NTP_LOCAL_MASTER`.
- **01:** pings routed to the `baremetal` group (excludes localhost), topology-based counting. Migrated deprecated `ansible-collection-kolla` stable branches to `unmaintained/<rel>`.
- **01b:** encrypted OSDs (`encrypted: true` spec + dm-crypt verification); disk iteration via fd 3 (prevents SSH from skipping disks); Ceph image pinned to the host version (avoids "Malformed input" keyring errors); `-i` SSH key injection in `add_hosts`; lab OSD caps; `osd_memory_target_autotune`.
- **02:**
  - Cinder coordinator (`redis | valkey | etcd`) + `cinder_cluster_name` (active-active HA).
  - Nova reservation clamped to actual RAM (prevents `NoValidHost` errors).
  - `ensure_ceph_running` restarts Ceph instances + `reset-failed` (prevents post-Docker MON stalls).
  - `ensure_rabbitmq_cluster` handles cold-start deadlocks (resets volumes + redeploys concurrently).
  - `detect_virt_type` sets KVM if `/dev/kvm` exists on computes, QEMU otherwise.
  - MTU: `global_physnet_mtu 1558` + `path_mtu 1558` + `physnet1:1500` (tenant 1500).
  - Kolla NTP prechecks disabled when `NTP_LOCAL_MASTER` is active.
- **03:** short hostnames (OVN chassis matches Nova host, prevents `PortBindingFailed`); post-deploy includes RabbitMQ polling + retries; non-fatal client installation.
- **Proxy:** revised `configura_proxy.sh`, step 00 proxy egress checks (3 retries), step 01 Docker drop-ins, topology-derived `NO_PROXY`.
- **Network diagnostics:** added `verifica_rete_nodi.sh` (ping, MTU, ports, physical bond state).
- **Lab specs:** short hostnames (non-FQDN), 40 GB boot disks, 6-octet MAC addresses, `host-passthrough` virtualization.

---

## Production Technical Debt (from LLD)

- **OpenStack 2025.1 (Epoxy)** has entered "unmaintained" status: images are available without guaranteed regular security patches. Plan an update to 2025.2 / 2026.1.
- **TLS:** internal/external TLS is currently disabled.
- **Barbican:** move from `simple_crypto` to HSM/Vault.
- **Encrypted OSDs:** move LUKS keys from MON config-keys to an external KMS (Vault) to decouple them from the cluster.
- **Cinder coordinator:** migrate to Valkey in place of Redis (2025.2+).
- **Octavia:** OVN provider only (L4). L7/TLS termination would need the amphora provider (dedicated `lb-mgmt` VLAN, certificates, image).
- **OpenStack client:** use `kolla_toolbox` instead of pip installs (isolated clusters without PyPI egress).
- **RAID controllers** in non-RAID layouts: switch to native HBAs (true IT mode).
- **Hostnames:** short, consistent hostnames across all nodes (OVN prerequisite).
- **Topology:** VLAN IDs, IPs and interface names are read dynamically via `configura_topologia.sh` (avoid editing `lib_topology.sh`).

---

## 🌟 Endorsers & Adopters

We gratefully acknowledge the organizations and professionals who endorse and validate the use of this suite in production or enterprise environments:

* **[Nome Organizzazione / Azienda o Professionista]** — *Role / Context (e.g., Enterprise Infrastructure Team)*
* **[Altro Endorser]** — *Role / Context*

*(If your organization uses or endorses this deployment suite, feel free to open a Pull Request to add your name to the list.)*

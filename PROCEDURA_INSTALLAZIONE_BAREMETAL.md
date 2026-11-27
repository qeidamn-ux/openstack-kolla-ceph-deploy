# Installation on three physical servers — complete procedure

Valid for the OpenStack Automation Suite v1.7 (OpenStack 2025.1 "Epoxy" deployed with Kolla-Ansible, encrypted Ceph, OVN, Barbican, Skyline, Masakari, optional Octavia with the OVN provider) on **3 physical servers** running Ubuntu 24.04, with access, if needed, **from the console only** (no copy/paste). Network values (VLAN, subnet, IP) are shown as placeholders: they are provided by the network team and typed in at the scripts' prompts.

Order: A prerequisites → B node checks → C network → D SSH keys → E topology → F installation → G verification → H functional tests → I troubleshooting.

## A. What you need beforehand (from the network team)

| Item | Notes |
|---|---|
| 5 VLAN IDs | management, overlay, external, Ceph public, Ceph cluster |
| Subnets | management (+ gateway, DNS), overlay, Ceph public, Ceph cluster |
| 3 management IPs | one per node |
| 1 free management IP | the API **VIP** (not assigned to anyone) |
| Overlay | the VLAN is L2 only, but **every node has an IP** in this subnet (Geneve endpoint) |
| External | public subnet, gateway, first/last IP of the floating pool. The external VLAN **has no IP on the nodes**. If missing, enter them later (section E.3) |
| Links | both ports of `bond0` and `bond1` with link UP, in the same LACP port-channel (or MLAG/vPC); VLANs trunked; suitable network MTU (9000 if planned) |
| Data disk | the Ceph disk must be exposed to the system as **Non-RAID / passthrough** (controller), not as a virtual RAID volume |
| Internet | outbound access to the repositories (apt, pip, quay.io) from the management network |

## B. Node checks (console, on every node)

```
sudo grep -E "Slave Interface|MII Status|Aggregator ID" /proc/net/bonding/bond0
ip -br link
lsblk -d -o NAME,SIZE,TYPE,MODEL
free -g
timedatectl
```

- The two `bond0` links must have the **same Aggregator ID**; if they differ, the switch is not aggregating them: ask the network team to fix it.
- The `bond1` ports must be UP.
- `lsblk` must show the data disk (in addition to the system disk). If it does not appear, the disk is still behind a RAID volume: fix it on the controller.
- The data disk is the one **with no partitions and no mountpoint**; the system disk is the one holding `/`. The names (`sda`, `sdb`) may be swapped compared to what is expected, or differ from node to node: this does not matter, because `01b` picks disks by size and only among the free ones. Still, check on every node that the free disk is the right one.
- Note down the NIC names (two for `bond0`, two for `bond1`).

## C. Network (only if the nodes do not already have all the VLANs configured)

If Linux only has `bond0` with the management VLAN, the network is completed by the scripts. Details in `PROCEDURA_RETE_DA_CONSOLE.md`; in short:

1. **Temporary IP** only if the node does not already have a reachable IP (section 1 of that document).
2. **Copy the package** to all three nodes into `/root` (section 2 of that document) and unpack the two zip files side by side.
3. **node01, from the console** (not over SSH):
   ```
   cd /root/OPENSTACK_deploy_*
   sudo bash configura_rete_locale.sh
   ```
   Answer the questions (ports, VLAN, subnets, gateway, node IPs, VIP), review the summary, `s` (yes). The script removes by itself the VLANs with the same IDs and the existing bonds, and applies the network with automatic rollback: **within 180 seconds press Enter**, but only if the gateway answers. Without confirmation it reverts to the previous network configuration.
4. **node02 and node03**: copy `topology.conf` and `ifaces.conf` from node01, then from the console:
   ```
   cd /root/OPENSTACK_deploy_*
   sudo bash configura_rete_locale.sh --usa-piano
   ```
5. Do **not** set `LAB_MODE` on physical servers. If the script mistakenly detects a virtual machine without `LAB_MODE`, it warns you.
6. Checks, on every node:
   ```
   sudo grep -E "Bonding Mode|Transmit Hash|Aggregator ID|MII Status" /proc/net/bonding/bond0
   ip -br addr
   ping -c3 GATEWAY
   ping -c3 -M do -s 8972 OTHER_NODE_IP_ON_EACH_NETWORK     # only if MTU 9000
   ```
   Bond in `IEEE 802.3ad`, a single Aggregator ID, and pings of 8972 bytes working on the networks with MTU 9000 (overlay, Ceph).

## D. SSH keys (from node01)

```
sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519_os_3node -C os-3node-deploy
sudo cat /root/.ssh/id_ed25519_os_3node.pub
```

On **each of the three nodes** (node01 included), as root:

```
sudo mkdir -p /root/.ssh && sudo chmod 700 /root/.ssh
echo "ssh-ed25519 AAAA...line printed above..." | sudo tee -a /root/.ssh/authorized_keys
sudo chmod 600 /root/.ssh/authorized_keys
sudo sshd -T | grep -i permitrootlogin      # yes or prohibit-password
```

If it is `no`: fix it in `/etc/ssh/sshd_config` (or `sshd_config.d/`) and run `sudo systemctl reload ssh`.

Verify from node01 (it must not ask for a password; it prints node01/02/03):

```
for ip in NODE01_IP NODE02_IP NODE03_IP; do
  sudo ssh -i /root/.ssh/id_ed25519_os_3node -o StrictHostKeyChecking=no root@$ip hostname
done
```

If you can log in with a sudo user from another node: `ssh -t USER@IP "sudo sshd -T | grep -i permitrootlogin"`.

## E. Topology (from node01)

### E.1 Detection
```
cd /root/OPENSTACK_deploy_*
sudo bash configura_topologia.sh
```
Answers: see the table in the guide (point 3). The summary must be reviewed by the network team. It writes `topology.conf` and `ifaces.conf`.

### E.1a Network check between nodes

After the network setup and before the deploy (and after any intervention on the network or cables):

```
bash verifica_rete_nodi.sh                       # 10 pings per test, port 22
bash verifica_rete_nodi.sh --count 30 --porte "22 9090"
bash verifica_rete_nodi.sh --solo-fisico         # bond status only, no pings
```

Loss that only shows up with large packets = MTU along the path; random loss at all sizes = bond or cable (`FISICO` lines: growing CRC errors, low optical Rx). It exits with 1 if anything is wrong.

### E.1b Internet access only through a proxy

If the nodes reach the internet only through a proxy (symptoms: direct connections to `archive.ubuntu.com`, `quay.io`, `pypi.org` blocked, `apt` slow or stalling halfway, public DNS not resolving), this step is needed **before** `00`/`install.sh`:

```
cd /root/OPENSTACK_deploy_*
env | grep -i proxy                                      # is the proxy already in the environment? (otherwise: --proxy)
bash configura_proxy.sh --proxy http://PROXY_IP:PORT --dry-run     # shows what it writes, does not touch the nodes
bash configura_proxy.sh --proxy http://PROXY_IP:PORT               # applies to all three nodes
set -a; . /etc/environment; set +a                       # loads the variables into the current shell
bash configura_proxy.sh --verify                         # tests the deployment endpoints via proxy, node by node
```

On each node the script writes `/etc/environment` (proxy and `NO_PROXY`), `/etc/apt/apt.conf.d/95proxy` and the Docker daemon drop-in. `NO_PROXY` contains the cluster's nodes, VIP and subnets: **it is essential**, otherwise the OpenStack APIs, Ceph and the CLI go through the proxy and do not work. Extra entries: `NO_PROXY_EXTRA="a,b"` in `topology.conf`. The URL can live in `topology.conf` as `PROXY_URL="http://IP:PORT"`.

Limits: the proxy does not carry NTP (UDP 123): you need an internal NTP server (`NTP_SERVERS_CSV`) or the port opened. If no NTP server is reachable, `NTP_LOCAL_MASTER="node01"` in `topology.conf` makes node01 the source for the other two (the nodes stay aligned with each other, which is what Ceph needs; the absolute time may be wrong: set it beforehand with `date -s`). A proxy with TLS inspection requires installing its CA certificate on the nodes (not handled by the scripts). With the proxy active, `00` checks the endpoints via the proxy (not with direct connections).
## DAVE
`download.cirros-cloud.net` e' controllato insieme agli altri endpoint: serve solo al `03b` per l'immagine CirrOS; se non e' raggiungibile il deploy prosegue e lo smoke test viene saltato.
## DAVE

### E.2 Optional settings (before launch)

- **Passwords**: copy `secrets.conf.example` to `secrets.conf`, set `DASHBOARD_PASS` (Ceph dashboard) and `DEMO_PASS` (demo user), `chmod 600 secrets.conf`. Minimum 8 characters, no spaces and none of `' " \ $` or the backtick. If the file is missing, the default values apply.
- **NTP servers**: in `topology.conf` add `NTP_SERVERS_CSV="ntp1.example,ntp2.example"` if the public defaults are not reachable.
- **LACP rate**: default `slow` (works with both `slow` and `fast` switches). If the switch is set to `fast`: `LACP_RATE=fast` in `topology.conf` before launching `configura_rete_locale.sh`.
- **VRRP router ID**: default 51. If another VRRP with the same ID already exists in the same management network (check: `sudo tcpdump -ni bond0 -c5 vrrp`), add `VRRP_ROUTER_ID=<free value 1-255>` to `topology.conf`.
- **Ceph disks** (mandatory if the data disk size is not 1.7–2.1 TB, the default range, otherwise `01b` stops): `sudo bash 01b_setup_ceph_3NODE.sh --discover-disks` shows the free disks of every node, you pick the right one, and the choice (size window) is saved to `osd_disks.conf` and reused by later runs. Do it after the SSH keys, before `install.sh`. Alternatively `DATA_DISK_MIN`/`DATA_DISK_MAX` (bytes).

### E.3 Missing External network
If subnet/gateway/pool are not available yet: press Enter at the prompts. The cloud installs without floating IPs; when the data arrives: `sudo bash configura_topologia.sh` and then `LAB_MODE=0 ./03_configure_openstack_3NODE.sh`.

### E.4 Offline check
```
cd /root/OPENSTACK_tests_*
bash test_render.sh </dev/null 2>/dev/null | tail -3      # FAIL=0
```

## F. Installation (from node01, inside tmux)

```
tmux new -s deploy
cd /root/OPENSTACK_deploy_*
export LAB_MODE=0
./install.sh --from-node
```

(Alternatively `LAB_MODE=0 ./run_all.sh --from-node`.) Do not use `sudo -E`. Duration 2-3 hours; the RabbitMQ phase may pause for about 13 minutes for an automatic recovery. If the console drops: `tmux attach -t deploy`; detach with `Ctrl+B` then `D`. If it stops: re-run the same command (steps that already succeeded are skipped).

At the end you will see `Catena completata` (chain completed) and `Horizon: http://<VIP>`.

## G. Final verification (node01)

```
sudo ceph -s                                  # HEALTH_OK, 3 mon, OSDs up/in
source /opt/kolla-venv/bin/activate
source /root/admin-openrc.sh
openstack compute service list
openstack hypervisor list                     # 3 hypervisors up
openstack network agent list
openstack network list                        # provider-ext present if External is defined
sudo docker ps --format '{{.Names}} {{.Status}}' | grep -vi "up" # no lines = all up
```

Admin password: `/root/admin-openrc-password.txt`. Console: `http://<VIP>`.

## H. Functional tests (optional)

From the test package, on node01, **as root** (`sudo -i`, because `sudo` does not pass variables):
```
cd /root/OPENSTACK_tests_*
DEPLOY_DIR=/root/OPENSTACK_deploy_<version> LAB_KVM=0 LAB_MODE=0 bash 03b_functional_tests_3NODE.sh
cd acceptance && ./acceptance_test.sh --run L1,L2 --level 2
```
(`source` environment as in G; `DEPLOY_DIR` is the folder of the deploy package.)

## H.1 Octavia load balancer (optional, on the installed cloud)

Only after G is clean (and preferably after the `03b`, which creates the `os-test-net` network used by the test load balancer). OVN provider only: no new VLAN, image or certificates are needed. From node01, in tmux, inside the deploy package folder:
```
cd /root/OPENSTACK_deploy_*
sudo LAB_MODE=0 bash 06_octavia.sh             # about 10-20 minutes
sudo LAB_MODE=0 bash 06_octavia.sh --verify    # re-check at any time
```
Expected at the end: `Octavia operativo` and `OS_OCTAVIA_LB_OK`. Without `os-test-net` the test LB is skipped with a `[WARN]` (not an error). Re-running `02` later does not switch Octavia off. Limits to report in the handover: layer 4 only (TCP/UDP), `SOURCE_IP_PORT` algorithm, no HTTP listeners or TLS termination.

## I. Common problems

| Symptom | What to do |
|---|---|
| Node without network after `configura_rete_locale` | do not confirm: after 180 s it reverts to the previous network configuration |
| `LACP NON formato` (LACP not formed) in 00 | switch side: port-channel/MLAG must be fixed |
| `bond1` port without link | cable/enable the port on the switch |
| Data disk not visible / out of range | Non-RAID on the controller; `--discover-disks`, `DATA_DISK_MIN/MAX` |
| "non risulti in tmux" (you are not in tmux) | open tmux and re-run |
| "nessun IP di management locale corrisponde" (no local management IP matches) | re-run `configura_topologia.sh` |
| "unsynchronized" | `sudo chronyc makestep; sleep 20; timedatectl`, or `NTP_SERVERS_CSV` |
| Failed downloads (apt, pip, images) | internet egress blocked: network team |
| Unstable VIP failover | possible VRRP conflict: use a different `VRRP_ROUTER_ID` |
| `06_octavia`: `password mancanti` (missing passwords) | follow the `kolla-genpwd` / `kolla-mergepwd` commands printed by the script |
| `06_octavia`: `API Octavia non risponde` (API not responding) | `kolla-ansible reconfigure -i /etc/kolla/multinode --tags haproxy`, then `--verify` |
| `loadbalancer create` asks for `amphora` | override `/etc/kolla/config/octavia.conf` missing: re-run `06_octavia.sh` |
| Start from scratch | `05_reset.sh` (see the script header) |

For any `[FAIL]` lines that remain: send them to whoever maintains the installation.

### Known limitations to report in the handover document

- **OpenStack release.** 2025.1 (Epoxy) is now an "unmaintained" release: published packages and images remain available,
  but new security fixes are not guaranteed. Plan the upgrade to a maintained release.
- **RabbitMQ cold start.** On first start the first node can take over 10 minutes to become `healthy` before Kolla creates the others;
  `02` handles it (cluster check and, if needed, volume reset and redeploy): do not interrupt.
- **Local NTP.** With `NTP_LOCAL_MASTER` the nodes are aligned with each other but not with an external source.

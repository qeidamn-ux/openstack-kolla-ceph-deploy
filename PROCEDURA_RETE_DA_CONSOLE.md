# Manual node network setup (console only)

When to use it: the nodes have Ubuntu installed but **do not** have a complete IP, VLAN or bond configuration, and the only access is the web console (no SSH, no copy/paste). Very little typing is needed: a few commands by hand, the rest is done by `configura_rete_locale.sh`.

## 0. What you need beforehand (from the network team)

- the **5 VLAN IDs**: management, overlay, external, Ceph public, Ceph cluster;
- the **subnets** for management, overlay, Ceph public and Ceph cluster, plus the management **gateway**;
- **one management IP per node** and **one free IP** (the API VIP);
- confirmation that **both ports** of each bond have link and belong to the **same LACP port-channel** (or to a switch pair with MLAG/vPC).

Check this right away on every node, from the console:

```
sudo grep -E "Slave Interface|MII Status|Aggregator ID" /proc/net/bonding/bond0
ip -br link
```

- If the two links of `bond0` have **different Aggregator IDs**, the switch is not aggregating them: ask for it to be fixed (the node works, but without real redundancy).
- The two Ceph ports (`bond1`) must be **UP**: if they are DOWN, they must be cabled or enabled on the switch.

## 1. Temporary IP, only to be able to copy files (on EVERY node, from the console)

Use **exactly the management IP planned for that node**. `ID` is the management VLAN ID, `GW` the gateway, `PFX` the prefix length (e.g. 26).

```
sudo ip link add link bond0 name vlanM type vlan id ID
sudo ip link set vlanM up
sudo ip addr add NODE_IP/PFX dev vlanM
sudo ip route add default via GW
ping -c2 GW
```

`vlanM` is an arbitrary name (it will not be kept). The configuration is not persistent: it is lost on reboot, by design. If `ping` gets no reply, the VLAN is not trunked to that node, or the IP/gateway are wrong: sort it out with the network team **before** continuing.

## 2. Getting the package onto the nodes

From a PC that can reach the management network (or from another node, now that all of them have the temporary IP):

```
scp OPENSTACK_deploy_*.zip OPENSTACK_tests_*.zip USER@NODE01_IP:/tmp/
```

Then, on each node, from the console:

```
sudo -i
cd /root && unzip /tmp/OPENSTACK_deploy_*.zip && unzip /tmp/OPENSTACK_tests_*.zip
```

This way the package is on all three nodes. (If you prefer, copy it to node01 and from there to the others with `scp -r`.)

## 3. Configure the network: node01 first

On node01, **from the console** (not over SSH):

```
cd /root/OPENSTACK_deploy_*
bash configura_rete_locale.sh
```

The script:
1. lists the NICs and proposes the ports (`bond0` = the ones already bonded, `bond1` = the other two multi-port ones): check that they are correct;
2. asks for the VLAN IDs, subnets, gateway, the IPs of the 3 nodes and the VIP (for overlay and Ceph it proposes the same "host number" as management: press Enter if that is fine);
3. shows a summary: **have it reviewed** and answer `s` (yes);
4. removes from the console any pre-existing VLANs with the same IDs on the bonds (e.g. the installer's management VLAN) and the existing bonds (so they receive the correct parameters: **no need to delete them by hand**), then applies the configuration with `netplan apply` and an automatic rollback: **within 180 seconds press Enter to confirm** (only if the gateway answers). If you do not confirm, it reverts on its own to the previous network configuration;
5. sets the hostname `node01` and checks bond, IP and gateway. Any `[ATTENZIONE]` (warning) lines must be resolved before continuing.

Try it first without touching anything: `bash configura_rete_locale.sh --dry-run` (writes the files into `dry-run/`).

## 4. Nodes 2 and 3

On node01, `topology.conf` and `ifaces.conf` have been created in the package folder. From node01, copy them to the other nodes (once per node, changing the IP):

```
sudo scp /root/OPENSTACK_deploy_*/topology.conf /root/OPENSTACK_deploy_*/ifaces.conf USER@NODE02_IP:/tmp/
```

Then, from the console on that node:

```
sudo cp /tmp/topology.conf /tmp/ifaces.conf /root/OPENSTACK_deploy_*/
cd /root/OPENSTACK_deploy_* && sudo bash configura_rete_locale.sh --usa-piano
```

It only asks for the ports (Enter if correct) and the node number (2 or 3), then applies the network configuration: confirm with Enter.

## 5. SSH keys and deployment

From node01, using the passwords of the node users:

```
sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519_os_3node -C os-3node-deploy
for ip in NODE01_IP NODE02_IP NODE03_IP; do
  sudo cat /root/.ssh/id_ed25519_os_3node.pub | ssh USER@$ip 'sudo mkdir -p /root/.ssh && sudo tee -a /root/.ssh/authorized_keys >/dev/null && sudo chmod 600 /root/.ssh/authorized_keys'
done
sudo ssh -i /root/.ssh/id_ed25519_os_3node root@NODE02_IP hostname
```

It must print `node02` (and likewise for the others). If `root` cannot log in, check `sshd -T | grep permitrootlogin` (it must be `yes` or `prohibit-password`).

Complete start-to-finish procedure: `PROCEDURA_INSTALLAZIONE_BAREMETAL.md`. Then continue as in the guide: `bash configura_topologia.sh` (adds the External network if you have it), `test_render.sh` and `LAB_MODE=0 ./run_all.sh --from-node` inside tmux.

## 6. If something goes wrong

| Symptom | What to do |
|---|---|
| the node loses network after applying | do not press Enter: after 180 s it reverts on its own to the previous network configuration |
| "the NIC 'X' does not exist" | wrong name: use the ones from the initial table |
| `[ATTENZIONE] ... senza link` on a bond1 port | the port is not cabled or not enabled on the switch |
| `[ATTENZIONE] ... NON nello stesso aggregato LACP` | port-channel/MLAG must be fixed on the switch |
| `gateway ... NON raggiungibile` | management VLAN not trunked on bond0, or wrong IP or gateway |
| you want to start over | the old netplan files are in `/root/netplan-backup-locale-<date>/` |

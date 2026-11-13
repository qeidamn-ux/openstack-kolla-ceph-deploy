# Rete dei nodi da configurare a mano (solo console)

Quando usarla: i nodi hanno Ubuntu installato ma **non** hanno IP, VLAN o bond completi e l'unico accesso è la console web (niente SSH, niente copia/incolla). Si digita poco: pochi comandi a mano, il resto lo fa `configura_rete_locale.sh`.

## 0. Da avere prima (dal referente di rete)

- i **5 VLAN ID**: management, overlay, external, Ceph public, Ceph cluster;
- le **subnet** di management, overlay, Ceph public, Ceph cluster, e il **gateway** della management;
- **un IP di management per ciascun nodo** e un **IP libero** (il VIP delle API);
- conferma che **tutte e due le porte** di ogni bond abbiano link e siano nello **stesso port-channel LACP** (oppure in una coppia di switch con MLAG/vPC).

Controllo da fare subito su ogni nodo, con la console:

```
sudo grep -E "Slave Interface|MII Status|Aggregator ID" /proc/net/bonding/bond0
ip -br link
```

- Se i due link di `bond0` hanno **Aggregator ID diversi**, lo switch non li aggrega: si chiede di correggerlo (il nodo funziona, ma senza ridondanza reale).
- Le due porte di Ceph (`bond1`) devono risultare **UP**: se sono DOWN, vanno collegate o abilitate sullo switch.

## 1. IP provvisorio, solo per poter copiare i file (su OGNI nodo, da console)

Usare come IP **esattamente quello di management previsto per quel nodo**. `ID` è il VLAN ID di management, `GW` il gateway, `PFX` il prefisso (es. 26).

```
sudo ip link add link bond0 name vlanM type vlan id ID
sudo ip link set vlanM up
sudo ip addr add IP_NODO/PFX dev vlanM
sudo ip route add default via GW
ping -c2 GW
```

`vlanM` è un nome qualsiasi (non verrà mantenuto). Non è permanente: si perde al riavvio, ed è voluto. Se il `ping` non risponde, la VLAN non è trunkata verso quel nodo o IP/gateway sono sbagliati: si risolve col referente di rete **prima** di continuare.

## 2. Portare il pacchetto sui nodi

Da un PC che raggiunge la rete di management (o da un altro nodo, ora che hanno tutti l'IP provvisorio):

```
scp OPENSTACK_deploy_*.zip OPENSTACK_tests_*.zip UTENTE@IP_NODE01:/tmp/
```

Poi su ogni nodo, da console:

```
sudo -i
cd /root && unzip /tmp/OPENSTACK_deploy_*.zip && unzip /tmp/OPENSTACK_tests_*.zip
```

Così il pacchetto è su tutti e tre i nodi. (Se si preferisce, si copia su node01 e da lì sugli altri con `scp -r`.)

## 3. Configurare la rete: node01 per primo

Su node01, **da console** (non da SSH):

```
cd /root/OPENSTACK_deploy_*
bash configura_rete_locale.sh
```

Lo script:
1. elenca le schede e propone le porte (`bond0` = quelle già in bond, `bond1` = le altre due multiporta): controllare che siano giuste;
2. chiede i VLAN ID, le subnet, il gateway, gli IP dei 3 nodi e il VIP (per overlay e Ceph propone lo stesso "numero di host" della management: Invio se va bene);
3. mostra il riepilogo: **farlo controllare** e rispondere `s`;
4. toglie da console eventuali VLAN preesistenti con gli stessi ID sui bond (es. quella di management degli installatori) e i bond esistenti (così ricevono i parametri corretti: **non serve cancellarli a mano**), poi applica con `netplan apply` e un rollback automatico: **entro 180 secondi premere Invio per confermare** (solo se il gateway risponde). Se non si conferma, torna da solo alla rete di prima;
5. imposta l'hostname `node01` e controlla bond, IP e gateway. Eventuali `[ATTENZIONE]` vanno risolti prima di proseguire.

Prova prima senza toccare nulla: `bash configura_rete_locale.sh --dry-run` (scrive i file in `dry-run/`).

## 4. Nodi 2 e 3

Su node01 sono nati `topology.conf` e `ifaces.conf` nella cartella del pacchetto. Da node01 copiarli sugli altri nodi (una volta per nodo, cambiando l'IP):

```
sudo scp /root/OPENSTACK_deploy_*/topology.conf /root/OPENSTACK_deploy_*/ifaces.conf UTENTE@IP_NODE02:/tmp/
```

Poi, da console su quel nodo:

```
sudo cp /tmp/topology.conf /tmp/ifaces.conf /root/OPENSTACK_deploy_*/
cd /root/OPENSTACK_deploy_* && sudo bash configura_rete_locale.sh --usa-piano
```

Chiede solo le porte (Invio se giuste) e il numero del nodo (2 o 3), poi applica la rete: confermare con Invio.

## 5. Chiavi SSH e deploy

Da node01, con le password degli utenti dei nodi:

```
sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519_os_3node -C os-3node-deploy
for ip in IP_NODE01 IP_NODE02 IP_NODE03; do
  sudo cat /root/.ssh/id_ed25519_os_3node.pub | ssh UTENTE@$ip 'sudo mkdir -p /root/.ssh && sudo tee -a /root/.ssh/authorized_keys >/dev/null && sudo chmod 600 /root/.ssh/authorized_keys'
done
sudo ssh -i /root/.ssh/id_ed25519_os_3node root@IP_NODE02 hostname
```

Deve stampare `node02` (e analogamente per gli altri). Se `root` non può entrare, vedere `sshd -T | grep permitrootlogin` (deve essere `yes` o `prohibit-password`).

Procedura completa dall'inizio alla fine: `PROCEDURA_INSTALLAZIONE_BAREMETAL.md`. Poi si prosegue come nella guida: `bash configura_topologia.sh` (aggiunge la rete External se la si ha), `test_render.sh` e `LAB_MODE=0 ./run_all.sh --from-node` dentro tmux.

## 6. Se qualcosa va storto

| Sintomo | Cosa fare |
|---|---|
| il nodo perde la rete dopo l'applicazione | non premere Invio: dopo 180 s torna da solo alla rete precedente |
| "la scheda 'X' non esiste" | nome sbagliato: usare quelli della tabella iniziale |
| `[ATTENZIONE] ... senza link` su una porta di bond1 | la porta non è collegata o abilitata sullo switch |
| `[ATTENZIONE] ... NON nello stesso aggregato LACP` | port-channel/MLAG da correggere sullo switch |
| `gateway ... NON raggiungibile` | VLAN di management non trunkata su bond0, oppure IP o gateway errati |
| vuoi ripartire da capo | i vecchi netplan sono in `/root/netplan-backup-locale-<data>/` |

# Installazione su tre server fisici — procedura completa

Valida per OpenStack v1.7 (Kolla-Ansible, Ceph cifrato, OVN, Barbican, Skyline, Masakari) su **3 server fisici** con Ubuntu 24.04 e accesso, se serve, **solo da console** (niente copia/incolla). I valori della rete (VLAN, subnet, IP) sono indicati con segnaposto: li fornisce il referente di rete e si digitano nelle domande degli script.

Ordine: A prerequisiti → B controlli sui nodi → C rete → D chiavi SSH → E topologia → F installazione → G verifiche → H test funzionali → I problemi.

## A. Da avere prima (dal referente di rete)

| Dato | Note |
|---|---|
| 5 VLAN ID | management, overlay, external, Ceph public, Ceph cluster |
| Subnet | management (+ gateway, DNS), overlay, Ceph public, Ceph cluster |
| 3 IP di management | uno per nodo |
| 1 IP libero di management | il **VIP** delle API (non assegnato a nessuno) |
| Overlay | la VLAN è solo L2, ma **ogni nodo ha un IP** in questa subnet (endpoint Geneve) |
| External | subnet pubblica, gateway, primo/ultimo IP del pool floating. La VLAN external **non ha IP sui nodi**. Se mancano, si inseriscono dopo (sezione E.3) |
| Link | entrambe le porte di `bond0` e di `bond1` con link UP, nello stesso port-channel LACP (o MLAG/vPC); VLAN trunkate; MTU di rete adeguata (9000 se prevista) |
| Disco dati | il disco per Ceph deve essere esposto al sistema come **Non-RAID / passthrough** (controller), non come volume RAID virtuale |
| Internet | uscita verso i repository (apt, pip, quay.io) dalla rete di management |

## B. Controlli sui nodi (console, su ogni nodo)

```
sudo grep -E "Slave Interface|MII Status|Aggregator ID" /proc/net/bonding/bond0
ip -br link
lsblk -d -o NAME,SIZE,TYPE,MODEL
free -g
timedatectl
```

- I due link di `bond0` devono avere lo **stesso Aggregator ID**; se sono diversi lo switch non li aggrega: chiedere la correzione al referente di rete.
- Le porte di `bond1` devono essere UP.
- `lsblk` deve mostrare il disco dati (oltre al disco di sistema). Se non compare, il disco è ancora dietro un volume RAID: va corretto sul controller.
- Il disco dati è quello **senza partizioni e senza mountpoint**; il disco di sistema è quello con `/`. I nomi (`sda`, `sdb`) possono essere invertiti rispetto al previsto o diversi da un nodo all'altro: non conta, perché il `01b` sceglie i dischi per dimensione e solo tra quelli liberi. Controllare comunque su ogni nodo che il disco libero sia quello giusto.
- Annotare i nomi delle schede (due per `bond0`, due per `bond1`).

## C. Rete (solo se i nodi non hanno già tutte le VLAN configurate)

Se su Linux c'è solo `bond0` con la VLAN di management, la rete si completa con gli script. Dettaglio in `PROCEDURA_RETE_DA_CONSOLE.md`; in sintesi:

1. **IP provvisorio** solo se il nodo non ha già un IP raggiungibile (sezione 1 di quel documento).
2. **Copiare il pacchetto** su tutti e tre i nodi in `/root` (sezione 2 di quel documento) e scompattare i due zip affiancati.
3. **node01, da console** (non da SSH):
   ```
   cd /root/OPENSTACK_deploy_*
   sudo bash configura_rete_locale.sh
   ```
   Rispondere alle domande (porte, VLAN, subnet, gateway, IP dei nodi, VIP), controllare il riepilogo, `s`. Lo script rimuove da solo le VLAN con gli stessi ID e i bond esistenti, applica la rete con rollback automatico: **entro 180 secondi premere Invio**, ma solo se il gateway risponde. Senza conferma torna alla rete precedente.
4. **node02 e node03**: copiare `topology.conf` e `ifaces.conf` da node01, poi da console:
   ```
   cd /root/OPENSTACK_deploy_*
   sudo bash configura_rete_locale.sh --usa-piano
   ```
5. **Non** impostare `LAB_MODE` su server fisici. Se per errore lo script rileva una macchina virtuale senza `LAB_MODE`, avvisa.
6. Verifiche, su ogni nodo:
   ```
   sudo grep -E "Bonding Mode|Transmit Hash|Aggregator ID|MII Status" /proc/net/bonding/bond0
   ip -br addr
   ping -c3 GATEWAY
   ping -c3 -M do -s 8972 IP_ALTRO_NODO_SU_OGNI_RETE     # solo se MTU 9000
   ```
   Bond in `IEEE 802.3ad`, un solo Aggregator ID, ping anche a 8972 byte sulle reti con MTU 9000 (overlay, Ceph).

## D. Chiavi SSH (da node01)

```
sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519_os_3node -C os-3node-deploy
sudo cat /root/.ssh/id_ed25519_os_3node.pub
```

Su **ognuno dei tre nodi** (node01 compreso), come root:

```
sudo mkdir -p /root/.ssh && sudo chmod 700 /root/.ssh
echo "ssh-ed25519 AAAA...riga stampata sopra..." | sudo tee -a /root/.ssh/authorized_keys
sudo chmod 600 /root/.ssh/authorized_keys
sudo sshd -T | grep -i permitrootlogin      # yes o prohibit-password
```

Se è `no`: correggere in `/etc/ssh/sshd_config` (o `sshd_config.d/`) e `sudo systemctl reload ssh`.

Verifica da node01 (non deve chiedere password; stampa node01/02/03):

```
for ip in IP_NODE01 IP_NODE02 IP_NODE03; do
  sudo ssh -i /root/.ssh/id_ed25519_os_3node -o StrictHostKeyChecking=no root@$ip hostname
done
```

Se si può accedere con un utente sudo da un altro nodo: `ssh -t UTENTE@IP "sudo sshd -T | grep -i permitrootlogin"`.

## E. Topologia (da node01)

### E.1 Rilevamento
```
cd /root/OPENSTACK_deploy_*
sudo bash configura_topologia.sh
```
Risposte: vedere la tabella nella guida (punto 3). Il riepilogo va fatto controllare al referente di rete. Scrive `topology.conf` e `ifaces.conf`.

### E.1a Verifica di rete tra i nodi

Dopo la rete e prima del deploy (e dopo ogni intervento sulla rete o sui cavi):

```
bash verifica_rete_nodi.sh                       # 10 ping per prova, porta 22
bash verifica_rete_nodi.sh --count 30 --porte "22 9090"
bash verifica_rete_nodi.sh --solo-fisico         # solo stato dei bond, senza ping
```

Perdita che compare solo con pacchetti grandi = MTU lungo il percorso; perdita casuale a tutte le dimensioni = bond o cavo (righe `FISICO`: errori CRC in crescita, Rx ottico basso). Esce con 1 se qualcosa non va.

### E.1b Uscita internet solo tramite proxy

Se i nodi escono su internet solo tramite un proxy (sintomi: connessioni dirette a `archive.ubuntu.com`, `quay.io`, `pypi.org` bloccate, `apt` lento o a metà, il DNS pubblico non risolve), serve questo passo **prima** del `00`/`install.sh`:

```
cd /root/OPENSTACK_deploy_*
env | grep -i proxy                                      # il proxy e' gia' in ambiente? (altrimenti: --proxy)
bash configura_proxy.sh --proxy http://IP_PROXY:PORTA --dry-run     # mostra cosa scrive, non tocca i nodi
bash configura_proxy.sh --proxy http://IP_PROXY:PORTA               # applica su tutti e tre i nodi
set -a; . /etc/environment; set +a                       # carica le variabili nella shell corrente
bash configura_proxy.sh --verify                         # prova gli endpoint del deploy via proxy, nodo per nodo
```

Lo script scrive su ogni nodo `/etc/environment` (proxy e `NO_PROXY`), `/etc/apt/apt.conf.d/95proxy` e il drop-in del daemon Docker. `NO_PROXY` contiene nodi, VIP e subnet del cluster: **è indispensabile**, altrimenti API OpenStack, Ceph e CLI passano dal proxy e non funzionano. Voci in più: `NO_PROXY_EXTRA="a,b"` in `topology.conf`. L'URL può stare in `topology.conf` come `PROXY_URL="http://IP:PORTA"`.

Limiti: il proxy non porta l'NTP (UDP 123): serve un server NTP interno (`NTP_SERVERS_CSV`) o l'apertura della porta. Se nessun server NTP è raggiungibile, `NTP_LOCAL_MASTER="node01"` in `topology.conf` fa di node01 la sorgente per gli altri due (i nodi restano allineati fra loro, che è ciò che serve a Ceph; l'ora assoluta può essere sbagliata: impostarla prima con `date -s`). Un proxy con ispezione TLS richiede di installare il certificato della sua CA sui nodi (non gestito dagli script). Con il proxy attivo il `00` controlla gli endpoint via proxy (non con connessioni dirette).

### E.2 Opzioni facoltative (prima del lancio)

- **Password**: copiare `secrets.conf.example` in `secrets.conf`, impostare `DASHBOARD_PASS` (dashboard Ceph) e `DEMO_PASS` (utente demo), `chmod 600 secrets.conf`. Minimo 8 caratteri, senza spazi né `' " \ $` e apice inverso. Se il file non c'è valgono i valori di default.
- **Server NTP**: in `topology.conf` aggiungere `NTP_SERVERS_CSV="ntp1.esempio,ntp2.esempio"` se i default pubblici non sono raggiungibili.
- **LACP rate**: default `slow` (funziona sia con switch a `slow` sia a `fast`). Se lo switch è a `fast`: `LACP_RATE=fast` in `topology.conf` prima di lanciare `configura_rete_locale.sh`.
- **Router ID VRRP**: default 51. Se nella stessa rete di management esiste già un altro VRRP con lo stesso ID (verifica: `sudo tcpdump -ni bond0 -c5 vrrp`), aggiungere in `topology.conf` `VRRP_ROUTER_ID=<1-255 libero>`.
- **Dischi Ceph** (obbligatorio se la dimensione del disco dati non è 1,7–2,1 TB, l'intervallo predefinito, altrimenti il `01b` si ferma): `sudo bash 01b_setup_ceph_3NODE.sh --discover-disks` mostra i dischi liberi di ogni nodo, si sceglie quello giusto e la scelta (finestra di dimensione) viene salvata in `osd_disks.conf` e riusata dai lanci successivi. Va fatto dopo le chiavi SSH, prima di `install.sh`. In alternativa `DATA_DISK_MIN`/`DATA_DISK_MAX` (byte).

### E.3 Rete External mancante
Se subnet/gateway/pool non ci sono ancora: Invio alle domande. Il cloud si installa senza floating IP; quando arrivano i dati: `sudo bash configura_topologia.sh` e poi `LAB_MODE=0 ./03_configure_openstack_3NODE.sh`.

### E.4 Controllo offline
```
cd /root/OPENSTACK_tests_*
bash test_render.sh </dev/null 2>/dev/null | tail -3      # FAIL=0
```

## F. Installazione (da node01, dentro tmux)

```
tmux new -s deploy
cd /root/OPENSTACK_deploy_*
export LAB_MODE=0
./install.sh --from-node
```

(In alternativa `LAB_MODE=0 ./run_all.sh --from-node`.) Non usare `sudo -E`. Durata 2-3 ore; la fase RabbitMQ può fermarsi circa 13 minuti per un recupero automatico. Se la console cade: `tmux attach -t deploy`; staccarsi con `Ctrl+B` poi `D`. Se si ferma: rilanciare lo stesso comando (i passi riusciti vengono saltati).

Alla fine compare `Catena completata` e `Horizon: http://<VIP>`.

## G. Verifiche finali (node01)

```
sudo ceph -s                                  # HEALTH_OK, 3 mon, OSD up/in
source /opt/kolla-venv/bin/activate
source /root/admin-openrc.sh
openstack compute service list
openstack hypervisor list                     # 3 hypervisor up
openstack network agent list
openstack network list                        # provider-ext presente se External definita
sudo docker ps --format '{{.Names}} {{.Status}}' | grep -vi "up" # nessuna riga = tutto up
```

Password admin: `/root/admin-openrc-password.txt`. Console: `http://<VIP>`.

## H. Test funzionali (facoltativi)

Dal pacchetto test, su node01, **come root** (`sudo -i`, perché `sudo` non passa le variabili):
```
cd /root/OPENSTACK_tests_*
DEPLOY_DIR=/root/OPENSTACK_deploy_<versione> LAB_KVM=0 LAB_MODE=0 bash 03b_functional_tests_3NODE.sh
cd acceptance && ./acceptance_test.sh --run L1,L2 --level 2
```
(ambiente `source` come in G; `DEPLOY_DIR` è la cartella del pacchetto deploy.)

## I. Problemi frequenti

| Sintomo | Cosa fare |
|---|---|
| Nodo senza rete dopo `configura_rete_locale` | non confermare: dopo 180 s torna alla rete precedente |
| `LACP NON formato` nel 00 | lato switch: port-channel/MLAG da correggere |
| Porta di `bond1` senza link | collegare/abilitare la porta sullo switch |
| Disco dati non visibile / fuori intervallo | Non-RAID sul controller; `--discover-disks`, `DATA_DISK_MIN/MAX` |
| "non risulti in tmux" | aprire tmux e rilanciare |
| "nessun IP di management locale corrisponde" | rilanciare `configura_topologia.sh` |
| "unsynchronized" | `sudo chronyc makestep; sleep 20; timedatectl`, oppure `NTP_SERVERS_CSV` |
| Download falliti (apt, pip, immagini) | uscita internet bloccata: referente di rete |
| Failover VIP instabile | possibile conflitto VRRP: `VRRP_ROUTER_ID` diverso |
| Ripartire da zero | `05_reset.sh` (vedere l'intestazione dello script) |

Per le righe `[FAIL]` che restano: inviarle a chi cura l'installazione.

### Limiti noti da riportare nel documento di consegna

- **Rilascio OpenStack.** 2025.1 (Epoxy) e' ora un rilascio "unmaintained": i pacchetti e le immagini pubblicate restano disponibili,
  ma non sono garantite nuove correzioni di sicurezza. Pianificare l'aggiornamento a un rilascio mantenuto.
- **Cold start di RabbitMQ.** Al primo avvio il primo nodo puo' impiegare oltre 10 minuti a diventare `healthy` prima che Kolla crei gli altri;
  il `02` lo gestisce (verifica del cluster e, se serve, reset dei volumi e redeploy): non interrompere.
- **NTP locale.** Con `NTP_LOCAL_MASTER` i nodi sono allineati fra loro ma non a una sorgente esterna.

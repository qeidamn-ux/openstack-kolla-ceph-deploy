# OpenStack — Changelog

## v1.0 — 2026-09-02 (release stabilizzata)

Prima release validata end-to-end: giro completo `00 → 03` in modalità hands-off
(nessun intervento manuale), con smoke test East-West superato (`OS_EASTWEST_OK`),
MTU tenant corretta (1500), RabbitMQ/Ceph/OVN/Cinder/Barbican tutti in HA e verificati.

### Corretto in questa release (rispetto ai tentativi precedenti)

- Verifica dischi del `00` flessibile: non si aspetta piu' esattamente 7 dischi da 1,7-2,1 TB. `EXPECTED_DATA_DISKS` vale `auto` (basta almeno un disco dati) o un numero esatto da ambiente; conta i dischi interi, non rimovibili, da almeno `DATA_DISK_MIN_BYTES` (100 GB) e SENZA parti montate, quindi il disco di root e' escluso anche se ha la stessa taglia. Elenca i dischi trovati. Se non ne trova, la verifica ora termina con errore e viene contata nei problemi del 00 (prima stampava solo `[FAIL]` senza fermare nulla).

- `configura_rete_locale.sh` da console: oltre alle VLAN con i nostri ID cancella anche i bond `bond0`/`bond1` esistenti prima di `netplan apply` (un bond gia' esistente non cambia modo/parametri con l'apply: restava, per esempio, con quelli degli installatori). Dopo l'apply attende fino a circa 90 s che il gateway risponda; timeout di conferma 180 s.
- NTP: default `ntp.ubuntu.com` e `0/1.ubuntu.pool.ntp.org`; sostituibili con `NTP_SERVERS_CSV` (elenco separato da virgole in `topology.conf`).
- Nuovo `secrets.conf` facoltativo (`secrets.conf.example`): `DASHBOARD_PASS` (01b) e `DEMO_PASS` (03), con controllo dei caratteri ammessi. Senza file valgono i default.
- Keepalived: router id VRRP configurabile (`VRRP_ROUTER_ID`, default 51, valore 1-255) per evitare conflitti con altri VRRP nella stessa rete.
- Banner finale di `run_all.sh` e `install.sh`: mostrano `http://<VIP>` letto dalla topologia. `04_masakari.sh`: testo sulla rete di prova allineato al `03b`.
- Supporto proxy (uscita internet solo tramite proxy): nuovo `configura_proxy.sh` (`/etc/environment`, apt e drop-in Docker su tutti i nodi, `NO_PROXY` con nodi/VIP/subnet, `--dry-run`, `--verify`); `lib_topology.sh` con `PROXY_URL`, `NO_PROXY_EXTRA`, `topo_no_proxy`; il `00` controlla gli endpoint via proxy (con proxy non usa connessioni dirette) e segnala `no_proxy` senza VIP; il `01` scrive il drop-in Docker prima dell'avvio.
- `02`: con `NTP_LOCAL_MASTER` attivo il globals.yml imposta `prechecks_enable_host_ntp_checks: "false"` (il master usa solo il proprio orologio e `timedatectl` lo vede non sincronizzato: il precheck NTP di Kolla fallirebbe su quel nodo). Senza `NTP_LOCAL_MASTER` il precheck resta attivo.
- `01` (Kolla-Ansible): se il ramo `stable/<rel>` della collezione `ansible-collection-kolla` non esiste piu' (rilascio passato a unmaintained) e `unmaintained/<rel>` si, il `requirements.yml` del venv viene corretto prima di `kolla-ansible install-deps`. Prima `install-deps` falliva con "pathspec 'stable/2025.1' did not match".
- `00`: il test jumbo (MTU 9000 fra i nodi) ora CONTA nel gate: prima un jumbo che non passava veniva solo stampato e il bootstrap risultava comunque completato. Ritenta 3 volte prima di segnare KO.
- `00`: il controllo internet via proxy ritenta fino a 3 volte ogni endpoint (con [WARN] se riesce solo al secondo/terzo tentativo): una perdita di pacchetti non genera piu' un FAIL, un blocco vero del proxy si.
- `00`: lo scarto orario fra i nodi e' misurato in modo compensato (confronto con l'orologio locale nello stesso istante, punto medio, campione a RTT minimo su connessione SSH aperta). Prima confrontava letture fatte in momenti diversi e segnalava scarti inesistenti su collegamenti lenti.
- `NTP_LOCAL_MASTER="nodeXX"` in `topology.conf` (00, fase NTP): se nessun server NTP e' raggiungibile, il nodo indicato fa da sorgente locale (`local stratum 10`, `allow` sulla subnet di management) e gli altri puntano a lui; con `NTP_SERVERS_CSV` valorizzato il master lo usa a monte e `local` resta di ripiego.
- Nuovo `verifica_rete_nodi.sh`: da node01, per ogni coppia di nodi e ogni rete misura la perdita (ping 100/1472/8972 byte con DF), controlla le porte TCP e lo stato fisico dei bond (aggregatore, errori CRC prima/dopo, potenza ottica Rx). Non modifica nulla.
- `lacp-rate` di default `slow` (compatibile con lo switch a slow o fast); `LACP_RATE=fast` in `topology.conf` per cambiarlo.
- Procedura baremetal: chiarito che il disco dati e' quello libero (senza partizioni ne' mountpoint) anche se `sda`/`sdb` sono invertiti, e che `--discover-disks` e' obbligatorio se la taglia non e' nella finestra 1,7-2,1 TB.
- Nuova `PROCEDURA_INSTALLAZIONE_BAREMETAL.md`: procedura completa generica per i tre server fisici; `PROCEDURA_RETE_DA_CONSOLE.md` e guida di supporto aggiornate.
- Validato in lab KVM (3 VM con solo `bond0`+management, `lab_create_vms.sh --scenario-reale`): rete, chiavi, topologia, installazione completa e `03b` superati. Non verificabili in lab: LACP/MLAG reale, MTU della rete fisica, nomi delle schede, controller RAID.

- `configura_rete_locale.sh` su una VM senza `LAB_MODE=1` (es. variabili perse aprendo una nuova shell): avvisa e chiede conferma prima di creare bond 802.3ad, che in lab non funzionano. In `--dry-run` non chiede nulla.
- Lab con VM esistenti (`LAB_MODE=1 LAB_KVM=0`): i bond ricreati da `configura_rete_locale.sh` usano il MAC permanente della prima porta (`BOND0_MAC`/`BOND1_MAC`, letti con `ethtool -P` e usati da `generate_netplan` del 00). Senza, systemd assegna un MAC proprio e il filtro anti-spoofing di libvirt scarta i frame in uscita (la VLAN non risponde). Sul ferro non viene impostato nulla. Test: 120.
- `configura_rete_locale.sh` rispetta `LAB_MODE`: carica il piano con `LAB_MODE=0` (niente default da lab) ma, se l'operatore ha esportato `LAB_MODE=1`, i bond sono active-backup come nel resto della catena (prima restavano sempre 802.3ad anche in lab, dove i bridge Linux non negoziano LACP). Test in `test_render.sh`.
- `configura_rete_locale.sh`: non usa piu' `netplan try` (rifiuta di partire se un bond ha parametri: "reverting custom parameters for bridges and bonds is not supported"; trovato nel lab con bond active-backup, vale anche per l'802.3ad sul ferro). Ora arma un rollback con timer systemd, applica con `netplan apply` e chiede Invio per confermare entro `TRY_TIMEOUT` (default 180 s); senza conferma ripristina i vecchi netplan. Da console toglie da solo le VLAN preesistenti con i nostri ID sui nostri bond (es. quella degli installatori), che prima andava tolta a mano.

- Nodi consegnati SENZA rete completa (solo `bond0`, nessuna VLAN/IP) e accessibili solo da console: nuovo `configura_rete_locale.sh`, da lanciare su ogni nodo. Elenca le schede (nome/link/velocita'), chiede porte, VLAN ID, subnet, IP dei 3 nodi, gateway e VIP, genera il netplan con la stessa `generate_netplan` del 00, applica con `netplan try` (ritorno automatico), imposta l'hostname, controlla bond (link, aggregato LACP unico), IP e gateway, e scrive `topology.conf`/`ifaces.conf`. `--usa-piano` per i nodi 2 e 3, `--dry-run` per provare senza toccare. Procedura per la console in `PROCEDURA_RETE_DA_CONSOLE.md`. Non provato su hardware: solo in `--dry-run` nel gate (5 controlli, 116 totali); `netplan try` e il passaggio dall'IP provvisorio alla configurazione finale vanno verificati sul primo nodo.

- Rete External: subnet, gateway e pool di floating IP non sono piu' cablati nel `03`. `configura_topologia.sh` li chiede (facoltativi, con controllo di coerenza: gateway e pool nella subnet, gateway fuori dal pool) e li scrive in `topology.conf`; una variabile d'ambiente ha la precedenza. Se non sono definiti il `03` NON crea la rete `provider-ext` e lo segnala; se la rete esiste con una subnet diversa da quella configurata avvisa invece di dire "gia' presente". Rimossi dai file i riferimenti a valori e termini specifici dell'infrastruttura.

- Collaudo (`acceptance_test.sh`): se `openstack` non e' nel PATH attiva da solo il venv Kolla (`KOLLA_VENV`) e, se manca ancora, lo dice con il comando da lanciare; la documentazione ora riporta `source /opt/kolla-venv/bin/activate` prima dell'openrc.- Ricerca del pacchetto gemello (`test_render.sh`, `03b`, `run_all.sh`, `install.sh`): considera solo le cartelle, non lo zip `OPENSTACK_*_v1.7_*.zip` accanto ad esse (prima poteva sceglierlo e dichiarare il pacchetto "non trovato").

- **Ceph**: immagine container pinnata alla versione del pacchetto host (evita
  keyring illeggibili per mismatch di versione); recupero dei daemon dopo un
  riavvio di Docker tramite `reset-failed` + restart delle singole istanze
  systemd (non del solo `ceph.target`, che risulta un no-op se già attivo).
- **RabbitMQ**: la formazione del cluster a freddo richiede un redeploy con i
  tag `common,haproxy,rabbitmq` — non `rabbitmq` da solo, che non genera la
  directory HAProxy né la lista dei peer in `rabbitmq.conf`. Safeguard
  automatica nel `02` (`ensure_rabbitmq_cluster`) con timeout e retry.
- **OVN**: i chassis devono registrarsi con hostname CORTO, coerente con
  l'host id usato da Nova per il binding delle porte; un alias FQDN in
  `/etc/hosts` causa `PortBindingFailed`. Fix sia alla radice (cloud-init del
  lab, hostname corto) sia come safeguard nel `02`
  (`ensure_ovn_chassis_shortname`).
- **MTU tenant**: `neutron_global_physnet_mtu` nel `globals.yml` non risulta
  propagata a `neutron.conf` da Kolla 2025.1; serve un override esplicito
  (`/etc/kolla/config/neutron.conf`) accanto a quello ml2 esistente.
- **Cinder HA**: backend Ceph con `cinder-volume` su più nodi richiede un
  coordinatore (redis, switchabile a valkey) e un `cinder_cluster_name` fisso.
- **Reservation Nova**: calcolata e CLAMPATA sulla RAM/CPU reali del nodo a
  runtime, non su costanti — un valore superiore alla capacità fisica azzera
  l'inventario Placement e blocca lo scheduling (`NoValidHost`) senza errori
  espliciti.
- **Virtualizzazione (LAB_MODE)**: rilevamento automatico di `/dev/kvm` sui
  compute, uso di KVM accelerato quando disponibile invece di QEMU emulato.
- **Banner TUI** (`install.sh`): corretto il calcolo del riempimento delle
  righe con codici colore ANSI incorporati (bordo destro disallineato).

### Debiti tecnici noti (vedi LLD, sez. 8)

- TLS disabilitato sulle API (interno/esterno).
- Barbican in `simple_crypto`; produzione: HSM/Vault.
- Coordinatore Cinder: redis in lab; valkey raccomandato in produzione.
- Controller storage RAID in Non-RAID; produzione: HBA nativo.
- Piano di rete con VLAN ID/indirizzamenti "DA CONFERMARE" (valori reali dello switch).

### Documenti collegati

- `LLD_OpenStack.docx` — Low Level Design (architettura, rete, HA, roadmap).

## v1.1 — 2026-09-09 (documentazione baremetal + hardening LAB_MODE)

### Aggiunto
- README: sezione "Uso su BAREMETAL" completa (prerequisiti, --discover,
  compilazione BOND_IFACES, sequenza 00→03, verifica periodica) — mancava
  del tutto nella v1.0, che documentava solo il flusso lab.

### Corretto (sicurezza)
- `install.sh` e `run_all.sh`: rimosso il fallback silenzioso
  `LAB_MODE="${LAB_MODE:-1}"`. Un lancio su hardware reale senza
  `export LAB_MODE=0` esplicito ereditava impostazioni da laboratorio
  (bond active-backup invece di LACP 802.3ad, reservation Nova ridotta)
  senza alcun avviso. Ora entrambi gli script si RIFIUTANO di partire se
  `LAB_MODE` non è impostato esplicitamente a 0 o 1, con messaggio chiaro.
  `lib_topology.sh` non necessitava fix: il suo fallback era già nella
  direzione sicura (0 = ferro).

## v1.2 — 2026-09-25 (dischi OSD rilevati automaticamente)

### Aggiunto
- `01b`: analisi dei dischi di ogni nodo prima di creare il cluster Ceph
  (sola lettura). Classifica ogni disco: libero, già OSD, sistema/BOSS, con
  dati, troppo piccolo. Se i dischi attesi (SSD ~1,92 TB) non ci sono su tutti
  i nodi, propone i gruppi di dischi liberi uguali sui tre nodi (flash prima,
  poi capacità) con la capacità utile stimata, e chiede quale usare.
- `01b --discover-disks`: solo analisi e scelta, non tocca Ceph né i dischi.
- La scelta viene salvata in `osd_disks.conf` (priorità: variabili
  d'ambiente > file > default), così vale anche per `run_all.sh`/`install.sh`.
- `install.sh`: con `LAB_MODE=0` il banner non mostra più le fasi solo-lab.

### Corretto (sicurezza dati)
- I dischi con partizioni o filesystem esistenti non vengono più selezionati
  come OSD (prima, se erano nella finestra di dimensione, il retry poteva
  fare uno zap automatico). Ora servono solo con `--zap-osd` esplicito.
- README: sezione baremetal riscritta nella parte iniziale — da quale macchina
  si lanciano gli script, cosa le serve (in particolare la raggiungibilità
  della rete di management dopo il cutover, senza la quale il `00` fa
  rollback), prerequisiti dei nodi (utente sudo NOPASSWD, uscita diretta verso
  internet, proxy non gestito), verifica del primo contatto. Corretti l'avviso
  obsoleto su `LAB_MODE` e i comandi della sezione lab.

## v1.3 — 2026-09-25 (cutover con lo stesso IP di management)

Caso reale: l'installazione mette già i nodi sull'IP di management
definitivo, su una scheda singola; il cutover deve solo creare bond e VLAN,
senza cambiare indirizzo. Il `00` era scritto per un cambio di IP e in questo
caso sbagliava in due punti.

### Corretto (sicurezza)
- `00`: il controllo "serve il cutover?" guardava solo se il nodo rispondeva
  sull'IP di management. Con lo stesso IP risponde fin dall'inizio, quindi il
  cutover veniva SALTATO (niente bond, niente VLAN). Ora controlla lo stato
  reale: l'IP deve stare sulla VLAN di management sopra bond0.
- `00`: la conferma che disarma il rollback aveva lo stesso difetto. Con lo
  stesso IP il nodo rispondeva PRIMA che la nuova rete fosse applicata, il
  rollback veniva disarmato troppo presto e una configurazione sbagliata
  avrebbe lasciato il nodo irraggiungibile. Ora si conferma solo quando l'IP
  risponde sulla VLAN nuova.
- `00`: se un lancio precedente si era interrotto prima della conferma, il
  rollback ancora armato viene disarmato al rilancio.
- `00`: dopo l'applicazione il nodo fa un ping al gateway, così lo switch
  aggiornano subito la posizione dell'IP passato dalla scheda al bond.

### Corretto (pacchetto)
- v1.1 e v1.2 contenevano per errore il `00` con i nomi di scheda del lab
  (`e0a e0b`) al posto dei segnaposto `REPLACE_*`: `run_all.sh` in modalità
  lab riscriveva il `00` con `sed` e il file modificato è finito nel pacchetto.
  Ora il `00` sceglie da solo i nomi del lab quando `LAB_MODE=1` e nessuno
  script modifica più altri file.

### Cambiato
- `TEMP_IPS` è vuoto di default: sul ferro significa "stesso IP di management".
  Si compila solo se l'installazione usa una rete diversa. In lab restano gli
  IP della rete di provisioning.
- README: tolti i riferimenti agli "IP temporanei"; aggiunta la spiegazione di
  cosa cambia al cutover e cosa serve lato switch (porta singola non
  sospesa prima del bond, VLAN di management taggata dopo).

## v1.4 — 2026-09-25 (lab su VMware / VM già esistenti)

### Aggiunto
- `LAB_KVM` (default = `LAB_MODE`): separa le taglie da lab (bond
  active-backup, 1 OSD per nodo, RAM riservata ridotta, rilevamento KVM) dal
  lab KVM creato dagli script (IP 192.168.99.x, schede e0a/e0b, creazione VM).
  Con `LAB_MODE=1 LAB_KVM=0` si usa un lab su VM già esistenti (es. VMware):
  IP e schede come sul ferro, taglie da lab. Nel lab KVM non cambia nulla.
- README: sezione "LAB su VMware" con la preparazione lato vSphere (schede,
  port group in trunk, sicurezza, MTU, virtualizzazione annidata, dischi,
  snapshot) e i requisiti del PC da cui si lancia.

### Corretto
- `00`: la verifica finale controllava le VLAN con nomi scritti a mano
  (vlan10…vlan50). Con VLAN ID diversi da quelli del lab avrebbe cercato
  interfacce inesistenti. Ora usa i VLAN ID di `lib_topology.sh`.

## v1.5 — 2026-10-08

### Aggiunto
- `04_masakari.sh`: Masakari (Instance HA), Fase A, senza fencing. Abilita
  `enable_masakari`, adatta l'inventory alla topologia (3 nodi: tutti membri pieni
  del cluster Corosync, `[hacluster-remote]` vuoto, `restrict_to_remotes=false`;
  6/9 nodi: default Kolla), fa il deploy con `--tags common,haproxy,hacluster,masakari`,
  verifica quorum/nodi/API/monitor, registra segmento e host, stima la capacità.
  Test: `--test-instance` (kill qemu) e `--watch` (guasto nodo guidato).
- Sul ferro il `04` richiede `--accept-no-fencing` (Kolla forza `disable_ipmi_check=true`).
- `run_all.sh` / `install.sh`: fase 04 opzionale con `ENABLE_MASAKARI=1` (lanciata dopo il 03).
- `test_render.sh`: 14 controlli in più (49 in tutto): flag Masakari nel globals,
  modalità per fase 3/6/9, patch dell'inventory (idempotenza, ritorno al control isolato).

### Corretto
- `02`: rigenerando il `globals.yml` non spegne più `enable_masakari` se il `04`
  l'ha già abilitato (si conserva il valore presente). Nessuna variabile
  d'ambiente lo forza a `yes` dal `02`: con l'inventory non adattato il deploy fallirebbe.
- `test_render.sh`: lo stub `ssh_dep` rispondeva "ok" a qualunque comando, quindi
  un controllo su `globals.yml` esistente non poteva mai fallire.

## v1.5.1 — 2026-10-08

### Corretto
- `04`: la stima di capacità dava sempre `[OK]` con 0 MB. Usava `hypervisor list
  --long`, che nelle versioni recenti di OpenStack non riporta più la memoria,
  e `0 <= 0` passava. Ora somma la RAM dei flavor delle VM per nodo e la confronta
  con `MemTotal - reserved_host_memory_mb` degli altri nodi (senza overcommit).
  Se i dati mancano, segnala "non disponibile" invece di un falso via libera.

### Verificato sul lab (3 nodi iperconvergenti, KVM)
- `04` completo al primo giro: container, quorum Corosync (3 nodi), Pacemaker (3 online),
  API sul VIP, `restrict_to_remotes=false`, segmento e 3 host registrati.
- Dopo uno spegnimento brusco dell'intero lab: `kolla-ansible mariadb-recovery`
  (nome con trattino) ricompone Galera; poi vanno riavviati i container API
  (`placement_api`, `nova_*`, `cinder_api`) rimasti con connessioni al DB morte.


## v1.5.2 — 2026-10-08 (solo documentazione)

### Documentazione

- README: nuova sezione "Spegnimento e riaccensione del cluster (MariaDB Galera)":
  procedura prima/dopo lo spegnimento (noout, ordine di stop, `mariadb-recovery`,
  restart dei container API, verifica Galera/Ceph/servizi) e riabilitazione di
  nova-compute dopo un evacuate Masakari. Nessuna modifica agli script.

## v1.6 — 2026-10-08

### Aggiunto
- `05_reset.sh`: reset/redeploy a tre livelli (`openstack`, `ceph`, `all`), con `--dry-run`,
  `--wipe-pools`, `--new-passwords`, `--purge-images`. Conferma scritta sul ferro, fotografia
  dello stato prima di distruggere, azzeramento limitato ai dischi che erano OSD, Ceph
  smontato dopo OpenStack e il nodo di deploy per ultimo. Non tocca rete, utenti, chiavi, Docker.
- `test_render.sh`: 11 controlli in piu' (60 in tutto) su guardie, dry-run non distruttivo,
  ordine dei passi e livello `openstack` che non tocca Ceph.
- README: sezione "Reset e redeploy"; numero dei test aggiornato.

### Non provato
- L'intero `05` su macchine vere (solo ssh simulato). `01b` rilanciato su un Ceph attivo dopo
  `--wipe-pools` e' coerente con l'idempotenza dichiarata ma non l'abbiamo eseguito.

## v1.6.1 — 2026-10-13

### Aggiunto
- Skyline (richiesta dell'infrastruttura): `02` genera `enable_skyline: "yes"` di default, con
  `ENABLE_SKYLINE=no` per spegnerlo; Horizon resta attivo. Console `VIP:9999`, API `VIP:9998`.
  `02` e `03` verificano che la console risponda; il riepilogo del `03` mostra l'URL.
- `test_render.sh`: 5 controlli in piu' (65 in tutto): default yes, chiave unica, `no` rispettato,
  valore non valido -> yes, Horizon ancora attivo.
- README: sezione "Skyline" (porte da aprire, abilitazione su cluster gia' deployato, nota Masakari).

### Non provato
- Il deploy di Skyline su macchine vere e la disponibilita' delle immagini 2025.1 nel registro.

## v1.7 — 2026-10-15

### Aggiunto
- `01b`: **OSD cifrati a riposo** (dm-crypt/LUKS) di default (`OSD_ENCRYPT=yes`, `no` per spegnere;
  valore non valido -> yes). Gli OSD si creano con uno spec cephadm per nodo (`osd_enc_<nodo>`,
  `encrypted: true`, dischi scelti, cumulativo fra le ri-esecuzioni) al posto di `daemon add osd`.
  Prerequisiti `cryptsetup` + `dm_crypt` (persistente) su tutti i nodi; `verify_osd_encryption`
  controlla che ogni disco abbia un mapping `crypt` e ferma lo script se uno e' in chiaro.
- `test_render.sh`: 10 controlli in piu' (75 in tutto): default e validazione di `OSD_ENCRYPT`, spec
  OSD (YAML, `encrypted`, device, host), cicli su fd 3, verifica cifratura (ok / disco in chiaro / off).
- README: sezione "Cifratura degli OSD Ceph" e debito tecnico (KMS esterno per le chiavi LUKS).

- **Lancio da un nodo del cluster** (es. console web di node01, senza host esterno con SSH):
  `lib_topology.sh` riconosce se lo script gira su un nodo (`SELF`, dall'IP di management locale).
  `00` e `05` da un nodo SENZA `--from-node` si rifiutano di partire (il cutover farebbe cadere la
  sessione; il reset ripulirebbe il nodo di lancio); `05 --dry-run` resta ammesso. Con `--from-node`:
  `00` salta il cutover (chiavi + NTP + verifiche) e controlla che tutti i nodi siano gia' su
  bond+VLAN; `05` accetta il nodo di lancio fra quelli ripuliti, rifiuta un pacchetto che sta in una
  cartella cancellata dal reset (`/etc/kolla`, `/var/lib/{docker,ceph}`, venv) e avvisa se non c'e' tmux/screen.
  `run_all.sh --from-node` (e `install.sh`, che lo inoltra) passa il flag al `00` e non crea VM.
  `--from-node` su un host esterno e' un errore. `test_render.sh`: 11 controlli in piu' (88); poi 9 sui nomi delle interfacce (97) e 8 sul piano IP (105; poi 6 sulla rete External, 111; poi 5 su configura_rete_locale, 116).

- **Octavia (LBaaS) con solo provider OVN**, aggiungibile a un cloud gia' installato: nuovo `06_octavia.sh`
  (sul modello del `04`, a cloud sano; `--config-only`, `--verify`, `--test-lb`). Scrive nel globals
  `enable_octavia: "yes"`, `octavia_provider_drivers: "ovn:OVN provider"`, `octavia_provider_agents: "ovn"`
  e l'override `/etc/kolla/config/octavia.conf` con `default_provider_driver = ovn` (Kolla imposta solo i
  driver abilitati: senza override il default di Octavia resta `amphora` e `loadbalancer create` senza
  `--provider` fallisce). Deploy `--tags common,haproxy,horizon,octavia` (+`skyline` se attivo), installa
  `python-octaviaclient`, verifica container/API (porta 9876)/provider e prova un LB TCP su `os-test-net`.
  Con solo `ovn` nei driver Kolla spegne `octavia_auto_configure` e i controlli sui certificati: niente
  `lb-mgmt-net`, VLAN, immagine amphora, flavor o certificati. Limiti: solo L4, algoritmo `SOURCE_IP_PORT`,
  niente HTTP/L7 ne' terminazione TLS. Password: controlla `octavia_*` in `passwords.yml` e, se mancano,
  indica `kolla-genpwd` (chiave vuota) o `kolla-mergepwd` (chiave assente: `kolla-genpwd` non aggiunge chiavi).
- `02`: `octavia_flag()` conserva `enable_octavia` ai rilanci (come `masakari_flag`); le chiavi provider OVN
  sono scritte sempre. `run_all.sh`/`install.sh`: fase opzionale `ENABLE_OCTAVIA=1` dopo il `04`. `05`: la
  ripartenza indica il `06`.
- `test_render.sh`: 13 controlli in piu' (190): enable_octavia iniziale/conservato/non forzabile, driver solo
  OVN, override INI, scrittura idempotente delle chiavi, tag del deploy, aggancio a run_all/install/05.
  Collaudo: LBA-01..04 adattati al provider OVN (provider `ovn`, `--provider ovn`, listener TCP con
  `SOURCE_IP_PORT`, failover SKIP se il provider non e' amphora).

### Corretto
- `install.sh`: l'auto-elevazione con `sudo` perdeva `ENABLE_MASAKARI`/`MASAKARI_ACCEPT_NOFENCING` (sudo
  azzera l'ambiente): lanciato da utente normale, il `04` non partiva mai. Ora le passa insieme a `ENABLE_OCTAVIA`.
- `run_all.sh`: con il gate offline fallito il messaggio diceva "correggi lib_topology.sh" anche per errori
  altrove; ora rimanda a `test_render.log` e alle righe [FAIL].
- Pacchetto TEST, `acceptance/` (falsi PASS nel collaudo, nessuna modifica al deploy):
  - `tests/50_resilience.sh`: dopo un'attesa (`wait_for`, `wait_node_up`, `wait_cluster_back`) il
    controllo usava `last_rc0`, cioe' il codice dell'ultimo comando con evidenza (il `reboot` o il
    `power on`), non quello dell'attesa: "il nodo rientra", "API Keystone raggiungibili", "servizi
    tornano senza intervento", "nova-compute up" risultavano OK anche ad attesa scaduta (RES-03, RES-09,
    HA-10, MSK-12). Ora il controllo e' l'attesa stessa; HA-10 elenca i nodi non rientrati. Stesso
    difetto in OPS-05 (porte API sul VIP).
  - `kolla-ansible ... | tail`: il codice di uscita era quello di `tail` (sempre 0). Aggiunto
    `set -o pipefail` a `reconfigure` (OVN-12, OPS-01), `mariadb_backup` (OPS-02) e al `00 --verify-only` (OPS-05).
  - Sonda API a 1 Hz (RES-02, RES-04, criterio C3): contava come fallimento solo `000`; ora ogni
    risposta diversa da 2xx/3xx (quindi anche il 503 del bilanciatore senza backend). Una sonda senza
    campioni non passa piu'. Soglia invariata: al massimo 3 fallimenti.
  - Interruzione a meta' scenario (Ctrl-C/TERM): il runner ferma la sonda API in background (prima
    restava attiva) e invia al BMC l'accensione dei nodi spenti dallo scenario in corso (prima restavano
    spenti); non ne attende il rientro. Se le API non rispondono la pulizia e' rimandata a
    `--cleanup <run-id>` (prima falliva e l'elenco delle risorse veniva archiviato come gia' pulito).
  - `configurazione_usata.txt` (nel pacchetto del verbale): valori di `BMC_HOSTS` e `IPMI_USER`
    sostituiti da `<omesso>`.
  - `acceptance.conf.example`: i valori attesi dell'hardware (`EXP_SOCKETS`, `EXP_CORES_PER_SOCKET`,
    `EXP_RAM_GB`, `EXP_DISKS`, `EXP_DISK_GB`, `EXP_USABLE_TB`, `EXP_LINK_GBPS`) sono vuoti: si compilano
    solo in `acceptance.conf` sul campo. Con un valore vuoto il controllo relativo (HW-01, HW-02, HW-07,
    NET-06, CEPH-09, CMP-02) e' saltato e annotato (nuovo `chk_exp`); un test con solo quei controlli
    risulta SKIP e il criterio C1 resta INCOMPLETO. All'avvio su `baremetal` il runner elenca le
    variabili da configurare. `selfcheck.sh`: un controllo in piu' (11) sui valori vuoti nell'esempio.
  - SSH del runner verso i nodi: `StrictHostKeyChecking=accept-new` con un `known_hosts.<run-id>`
    nella cartella dei risultati (prima `no` con `/dev/null`): la chiave dell'host e' accettata al primo
    contatto e poi verificata. Se un nodo viene reinstallato e si riusa lo stesso `--run-id`, eliminare quel file.
  - Pool Ceph temporaneo (CEPH-08 e pulizia): `mon_allow_pool_delete` torna al valore che aveva prima
    (prima veniva sempre lasciato a `false`); l'esito di "pool temporaneo rimosso" e' quello della cancellazione.
  - `selfcheck.sh`: i marcatori `## DAVE` sono contati in tutti i file del collaudo (runner, libreria,
    esempio di configurazione, strumenti), anche con il commento sulla riga di apertura.
  - `sc_rolling`: rimossa la variabile inutilizzata `note_all`.
  - Rete External non ancora configurata: nuovo `HAVE_EXTERNAL=auto|yes|no` in `acceptance.conf`
    (`auto` = configurata se `EXT_CIDR` del collaudo o `EXT_SUBNET_CIDR` della topologia e' valorizzato).
    Con `no` OVN-10 e OVN-11 (nuovo tag `extnet`) non vengono eseguiti e risultano `LIMITE`: restano
    nel verbale fra i limiti noti e fuori dal criterio C1 (prima erano SKIP e C1 restava INCOMPLETO).
    Il runner lo segnala all'avvio e in `ambiente.txt`. NET-02/NET-03 invariati (l'interfaccia VLAN
    External sui nodi esiste comunque), NET-12 e SCR-01 invariati.
  - Blocchi per il copia/incolla: in `tests/*.sh` ogni test (158) e ogni scenario (6) e' racchiuso tra
    `# >>>>>> INIZIO TEST <ID>` e `# <<<<<< FINE TEST <ID>` (`SCENARIO <nome>` per gli scenari), con
    livello, classe, comando previsto e risultato atteso presi dal catalogo. Nuovo
    `./acceptance_test.sh --shell`: shell con il collaudo caricato in cui un blocco incollato viene
    eseguito (riga `fine_test <ID>` / `fine_scenario <nome>`, senza effetto nel runner normale), con le
    stesse protezioni (`--intrusive`, `--destructive`, `--heavy`, conferma `SI`, Ceph `HEALTH_OK`);
    all'uscita pulizia e verbale. Nuovo `--show <ID>`: stampa il blocco. `selfcheck.sh`: un controllo
    in piu' (12) sulla presenza dei blocchi.
  - Verifica solo offline (comandi simulati): non provato su un cluster.
- `00`: il netplan di EMERGENZA del cutover usava `ip route get <IP del nodo>`, che sul nodo stesso
  risponde `dev lo`: l'emergenza ripristinava 127.0.0.1. Ora l'interfaccia e' quella che porta l'IP
  (il rollback sui netplan salvati funzionava gia', ma senza backup il nodo sarebbe rimasto senza rete).
- `01b`: i cicli sui dischi chiamavano `ssh` (senza `-n`) dentro `while read ... <<< "$devs"`: ssh
  consuma lo stdin e dopo il primo disco il ciclo terminava. Con 7 dischi/nodo sul ferro solo il primo
  veniva elaborato (nel lab, con 1 disco/nodo, non si vedeva). Ora i dischi si leggono da fd 3.
- `test_render.sh`: i test di `verify_osd_encryption` usavano un `node_exec` finto con `cat` che,
  su un terminale interattivo, aspettava la tastiera: il gate sembrava bloccato dopo il test sui
  cicli fd 3. Ora girano con stdin=/dev/null.
- `install.sh`: il banner conteneva ancora il nome di un'organizzazione (lettere spaziate, sfuggito
  alla pulizia precedente): ora e' neutro.
- `README.md`: aggiunto il riferimento alla licenza GPL-3.0 (`LICENSE`). Riallineati `CHECKSUMS.sha256`
  e gli zip dei due pacchetti: il checksum del README non tornava e `LICENSE` non era incluso nello
  zip del deploy. Rimosso `invia.txt` (bozza di messaggio, non parte del pacchetto).

### Struttura
- La suite si distribuisce in DUE pacchetti, stessa release: **deploy** (lib, 00, 01, 01b, 02, 03,
  04, 05, run_all, install) e **test funzionali** (test_render, lab_create_vms, 03b).
- Il `03` ora fa solo la configurazione del cloud (openrc, rete external, progetto demo, flavor,
  keypair, regole del security group). Verifiche di piattaforma, Barbican, Skyline, smoke test
  East-West e volume Ceph sono nel nuovo `03b_functional_tests_3NODE.sh` (stesso codice, spostato).
- `run_all.sh` / `install.sh`: i test sono opzionali (pacchetto cercato in `$TESTS_DIR`, nella
  cartella corrente, in `../OPENSTACK_tests_*`); `RUN_FUNCTIONAL=0` salta il `03b`.
- `test_render.sh` cerca il deploy in `$DEPLOY_DIR` o in `../OPENSTACK_deploy_*`; 116 controlli (77 + 11 sul lancio da un nodo + 9 sui nomi delle interfacce + 8 sul piano IP).

### Lab KVM allineato al flusso reale
- Le VM del lab nascono come le consegna il team di installazione: IP di management sulla VLAN 10,
  `bond0`/`bond1` e VLAN 10/20/30/40/50 gia' configurati (netplan via cloud-init). Nessun IP temporaneo:
  `TEMP_IPS` resta vuoto anche con `LAB_KVM=1`. La NIC `prov` resta solo come accesso di servizio.
- Il bond usa il MAC della sua prima NIC (il filtro anti-spoofing di libvirt scartava i frame del bond);
  corretto anche nel netplan generato dal `00` quando `LAB_KVM=1`.
- `run_all.sh`: l'attesa SSH dopo la creazione delle VM usa gli IP di management.
- **Piano IP da file**: nuovo `configura_topologia.sh` (sola lettura sui nodi, anche senza SSH con `--facts` /
  `--facts-dir`): rileva IP, prefissi, VLAN ID, gateway, DNS e nomi delle interfacce, chiede il VIP e scrive
  `topology.conf` + `ifaces.conf`. `lib_topology.sh` legge `topology.conf` (IP per nodo e per rete, non piu'
  vincolati a "stesso ultimo ottetto" e /24; prefissi e CIDR Ceph configurabili). `00` (netplan, jumbo, riepilogo),
  `02` e il collaudo `acceptance/` usano gli IP per nodo dalla topologia.
- **Nomi di bond e VLAN parametrizzabili**: `lib_topology.sh` definisce `IF_BOND0/1`, `IF_MGMT`, `IF_OVERLAY`,
  `IF_EXT`, `IF_CEPHPUB`, `IF_CEPHCLU` (default `bond0/bond1/vlan<ID>`; precedenza: ambiente > `ifaces.conf` >
  default). Li usano il `00` (netplan, verifiche, controllo `--from-node`), il `02` (interfacce Kolla) e il
  collaudo `acceptance/`. Nuovo `00 --detect-ifaces` (e rilevamento automatico con `--from-node`): legge dai nodi
  i nomi reali, controlla che siano uguali su tutti e li salva in `ifaces.conf`.
- `00`: nuova fase `phase_hosts` — hostname e `/etc/hosts` (tutti i nodi) vengono scritti sempre, anche con
  bond/VLAN gia' configurati o con `--from-node`; prima stavano solo nel cutover e i prechecks Kolla/RabbitMQ
  fallivano con "getent ahostsv4 node02".
- `00`: l'attesa NTP ripete `makestep` finche' `timedatectl` dice "synchronized: yes".

### Invariato
- Skyline era gia' attivo di default dalla v1.6.1 (`enable_skyline: "yes"`, console `VIP:9999`).

### Non provato
- `06_octavia.sh`: verificato solo offline (sintassi, generatori, override, tag). Deploy, verifica e LB di
  prova non eseguiti su un cloud reale. Nel collaudo LBA-03 la raggiungibilita' del VIP OVN dal namespace
  `ovnmeta` va confermata sul campo.
- `configura_topologia.sh`: verificato solo offline (fatti simulati, un piano 172.20.x con /23 e ottetti diversi).
  Mai eseguito su nodi reali con `ip` vero e SSH reale; la lettura via SSH dei nodi non e' stata provata.
- Il rilevamento dei nomi di bond/VLAN (`--detect-ifaces`): verificato solo offline, con un `ip` finto che
  imita nomi liberi; mai eseguito su nodi con interfacce rinominate. Su VM del lab (nomi standard) e' quello
  che e' girato nella prova `--from-node`.
- Il lancio da un nodo con `--from-node`: provato nel lab KVM con `run_all.sh --from-node` da node01 (VM gia'
  su bond+VLAN): catena `00 -> 03b` completata, smoke test East-West e volume Ceph superati. Resta NON provato
  il `05_reset.sh --from-node` e l'esecuzione su ferro reale.
- La creazione degli OSD cifrati su Ceph/dischi veri: lo spec e il flusso sono verificati solo offline
  (generatore, YAML, ssh simulato). In particolare il riconoscimento `crypt` di `lsblk` va confermato
  sul primo nodo reale: se il controllo fosse un falso negativo, `OSD_ENCRYPT=no` lo salta.
- La separazione in due pacchetti: il `03` ridotto e il `03b` sono verificati solo offline (sintassi,
  funzioni e variabili coerenti con l'originale, rilevamento del pacchetto test); `run_all.sh`/`install.sh`
  con i due pacchetti non sono stati eseguiti su un lab vero.

# mam-bonus-manager

Script Bash ottimizzato per gestire automaticamente i seedbonus di MyAnonamouse:

- verifica o ricrea la sessione usando `MAM_ID`;
- legge i punti seedbonus correnti;
- compra wedge a intervalli configurabili;
- opzionalmente estende/acquista VIP;
- compra upload bonus a pacchetti, senza scendere sotto il buffer configurato;
- evita esecuzioni parallele con `flock`;
- supporta `--dry-run` per test sicuri;
- tiene segreti e cookie fuori dal repository.

## Installazione rapida

```bash
sudo mkdir -p /etc/mam-bonus-manager /opt/MAM
sudo cp config/config.env.example /etc/mam-bonus-manager/config.env
sudo nano /etc/mam-bonus-manager/config.env
sudo chmod 600 /etc/mam-bonus-manager/config.env
sudo chmod 700 /opt/MAM
chmod +x mam-bonus-manager.sh
./mam-bonus-manager.sh --dry-run
```

Dipendenze:

```bash
sudo apt update
sudo apt install -y curl jq util-linux findutils
```

## Configurazione

Il file reale va tenuto fuori da git:

```text
/etc/mam-bonus-manager/config.env
```

Variabili principali:

| Variabile | Default | Significato |
| --- | ---: | --- |
| `MAM_ID` | obbligatoria | valore del cookie `mam_id` |
| `WORKDIR` | `/opt/MAM` | directory per cookie, lock e stato |
| `BUFFER` | `55000` | punti da conservare prima di comprare upload |
| `VIP` | `0` | `1` abilita acquisto VIP |
| `WEDGE_HOURS` | `4` | intervallo wedge; `0` disabilita |
| `WEDGE_RESERVE_AFTER` | `5000` | punti minimi da lasciare dopo wedge |
| `UPLOAD_PACKS` | `100 20 5 1` | pacchetti upload da acquistare |

## Uso

```bash
./mam-bonus-manager.sh --dry-run
./mam-bonus-manager.sh run
./mam-bonus-manager.sh check-session
./mam-bonus-manager.sh points
```

Con config alternativa:

```bash
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh --dry-run
```

## Systemd timer

```bash
sudo cp mam-bonus-manager.sh /usr/local/bin/mam-bonus-manager
sudo chmod +x /usr/local/bin/mam-bonus-manager
sudo cp systemd/mam-bonus-manager.service /etc/systemd/system/
sudo cp systemd/mam-bonus-manager.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mam-bonus-manager.timer
systemctl list-timers mam-bonus-manager.timer
```

Test manuale:

```bash
sudo systemctl start mam-bonus-manager.service
journalctl -u mam-bonus-manager.service -n 100 --no-pager
```

## Migliorie rispetto allo script originale

- `MAM_ID` non è più scritto nello script.
- Cookie e config hanno permessi restrittivi.
- URL wedge/VIP/upload usano timestamp aggiornato a ogni chiamata.
- `curl` usa timeout, retry e fallisce in modo esplicito.
- Validazione numerica dei punti prima di confronti aritmetici.
- Lock anti doppia esecuzione.
- `--dry-run` per vedere gli acquisti previsti senza spendere punti.
- `WEDGE_RESERVE_AFTER` evita di comprare wedge se resterebbero troppo pochi punti.
- Script più leggibile, diviso in funzioni e con messaggi di log chiari.

## Sicurezza

Non committare mai:

- `MAM_ID` reale;
- `MAM.cookies`;
- file `config.env` reale;
- log contenenti risposte API sensibili.

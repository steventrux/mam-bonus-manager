# mam-bonus-manager

A safe and configurable Bash script for managing MyAnonamouse bonus points automatically.

It can:

- validate or recreate the MAM session using `MAM_ID`;
- read the current seedbonus balance;
- buy wedges at a configurable interval;
- optionally buy or extend VIP;
- buy upload credit in configurable package sizes;
- keep a configurable points buffer untouched;
- prevent concurrent runs with `flock`;
- run safely in `--dry-run` mode;
- keep secrets and cookies outside the repository.

## Quick start

```bash
sudo mkdir -p /etc/mam-bonus-manager /opt/MAM
sudo cp config/config.env.example /etc/mam-bonus-manager/config.env
sudo nano /etc/mam-bonus-manager/config.env
sudo chmod 600 /etc/mam-bonus-manager/config.env
sudo chmod 700 /opt/MAM
chmod +x mam-bonus-manager.sh
./mam-bonus-manager.sh --dry-run
```

Dependencies:

```bash
sudo apt update
sudo apt install -y curl jq util-linux findutils
```

## Configuration

The real configuration file should stay outside git:

```text
/etc/mam-bonus-manager/config.env
```

Main variables:

| Variable | Default | Meaning |
| --- | ---: | --- |
| `MAM_ID` | required | value of the `mam_id` cookie |
| `WORKDIR` | `/opt/MAM` | working directory for cookies, lock file and state files |
| `BUFFER` | `55000` | bonus points to keep untouched before buying upload credit |
| `VIP` | `0` | set to `1` to enable VIP purchase/extension |
| `WEDGE_HOURS` | `4` | wedge purchase interval; `0` disables wedges |
| `WEDGE_RESERVE_AFTER` | `5000` | minimum points to keep after a wedge purchase |
| `UPLOAD_PACKS` | `100 20 5 1` | upload credit package sizes to buy, in GB |
| `USER_AGENT` | `Mozilla/5.0 mam-bonus-manager/1.0.0` | User-Agent sent by curl |

## Usage

```bash
./mam-bonus-manager.sh --dry-run
./mam-bonus-manager.sh run
./mam-bonus-manager.sh check-session
./mam-bonus-manager.sh points
```

Use an alternate config file:

```bash
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh --dry-run
```

## Local dry-run test

Use this workflow to test the script locally, including on a Chromebook Linux container, without writing to `/etc` or `/opt`.

```bash
cp config/config.env.example ./config.env
chmod 600 ./config.env
mkdir -p .mam-workdir
```

Edit `./config.env`:

```bash
MAM_ID="your_real_mam_id"
WORKDIR="$PWD/.mam-workdir"
VIP=0
WEDGE_HOURS=0
```

Then run:

```bash
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh check-session
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh points
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh --dry-run run
```

With `VIP=0` and `WEDGE_HOURS=0`, the script will not buy VIP or wedges. With the default `BUFFER=55000`, it will only buy upload credit if your bonus balance is above the configured thresholds.

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

Manual test:

```bash
sudo systemctl start mam-bonus-manager.service
journalctl -u mam-bonus-manager.service -n 100 --no-pager
```

## Improvements over the original script

- `MAM_ID` is no longer stored in the script.
- Cookies and configuration files use restrictive permissions.
- Wedge, VIP and upload URLs use a fresh timestamp for each request.
- `curl` uses timeouts, retries and explicit failure handling.
- Bonus points are validated before numeric comparisons.
- A lock file prevents overlapping runs.
- `--dry-run` shows planned purchases without spending points.
- `WEDGE_RESERVE_AFTER` prevents buying wedges when it would leave too few points.
- The script is function-based and easier to read and maintain.

## Safety notes

Never commit:

- the real `MAM_ID` value;
- `MAM.cookies`;
- the real `config.env` file;
- logs containing sensitive API responses.

Run `--dry-run` first after every configuration change.

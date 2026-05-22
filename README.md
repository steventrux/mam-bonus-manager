# mam-bonus-manager

`mam-bonus-manager` is a configurable Bash tool for managing MyAnonamouse bonus points safely from a server, cron job, systemd timer or Docker container.

It can validate the MAM session, read the current seedbonus balance, buy VIP, buy wedges, buy upload credit, and plan donations to new users. All spending actions support `--dry-run`, so configuration changes can be tested before any real purchase is sent.

## Features

- Session management using `MAM_ID` or `MAM_ID_FILE`.
- Current seedbonus balance lookup.
- Automated VIP purchase or extension for eligible account classes.
- Automated wedge purchases at a configurable interval.
- Automated upload credit purchases using configurable package sizes.
- Optional upload ratio guard: upload credit is bought only if the account ratio is below `UPLOAD_RATIO_THRESHOLD`.
- Donation planning for new users, with amount, buffer, cooldown and max-users-per-run controls.
- Interactive manual mode for VIP, wedges, upload credit and donations.
- Dedicated `--dry-run` mode for safe testing.
- Configurable point buffers for upload and donation logic.
- Purchase history in TSV format.
- Daily Telegram summary, optional.
- Heartbeat URL support, optional.
- Lock file with `flock` to prevent overlapping runs.
- Docker, systemd and local shell usage.
- Secrets, cookies and runtime state kept outside the repository.

## Current purchase flow

### Automated mode

Automated mode runs the steps in this order:

```text
1. VIP
2. Wedge
3. Upload credit
4. Donations to new users
```

The upload step is controlled by both point availability and ratio threshold. With the default `UPLOAD_RATIO_THRESHOLD=2.5`, upload credit is bought only when the current ratio is below `2.5`. Set `UPLOAD_RATIO_THRESHOLD=0` to disable the ratio guard.

The donation step runs after VIP, wedge and upload credit. It uses only points above `DONATION_BUFFER`, skips users already present in `DONATION_STATE_FILE` within the cooldown window, and limits the number of candidates with `DONATION_MAX_USERS_PER_RUN`.

At this stage, real donation sending is intentionally disabled in `lib/donations.sh`. The donation flow is wired into automatic and manual mode, but `send_donation()` logs the action in dry-run and skips real sending in normal mode until the final send logic is enabled.

### Manual mode

Manual mode runs the steps in this order:

```text
1. VIP
2. Wedge
3. Upload credit
4. Donations to new users
```

Manual upload shows the current ratio and the configured automatic ratio threshold, but it does **not** block the manual purchase based on the ratio. The threshold is binding only in automated mode.

Manual donations show the number of available new-user candidates after cooldown filtering. You then choose how many points to donate to each user and the maximum total budget for that manual run.

## Quick start

```bash
sudo mkdir -p /etc/mam-bonus-manager /opt/MAM
sudo cp config/config.env.example /etc/mam-bonus-manager/config.env
sudo nano /etc/mam-bonus-manager/config.env
sudo chmod 600 /etc/mam-bonus-manager/config.env
sudo chmod 700 /opt/MAM
chmod +x mam-bonus-manager.sh scripts/donation-planner.sh
./mam-bonus-manager.sh --dry-run run
```

Dependencies:

```bash
sudo apt update
sudo apt install -y curl jq util-linux findutils grep sed gawk
```

`awk` is required by the donation candidate parser. On Debian/Ubuntu, `gawk` or the default `awk` provider is sufficient.

## Configuration

The production configuration file should stay outside git:

```text
/etc/mam-bonus-manager/config.env
```

Start from the example file:

```bash
cp config/config.env.example config.env
```

Most variables can also be overridden with the `MAM_` prefix. For example, `BUFFER` can be overridden by `MAM_BUFFER`, `VIP` by `MAM_VIP`, and `UPLOAD_RATIO_THRESHOLD` by `MAM_UPLOAD_RATIO_THRESHOLD`.

### Required session settings

| Variable | Default | Description |
| --- | ---: | --- |
| `MAM_ID` | required | Value of the `mam_id` cookie. Do not commit it. |
| `MAM_ID_FILE` | empty | Optional file containing the `mam_id` value. Useful for secret management. |
| `WORKDIR` | `/opt/MAM` | Runtime directory for cookies, lock file, state files and purchase logs. |

### Logging and runtime settings

| Variable | Default | Description |
| --- | ---: | --- |
| `VERBOSITY` | `1` | `0=ERROR`, `1=INFO/WARN`, `2=DEBUG`. |
| `LOG_FILE` | empty | Optional additional log file path. |
| `CURL_TIMEOUT` | `30` | Maximum curl request time in seconds. |
| `CURL_RETRIES` | `3` | Number of curl retries. |
| `USER_AGENT` | `Mozilla/5.0 mam-bonus-manager/1.2.4` | User-Agent sent to MAM. |

### VIP settings

| Variable | Default | Description |
| --- | ---: | --- |
| `VIP` | `0` | Set to `1` to enable automatic VIP purchase or extension. |
| `VIP_BLOCK_COST` | `5000` | Cost of one 4-week VIP block. |
| `VIP_THRESHOLD_WEEKS` | `11` | If already VIP, automatic extension runs only when VIP expires within this many weeks. |

Automatic VIP is available only for eligible account classes reported by MAM. The script currently treats `Power User` and `VIP` as eligible.

### Wedge settings

| Variable | Default | Description |
| --- | ---: | --- |
| `WEDGE_HOURS` | `4` | Buy one wedge every N hours. Set to `0` to disable automatic wedges. |
| `WEDGE_COST` | `50000` | Wedge cost in bonus points. |
| `WEDGE_RESERVE_AFTER` | `5000` | Minimum points to keep after wedge purchases. |

### Upload credit settings

| Variable | Default | Description |
| --- | ---: | --- |
| `BUFFER` | `55000` | Points to keep untouched before buying upload credit in automated mode. |
| `MIN_UPLOAD_GB` | `50` | Minimum upload package size allowed for automated purchases. |
| `UPLOAD_PACKS` | `100 50` | Upload credit package sizes to try, from largest to smallest, in GB. |
| `UPLOAD_RATIO_THRESHOLD` | `2.5` | Buy upload credit only if current ratio is below this value. Set to `0` to disable. |

Automated upload purchases require both enough points above `BUFFER` and, unless disabled, a current ratio below `UPLOAD_RATIO_THRESHOLD`.

### Donation settings

| Variable | Default | Description |
| --- | ---: | --- |
| `DONATIONS` | `0` | Set to `1` to enable the automated donation step and donation planner. |
| `DONATION_AMOUNT` | `100` | Points planned per user in automated donation mode. |
| `DONATION_BUFFER` | `5000` | Points to keep untouched before planning donations. |
| `DONATION_MAX_USERS_PER_RUN` | `5` | Maximum new-user donation candidates per automatic run. |
| `DONATION_COOLDOWN_DAYS` | `30` | Cooldown before the same user can be planned again. `0` means never repeat. |
| `DONATION_STATE_FILE` | `$WORKDIR/donations.tsv` | Local donation history file. |

Donation discovery reads new-user candidates from MAM, filters out users already in the local donation history within the cooldown period, and plans donations only while enough points remain above the configured donation buffer.

### Notification settings

| Variable | Default | Description |
| --- | ---: | --- |
| `HEARTBEAT_URL` | empty | Optional push URL for Healthchecks.io, Uptime Kuma or similar. |
| `TELEGRAM_DAILY_SUMMARY` | `0` | Set to `1` to enable one daily Telegram summary. |
| `TELEGRAM_BOT_TOKEN` | empty | Telegram bot token. |
| `TELEGRAM_CHAT_ID` | empty | Telegram chat ID. |
| `PURCHASE_LOG_FILE` | `$WORKDIR/purchases.tsv` | TSV purchase history used by summaries. |
| `TELEGRAM_SENT_FILE` | `$WORKDIR/telegram-summary.sent` | Tracks already-sent summary dates. |

## Commands

### Automated run

```bash
./mam-bonus-manager.sh --dry-run run
./mam-bonus-manager.sh run
```

`run` is the default command, so this is equivalent:

```bash
./mam-bonus-manager.sh --dry-run
```

Use `--dry-run` first after every config change.

### Manual interactive mode

```bash
./mam-bonus-manager.sh --dry-run manual
./mam-bonus-manager.sh manual
```

Manual mode asks step by step. You can skip each step by entering `0` or pressing Enter where supported.

Manual mode currently includes:

- VIP duration selection: `0`, `4`, `8`, `12`, or `max`.
- Number of wedges to buy.
- Upload package and quantity selection.
- Donation amount per user and maximum total donation budget.

### Session and balance checks

```bash
./mam-bonus-manager.sh check-session
./mam-bonus-manager.sh points
```

### Alternate config file

```bash
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh --dry-run run
```

## Donation planner

A dedicated donation planner is available for testing the donation candidate flow independently from the main purchase cycle:

```bash
MAM_CONFIG="$PWD/config.env" ./scripts/donation-planner.sh
```

The planner:

1. validates or recreates the MAM session;
2. reads the current point balance;
3. keeps `DONATION_BUFFER` untouched;
4. reads new-user candidates;
5. applies the local cooldown history;
6. prints the donations it would make.

The planner is intentionally safe: it uses dry-run behavior and does not send real donations.

## Local dry-run workflow

Use this workflow to test without writing to `/etc` or `/opt`:

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
DONATIONS=1
```

Run checks and dry-runs:

```bash
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh check-session
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh points
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh --dry-run run
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh --dry-run manual
MAM_CONFIG="$PWD/config.env" ./scripts/donation-planner.sh
```

## Docker

Docker is supported as an alternative to local/systemd installation.

- The container does not expose ports.
- Configuration is read from `/config/config.env`.
- `/data` is the persistent `WORKDIR` for cookies, lock files, state files and purchase history.
- With Docker, set `WORKDIR="/data"` in `config.env`.

One-off examples:

```bash
docker run --rm ghcr.io/steventrux/mam-bonus-manager:latest --version
docker run --rm -it \
  -v "$PWD/docker-config:/config" \
  -v "$PWD/docker-data:/data" \
  ghcr.io/steventrux/mam-bonus-manager:latest --dry-run run

docker run --rm -it \
  -v "$PWD/docker-config:/config" \
  -v "$PWD/docker-data:/data" \
  ghcr.io/steventrux/mam-bonus-manager:latest --dry-run manual
```

For production usage, prefer versioned image tags once releases are available.

## Systemd timer

Install the script:

```bash
sudo cp mam-bonus-manager.sh /usr/local/bin/mam-bonus-manager
sudo chmod +x /usr/local/bin/mam-bonus-manager
```

Install and enable the timer:

```bash
sudo cp systemd/mam-bonus-manager.service /etc/systemd/system/
sudo cp systemd/mam-bonus-manager.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mam-bonus-manager.timer
systemctl list-timers mam-bonus-manager.timer
```

Manual systemd test:

```bash
sudo systemctl start mam-bonus-manager.service
journalctl -u mam-bonus-manager.service -n 100 --no-pager
```

## Runtime files

Typical runtime files are stored under `WORKDIR`:

```text
MAM.cookies
MAM.json
mam-bonus-manager.lock
wedge.last
purchases.tsv
donations.tsv
telegram-summary.sent
```

These files may contain sensitive data or account activity history. Do not commit them.

## Safety notes

Never commit:

- the real `MAM_ID` value;
- Telegram bot tokens or chat IDs;
- `MAM.cookies`;
- the real `config.env` file;
- runtime state files;
- logs containing sensitive API responses.

Recommended workflow:

```bash
./mam-bonus-manager.sh --dry-run run
./mam-bonus-manager.sh --dry-run manual
```

Only run without `--dry-run` after reviewing the output.

## Project layout

```text
mam-bonus-manager.sh              Main script
config/config.env.example         Example configuration
lib/donations.sh                  Donation helper functions
scripts/donation-planner.sh       Standalone donation dry-run planner
systemd/                          systemd service and timer files
compose.yml                       Docker Compose example
```

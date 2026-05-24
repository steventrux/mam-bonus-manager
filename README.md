# mam-bonus-manager

`mam-bonus-manager` is a configurable Bash tool for managing MyAnonamouse bonus points from a local shell, server, cron job, systemd timer or Docker container.

It validates the MAM session, reads the current seedbonus balance, and can automate VIP checks, upload-credit purchases, wedge purchases and bonus-point donations to new users. Every spending action supports `--dry-run`, so configuration changes can be tested before any real purchase or donation is sent.

## Features

### Core

- Session management using `MAM_ID` or `MAM_ID_FILE`.
- Current seedbonus balance lookup.
- Dedicated `--dry-run` mode for safe testing.
- Lock file with `flock` to prevent overlapping runs.
- Secrets, cookies and runtime state kept outside the repository.

### Automated spending

- VIP purchase or extension for eligible account classes.
- Upload credit purchases using configurable package sizes.
- Optional upload ratio guard through `UPLOAD_RATIO_THRESHOLD`.
- Optional wedge purchases, disabled by default with `WEDGE_HOURS=0`.
- Donations to new users with cooldown, candidate limits, uploaded-amount filtering and per-user total limit.
- Single automated spending reserve through `BONUS_RESERVE_POINTS`.

### Operations

- Interactive manual mode for VIP, upload credit, wedges and donations.
- Purchase and donation history in TSV format.
- Optional daily Telegram summary.
- Optional heartbeat URL support.
- Docker, systemd and local shell usage.

## Current purchase flow

### Automated mode

Automated mode runs the steps in this order:

```text
1. VIP
2. Upload credit
3. Wedge
4. Donations to new users
```

VIP is evaluated first. Automatic VIP purchases are attempted only when `VIP=1` and the current account class is eligible.

Upload credit is controlled by point availability, `BONUS_RESERVE_POINTS` and the ratio threshold. With the default `UPLOAD_RATIO_THRESHOLD=2.5`, upload credit is bought only when the current ratio is below `2.5`. Set `UPLOAD_RATIO_THRESHOLD=0` to disable the ratio guard.

Wedges are disabled by default. Set `WEDGE_HOURS` to a value greater than `0` to enable automatic wedge purchases. The automated wedge step also respects `BONUS_RESERVE_POINTS`.

Donations run last and use only points above `BONUS_RESERVE_POINTS`. They also apply cooldown history, max candidates per run, recipient uploaded-amount filtering and the cumulative per-user donation limit.

With `--dry-run`, purchases and donations are only printed. Without `--dry-run`, enabled spending actions are sent to MAM and successful actions are recorded in the local TSV history files.

### Manual mode

Manual mode runs the same steps in the same order:

```text
1. VIP
2. Upload credit
3. Wedge
4. Donations to new users
```

Manual mode does not enforce the automated global reserve. It shows the available choices at each step and asks before each action, so the user decides how many points to spend.

Manual upload shows the current ratio and the configured automatic ratio threshold, but it does **not** block the manual purchase based on the ratio. The threshold is binding only in automated mode.

Manual donations show the number of available candidates after cooldown and uploaded-amount filtering. You then choose how many points to donate to each user and the maximum total budget for that manual run.

## Quick start

```bash
sudo mkdir -p /etc/mam-bonus-manager /opt/MAM
sudo chmod 700 /opt/MAM
chmod +x mam-bonus-manager.sh scripts/donation-planner.sh
sudo MAM_CONFIG=/etc/mam-bonus-manager/config.env ./mam-bonus-manager.sh config edit
sudo MAM_CONFIG=/etc/mam-bonus-manager/config.env ./mam-bonus-manager.sh --dry-run run
```

The `config edit` command creates or migrates the configuration file, makes a backup when needed, and opens the file in an editor.

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

For local testing, let the script create or migrate the file:

```bash
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh config edit
```

Most variables can also be overridden with the `MAM_` prefix. For example, `BONUS_RESERVE_POINTS` can be overridden by `MAM_BONUS_RESERVE_POINTS`, `VIP` by `MAM_VIP`, and `UPLOAD_RATIO_THRESHOLD` by `MAM_UPLOAD_RATIO_THRESHOLD`.

### Required session settings

| Variable | Default | Description |
| --- | ---: | --- |
| `MAM_ID` | required | Value of the `mam_id` cookie. Do not commit it. |
| `MAM_ID_FILE` | empty | Optional file containing the `mam_id` value. Useful for secret management. |
| `WORKDIR` | `/opt/MAM` | Runtime directory for cookies, lock file, state files and purchase logs. |

### Runtime settings

| Variable | Default | Description |
| --- | ---: | --- |
| `VERBOSITY` | `1` | `0=ERROR`, `1=INFO/WARN`, `2=DEBUG`. |
| `LOG_FILE` | empty | Optional additional log file path. |
| `CURL_TIMEOUT` | `30` | Maximum curl request time in seconds. |
| `CURL_RETRIES` | `3` | Number of curl retries. |
| `USER_AGENT` | `Mozilla/5.0 mam-bonus-manager/1.3.1` | User-Agent sent to MAM. |

### Global reserve

| Variable | Default | Description |
| --- | ---: | --- |
| `BONUS_RESERVE_POINTS` | `55000` | Global reserve used by automated upload credit, wedge and donation steps. The default 55k reserve is intended to preserve enough points for the maximum VIP purchase shown by MAM, but it can be lowered or raised according to each user's preferences. |

VIP is evaluated before the reserve is applied to the other automated spending steps. Manual mode does not enforce this reserve, because the user confirms each action step by step.

### VIP settings

| Variable | Default | Description |
| --- | ---: | --- |
| `VIP` | `1` | Set to `1` to enable automatic VIP purchase or extension. Set to `0` to disable the VIP step. |
| `VIP_THRESHOLD_WEEKS` | `11` | If already VIP, automatic extension runs only when VIP expires within this many weeks. |

Automatic VIP is available only for eligible account classes reported by MAM. The script currently treats `Power User` and `VIP` as eligible. The VIP block cost is fixed by MAM and is not exposed as a user-configurable setting.

### Upload credit settings

| Variable | Default | Description |
| --- | ---: | --- |
| `MIN_UPLOAD_GB` | `50` | Minimum upload package size allowed for automated purchases. |
| `UPLOAD_PACKS` | `100 50` | Upload credit package sizes to try, from largest to smallest, in GB. |
| `UPLOAD_RATIO_THRESHOLD` | `2.5` | Buy upload credit only if current ratio is below this value. Set to `0` to disable. |

Automated upload purchases require enough points above `BONUS_RESERVE_POINTS` and, unless disabled, a current ratio below `UPLOAD_RATIO_THRESHOLD`.

### Wedge settings

| Variable | Default | Description |
| --- | ---: | --- |
| `WEDGE_HOURS` | `0` | Buy one wedge every N hours. Default is disabled. Set a value greater than `0` to enable automatic wedges. |

The wedge cost is fixed by MAM and is not exposed as a user-configurable setting.

### Donation settings

| Variable | Default | Description |
| --- | ---: | --- |
| `DONATIONS` | `0` | Set to `1` to enable the automated donation step and donation planner. |
| `DONATION_AMOUNT` | `100` | Points donated per user in automated donation mode. |
| `DONATION_MAX_USERS_PER_RUN` | `5` | Maximum new-user donation candidates per automatic run. |
| `DONATION_MAX_POINTS_PER_USER` | `1000` | Maximum cumulative points that can be donated to the same user, based on `DONATION_STATE_FILE`. Set to `0` to disable this limit. |
| `DONATION_COOLDOWN_DAYS` | `30` | Cooldown before the same user can receive another donation. `0` means never repeat. |
| `DONATION_MAX_RECIPIENT_UPLOADED_BYTES` | `53687091200` | Recipient uploaded threshold. Default is 50 GiB. If greater than `0`, donate only to users whose uploaded amount is less than or equal to this value. `0` disables this filter. |
| `DONATION_STATE_FILE` | `$WORKDIR/donations.tsv` | Local donation history file. |

### Donation discovery settings

Donation candidate discovery is automatic and does not require a manually configured starting UID.

The script starts from the authenticated account UID, probes upward in configurable blocks until it finds an empty UID, uses binary search to identify the latest valid UID, and then scans backward from there to collect recent donation candidates.

| Variable | Default | Description |
| --- | ---: | --- |
| `DONATION_LATEST_UID_STEP` | `1000` | UID probing step used to find a valid/empty interval before binary search. |
| `DONATION_SCAN_LOOKBACK` | `100` | Maximum number of recent UIDs to check while scanning backward from the latest valid UID. |
| `DONATION_SCAN_MAX_CANDIDATES` | `20` | Maximum number of valid UID profiles returned by discovery before donation filters are applied. |
| `DONATION_SCAN_DELAY_SECONDS` | `1` | Delay between UID checks. Use `0` only for short tests. |

Discovered users still go through the normal donation filters: cooldown history, recipient uploaded-amount threshold, cumulative per-user donation limit and the automated `BONUS_RESERVE_POINTS` reserve.

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

Always use `--dry-run` first after every configuration change.

### Manual interactive mode

```bash
./mam-bonus-manager.sh --dry-run manual
./mam-bonus-manager.sh manual
```

Manual mode asks step by step. You can skip each step by entering `0` or pressing Enter where supported.

Manual mode includes:

- VIP duration selection: `0`, `4`, `8`, `12`, or `max`.
- Upload package and quantity selection.
- Number of wedges to buy.
- Donation amount per user and maximum total donation budget.

### Configuration migration and editing

```bash
./mam-bonus-manager.sh config
./mam-bonus-manager.sh config edit
```

The `config` command creates the configuration file if it does not exist, or migrates an existing one by adding newly introduced settings from `config/config.env.example`.

Existing values are preserved. Settings that are no longer user-configurable are commented out automatically so they cannot interfere with newer releases.

Use `config edit` to migrate the file and then open it in an editor. The editor is selected from `$EDITOR`, then `nano`, then `vi`.

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

The planner is always dry-run. It:

1. validates or recreates the MAM session;
2. reads the current point balance;
3. keeps `BONUS_RESERVE_POINTS` untouched;
4. discovers donation candidates;
5. applies cooldown history and recipient filters;
6. prints the donations it would make.

Use the main script without `--dry-run` only when you want to send real purchases or donations.

## Local dry-run workflow

Use this workflow to test without writing to `/etc` or `/opt`:

```bash
mkdir -p .mam-workdir
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh config edit
```

At minimum, check these values in `./config.env`:

```bash
MAM_ID="your_real_mam_id"
WORKDIR="$PWD/.mam-workdir"
BONUS_RESERVE_POINTS=55000
VIP=1
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
- Mount `/config` read-write if you want to use the built-in `config` or `config edit` migration commands from inside the container.
- `/data` is the persistent `WORKDIR` for cookies, lock files, state files and purchase history.
- With Docker, set `WORKDIR="/data"` in `config.env`.

One-off examples:

```bash
docker run --rm ghcr.io/steventrux/mam-bonus-manager:latest --version
docker run --rm -it \
  -v "$PWD/docker-config:/config" \
  -v "$PWD/docker-data:/data" \
  ghcr.io/steventrux/mam-bonus-manager:latest config edit

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

## Safety notes

Keep secrets and runtime files out of git. Never commit or share:

- the real `MAM_ID` value;
- the real `config.env` file;
- `MAM.cookies`;
- Telegram bot tokens or chat IDs;
- logs containing sensitive API responses.

The `WORKDIR` directory contains cookies, state files and activity history, so treat it as private.

Recommended workflow:

```bash
./mam-bonus-manager.sh --dry-run run
./mam-bonus-manager.sh --dry-run manual
```

Run without `--dry-run` only after reviewing the output. When `DONATIONS=1`, running without `--dry-run` can send real donations to new users.

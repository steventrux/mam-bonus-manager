# mam-bonus-manager

A safe and configurable Bash script for managing MyAnonamouse bonus points automatically.

It can:

- validate or recreate the MAM session using `MAM_ID` or `MAM_ID_FILE`;
- read the current seedbonus balance;
- optionally buy or extend VIP only when needed;
- buy wedges at a configurable interval;
- buy upload credit in configurable package sizes;
- refresh the bonus balance after each automated purchase step;
- keep a configurable points buffer untouched in automated mode;
- prevent concurrent runs with `flock`;
- run safely in `--dry-run` mode;
- provide an interactive manual mode for one-off purchases;
- optionally write logs to a file;
- optionally send heartbeat checks;
- optionally send one Telegram daily purchase summary;
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

Most options can also be overridden with environment variables prefixed with `MAM_`, for example `MAM_BUFFER`, `MAM_VIP`, `MAM_WORKDIR`, `MAM_DRY_RUN`, `MAM_VERBOSITY`, `MAM_HEARTBEAT_URL`, `MAM_TELEGRAM_BOT_TOKEN` and `MAM_TELEGRAM_CHAT_ID`.

Main variables:

| Variable | Default | Meaning |
| --- | ---: | --- |
| `MAM_ID` | required | value of the `mam_id` cookie |
| `MAM_ID_FILE` | empty | optional file containing the `mam_id` value |
| `WORKDIR` | `/opt/MAM` | working directory for cookies, lock file and state files |
| `VERBOSITY` | `1` | `0=ERROR`, `1=INFO/WARN`, `2=DEBUG` |
| `LOG_FILE` | empty | optional extra log file path |
| `BUFFER` | `55000` | bonus points to keep untouched before buying upload credit in automated mode |
| `VIP` | `0` | set to `1` to enable automated VIP purchase/extension |
| `VIP_WEEK_COST` | `5000` | VIP cost per week, used by interactive mode |
| `VIP_THRESHOLD_WEEKS` | `11` | automated VIP purchase threshold |
| `WEDGE_HOURS` | `4` | wedge purchase interval; `0` disables automated wedges |
| `WEDGE_COST` | `50000` | wedge cost in bonus points |
| `WEDGE_RESERVE_AFTER` | `5000` | minimum points to keep after automated or manual wedge purchases |
| `MIN_UPLOAD_GB` | `50` | minimum upload package size allowed for automated API purchases |
| `UPLOAD_PACKS` | `100 50` | upload credit package sizes to buy, in GB |
| `USER_AGENT` | `Mozilla/5.0 mam-bonus-manager/1.2.0` | User-Agent sent by curl |
| `HEARTBEAT_URL` | empty | optional HTTP heartbeat URL |
| `TELEGRAM_DAILY_SUMMARY` | `0` | set to `1` to enable daily Telegram purchase summaries |
| `TELEGRAM_BOT_TOKEN` | empty | Telegram bot token |
| `TELEGRAM_CHAT_ID` | empty | Telegram chat ID |
| `PURCHASE_LOG_FILE` | `$WORKDIR/purchases.tsv` | local purchase event log used for summaries |
| `TELEGRAM_SENT_FILE` | `$WORKDIR/telegram-summary.sent` | tracks already-sent summary dates |

## Usage

Automated mode, suitable for cron or systemd:

```bash
./mam-bonus-manager.sh --dry-run
./mam-bonus-manager.sh run
```

In automated mode, purchases are processed in this order:

1. VIP purchase/extension;
2. wedge purchase;
3. upload credit purchase.

VIP is purchased only if `VIP=1` and either the account is not currently VIP or VIP expires within `VIP_THRESHOLD_WEEKS`. After each real purchase step, the script refreshes the bonus balance from MAM before moving to the next step. In `--dry-run` mode, no purchase is sent to MAM and the script only estimates or reports the planned actions.

Utility commands:

```bash
./mam-bonus-manager.sh check-session
./mam-bonus-manager.sh points
```

Interactive manual mode:

```bash
./mam-bonus-manager.sh --dry-run manual
./mam-bonus-manager.sh manual
```

Use an alternate config file:

```bash
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh --dry-run
```

## Interactive manual mode

Manual mode is intended for one-off runs from a terminal. It does not replace the automated `run` command used by cron or systemd.

It proceeds in three steps:

1. VIP purchase/extension;
2. wedge purchase;
3. upload credit purchase.

Before each step, the script prints the current points, the relevant cost and the maximum quantity currently purchasable. You can enter `0` or press Enter to skip a step.

Manual mode does **not** apply the automated `BUFFER` to VIP or upload purchases. It only prevents you from selecting more than your current balance can buy. Wedges still respect `WEDGE_RESERVE_AFTER`, because that setting is specific to wedge safety.

Example safe test:

```bash
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh --dry-run manual
```

In `--dry-run` mode, no purchase is sent to MAM. The script only estimates the point balance after each selected step.

## Notifications

### Heartbeat

Set `HEARTBEAT_URL` to a push monitor URL, such as Healthchecks.io or Uptime Kuma. The heartbeat is sent at the end of successful non-dry-run executions.

```bash
HEARTBEAT_URL="https://example.com/api/push/..."
```

### Telegram daily summary

Telegram summaries are optional and disabled by default. When enabled, the script records successful purchases in `PURCHASE_LOG_FILE` and sends at most one summary per day for the previous day's purchases.

```bash
TELEGRAM_DAILY_SUMMARY=1
TELEGRAM_BOT_TOKEN="123456:ABCDEF..."
TELEGRAM_CHAT_ID="123456789"
```

The summary includes total VIP purchases, wedges, upload credit and points spent for the day. No Telegram message is sent if there were no purchases for the summarized date.

## Local dry-run test

Use this workflow to test the script locally on any Linux-like environment without writing to `/etc` or `/opt`.

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
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh --dry-run manual
```

With `VIP=0` and `WEDGE_HOURS=0`, the automated `run` command will not buy VIP or wedges. With the default `BUFFER=55000`, automated upload purchases only happen if your bonus balance is above the configured thresholds. Manual mode ignores that automated buffer and asks before every selected purchase.

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
- `MAM_ID` can be read from a separate file.
- Runtime options can be overridden with environment variables.
- Cookies and configuration files use restrictive permissions.
- Wedge, VIP and upload URLs use a fresh timestamp for each request.
- `curl` uses timeouts, retries and explicit failure handling.
- Bonus points are validated before numeric comparisons.
- A lock file prevents overlapping runs.
- `--dry-run` shows planned purchases without spending points.
- `WEDGE_RESERVE_AFTER` prevents buying wedges when it would leave too few points.
- Automated upload purchases respect MAM's current minimum package size.
- Automated mode runs in VIP → wedge → upload order and refreshes points after each purchase step.
- Automated VIP purchase is skipped when VIP is already valid beyond the configured threshold.
- Interactive mode supports controlled one-off VIP, wedge and upload purchases.
- Optional heartbeat and Telegram daily summary notifications are supported.
- The script is function-based and easier to read and maintain.

## Safety notes

Never commit:

- the real `MAM_ID` value;
- Telegram bot tokens or chat IDs;
- `MAM.cookies`;
- the real `config.env` file;
- logs containing sensitive API responses.

Run `--dry-run` first after every configuration change.

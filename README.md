# mam-bonus-manager

`mam-bonus-manager` is a configurable tool for managing MyAnonamouse bonus points from Docker, Portainer, a local shell, cron or a systemd timer.

It can check the current seedbonus balance and automate VIP checks, upload-credit purchases, wedge purchases and bonus-point donations to new users. Every spending action supports `--dry-run`, so you can test the configuration before any real purchase or donation is sent.

## What it can do

### Core features

- Validate or recreate a MAM session using `MAM_ID` or `MAM_ID_FILE`.
- Read the current seedbonus balance.
- Run in safe dry-run mode.
- Prevent overlapping executions with a lock file.
- Keep cookies, history files and browser data outside the application files.

### Automated spending

- Buy or extend VIP when the account class is eligible.
- Buy upload credit using configurable package sizes.
- Use an optional ratio guard before buying upload credit.
- Buy wedges on a configurable interval.
- Donate bonus points to new users.
- Preserve a global bonus-point reserve.

### Donation support

Gift donations are sent through the bundled Playwright/Chromium browser executor. The older direct API/curl gift method is not supported because MAM rejects gift requests outside a browser context.

The browser executor uses a persistent Chromium profile. After the first successful login, it can usually reuse the browser session without logging in again.

## Automated purchase flow

Automated mode runs the steps in this order:

```text
1. VIP
2. Upload credit
3. Wedge
4. Donations to new users
```

VIP is evaluated first. Automatic VIP purchases are attempted only when `VIP=1` and the current account class is eligible.

Upload credit is controlled by available points and the ratio threshold. With the default `UPLOAD_RATIO_THRESHOLD=2.5`, upload credit is bought only when the current ratio is below `2.5`. Set `UPLOAD_RATIO_THRESHOLD=0` to disable this ratio guard. Larger upload packages respect `BONUS_RESERVE_POINTS`; the minimum configured upload package can be bought when enough points are available for that package.

Wedges are disabled by default. Set `WEDGE_HOURS` to a value greater than `0` to enable automatic wedge purchases. The automated wedge step respects `BONUS_RESERVE_POINTS`.

Donations run last and use only points above `BONUS_RESERVE_POINTS`. They are also skipped when the current ratio is below `UPLOAD_RATIO_THRESHOLD`, so points can accumulate for upload credit instead of being donated while the ratio is low. Donations apply cooldown history, max recipients per run, recipient uploaded-amount filtering and cumulative per-user limits.

## Manual mode

Manual mode runs the same steps in the same order, but asks before each action:

```text
1. VIP
2. Upload credit
3. Wedge
4. Donations to new users
```

Manual mode does not enforce the automated global reserve. It shows the available choices and lets you decide how many points to spend. Manual upload shows the current ratio but does not block the purchase based on the automated ratio threshold.

## Installation option 1: Docker / Portainer

Docker is the recommended installation method for always-on usage.

The Docker image already includes:

- Bash runtime and core dependencies.
- Node.js dependencies used by the browser executor.
- Playwright and Chromium.
- The scheduler entrypoint.

No `npm install` or `npx playwright install chromium` step is required inside Docker.

The image is intentionally heavier than the earlier Alpine-based image because it includes Playwright, Chromium and the browser runtime required for gift donations. On a tested VPS, Docker reported about `893 MB` content size and about `3.58 GB` disk usage. Exact numbers can vary by Docker storage driver, cache and base image version.

### Minimal Docker Compose / Portainer stack

This layout keeps configuration and runtime data separated:

```yaml
services:
  mam-bonus-manager:
    image: ghcr.io/steventrux/mam-bonus-manager:latest
    container_name: mam-bonus-manager
    restart: unless-stopped
    user: "1000:1000"
    environment:
      - TZ=Europe/Rome
      - MAM_CONFIG=/config/config.env
      - MAM_INTERVAL_SECONDS=3600
    volumes:
      - ./config:/config
      - ./data:/data
    command: scheduler
```

Adjust `user: "1000:1000"` to match the owner of the mounted `config` and `data` directories. The container user must be able to read `/config` and write to `/data`.

For this two-volume layout, use these values in `/config/config.env`:

```bash
WORKDIR="/data"
MAM_ID_FILE="/config/mam_id"

DONATIONS=1
MAM_BROWSER_PROFILE_DIR="/data/browser-profile"
MAM_LOGIN_EMAIL="your_mam_email"
MAM_LOGIN_PASSWORD_FILE="/config/secrets/mam-password"
```

Create the required secret files on the host:

```bash
mkdir -p config/secrets data
nano config/mam_id
nano config/secrets/mam-password
chmod 700 config config/secrets data
chmod 600 config/mam_id config/secrets/mam-password
```

`config/mam_id` must contain only the value of the `mam_id` cookie. `config/secrets/mam-password` must contain only the MAM web-login password.

Run safe checks before enabling real automated spending:

```bash
docker compose run --rm mam-bonus-manager check-session
docker compose run --rm mam-bonus-manager points
docker compose run --rm mam-bonus-manager --dry-run run
```

Start the scheduler:

```bash
docker compose up -d
docker logs -f mam-bonus-manager
```

### Single-volume Docker example

For quick tests, a single `/config` volume also works:

```bash
mkdir -p docker-config/secrets
docker run --rm -it \
  -v "$PWD/docker-config:/config" \
  ghcr.io/steventrux/mam-bonus-manager:latest config edit
```

With this layout, set:

```bash
WORKDIR="/config"
MAM_ID_FILE="/config/mam_id"
MAM_BROWSER_PROFILE_DIR="/config/browser-profile"
MAM_LOGIN_PASSWORD_FILE="/config/secrets/mam-password"
```

## Installation option 2: cloned repository

Use this method when running directly from a cloned directory without Docker.

### 1. Install dependencies

On Debian/Ubuntu:

```bash
sudo apt update
sudo apt install -y curl jq util-linux findutils grep sed gawk nodejs npm
```

`util-linux` provides `flock`. `awk` is required by the donation candidate parser; on Debian/Ubuntu, `gawk` or the default `awk` provider is sufficient.

### 2. Clone and install browser dependencies

```bash
git clone https://github.com/steventrux/mam-bonus-manager.git
cd mam-bonus-manager

chmod +x mam-bonus-manager.sh scripts/donation-planner.sh
npm install
npx playwright install chromium
```

A cloned-repository install needs `npm install` and `npx playwright install chromium` because browser donations always use the Playwright/Chromium browser executor. Docker users do not need these commands because the Docker image already includes the browser runtime.

### 3. Create a local config

```bash
mkdir -p .mam-workdir .mam-secrets
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh config edit
```

At minimum, set:

```bash
MAM_ID="your_real_mam_id"
WORKDIR="$PWD/.mam-workdir"

DONATIONS=1
MAM_BROWSER_PROFILE_DIR="$PWD/.mam-browser-profile"
MAM_LOGIN_EMAIL="your_mam_email"
MAM_LOGIN_PASSWORD_FILE="$PWD/.mam-secrets/mam-password"
```

Create the password file:

```bash
nano .mam-secrets/mam-password
chmod 700 .mam-secrets
chmod 600 .mam-secrets/mam-password
```

The password file must contain only the MAM web-login password.

### 4. Run safe checks

```bash
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh check-session
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh points
MAM_CONFIG="$PWD/config.env" ./mam-bonus-manager.sh --dry-run run
```

Run without `--dry-run` only when you want to send real purchases or donations.

## Configuration

The script reads its configuration from `config.env`. You can select a config file with the `MAM_CONFIG` environment variable.

Most variables can also be overridden with the `MAM_` prefix. For example, `BONUS_RESERVE_POINTS` can be overridden by `MAM_BONUS_RESERVE_POINTS`, `VIP` by `MAM_VIP`, and `UPLOAD_RATIO_THRESHOLD` by `MAM_UPLOAD_RATIO_THRESHOLD`.

The `config` command creates a new configuration file if it does not exist, or migrates an existing one by adding newly introduced settings. Configuration migration also runs automatically at startup when the `CONFIG_VERSION` value differs from the version shipped with the installed release.

### Required session settings

| Variable | Default | Description |
| --- | ---: | --- |
| `MAM_ID` | required | Value of the `mam_id` cookie. |
| `MAM_ID_FILE` | empty | Optional file containing the `mam_id` value. Useful for secret management. |
| `WORKDIR` | `/opt/MAM` | Runtime directory for cookies, lock file, state files, history files and browser profile. In Docker, use `/data` with the recommended two-volume layout or `/config` with a single mounted volume. |

### Runtime settings

| Variable | Default | Description |
| --- | ---: | --- |
| `VERBOSITY` | `1` | `0=ERROR`, `1=INFO/WARN`, `2=DEBUG`. |
| `LOG_FILE` | empty | Optional additional log file path. |
| `CURL_TIMEOUT` | `30` | Maximum curl request time in seconds. |
| `CURL_RETRIES` | `3` | Number of curl retries. |
| `USER_AGENT` | `Mozilla/5.0 mam-bonus-manager` | User-Agent sent to MAM. |

### Global reserve

| Variable | Default | Description |
| --- | ---: | --- |
| `BONUS_RESERVE_POINTS` | `30000` | Safety reserve preserved by automated wedge, donation and larger upload-credit purchases. It does not block automatic VIP purchases, and it does not block the minimum configured upload package when the ratio guard allows upload purchases and enough points are available for that package. |

VIP is evaluated before the reserve is applied to the other automated spending steps and does not enforce this reserve locally. Manual mode does not enforce this reserve because the user confirms each action step by step.

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

Automated upload purchases require, unless disabled, a current ratio below `UPLOAD_RATIO_THRESHOLD`. Larger packages require enough points above `BONUS_RESERVE_POINTS`; the minimum configured package requires only enough points to pay for that package.

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
| `DONATION_MAX_USERS_PER_RUN` | `5` | Maximum number of actual donation recipients per automatic run. Discovery scans backward until this many eligible candidates are found, or until `DONATION_SCAN_LOOKBACK` is reached. |
| `DONATION_MAX_POINTS_PER_USER` | `1000` | Maximum cumulative points that can be donated to the same user, based on `DONATION_STATE_FILE`. Set to `0` to disable this limit. |
| `DONATION_COOLDOWN_DAYS` | `30` | Cooldown before the same user can receive another donation. `0` means never repeat. |
| `DONATION_MAX_RECIPIENT_UPLOADED_BYTES` | `53687091200` | Recipient uploaded threshold. Default is 50 GiB. If greater than `0`, donate only to users whose uploaded amount is less than or equal to this value. `0` disables this filter. |
| `DONATION_STATE_FILE` | `$WORKDIR/donations.tsv` | Local donation history file. |
| `MAM_BROWSER_PROFILE_DIR` | `$WORKDIR/browser-profile` | Persistent Chromium profile directory used by the browser executor. |
| `MAM_BROWSER_TIMEOUT` | `30000` | Browser executor timeout in milliseconds. |
| `MAM_LOGIN_EMAIL` | empty | MAM web-login email used when the browser profile is not already logged in. |
| `MAM_LOGIN_PASSWORD_FILE` | empty | File containing the MAM web-login password. Prefer this over putting a password directly in the config. |

### Donation discovery settings

Donation candidate discovery is automatic and does not require a manually configured starting UID.

On the first run, the script starts from the authenticated account UID. After successful real donations have been recorded, discovery starts from the highest UID stored in `DONATION_STATE_FILE`, probes upward in configurable blocks until it finds an empty UID, uses binary search to identify the latest valid UID, and scans backward from there.

| Variable | Default | Description |
| --- | ---: | --- |
| `DONATION_LATEST_UID_STEP` | `1000` | UID probing step used to find a valid/empty interval before binary search. |
| `DONATION_SCAN_LOOKBACK` | `100` | Maximum number of recent UIDs to check while scanning backward from the latest valid UID. |
| `DONATION_SCAN_DELAY_SECONDS` | `1` | Delay between UID checks. Use `0` only for short tests. |

The scan walks backward from the latest valid UID until it finds up to `DONATION_MAX_USERS_PER_RUN` eligible donation candidates, or until `DONATION_SCAN_LOOKBACK` is reached. Eligibility filters are applied during the scan, so the script does not collect a separate raw-candidate buffer.

To reduce profile API calls on later runs, the script keeps a local exclusion file in `WORKDIR` for safe persistent exclusions only:

- `empty_profile`: the UID returned an empty profile response.
- `uploaded_too_high`: the user exceeded `DONATION_MAX_RECIPIENT_UPLOADED_BYTES`.

Temporary errors such as rate limits, curl failures or incomplete JSON are not stored as persistent exclusions.

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

Use `config edit` to migrate the file manually and then open it in an editor. The editor is selected from `$EDITOR`, then `nano`, then `vi`.

### Session and balance checks

```bash
./mam-bonus-manager.sh check-session
./mam-bonus-manager.sh points
```

### Donation planner

A dedicated donation planner is available for testing the donation candidate flow independently from the main purchase cycle:

```bash
MAM_CONFIG="$PWD/config.env" ./scripts/donation-planner.sh
```

The planner is always dry-run. It validates or recreates the MAM session, reads the current point balance, keeps `BONUS_RESERVE_POINTS` untouched, discovers donation candidates, applies cooldown and recipient filters, and prints the donations it would make.

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

Keep secrets and runtime files private. Never share:

- the real `MAM_ID` value;
- the real `config.env` file;
- `MAM.cookies`;
- Telegram bot tokens or chat IDs;
- logs containing sensitive API responses;
- `MAM_LOGIN_PASSWORD_FILE` contents;
- the Chromium browser profile directory used by Playwright.

The `WORKDIR` directory contains cookies, state files, activity history and the Chromium browser profile, so treat it as private.

Recommended workflow after every configuration change:

```bash
./mam-bonus-manager.sh --dry-run run
./mam-bonus-manager.sh --dry-run manual
```

Run without `--dry-run` only after reviewing the output. When `DONATIONS=1`, running without `--dry-run` can send real donations to new users.

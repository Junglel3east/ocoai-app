# Daily X (Twitter) Posting

Automatic thread on [@OnChainOracleA](https://x.com/OnChainOracleA) after each daily analysis batch (BTC, ETH, SOL, XRP).

## How it works

1. **Existing flow unchanged** — 7:30 AM `America/Chicago` scheduler still generates analyses, saves `data/daily_analyses.json`, and serves `GET /daily_analyses`. Flutter push notifications are client-side only.
2. **After batch save** — a background task posts a thread to X (header + one reply per coin).
3. **Backup scheduler** — 2 minutes after 7:30 AM, reads persisted analyses and posts if not already posted today (`data/x_daily_posts.json` dedupes).
4. **Optional Railway cron** — `POST /internal/cron/post_daily_x` with `X-Cron-Secret` header.

## Railway variables

| Variable | Required | Description |
|----------|----------|-------------|
| `X_DAILY_POST_ENABLED` | Yes | `true` to enable |
| `X_API_KEY` | Yes | Twitter app API key (Consumer Key) |
| `X_API_SECRET` | Yes | Twitter app API secret |
| `X_ACCESS_TOKEN` | Yes | User access token for @OnChainOracleA |
| `X_ACCESS_TOKEN_SECRET` | Yes | User access token secret |
| `X_ACCOUNT_HANDLE` | No | Default `@OnChainOracleA` |
| `X_DAILY_POST_COINS` | No | Default `BTC,ETH,SOL,XRP` |
| `X_DAILY_POST_DELAY_SECONDS` | No | Backup scheduler delay (default `120`) |
| `X_CRON_SECRET` | Cron only | Secret for `/internal/cron/post_daily_x` |

Bearer token alone cannot create tweets — use OAuth 1.0a User Context credentials from the [X Developer Portal](https://developer.x.com/).

## Tweet format

**Header**
- Date, coins, thread intro, `#OnChainOracle #Crypto #Trading`

**Per coin (reply)**
- Coin + bias (Bullish / Bearish / Neutral) + conviction %
- Entry, TP1 (40%), TP2 (60%), SL
- Confluence summary (truncated)
- `#OnChainOracle #Crypto #BTC` (coin-specific tags)

## Railway cron (optional)

Create a cron job that runs daily at **7:32 AM America/Chicago** (after analyses finish):

```bash
curl -X POST "https://ocoai-app-production.up.railway.app/internal/cron/post_daily_x" \
  -H "X-Cron-Secret: YOUR_X_CRON_SECRET"
```

Schedule in cron UTC: `32 13 * * *` (CDT) or `32 12 * * *` (CST) — adjust for DST as needed, or rely on the in-process schedulers.

## Manual test (local)

```bash
cd backend
pip install -r requirements.txt
# Set X_* vars in .env with X_DAILY_POST_ENABLED=true
python -c "
from x_daily_poster import format_coin_tweet, parse_report_metadata
from api import parse_trade_levels, format_usd
sample = {'coin': 'BTC', 'report': open('data/daily_analyses.json').read()}
"
```

Or trigger cron endpoint after today's batch exists on disk.

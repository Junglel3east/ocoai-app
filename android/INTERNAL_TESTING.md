# Google Play Internal Testing — On-Chain Oracle AI

**Package:** `com.onchainoracleai.app`  
**Backend:** `https://ocoai-app-production.up.railway.app`  
**Version:** `1.0.1` (versionCode `2`)

> This is a **Flutter** app (Dart). Native Android/Jetpack Compose is not used — the Android shell hosts the Flutter engine. All product logic lives in `lib/`.

## What's in this build

- Railway backend for Grok analysis, trade setups, Citadel execution, daily analyses
- **Live + Demo** BloFin via Oracle Citadel Setup (toggle + separate API keys/passphrase)
- **Push to X** on analysis reports, daily analysis cards, and news headlines (opens X compose)
- Server **automated daily X threads** (BTC/ETH/SOL/XRP at 7:30 AM Chicago) when `X_DAILY_POST_ENABLED=true` on Railway
- Google Play Billing scaffolding (`premium_monthly`, `expert_monthly`)

## 1. Signing (one-time)

See `android/PLAY_STORE_RELEASE.md` for keystore + `android/key.properties`.

## 2. Build signed App Bundle

```powershell
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
cd c:\Users\codym\Documents\OCO_AI_APP\on_chain_oracle_ai
flutter clean
flutter pub get
flutter build appbundle --release
```

**Output:** `build\app\outputs\bundle\release\app-release.aab`

On Windows, a “failed to strip debug symbols” warning may appear with exit code 1 — if the `.aab` file exists (~60 MB), upload it.

Optional dart-defines (no secrets in source):

```powershell
flutter build appbundle --release `
  --dart-define=BACKEND_BASE_URL=https://ocoai-app-production.up.railway.app `
  --dart-define=NEWS_API_KEY=your_newsapi_key_if_needed
```

## 3. Upload to Play Console — Internal Testing

1. [Google Play Console](https://play.google.com/console) → **On-Chain Oracle AI**
2. **Testing → Internal testing** → **Create new release**
3. Upload `app-release.aab`
4. Release name: `1.0.1 (2)` — Internal testing
5. Release notes: `play/release-notes/en-US/default.txt`
6. Add testers (email list or Google Group) → **Save** → **Review release** → **Start rollout to Internal testing**

### First-time app setup checklist

| Item | Value |
|------|--------|
| Application ID | `com.onchainoracleai.app` |
| Privacy policy | https://onchainoracleai.com/privacy |
| App category | Finance (educational — not financial advice) |
| Data safety | Declare network, purchases, optional photos (profile) |
| Subscriptions | `premium_monthly` ($39), `expert_monthly` ($79) |

## 4. Railway (already live)

Confirm health:

```powershell
curl https://ocoai-app-production.up.railway.app/health
```

Citadel live trades require re-saving BloFin keys with **API Passphrase** in Oracle Citadel Setup after this build.

## 5. Wireless install to phone (dev)

```powershell
flutter build apk --release
flutter install --release -d <device-id>
```

Use `flutter devices` when wireless debugging is connected.

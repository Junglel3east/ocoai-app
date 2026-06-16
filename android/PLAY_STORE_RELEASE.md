# Google Play production release (On-Chain Oracle AI)



**Application ID:** `com.onchainoracleai.app`  

**Version:** `1.0.0` (versionCode `1`) — from `pubspec.yaml`



## Pre-upload checklist



- [ ] `android/app/build.gradle.kts` → `applicationId = "com.onchainoracleai.app"`

- [ ] Release keystore configured (`android/key.properties` + `app/upload-keystore.jks`)

- [ ] Google Play subscriptions created: `premium_monthly` ($39), `expert_monthly` ($79)

- [ ] Privacy policy URL: https://onchainoracleai.com/privacy

- [ ] Release notes: `play/release-notes/en-US/default.txt`

- [ ] Firebase (optional push): add `android/app/google-services.json` + real values in `lib/firebase_options.dart`



## 1. Create upload keystore (one-time)



**Option A — Android Studio (recommended on Windows)**



1. Open `on_chain_oracle_ai/android` in Android Studio.

2. **Build → Generate Signed App Bundle / APK…**

3. Create new keystore → save as `android/app/upload-keystore.jks`, alias `upload`.

4. Copy `android/key.properties.example` → `android/key.properties` and fill in passwords.



**Option B — keytool (if Java is on PATH)**



From the `android` folder:



```powershell

keytool -genkey -v -keystore app/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload

Copy-Item key.properties.example key.properties

```



Edit `key.properties`:



```properties

storePassword=YOUR_KEYSTORE_PASSWORD

keyPassword=YOUR_KEY_PASSWORD

keyAlias=upload

storeFile=upload-keystore.jks

```



**Never commit** `key.properties` or `*.jks` (already in `.gitignore`). Back up the keystore — losing it blocks future updates on Play.



## 2. Google Play Console subscriptions



Create auto-renewing subscriptions with these **Product IDs** (must match exactly):



| Product ID        | Tier    | Price   |

|-------------------|---------|---------|

| `premium_monthly` | Premium | $39/mo  |

| `expert_monthly`  | Expert  | $79/mo  |



## 3. Build the release App Bundle



From the project root (`on_chain_oracle_ai`):



```powershell

flutter clean

flutter pub get

flutter build appbundle --release

```



**Output:** `build/app/outputs/bundle/release/app-release.aab`



On Windows you may see `Release app bundle failed to strip debug symbols` with exit code 1. If `app-release.aab` exists (~60 MB), the bundle is still valid for Play Console upload.



Without `key.properties`, the build uses **debug signing** — Play Console will reject it. Configure release signing first (step 1).



## 4. Upload to Play Console



1. [Google Play Console](https://play.google.com/console) → **On-Chain Oracle AI**

2. **Release → Production** (or Internal testing first)

3. **Create new release** → Upload `app-release.aab`

4. Confirm package name: `com.onchainoracleai.app`

5. Paste release notes from `play/release-notes/en-US/default.txt`

6. Complete **App content** (privacy policy, financial/crypto disclaimers, target audience)



### Store listing reminders



- App name: **On-Chain Oracle AI**

- Category: Finance (educational analysis — not financial advice)

- Oracle Citadel: non-custodial; users connect their own exchange API keys

- Billing permission is declared for in-app subscriptions



## 5. Verify build locally (optional)



```powershell

# Confirm AAB exists and size

Get-Item build/app/outputs/bundle/release/app-release.aab | Format-List Name, Length, LastWriteTime

```



After release signing, jarsigner/apksigner will show your upload certificate (not "CN=Android Debug").



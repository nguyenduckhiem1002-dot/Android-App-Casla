# Android production flavors and signing

The Android app has three explicit flavors:

- `dev` — application ID suffix `.dev`, app name `Casla Dev`.
- `staging` — application ID suffix `.staging`, app name `Casla Staging`.
- `production` — no suffix, intended for the store/distributed PDA build.

## Application ID

The repository deliberately keeps `com.example.casla_production` as a non-production placeholder because the official package identity has not been confirmed in source control.

Set the real production identity with either a Gradle property or environment variable:

```text
CASLA_ANDROID_APPLICATION_ID=com.yourcompany.casla
```

A `productionRelease` task fails closed while the placeholder is still active.

## Production signing

Never commit a keystore or credentials. The repository ignores `key.properties`, `*.jks`, and `*.keystore` files.

CI/CD should inject these variables only for an authorized release job:

```text
CASLA_ANDROID_STORE_FILE=/secure/path/casla-upload.jks
CASLA_ANDROID_STORE_PASSWORD=...
CASLA_ANDROID_KEY_ALIAS=...
CASLA_ANDROID_KEY_PASSWORD=...
```

For a local release, `android/key.properties` is also supported using the standard keys:

```properties
storeFile=/secure/path/casla-upload.jks
storePassword=...
keyAlias=...
keyPassword=...
```

The production release configuration never falls back to the Android debug key. Any production release task runs `verifyCaslaSigning` first and fails if the official application ID, keystore, alias, or passwords are missing.

## Commands

Development/staging verification:

```bash
flutter run --flavor dev
flutter run --flavor staging
```

Production-like CI build without release secrets:

```bash
flutter build apk --debug --flavor production
```

Authorized production bundle after the real ID and signing secrets are configured:

```bash
flutter build appbundle --release --flavor production
```

Before distributing an AAB/APK, also confirm the SAP production endpoint, disable demo data, enroll the upload key with the chosen store/MDM process, and retain the keystore in an organization-controlled secret store.

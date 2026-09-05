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

The production release configuration never falls back to the Android debug key.

## Production SAP transport

Direct Basic transport is retained only for development/staging against SAP. A production binary must not contain a shared SAP service account.

Production therefore requires this Dart define:

```text
SAP_TRANSPORT_AUTH_MODE=gateway
```

Do **not** pass either of these to a production build:

```text
SAP_BASIC_AUTH_USER
SAP_BASIC_AUTH_PASSWORD
```

In gateway mode the mobile client sends no shared Basic `Authorization` header. The trusted gateway/API-management layer must own the upstream SAP service credential while preserving the existing RAP user-token payload contract until the backend contract is deliberately changed.

`verifyCaslaSigning` fails if production transport is not `gateway`, if either Basic value is embedded, if demo data is enabled, or if Android identity/signing inputs are incomplete.

## Commands

Development/staging verification:

```bash
flutter run --flavor dev --dart-define=SAP_TRANSPORT_AUTH_MODE=basic
flutter run --flavor staging --dart-define=SAP_TRANSPORT_AUTH_MODE=basic
```

Production-like CI build without release secrets:

```bash
flutter build apk --debug --flavor production
```

Authorized production bundle after the real ID, signing secrets and gateway endpoint are configured:

```bash
flutter build appbundle --release --flavor production \
  --dart-define=SAP_TRANSPORT_AUTH_MODE=gateway \
  --dart-define=SAP_BASE_URL=https://your-gateway.example/sap/opu/odata4/sap/
```

Before distributing an AAB/APK, confirm that the gateway is deployed and owns the upstream SAP credential, disable demo data, enroll the upload key with the chosen store/MDM process, and retain the keystore in an organization-controlled secret store.

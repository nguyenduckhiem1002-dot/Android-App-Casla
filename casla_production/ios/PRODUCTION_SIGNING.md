# iOS production identity and signing

The checked-in Xcode project intentionally still uses a `com.example...` bundle identifier because the official Casla iOS identity has not been supplied. The compile-only CI job disables code signing and must not be treated as a distributable build.

## Required production identity

An authorized distribution pipeline must provide at least:

```text
CASLA_IOS_BUNDLE_ID=com.yourcompany.casla
CASLA_IOS_TEAM_ID=YOURTEAMID
```

Run the repository guard before any archive/export step:

```bash
bash ios/verify_production_identity.sh
```

The guard fails closed when the bundle ID is missing/placeholder or the Apple Team ID is missing.

## Signing material

Do not commit certificates, private keys, provisioning profiles or App Store Connect credentials. Store them in an organization-controlled secret store / GitHub Environment and inject them only into an approved release job.

A real App Store/TestFlight or MDM pipeline additionally needs the chosen distribution certificate/profile (or managed signing credentials), an export configuration, and any App Store Connect API key required by the deployment mechanism.

When the distribution job is implemented, override the checked-in placeholder with the authorized identity, for example through Xcode build settings such as `PRODUCT_BUNDLE_IDENTIFIER="$CASLA_IOS_BUNDLE_ID"` and `DEVELOPMENT_TEAM="$CASLA_IOS_TEAM_ID"`, then sign/export the archive. The existing `--no-codesign` CI path is compile validation only.

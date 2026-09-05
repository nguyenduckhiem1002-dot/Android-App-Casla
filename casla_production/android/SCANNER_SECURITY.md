# CipherLab RS38 scanner security

The Android scanner integration deliberately avoids bundling CipherLab's proprietary Reader SDK. It receives ReaderConfig/Reader Service barcode output through the documented broadcast action:

```text
com.cipherlab.barcodebaseapi.PASS_DATA_2_APP
```

Because Reader Service is a different application, the runtime receiver must remain exported. `RECEIVER_NOT_EXPORTED` would prevent the real CipherLab service from delivering scans and is therefore not a valid security fix by itself.

## Trust model

The broadcast is **input**, not authorization. A scan may select a worker/order candidate, but role, work scope, password verification, idempotency and mutation authorization remain server-side responsibilities.

The app applies the following controls before a hardware scan reaches Flutter:

1. The receiver exists only while the activity is started **and** Flutter has an active scanner listener.
2. On Android 14/API 34 and newer, `BroadcastReceiver.getSentFromPackage()` must identify one of the known CipherLab sender packages:
   - `com.cipherlab.clbarcodeservice` — Reader Service.
   - `sw.programme.readerconfig` — ReaderConfig.
3. Only `Decoder_Data` is accepted. The bridge deliberately does not fall back to `Original_Decoder_Data`, because CipherLab documents `Decoder_Data` as the value after ReaderConfig processing.
4. Barcode values must be `String`/`ByteArray`, are bounded to 4096 characters / 8192 bytes, and embedded NUL is rejected.
5. Symbology metadata is type-checked and bounded.
6. Flutter validates the platform event envelope again and rejects unknown sources instead of defaulting them to `hardware`.
7. Worker QR parsing has an independent 4096-character/NUL bound and extracts only an employee code. Master data and permissions are resolved separately.

The pure native policy is covered by JVM unit tests in `CipherLabBroadcastPolicyTest`; CI runs `:app:testProductionDebugUnitTest` before the production-flavor APK build.

## Android 13 and older: residual risk

`BroadcastReceiver.getSentFromPackage()` was added in API 34. On Android 13/API 33 and older, the current implicit CipherLab broadcast contract does not provide an equivalent trustworthy sender identity to this runtime receiver.

Therefore those devices remain **legacy sender-unverified**. Input validation, foreground-only registration and backend authorization reduce impact, but they do not cryptographically prove who emitted the broadcast.

Do not claim this risk is eliminated until at least one of these is available and validated on the deployed RS38 firmware:

- a CipherLab sender permission/signature permission for `PASS_DATA_2_APP`;
- a vendor-supported explicit/package-targeted output contract that can be authenticated;
- a Reader SDK/service API with a stronger caller boundary;
- an OS/firmware upgrade where sender identity can be verified reliably.

## Device-management controls

For managed RS38 deployments, lock ReaderConfig/reader-output settings through the organization's supported CipherLab ADC/MDM configuration so ordinary users cannot change the scanner output contract. This is an operational hardening layer, not a replacement for sender authentication.

## Required physical-device verification

Before rollout, exercise at least:

- Android 13 RS38: valid scan, rapid repeated trigger, sleep/resume and app foreground/background transitions.
- Android 14+ RS38 if available: confirm real Reader Service broadcasts are accepted by the sender-package allowlist.
- Attempt a broadcast from a test/spoof app on Android 14+: it must not create a scan event.
- Oversized, malformed and NUL-containing payloads: they must be dropped without crash/UI corruption.
- Camera/manual fallback: valid worker QR still parses, malformed payload remains rejected.

If an Android 14+ CipherLab firmware reports a different legitimate sender package, do not broaden the allowlist from guesswork. Capture the sender identity on the managed device, verify it against CipherLab documentation/support, then update the allowlist with a regression test.

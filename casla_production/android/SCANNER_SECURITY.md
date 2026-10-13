# PDA scanner security

The app captures barcodes through two independent paths, neither of which links a proprietary Reader SDK.

## Path 1 — vendor broadcast (fast, attributable, per-vendor)

Reader services broadcast decoded data using their own documented app-output action. `ScannerBroadcastPolicy` holds one entry per supported vendor: the action, the extras carrying the processed value and symbology, and the reader-service packages allowed to emit it.

Currently configured: CipherLab, Zebra DataWedge, Honeywell/Intermec, Newland, Urovo, Sunmi.

Because reader services are separate applications, the runtime receiver must remain exported. `RECEIVER_NOT_EXPORTED` would stop real hardware scans and is therefore not a valid fix on its own.

## Path 2 — keyboard wedge (universal, unattributable)

PDAs configured for "keyboard wedge" output type the decoded barcode as keyboard input, optionally followed by a terminator. `WedgeBarcodeScanner` reads that input, including on handsets outside the vendor list. The device's actual output configuration must be checked; this mode is not a universal factory default.

Wedge input carries **no sender identity at all** — it is indistinguishable from a physical keyboard by construction. It is therefore the weaker of the two paths in attribution terms, and the controls below matter more for it, not less.

The previous implementation gated all scanning on `Build.MANUFACTURER`/`Build.MODEL` containing "cipherlab" or "RS38". That was not a security control — it blocked legitimate hardware and stopped no attacker — and it has been removed. Device detection is now a *hint* that chooses which UI to show; a technician can override it from the Account screen.

## Trust model

A scan is **input**, not authorization. It may select a worker/order candidate. Role, work scope, password verification, idempotency and mutation authorization remain server-side responsibilities.

Controls applied before a scan reaches Flutter:

1. The receiver exists only while the activity is started **and** Flutter has an active scanner listener. The wedge handler is likewise attached only while a screen is listening, and steps aside entirely when a text field holds focus.
2. On Android 14/API 34+, sender identity is checked in four descending steps (`ScannerBroadcastPolicy.verifySender`). Whichever step answers first decides:
   1. `BroadcastReceiver.getSentFromPackage()` names a package — it must belong to **the same vendor as the action received**. A package cannot borrow another vendor's action; a named-but-wrong package is rejected outright, with no fallback to the steps below.
   2. No package was named — `getSentFromUid()` is resolved through `PackageManager.getPackagesForUid()`, and one of those packages must be in the same vendor's allowlist.
   3. A uid was named but resolved to nothing in the vendor allowlist — it must be **privileged** (an OS-image uid, i.e. app id below 10000). An installed third-party app cannot hold one, so a spoofer cannot get in merely by being unattributed.
   4. **Neither a package nor a uid was named at all** — accepted on the action + payload rules alone, the same basis pre-34 Android already uses. Observed for real: a Zebra TC22 delivering DataWedge's own broadcast gave `getSentFromPackage()` *and* `getSentFromUid()` both empty, not just the package. Step 3's uid check has nothing to evaluate in that case, and continuing to reject would have made this specific, real hardware strictly worse off than Android 13 for a check that verifies nothing.

   Steps 2–4 exist because the platform frequently declines to attribute these broadcasts on real hardware, and requiring step 1 alone made the scanner unusable on the exact devices this app is deployed to. Steps 3 and 4 are genuine relaxations, both recorded under residual risk below. Step 4 is deliberately distinct from step 3 in the trace (`ACCEPTED_NO_ATTRIBUTION` vs `ACCEPTED_UNATTRIBUTED_SYSTEM`/`ACCEPTED_BY_UID`) — a *known*, non-privileged, non-vendor uid must still hit `REJECTED_UNATTRIBUTED`; only a platform that hands back nothing at all falls through to step 4.
3. An action not present in `ScannerBroadcastPolicy.vendorBroadcasts` is rejected outright, on every Android version.
4. Only the documented processed-value extras are read. The bridge deliberately does not fall back to raw/original decoder values, which would bypass the device-side configuration the site set.
5. Barcode values must be `String`/`ByteArray`, are bounded to 4096 characters / 8192 bytes, and embedded NUL is rejected.
6. Symbology metadata is type-checked and bounded.
7. Flutter validates the platform event envelope again and rejects unknown sources instead of defaulting them to `hardware`.
8. The wedge buffer is bounded to 4096 characters, drops control characters, and requires a burst to be long enough and fast enough to be machine-typed before publishing anything.
9. Worker QR parsing has an independent 4096-character/NUL bound. Scanning accepts the QR identity/display name locally and checks its validity dates without requiring master-data membership or local team scope. This trusts the QR for selection, not authentication; SAP still verifies passwords and authorization on writes.
10. A valid worker JSON card is accepted locally without checking catalogue membership or calling SAP. Its dates are checked and its department is retained. An ambiguous plain code not in the local catalogue requires confirmation before creating a worker; retail-shaped codes receive a stronger accidental-scan warning.

The pure native policy is covered by JVM unit tests in `ScannerBroadcastPolicyTest`; CI runs `:app:testProductionDebugUnitTest` after generating the Android wrapper through the production-flavor build. The Dart-side wedge rules are covered by `test/core/wedge_scan_buffer_test.dart` and `test/core/wedge_barcode_scanner_test.dart`.

## Package visibility

`installedReaderServices()` probes for known reader-service packages to decide whether a handset looks like a data-capture device. Android 11+ hides other packages unless declared, so `AndroidManifest.xml` lists them under `<queries>`. That grants visibility only: the app never starts, binds to, or sends anything to those packages.

## Android 13 and older: residual risk

`BroadcastReceiver.getSentFromPackage()` was added in API 34. On Android 13/API 33 and older, the vendor broadcast contracts do not provide an equivalent trustworthy sender identity to a runtime receiver.

Those devices remain **legacy sender-unverified**. Input validation, foreground-only registration, listener-scoped registration and backend authorization reduce impact, but they do not prove who emitted the broadcast.

On Android 14+ the same gap reappears when step 3 or step 4 admits an unattributed broadcast. On the reported Zebra TC22, DataWedge supplies neither package nor uid, reaching `ACCEPTED_NO_ATTRIBUTION`. This is compatibility behavior, **not sender authentication**. An ordinary third-party app can also omit identity sharing: Android's `BroadcastOptions.setShareIdentityEnabled` defaults to false. Such an app can spoof a known action and valid-looking payload. A known wrong package/uid is rejected, but missing identity does not prove a system sender. See [Android BroadcastOptions](https://developer.android.com/reference/android/app/BroadcastOptions#setShareIdentityEnabled(boolean)). Treat every accepted scan as untrusted input; it must never submit a business transaction without the normal user confirmation, password and SAP authorization.

The keyboard-wedge path is sender-unverified on **every** Android version, by the nature of keyboard input.

Do not claim this risk is eliminated until at least one of these is available and validated on deployed firmware:

- a vendor sender/signature permission for the output action;
- a vendor-supported explicit/package-targeted output contract that can be authenticated;
- a Reader SDK/service API with a stronger caller boundary;
- an OS/firmware upgrade where sender identity can be verified reliably.

## Device-management controls

For managed deployments, lock reader-output settings and app installation through the organization's supported ADC/MDM configuration. Vendor broadcasts avoid competing with text fields; attribution on Android 14+ is available only when the sender identity is exposed.

This is operational hardening, not a replacement for sender authentication.

## Required physical-device verification

### Collecting a scanner trace (including release APKs)

1. Open Account > Đầu đọc mã vạch > Xóa log quét.
2. Open the affected scan screen and pull the trigger at the QR two or three times.
3. Return to Account > Đầu đọc mã vạch > Sao chép log quét.
4. Share that copied report with support before force-closing the app.

Each layer retains at most 120 events in memory. Copy fetches the latest native
snapshot, including Android key-down/ACTION_MULTIPLE counters observed while a
scanner listener exists. These counters describe input delivery, not successful
QR decoding. No scan text, characters, parser error strings or passwords enter
the event buffers. Debug builds separately print accepted QR payloads to
logcat for local USB-debugging sessions, with password/token/secret fields
redacted. Review business data before sharing those debug logs.
`SENDER_UNAVAILABLE`/`SENDER_REJECTED` entries additionally
carry the rejected sender's package name (`sender=com.symbol.datawedge`) —
device/app identity, not scan content, and the only reason to widen the vendor
allowlist for a real device is knowing that exact value instead of guessing.
The report is copied only on user action and is not uploaded.

For a USB-connected PDA, native decision events and hardware QR payloads can
also be watched with `adb -s <device-serial> logcat -s CaslaScan:I`. Camera and
keyboard-wedge QR payloads use Flutter's `flutter` tag; use
`adb -s <device-serial> logcat -s CaslaScan:I flutter:I` to watch all sources.
The `flutter run` terminal also shows the QR payload lines in a debug build.
Payload logging is disabled in release builds.

- `BROADCAST_RECEIVED` -> `SENDER_UNAVAILABLE` / `SENDER_REJECTED` (see the
  `sender=` and `uid=` fields on that line): sender policy turned it away. If
  `SENDER_UNAVAILABLE` carries no `uid=` field at all, the platform gave no
  uid either — see `SENDER_ACCEPTED_UNATTRIBUTED` below for what that becomes
  once step 4 is reached.
- `BROADCAST_RECEIVED` -> `SENDER_ACCEPTED_BY_UID`: the platform named no sender
  package, and the broadcast was admitted on the uid instead (step 2 or 3
  above). The `sender=` field shows which packages that uid resolved to, or
  `none` when it resolved to nothing but the uid was still privileged.
- `BROADCAST_RECEIVED` -> `SENDER_ACCEPTED_UNATTRIBUTED`: step 4 — the platform
  named neither a package nor a uid. Expected on a Zebra TC22 delivering
  DataWedge's own broadcast; nothing was verified for this scan.
- `PAYLOAD_REJECTED`: none of the configured processed-data extras was usable.
- `FORWARDED_TO_DART` -> `eventReceived`: native-to-Flutter delivery succeeded.
- Android key counters rising without `wedgeBurst`: inspect keyboard delivery/focus.
- `wedgeRejected`: input burst did not meet length/timing rules.
- `ignoredInactive`: route/tab/dialog is preventing consumption.
- `classifiedUnknown` / `callbackRejected`: app validation rejected the scan.
- `channelError` / `invalidEnvelope`: platform channel or event-shape problem.

An absent broadcast event does not prove the reader failed to decode: an output
action outside the registered vendor contracts never reaches this receiver.
`receiverRegistered=false` on Account is normal when no scan screen is listening;
check the preceding registration events when interpreting the trace.

Not yet performed. Before rollout, exercise at least:

- Each PDA model in the fleet, in both broadcast mode and wedge mode: valid scan, rapid repeated trigger, sleep/resume, app foreground/background.
- A handset belonging to no configured vendor: confirm the wedge path still captures, and that the Account screen's manual override works.
- Wedge with a text field focused: the reader's output must land in the field, and must not also fire the screen's scan handler.
- Android 14+ where available: confirm real reader broadcasts are accepted by the per-vendor sender allowlist.
- A broadcast from a test app on Android 14+: an attributed wrong vendor must be rejected. With identity sharing disabled, the compatibility path can accept a scan candidate; verify that it cannot bypass user confirmation, worker password or SAP authorization.
- Oversized, malformed and NUL-containing payloads: dropped without crash or UI corruption.
- Camera/manual fallback: valid worker QR still parses, malformed payload still rejected.
- A carton barcode scanned on the worker field: the "possible mis-scan" confirmation must appear, and declining it must leave the catalogue unchanged.

If a firmware reports a different legitimate sender package, do not broaden the allowlist from guesswork. Capture the sender identity on the managed device, verify it against vendor documentation/support, then update `ScannerBroadcastPolicy` with a regression test.

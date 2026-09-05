# Supply-chain security

This repository uses source-controlled automation for dependency hygiene and native-code SAST, but repository settings remain a separate security boundary. A green workflow is useful only if the default branch is configured to require the relevant checks before merge.

## Automated dependency updates

`.github/dependabot.yml` monitors three ecosystems every week:

- Dart/Flutter (`pub`) under `/casla_production`.
- Android build dependencies (`gradle`) under `/casla_production/android`.
- GitHub Actions under `/.github/workflows`.

Version-update PRs intentionally ignore semantic-version **major** upgrades. Minor and patch updates are grouped per ecosystem to reduce PR noise. Major Flutter/plugin/toolchain upgrades stay deliberate because this project has known SDK/Xcode compatibility pins and every major upgrade needs the full platform gate.

This policy does not suppress Dependabot security alerts or replace review of a security update. A vulnerable package may justify an otherwise-disallowed major upgrade; handle that as a deliberate remediation PR with the normal CI/security checks.

## Dependency review

`.github/workflows/dependency-review.yml` runs on pull requests and fails when a dependency change introduces a known vulnerability with severity `high` or `critical`.

The workflow uses `actions/dependency-review-action` v5 on its Node 24 generation. Dependency review compares the dependency graph between the base and head revisions. It is a merge gate for dependency changes, not a general vulnerability scanner for unchanged dependencies. Existing alerts still need normal Dependabot/security-alert triage.

## CodeQL scope

`.github/workflows/codeql.yml` uses CodeQL Action v4 and manual production-like builds for:

- `java-kotlin`: Android/Kotlin sources, including the CipherLab native bridge.
- `swift`: iOS Swift sources.

Kotlin is extracted from the production-flavor Android build. For Swift, a normal `flutter build ios` is first used to generate Flutter/Xcode inputs; CodeQL is then initialized and a clean direct `xcodebuild` is run under the tracer with a fresh DerivedData directory. The traced build is restricted to `arm64` so the macOS runner does not compile an unnecessary second architecture.

CodeQL runs on `master`, on pull requests (including temporary stacked `chatgpt/**` bases used during phased hardening), and weekly. It does **not** run on every feature-branch push; the faster Flutter CI still does. This keeps the expensive native/macOS scan at review/default-branch boundaries while preserving stable PR check names that can be required by branch protection.

Do not add workflow-level `paths` filters to a CodeQL workflow that is configured as a required status check. GitHub can leave a path-filtered workflow pending and block merge. If native scan cost needs further optimization, keep the workflow triggered and use job-level conditions so a non-applicable job reports a skipped/successful conclusion.

**Dart is not a CodeQL-supported language.** Do not report CodeQL as SAST coverage for the Flutter/Dart application layer. Dart remains covered by `flutter analyze`, the test suite, dependency review/Dependabot and focused security tests in source. If a dedicated Dart SAST product is introduced later, evaluate its false-positive profile and privacy/retention model before making it required.

## GitHub Actions runtime and pinning

Direct third-party/action dependencies in the source-controlled CI/security workflows are pinned to immutable full commit SHAs, with the intended release kept in an inline comment for reviewability and Dependabot tracking. This reduces the trust placed in mutable major-version tags.

Current direct action lines include:

- `actions/checkout` pinned to the v6 commit used by the Node 24 generation.
- `subosito/flutter-action` pinned to the reviewed v2 commit.
- `github/codeql-action` pinned to the reviewed v4 commit.
- `actions/dependency-review-action` pinned to the reviewed v5.0.0 commit.

Dependabot continues to monitor GitHub Actions. A future action update must change the pinned SHA through a reviewed dependency PR rather than silently following a moved tag.

## Required repository-side settings

These controls cannot be guaranteed by files in the repository alone. Configure them in GitHub repository/organization administration and verify them after any ownership or plan change.

On 2026-09-05, the repository rulesets endpoint returned an empty list and branch metadata reported `master` as `protected: false` with required-status-check enforcement `off`. Therefore the checks below are currently advisory until repository administration is changed. Tracking issue: #19.

1. Protect `master` with a ruleset or branch protection that requires pull requests and blocks direct/force pushes.
2. Require the primary CI jobs before merge:
   - `Dart analyze and tests`
   - `Android / PDA build`
   - `iOS / Xcode build`
3. Require security checks:
   - `Dependency Review`
   - `CodeQL Java/Kotlin`
   - `CodeQL Swift`
4. Require at least one independent review for production-impacting changes and resolve review conversations before merge.
5. Enable dependency graph, Dependabot alerts, secret scanning and push protection where the GitHub plan/repository type supports them.
6. Store signing keys, gateway credentials and deployment tokens only in environment/organization secrets. Use a protected `production` environment with explicit approval for release jobs.
7. Do not grant write-capable workflow tokens globally. Workflows should declare the narrowest `permissions` they need.

A source PR can add or improve checks, but it cannot make those checks mandatory if branch/ruleset administration does not require them.

## Review rules for dependency PRs

Do not merge dependency updates solely because Dependabot opened them. For each update:

- read upstream release/security notes;
- verify the lockfile diff is consistent with the requested package change;
- keep Flutter `3.44.8`/Xcode compatibility constraints in mind;
- run the full Flutter/Android/iOS matrix;
- for Android native changes, keep the scanner JVM policy test green;
- for major upgrades, use a dedicated PR even if Dependabot/security remediation suggests urgency.

## Residual coverage gaps

- Pub support in Dependabot is community-maintained, so failed update resolution must be investigated rather than treated as proof that no update exists.
- Gradle version updates can update direct manifest declarations, but complete transitive dependency visibility may require dependency-submission integration depending on how the build graph is resolved.
- CodeQL does not cover Dart.
- CodeQL/dependency review findings are only enforceable after GitHub branch/ruleset settings require those checks; `master` is currently unprotected.
- Secret scanning/push-protection state has not been verified through the available connector and must not be assumed enabled.
- No source-controlled tool can replace production signing, gateway, MDM/device and SAP authorization controls documented in `PRODUCTION_READINESS.md`.

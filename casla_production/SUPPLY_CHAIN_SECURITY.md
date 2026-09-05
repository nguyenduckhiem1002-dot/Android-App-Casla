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

Dependency review compares the dependency graph between the base and head revisions. It is a merge gate, not a general vulnerability scanner for unchanged dependencies. Existing alerts still need normal Dependabot/security-alert triage.

## CodeQL scope

`.github/workflows/codeql.yml` uses CodeQL Action v4 and manual production-like builds for:

- `java-kotlin`: Android/Kotlin sources, including the CipherLab native bridge.
- `swift`: iOS Swift sources.

The workflow runs on protected-branch/feature-branch changes and weekly, and cancels stale runs on the same ref.

**Dart is not a CodeQL-supported language.** Do not report CodeQL as SAST coverage for the Flutter/Dart application layer. Dart remains covered by `flutter analyze`, the test suite, dependency review/Dependabot and focused security tests in source. If a dedicated Dart SAST product is introduced later, evaluate its false-positive profile and privacy/retention model before making it required.

## GitHub Actions runtime

Source-controlled workflows use `actions/checkout@v6`, which is on the current Node 24 generation. Dependabot monitors action versions so minor/patch action updates are reviewed like other dependencies.

## Required repository-side settings

These controls cannot be guaranteed by files in the repository alone. Configure them in GitHub repository/organization administration and verify them after any ownership or plan change:

1. Protect `master` with a ruleset or branch protection that requires pull requests and blocks direct/force pushes.
2. Require the primary CI jobs before merge:
   - `Dart analyze and tests`
   - `Android / PDA build`
   - `iOS / Xcode build`
3. Require security checks when they apply:
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
- CodeQL/dependency review findings are only enforceable if GitHub branch/ruleset settings require those checks.
- No source-controlled tool can replace production signing, gateway, MDM/device and SAP authorization controls documented in `PRODUCTION_READINESS.md`.

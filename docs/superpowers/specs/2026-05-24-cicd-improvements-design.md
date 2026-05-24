# CI/CD: PR-driven release-on-merge with safety nets

**Status:** Designed, not implemented
**Date:** 2026-05-24
**Author:** Anand Badari, with Claude

## Goal

Every merged PR triggers an automated path to a real release. No hand-cranked tags. No direct commits to `main`. The release path runs constantly, so brittleness surfaces immediately rather than at "release time."

## Scope

In scope:
- Branch protection on `main` (PRs only, required checks)
- Conventional Commits enforced via PR title lint
- `release-please` to manage version bumps + tag cutting via a "Release PR"
- One repo-wide version across worker + iOS + tvOS + Android
- Workflow consolidation: 7 → 5 files
- Build-once-then-reuse-artifact (eliminate the current rebuild during release)
- Lint: SwiftLint, ktlint, Prettier
- Tests: wire existing Swift tests into CI, write minimal Kotlin + worker tests
- Post-deploy smoke check on the worker

Out of scope (explicit deferrals):
- Signing automation (Apple proper signing, Android keystore) — separate project
- Lint/tests for the iOS/tvOS app layer (only `CastTVShared` is tested today)
- Worker integration tests against real Cloudflare (only unit tests on routing logic)
- Per-platform versioning
- Dependabot
- PR previews (Cloudflare worker preview URLs)
- Richer release-note generation beyond release-please defaults

## The new flow

```
       open PR
          │
          ▼
   ┌─────────────────────────────────────────────┐
   │ Required PR checks (block merge if any fail)│
   │  • PR title is Conventional Commits         │
   │  • apple.yml / build  (build, tests, lint)  │
   │  • android.yml / build (build, tests, lint) │
   │  • worker.yml / build (build, tests, lint)  │
   └─────────────────────────────────────────────┘
          │ (all green → squash-merge)
          ▼
   ┌─────────────────────────────────────────────┐
   │ release-please reads new commits on main    │
   │  • feat:/fix:/breaking → opens/updates       │
   │    "Release PR" with version bump + notes   │
   │  • otherwise no-op                          │
   └─────────────────────────────────────────────┘
          │ (manual merge of Release PR when ready to ship)
          ▼
   ┌─────────────────────────────────────────────┐
   │ release-please creates tag v1.x.y           │
   └─────────────────────────────────────────────┘
          │
          ▼
   ┌─────────────────────────────────────────────┐
   │ apple.yml release job  ─┐                   │
   │ android.yml release job ─┼─ run in parallel │
   │ worker.yml release job  ─┘  (smoke check)   │
   └─────────────────────────────────────────────┘
          │
          ▼
       artifacts on GitHub Release, worker live
```

**Two-click release.** First click: merge a feature PR. Second click: merge the Release PR. The Release PR is the "ship it now" button.

**Conventional Commits drive versioning:**
- `feat:` → minor bump
- `fix:` → patch bump
- `feat!:` or `BREAKING CHANGE:` in body → major bump
- `chore:`, `docs:`, `refactor:`, `style:`, `test:`, `ci:` → no release on their own; pile up until a `feat:`/`fix:` lands

## Workflow inventory

**Before (7 files):**
- `ci-apple.yml`, `ci-android.yml`, `ci-worker.yml`
- `release-apple.yml`, `release-android.yml`, `deploy-worker.yml`
- `update-latest.yml`

**After (5 files):**

| File | Triggers | Responsibilities |
|---|---|---|
| `apple.yml` | PR, push to main, tag `v*` | Build iOS + tvOS, SwiftLint, run Swift tests. On tag: package IPAs, upload to GitHub Release. |
| `android.yml` | PR, push to main, tag `v*` | Build APK, ktlint, run Kotlin tests. On tag: upload APK to GitHub Release. |
| `worker.yml` | PR, push to main, tag `v*` | Type/syntax check, prettier, run worker tests. On tag: `wrangler deploy` + smoke check. |
| `pr-title.yml` | `pull_request` open/edit/synchronize | Validate Conventional Commits prefix in PR title. |
| `release-please.yml` | `push: branches: [main]` | Maintain Release PR; cut tag when it merges. |

**Removed:** `update-latest.yml` — force-pushed a `latest` git tag that nothing references. The landing page uses GitHub's auto-managed `releases/latest/download/...` URL, which is independent of any tag.

## Required-check gating mechanics

The `paths:` filter approach (used today) doesn't compose with required-status-checks. If a workflow doesn't run because no relevant paths changed, GitHub treats the required check as "expected but missing" and blocks the merge — even though nothing relevant changed.

**Solution: fast-skip pattern inside each workflow.** Drop `paths:` from the workflow trigger. The first job uses `dorny/paths-filter@v3` to compute whether real work is needed and outputs a boolean. Downstream jobs gate on that boolean.

For irrelevant PRs: workflow runs, path-check job exits in ~5 seconds, downstream jobs are skipped. GitHub sees a successful workflow, the required check is reported, branch protection is satisfied.

Skeleton of `apple.yml`:

```yaml
on:
  pull_request:
  push:
    branches: [main]
    tags: ['v*']

jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      apple: ${{ steps.filter.outputs.apple }}
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            apple:
              - 'apple/**'
              - 'scripts/build-ffmpeg.sh'
              - '.github/workflows/apple.yml'

  build:
    needs: changes
    if: needs.changes.outputs.apple == 'true' || startsWith(github.ref, 'refs/tags/v')
    runs-on: macos-15
    steps:
      # Cache FFmpeg.xcframework, xcodegen, xcodebuild build,
      # SwiftLint, xcodebuild test, upload .app as artifact.

  release:
    needs: build
    if: startsWith(github.ref, 'refs/tags/v')
    runs-on: macos-15
    steps:
      # Download .app artifact, package into Payload/.ipa, upload to GitHub Release.
```

The `|| startsWith(github.ref, 'refs/tags/v')` clause forces a build on every tag push regardless of which files changed (defensive: ensures the artifact exists for the release job).

**Branch-protection required checks:**
- `apple.yml / build`
- `android.yml / build`
- `worker.yml / build`
- `pr-title.yml / main`

## Version plumbing

Today's state:
- `worker/package.json`: `"version": "1.0.0"`
- `apple/CastTV/CastTV.xcodeproj/project.pbxproj`: no `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION` (defaults to `1.0` / `1`)
- `android/app/build.gradle.kts`: `versionName = "1.0"`, `versionCode = 1`
- Last GitHub tag: `v1.0.2`

**First PR brings all four to `1.0.2`** so release-please starts coherent.

**Apple build settings to add** (all four build configs: iOS Debug/Release, tvOS Debug/Release):

```
MARKETING_VERSION = 1.0.2;
CURRENT_PROJECT_VERSION = 1;
```

release-please updates `MARKETING_VERSION` on each release. `CURRENT_PROJECT_VERSION` is the build number, bumped on every release via an `extra-files` rule.

**release-please-config.json** (repo root):

```json
{
  "release-type": "simple",
  "include-component-in-tag": false,
  "packages": {
    ".": {
      "release-type": "simple",
      "extra-files": [
        {
          "type": "json",
          "path": "worker/package.json",
          "jsonpath": "$.version"
        },
        {
          "type": "generic",
          "path": "android/app/build.gradle.kts"
        },
        {
          "type": "generic",
          "path": "apple/CastTV/CastTV.xcodeproj/project.pbxproj"
        }
      ]
    }
  }
}
```

The `generic` type updates lines tagged with an inline `# x-release-please-version` (Gradle) or `// x-release-please-version` (pbxproj) marker comment. Each version-bearing line gets such a marker.

**.release-please-manifest.json** (repo root): `{".": "1.0.2"}` — initial baseline.

## Merge policy and branch protection

**Squash-merge required.** PR title becomes the squashed commit subject → automatically Conventional Commits on `main` → release-please reads correctly. Disable rebase and merge-commit options in repo settings.

**Release PR is not auto-merged.** release-please opens and updates it; manual merge when ready to ship.

**Branch protection on `main`:**
- Require PR before merging
- Require status checks: `apple.yml / build`, `android.yml / build`, `worker.yml / build`, `pr-title.yml / main`
- Require branches up to date before merging
- Squash-merge only (disable rebase + merge-commit)
- Apply rules to admins (otherwise the lockdown is theatre)

## Smoke check (worker)

After `wrangler deploy` in `worker.yml`'s release job:

```bash
curl -fsS https://cast.anandabadari.com/ > /dev/null
curl -fsS "https://cast.anandabadari.com/room/AAAAAA/status" | jq -e '.appleTvConnected != null' > /dev/null
```

Either failing fails the job. Surfaces the failure in the tag-cut context (visible on the Release PR's tag).

This specifically catches the class of bug we just hit: wrangler v4 silently flipped `workers_dev` off and we only noticed by hand. A smoke check would have failed the deploy immediately.

## Lint and tests

**Lint:**
- Apple: SwiftLint via Mint or Homebrew on runner. Config at `apple/.swiftlint.yml`.
- Android: ktlint via the `org.jlleitschuh.gradle.ktlint` Gradle plugin. Configured in `android/app/build.gradle.kts`.
- Worker: Prettier via npm devDep. Config at `worker/.prettierrc`.

**Tests:**
- Apple: existing `CastTVSharedTests` target already covers Encryption round-trip, QR encode/decode, PlayMessage / CastMessage decode. Just wire `xcodebuild test` into the build job. **Existing tests must pass on first wire-up** (no green-washing — if they fail, fix the underlying code or fix the test, don't disable).
- Android: new `android/app/src/test/java/com/casttv/androidtv/crypto/EncryptionTest.kt`. Cover Encryption round-trip + key import/export + QR-equivalent parsing. ~5 cases.
- Worker: new `worker/test/index.test.mjs` using Node's built-in `node:test`. Cover route matching (`/`, `/room/ABC123/status`, `/room/abc/ws` missing role param, 404 fallback), room-code validation, rate limiter logic. ~10 cases. Pure-function units extracted from the Worker as needed; integration with Durable Objects / real WebSockets out of scope.

## Rollout order

The current state has zero protection on `main`, so we use direct pushes for the bootstrap PRs and enable branch protection last.

1. **PR 1 — Version sync + Apple build settings**: bring worker, Android, Apple to `1.0.2`; add `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` to all four Apple build configs; add release-please marker comments. Direct push acceptable.

2. **PR 2 — Workflow consolidation**: replace 7 files with 5. Add fast-skip pattern. Add `xcodebuild test` to Apple build. Move release steps into per-platform workflows. Delete `update-latest.yml`. Direct push acceptable.

3. **PR 3 — Lint configs**: add SwiftLint, ktlint, Prettier configs and wire them into the build jobs. Fix any violations surfaced. Direct push acceptable.

4. **PR 4 — New tests**: Kotlin EncryptionTest + worker route tests. Wire `./gradlew test` and `npm test` into respective build jobs. Direct push acceptable.

5. **PR 5 — release-please**: add `release-please.yml`, `release-please-config.json`, `.release-please-manifest.json`. After this lands, the first feature PR with a `feat:`/`fix:` prefix will start producing Release PRs. Direct push acceptable.

6. **PR 6 — PR-title lint**: add `pr-title.yml`. Direct push acceptable (it's a new file).

7. **Manual step — flip branch protection**: in GitHub repo settings, require PRs, list the four required checks, force squash-only, apply to admins. **After this, all further changes go through PRs.**

8. **PR 7 — Update README** to reflect the new flow. First PR through the new gates; a real-world test of the system.

## Risks and mitigations

- **release-please's `generic` file updater requires marker comments.** If a marker is missing or misplaced, release-please silently fails to update the file. Mitigation: include a one-time manual check after the first release-please run confirming all four version locations got bumped.
- **First Release PR will have a giant changelog** because release-please backfills history from `1.0.2`. Mitigation: edit the Release PR's body before merging if needed.
- **The Apple smoke check builds on the new build settings landing.** If `MARKETING_VERSION` is malformed, `xcodebuild` will fail loudly. Mitigation: verified by PR 1's CI run before PR 2 touches workflows.
- **Branch protection applied to admins** locks Anand out of direct push. Mitigation: this is the goal. Emergency override is a temporary unprotect via repo settings if truly stuck.
- **Smoke check uses a hardcoded room code (`AAAAAA`)** that never had a TV connected. The endpoint should return `appleTvConnected: false` — that's the assertion (`!= null`). Mitigation: documented in the spec; if the response shape changes, the smoke check will fail loudly and the change is intentional.

## Open questions (none blocking)

None. All major decisions are settled.

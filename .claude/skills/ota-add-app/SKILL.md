---
name: ota-add-app
description: Connect an iOS app repository (single app or a monorepo with one scheme per app) to ios-ota-server, so every green CI run on main publishes its build to the OTA install page. Use when someone asks to add an app or repo to OTA, publish another app, or set up OTA for a monorepo.
---

# Connect an app to OTA

This assumes the OTA setup itself works: the NAS page, the upload and signing on the runner. If it doesn't, use the `ota-setup` skill first. The work here happens in the **app's** repository, through a normal PR that follows that repository's own rules (its CLAUDE.md, issue and ADR conventions, branch names).

## 1. Check before writing anything

Read these from the app repository, and ask only for what you cannot read:

- **CI workflow name.** The OTA workflow listens for it by name in `workflows:`, which must equal the `name:` line of the repository's CI workflow (often `CI`). A wrong name means OTA never starts, and nothing reports an error.
- **Runner.** The OTA job needs the self-hosted Mac that builds with the signing setup, usually `[self-hosted, macOS, ARM64]`. Use the same labels as the repository's existing Mac jobs.
  - An organisation runner serves only repositories in that organisation.
  - A repository outside it needs its own runner, registered on the same Mac **as the same macOS user**. That user holds `ota.conf`, the SSH key and the keychain.
- **Access to the action.** While `ios-ota-server` is private, its Settings → Actions → General → Access must allow the organisation's repositories. Repositories outside the organisation can use it only once it is public.
- **Project and schemes.**
  - Where the `.xcodeproj` or `.xcworkspace` lives (`project-dir`).
  - Which scheme builds each app.
  - Whether `project.yml` (XcodeGen) exists; the action generates the project when `xcodegen` is installed.
  - If the repository already has a setup action that selects Xcode, reuse it before the OTA step, as CycleCompanion does with `prepare-ios`.
- **Bundle IDs.** Each app needs its own bundle ID; two apps with the same one replace each other on the phone.
- **Version keys.** If the project uses XcodeGen with an `info:` block, `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` must be set. Otherwise the app ships with no version, and the page lists it as `0-0-<sha>`.
- **Free team limits.** A free team allows 3 apps on a phone at a time and 10 new App IDs per 7 days. Say so when a monorepo adds more.

## 2. Files to add

**Pin the action to a commit**, never a branch, and say which in a comment. Get the newest commit with:
```bash
git ls-remote https://github.com/ios-ci-apps/ios-ota-server refs/heads/main
```

**Single app:** add `ota.json` (`{"scheme": "...", "project": "..."}`) next to the project, and copy `examples/ota.yml` to `.github/workflows/ota.yml`.

**Monorepo (several schemes):** check that the pinned `action.yml` has `scheme` and `paths` inputs (`grep -n 'scheme:\|paths:' action.yml`). If it does, start from `examples/ota-monorepo.yml`: a matrix with one entry per app (`scheme`, `slug`, `name`, `paths`), `max-parallel: 1`, `fail-fast: false`. Without those inputs, write each app's `ota.json` in a step before the action, or update the pin first.

**In every OTA workflow, keep these:**
- `on: workflow_run` for the CI workflow, `types: [completed]`, `branches: [main]`, plus `workflow_dispatch`.
- The job condition must check that the CI run **succeeded** and was started by a **push**. Otherwise a PR from a branch named `main` would publish:
  ```yaml
  if: ${{ github.event_name == 'workflow_dispatch' || (github.event.workflow_run.conclusion == 'success' && github.event.workflow_run.event == 'push') }}
  ```
- Check out `${{ github.event.workflow_run.head_sha || github.sha }}`, and pass the same value as `sha`. Without that, the job builds the default branch's newest commit instead of the one CI tested.
- `fetch-depth: 0` when using `paths`, so the build can be compared with the last published commit.
- `concurrency` with `cancel-in-progress: false`, so an upload is never cut off halfway.
- `force: ${{ github.event_name == 'workflow_dispatch' }}` with `paths`, so *Run workflow* rebuilds every app. That renews a free team's 7-day profiles.
- **Slugs:** each app gets its own slug. Letters, digits, `.`, `_` and `-`, not starting with `.`. It becomes the folder name on the NAS.
- **`paths`:** list the app's own folder, the shared code it uses and the project file. A change to shared code that is missing from `paths` won't rebuild the app.

Record the decision the way the repository expects; for example, CycleCompanion wants an ADR for each workflow change.

## 3. After the PR merges

1. `workflow_run` and *Run workflow* work only once the file is on the default branch. The first real run is the first green CI on `main` after the merge, or a manual *Run workflow*.
2. **Each new app, once:** log in to the Mac as the runner user, open the project in Xcode and **Run** that app on the iPhone. Otherwise its OTA build installs but closes at once (`AppleMobileFileIntegrityError -400`).
3. In the run's log:
   - the **Check setup** step (`ota-doctor`) passes;
   - the publish step prints `ota: uploading <slug>/<version>-<build>-<sha>`;
   - a version of `0-0` means the version keys are missing (see step 1).
4. The person installs it from the page on the iPhone, and it opens. That is the acceptance check, not "the build is on the page".

If a run fails, read the **Check setup** step first, then find the error text in `TROUBLESHOOTING.md`.

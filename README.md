# ios-ota-server

Install your own iOS builds on your iPhone from anywhere, without TestFlight.
Your Mac CI runner builds and signs the app and uploads it to a NAS. The NAS serves a private install page over [Tailscale](https://tailscale.com).
Nothing is exposed to the internet.

```
iPhone (Tailscale on) ──HTTPS──▶ https://<nas>.<tailnet>.ts.net/        tailscale serve, tailnet only
                                   NAS: /volume1/ios-ota/www/
                                     index.html
                                     <app>/<version>-<build>-<sha>/{<app>.ipa, manifest.plist, meta.json}
Mac runner ──rsync (LAN)──▶ NAS
  CI green on main → ota-build (archive + export) → ota-publish (upload, prune, index)
```

- **Nothing updates by itself.** A build only shows up on the page. The phone installs it only when you tap **Install**. Older versions stay listed, so you can roll back.
- **No secrets in this repository.** Hosts, accounts, team IDs and keys come from a config file on the runner, or from environment variables.

Something not working? See [TROUBLESHOOTING.md](TROUBLESHOOTING.md): every error met so far with its fix, where each secret lives, and what to update when a password changes.

## Using Claude Code

The repository carries two [Claude Code skills](.claude/skills/) that lead the setup step by step, check each step, and know the pitfalls listed in TROUBLESHOOTING.md:

- **`ota-setup`**: first-time setup of the NAS, Tailscale, the upload and signing on the runner Mac. Ask *"set up OTA"*.
- **`ota-add-app`**: connect an app repository or a monorepo to OTA. Ask *"add <repo> to OTA"*.

## Requirements

- A Mac with Xcode that runs a GitHub Actions self-hosted runner, installed as a service (`svc.sh install`, a LaunchAgent).
- An Apple ID with a developer team. A free personal team works (see below).
- A NAS that can run Tailscale and serve static files. These steps use Synology DSM 7.
- An iPhone with Tailscale, in the same tailnet as the NAS.

### Free vs paid Apple developer account

| | Free (personal team) | Paid Apple Developer Program |
|---|---|---|
| `OTA_EXPORT_METHOD` | `debugging` | `release-testing` (Ad Hoc) |
| Profile lifetime | 7 days, then the app will not launch until reinstalled | 1 year |
| Devices | only devices registered through Xcode | up to 100 registered devices |
| Apps per device | 3 at a time | no limit |

With a free team, `ota-build` first tries `xcodebuild -exportArchive`. If that is refused, it packages the archived app, which is already signed with the development profile, as an IPA.
A free team's OTA builds open once the phone knows the runner user's certificate (Runner Mac, step 5). The page shows each build's profile expiry. Rebuild with *Run workflow* before it expires, then install over the existing app. Do not delete the app first, or its data is lost.

## Setup

Do the steps in this order. Each one is checked before the next: run `bin/ota-doctor` on the runner Mac after step 2, and fix anything it marks with ✘ first. The fixes are in [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

### 1. NAS (Synology)

1. **Tailscale.** Package Center → Tailscale. Sign in to the tailnet your iPhone uses. In the Tailscale admin console (DNS page), turn on **MagicDNS** and **HTTPS Certificates**.
2. **Folder and upload user.**
   - Create the shared folder `ios-ota` with a subfolder `www`.
   - Create a user `ota-uploader` with read/write access to that folder only.
   - Under the folder's Permissions, switch the list to **Local groups** and give the group **`http`** read-only access. That is the web server; it is not listed under *System internal user*.
3. **SSH for uploads.**
   - Control Panel → Terminal & SNMP → enable SSH.
   - Control Panel → User & Group → Advanced → enable the user home service.
   - Step 2 of *Runner Mac* installs the key.

   SSH is the default. The Synology rsync service (`rsync://`) is supported too, but it refused every account in testing with `account system disabled`.
4. **Web Station.**
   - Web Station → Web Service → Create → *Static website*, with the document root `ios-ota/www`.
   - Web Station → Web Portal → Create. Pick that service, set the portal type to **port-based** and HTTP to `8088`. Leave the host name empty. If HTTPS cannot be empty, enter an unused port such as `8443`; it is never used.
   - A host-based portal answers `404` to everything Tailscale forwards.
   - Check it on the NAS. `404` is fine before the first publish; `403` means the `http` group cannot read the folder.
     ```bash
     curl -I http://127.0.0.1:8088/
     ```
5. **Tailscale serve.** Over SSH on the NAS, as an admin:
   ```bash
   sudo tailscale serve --bg --https=443 http://127.0.0.1:8088
   ```
   ```bash
   sudo tailscale serve status
   ```
   The second command prints the page's address, `https://<nas>.<tailnet>.ts.net`. Rename the machine in the Tailscale admin console *before* this step if you want a different name.

   Do **not** enable Funnel, and do not forward ports on your router.
6. **Check from the iPhone.** Turn Tailscale on and open the address in Safari. The certificate must be valid; iOS refuses OTA without a trusted HTTPS certificate. Test from a device in the **same tailnet**: a Mac signed in to another Tailscale account cannot reach it.

### 2. Runner Mac

Do all of this **logged in as the macOS user the GitHub runner runs as**. Its keychain, Xcode account, SSH key and settings are per user.

1. **Tools.**
   ```bash
   brew install rsync
   ```
   Only the user who owns Homebrew can install. If that is another user, run it there (`su - <owner>`); every user can then run `/opt/homebrew/bin/rsync`. macOS's own rsync (openrsync) is not enough.
2. **SSH key for the NAS.**
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/ota_uploader -N "" -C "ota-runner"
   ```
   ```bash
   ssh-copy-id -i ~/.ssh/ota_uploader.pub ota-uploader@<nas>.local
   ```
   DSM may refuse SSH logins from non-administrators. If `ssh-copy-id` says `Permission denied`, install the key as an administrator instead (TROUBLESHOOTING.md, *Upload*).
3. **Settings.**
   ```bash
   mkdir -p ~/.config/ios-ota && cp ota.conf.example ~/.config/ios-ota/ota.conf && chmod 600 ~/.config/ios-ota/ota.conf
   ```
   Fill in `OTA_BASE_URL` with the address from step 1.5 and `OTA_RSYNC_DEST`. The other defaults match this setup. Environment variables with the same names override the file, so a workflow can also pass them from repository or organisation *Variables* and *Secrets*.
4. **Signing.** A runner service can find the login keychain locked, and `codesign` then fails with `errSecInternalComponent`. Let each build unlock it:
   ```bash
   printf '%s' '<runner user login password>' > ~/.config/ios-ota/keychain.password && chmod 600 ~/.config/ios-ota/keychain.password
   ```
   ```bash
   security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k '<runner user login password>' ~/Library/Keychains/login.keychain-db
   ```
   When this password changes, see TROUBLESHOOTING.md, *Changing a password*.
5. **Xcode, once per app.**
   - Xcode → Settings → Accounts: sign in with the Apple ID of the signing team.
   - Connect the iPhone, open the app's project and press **Run** once.

   This registers the phone and sets up this user's certificate. Without it, OTA builds install but close at once (`AppleMobileFileIntegrityError -400`). Each macOS user has its own certificate, even under the same Apple ID.
6. **Check.** From a clone of this repository:
   ```bash
   bin/ota-doctor
   ```
   Every line should be ✔. Fix any ✘ before the first build.

### 3. App repository

1. Add `ota.json` at the root (see [`examples/ota.json`](examples/ota.json)). It needs `scheme`. `project` or `workspace` and `configuration` are optional. If `project.yml` exists and `xcodegen` is installed, the project is generated first.
2. Add the workflow [`examples/ota.yml`](examples/ota.yml) as `.github/workflows/ota.yml`. Set `workflows:` to the name of your CI workflow and choose a `slug`.
3. If this repository is private, allow other repositories in the organization to use its action: **Settings → Actions → General → Access**.

### Monorepo: several apps in one Xcode project

Run the action once per app with a matrix, giving each its `scheme` and `slug`. `ota.json` is then optional. Add `paths` so an app is rebuilt only when its files changed. See [`examples/ota-monorepo.yml`](examples/ota-monorepo.yml).

- **`scheme`** overrides `"scheme"` in `ota.json`. Without `ota.json`, `xcodebuild` finds the project in `project-dir` itself.
- **`paths`** lists folders or files relative to the repository root, separated by spaces or new lines: the app's own folder, shared code, and the project file. The action reads the commit of the app's newest version on the install page. If none of `paths` changed between that commit and the one being built, the app is skipped (output `published=false`). It always builds when the app has no version yet, or when that commit is missing from the checkout, so use `fetch-depth: 0`.
- **`force: true`** rebuilds anyway. The example sets it on manual runs, so *Run workflow* renews every app.
- Every app needs its own bundle identifier. With a free team, a device holds at most 3 such apps at a time.

## Which team signs

Each build logs `ota: signing with team <ID> (from <source>)`, and the install page shows, for every version, the team that actually signed it and how (`Development` or `Ad Hoc`), read from the build's own provisioning profile. The team is chosen in this order:

1. **`OTA_TEAM_ID`**: an explicit choice that wins over everything. Set it per app in the workflow (`env:` on the action's step, or a matrix field) to sign different apps with different teams.
2. **The project's own team**: `DEVELOPMENT_TEAM` of the scheme's app target. OTA builds then use the same team as running the app from Xcode, so the two can install over each other on a phone.
3. **`OTA_DEFAULT_TEAM_ID`** in `ota.conf`: the runner's default, for projects that leave the team out of the repository.

`OTA_EXPORT_METHOD` can be set per app the same way. Ad Hoc (`release-testing`) needs a paid team with an Apple Distribution certificate on the runner; if it fails, the build stops instead of shipping a development-signed app. `bin/ota-doctor` checks that each team setting has a certificate in the keychain.

## Commands

```bash
bin/ota-doctor [--skip-upload] [--skip-signing] [--skip-page]   # checks the setup, layer by layer
bin/ota-build --project-dir path/to/app [--scheme MyApp]   # macOS; prints the IPA path on the last line
bin/ota-publish --ipa App.ipa --slug myapp [--name "My App"] [--sha <commit>] [--ref main]
bin/ota-changed --slug myapp -- apps/MyApp Shared         # prints true (rebuild) or false (unchanged)
tests/run.sh                                # end-to-end tests against a local folder
```

`ota-publish` uploads a new version, keeps the newest `OTA_KEEP_VERSIONS` per app (default 10), and re-renders `index.html` from every version's `meta.json`.

## Settings

| Setting | Required | Default | Meaning |
|---|---|---|---|
| `OTA_BASE_URL` | yes | | HTTPS address of the page as the phone sees it |
| `OTA_RSYNC_DEST` | yes | | `rsync://user@host/module/path`, `user@host:/path`, or a local directory |
| `OTA_RSYNC_PASSWORD_FILE` | | | password file for the rsync service |
| `OTA_SSH_KEY`, `OTA_SSH_PORT` | | `22` | SSH destination only |
| `OTA_RSYNC_BIN` | | `rsync` | for example `/opt/homebrew/bin/rsync` |
| `OTA_KEEP_VERSIONS` | | `10` | versions kept per app |
| `OTA_DEFAULT_TEAM_ID` | | | team for projects that name no team of their own |
| `OTA_TEAM_ID` | | | explicit team for every app, over the project's own; usually set per app in a workflow's `env` |
| `OTA_EXPORT_METHOD` | | `debugging` | `release-testing` for Ad Hoc |
| `OTA_PROFILE_DAYS` | | `7` | expiry shown when the IPA has no profile |
| `OTA_KEYCHAIN_PASSWORD_FILE` | | | file with the runner user's login password (chmod 600); unlocks the keychain before each build |
| `OTA_KEYCHAIN` | | login keychain | keychain to unlock |

## Security notes

- **Self-hosted runners and public repositories.** This action runs inside *your* repository's job, on *your* runner. Making this repository public shares only its code, not your runner. Who may use the runner is set where the runner is registered:
  - for an organisation runner: Settings → Actions → Runner groups → choose *Selected repositories* and leave *Allow public repositories* off;
  - for a repository runner: keep that repository private.

  A public repository whose workflows use a self-hosted runner lets anyone who opens a pull request run code on that machine. This repository's own CI uses GitHub-hosted runners only, and a CI check fails if a workflow here asks for `self-hosted`.
- **Pin the action to a commit** (`uses: <owner>/ios-ota-server@<full sha>`), not a branch. A later change to this repository then cannot run on your Mac until you choose to update the pin.

- Only devices in your tailnet can reach the page. The IPA files are not encrypted at rest on the NAS.
- The config file is read as `KEY=value` lines and never executed. Unknown keys are an error.
- CI runs ShellCheck, the tests, and a gitleaks scan of the whole history.

## License

MIT

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

## Requirements

- A Mac with Xcode that runs a GitHub Actions self-hosted runner. The runner must run inside a logged-in user session (a LaunchAgent), so that signing can use that user's keychain.
- In that user's Xcode: signed in to the Apple ID whose team signs the app, and the iPhone connected once so its UDID is registered.
- A NAS that can run Tailscale and serve static files. These steps use Synology DSM 7.
- Homebrew `rsync` on the Mac is recommended (`brew install rsync`). macOS ships openrsync.

### Free vs paid Apple developer account

| | Free (personal team) | Paid Apple Developer Program |
|---|---|---|
| `OTA_EXPORT_METHOD` | `debugging` | `release-testing` (Ad Hoc) |
| Profile lifetime | 7 days, then the app will not launch until reinstalled | 1 year |
| Devices | only devices registered through Xcode | up to 100 registered devices |
| Apps per device | 3 at a time | no limit |

With a free team, `ota-build` first tries `xcodebuild -exportArchive`. If that is refused, it packages the archived app, which is already signed with the development profile, as an IPA.
**Try one install by hand before you rely on it.** The page shows each build's profile expiry. Rebuild with *Run workflow* before it expires, then install over the existing app. Do not delete the app first, or its data is lost.

## Setup

### 1. NAS (Synology)

1. **Package Center → Tailscale.** Install it and sign in to the tailnet your iPhone uses. In the Tailscale admin console, enable **MagicDNS** and **HTTPS Certificates**.
2. **Shared folder `ios-ota`** with a subfolder `www`. Create a user `ota-uploader` with read/write access to that folder only.
3. **Upload access.** Choose one:
   - *rsync service* (recommended, no shell account): **Control Panel → File Services → rsync → Enable rsync service** and **Edit rsync account** for `ota-uploader`. Then create a module, or use the shared folder name. The destination is `rsync://ota-uploader@<nas>.local/ios-ota/www`.
   - *SSH*: the destination is `ota-uploader@<nas>.local:/volume1/ios-ota/www`. Install the runner user's public key.
4. **Web Station.** Serve `/volume1/ios-ota/www` as a static site on a local port, for example `8088`.
5. Over SSH on the NAS, as an admin:
   ```bash
   sudo tailscale serve --bg --https=443 http://127.0.0.1:8088
   ```
   Do **not** enable Funnel. Do not forward ports on your router.
6. On the iPhone, install Tailscale, then open `https://<nas>.<tailnet>.ts.net/` in Safari. The certificate must be valid. iOS refuses OTA without a trusted HTTPS certificate.

### 2. Runner Mac

As the user that runs the GitHub runner:

```bash
mkdir -p ~/.config/ios-ota
cp ota.conf.example ~/.config/ios-ota/ota.conf
```

```bash
chmod 600 ~/.config/ios-ota/ota.conf
```

Fill in `OTA_BASE_URL` and `OTA_RSYNC_DEST`.

**Signing from the runner service.** The runner runs as a LaunchAgent, and it can find the login keychain locked: after sleep, after an idle timeout, or when the session was not started at the desktop. `codesign` then fails with `errSecInternalComponent`, even though the same archive works in Terminal. To fix it, let the build unlock the keychain itself:

```bash
printf '%s' '<runner user login password>' > ~/.config/ios-ota/keychain.password && chmod 600 ~/.config/ios-ota/keychain.password
```

Then add `OTA_KEYCHAIN_PASSWORD_FILE=~/.config/ios-ota/keychain.password` to `ota.conf`. Once, also allow Apple's signing tools to use the key without a prompt:

```bash
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k '<runner user login password>' ~/Library/Keychains/login.keychain-db
```
 For the rsync service, also fill in `OTA_RSYNC_PASSWORD_FILE` and put the password in that file (`chmod 600`).
Environment variables with the same names override the file. That lets a workflow pass them from repository or organization *Variables* and *Secrets* instead.

### 3. App repository

1. Add `ota.json` at the root (see [`examples/ota.json`](examples/ota.json)). It needs `scheme`. `project` or `workspace` and `configuration` are optional. If `project.yml` exists and `xcodegen` is installed, the project is generated first.
2. Add the workflow [`examples/ota.yml`](examples/ota.yml) as `.github/workflows/ota.yml`. Set `workflows:` to the name of your CI workflow and choose a `slug`.
3. If this repository is private, allow other repositories in the organization to use its action: **Settings → Actions → General → Access**.

## Commands

```bash
bin/ota-build --project-dir path/to/app     # macOS; prints the IPA path on the last line
bin/ota-publish --ipa App.ipa --slug myapp [--name "My App"] [--sha <commit>] [--ref main]
tests/run.sh                                # end-to-end test of ota-publish against a local folder
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
| `OTA_TEAM_ID` | | project setting | Apple team that signs |
| `OTA_EXPORT_METHOD` | | `debugging` | `release-testing` for Ad Hoc |
| `OTA_PROFILE_DAYS` | | `7` | expiry shown when the IPA has no profile |
| `OTA_KEYCHAIN_PASSWORD_FILE` | | | file with the runner user's login password (chmod 600); unlocks the keychain before each build |
| `OTA_KEYCHAIN` | | login keychain | keychain to unlock |

## Security notes

- Only devices in your tailnet can reach the page. The IPA files are not encrypted at rest on the NAS.
- The config file is read as `KEY=value` lines and never executed. Unknown keys are an error.
- CI runs ShellCheck, the tests, and a gitleaks scan of the whole history.

## License

MIT

# Troubleshooting

Problems met while setting this up, each with the message you see and the fix. Search this page for the error text.

Start with `bin/ota-doctor` on the runner Mac, as the runner user. It checks the settings, the upload to the NAS, signing and the install page, and names the layer that is broken. The OTA action runs it before every build.

- [Where each secret lives](#where-each-secret-lives)
- [Changing a password](#changing-a-password)
- [Install page (NAS, Tailscale)](#install-page-nas-tailscale)
- [Upload (rsync)](#upload-rsync)
- [Build and signing (runner Mac)](#build-and-signing-runner-mac)
- [Workflow](#workflow)
- [On the iPhone](#on-the-iphone)
- [Finding your team ID](#finding-your-team-id)

## Where each secret lives

Nothing below is in any repository. Paths are on the runner Mac, as the user the GitHub runner runs as.

| Secret | Where | Used for |
|---|---|---|
| Runner user's macOS login password | `~/.config/ios-ota/keychain.password` (`chmod 600`), set as `OTA_KEYCHAIN_PASSWORD_FILE` | Unlocking the login keychain before signing |
| Apple ID | Xcode → Settings → Accounts, in the runner user | Creating and renewing provisioning profiles (`-allowProvisioningUpdates`) |
| Signing key | The runner user's login keychain | `codesign` |
| SSH key for the NAS | `~/.ssh/ota_uploader` (private), and the `.pub` in the NAS user's `~/.ssh/authorized_keys` | Upload over SSH |
| NAS rsync password (rsync service only) | file named by `OTA_RSYNC_PASSWORD_FILE` (`chmod 600`) | Upload to `rsync://` |

## Changing a password

**The runner user's macOS login password**
1. Change it in System Settings → Users & Groups while logged in as that user. Use the old password when asked. macOS then changes the login keychain's password to match.
2. Update the password file, still as that user:
   ```bash
   printf '%s' '<new password>' > ~/.config/ios-ota/keychain.password && chmod 600 ~/.config/ios-ota/keychain.password
   ```
3. When no build is running, check that the keychain opens with it (this asks for the password; nothing is shown):
   ```bash
   security lock-keychain ~/Library/Keychains/login.keychain-db && security unlock-keychain ~/Library/Keychains/login.keychain-db && echo OK
   ```
4. If signing asks for permission again, repeat the one-time key setup with the new password:
   ```bash
   security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k '<new password>' ~/Library/Keychains/login.keychain-db
   ```

If an administrator *reset* the password (without the old one), the login keychain keeps the **old** password. Step 3 then fails. Fix it with the old password:
```bash
security set-keychain-password -o '<old password>' -p '<new password>' ~/Library/Keychains/login.keychain-db
```
If the old password is lost, macOS offers to create a new login keychain at the next desktop login. Afterwards, sign in to Xcode again (below) so it can recreate the signing key.

Until the file matches, every build stops with `ota: could not unlock ...; check the password in ...`.

**The Apple ID password.** Xcode may drop the account. Builds then fail with `No Accounts`; see below.

**The NAS user's password.** Uploads over SSH use the key, not the password, so nothing changes. With the rsync service, update the file named by `OTA_RSYNC_PASSWORD_FILE`.

## Install page (NAS, Tailscale)

**`curl -I http://127.0.0.1:8088/` on the NAS returns `403`**
- The web server cannot read the folder. Give the `http` *group* read access to the shared folder: Control Panel → Shared Folder → Edit → Permissions → **Local groups** → `http` → Read only. The `http` user is not listed under *System internal user*.
- `403` also shows when the folder has no `index.html`. The first publish writes one.

**`404 Not Found` from nginx, although `index.html` is there**
The Web Station portal is host-based. Check its `server_name`:
```bash
sudo grep -rn -A15 'listen.*8088' /usr/local/etc/nginx/ | grep -E 'listen|root|server_name'
```
If it lists names, requests for `127.0.0.1` or the `ts.net` name do not match. Edit the portal in Web Station → Web Portal: make it **port-based** and clear the host name.

**Web Station will not leave the HTTPS port empty**
Enter an unused port such as `8443`. Tailscale only proxies to the HTTP port, so the HTTPS one is never used.

**`https://<nas>.<tailnet>.ts.net/` does not open**
- The device you test from must be in the **same tailnet** as the NAS. A Mac signed in to another Tailscale account cannot reach it; test from the iPhone with Tailscale on.
- On the NAS, `sudo tailscale serve status` must show `|-- / proxy http://127.0.0.1:8088`.
- HTTPS Certificates must be on in the Tailscale admin console (DNS page). The first request after `serve` can take about 30 seconds while the certificate is issued.

**Renaming the NAS in Tailscale**
Use the ⋯ menu in the Machines list, or `sudo tailscale set --hostname=<name>` on the NAS. The device page's message "Cannot access this device's Tailscale IP" only means the browser's device is not in that tailnet. After renaming, run `tailscale serve` again and update `OTA_BASE_URL`.

## Upload (rsync)

**`zsh: no such file or directory: /opt/homebrew/bin/rsync`**
Homebrew's rsync is not installed. Only the user who owns Homebrew can install it (`brew install rsync`), for example with `su - <owner>`. Every user can then run it. Do not use `sudo brew`.

**`@ERROR: account system disabled` (rsync service)**
The Synology rsync service would not accept any account, an administrator's included. Use SSH instead: `OTA_RSYNC_DEST=user@nas.local:/volume1/ios-ota/www` with `OTA_SSH_KEY`.

**`ssh-copy-id` says `Permission denied`**
Either the password is wrong (use the NAS user's DSM password, not an rsync-account password), or DSM refuses SSH logins from non-administrators. Install the key as an administrator instead:
```bash
sudo mkdir -p /volume1/homes/<user>/.ssh
echo '<contents of ota_uploader.pub>' | sudo tee /volume1/homes/<user>/.ssh/authorized_keys
sudo chown -R <user>:users /volume1/homes/<user>/.ssh
sudo chmod 755 /volume1/homes/<user> && sudo chmod 700 /volume1/homes/<user>/.ssh && sudo chmod 600 /volume1/homes/<user>/.ssh/authorized_keys
```
The user home service must be on (Control Panel → User & Group → Advanced). If the key is still refused, upload as an administrator account and keep that private key only on the runner Mac.

## Build and signing (runner Mac)

**`No Accounts: Add a new account in Accounts settings` / `missing Xcode-Username` / `No profiles for '<bundle id>' were found`**
Xcode in the runner user has no working Apple ID. Log in to the Mac **as the runner user**, open Xcode → Settings → Accounts, remove the account if one is listed, and add the Apple ID of the signing team again.

**`errSecInternalComponent` / `Command CodeSign failed`, but the same archive works in Terminal**
The runner is a LaunchAgent service. It can find the login keychain locked after sleep or an idle timeout, and with no screen to ask on, `codesign` fails. Let each build unlock the keychain:
1. Put the runner user's login password in `~/.config/ios-ota/keychain.password` and run `chmod 600` on it.
2. Add `OTA_KEYCHAIN_PASSWORD_FILE=~/.config/ios-ota/keychain.password` to `ota.conf`.
3. Run `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k '<password>' ~/Library/Keychains/login.keychain-db` once.

To see how the runners were installed: `ls ~/Library/LaunchAgents | grep actions.runner`.

**`ota: could not unlock ...; check the password in ...`**
The password file does not match the keychain password, usually after a password change. See [Changing a password](#changing-a-password).

**`ota: ... is readable by others`**
Run `chmod 600` on the password file.

## Workflow

**`uses: ios-ci-apps/ios-ota-server@...` fails with "repository not found"**
While this repository is private, allow its action to be used by the organisation: Settings → Actions → General → Access → *Accessible from repositories in the organization*. Repositories outside the organisation can use it only once it is public.

**The OTA job sits in "queued"**
The Mac runs one job at a time. It usually waits behind a long UI test run.

## On the iPhone

**"Unable to install" after tapping Install**
A free (personal) team's build may be refused for OTA installation. With the paid Apple Developer Program, set `OTA_EXPORT_METHOD=release-testing` (Ad Hoc) in `ota.conf` and rebuild.

**The app installs but closes at once, with no crash report**
The phone refused the signature before any app code ran, so there is no crash report under Analytics Data. To see why, connect the iPhone to a Mac, open Console, pick the phone, start streaming and filter for the app's name. The cause shows as:
```
amfid  .../<App>.app/<App> not valid: Error Domain=AppleMobileFileIntegrityError Code=-400
SpringBoard  Bootstrapping failed ... "Launch failed." ... Launchd job spawn failed
```
Each macOS user signs with its own Apple Development certificate, even under the same Apple ID. The phone has not accepted the runner user's certificate yet.

Fix it once: log in to the Mac **as the runner user**, open the project in Xcode, pick the iPhone (by cable, or over the network after *Connect via network*) and press Run. Xcode registers the device and sets up that certificate's profile. After that, OTA builds signed by the same certificate open.

Do this again only if the runner user's certificate changes, for example after signing out of Xcode or a new Mac. App data is kept either way; never delete the app to fix this.

On a paid team with Ad Hoc export (`OTA_EXPORT_METHOD=release-testing`), registering the device's UDID in the Apple Developer portal replaces this step.

**Tapping Install does nothing**
Open the page in Safari, not in an app's built-in browser, and check that Tailscale is on.

**The app stops opening after 7 days**
That is the free team's profile expiry, shown on the page. Rebuild (Run workflow), then install over the existing app. Never delete the app first, or its data is lost.

## Which team signed this build?

The build log says it: `ota: signing with team <ID> (from OTA_TEAM_ID | project | OTA_DEFAULT_TEAM_ID)`. If it is not the team you expected:
- `from OTA_TEAM_ID`: an explicit team is set in the workflow's `env` or in `ota.conf`, and it overrides the project.
- `from project`: the project names its own team (`DEVELOPMENT_TEAM` in `project.yml`, an `.xcconfig`, or a gitignored local `.xcconfig` on the runner). Change it there.
- `from OTA_DEFAULT_TEAM_ID`: the project names no team, so the runner's default was used.

**`Ad Hoc export (release-testing) failed for team ...`**
Ad Hoc needs a paid team, and an Apple Distribution certificate for it in the runner user's keychain (Xcode → Settings → Accounts → Manage Certificates). The device must be registered in that team. Use `OTA_EXPORT_METHOD=debugging` for a free team.

## Finding your team ID

`OTA_TEAM_ID` and Xcode's `DEVELOPMENT_TEAM` take a 10-character team ID. A free (personal) team has no Membership page on the Apple Developer site, so read it on the Mac:

- **Xcode:** target → Build Settings → search `DEVELOPMENT_TEAM`, or Signing & Capabilities → Team.
- **The signing certificate:** the `OU` field is the team ID.
  ```bash
  security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
  ```
- **An exported app's profile:**
  ```bash
  security cms -D -i <App>.app/embedded.mobileprovision | grep -A2 TeamIdentifier
  ```

`security find-identity -v -p codesigning` also prints a 10-character code in brackets, but that is the certificate's ID, not the team's.

A paid team has its own, different team ID: Apple Developer → Account → Membership details. Switching to it can change the signing identity and the bundle ID prefix. Check before the first install whether the app keeps its data.

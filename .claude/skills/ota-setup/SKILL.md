---
name: ota-setup
description: Guide a person through setting up ios-ota-server for the first time — NAS install page over Tailscale, upload from the runner Mac, signing for the GitHub runner — one checked step at a time. Use when someone asks to set up, install or get started with OTA, or when ota-doctor reports failures on a fresh setup.
---

# Set up ios-ota-server

You are walking a person through a setup that happens on **their** NAS, Mac and iPhone. You normally cannot run anything there. Your job is to give the next step, wait for its result, check it, and only then move on. The setup in `README.md` is the source of truth for the steps; this skill says how to lead it and what goes wrong.

## Rules

- **One step at a time.** Give a step's commands, say what a good result looks like, and wait for the person to paste the output. Don't hand over the whole README at once.
- **Never ask for secrets in chat.** Passwords, private keys and tokens go straight into files on their machine. Write commands with placeholders such as `'<runner user login password>'` and tell them to replace it there.
- **Nothing host- or account-specific goes into the repository.** It all lives in `~/.config/ios-ota/ota.conf` and the files it names.
- **Each command block holds one command, or one `&&` chain,** so it can be copied on its own.
- When a step fails, find the error text in `TROUBLESHOOTING.md` and use that fix before improvising.

## 1. Ask first

Ask these before any step, because the answers change the steps:

1. **NAS:** Synology DSM 7 is the tested path. For anything else, keep the same shape: Tailscale on the NAS, a static web server on a local port, SSH upload. Adapt the UI steps.
2. **Runner Mac:** which macOS user runs the GitHub runner (`ls ~/Library/LaunchAgents | grep actions.runner` as that user), and is it a separate user from the one they normally use? Everything on the Mac happens as **that** user.
3. **Apple team:** free (personal) or paid? A free team uses `OTA_EXPORT_METHOD=debugging`; a paid one uses `release-testing`. See the table in the README.
4. **Tailscale:** which account and tailnet their iPhone uses. The NAS must join **that** tailnet. The Mac needs no Tailscale at all; if it is signed in to another tailnet, that is fine. It only means the Mac cannot open the page.

## 2. The steps, in order, with their check

Follow README → Setup. After each step, check before moving on:

| Step | Check | Usual failure (TROUBLESHOOTING.md) |
|---|---|---|
| NAS 1: Tailscale, MagicDNS, HTTPS Certificates | admin console shows the NAS online | — |
| NAS 2: folder, upload user, `http` group read-only | — | `http` not under *System internal user*: it is under **Local groups** |
| NAS 3: SSH and the user home service | — | — |
| NAS 4: Web Station static site, **port-based** portal on 8088 | `curl -I http://127.0.0.1:8088/` on the NAS: `404` before the first publish, `200` after; **not** `403` | `403` → `http` group; `404` with an `index.html` → host-based portal |
| NAS 5: `tailscale serve` | `sudo tailscale serve status` shows `proxy http://127.0.0.1:8088` | rename the NAS **before** this step |
| NAS 6: open the page on the iPhone | valid certificate, page loads | testing from a device in another tailnet |
| Mac 1: Homebrew rsync | `/opt/homebrew/bin/rsync --version` is not openrsync | only Homebrew's owner can `brew install` |
| Mac 2: SSH key on the NAS | `ssh -i ~/.ssh/ota_uploader ota-uploader@<nas>.local` logs in without a password | `Permission denied` → install the key as an administrator |
| Mac 3: `ota.conf` | — | — |
| Mac 4: keychain password file and `set-key-partition-list` | — | — |
| Mac 5: Xcode account, then **Run once** on the iPhone | the app opens from Xcode | — |
| Mac 6: `bin/ota-doctor` | every line ✔ (a page warning is expected from a Mac outside the tailnet) | follow the → hint on each ✘ |

Things people skip, and that later cost an hour each:

- **The `http` group's read access** and the **port-based portal**. Without them the page answers 403 or 404 although the files are there.
- **SSH, not the Synology rsync service.** The rsync service refused every account in testing (`account system disabled`).
- **The keychain password file.** Without it, CI fails at CodeSign with `errSecInternalComponent`, while the same archive works in Terminal.
- **Running the app once from Xcode as the runner user.** Without it, OTA builds install but close at once (`AppleMobileFileIntegrityError -400` in Console, and no crash report). Each macOS user has its own signing certificate, even under the same Apple ID.

## 3. Finish

Setup is done when:

1. `bin/ota-doctor` passes on the runner Mac, as the runner user.
2. The first app is connected (use the `ota-add-app` skill), and its first build shows on the page.
3. The person installs it from the iPhone, **and it opens**.

Don't call it done at "the build is on the page": installing and opening is the real test.

Then tell them where the secrets live and what to do when a password changes. Point to TROUBLESHOOTING.md → *Where each secret lives* and *Changing a password*.

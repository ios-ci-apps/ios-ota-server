#!/usr/bin/env bash
# The checks are single-quoted on purpose: check() evaluates them later.
# shellcheck disable=SC2016
# End-to-end test of ota-publish on Linux or macOS: fake IPAs are published to a local directory
# (rsync accepts a local path as destination), then the layout, manifest, index and pruning are checked.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0

check() {
    if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails + 1)); fi
}

make_ipa() { # <out> <bundle id> <version> <build>
    python3 - "$@" <<'PY'
import plistlib, sys, zipfile, datetime
out, bundle, version, build = sys.argv[1:]
info = plistlib.dumps({"CFBundleIdentifier": bundle, "CFBundleShortVersionString": version,
                       "CFBundleVersion": build, "CFBundleDisplayName": "Demo <App>"})
profile = b"\x30\x80garbage" + plistlib.dumps({"ExpirationDate": datetime.datetime(2030, 1, 2, 3, 4, 5)}) + b"\x00sig"
with zipfile.ZipFile(out, "w") as z:
    z.writestr("Payload/Demo.app/Info.plist", info)
    z.writestr("Payload/Demo.app/embedded.mobileprovision", profile)
PY
}

site="$work/site"
mkdir -p "$site"
export OTA_CONFIG="$work/ota.conf"
cat > "$OTA_CONFIG" <<CONF
# test config
OTA_BASE_URL=https://nas.example.ts.net
OTA_RSYNC_DEST=$site
OTA_KEEP_VERSIONS=2
CONF

for build in 1 2 3; do
    make_ipa "$work/demo$build.ipa" com.example.demo 1.0 "$build"
    "$ROOT/bin/ota-publish" --ipa "$work/demo$build.ipa" --slug demo --sha "abcdef${build}0000" > "$work/out$build.log"
    sleep 1
done
make_ipa "$work/other.ipa" com.example.other 2.1 7
"$ROOT/bin/ota-publish" --ipa "$work/other.ipa" --slug other --name "Other" --sha 1234567890 > /dev/null

check "keeps the newest two versions" '[[ "$(find "$site/demo" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2 ]]'
check "pruned the oldest version" '[[ ! -d "$site/demo/1.0-1-abcdef1" ]]'
check "newest version has ipa, manifest, meta" '[[ -f "$site/demo/1.0-3-abcdef3/demo.ipa" && -f "$site/demo/1.0-3-abcdef3/manifest.plist" && -f "$site/demo/1.0-3-abcdef3/meta.json" ]]'
check "other app untouched by pruning" '[[ -d "$site/other/2.1-7-1234567" ]]'
check "manifest points at the ipa" 'python3 -c "import plistlib,sys; m=plistlib.load(open(sys.argv[1],\"rb\")); a=m[\"items\"][0]; assert a[\"assets\"][0][\"url\"]==\"https://nas.example.ts.net/demo/1.0-3-abcdef3/demo.ipa\"; assert a[\"metadata\"][\"bundle-identifier\"]==\"com.example.demo\"" "$site/demo/1.0-3-abcdef3/manifest.plist"'
check "expiry read from the profile" 'grep -q "\"expiresAt\": \"2030-01-02T03:04:05Z\"" "$site/demo/1.0-3-abcdef3/meta.json"'
check "index lists both apps" 'grep -q ">Other<" "$site/index.html" && grep -q "Demo &lt;App&gt;" "$site/index.html"'
check "index has an encoded itms-services link" 'grep -q "itms-services://?action=download-manifest&amp;url=https%3A%2F%2Fnas.example.ts.net%2Fdemo%2F1.0-3-abcdef3%2Fmanifest.plist" "$site/index.html"'
check "index escapes the display name" '! grep -q "Demo <App>" "$site/index.html"'

# Configuration errors.
cat > "$work/missing.conf" <<'CONF'
OTA_BASE_URL=https://nas.example.ts.net
CONF
check "missing setting is reported" '! OTA_CONFIG="$work/missing.conf" "$ROOT/bin/ota-publish" --ipa "$work/demo3.ipa" --slug demo 2> "$work/err" && grep -q "missing setting(s): OTA_RSYNC_DEST" "$work/err"'
check "http base url is refused" '! OTA_BASE_URL=http://x OTA_RSYNC_DEST="$site" OTA_CONFIG="$work/missing.conf" "$ROOT/bin/ota-publish" --ipa "$work/demo3.ipa" --slug demo 2> "$work/err" && grep -q "https://" "$work/err"'
check "unsafe slug is refused" '! "$ROOT/bin/ota-publish" --ipa "$work/demo3.ipa" --slug "../x" 2> /dev/null'
echo 'rm -rf / # $(touch pwned)' > "$work/evil.conf"
check "config file is not executed" '! OTA_CONFIG="$work/evil.conf" "$ROOT/bin/ota-publish" --ipa "$work/demo3.ipa" --slug demo 2> /dev/null && [[ ! -e pwned ]]'
check "environment overrides the config file" 'OTA_KEEP_VERSIONS=1 "$ROOT/bin/ota-publish" --ipa "$work/demo3.ipa" --slug demo --sha abcdef3000 > /dev/null && [[ "$(find "$site/demo" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ]]'

# ota-changed: rebuild only when the app's paths changed since its newest published commit.
repo="$work/repo"
mkdir -p "$repo/apps/demo" "$repo/apps/other" "$repo/shared"
git -C "$repo" init -q
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
echo a > "$repo/apps/demo/a.swift"; echo o > "$repo/apps/other/o.swift"; echo s > "$repo/shared/s.swift"
git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m one
first="$(git -C "$repo" rev-parse HEAD)"
changed_site="$work/changed-site"
mkdir -p "$changed_site"
OTA_RSYNC_DEST="$changed_site" "$ROOT/bin/ota-publish" --ipa "$work/demo3.ipa" --slug demo --sha "$first" > /dev/null
changed() { OTA_RSYNC_DEST="$changed_site" "$ROOT/bin/ota-changed" --repo "$repo" "$@" 2> /dev/null; }
check "unchanged paths skip the build" '[[ "$(changed --slug demo -- apps/demo shared)" == false ]]'
echo b > "$repo/apps/other/o.swift"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -am "other app only"
check "a change in another app skips the build" '[[ "$(changed --slug demo -- apps/demo shared)" == false ]]'
echo t > "$repo/shared/s.swift"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -am "shared code"
check "a change in a shared path builds" '[[ "$(changed --slug demo -- apps/demo shared)" == true ]]'
check "an app never published builds" '[[ "$(changed --slug newapp -- apps/demo)" == true ]]'
OTA_RSYNC_DEST="$changed_site" "$ROOT/bin/ota-publish" --ipa "$work/other.ipa" --slug other --sha 0123456789abcdef0123456789abcdef01234567 > /dev/null
check "a commit missing from history builds" '[[ "$(changed --slug other -- apps/other)" == true ]]'
check "ota-changed needs a path" '! changed --slug demo'
check "a slug starting with a dot is refused" '! "$ROOT/bin/ota-publish" --ipa "$work/demo3.ipa" --slug ".hidden" 2> /dev/null'

# Keychain unlock: a fake `security` records its arguments; the password must not reach the output.
fakebin="$work/fakebin"
mkdir -p "$fakebin"
cat > "$fakebin/security" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$SECURITY_LOG"
[[ "$3" == right-password ]]
FAKE
chmod +x "$fakebin/security"
export SECURITY_LOG="$work/security.log"
unlock() { PATH="$fakebin:$PATH" bash -c 'source "$1/lib/config.sh"; ota_unlock_keychain' _ "$ROOT"; }
printf 'right-password\n' > "$work/kc.pw"; chmod 600 "$work/kc.pw"
check "no setting, no unlock" 'OTA_KEYCHAIN_PASSWORD_FILE= unlock 2> /dev/null && [[ ! -e "$SECURITY_LOG" ]]'
check "unlocks the given keychain" 'OTA_KEYCHAIN_PASSWORD_FILE="$work/kc.pw" OTA_KEYCHAIN=/k.db unlock > "$work/unlock.out" 2>&1 && grep -qx "unlock-keychain -p right-password /k.db" "$SECURITY_LOG"'
check "the password is not printed" '! grep -q right-password "$work/unlock.out"'
chmod 644 "$work/kc.pw"
check "a password file others can read is refused" '! OTA_KEYCHAIN_PASSWORD_FILE="$work/kc.pw" unlock 2> "$work/err" && grep -q "chmod 600" "$work/err"'
printf 'wrong\n' > "$work/kc.pw"; chmod 600 "$work/kc.pw"
check "a wrong password fails clearly" '! OTA_KEYCHAIN_PASSWORD_FILE="$work/kc.pw" unlock 2> "$work/err" && grep -q "could not unlock" "$work/err" && ! grep -q wrong "$work/err"'
check "the setting is accepted in ota.conf" 'printf "OTA_BASE_URL=https://x\nOTA_RSYNC_DEST=%s\nOTA_KEYCHAIN_PASSWORD_FILE=%s\n" "$site" "$work/kc.pw" > "$work/kc.conf" && OTA_CONFIG="$work/kc.conf" "$ROOT/bin/ota-publish" --ipa "$work/demo3.ipa" --slug demo > /dev/null'

# ota-doctor: settings, upload and page checks (signing is skipped off macOS).
doc_site="$work/doctor-site"; mkdir -p "$doc_site"
printf 'OTA_BASE_URL=https://nas.example.ts.net\nOTA_RSYNC_DEST=%s\nOTA_RSYNC_BIN=rsync\n' "$doc_site" > "$work/doctor.conf"
chmod 600 "$work/doctor.conf"
doctor() { env -u OTA_KEYCHAIN_PASSWORD_FILE "$ROOT/bin/ota-doctor" --skip-page "$@"; }
check "doctor passes on a good setup" 'doctor --config "$work/doctor.conf" > "$work/doc.out" && grep -q "All checks passed" "$work/doc.out"'
check "doctor leaves no test file behind" '[[ -z "$(ls -A "$doc_site")" ]]'
check "doctor fails on an http address" '! OTA_BASE_URL=http://x doctor --config "$work/doctor.conf" > "$work/doc.out" && grep -q "must start with https" "$work/doc.out"'
check "doctor fails when the upload cannot write" '! OTA_RSYNC_DEST=/nonexistent/deep/site doctor --config "$work/doctor.conf" > "$work/doc.out" && grep -q "cannot write to" "$work/doc.out"'
printf '#!/usr/bin/env bash\necho "openrsync: protocol version 29"\n' > "$fakebin/rsync"; chmod +x "$fakebin/rsync"
check "doctor flags openrsync" '! OTA_RSYNC_BIN="$fakebin/rsync" doctor --config "$work/doctor.conf" > "$work/doc.out" && grep -q "is openrsync" "$work/doc.out"'
touch "$work/id_test"; chmod 644 "$work/id_test"
check "doctor flags an SSH key others can read" '! OTA_RSYNC_DEST="user@nas.invalid:/x" OTA_SSH_KEY="$work/id_test" doctor --config "$work/doctor.conf" > "$work/doc.out" && grep -q "readable by other users (ssh refuses it)" "$work/doc.out"'
check "doctor reports an unknown setting" 'printf "OTA_NOPE=1\n" > "$work/nope.conf" && ! doctor --config "$work/nope.conf" > "$work/doc.out" && grep -q "unknown setting OTA_NOPE" "$work/doc.out"'

# Team precedence: OTA_TEAM_ID, then the project's team, then OTA_DEFAULT_TEAM_ID.
team_of() { # <OTA_TEAM_ID> <OTA_DEFAULT_TEAM_ID> <project team>
    OTA_TEAM_ID="$1" OTA_DEFAULT_TEAM_ID="$2" bash -c 'source "$1/lib/config.sh"; ota_resolve_team "$2"; echo "$OTA_SIGN_TEAM $OTA_SIGN_TEAM_SOURCE"' _ "$ROOT" "$3"
}
check "OTA_TEAM_ID wins over the project" '[[ "$(team_of OVERRIDE00 DEFAULT000 PROJECT000)" == "OVERRIDE00 OTA_TEAM_ID" ]]'
check "the project wins over the default" '[[ "$(team_of "" DEFAULT000 PROJECT000)" == "PROJECT000 project" ]]'
check "the default applies when the project names no team" '[[ "$(team_of "" DEFAULT000 "")" == "DEFAULT000 OTA_DEFAULT_TEAM_ID" ]]'
check "no team anywhere leaves it to Xcode" '[[ "$(team_of "" "" "")" == " none" ]]'
export build_settings='[{"target":"Widgets","buildSettings":{"WRAPPER_EXTENSION":"appex","DEVELOPMENT_TEAM":"WIDGETTEAM"}},{"target":"App","buildSettings":{"WRAPPER_EXTENSION":"app","DEVELOPMENT_TEAM":"APPTEAM001"}}]'
check "the app target's team is read, not an extension's" '[[ "$(printf "%s" "$build_settings" | python3 "$ROOT/lib/ota_tools.py" project-team)" == APPTEAM001 ]]'
check "an app target without a team reads as none" '[[ -z "$(printf "%s" "[{\"buildSettings\":{\"WRAPPER_EXTENSION\":\"app\",\"DEVELOPMENT_TEAM\":\"\"}}]" | python3 "$ROOT/lib/ota_tools.py" project-team)" ]]'
check "unreadable build settings read as none" '[[ -z "$(echo "xcodebuild: error" | python3 "$ROOT/lib/ota_tools.py" project-team)" ]]'
check "OTA_DEFAULT_TEAM_ID is accepted in ota.conf" 'printf "OTA_BASE_URL=https://x\nOTA_RSYNC_DEST=%s\nOTA_DEFAULT_TEAM_ID=ABCDE12345\n" "$site" > "$work/team.conf" && OTA_CONFIG="$work/team.conf" "$ROOT/bin/ota-publish" --ipa "$work/demo3.ipa" --slug demo > /dev/null'
check "Ad Hoc methods are recognised" 'bash -c "source \"$ROOT/lib/config.sh\"; OTA_EXPORT_METHOD=release-testing ota_is_adhoc_method && OTA_EXPORT_METHOD=ad-hoc ota_is_adhoc_method && ! OTA_EXPORT_METHOD=debugging ota_is_adhoc_method"'

if ((fails)); then echo "$fails test(s) failed"; exit 1; fi
echo "all tests passed"

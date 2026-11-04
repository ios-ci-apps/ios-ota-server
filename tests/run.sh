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

if ((fails)); then echo "$fails test(s) failed"; exit 1; fi
echo "all tests passed"

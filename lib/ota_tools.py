#!/usr/bin/env python3
"""Helpers for ios-ota-server: read an IPA, write manifest and metadata, render the index, pick versions to prune.

Standard library only, so it runs on macOS (Xcode's python3) and on Linux CI alike.
"""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import plistlib
import re
import sys
import urllib.parse
import zipfile
from pathlib import Path

# A version directory name: <version>-<build>-<short sha>. Only safe characters, so it can go into paths and URLs.
SAFE_NAME = re.compile(r"^[A-Za-z0-9._-]+$")


def fail(message: str) -> None:
    print(f"ota_tools: {message}", file=sys.stderr)
    sys.exit(1)


def read_ipa(ipa_path: Path) -> dict:
    """Return bundle id, version, build, name and the provisioning profile's expiry from an IPA."""
    with zipfile.ZipFile(ipa_path) as ipa:
        names = ipa.namelist()
        info_name = next(
            (n for n in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)), None
        )
        if info_name is None:
            fail(f"{ipa_path} has no Payload/<App>.app/Info.plist")
        info = plistlib.loads(ipa.read(info_name))
        app_dir = info_name.rsplit("/", 1)[0]
        expires_at = None
        profile_name = f"{app_dir}/embedded.mobileprovision"
        if profile_name in names:
            expires_at = profile_expiry(ipa.read(profile_name))
    return {
        "bundleId": info["CFBundleIdentifier"],
        "version": str(info.get("CFBundleShortVersionString", "0")),
        "build": str(info.get("CFBundleVersion", "0")),
        "name": info.get("CFBundleDisplayName") or info.get("CFBundleName") or "App",
        "expiresAt": expires_at,
    }


def profile_expiry(data: bytes) -> str | None:
    """The profile is a signed CMS blob with an XML plist inside; cut the plist out instead of verifying it."""
    start = data.find(b"<?xml")
    end = data.find(b"</plist>")
    if start < 0 or end < 0:
        return None
    try:
        profile = plistlib.loads(data[start : end + len(b"</plist>")])
    except Exception:
        return None
    expiry = profile.get("ExpirationDate")
    if isinstance(expiry, dt.datetime):
        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=dt.timezone.utc)
        return iso(expiry)
    return None


def iso(moment: dt.datetime) -> str:
    return moment.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def version_dir_name(meta: dict) -> str:
    name = f"{meta['version']}-{meta['build']}-{meta['sha'][:7]}"
    name = re.sub(r"[^A-Za-z0-9._-]", "_", name)
    return name


def cmd_prepare(args: argparse.Namespace) -> None:
    """Build <out>/<slug>/<version dir>/ with the IPA, manifest.plist and meta.json; print the relative dir."""
    if not SAFE_NAME.fullmatch(args.slug):
        fail(f"app slug '{args.slug}' may only contain letters, digits, '.', '_' and '-'")
    ipa_path = Path(args.ipa)
    meta = read_ipa(ipa_path)
    built_at = dt.datetime.now(dt.timezone.utc)
    if meta["expiresAt"] is None:
        meta["expiresAt"] = iso(built_at + dt.timedelta(days=args.profile_days))
    meta.update(
        {
            "slug": args.slug,
            "displayName": args.display_name or meta["name"],
            "sha": args.sha or "unknown",
            "ref": args.ref or "",
            "builtAt": iso(built_at),
        }
    )
    rel_dir = f"{args.slug}/{version_dir_name(meta)}"
    meta["dir"] = rel_dir
    target = Path(args.out) / rel_dir
    target.mkdir(parents=True, exist_ok=True)

    ipa_name = f"{args.slug}.ipa"
    (target / ipa_name).write_bytes(ipa_path.read_bytes())
    base = args.base_url.rstrip("/")
    manifest = {
        "items": [
            {
                "assets": [{"kind": "software-package", "url": f"{base}/{rel_dir}/{ipa_name}"}],
                "metadata": {
                    "bundle-identifier": meta["bundleId"],
                    "bundle-version": meta["version"],
                    "kind": "software",
                    "title": meta["displayName"],
                },
            }
        ]
    }
    with open(target / "manifest.plist", "wb") as handle:
        plistlib.dump(manifest, handle)
    (target / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(rel_dir)


def load_metas(root: Path) -> dict[str, list[dict]]:
    """All meta.json files under root, grouped by app slug, newest first."""
    apps: dict[str, list[dict]] = {}
    for path in sorted(root.glob("*/*/meta.json")):
        try:
            meta = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        meta["dir"] = f"{path.parent.parent.name}/{path.parent.name}"
        apps.setdefault(path.parent.parent.name, []).append(meta)
    for versions in apps.values():
        versions.sort(key=lambda m: m.get("builtAt", ""), reverse=True)
    return apps


def cmd_prune(args: argparse.Namespace) -> None:
    """Print the version dirs (relative to root) that fall outside the newest --keep of each app."""
    for versions in load_metas(Path(args.root)).values():
        for meta in versions[args.keep :]:
            print(meta["dir"])


def install_link(base: str, rel_dir: str) -> str:
    manifest_url = f"{base}/{rel_dir}/manifest.plist"
    return "itms-services://?action=download-manifest&url=" + urllib.parse.quote(manifest_url, safe="")


def cmd_index(args: argparse.Namespace) -> None:
    base = args.base_url.rstrip("/")
    now = dt.datetime.now(dt.timezone.utc)
    apps = load_metas(Path(args.root))
    sections = []
    for slug in sorted(apps, key=lambda s: apps[s][0].get("displayName", s).lower()):
        versions = apps[slug]
        rows = []
        for position, meta in enumerate(versions):
            esc = {k: html.escape(str(v)) for k, v in meta.items()}
            expired = meta.get("expiresAt", "") < iso(now)
            status = '<span class="bad">expired</span>' if expired else f"expires {esc.get('expiresAt', '')[:10]}"
            label = "Install" if position == 0 else "Install this version"
            rows.append(
                f'<li class="{"latest" if position == 0 else "old"}">'
                f'<div><strong>{esc["version"]} ({esc["build"]})</strong> '
                f'<code>{esc["sha"][:7]}</code><br><small>built {esc["builtAt"][:16].replace("T", " ")} UTC · {status}</small></div>'
                f'<a class="btn" href="{html.escape(install_link(base, meta["dir"]))}">{label}</a></li>'
            )
        title = html.escape(versions[0].get("displayName", slug))
        older = ""
        if len(rows) > 1:
            older = f'<details><summary>Older versions ({len(rows) - 1})</summary><ul>{"".join(rows[1:])}</ul></details>'
        sections.append(
            f'<section><h2>{title}</h2><p class="muted">{html.escape(versions[0].get("bundleId", ""))}</p>'
            f"<ul>{rows[0]}</ul>{older}</section>"
        )
    body = "".join(sections) or '<p class="muted">No builds yet.</p>'
    page = INDEX_TEMPLATE.replace("{{BODY}}", body).replace("{{UPDATED}}", iso(now))
    Path(args.output).write_text(page)


INDEX_TEMPLATE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>OTA Builds</title>
<style>
:root{--bg:#f6f6f8;--card:#fff;--fg:#1c1c1e;--muted:#6e6e73;--accent:#0a84ff;--bad:#d70015}
@media (prefers-color-scheme: dark){:root{--bg:#000;--card:#1c1c1e;--fg:#f2f2f7;--muted:#98989d;--bad:#ff453a}}
body{margin:0;background:var(--bg);color:var(--fg);font:16px -apple-system,system-ui,sans-serif}
main{max-width:640px;margin:0 auto;padding:16px}
section{background:var(--card);border-radius:12px;padding:12px 16px;margin:12px 0}
h1{font-size:28px;margin:8px 0}h2{font-size:20px;margin:4px 0}
ul{list-style:none;margin:0;padding:0}
li{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:10px 0;border-top:1px solid rgba(128,128,128,.2)}
.muted,small{color:var(--muted)}.bad{color:var(--bad)}
.btn{background:var(--accent);color:#fff;text-decoration:none;padding:8px 14px;border-radius:18px;white-space:nowrap}
.old .btn{background:transparent;color:var(--accent);border:1px solid var(--accent)}
summary{cursor:pointer;color:var(--accent);padding:8px 0}
</style></head>
<body><main><h1>OTA Builds</h1>{{BODY}}
<p class="muted"><small>Updated {{UPDATED}}</small></p></main></body></html>
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    prepare = sub.add_parser("prepare", help="stage an IPA with its manifest and metadata")
    prepare.add_argument("--ipa", required=True)
    prepare.add_argument("--slug", required=True)
    prepare.add_argument("--out", required=True)
    prepare.add_argument("--base-url", required=True)
    prepare.add_argument("--display-name", default="")
    prepare.add_argument("--sha", default="")
    prepare.add_argument("--ref", default="")
    prepare.add_argument("--profile-days", type=int, default=7)
    prepare.set_defaults(func=cmd_prepare)

    prune = sub.add_parser("prune", help="list version dirs beyond the newest --keep per app")
    prune.add_argument("--root", required=True)
    prune.add_argument("--keep", type=int, required=True)
    prune.set_defaults(func=cmd_prune)

    index = sub.add_parser("index", help="render index.html from every meta.json under --root")
    index.add_argument("--root", required=True)
    index.add_argument("--base-url", required=True)
    index.add_argument("--output", required=True)
    index.set_defaults(func=cmd_index)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

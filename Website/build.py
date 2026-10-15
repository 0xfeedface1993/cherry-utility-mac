#!/usr/bin/env python3
"""Builds the static website, the Sparkle appcast and the release manifest from Website/releases.json.

    python3 Website/build.py [--artifacts DIR] [--out DIR]
    python3 Website/build.py --design OUT.html     # self-contained 1440 + 390 px capture for Figma

releases.json is the single source of truth: the release script appends an entry (version, build, DMG name,
length, SHA-256, EdDSA signature). Until the newest entry has a DMG the site renders in "pending" mode — the
download buttons are disabled and appcast.xml lists no items, so no installed app is offered an update.
"""
import argparse
import base64
import html
import json
import re
import shutil
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.dmg$")


def load_manifest():
    data = json.loads((ROOT / "releases.json").read_text())
    base = data["baseURL"]
    if not base.startswith("https://") or not base.endswith("/"):
        sys.exit("baseURL must be an https URL ending in /")
    for r in data["releases"]:
        if r.get("dmg") and not SAFE_NAME.match(r["dmg"]):
            sys.exit(f"invalid DMG name: {r['dmg']}")
    return data


def published(data):
    """Releases with a notarized, Sparkle-signed DMG; anything else is listed as upcoming only."""
    return [r for r in data["releases"]
            if r.get("dmg") and r.get("edSignature") and r.get("sha256") and r.get("length") and r.get("notarized") is True]


def human_size(n):
    return f"{n / 1_000_000:.1f} MB"


def changelog_html(releases):
    out = []
    for r in releases:
        notes = "".join(f"<li>{html.escape(n)}</li>" for n in r["notes"])
        date = r.get("date") or "即将发布"
        out.append(f'          <article class="release"><header><h3>{html.escape(r["version"])}</h3>'
                   f'<time>{html.escape(date)}</time></header><ul>{notes}</ul></article>')
    return "\n".join(out)


def render_index(data, design=False):
    live = published(data)
    latest = live[0] if live else None
    shown = data["releases"]
    page = (SRC / "index.html").read_text()
    if latest:
        values = {"VERSION": latest["version"], "DMG": f"downloads/{latest['dmg']}", "DMG_SIZE": human_size(latest["length"])}
    else:
        values = {"VERSION": shown[0]["version"] if shown else "1.0", "DMG": "#changelog", "DMG_SIZE": "即将发布"}
    if design and not latest:
        values["DMG_SIZE"] = "14.8 MB"
    # Hero eyebrow: the first public release is announced as such, later ones as the latest version.
    values["HEADLINE"] = "即将发布" if not latest and not design else ("首个公开版本" if len(live) <= 1 else "最新版本")
    values["MIN_OS"] = data["minimumSystemVersion"]
    values["CHANGELOG"] = changelog_html(shown)
    for k, v in values.items():
        page = page.replace("{{" + k + "}}", v)
    if not latest and not design:
        # Pending: keep the layout but make every download control inert.
        page = page.replace("data-download>", 'data-download aria-disabled="true" style="pointer-events:none;opacity:.55">')
    leftover = re.findall(r"\{\{[A-Z_]+\}\}", page)
    if leftover:
        sys.exit(f"unfilled placeholders: {leftover}")
    return page


def appcast(data):
    base = data["baseURL"]
    items = []
    for r in published(data):
        notes = "".join(f"<li>{html.escape(n)}</li>" for n in r["notes"])
        pub = format_datetime(datetime.fromisoformat(r["published"]).astimezone(timezone.utc)) if r.get("published") else ""
        items.append(f"""    <item>
      <title>{html.escape(r['version'])}</title>
      <pubDate>{pub}</pubDate>
      <sparkle:version>{int(r['build'])}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(r['version'])}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(r.get('minimumSystemVersion', data['minimumSystemVersion']))}</sparkle:minimumSystemVersion>
      <description><![CDATA[<meta charset="utf-8"><h3>{html.escape(r['version'])}</h3><ul>{notes}</ul>]]></description>
      <enclosure url="{base}downloads/{r['dmg']}" length="{int(r['length'])}" type="application/octet-stream" sparkle:edSignature="{html.escape(r['edSignature'])}"/>
    </item>""")
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>{html.escape(data['product'])}</title>
    <link>{base}</link>
    <description>{html.escape(data['product'])} 更新</description>
    <language>zh-cn</language>
{chr(10).join(items)}
  </channel>
</rss>
"""


def latest_json(data):
    live = published(data)
    if not live:
        return {"product": data["product"], "status": "pending", "version": None, "build": None, "dmg": None,
                "sha256": None, "length": None, "minimumSystemVersion": data["minimumSystemVersion"], "appcast": data["baseURL"] + "appcast.xml"}
    r = live[0]
    return {"product": data["product"], "status": "published", "version": r["version"], "build": r["build"],
            "published": r.get("published"), "dmg": data["baseURL"] + "downloads/" + r["dmg"], "sha256": r["sha256"],
            "length": r["length"], "minimumSystemVersion": r.get("minimumSystemVersion", data["minimumSystemVersion"]),
            "appcast": data["baseURL"] + "appcast.xml"}


def build(out, artifacts):
    data = load_manifest()
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(SRC, out, ignore=shutil.ignore_patterns("index.html", ".DS_Store"))
    (out / "index.html").write_text(render_index(data))
    (out / "appcast.xml").write_text(appcast(data))
    (out / "releases").mkdir()
    (out / "releases" / "latest.json").write_text(json.dumps(latest_json(data), ensure_ascii=False, indent=2) + "\n")
    downloads = out / "downloads"
    downloads.mkdir()
    for r in published(data):
        # Only DMGs from this run are copied; earlier ones are carried forward by the deploy script.
        if artifacts and (artifacts / r["dmg"]).exists():
            src = artifacts / r["dmg"]
            if src.stat().st_size != r["length"]:
                sys.exit(f"{r['dmg']}: size differs from releases.json")
            shutil.copy2(src, downloads / r["dmg"])
            (downloads / (r["dmg"] + ".sha256")).write_text(f"{r['sha256']}  {r['dmg']}\n")
    print(f"built {out} ({'published ' + published(data)[0]['version'] if published(data) else 'pending'})")


def design(path):
    data = load_manifest()
    page = render_index(data, design=True)
    css = (SRC / "styles.css").read_text()
    css += "\n.site{min-height:0}.capture{display:flex;gap:80px;align-items:flex-start;padding:40px;background:#E6E2DF;width:max-content}"

    def inline(m):
        ref = m.group(1)
        p = SRC / ref
        kinds = {".png": "image/png", ".webp": "image/webp"}
        if p.suffix in kinds and p.exists():
            return f'src="data:{kinds[p.suffix]};base64,{base64.b64encode(p.read_bytes()).decode()}"'
        return m.group(0)

    # Captures are rendered per theme: drop the dark <source>; dark frames point their <img> at the dark screenshots.
    page = re.sub(r'<source [^>]*prefers-color-scheme: dark[^>]*>', "", page)
    page = page.replace('<link rel="stylesheet" href="styles.css">', f"<style>{css}</style>")
    body = re.search(r'<div class="site">.*</div>\s*</body>', page, re.S).group(0).rsplit("</body>", 1)[0]
    frames = [(1440, "light", "Website / Desktop 1440 (light)"), (1440, "dark", "Website / Desktop 1440 (dark)"), (390, "light", "Website / Mobile 390 (light)")]
    parts = []
    for w, theme, name in frames:
        frame = body.replace('<div class="site">', f'<div class="site" data-theme="{theme}" data-name="{name}">', 1)
        if theme == "dark":
            frame = frame.replace("-light.webp", "-dark.webp")
        parts.append(f'<div style="width:{w}px;flex:none">' + re.sub(r'src="(assets/[^"]+)"', inline, frame) + "</div>")
    two = '<div class="capture">' + "".join(parts) + "</div>"
    page = re.sub(r'<body>.*</body>', lambda _: f"<body>{two}</body>", page, flags=re.S)
    Path(path).write_text(page)
    print(f"design capture → {path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=ROOT / "dist")
    ap.add_argument("--artifacts", type=Path)
    ap.add_argument("--design")
    a = ap.parse_args()
    if a.design:
        design(a.design)
    else:
        build(a.out.resolve(), a.artifacts.resolve() if a.artifacts else None)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Builds the static website, the Sparkle appcast and the release manifest from Website/releases.json.

    python3 Website/build.py [--artifacts DIR] [--out DIR]
    python3 Website/build.py --design OUT.html     # self-contained 1440 + 390 px capture for Figma

releases.json is the single source of truth (repository is the GitHub URL the page links to): the release script appends an entry (version, build, DMG name,
length, SHA-256, EdDSA signature). Until the newest entry has a DMG the site renders in "pending" mode — the
download buttons are disabled and appcast.xml lists no items, so no installed app is offered an update.

每个版本可选附带独立命令行 cherry 的 zip：cliZip（文件名）、cliLength（字节数）、cliSha256，三项同时出现。
带 zip 的最新已发布版本会在下载按钮旁显示「下载命令行工具 cherry」（模板里 <!--CLI-->…<!--/CLI--> 包住的部分），
并写进 releases/latest.json 的 cli 段；没有时这些内容都不出现。（Homebrew cask 的 livecheck 读 GitHub Release，不读这里。）
"""
import argparse
import base64
import hashlib
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
SAFE_ZIP = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
CLI_FIELDS = ("cliZip", "cliLength", "cliSha256")
CLI_BLOCK = re.compile(r"[ \t]*<!--CLI-->\n?(.*?)[ \t]*<!--/CLI-->\n?", re.S)


def load_manifest():
    data = json.loads((ROOT / "releases.json").read_text())
    base = data["baseURL"]
    if not base.startswith("https://") or not base.endswith("/"):
        sys.exit("baseURL must be an https URL ending in /")
    # 官网的 GitHub 入口（导航、自动化文档链接、开源一节、页脚）都由它生成。
    if not re.fullmatch(r"https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+", data.get("repository", "")):
        sys.exit("repository must be https://github.com/<owner>/<repo> without a trailing slash")
    for r in data["releases"]:
        if r.get("dmg") and not SAFE_NAME.match(r["dmg"]):
            sys.exit(f"invalid DMG name: {r['dmg']}")
        # 命令行 zip 的三项要么都有、要么都没有；文件名沿用 DMG 的安全规则。
        present = [k for k in CLI_FIELDS if r.get(k) is not None]
        if not present:
            continue
        if len(present) != len(CLI_FIELDS):
            sys.exit(f"{r['version']}: cliZip, cliLength and cliSha256 must be given together (found {', '.join(present)})")
        if not SAFE_ZIP.match(r["cliZip"]):
            sys.exit(f"invalid CLI zip name: {r['cliZip']}")
        if type(r["cliLength"]) is not int or r["cliLength"] <= 0:
            sys.exit(f"{r['cliZip']}: cliLength must be a positive integer")
        if not SHA256.match(r["cliSha256"]):
            sys.exit(f"{r['cliZip']}: cliSha256 must be 64 lowercase hex digits")
    return data


def published(data):
    """Releases with a notarized, Sparkle-signed DMG; anything else is listed as upcoming only."""
    return [r for r in data["releases"]
            if r.get("dmg") and r.get("edSignature") and r.get("sha256") and r.get("length") and r.get("notarized") is True]


def latest_cli(data):
    """带命令行 zip 的最新已发布版本；旧版本都没有 cliZip 时为 None。"""
    return next((r for r in published(data) if r.get("cliZip")), None)


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
    values["GITHUB"] = data["repository"]
    values["DOCS"] = data["repository"] + "/blob/main/Docs"
    values["GITHUB_OWNER"], values["GITHUB_REPO"] = data["repository"].rsplit("/", 2)[1:]
    values["CHANGELOG"] = changelog_html(shown)
    # 命令行入口只在有带 zip 的已发布版本时出现，否则连同其中的占位符一起删掉。
    cli = latest_cli(data)
    page = CLI_BLOCK.sub((lambda m: m.group(1)) if cli else "", page)
    if "<!--CLI-->" in page or "<!--/CLI-->" in page:
        sys.exit("unbalanced <!--CLI--> block in index.html")
    if cli:
        values.update({"CLI_ZIP": f"downloads/{cli['cliZip']}", "CLI_SIZE": human_size(cli["cliLength"]),
                       "CLI_VERSION": cli["version"]})
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


def cli_json(data):
    c = latest_cli(data)
    if not c:
        return None
    return {"version": c["version"], "build": c["build"], "zip": data["baseURL"] + "downloads/" + c["cliZip"],
            "sha256": c["cliSha256"], "length": c["cliLength"]}


def latest_json(data):
    live = published(data)
    if not live:
        return {"product": data["product"], "status": "pending", "version": None, "build": None, "dmg": None,
                "sha256": None, "length": None, "minimumSystemVersion": data["minimumSystemVersion"], "appcast": data["baseURL"] + "appcast.xml",
                "cli": None}
    r = live[0]
    return {"product": data["product"], "status": "published", "version": r["version"], "build": r["build"],
            "published": r.get("published"), "dmg": data["baseURL"] + "downloads/" + r["dmg"], "sha256": r["sha256"],
            "length": r["length"], "minimumSystemVersion": r.get("minimumSystemVersion", data["minimumSystemVersion"]),
            "appcast": data["baseURL"] + "appcast.xml", "cli": cli_json(data)}


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
        # 命令行 zip 同理，另外核对 SHA-256。
        if artifacts and r.get("cliZip") and (artifacts / r["cliZip"]).exists():
            src = artifacts / r["cliZip"]
            if src.stat().st_size != r["cliLength"]:
                sys.exit(f"{r['cliZip']}: size differs from releases.json")
            if hashlib.sha256(src.read_bytes()).hexdigest() != r["cliSha256"]:
                sys.exit(f"{r['cliZip']}: SHA-256 differs from releases.json")
            shutil.copy2(src, downloads / r["cliZip"])
            (downloads / (r["cliZip"] + ".sha256")).write_text(f"{r['cliSha256']}  {r['cliZip']}\n")
    cli = latest_cli(data)
    print(f"built {out} ({'published ' + published(data)[0]['version'] if published(data) else 'pending'}"
          f"{', cli ' + cli['version'] if cli else ''})")


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

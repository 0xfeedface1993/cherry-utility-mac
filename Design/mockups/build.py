#!/usr/bin/env python3
"""Generates the high-fidelity HTML mockups that seed the Figma redesign file.

Each output document holds several `.screen` elements; html_to_figma captures every match as its own frame.
Icons are SF Symbols (private-use glyphs of SF Pro), so the names map 1:1 to `Image(systemName:)`.
Run: python3 Design/mockups/build.py  →  Design/mockups/out/*.html
"""
import base64
import html
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "out"
LAYOUT = json.loads((ROOT / "pixiu75.js").read_text().split("=", 1)[1].rstrip().rstrip(";"))

SYM = {
    "gauge.with.dots.needle.67percent": "10037e", "lightbulb.led": "1013a6", "light.max": "1001ee", "keyboard": "1001f3",
    "arrow.down.circle": "100078", "flask": "101c0d", "stethoscope": "10077e", "gearshape": "1008cb",
    "battery.75percent": "100eb8", "battery.100percent.bolt": "10088b", "cable.connector": "100ea6",
    "antenna.radiowaves.left.and.right": "100580", "cpu": "100ae5", "arrow.clockwise": "100148",
    "checkmark.seal.fill": "1001fb", "exclamationmark.triangle.fill": "1001ff", "info.circle": "100174",
    "chevron.right": "10018a", "chevron.down": "100188", "chevron.up.chevron.down": "10018f", "xmark": "100184",
    "power": "1001a8", "macwindow": "1003dc", "sparkles": "1001bf", "square.and.arrow.up": "100202",
    "square.and.arrow.down": "100204", "ellipsis.circle": "100361", "ellipsis": "100360", "plus": "10017c",
    "trash": "100211", "tortoise": "1004d0", "hare": "1004ce", "sun.min": "1001ab", "sun.max": "1001ad",
    "moon.zzz": "1001bd", "bolt.fill": "1002e6", "icloud.and.arrow.down": "100315", "folder": "100215",
    "arrow.uturn.backward": "100c4d", "wand.and.stars": "10070d", "hand.raised.fill": "10027c",
    "dot.radiowaves.left.and.right": "100319", "keyboard.badge.ellipsis": "100ad2", "cable.connector.slash": "1021e5",
    "arrow.counterclockwise": "100149", "lock.shield": "100799", "checkmark.circle.fill": "100063",
    "xmark.octagon.fill": "10048a", "arrow.triangle.2.circlepath": "1002af", "square.stack.3d.down.right": "10041c",
    "paintpalette": "100765", "water.waves": "101384", "rainbow": "100f2d", "wind": "1001e4",
    "arrow.trianglehead.2.clockwise": "1028fc", "point.topleft.down.to.point.bottomright.curvepath": "1008f1",
    "arrow.left.and.right": "10013e", "circle.dotted.circle": "101e67", "hand.tap": "100b01", "lightbulb": "1006ed",
    "arrow.down.circle.fill": "100079", "arrow.up.circle": "100076", "questionmark.circle": "10005c", "clock": "10042b",
    "checkmark": "100185", "dial.medium": "1013b4", "slider.horizontal.3": "100306", "arrow.up.right.square": "100114",
    "arrow.down.to.line": "100140", "shippingbox": "10041a", "lock": "1003a0", "exclamationmark.shield": "10079f",
    "eye": "1002ed", "doc.text": "10023f", "magnifyingglass": "1002ab", "bell.badge": "100756", "command": "100194",
    "apple.logo": "1008fa", "speaker.wave.2.fill": "1002a7", "gearshape.2": "10094e", "checklist": "100dfe",
    "arrow.right": "10012b", "circle.fill": "100001", "menubar.rectangle": "10098d", "list.bullet": "1002f2",
    "pencil.circle.fill": "10020c", "app.badge": "10044f", "shield.lefthalf.filled": "100668",
    "exclamationmark.circle": "10005e",
}

EFFECTS = [  # rawValue, name, symbol — CherryCore LightingEffect.pixiu75 order
    (0, "波纹", "water.waves"), (1, "光谱", "rainbow"), (2, "呼吸", "wind"), (10, "霓虹", "arrow.trianglehead.2.clockwise"),
    (12, "曲线", "point.topleft.down.to.point.bottomright.curvepath"), (15, "折返", "arrow.left.and.right"),
    (18, "放射", "dot.radiowaves.left.and.right"), (19, "扩散", "circle.dotted.circle"), (21, "单点亮", "hand.tap"),
    (3, "常亮", "lightbulb"), (8, "自定义", "paintpalette"),
]
PALETTE = ["FF0000", "FF7200", "FFF005", "00D70F", "0099FF", "3153FF", "5E01D2", "EE00F1", "FF008A", "FFFFFF"]


def s(name, cls=""):
    return f'<span class="sym {cls}">&#x{SYM[name]};</span>'


def e(text):
    return html.escape(text)


def png_data_uri(path):
    return "data:image/png;base64," + base64.b64encode(Path(path).read_bytes()).decode()


ICON_URI = None  # filled in main()

CSS = r"""
*{box-sizing:border-box;margin:0;padding:0}
body{background:#E6E2DF;font-family:"SF Pro","SF Pro Text",-apple-system,"PingFang SC",sans-serif;-webkit-font-smoothing:antialiased;color:#1B1A19}
.sheet{display:flex;flex-wrap:wrap;gap:60px;padding:60px;align-items:flex-start}
.sym{font-family:"SF Pro","SF Pro Text";font-weight:400;line-height:1;display:inline-block}
.light{--bg-window:#FBFAF9;--bg-sidebar:#F2F0EE;--bg-surface:#FFFFFF;--bg-inset:#F5F3F2;--bg-control:#ECE9E7;--bg-hover:#E7E3E0;
  --border:#E3DFDC;--border-strong:#C5C0BC;--text:#1B1A19;--text-2:#5A5552;--text-3:#A09A96;
  --accent:#D3123F;--accent-text:#D3123F;--accent-subtle:#FFF0F2;--accent-line:#FFC1CB;
  --success:#16A34A;--success-subtle:#E9F8EE;--warning:#C2410C;--warning-subtle:#FFF5E6;--warning-line:#FCD9A8;--danger:#DC2626;--info:#2563EB;--info-subtle:#EEF4FF;
  --shadow:0 1px 2px rgba(27,26,25,.06),0 1px 1px rgba(27,26,25,.04);--knob:#FFFFFF;--kbd-case:#E9E5E2;--kbd-cap:#FFFFFF;--kbd-cap-side:#D9D3CF;--kbd-legend:#5A5552}
.dark{--bg-window:#1B1A19;--bg-sidebar:#232120;--bg-surface:#262423;--bg-inset:#1F1D1C;--bg-control:#34312F;--bg-hover:#3A3735;
  --border:#3A3634;--border-strong:#5A5552;--text:#FBFAF9;--text-2:#A9A39F;--text-3:#7B7571;
  --accent:#D3123F;--accent-text:#FF5A76;--accent-subtle:#3A0F1B;--accent-line:#8A0D2E;
  --success:#4ADE80;--success-subtle:#14301F;--warning:#FBBF24;--warning-subtle:#352812;--warning-line:#6B4A12;--danger:#F87171;--info:#60A5FA;--info-subtle:#172540;
  --shadow:0 1px 2px rgba(0,0,0,.4);--knob:#F5F3F2;--kbd-case:#121110;--kbd-cap:#34312F;--kbd-cap-side:#232120;--kbd-legend:#C5C0BC}

/* window */
.screen{position:relative}
.window{width:1120px;height:760px;border-radius:16px;overflow:hidden;display:flex;background:var(--bg-window);color:var(--text);
  box-shadow:0 0 0 .5px rgba(0,0,0,.28),0 24px 70px rgba(0,0,0,.25),0 4px 14px rgba(0,0,0,.08)}
.sidebar{width:248px;margin:8px 0 8px 8px;border-radius:14px;background:var(--bg-sidebar);border:.5px solid var(--border);display:flex;flex-direction:column;padding:10px 10px 10px;flex:none}
.traffic{display:flex;gap:8px;padding:6px 6px 16px}
.traffic i{display:block;width:12px;height:12px;border-radius:50%;background:#FF5F57;box-shadow:inset 0 0 0 .5px rgba(0,0,0,.18)}
.traffic i:nth-child(2){background:#FEBC2E}.traffic i:nth-child(3){background:#28C840}
.device{display:flex;align-items:center;gap:10px;padding:10px;border-radius:12px;background:var(--bg-surface);border:.5px solid var(--border);box-shadow:var(--shadow);margin-bottom:14px}
.device .thumb{width:36px;height:36px;border-radius:9px;background:linear-gradient(180deg,#FF4F6D,#D3123F 55%,#8A0D2E);display:flex;align-items:center;justify-content:center;flex:none}
.device .thumb svg{width:24px;height:24px}
.device .name{font-size:13px;font-weight:600;line-height:16px}
.device .meta{font-size:11px;color:var(--text-2);line-height:14px;display:flex;align-items:center;gap:4px}
.device .chev{margin-left:auto;font-size:11px;color:var(--text-3)}
.dot{display:inline-block;width:6px;height:6px;border-radius:50%;background:var(--success)}
.dot.gray{background:var(--text-3)}.dot.amber{background:var(--warning)}
.navlabel{font-size:11px;font-weight:600;color:var(--text-3);padding:2px 8px 6px}
.nav{display:flex;flex-direction:column;gap:2px}
.nav a{display:flex;align-items:center;gap:9px;height:32px;padding:0 9px;border-radius:8px;font-size:13px;color:var(--text);text-decoration:none}
.nav a .sym{width:18px;text-align:center;font-size:14px;color:var(--accent-text)}
.nav a.on{background:var(--accent);color:#fff}
.nav a.on .sym{color:#fff}
.nav a .badge{margin-left:auto}
.nav a.on .badge{background:rgba(255,255,255,.22);color:#fff}
.sidebar .spacer{flex:1}
.sidebar .foot{display:flex;flex-direction:column;gap:2px;border-top:.5px solid var(--border);padding-top:8px}
.sidebar .foot a .sym{color:var(--text-2)}
main{flex:1;display:flex;flex-direction:column;min-width:0}
.toolbar{height:56px;display:flex;align-items:center;padding:0 16px 0 24px;gap:10px;flex:none}
.toolbar .titles{display:flex;flex-direction:column}
.toolbar h1{font-size:15px;font-weight:600;line-height:19px;display:flex;align-items:center;gap:8px}
.toolbar .sub{font-size:11px;color:var(--text-2);line-height:13px}
.toolbar .tools{margin-left:auto;display:flex;gap:8px;align-items:center}
.glass{height:32px;min-width:32px;padding:0 12px;border-radius:999px;background:var(--bg-surface);border:.5px solid var(--border);box-shadow:var(--shadow);display:flex;align-items:center;justify-content:center;gap:6px;font-size:12px;color:var(--text)}
.glass .sym{font-size:13px}
.content{flex:1;overflow:hidden;padding:4px 28px 24px;display:flex;flex-direction:column;gap:16px;position:relative}
.content>*{flex-shrink:0}
.col{display:flex;flex-direction:column;gap:16px}
.row{display:flex;gap:16px}
.grow{flex:1;min-width:0}

/* cards & text */
.card{background:var(--bg-surface);border:.5px solid var(--border);border-radius:14px;box-shadow:var(--shadow);padding:16px}
.card-h{display:flex;align-items:center;gap:8px;margin-bottom:12px}
.card-h h3{font-size:13px;font-weight:600}
.card-h .aux{margin-left:auto;font-size:11px;color:var(--text-2);display:flex;align-items:center;gap:6px}
.title1{font-size:22px;font-weight:700;letter-spacing:-.3px;line-height:28px}
.title2{font-size:17px;font-weight:600;letter-spacing:-.2px}
.body{font-size:13px;line-height:18px}
.callout{font-size:12px;line-height:16px}
.caption{font-size:11px;line-height:14px;color:var(--text-2)}
.muted{color:var(--text-2)}.faint{color:var(--text-3)}
.mono{font-family:"SF Mono","JetBrains Mono",ui-monospace,monospace;font-size:12px}
.badge{display:inline-flex;align-items:center;gap:4px;height:18px;font-size:10px;font-weight:600;padding:0 7px;border-radius:999px;background:var(--accent-subtle);color:var(--accent-text);white-space:nowrap}
.badge.green{background:var(--success-subtle);color:var(--success)}
.badge.amber{background:var(--warning-subtle);color:var(--warning)}
.badge.gray{background:var(--bg-control);color:var(--text-2)}
.badge.info{background:var(--info-subtle);color:var(--info)}

/* controls */
.btn{height:28px;padding:0 14px;border-radius:999px;font-size:13px;font-weight:500;background:var(--bg-control);color:var(--text);display:inline-flex;align-items:center;justify-content:center;gap:6px;white-space:nowrap;border:.5px solid var(--border)}
.btn.primary{background:var(--accent);color:#fff;border-color:transparent;box-shadow:0 1px 2px rgba(211,18,63,.35)}
.btn.plain{background:transparent;border-color:transparent;color:var(--accent-text)}
.btn.danger{color:var(--danger)}
.btn.lg{height:34px;padding:0 18px;font-size:13px}
.btn.sm{height:24px;padding:0 10px;font-size:12px}
.btn[disabled]{opacity:.45}
.btn .sym{font-size:12px}
.kbdhint{font-size:11px;opacity:.7}
.seg{display:inline-flex;background:var(--bg-control);border-radius:999px;padding:2px;gap:2px}
.seg span{height:24px;padding:0 12px;border-radius:999px;font-size:12px;display:flex;align-items:center;gap:5px;color:var(--text-2)}
.seg span.on{background:var(--bg-surface);color:var(--text);font-weight:600;box-shadow:0 1px 2px rgba(0,0,0,.14),0 0 0 .5px rgba(0,0,0,.06)}
.seg.fill{display:flex}.seg.fill span{flex:1;justify-content:center}
.switch{width:34px;height:20px;border-radius:999px;background:var(--bg-control);position:relative;flex:none;box-shadow:inset 0 0 0 .5px var(--border-strong)}
.switch::after{content:"";position:absolute;top:2px;left:2px;width:16px;height:16px;border-radius:50%;background:var(--knob);box-shadow:0 1px 2px rgba(0,0,0,.25)}
.switch.on{background:var(--accent);box-shadow:none}.switch.on::after{left:16px}
.slider{position:relative;height:20px;flex:1;display:flex;align-items:center}
.slider .track{position:absolute;left:0;right:0;height:4px;border-radius:2px;background:var(--bg-control)}
.slider .fill{position:absolute;left:0;height:4px;border-radius:2px;background:var(--accent)}
.slider .thumb{position:absolute;width:18px;height:18px;margin-left:-9px;border-radius:50%;background:var(--knob);box-shadow:0 1px 3px rgba(0,0,0,.3),0 0 0 .5px rgba(0,0,0,.08)}
.slider .tick{position:absolute;width:2px;height:6px;margin-left:-1px;border-radius:1px;background:var(--border-strong);top:7px}
.field{height:28px;border-radius:7px;background:var(--bg-surface);border:.5px solid var(--border-strong);padding:0 10px;font-size:13px;display:flex;align-items:center;color:var(--text-3)}
.check{width:16px;height:16px;border-radius:4px;background:var(--accent);color:#fff;display:inline-flex;align-items:center;justify-content:center;font-size:10px;flex:none}
.check.off{background:var(--bg-surface);box-shadow:inset 0 0 0 .5px var(--border-strong)}

/* list rows (grouped form) */
.group{background:var(--bg-surface);border:.5px solid var(--border);border-radius:12px;box-shadow:var(--shadow);overflow:hidden}
.group .r{display:flex;align-items:center;gap:12px;min-height:38px;padding:8px 14px;font-size:13px}
.group .r + .r{border-top:.5px solid var(--border)}
.group .r .k{color:var(--text-2);width:120px;flex:none}
.group .r .v{flex:1;min-width:0}
.group .r .end{margin-left:auto;display:flex;align-items:center;gap:8px;color:var(--text-2)}
.group .r .sub{font-size:11px;color:var(--text-2);line-height:14px;margin-top:2px}

/* tiles */
.tiles{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}
.tile{background:var(--bg-surface);border:.5px solid var(--border);border-radius:14px;box-shadow:var(--shadow);padding:14px;display:flex;flex-direction:column;gap:6px;min-height:108px}
.tile .lab{font-size:11px;font-weight:600;color:var(--text-2);display:flex;align-items:center;gap:6px}
.tile .lab .sym{color:var(--accent-text);font-size:12px}
.tile .val{font-size:22px;font-weight:700;letter-spacing:-.4px;line-height:26px;display:flex;align-items:baseline;gap:6px}
.tile .val small{font-size:12px;font-weight:500;color:var(--text-2);letter-spacing:0}
.tile .foot{margin-top:auto;font-size:11px;color:var(--text-2);display:flex;align-items:center;gap:6px}

/* effects */
.fxgrid{display:grid;gap:8px}
.fx{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:6px;height:64px;border-radius:10px;background:var(--bg-inset);border:1px solid transparent;font-size:11px;color:var(--text)}
.fx .sym{font-size:19px;color:var(--text-2)}
.fx.on{background:var(--accent-subtle);border-color:var(--accent);color:var(--accent-text);font-weight:600}
.fx.on .sym{color:var(--accent-text)}
.fx.sm{height:50px;gap:4px;font-size:10px}.fx.sm .sym{font-size:15px}
.swatches{display:flex;align-items:center;gap:8px}
.sw{width:22px;height:22px;border-radius:50%;box-shadow:inset 0 0 0 .5px rgba(0,0,0,.18);flex:none;position:relative}
.sw.on{box-shadow:0 0 0 2px var(--bg-surface),0 0 0 4px var(--text)}
.sw.rand{background:linear-gradient(135deg,#ff3b30,#ffcc00 28%,#34c759 50%,#007aff 74%,#af52de)}
.vsep{width:1px;height:18px;background:var(--border)}
.dirty{display:inline-block;width:6px;height:6px;border-radius:50%;background:var(--warning)}

/* profile cards */
.profiles{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}
.pcard{border-radius:12px;background:var(--bg-surface);border:.5px solid var(--border);box-shadow:var(--shadow);padding:12px;display:flex;flex-direction:column;gap:8px}
.pcard.sel{box-shadow:0 0 0 2px var(--accent),var(--shadow);border-color:transparent}
.pcard .strip{height:6px;border-radius:3px}
.pcard .t{display:flex;align-items:center;gap:6px;font-size:13px;font-weight:600}
.pcard .t .badge{margin-left:auto}

/* save bar */
.savebar{position:absolute;left:24px;right:24px;bottom:18px;height:52px;border-radius:999px;background:var(--bg-surface);border:.5px solid var(--border);
  box-shadow:0 10px 30px rgba(0,0,0,.16),0 1px 3px rgba(0,0,0,.08);display:flex;align-items:center;gap:12px;padding:0 10px 0 20px;font-size:13px}
.savebar .sym{color:var(--warning);font-size:15px}
.savebar .gap{flex:1}

/* callouts */
.note{display:flex;gap:10px;align-items:flex-start;padding:12px 14px;border-radius:12px;font-size:12px;line-height:17px}
.note .sym{font-size:15px;margin-top:1px}
.note.warn{background:var(--warning-subtle);color:var(--text);box-shadow:inset 0 0 0 .5px var(--warning-line)}
.note.warn .sym{color:var(--warning)}
.note.info{background:var(--info-subtle)}.note.info .sym{color:var(--info)}
.note.accent{background:var(--accent-subtle);box-shadow:inset 0 0 0 .5px var(--accent-line)}.note.accent .sym{color:var(--accent-text)}
.note b{font-weight:600}

/* keyboard */
.kbd-well{border-radius:12px;display:flex;align-items:center;justify-content:center;overflow:hidden}
.kbd-well svg{display:block}

/* stepper */
.steps{display:flex;align-items:center;gap:8px}
.step{display:flex;align-items:center;gap:8px;font-size:12px;color:var(--text-2)}
.step i{font-style:normal;width:22px;height:22px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:11px;font-weight:700;background:var(--bg-control);color:var(--text-2)}
.step.done i{background:var(--success);color:#fff}
.step.cur{color:var(--text);font-weight:600}.step.cur i{background:var(--accent);color:#fff}
.step-line{flex:1;height:1.5px;background:var(--border);min-width:24px}
.step-line.done{background:var(--success)}
.progress{height:8px;border-radius:4px;background:var(--bg-control);overflow:hidden}
.progress b{display:block;height:100%;border-radius:4px;background:linear-gradient(90deg,#F2264E,#D3123F)}

/* menu bar panel */
.desk{width:440px;height:720px;border-radius:16px;overflow:hidden;position:relative;background:linear-gradient(160deg,#6E1B33 0%,#2B1F3A 45%,#13212E 100%)}
.desk.lightdesk{background:linear-gradient(160deg,#F6C9CF 0%,#E8DCEB 45%,#CFE0EC 100%)}
.menubar{height:26px;display:flex;align-items:center;justify-content:flex-end;gap:14px;padding:0 14px;font-size:13px;color:#fff;background:rgba(0,0,0,.18)}
.lightdesk .menubar{color:#000;background:rgba(255,255,255,.35)}
.menubar .item{display:flex;align-items:center;gap:4px;height:22px;padding:0 6px;border-radius:5px}
.menubar .item.on{background:rgba(255,255,255,.28)}
.lightdesk .menubar .item.on{background:rgba(0,0,0,.12)}
.menubar svg{width:16px;height:16px}
.panel{position:absolute;top:34px;right:14px;width:340px;border-radius:18px;background:var(--bg-window);color:var(--text);
  box-shadow:0 0 0 .5px rgba(0,0,0,.25),0 18px 50px rgba(0,0,0,.35);padding:14px;display:flex;flex-direction:column;gap:12px}
.panel .hdr{display:flex;align-items:center;gap:10px}
.panel .sec{display:flex;flex-direction:column;gap:8px}
.panel .lbl{font-size:11px;font-weight:600;color:var(--text-2);display:flex;align-items:center}
.panel .lbl .aux{margin-left:auto;font-weight:400}
.panel .hr{height:.5px;background:var(--border);margin:0 -14px}
.panel .foot{display:flex;align-items:center;gap:4px}
.iconbtn{width:30px;height:30px;border-radius:999px;display:flex;align-items:center;justify-content:center;color:var(--text-2);font-size:14px}
.ring{position:relative;width:38px;height:38px;flex:none}
.ring svg{position:absolute;inset:0}
.ring span{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:700}

/* settings window */
.settings{width:620px;border-radius:14px;overflow:hidden;background:var(--bg-window);color:var(--text);box-shadow:0 0 0 .5px rgba(0,0,0,.28),0 24px 70px rgba(0,0,0,.25)}
.settings .tb{height:84px;display:flex;flex-direction:column;align-items:center;border-bottom:.5px solid var(--border);background:var(--bg-sidebar)}
.settings .tb .traffic{align-self:flex-start;padding:10px 12px 0}
.settings .tb .title{font-size:13px;font-weight:600;margin-top:-14px}
.settings .tabs{display:flex;gap:4px;margin-top:8px}
.settings .tab{display:flex;flex-direction:column;align-items:center;gap:2px;width:84px;height:44px;border-radius:8px;justify-content:center;font-size:11px;color:var(--text-2)}
.settings .tab .sym{font-size:17px}
.settings .tab.on{background:var(--bg-control);color:var(--accent-text)}
.settings .sbody{padding:20px 28px 26px;display:flex;flex-direction:column;gap:14px}
.settings .group .r .k{width:auto;flex:1;color:var(--text)}
.sheet-overlay{position:absolute;inset:0;background:rgba(0,0,0,.18);display:flex;justify-content:center;align-items:flex-start;padding-top:84px}
.dialog{width:420px;border-radius:14px;background:var(--bg-window);box-shadow:0 0 0 .5px rgba(0,0,0,.3),0 20px 60px rgba(0,0,0,.35);padding:22px;display:flex;flex-direction:column;gap:12px}
.dialog .ic{width:44px;height:44px;border-radius:12px;background:var(--warning-subtle);display:flex;align-items:center;justify-content:center;font-size:22px;color:var(--warning)}
.dialog ul{padding-left:18px;font-size:12px;line-height:18px;color:var(--text-2)}
.dialog .acts{display:flex;justify-content:flex-end;gap:8px;margin-top:4px}

/* key test */
.legend{display:flex;gap:14px;font-size:11px;color:var(--text-2);align-items:center}
.legend i{display:inline-block;width:12px;height:12px;border-radius:3px;margin-right:5px;vertical-align:-2px}
.log{font-family:"SF Mono","JetBrains Mono",ui-monospace,monospace;font-size:11.5px}
.log .lr{display:flex;align-items:center;gap:10px;height:24px;padding:0 4px;border-radius:6px}
.log .lr:nth-child(odd){background:var(--bg-inset)}
.log .lr .sym{font-size:12px}
.statpill{display:flex;align-items:center;gap:20px;padding:10px 16px;border-radius:12px;background:var(--bg-surface);border:.5px solid var(--border);box-shadow:var(--shadow)}
.statpill .st{display:flex;flex-direction:column;gap:1px}
.statpill .st b{font-size:17px;font-weight:700;font-variant-numeric:tabular-nums}
.statpill .st span{font-size:11px;color:var(--text-2)}
.statpill .vs{width:.5px;align-self:stretch;background:var(--border)}
.live{display:flex;align-items:center;gap:6px;font-size:12px;font-weight:600;color:var(--success)}
.live i{width:8px;height:8px;border-radius:50%;background:var(--success);box-shadow:0 0 0 3px var(--success-subtle)}
"""

# ---------------------------------------------------------------------------------------------------------------
# Keyboard renderer

def hsl_hex(h, s=0.85, l=0.58):
    c = (1 - abs(2 * l - 1)) * s
    x = c * (1 - abs((h / 60) % 2 - 1))
    m = l - c / 2
    r, g, b = [(c, x, 0), (x, c, 0), (0, c, x), (0, x, c), (x, 0, c), (c, 0, x)][int(h // 60) % 6]
    return "#%02X%02X%02X" % tuple(round((v + m) * 255) for v in (r, g, b))


def keyboard_svg(width, mode="lit", theme="dark", states=None, fixed=None, legends=True):
    """mode: lit (RGB legends + underglow), plain, test (states dict id → pressed/tested/untested/nohid)."""
    pad = 12
    W, H = 582, 267
    vw, vh = W + pad * 2, H + pad * 2
    height = width * vh / vw
    case = {"dark": "#121110", "light": "#E4DFDB"}[theme]
    cap = {"dark": "#2E2B29", "light": "#FFFFFF"}[theme]
    cap_top = {"dark": "#3A3634", "light": "#FFFFFF"}[theme]
    side = {"dark": "#1E1C1B", "light": "#D6CFCA"}[theme]
    legend = {"dark": "#D9D3CF", "light": "#5A5552"}[theme]
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0f}" height="{height:.0f}" viewBox="{-pad} {-pad} {vw} {vh}">',
             '<defs><filter id="glow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="5"/></filter></defs>',
             f'<rect x="{-pad}" y="{-pad}" width="{vw}" height="{vh}" rx="14" fill="{case}"/>']

    def color_for(k):
        if fixed:
            return fixed
        cx = k["x"] + k["w"] / 2
        cy = k["y"] + k["h"] / 2
        return hsl_hex((cx / W * 300 + cy / H * 40) % 360)

    if mode == "lit":
        parts.append('<g filter="url(#glow)" opacity="0.75">')
        for k in LAYOUT:
            if k["id"] in (122, 123, 124):
                continue
            parts.append(f'<rect x="{k["x"]}" y="{k["y"]}" width="{k["w"] - 3}" height="{k["h"] - 3}" rx="5" fill="{color_for(k)}"/>')
        parts.append('</g>')
    # knob
    parts.append(f'<circle cx="539" cy="16" r="17" fill="{side}"/><circle cx="539" cy="15" r="14" fill="{cap_top}"/>')
    for i in range(18):
        a = i / 18 * math.tau
        parts.append(f'<line x1="{539 + 10 * math.cos(a):.1f}" y1="{15 + 10 * math.sin(a):.1f}" x2="{539 + 13 * math.cos(a):.1f}" y2="{15 + 13 * math.sin(a):.1f}" stroke="{side}" stroke-width="1"/>')
    for k in LAYOUT:
        if k["id"] in (122, 123, 124):
            continue
        x, y, w, h = k["x"], k["y"], k["w"] - 3, k["h"] - 3
        state = (states or {}).get(k["id"], "untested" if mode == "test" else None)
        if mode == "test" and not k["u"]:
            state = "nohid"
        base, top, lg, stroke = side, cap_top, legend, None
        if mode == "lit":
            lg = color_for(k)
        if state == "tested":
            base, top, lg = ("#B9E7C8", "#DDF6E5", "#166534") if theme == "light" else ("#1E4A2E", "#245A37", "#BBF7D0")
        elif state == "pressed":
            base, top, lg = "#9E0E30", "#D3123F", "#FFFFFF"
        elif state == "nohid":
            base, top, lg, stroke = case, case, "#A09A96", "#A09A96"
        if stroke:
            parts.append(f'<rect x="{x + .5}" y="{y + .5}" width="{w - 1}" height="{h - 1}" rx="5" fill="none" stroke="{stroke}" stroke-dasharray="3 2" stroke-width="1"/>')
        else:
            parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="5" fill="{base}"/>')
            parts.append(f'<rect x="{x + 2.5}" y="{y + 1.5}" width="{w - 5}" height="{h - 6.5}" rx="4" fill="{top}"/>')
        if legends and k["l"].strip():
            label = k["l"]
            fs = 7 if len(label) <= 3 else 6
            if label in ("⌫", "⏎", "⇪", "⇧", "⇥") or len(label) == 1:
                fs = 8
            parts.append(f'<text x="{x + w / 2}" y="{y + h / 2 + 1}" font-size="{fs}" text-anchor="middle" dominant-baseline="middle" font-family="SF Pro, -apple-system, sans-serif" font-weight="500" fill="{lg}">{e(label)}</text>')
    parts.append("</svg>")
    return "".join(parts)


KEYCAP_GLYPH = ('<svg viewBox="0 0 18 18"><defs><mask id="mk{n}" maskUnits="userSpaceOnUse" x="0" y="0" width="18" height="18"><rect width="18" height="18" fill="#fff"/>'
                '<rect x="4.35" y="1.85" width="9.3" height="9.1" rx="2.15" fill="#000"/></mask></defs>'
                '<path mask="url(#mk{n})" d="M5.6 3.1H12.4Q13.55 3.1 13.75 4.25L15.15 13.7Q15.35 15.4 13.65 15.4H4.35Q2.65 15.4 2.85 13.7L4.25 4.25Q4.45 3.1 5.6 3.1Z" fill="{c}"/>'
                '<rect x="5.1" y="2.6" width="7.8" height="7.6" rx="1.6" fill="{c}"/></svg>')
_glyph_n = 0


def keycap(color="#fff"):
    global _glyph_n
    _glyph_n += 1
    return KEYCAP_GLYPH.replace("{n}", str(_glyph_n)).replace("{c}", color)


def ring(percent, color="#16A34A", size=38, label=True):
    r = size / 2 - 3
    c = 2 * math.pi * r
    return (f'<div class="ring" style="width:{size}px;height:{size}px"><svg width="{size}" height="{size}" viewBox="0 0 {size} {size}">'
            f'<circle cx="{size/2}" cy="{size/2}" r="{r}" fill="none" stroke="var(--bg-control)" stroke-width="4"/>'
            f'<circle cx="{size/2}" cy="{size/2}" r="{r}" fill="none" stroke="{color}" stroke-width="4" stroke-linecap="round" '
            f'stroke-dasharray="{c * percent / 100:.1f} {c:.1f}" transform="rotate(-90 {size/2} {size/2})"/></svg>'
            + (f'<span>{percent}</span>' if label else "") + '</div>')


def slider(frac, ticks=0):
    t = "".join(f'<i class="tick" style="left:{i / (ticks - 1) * 100:.2f}%"></i>' for i in range(ticks)) if ticks else ""
    return (f'<div class="slider"><i class="track"></i>{t}<i class="fill" style="width:{frac * 100:.1f}%"></i>'
            f'<i class="thumb" style="left:{frac * 100:.1f}%"></i></div>')


# ---------------------------------------------------------------------------------------------------------------
# Window chrome

NAV = [("overview", "概览", "gauge.with.dots.needle.67percent"), ("lighting", "灯光与配置档", "lightbulb.led"),
       ("keytest", "按键测试", "keyboard"), ("firmware", "固件升级", "arrow.down.circle")]


def sidebar(active, connected=True, experimental=True, empty=False):
    if empty:
        dev = (f'<div class="device"><div class="thumb" style="background:var(--bg-control)">{keycap("#A09A96")}</div>'
               f'<div><div class="name">未连接键盘</div><div class="meta"><span class="dot gray"></span>等待 USB 连接</div></div></div>')
    else:
        meta = '<span class="dot"></span>有线 USB · 86%' if connected else '<span class="dot amber"></span>已断开 · 显示上次信息'
        dev = (f'<div class="device"><div class="thumb">{keycap("#fff")}</div><div><div class="name">MX PIXIU 75</div>'
               f'<div class="meta">{meta}</div></div>{s("chevron.up.chevron.down", "chev")}</div>')
    items = []
    for key, title, sym in NAV:
        cls = "on" if key == active else ""
        dim = ' style="opacity:.4"' if empty else ""
        items.append(f'<a class="{cls}"{dim}>{s(sym)}{e(title)}</a>')
    if experimental:
        cls = "on" if active == "custom" else ""
        dim = ' style="opacity:.4"' if empty else ""
        items.append(f'<a class="{cls}"{dim}>{s("flask")}自定义固件<span class="badge amber">实验</span></a>')
    return (f'<aside class="sidebar"><div class="traffic"><i></i><i></i><i></i></div>{dev}'
            f'<div class="navlabel">设备</div><nav class="nav">{"".join(items)}</nav><div class="spacer"></div>'
            f'<nav class="nav foot"><a>{s("stethoscope")}诊断与日志</a><a>{s("gearshape")}设置</a></nav></aside>')


def window(theme, active, title, sub, tools, content, name, **kw):
    return (f'<div class="screen {theme}" data-name="{e(name)}"><div class="window">{sidebar(active, **kw)}<main>'
            f'<header class="toolbar"><div class="titles"><h1>{title}</h1><div class="sub">{e(sub)}</div></div>'
            f'<div class="tools">{tools}</div></header><div class="content">{content}</div></main></div></div>')


# ---------------------------------------------------------------------------------------------------------------
# Screens

def overview(theme):
    kb = keyboard_svg(430, "lit", "dark")
    tools = f'<div class="glass">{s("arrow.clockwise")}</div>'
    hero = (f'<div class="card" style="padding:0;overflow:hidden">'
            f'<div class="kbd-well" style="height:226px;border-radius:0;background:radial-gradient(120% 90% at 50% 0%,#3A2A30 0%,#161413 70%)">{kb}</div>'
            f'<div style="display:flex;align-items:center;gap:14px;padding:14px 18px">'
            f'<div><div class="title1">MX PIXIU 75</div><div class="caption" style="margin-top:2px">CHERRY · 75% 三模机械键盘 · 序列号 PX75-0117-A1</div></div>'
            f'<div style="margin-left:auto;display:flex;gap:6px"><span class="badge green"><span class="dot"></span>已连接</span><span class="badge gray">{s("cable.connector")} 有线 USB</span></div></div></div>')
    tiles = (
        f'<div class="tiles">'
        f'<div class="tile"><div class="lab">{s("battery.100percent.bolt")}电量</div><div style="display:flex;align-items:center;gap:12px">{ring(86, "#16A34A", 44)}'
        f'<div class="val">86<small>%</small></div></div><div class="foot"><span class="sym" style="color:var(--success)">&#x{SYM["bolt.fill"]};</span>正在充电</div></div>'
        f'<div class="tile"><div class="lab">{s("square.stack.3d.down.right")}配置档</div><div class="val">配置 2<small>/ 3</small></div>'
        f'<div class="seg fill"><span>1</span><span class="on">2</span><span>3</span></div></div>'
        f'<div class="tile"><div class="lab">{s("lightbulb.led")}灯效</div><div class="val">波纹</div>'
        f'<div class="foot"><span class="sw rand" style="width:12px;height:12px"></span>随机颜色 · 亮度 高 · 速度 3/5</div></div>'
        f'<div class="tile"><div class="lab">{s("moon.zzz")}休眠</div><div class="val">5<small>分钟</small></div>'
        f'<div class="foot">无操作 5 分钟熄灯 · 30 分钟深度休眠</div></div></div>')
    fw = (f'<div class="card" style="display:flex;align-items:center;gap:14px;padding:14px 16px">'
          f'<div style="width:36px;height:36px;border-radius:10px;background:var(--accent-subtle);display:flex;align-items:center;justify-content:center;font-size:17px;color:var(--accent-text)">{s("arrow.down.circle.fill")}</div>'
          f'<div><div class="body" style="font-weight:600">有新固件 0.1.1.8</div><div class="caption">当前 0.1.1.7 · 来自 CHERRY 官方升级目录，刷写前会校验 MD5 与 CRC</div></div>'
          f'<div style="margin-left:auto;display:flex;gap:8px"><span class="btn">更新说明</span><span class="btn primary">前往升级 {s("chevron.right")}</span></div></div>')
    details = (f'<div class="group">'
               f'<div class="r"><span class="k">型号</span><span class="v">MX PIXIU 75 · VID 0x046A / PID 0x01E2</span></div>'
               f'<div class="r"><span class="k">固件</span><span class="v">0.1.1.7 <span class="faint mono">· CRC 0xCFE1A03E · 原厂固件</span></span></div>'
               f'<div class="r"><span class="k">指示灯颜色</span><span class="v swatches"><span class="sw" style="background:#FF0000;width:14px;height:14px"></span><span class="sw" style="background:#00D70F;width:14px;height:14px"></span><span class="sw" style="background:#0099FF;width:14px;height:14px"></span></span></div>'
               f'<div class="r"><span class="v" style="color:var(--accent-text)">HID 接口与协议原始数据</span><span class="end">{s("chevron.right")}</span></div></div>')
    content = hero + tiles + fw + f'<div class="card-h" style="margin:4px 0 -8px"><h3>设备详情</h3></div>' + details
    return window(theme, "overview", "概览", "MX PIXIU 75 · 读取于 21:42:08", tools, content, f"Main / 概览 ({theme})")


def lighting(theme):
    tools = (f'<div class="glass">{s("square.and.arrow.down")} 导入预设</div><div class="glass">{s("arrow.clockwise")}</div>')
    strip_rand = "linear-gradient(90deg,#ff3b30,#ffcc00,#34c759,#00c7be,#007aff,#af52de)"
    profiles = (f'<div class="profiles">'
                f'<div class="pcard"><div class="t">配置 1</div><div class="strip" style="background:#3153FF"></div><div class="caption">常亮 · 固定 #3153FF · 亮度 中</div></div>'
                f'<div class="pcard sel"><div class="t">配置 2<span class="badge green">使用中</span></div><div class="strip" style="background:{strip_rand}"></div><div class="caption">波纹 · 随机颜色 · 正在编辑</div></div>'
                f'<div class="pcard"><div class="t">配置 3<span class="btn sm" style="margin-left:auto">设为使用中</span></div><div class="strip" style="background:#FF7200"></div><div class="caption">呼吸 · 固定 #FF7200 · 亮度 低</div></div></div>')
    fx = "".join(f'<div class="fx{" on" if raw == 0 else ""}">{s(sym)}{e(name)}</div>' for raw, name, sym in EFFECTS)
    effect = (f'<div class="card"><div class="card-h"><h3>灯效</h3><span class="aux">「自定义」使用键盘内保存的逐键颜色</span></div>'
              f'<div class="fxgrid" style="grid-template-columns:repeat(6,1fr)">{fx}</div></div>')
    sw = "".join(f'<span class="sw" style="background:#{c}"></span>' for c in PALETTE)
    adjust = (f'<div class="card"><div class="col" style="gap:14px">'
              f'<div style="display:flex;align-items:center;gap:14px"><span class="body muted" style="width:56px">亮度 <span class="dirty"></span></span>'
              f'<div class="seg"><span>灭</span><span>低</span><span>中</span><span class="on">高</span><span>全亮</span></div><span class="caption" style="margin-left:auto">原为「中」</span></div>'
              f'<div style="display:flex;align-items:center;gap:14px"><span class="body muted" style="width:56px">速度</span>{s("tortoise", "faint")}'
              f'<div style="width:300px;display:flex">{slider(0.5, 5)}</div>{s("hare", "faint")}<span class="body muted" style="margin-left:auto;font-variant-numeric:tabular-nums">3 / 5</span></div>'
              f'<div style="display:flex;align-items:center;gap:14px"><span class="body muted" style="width:56px">颜色 <span class="dirty"></span></span>'
              f'<div class="swatches"><span class="sw rand on"></span><span class="vsep"></span>{sw}<span class="vsep"></span>'
              f'<span class="sw" style="background:linear-gradient(135deg,red,yellow 25%,lime 45%,aqua 60%,blue 80%,magenta);box-shadow:inset 0 0 0 3px var(--bg-surface),inset 0 0 0 3.5px rgba(0,0,0,.2)"></span></div>'
              f'<span class="caption" style="margin-left:auto">随机颜色</span></div></div></div>')
    sleep = (f'<div class="card"><div class="card-h"><h3>休眠</h3><span class="aux">范围与官方驱动一致</span></div><div class="col" style="gap:12px">'
             f'<div style="display:flex;align-items:center;gap:14px"><span class="body muted" style="width:64px">熄灯</span><span class="switch"></span><span class="caption" style="width:44px">不休眠</span><div style="width:260px;display:flex">{slider(1.0)}</div><span class="body" style="margin-left:auto">300 秒</span></div>'
             f'<div style="display:flex;align-items:center;gap:14px"><span class="body muted" style="width:64px">深度休眠</span><span class="switch"></span><span class="caption" style="width:44px">不休眠</span><div style="width:260px;display:flex">{slider(0.05)}</div><span class="body" style="margin-left:auto">30 分钟</span></div></div></div>')
    presets = (f'<div class="card"><div class="card-h"><h3>本地预设</h3><span class="aux">可载入任意配置档，或导出给其他 Mac</span></div>'
               f'<div style="display:flex;gap:8px;margin-bottom:10px"><div class="field" style="width:240px">预设名称（可留空）</div><span class="btn">将编辑区保存为预设</span></div>'
               f'<div class="group" style="box-shadow:none"><div class="r"><div class="v"><div style="font-weight:500">夜间 · 暖橙呼吸</div><div class="sub">呼吸 · #FF7200 · 亮度 低 · 速度 2/5</div></div><span class="btn sm">载入</span>{s("ellipsis.circle", "faint")}</div></div></div>')
    content = (profiles + effect + adjust + sleep + presets +
               f'<div class="savebar">{s("pencil.circle.fill")}<span><b>2 项修改</b>尚未写入键盘</span><span class="caption">配置 2 · 亮度、颜色</span><span class="gap"></span>'
               f'<span class="btn">放弃</span><span class="btn primary">写入键盘 <span class="kbdhint">⌘S</span></span></div>')
    return window(theme, "lighting", "灯光与配置档", "编辑配置 2 · 修改会在点「写入键盘」后生效", tools, content, f"Main / 灯光与配置档 ({theme})")


def keytest(theme):
    pressed = {37, 38}  # placeholders, mapped below by label
    states = {}
    tested_labels = set("` 1 2 3 4 5 6 7 8 9 0 Q W E R T Y U I O P A S D F G H J K L Z X C V B N M Esc F1 F2 F3 F4 Tab Caps".split())
    for k in LAYOUT:
        if k["l"] in tested_labels or k["l"] in ("⇧", "Ctrl", "⌥", "⌘", "Space", ""):
            states[k["id"]] = "tested"
        if k["l"] in ("W", "D"):
            states[k["id"]] = "pressed"
    kb = keyboard_svg(800, "test", "light" if theme == "light" else "dark", states)
    tools = (f'<div class="glass"><span class="switch on" style="transform:scale(.8)"></span>屏蔽本应用快捷键</div>'
             f'<div class="glass">{s("arrow.counterclockwise")} 重置</div>')
    stats = (f'<div class="statpill"><div class="live"><i></i>正在监听</div><span class="vs"></span>'
             f'<div class="st"><b>52 / 83</b><span>已测按键</span></div><div class="st"><b>2</b><span>当前按下</span></div>'
             f'<div class="st"><b>6</b><span>最多同时按下</span></div><div class="st"><b>214</b><span>事件数</span></div>'
             f'<div class="legend" style="margin-left:auto"><span><i style="background:var(--bg-surface);box-shadow:inset 0 0 0 1px var(--border-strong)"></i>未测</span>'
             f'<span><i style="background:#B9E7C8"></i>已测</span><span><i style="background:#D3123F"></i>按下</span>'
             f'<span><i style="border:1px dashed #A09A96"></i>不可测</span></div></div>')
    canvas = f'<div class="card" style="padding:18px;display:flex;justify-content:center">{kb}</div>'
    rows = [("arrow.down.circle.fill", "D", "0x07:0x07", "+0.0 ms", True), ("arrow.down.circle.fill", "W", "0x07:0x1A", "+38.2 ms", True),
            ("arrow.up.circle", "A", "0x07:0x04", "+12.6 ms", False), ("arrow.down.circle.fill", "A", "0x07:0x04", "+96.4 ms", True),
            ("arrow.up.circle", "S", "0x07:0x16", "+141.0 ms", False)]
    log = "".join(f'<div class="lr"><span class="sym" style="color:{"var(--accent-text)" if d else "var(--text-3)"}">&#x{SYM[i]};</span>'
                  f'<span style="width:40px;font-weight:600;font-family:SF Pro">{k}</span><span class="faint">{u}</span><span style="margin-left:auto" class="faint">{t}</span></div>'
                  for i, k, u, t, d in rows)
    lower = (f'<div class="row"><div class="card grow"><div class="card-h"><h3>最近事件</h3><span class="aux">最新在上</span></div><div class="log">{log}</div></div>'
             f'<div class="card" style="width:260px"><div class="card-h"><h3>小提示</h3></div><div class="callout muted" style="display:flex;flex-direction:column;gap:8px">'
             f'<span>• 旋钮的左转、按下、右转分别显示在右上角。</span><span>• Fn 由键盘内部处理，不产生 HID 事件，显示为虚线。</span><span>• 系统级快捷键（如 ⌘Space）无法屏蔽。</span></div></div></div>')
    return window(theme, "keytest", "按键测试", "按下键盘上的任意键，测过的键会变绿", tools, stats + canvas + lower, f"Main / 按键测试 ({theme})")


def firmware(theme):
    tools = f'<div class="glass">{s("folder")} 选择本地升级包…</div>'
    hero = (f'<div class="card" style="display:flex;align-items:center;gap:22px;padding:20px 22px">'
            f'<div><div class="caption">当前固件</div><div class="title1" style="font-variant-numeric:tabular-nums">0.1.1.7</div></div>'
            f'<span class="sym" style="font-size:20px;color:var(--text-3)">&#x{SYM["arrow.right"]};</span>'
            f'<div><div class="caption">CHERRY 官方最新</div><div class="title1" style="color:var(--accent-text)">0.1.1.8</div></div>'
            f'<div class="caption" style="max-width:250px;margin-left:12px">MX_PIXIU75_WIRELESS_0118 · 从官方 Windows 升级包中提取，在 Mac 上直接刷写</div>'
            f'<span class="badge" style="margin-left:auto">有可用更新</span></div>')
    steps = (f'<div class="card" style="padding:14px 18px"><div class="steps">'
             f'<div class="step done"><i>&#x{SYM["checkmark"]};</i>获取升级包</div><div class="step-line done"></div>'
             f'<div class="step done"><i>&#x{SYM["checkmark"]};</i>校验 MD5 / CRC</div><div class="step-line done"></div>'
             f'<div class="step cur"><i>3</i>刷写固件</div><div class="step-line"></div>'
             f'<div class="step"><i>4</i>重启并读回验证</div></div></div>')
    pkg = (f'<div class="group">'
           f'<div class="r"><span class="k">升级包</span><span class="v">MX_PIXIU75_WIRELESS_0118.exe</span><span class="end"><span class="badge green">{s("checkmark.seal.fill")} MD5 一致</span></span></div>'
           f'<div class="r"><span class="k">目标设备</span><span class="v">VID 0x046A · PID 0x01E2 · OTA 0xFFEF</span></div>'
           f'<div class="r"><span class="k">固件镜像</span><span class="v mono">131,072 字节 · CRC32 0x5B0D72E4</span><span class="end"><span class="badge green">{s("checkmark")} 校验通过</span></span></div>'
           f'<div class="r"><span class="k">键盘当前 CRC</span><span class="v mono">0xCFE1A03E</span><span class="end caption">与升级包不同，可以升级</span></div></div>')
    flash = (f'<div class="card"><div class="card-h"><h3>正在刷写</h3><span class="aux mono">1,231 / 1,920 个报文</span></div>'
             f'<div style="display:flex;align-items:baseline;gap:10px;margin-bottom:10px"><span style="font-size:34px;font-weight:700;letter-spacing:-1px;font-variant-numeric:tabular-nums">64%</span><span class="caption">预计还需约 11 秒</span></div>'
             f'<div class="progress"><b style="width:64%"></b></div>'
             f'<div class="note warn" style="margin-top:14px">{s("exclamationmark.triangle.fill")}<div><b>请不要拔线或让 Mac 睡眠。</b>键盘需保持有线模式直连 USB；完成后键盘会自动重启，本应用会读回 CRC 确认写入正确。</div></div>'
             f'<div style="display:flex;justify-content:flex-end;gap:8px;margin-top:14px"><span class="btn" disabled>取消</span><span class="btn primary" disabled>{s("bolt.fill")} 正在升级…</span></div></div>')
    return window(theme, "firmware", "固件升级", "MX PIXIU 75 · 有线 USB", tools, hero + steps + pkg + flash, f"Main / 固件升级 ({theme})")


def custom(theme):
    tools = f'<div class="glass">{s("arrow.clockwise")} 重新识别</div>'
    banner = (f'<div class="note warn">{s("exclamationmark.triangle.fill")}<div><b>实验性功能。</b>写入修改过的固件可能让按键行为与预期不同。'
              f'每次写入后都会读回 CRC 验证，随时可以「恢复原厂固件」。</div></div>')
    status = (f'<div class="card" style="display:flex;align-items:center;gap:14px;padding:14px 16px">'
              f'<div style="width:36px;height:36px;border-radius:10px;background:var(--success-subtle);color:var(--success);display:flex;align-items:center;justify-content:center;font-size:17px">{s("checkmark.seal.fill")}</div>'
              f'<div><div class="body" style="font-weight:600">键盘正在运行方案「办公 · F 区固定」</div><div class="caption mono">CRC 0x46F8C57A · 基于原厂 0117 · 10 月 11 日写入</div></div>'
              f'<span class="btn" style="margin-left:auto">{s("arrow.uturn.backward")} 恢复原厂固件</span></div>')
    plans = (f'<div class="card" style="width:220px;padding:10px;display:flex;flex-direction:column;gap:2px">'
             f'<div class="card-h" style="padding:4px 6px 2px;margin-bottom:6px"><h3>方案</h3><span class="aux">{s("plus")}</span></div>'
             f'<div class="nav"><a class="on">{s("checkmark.circle.fill")}办公 · F 区固定</a><a>{s("wand.and.stars")}游戏 · 去掉 Ctrl+Fn</a><a style="color:var(--text-2)">{s("plus")}新建方案…</a></div>'
             f'<div class="spacer" style="flex:1"></div><div class="caption" style="padding:8px 6px 4px">原厂镜像：已从官方目录获取 · CRC 0xCFE1A03E ✓</div></div>')
    opts = (f'<div class="card grow" style="padding:0;overflow:hidden">'
            f'<div style="padding:14px 16px 10px"><div class="card-h" style="margin:0"><h3>F 区行为</h3><span class="aux">原厂的 Ctrl+Fn、Fn+Enter 会掉电保存，F 区时而需要按 Fn</span></div></div>'
            f'<div class="group" style="border-radius:0;border-left:0;border-right:0;box-shadow:none">'
            f'<div class="r"><div class="v"><div>F 区固定：单按功能，Fn+F 输出 F1–F12</div><div class="sub">Win 和 Mac 模式都固定，不再受 Fn Lock 影响 · 已在真机验证</div></div><span class="switch on"></span></div>'
            f'<div class="r"><div class="v"><div>去掉 Ctrl+Fn 切换 Fn Lock</div><div class="sub">Fn 紧挨右 Ctrl，避免按组合键时误触</div></div><span class="switch on"></span></div></div>'
            f'<div style="padding:14px 16px 10px"><div class="card-h" style="margin:0"><h3>Mac 模式 F1–F12 功能</h3><span class="aux">单按触发</span></div></div>'
            f'<div class="group" style="border-radius:0;border-left:0;border-right:0;border-bottom:0;box-shadow:none">'
            f'<div class="r"><span class="k mono" style="width:40px">F1</span><span class="v">降低屏幕亮度</span><span class="end">原厂 {s("chevron.up.chevron.down")}</span></div>'
            f'<div class="r"><span class="k mono" style="width:40px">F7</span><span class="v">灯效速度 −</span><span class="end"><span class="dirty"></span> 已修改 {s("chevron.up.chevron.down")}</span></div>'
            f'<div class="r"><span class="k mono" style="width:40px">F9</span><span class="v">打开 CHERRY 官网</span><span class="end">原厂 {s("chevron.up.chevron.down")}</span></div></div></div>')
    actions = (f'<div style="display:flex;align-items:center;gap:10px"><span class="caption">方案已保存 · 生成镜像 CRC 0x46F8C57A（与键盘一致）</span>'
               f'<span class="btn" style="margin-left:auto">复制方案</span><span class="btn primary" disabled>{s("bolt.fill")} 写入所选方案</span></div>')
    content = banner + status + f'<div class="row" style="flex:1;min-height:0">{plans}{opts}</div>' + actions
    title = f'自定义固件 <span class="badge amber">实验</span>'
    return window(theme, "custom", title, "MX PIXIU 75 · 固件 0117 · 需有线连接", tools, content, f"Main / 自定义固件 ({theme})")


def onboarding(theme):
    steps = [("cable.connector", "用 USB 线连接键盘", "固件读取、灯效写入和升级都走有线接口。"),
             ("antenna.radiowaves.left.and.right", "无线模式也能显示", "2.4G / 蓝牙下只读取 USB 接收器的基础信息。"),
             ("hand.raised.fill", "按键测试需要授权", "首次使用时按提示打开「输入监控」权限。")]
    cards = "".join(f'<div class="card" style="flex:1;display:flex;flex-direction:column;gap:8px;padding:18px">'
                    f'<div style="width:34px;height:34px;border-radius:10px;background:var(--accent-subtle);color:var(--accent-text);display:flex;align-items:center;justify-content:center;font-size:16px">{s(sym)}</div>'
                    f'<div class="body" style="font-weight:600">{i + 1}. {e(t)}</div><div class="caption">{e(d)}</div></div>' for i, (sym, t, d) in enumerate(steps))
    content = (f'<div style="flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:18px;padding:0 30px 30px">'
               f'<img src="{ICON_URI}" width="112" height="112" style="filter:drop-shadow(0 10px 18px rgba(138,13,46,.25))">'
               f'<div style="text-align:center"><div class="title1">连接你的 CHERRY 键盘</div>'
               f'<div class="body muted" style="margin-top:6px">插上后会自动识别，并在菜单栏显示电量。关闭窗口后仍在菜单栏运行。</div></div>'
               f'<div class="row" style="width:100%;max-width:720px;margin-top:8px">{cards}</div>'
               f'<div class="caption" style="margin-top:4px">已适配 MX PIXIU 75 · 其他 CHERRY 设备显示 USB 信息 · <span style="color:var(--accent-text)">支持的型号</span></div></div>')
    return window(theme, "overview", "CHERRY Utility", "未检测到设备", "", content, f"Main / 未连接 ({theme})", empty=True)


def menubar_panel(theme, empty=False):
    desk_cls = "desk" + (" lightdesk" if theme == "light" else "")
    glyph = keycap("#000" if theme == "light" else "#fff")
    bar = (f'<div class="menubar"><span class="item">{s("magnifyingglass")}</span><span class="item on">{glyph}'
           f'<span style="font-variant-numeric:tabular-nums">{"" if empty else "86%"}</span></span><span>周一 21:42</span></div>')
    if empty:
        body = (f'<div style="display:flex;flex-direction:column;align-items:center;gap:8px;padding:26px 10px 18px;text-align:center">'
                f'<div style="font-size:34px;color:var(--text-3)">{s("keyboard.badge.ellipsis")}</div><div class="body" style="font-weight:600">未检测到 CHERRY 键盘</div>'
                f'<div class="caption">用 USB 线连接键盘后会自动出现</div></div>')
    else:
        fx = "".join(f'<div class="fx sm{" on" if raw == 0 else ""}">{s(sym)}{e(name)}</div>' for raw, name, sym in EFFECTS[:8])
        sw = "".join(f'<span class="sw" style="background:#{c};width:20px;height:20px"></span>' for c in PALETTE[:9])
        body = (f'<div class="hdr"><div class="device" style="margin:0;padding:0;border:0;box-shadow:none;background:none;flex:1">'
                f'<div class="thumb">{keycap("#fff")}</div><div><div class="name">MX PIXIU 75</div><div class="meta"><span class="dot"></span>有线 USB · 固件 0.1.1.7</div></div></div>'
                f'{ring(86, "#16A34A", 40)}</div>'
                f'<div class="sec"><div class="lbl">配置档</div><div class="seg fill"><span>配置 1</span><span class="on">配置 2</span><span>配置 3</span></div></div>'
                f'<div class="sec"><div class="lbl">灯效<span class="aux">更多灯效在主窗口</span></div><div class="fxgrid" style="grid-template-columns:repeat(4,1fr);gap:6px">{fx}</div></div>'
                f'<div class="sec"><div class="lbl">亮度</div><div class="seg fill"><span>{s("sun.min")}</span><span>低</span><span>中</span><span class="on">高</span><span>{s("sun.max")}</span></div></div>'
                f'<div class="sec"><div class="lbl">速度</div><div style="display:flex;align-items:center;gap:10px">{s("tortoise", "faint")}{slider(0.5, 5)}{s("hare", "faint")}</div></div>'
                f'<div class="sec"><div class="lbl">颜色</div><div class="swatches" style="gap:7px"><span class="sw rand on" style="width:20px;height:20px"></span><span class="vsep"></span>{sw}</div></div>'
                f'<div class="group" style="box-shadow:none"><div class="r" style="min-height:34px">{s("square.stack.3d.down.right", "faint")}<span class="v">载入预设到当前配置档</span><span class="end">{s("chevron.right")}</span></div></div>')
    foot = (f'<div class="hr"></div><div class="foot"><span class="btn plain" style="padding:0 6px">{s("macwindow")} 打开 CHERRY Utility</span>'
            f'<span style="margin-left:auto" class="iconbtn">{s("arrow.clockwise")}</span><span class="iconbtn">{s("stethoscope")}</span>'
            f'<span class="iconbtn">{s("gearshape")}</span><span class="iconbtn">{s("power")}</span></div>')
    name = f"Menu Bar / {'未连接' if empty else '面板'} ({theme})"
    return f'<div class="screen {theme}" data-name="{e(name)}"><div class="{desk_cls}">{bar}<div class="panel">{body}{foot}</div></div></div>'


def settings(theme, tab):
    tabs = [("general", "通用", "gearshape"), ("updates", "更新", "arrow.down.circle"), ("labs", "实验性功能", "flask")]
    tb = "".join(f'<div class="tab{" on" if k == tab else ""}">{s(sym)}{e(t)}</div>' for k, t, sym in tabs)
    if tab == "general":
        body = (f'<div class="group"><div class="r"><span class="k">登录时打开</span><span class="switch on"></span></div>'
                f'<div class="r"><div class="k"><div>启动时显示主窗口</div><div class="sub">关闭后只在菜单栏运行</div></div><span class="switch"></span></div>'
                f'<div class="r"><span class="k">菜单栏显示电量百分比</span><span class="switch on"></span></div></div>'
                f'<div class="group"><div class="r"><div class="k"><div>诊断记录</div><div class="sub">只保存在本机，不会自动上传</div></div><span class="end">标准 {s("chevron.up.chevron.down")}</span></div></div>')
        title = "通用"
    elif tab == "updates":
        body = (f'<div class="card" style="display:flex;align-items:center;gap:14px;padding:16px">'
                f'<img src="{ICON_URI}" width="52" height="52"><div><div class="body" style="font-weight:600">CHERRY Utility 1.0.0 <span class="faint">(1)</span></div>'
                f'<div class="caption">已是最新版本 · 上次检查：今天 21:40</div></div><span class="btn" style="margin-left:auto">立即检查</span></div>'
                f'<div class="group"><div class="r"><div class="k"><div>自动检查更新</div><div class="sub">每天在后台检查一次</div></div><span class="switch on"></span></div>'
                f'<div class="r"><div class="k"><div>自动下载并安装</div><div class="sub">下次退出时安装；更新包经过签名校验</div></div><span class="switch"></span></div></div>'
                f'<div class="caption" style="display:flex;gap:6px;align-items:center">{s("lock.shield")}更新来自 odeployer.online/cherry-utility，使用 EdDSA 签名并经 Apple 公证。<span style="color:var(--accent-text)">更新日志</span></div>')
        title = "更新"
    else:
        body = (f'<div class="note warn">{s("exclamationmark.triangle.fill")}<div>实验性功能尚未经过广泛验证，可能让键盘行为与预期不同。仅在你清楚自己在做什么时开启。</div></div>'
                f'<div class="group"><div class="r"><div class="k"><div>自定义固件</div><div class="sub">在已知原厂固件上选择要修改的功能，生成补丁镜像并写入键盘。随时可恢复原厂固件。</div></div><span class="switch"></span></div></div>')
        title = "实验性功能"
    inner = (f'<div class="settings"><div class="tb"><div class="traffic"><i></i><i></i><i></i></div><div class="title">{title}</div>'
             f'<div class="tabs">{tb}</div></div><div class="sbody">{body}</div></div>')
    if tab == "labs":
        inner = inner.replace('<div class="settings">', '<div class="settings" style="height:470px">', 1)
        dialog = (f'<div class="sheet-overlay"><div class="dialog"><div class="ic">{s("exclamationmark.shield")}</div>'
                  f'<div class="title2">开启自定义固件？</div>'
                  f'<ul><li>写入修改过的固件可能导致部分按键、灯光或 Fn 组合键行为异常。</li><li>写入过程中断开连接可能需要重新刷写原厂固件。</li>'
                  f'<li>本工具是非官方软件，与 CHERRY 无关，由此造成的问题需自行承担。</li></ul>'
                  f'<div style="display:flex;gap:8px;align-items:flex-start;font-size:12px;line-height:17px"><span class="check">&#x{SYM["checkmark"]};</span><span>我已了解风险，并知道如何「恢复原厂固件」。</span></div>'
                  f'<div class="acts"><span class="btn">取消</span><span class="btn primary">开启</span></div></div></div>')
        inner = f'<div style="position:relative">{inner}{dialog}</div>'
    return f'<div class="screen {theme}" data-name="Settings / {title} ({theme})">{inner}</div>'


SEMANTIC = [  # name, light, dark, usage
    ("bg/window", "#FBFAF9", "#1B1A19", "窗口背景"), ("bg/sidebar", "#F2F0EE", "#232120", "侧栏 / 设置标签栏"),
    ("bg/surface", "#FFFFFF", "#262423", "卡片、分组列表"), ("bg/inset", "#F5F3F2", "#1F1D1C", "灯效磁贴、日志斑马纹"),
    ("bg/control", "#ECE9E7", "#34312F", "分段控件、按钮底"), ("border/default", "#E3DFDC", "#3A3634", "0.5 pt 描边"),
    ("text/primary", "#1B1A19", "#FBFAF9", "正文"), ("text/secondary", "#5A5552", "#A9A39F", "说明、标签"),
    ("text/tertiary", "#A09A96", "#7B7571", "占位、次要元数据"), ("accent/fill", "#D3123F", "#D3123F", "主按钮、选中、开关"),
    ("accent/text", "#D3123F", "#FF5A76", "链接、图标、选中文字"), ("accent/subtle", "#FFF0F2", "#3A0F1B", "选中磁贴底、强调卡片"),
    ("status/success", "#16A34A", "#4ADE80", "已连接、校验通过、已测按键"), ("status/warning", "#C2410C", "#FBBF24", "未写入修改、实验性功能"),
    ("status/danger", "#DC2626", "#F87171", "失败、破坏性操作"), ("status/info", "#2563EB", "#60A5FA", "提示信息"),
]


def foundations():
    rows = "".join(
        f'<div style="display:grid;grid-template-columns:200px 120px 120px 1fr;align-items:center;gap:16px;padding:10px 0;border-top:.5px solid var(--border)">'
        f'<span class="mono">{n}</span>'
        f'<span style="display:flex;align-items:center;gap:8px"><i style="width:28px;height:28px;border-radius:8px;background:{l};box-shadow:inset 0 0 0 .5px rgba(0,0,0,.15)"></i><span class="caption mono">{l}</span></span>'
        f'<span style="display:flex;align-items:center;gap:8px"><i style="width:28px;height:28px;border-radius:8px;background:{d};box-shadow:inset 0 0 0 .5px rgba(0,0,0,.15)"></i><span class="caption mono">{d}</span></span>'
        f'<span class="callout muted">{u}</span></div>' for n, l, d, u in SEMANTIC)
    colors = (f'<div class="card" style="width:820px"><div class="card-h"><h3>颜色 · 语义变量（Figma 变量集合 Color：Light / Dark）</h3></div>'
              f'<div style="display:grid;grid-template-columns:200px 120px 120px 1fr;gap:16px;padding-bottom:6px" class="caption"><span>变量</span><span>浅色</span><span>深色</span><span>用途</span></div>{rows}</div>')
    ramp = [("Display", "28 / 34 · Bold", 28, 700), ("Title 1", "22 / 28 · Bold", 22, 700), ("Title 2", "17 / 22 · Semibold", 17, 600),
            ("Title 3", "15 / 20 · Semibold", 15, 600), ("Headline", "13 / 16 · Semibold", 13, 600), ("Body", "13 / 18 · Regular", 13, 400),
            ("Callout", "12 / 16 · Regular", 12, 400), ("Caption", "11 / 14 · Regular", 11, 400)]
    type_rows = "".join(f'<div style="display:flex;align-items:baseline;gap:20px;padding:10px 0;border-top:.5px solid var(--border)">'
                        f'<span class="caption" style="width:150px">{n}<br>{m}</span><span style="font-size:{s}px;font-weight:{w}">灯光与配置档 Lighting 0.1.1.8</span></div>' for n, m, s, w in ramp)
    typo = f'<div class="card" style="width:700px"><div class="card-h"><h3>字体 · SF Pro（中文 PingFang SC）· macOS 字号体系</h3></div>{type_rows}</div>'
    comp = (f'<div class="card" style="width:1540px"><div class="card-h"><h3>组件与状态</h3><span class="aux">圆角：控件 6 · 磁贴 10 · 卡片 14 · 面板 20 · 胶囊 999；间距 4 的倍数</span></div>'
            f'<div style="display:flex;flex-wrap:wrap;gap:28px 40px;align-items:flex-start">'
            f'<div class="col" style="gap:10px"><span class="caption">按钮</span><div style="display:flex;gap:8px"><span class="btn primary">写入键盘 <span class="kbdhint">⌘S</span></span><span class="btn">放弃</span><span class="btn plain">更新日志</span><span class="btn primary" disabled>正在升级…</span></div></div>'
            f'<div class="col" style="gap:10px"><span class="caption">分段控件</span><div class="seg"><span>灭</span><span>低</span><span>中</span><span class="on">高</span><span>全亮</span></div></div>'
            f'<div class="col" style="gap:10px"><span class="caption">开关</span><div style="display:flex;gap:10px"><span class="switch on"></span><span class="switch"></span></div></div>'
            f'<div class="col" style="gap:10px;width:220px"><span class="caption">滑块（5 档吸附）</span><div style="display:flex">{slider(0.5, 5)}</div></div>'
            f'<div class="col" style="gap:10px"><span class="caption">徽标</span><div style="display:flex;gap:6px"><span class="badge green">使用中</span><span class="badge">有可用更新</span><span class="badge amber">实验</span><span class="badge gray">只读</span><span class="badge info">提示</span></div></div>'
            f'<div class="col" style="gap:10px;width:300px"><span class="caption">灯效磁贴：默认 / 选中</span><div class="fxgrid" style="grid-template-columns:repeat(3,1fr)"><div class="fx on">{s("water.waves")}波纹</div><div class="fx">{s("rainbow")}光谱</div><div class="fx">{s("wind")}呼吸</div></div></div>'
            f'<div class="col" style="gap:10px"><span class="caption">颜色选择：随机 / 收藏色 / 选中</span><div class="swatches"><span class="sw rand"></span><span class="vsep"></span><span class="sw on" style="background:#0099FF"></span><span class="sw" style="background:#FF7200"></span><span class="sw" style="background:#00D70F"></span></div></div>'
            f'<div class="col" style="gap:10px;width:420px"><span class="caption">提示条</span><div class="note warn">{s("exclamationmark.triangle.fill")}<div><b>实验性功能。</b>写入前请确认风险。</div></div><div class="note info">{s("info.circle")}<div>「自定义」使用键盘内保存的逐键颜色。</div></div></div>'
            f'<div class="col" style="gap:10px;width:520px"><span class="caption">步骤条</span><div class="steps"><div class="step done"><i>&#x{SYM["checkmark"]};</i>获取</div><div class="step-line done"></div><div class="step cur"><i>2</i>刷写</div><div class="step-line"></div><div class="step"><i>3</i>验证</div></div></div>'
            f'<div class="col" style="gap:10px;width:360px"><span class="caption">分组列表行</span><div class="group"><div class="r"><span class="k">固件</span><span class="v">0.1.1.7</span><span class="end">{s("chevron.right")}</span></div><div class="r"><div class="v"><div>自动检查更新</div><div class="sub">每天在后台检查一次</div></div><span class="switch on"></span></div></div></div>'
            f'<div class="col" style="gap:10px;width:560px;position:relative;height:90px"><span class="caption">未写入修改提示条（浮在内容底部）</span><div class="savebar" style="left:0;right:0;bottom:0">{s("pencil.circle.fill")}<span><b>2 项修改</b>尚未写入键盘</span><span class="gap"></span><span class="btn">放弃</span><span class="btn primary">写入键盘</span></div></div>'
            f'</div></div>')
    return (f'<div class="screen light" data-name="Foundations"><div style="width:1620px;padding:40px;background:var(--bg-window);border-radius:20px;display:flex;flex-wrap:wrap;gap:20px;align-items:flex-start">'
            f'<div style="width:100%"><div class="title1">CHERRY Utility · 设计基础</div><div class="body muted" style="margin-top:4px">原生 macOS 控件为主，深樱桃红作强调色；所有颜色均为 Figma 变量（Primitives → Color 语义层，Light / Dark 两种模式）。</div></div>'
            f'{colors}{typo}{comp}</div></div>')


def page(title, screens):
    return (f'<!doctype html><html lang="zh-Hans"><head><meta charset="utf-8"><title>{e(title)}</title><style>{CSS}</style></head>'
            f'<body><div class="sheet">{"".join(screens)}</div></body></html>')


def main():
    global ICON_URI
    icon_png = ROOT.parent / "icons" / "AppIcon-256.png"
    ICON_URI = png_data_uri(icon_png)
    OUT.mkdir(exist_ok=True)
    docs = {
        "main-light.html": [overview("light"), lighting("light"), keytest("light"), firmware("light"), custom("light"), onboarding("light")],
        "main-dark.html": [overview("dark"), lighting("dark"), keytest("dark")],
        "foundations.html": [foundations()],
        "menubar-settings.html": [menubar_panel("light"), menubar_panel("dark"), menubar_panel("light", empty=True),
                                  settings("light", "general"), settings("light", "updates"), settings("light", "labs")],
    }
    for name, screens in docs.items():
        (OUT / name).write_text(page(name, screens))
        # One file per screen for local preview renders.
        for i, sc in enumerate(screens):
            (OUT / f"{name[:-5]}-{i}.html").write_text(page(name, [sc]).replace('class="sheet"', 'class="sheet" style="padding:40px"'))
    # Bare captures (no desktop, no shadow) used as interim website images until real app screenshots replace them.
    bare_css = "body{background:transparent}.sheet{padding:0;gap:0}.window{box-shadow:none}.panel{position:static;box-shadow:none}"
    bare = {"overview": overview("light"), "lighting": lighting("light"), "keytest": keytest("light"),
            "firmware": firmware("light"), "onboarding": onboarding("light"),
            "menubar": menubar_panel("light").split('<div class="panel">', 1)[1].rsplit("</div></div></div>", 1)[0]}
    bare["menubar"] = '<div class="screen light"><div class="panel">' + bare["menubar"] + "</div></div>"
    for name, sc in bare.items():
        (OUT / f"bare-{name}.html").write_text(page(name, [sc]).replace("</style>", bare_css + "</style>"))
    print("\n".join(sorted(p.name for p in OUT.glob("*.html"))))


if __name__ == "__main__":
    main()

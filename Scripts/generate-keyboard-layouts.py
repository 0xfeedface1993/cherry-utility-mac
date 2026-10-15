#!/usr/bin/env python3
"""Generates CherryCore's keyboard layouts from the official CHERRY Utility driver data.

Input: the extracted driver payload (`app/` from `CHERRY Utility Setup*.exe` → `app.7z`), which holds
  Skin/XML/DeviceXml/keyboarddevice_<NAME>.xml   key index, on-screen position/size and tooltip (first panel = US)
  DefaultData/DefaultData0.json                  per DeviceIndex key table: Assignment = [type][p1][p2]
                                                 (0x20 keycode, 0x30 consumer usage LE, 0xA0 internal, 0xD0 knob)

Output: Packages/CherryKit/Sources/CherryCore/Domain/KeyboardLayout+Catalog.swift

Usage:
  python3 -I Scripts/generate-keyboard-layouts.py --driver <extracted app dir> [--check-pixiu75]

`--check-pixiu75` compares the generated PIXIU 75 layout with the hand-checked one in
KeyboardLayout+PIXIU75.swift and exits non-zero on any difference; that layout is not regenerated.
"""
import argparse
import json
import os
import re
import sys

DOMAIN_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Packages/CherryKit/Sources/CherryCore/Domain")

# (layout id, DeviceXml name, driver DeviceIndex, display name). DeviceIndex picks the KeyList in DefaultData.
LAYOUTS = [
    ("mx80TKLRGB", "MX_8_0_TKL_RGB", 0, "MX BOARD 8.0 TKL RGB"),
    ("mx30SFLNBL", "MX_3_0S_FL_NBL", 3, "MX BOARD 3.0S FL NBL"),
    ("mx10TKLBL", "MX_1_0_TKL_BL", 4, "MX BOARD 1.0 TKL BL"),
    ("mx30SFLRGB", "MX_3_0S_FL_RGB", 6, "MX BOARD 3.0S FL RGB"),
    ("mx100FLRGB", "MX_10_0_FL_RGB", 7, "MX BOARD 10.0 FL RGB"),
    ("g80TKLNBL", "G80_3000S_TKL_NBL", 8, "G80-3000S TKL NBL"),
    ("mx30SFLRGBKorean", "MX_3_0S_FL_RGB_KOREAN", 10, "MX BOARD 3.0S FL RGB (KR)"),
    ("g80TKLNBLKorean", "G80_3000S_TKL_NBL_KOREAN", 11, "G80-3000S TKL NBL (KR)"),
    ("g80TKLRGB", "G80_3000S_TKL_RGB", 12, "G80-3000S TKL RGB"),
    ("ccfMX10TKLBL", "CCF_MX_1_0_TKL_BL", 13, "MX BOARD 1.0 TKL BL (CCF)"),
    ("ccfMX80TKLBL", "CCF_MX_8_0_TKL_BL", 14, "MX BOARD 8.0 TKL BL (CCF)"),
    ("mx20SFLRGB", "MX_2_0S_FL_RGB", 15, "MX BOARD 2.0S FL RGB"),
    ("ccfMX10TKLNBL", "CCF_MX_1_0_TKL_NBL", 16, "MX BOARD 1.0 TKL NBL (CCF)"),
    ("mx10FLRGB", "MX_1_0_FL_RGB", 17, "MX BOARD 1.0 FL RGB"),
    ("mx10FLNBL", "MX_1_0_FL_NBL", 18, "MX BOARD 1.0 FL NBL"),
    ("mx10FLBL", "MX_1_0_FL_BL", 19, "MX BOARD 1.0 FL BL"),
    ("mx10TKLRGB", "MX_1_0_TKL_RGB", 20, "MX BOARD 1.0 TKL RGB"),
    ("mv30FLRGB", "MV_3_0_FL_RGB", 21, "MV BOARD 3.0 FL RGB"),
    ("mx20SFLNBL", "MX_2_0S_FL_NBL", 22, "MX BOARD 2.0S FL NBL"),
    ("mx30SFLRGBWireless", "MX_3_0S_FL_RGB_WIRELESS", 23, "MX BOARD 3.0S FL RGB Wireless"),
    ("g80FSRGB", "G80_3000S_FS_RGB", 26, "G80-3000S FS RGB"),
    ("mx82TKLRGBWireless", "MX_8_2_TKL_RGB_WIRELESS", 34, "MX BOARD 8.2 TKL RGB Wireless"),
    ("mx20FLNBLWireless", "MX_2_0_FL_NBL_WIRELESS", 35, "MX BOARD 2.0 FL NBL Wireless"),
    ("mx30STKLRGB", "MX_3_0S_TKL_RGB", 36, "MX BOARD 3.0S TKL RGB"),
    ("mx30STKLNBL", "MX_3_0S_TKL_NBL", 37, "MX BOARD 3.0S TKL NBL"),
    ("mx20SFLRGB2", "MX_2_0S_FL_RGB2", 38, "MX BOARD 2.0S FL RGB"),
    ("mxlp21", "MXLP_2_1_TKL_RGB_WIRELESS", 41, "MX-LP 2.1 Compact Wireless"),
    ("mxlp61", "MXLP_6_1_TKL_RGB_WIRELESS", 42, "MX-LP 6.1 Compact Wireless"),
    ("mx11TKLNBL", "MX_1_1_TKL_NBL", 43, "MX BOARD 1.1 TKL NBL"),
    ("mx82Xaga", "MX_8_2_Xaga_TKL_RGB_WIRELESS", 44, "MX BOARD 8.2 Xaga TKL RGB Wireless"),
    ("mx11TKLRGB", "MX_1_1_TKL_RGB", 45, "MX BOARD 1.1 TKL RGB"),
    ("mx30SFLRGBWirelessPokemon", "MX_3_0S_FL_RGB_WIRELESS_POKEMON", 47, "MX BOARD 3.0S Wireless Pokémon"),
    ("mx31FLRGB", "MX_3_1_FL_RGB", 48, "MX BOARD 3.1 FL RGB"),
    ("mx20FLNBLWirelessTLK", "MX_2_0_FL_NBL_WIRELESS_TLK", 49, "MX BOARD 2.0 FL NBL Wireless"),
    ("mx30SFLRGBWirelessFireloong", "MX_3_0S_FL_RGB_WIRELESS_FIRELOONG", 50, "MX BOARD 3.0S Wireless Fireloong"),
    ("pixiu75", "MX_PIXIU75_WIRELESS", 51, "PIXIU 75"),
    ("mx83TKLWireless", "MX_8_3_TKL_RGB_WIRELESS", 52, "MX 8.3 TKL Wireless"),
    ("pixiu75Pokemon", "MX_PIXIU75_WIRELESS_POKEMON", 53, "PIXIU 75 Pokémon"),
    ("pixiu98", "MX_98_TKL_RGB_WIRELESS", 54, "PIXIU 98"),
    ("mx101FLWireless", "MX_10_1_FL_RGB_WIRELESS", 55, "MX 10.1 Wireless"),
    ("pixiu99", "MX_PIXIU99_WIRELESS", 56, "PIXIU 99"),
    ("mx20SFLNBLNew", "MX_2_0S_FL_NBL_NEW", 57, "MX BOARD 2.0S FL NBL"),
    ("k63WPro", "MX_K6_WIRELESS", 59, "K63W Pro"),
    ("mx83ProWireless", "MX_8_3_Pro_RGB_WIRELESS", 60, "MX 8.3 Pro TKL Wireless"),
]

KEY_LABELS = {
    0x28: "Enter", 0x29: "Esc", 0x2A: "⌫", 0x2B: "Tab", 0x2C: "", 0x2D: "-", 0x2E: "=", 0x2F: "[", 0x30: "]",
    0x31: "\\", 0x32: "#", 0x33: ";", 0x34: "'", 0x35: "`", 0x36: ",", 0x37: ".", 0x38: "/", 0x39: "Caps",
    0x46: "PrtSc", 0x47: "ScrLk", 0x48: "Pause", 0x49: "Ins", 0x4A: "Home", 0x4B: "PgUp", 0x4C: "Del", 0x4D: "End",
    0x4E: "PgDn", 0x4F: "→", 0x50: "←", 0x51: "↓", 0x52: "↑", 0x53: "Num", 0x54: "/", 0x55: "*", 0x56: "-",
    0x57: "+", 0x58: "Enter", 0x63: ".", 0x64: "\\", 0x65: "Menu", 0x87: "ろ", 0x88: "かな", 0x89: "¥",
    0x8A: "変換", 0x8B: "無変換", 0x90: "한/영", 0x91: "한자",
    0xE0: "Ctrl", 0xE1: "Shift", 0xE2: "Alt", 0xE3: "Win", 0xE4: "Ctrl", 0xE5: "Shift", 0xE6: "Alt", 0xE7: "Win",
}
for u in range(0x04, 0x1E):
    KEY_LABELS[u] = chr(ord("A") + u - 0x04)
for u in range(0x1E, 0x28):
    KEY_LABELS[u] = "1234567890"[u - 0x1E]
for u in range(0x3A, 0x46):
    KEY_LABELS[u] = f"F{u - 0x39}"
for u in range(0x59, 0x63):
    KEY_LABELS[u] = "1234567890"[u - 0x59]
CONSUMER_LABELS = {
    0xE2: "🔇", 0xE9: "🔊", 0xEA: "🔉", 0xCD: "⏯", 0xB5: "⏭", 0xB6: "⏮", 0xB7: "⏹", 0x192: "Calc",
    0x18A: "Mail", 0x223: "Home", 0x194: "PC", 0x221: "Search", 0x183: "Media",
}
# Knob events (type 0xD0): counter-clockwise / clockwise / press, reported as Volume- / Volume+ / Mute.
KNOB = {0x01: (0xEA, "⟲"), 0x02: (0xE9, "⟳"), 0x04: (0xE2, "🔇")}


def parse_panel(xml):
    panel = re.split(r"<SelectPanel\s", xml)[1]
    keys = []
    for m in re.finditer(r'<DeviceKeyButton\s+name="key_(\d+)"(.*?)/?>', panel, re.S):
        attrs = m.group(2)
        pos = re.search(r'pos="(-?\d+),(-?\d+)', attrs)
        w = re.search(r'\bwidth="(\d+)"', attrs)
        h = re.search(r'\bheight="(\d+)"', attrs)
        # Hidden buttons and 1×1 placeholders at (1,1) are not physical keys.
        if not (pos and w and h) or 'visible="false"' in attrs or int(w.group(1)) <= 1 or int(h.group(1)) <= 1:
            continue
        tip = re.search(r'\btooltip="([^"]*)"', attrs)
        keys.append(dict(id=int(m.group(1)), x=int(pos.group(1)), y=int(pos.group(2)), w=int(w.group(1)),
                         h=int(h.group(1)), tip=tip.group(1) if tip else ""))
    return keys


def classify(assignment, tip):
    kind, p1, p2 = assignment >> 16 & 0xFF, assignment >> 8 & 0xFF, assignment & 0xFF
    if kind == 0x20 and p2:
        return ("keyboard", p2, KEY_LABELS.get(p2, tip))
    if kind == 0x20 and p1 and p1 & (p1 - 1) == 0:
        usage = 0xE0 + p1.bit_length() - 1  # modifier bitmask: bit0 = Left Ctrl … bit7 = Right GUI
        return ("keyboard", usage, KEY_LABELS[usage])
    if kind == 0x30:
        usage = p1 | p2 << 8
        return ("consumer", usage, CONSUMER_LABELS.get(usage, tip))
    if kind == 0xD0 and p1 in KNOB:
        usage, label = KNOB[p1]
        return ("knob", usage, label)
    # Internal functions (Fn, game mode…) are handled inside the keyboard and report nothing.
    return (None, None, "" if tip == "NULL" else tip)


def build(driver, xml_name, device_index):
    xml = open(os.path.join(driver, "Skin/XML/DeviceXml", f"keyboarddevice_{xml_name}.xml"), encoding="utf-8-sig").read()
    table = json.load(open(os.path.join(driver, "DefaultData/DefaultData0.json"), encoding="utf-8-sig"))
    key_list = table["Device"][device_index]["KeyList"]
    raw = parse_panel(xml)
    caps, knob = [], []
    for k in raw:
        assignment = key_list[k["id"]]["DefaultAssignment"] if k["id"] < len(key_list) else 0
        kind, usage, label = classify(assignment, k["tip"])
        if kind is None and k["w"] == 0:
            continue
        entry = dict(k, kind=kind, usage=usage, label=label)
        (knob if kind == "knob" else caps).append(entry)
    min_x = min(c["x"] for c in caps)
    min_y = min(c["y"] for c in caps)
    top = 40 if knob else 0
    out = []
    for c in caps:
        out.append(dict(c, x=c["x"] - min_x, y=c["y"] - min_y + top))
    if knob:
        right = max(c["x"] + c["w"] for c in out)
        order = {0xEA: 0, 0xE2: 1, 0xE9: 2}
        for k in sorted(knob, key=lambda k: order[k["usage"]]):
            out.insert(order[k["usage"]], dict(k, kind="consumer", x=right - 84 + 29 * order[k["usage"]], y=0, w=27, h=30))
    return out


def swift_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def swift_usage(c):
    if c["kind"] == "keyboard":
        return f".keyboard(0x{c['usage']:02X})"
    if c["kind"] == "consumer":
        return f".consumer(0x{c['usage']:02X})"
    return "nil"


def emit_layout(ident, name, caps):
    lines = [f"    public static let {ident} = KeyboardLayout(name: {swift_string(name)}, keys: ["]
    for c in caps:
        lines.append(
            f"        KeyCap(id: {c['id']}, label: {swift_string(c['label'])}, usage: {swift_usage(c)}, "
            f"x: {c['x']}, y: {c['y']}, width: {c['w']}, height: {c['h']}),"
        )
    lines.append("    ])")
    return "\n".join(lines)


def check_pixiu75(generated, swift_path):
    text = open(swift_path, encoding="utf-8").read()
    pattern = re.compile(
        r'KeyCap\(id: (\d+), label: "((?:[^"\\]|\\.)*)", usage: (nil|\.(keyboard|consumer)\(0x([0-9A-F]+)\)), '
        r'x: (\d+), y: (\d+), width: (\d+), height: (\d+)\)'
    )
    existing = []
    for m in pattern.finditer(text):
        usage = None if m.group(3) == "nil" else (m.group(4), int(m.group(5), 16))
        existing.append((int(m.group(1)), usage, int(m.group(6)), int(m.group(7)), int(m.group(8)), int(m.group(9))))
    ours = []
    for c in generated:
        usage = None if c["kind"] is None else ("keyboard" if c["kind"] == "keyboard" else "consumer", c["usage"])
        ours.append((c["id"], usage, c["x"], c["y"], c["w"], c["h"]))
    diff = sorted(set(existing) ^ set(ours), key=repr)
    for d in diff:
        print("PIXIU 75 mismatch:", d, "(existing)" if d in existing else "(generated)", file=sys.stderr)
    return not diff


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--driver", required=True)
    parser.add_argument("--check-pixiu75", action="store_true")
    parser.add_argument("--output", default=os.path.join(DOMAIN_DIR, "KeyboardLayout+Catalog.swift"))
    args = parser.parse_args()
    body = []
    for ident, xml_name, device_index, name in LAYOUTS:
        caps = build(args.driver, xml_name, device_index)
        if ident == "pixiu75":
            if args.check_pixiu75:
                path = os.path.join(DOMAIN_DIR, "KeyboardLayout+PIXIU75.swift")
                if not check_pixiu75(caps, path):
                    sys.exit(1)
                print("PIXIU 75: generated layout matches KeyboardLayout+PIXIU75.swift")
            continue
        body.append(emit_layout(ident, f"{name} (US)", caps))
    header = (
        "import Foundation\n\n"
        "// Generated by Scripts/generate-keyboard-layouts.py from CHERRY Utility 2.3.28.7's\n"
        "// Skin/XML/DeviceXml/keyboarddevice_*.xml (first panel = US) and DefaultData/DefaultData0.json (KeyList).\n"
        "// Do not edit by hand. Positions are skin pixels normalised to the top-left key; knobs are laid out as\n"
        "// three caps above the right end of the top row (Volume-/Mute/Volume+), as in KeyboardLayout+PIXIU75.swift.\n"
        "extension KeyboardLayout {\n"
    )
    with open(args.output, "w", encoding="utf-8") as f:
        f.write(header + "\n\n".join(body) + "\n}\n")
    print(f"wrote {len(body)} layouts to {os.path.normpath(args.output)}")


if __name__ == "__main__":
    main()

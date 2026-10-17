#!/usr/bin/env python3
"""检查构建产物里的 App Intents 元数据（AI-20）。不启动 App。

    Scripts/verify-intents-metadata.py <CherryUtility.app> [<另一个构建的 CherryUtility.app>] [--results <results.tsv>]

检查：10 个动作、3 个实体、5 个枚举（取值数 3/5/5/16/12）、9 个 App Shortcut；每条短语都含 ${applicationName}，
最多一个其他参数且是该意图的枚举或实体参数，没有重复短语；参数摘要包含全部必填参数（Spotlight 可直接运行）；
不打开 App、以后台模式运行；没有面向 Siri AI 的 schema；Resources 下只有 zh-Hans.lproj。给两个 App 时，两者元数据一致。
"""

import argparse
import json
import os
import re
import sys

parser = argparse.ArgumentParser()
parser.add_argument("apps", nargs="+")
parser.add_argument("--results")
options = parser.parse_args()
failures = 0
results = open(options.results, "a", encoding="utf-8") if options.results else None

ACTIONS = {"GetKeyboardStatusIntent", "GetBatteryIntent", "SwitchProfileIntent", "SetLightingEffectIntent", "SetBrightnessIntent",
           "TurnOffBacklightIntent", "SetLightingSpeedIntent", "SetLightingColorIntent", "SetSleepTimersIntent", "ApplyPresetIntent"}
ENUMS = {"ProfileSlot": 3, "BrightnessLevel": 5, "SpeedLevel": 5, "LightingEffectOption": 16, "LightingColorOption": 12}
ENTITIES = {"KeyboardEntity", "KeyboardStatusEntity", "PresetEntity"}


def report(app, check_id, ok, detail=""):
    global failures
    status = "PASS" if ok else "FAIL"
    if not ok:
        failures += 1
    label = os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(app)))) or app
    print(f"{status}  [metadata/{label}] {check_id}" + (f"（{detail}）" if detail and not ok else ""))
    if results:
        results.write(f"metadata/{label}\t{check_id}\t{status}\t0\t{'' if ok else detail}\n")


def load(app):
    with open(os.path.join(app, "Contents/Resources/Metadata.appintents/extract.actionsdata"), encoding="utf-8") as file:
        return json.load(file)


def check(app):
    data = load(app)
    actions = data["actions"]
    report(app, "AI-20 10 个动作", set(actions) == ACTIONS, sorted(set(actions) ^ ACTIONS))
    report(app, "AI-20 3 个实体", set(data["entities"]) == ENTITIES, sorted(data["entities"]))
    enums = {item["identifier"]: len(item["cases"]) for item in data["enums"]}
    report(app, "AI-20 5 个枚举与取值数", enums == ENUMS, enums)
    shortcuts = data["autoShortcuts"]
    report(app, "AI-20 9 个 App Shortcut", len(shortcuts) == 9, len(shortcuts))
    phrases = []
    for shortcut in shortcuts:
        action = actions.get(shortcut["actionIdentifier"], {})
        parameters = {parameter["name"]: parameter for parameter in action.get("parameters", [])}
        for template in shortcut["phraseTemplates"]:
            phrase = template["key"]
            phrases.append(phrase)
            others = [name for name in re.findall(r"\$\{(\w+)\}", phrase) if name != "applicationName"]
            typed = all(
                "linkEnumeration" in json.dumps(parameters.get(name, {}).get("valueType", {}))
                or "entity" in json.dumps(parameters.get(name, {}).get("valueType", {})).lower()
                for name in others
            )
            ok = "${applicationName}" in phrase and len(others) <= 1 and all(name in parameters for name in others) and typed
            report(app, f"AI-20 短语「{phrase}」", ok, f"参数 {others}")
    report(app, "AI-20 短语不重复", len(phrases) == len(set(phrases)), [p for p in phrases if phrases.count(p) > 1])
    for identifier, action in sorted(actions.items()):
        summary = ((action.get("actionConfiguration") or {}).get("actionSummary") or {}).get("wrapper") or {}
        in_sentence = set((summary.get("summaryString") or {}).get("parameterIdentifiers") or [])
        listed = in_sentence | set(summary.get("otherParameterIdentifiers") or [])
        required = {parameter["name"] for parameter in action.get("parameters", []) if not parameter.get("isOptional")}
        report(app, f"AI-20 {identifier} 摘要含全部必填参数", required <= in_sentence, f"必填 {sorted(required)}，摘要 {sorted(in_sentence)}")
        report(app, f"AI-20 {identifier} 列出全部参数", listed == {p["name"] for p in action.get("parameters", [])}, sorted(listed))
        report(app, f"AI-20 {identifier} 后台运行", action.get("openAppWhenRun") is False and action.get("supportedModes") == 1,
               f"openAppWhenRun={action.get('openAppWhenRun')} supportedModes={action.get('supportedModes')}")
        category = (((action.get("descriptionMetadata") or {}).get("categoryName") or {}).get("title") or {}).get("key")
        report(app, f"AI-20 {identifier} 分类为键盘", category == "键盘", category)
        report(app, f"AI-20 {identifier} 没有 Siri AI schema", not action.get("assistantDefinedSchemas"), action.get("assistantDefinedSchemas"))
    report(app, "AI-20 没有 assistantIntents", not data.get("assistantIntents"), data.get("assistantIntents"))
    lprojs = sorted(name for name in os.listdir(os.path.join(app, "Contents/Resources")) if name.endswith(".lproj"))
    report(app, "AI-20 只有 zh-Hans.lproj", lprojs in ([], ["zh-Hans.lproj"]), lprojs)
    return data


loaded = [check(app) for app in options.apps]
if len(loaded) == 2:
    def comparable(data):
        return {key: data[key] for key in ("actions", "entities", "enums", "autoShortcuts")}
    first, second = (json.dumps(comparable(data), sort_keys=True) for data in loaded)
    report(options.apps[1], "AI-20 两个构建的元数据一致", first == second, "Debug 与 Release 不同")
sys.exit(min(failures, 125))

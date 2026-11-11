#!/usr/bin/env python3
"""Builds app/data/esde_commands.json from ES-DE's own Linux system and find-rule files.

ES-DE (https://gitlab.com/es-de/emulationstation-de, MIT) decides how each system's
games start: resources/systems/linux/es_systems.xml lists every system's ROM folder,
file extensions and launch commands (the first is the default, the others are the
"alternative emulators" a user can pick), and resources/systems/linux/es_find_rules.xml
says where each %EMULATOR_x% and %CORE_x% is looked for. GameCove resolves a game's
command the same way (scripts/library/stores/esde_launch.gd), reading the installed
ES-DE's custom_systems/ overrides first, so it needs ES-DE's defaults for the systems
and emulators the user didn't override. ES-DE ships these inside its AppImage, where
we can't read them, so this keeps a copy.

Usage:
  curl -sSO https://gitlab.com/es-de/emulationstation-de/-/raw/master/resources/systems/linux/es_systems.xml
  curl -sSO https://gitlab.com/es-de/emulationstation-de/-/raw/master/resources/systems/linux/es_find_rules.xml
  python3 -I tools/emu/esde_data.py es_systems.xml es_find_rules.xml app/data/esde_commands.json
"""
import json
import sys
import xml.etree.ElementTree as ET

SOURCE = ("ES-DE's resources/systems/linux/es_systems.xml and es_find_rules.xml (MIT, "
          "https://gitlab.com/es-de/emulationstation-de), master as of %s, reduced to what "
          "GameCove needs to start a game the way ES-DE does: each system's ROM path, file "
          "extensions and launch commands (first = default), and where each emulator and "
          "RetroArch core is looked for. Rebuilt by tools/emu/esde_data.py.")


def text(el, tag):
    t = el.find(tag)
    return (t.text or "").strip() if t is not None else ""


def main(systems_xml, rules_xml, out_path, date="2026-11-10"):
    systems = {}
    for s in ET.parse(systems_xml).getroot().findall("system"):
        name = text(s, "name")
        if not name:
            continue
        exts = []
        for e in text(s, "extension").split():
            e = e.lower()
            if e.startswith(".") and len(e) > 1 and e not in exts:
                exts.append(e)
        cmds = []
        for c in s.findall("command"):
            label = (c.get("label") or "").strip()
            cmds.append([label, (c.text or "").strip()])
        systems[name] = {"path": text(s, "path"), "ext": exts, "commands": cmds}
    emulators = {}
    cores = {}
    for e in ET.parse(rules_xml).getroot():
        name = e.get("name", "")
        rules = {}
        for r in e.findall("rule"):
            rules.setdefault(r.get("type", ""), []).extend((x.text or "").strip() for x in r.findall("entry"))
        if e.tag == "emulator":
            emulators[name] = rules
        elif e.tag == "core":
            cores[name] = rules.get("corepath", [])
    doc = {"_source": SOURCE % date, "systems": systems, "emulators": emulators, "cores": cores}
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=None, separators=(",", ":"), sort_keys=True, ensure_ascii=False)
        f.write("\n")
    print("%d systems, %d emulators, %d cores" % (len(systems), len(emulators), len(cores)))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3])

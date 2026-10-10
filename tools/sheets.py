#!/usr/bin/env python3
"""Sheets are the source of truth for Rock and Stone Frontier.

  python3 tools/sheets.py preflight   # list every unfilled cell and unresolved reference
  python3 tools/sheets.py generate    # preflight, then write the Lua structs and extractor targets

Every row becomes one Lua struct (a table literal) in
mod/RockAndStoneFrontier/Scripts/generated/sheets.lua, built from that row's columns, and the
DRG rows become extractor/targets.json.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHEETS = os.path.join(ROOT, "sheets")
SCRIPTS = os.path.join(ROOT, "mod", "RockAndStoneFrontier", "Scripts")
GENERATED_LUA = os.path.join(SCRIPTS, "generated", "sheets.lua")
TARGETS_JSON = os.path.join(ROOT, "extractor", "targets.json")


def load():
    sheets = {}
    for name in sorted(os.listdir(SHEETS)):
        if name.endswith(".json"):
            with open(os.path.join(SHEETS, name), encoding="utf-8") as f:
                data = json.load(f)
            sheets[data["sheet"]] = data
    return sheets


def col_kind(spec):
    return spec.split(":", 1)[0] if ":" in spec else spec.split(" ")[0]


def preflight(sheets):
    problems = []
    pending = []
    ids = {name: {r.get("id") for r in s["rows"]} for name, s in sheets.items()}

    def resolve(sheet, row_id, col, target_spec, value):
        allow_none = target_spec.endswith("|none")
        target = target_spec.split("|")[0]
        if target not in sheets:
            problems.append(f"{sheet}.{row_id}.{col}: refers to missing sheet '{target}'")
            return
        if allow_none and value == "none":
            return
        if value not in ids[target]:
            problems.append(f"{sheet}.{row_id}.{col}: '{value}' is not a row of {target}")

    for name, s in sheets.items():
        cols = s["columns"]
        seen = set()
        for i, row in enumerate(s["rows"]):
            rid = row.get("id", f"#{i}")
            if rid in seen:
                problems.append(f"{name}.{rid}: duplicate id")
            seen.add(rid)
            for extra in set(row) - set(cols):
                problems.append(f"{name}.{rid}.{extra}: cell has no column in the sheet")
            for col, spec in cols.items():
                if col not in row or row[col] is None or row[col] == "":
                    problems.append(f"{name}.{rid}.{col}: unfilled")
                    continue
                value = row[col]
                kind = spec.split(" ")[0].split(":")
                if kind[0] == "ref":
                    resolve(name, rid, col, kind[1], value)
                elif kind[0] == "list":
                    if not isinstance(value, list):
                        problems.append(f"{name}.{rid}.{col}: should be a list")
                    elif len(kind) > 2 and kind[1] == "ref":
                        for v in value:
                            resolve(name, rid, col, kind[2], v)
                    elif not value and name != "systems":
                        problems.append(f"{name}.{rid}.{col}: empty list")
                elif kind[0] in ("number", "int"):
                    if not isinstance(value, (int, float)) or isinstance(value, bool):
                        problems.append(f"{name}.{rid}.{col}: not a number")
                    elif kind[0] == "int" and int(value) != value:
                        problems.append(f"{name}.{rid}.{col}: not a whole number")
                elif kind[0] == "bool" and not isinstance(value, bool):
                    problems.append(f"{name}.{rid}.{col}: not true/false")
                elif kind[0] == "enum":
                    allowed = kind[1].split("|")
                    if value not in allowed:
                        problems.append(f"{name}.{rid}.{col}: '{value}' not one of {allowed}")
                elif kind[0] == "color":
                    if not (isinstance(value, list) and len(value) == 3):
                        problems.append(f"{name}.{rid}.{col}: color needs 3 numbers")
            if name == "ffw_hooks" and row.get("verified") == "pending":
                pending.append(f"ffw_hooks.{rid}: {row.get('purpose')}")

    # Cross-sheet rules.
    weapons = {r["id"]: r for r in sheets["weapons"]["rows"]}
    grenades = {r["id"]: r for r in sheets["grenades"]["rows"]}
    deployables = {r["id"]: r for r in sheets["deployables"]["rows"]}
    for c in sheets["classes"]["rows"]:
        for slot in ("primary", "secondary"):
            w = weapons.get(c[slot])
            if w and (w["class"] != c["id"] or w["slot"] != slot):
                problems.append(f"classes.{c['id']}.{slot}: {w['id']} is {w['class']}/{w['slot']}")
        g = grenades.get(c["grenade"])
        if g and g["class"] != c["id"]:
            problems.append(f"classes.{c['id']}.grenade: {g['id']} belongs to {g['class']}")
        d = deployables.get(c["deployable"])
        if d and d["class"] != c["id"]:
            problems.append(f"classes.{c['id']}.deployable: {d['id']} belongs to {d['class']}")

    sources = {r["id"]: r for r in sheets["drg_sources"]["rows"]}
    for sheet in ("weapons", "grenades", "deployables"):
        for row in sheets[sheet]["rows"]:
            src = sources.get(row["drg_source"])
            if not src:
                continue
            for stat in src["stats"]:
                if stat not in sheets[sheet]["columns"]:
                    problems.append(f"drg_sources.{src['id']}.stats: '{stat}' is not a column of {sheet} (used by {row['id']})")
    used = {row["drg_source"] for s in ("weapons", "grenades", "deployables") for row in sheets[s]["rows"]}
    for sid in sources:
        if sid not in used:
            problems.append(f"drg_sources.{sid}: no gear uses it")

    for row in sheets["systems"]["rows"]:
        if not os.path.exists(os.path.join(SCRIPTS, row["file"])):
            problems.append(f"systems.{row['id']}.file: {row['file']} does not exist yet")

    keys = {}
    for row in sheets["controls"]["rows"]:
        if row["when"] != "picker":
            if row["key"] in keys:
                problems.append(f"controls.{row['id']}.key: {row['key']} already used by {keys[row['key']]}")
            keys[row["key"]] = row["id"]
    for row in sheets["deployables"]["rows"]:
        if row["deploy_key"] not in keys:
            problems.append(f"deployables.{row['id']}.deploy_key: {row['deploy_key']} has no controls row")
    return problems, pending


def lua_value(v, indent=""):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v)  # JSON string escapes are valid Lua escapes for this content
    if isinstance(v, list):
        return "{" + ", ".join(lua_value(x) for x in v) + "}"
    if isinstance(v, dict):
        return "{" + ", ".join(f"[{json.dumps(k)}] = {lua_value(x)}" for k, x in v.items()) + "}"
    raise TypeError(type(v))


def generate(sheets):
    out = ["-- Generated by tools/sheets.py from sheets/*.json. Do not edit: change the sheet and regenerate.",
           "local S = {}", ""]
    for name, s in sheets.items():
        out.append(f"-- {s['about']}")
        out.append(f"S.{name} = {{}}")
        out.append(f"S.{name}_order = {{}}")
        for row in s["rows"]:
            fields = ", ".join(f"{k} = {lua_value(row[k])}" for k in s["columns"])
            out.append(f"S.{name}[{json.dumps(row['id'])}] = {{ {fields} }}")
            out.append(f"table.insert(S.{name}_order, {json.dumps(row['id'])})")
        out.append("")
    out.append("return S")
    os.makedirs(os.path.dirname(GENERATED_LUA), exist_ok=True)
    with open(GENERATED_LUA, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")

    props = {r["id"]: r for r in sheets["drg_stat_props"]["rows"]}
    gear = []
    for sheet in ("weapons", "grenades", "deployables"):
        for row in sheets[sheet]["rows"]:
            gear.append({"id": row["id"], "sheet": sheet, "source": row["drg_source"]})
    targets = {
        "sources": [
            {"id": r["id"], "asset_globs": r["asset_globs"],
             "stats": [{"id": st, "candidates": props[st]["candidates"], "scale": props[st]["scale"],
                        "value_type": props[st]["value_type"]} for st in r["stats"]]}
            for r in sheets["drg_sources"]["rows"]
        ],
        "gear": gear,
    }
    with open(TARGETS_JSON, "w", encoding="utf-8", newline="\n") as f:
        json.dump(targets, f, indent=1)
        f.write("\n")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "preflight"
    sheets = load()
    problems, pending = preflight(sheets)
    total_cells = sum(len(s["rows"]) * len(s["columns"]) for s in sheets.values())
    print(f"{len(sheets)} sheets, {sum(len(s['rows']) for s in sheets.values())} rows, {total_cells} cells")
    for p in problems:
        print("  FAIL", p)
    for p in pending:
        print("  UNVERIFIED (needs the running game)", p)
    if problems:
        print(f"preflight: {len(problems)} problem(s); not building")
        sys.exit(1)
    print(f"preflight clean ({len(pending)} hook(s) still to confirm in the running game)")
    if cmd == "generate":
        generate(sheets)
        print("generated", os.path.relpath(GENERATED_LUA, ROOT), "and", os.path.relpath(TARGETS_JSON, ROOT))


if __name__ == "__main__":
    main()

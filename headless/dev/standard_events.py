"""standard_events.py <standard dir> [out prefix]

What happens in a standard: for each save (date order) a row of counts (countries by kind, wars,
federations, the player's open events and messages, ships, fleets, pop groups), and the events
between saves (countries appearing or gone, with their type and name; wars starting and ending).
Writes <prefix>timeline.tsv and <prefix>events.txt (prefix default: the standard dir/).
"""
import os
import re
import sys
import zipfile

std = sys.argv[1]
prefix = sys.argv[2] if len(sys.argv) > 2 else os.path.join(std, "")


def section(text, name):
    m = re.search(r"^" + name + r"=\n\{\n(.*?)^\}", text, re.S | re.M)
    return m.group(1) if m else ""


def entries(body):
    """{id: entry text} of a top-level section's `\tN=\n\t{ ... \t}` entries (not `N=none`)."""
    out = {}
    for m in re.finditer(r"^\t(\d+)=\n\t\{\n(.*?)^\t\}", body, re.S | re.M):
        out[m.group(1)] = m.group(2)
    return out


def first(pattern, text, default=""):
    m = re.search(pattern, text, re.M)
    return m.group(1) if m else default


def name_of(entry):
    block = first(r"^\t\tname=\n\t\t\{\n(.*?)^\t\t\}", entry.replace("\r", ""), "") if "\t\tname=" in entry else ""
    keys = re.findall(r'key="([^"]+)"', block)
    return "/".join(keys[:3]) if keys else "?"


saves = sorted(f for f in os.listdir(std) if f.startswith("autosave_") and f.endswith(".sav"))
finals = sorted(f for f in os.listdir(std) if f.startswith("final_") and f.endswith(".sav"))
rows, events = [], []
prev_c, prev_w = None, None
for f in saves + finals:
    g = zipfile.ZipFile(os.path.join(std, f)).read("gamestate").decode("utf-8", "replace")
    date = first(r'^date="([^"]+)"', g)
    countries = entries(section(g, "country"))
    kinds = {}
    for cid, e in countries.items():
        kinds[cid] = (first(r'^\t\ttype="([^"]+)"', e), name_of(e))
    wars = {wid: name_of(e) for wid, e in entries(section(g, "war")).items()}
    feds = len(entries(section(g, "federation")))
    by_type = {}
    for t, _ in kinds.values():
        by_type[t] = by_type.get(t, 0) + 1
    player_events = len(re.findall(r"^player_event=", g, re.M))
    messages = len(re.findall(r"^message=", g, re.M))
    ships = len(entries(section(g, "ships")))
    fleets = len(entries(section(g, "fleet")))
    pops = len(entries(section(g, "pop_groups")))
    rows.append((f, date, by_type.get("default", 0), by_type.get("fallen_empire", 0) + by_type.get("awakened_fallen_empire", 0),
                 by_type.get("primitive", 0), len(kinds), len(wars), feds, player_events, messages,
                 first(r"^last_event_id=(\d+)", g), ships, fleets, pops))
    if prev_c is not None:
        for cid, (t, n) in kinds.items():
            if cid not in prev_c:
                events.append(f"{date}  country {cid} appears: {t} {n}")
            elif prev_c[cid][0] != t:
                events.append(f"{date}  country {cid} {n}: {prev_c[cid][0]} -> {t}")
        for cid, (t, n) in prev_c.items():
            if cid not in kinds:
                events.append(f"{date}  country {cid} gone: {t} {n}")
        for wid, n in wars.items():
            if wid not in prev_w:
                events.append(f"{date}  war {wid} starts: {n}")
        for wid, n in prev_w.items():
            if wid not in wars:
                events.append(f"{date}  war {wid} ends: {n}")
    prev_c, prev_w = kinds, wars

with open(prefix + "timeline.tsv", "w") as out:
    out.write("file\tdate\tempires\tfallen_empires\tprimitives\tcountries\twars\tfederations\t"
              "player_events_open\tmessages\tlast_event_id\tships\tfleets\tpop_groups\n")
    for r in rows:
        out.write("\t".join(map(str, r)) + "\n")
with open(prefix + "events.txt", "w") as out:
    out.write("\n".join(events) + "\n")
print(f"{len(rows)} saves, {len(events)} events -> {prefix}timeline.tsv, {prefix}events.txt")

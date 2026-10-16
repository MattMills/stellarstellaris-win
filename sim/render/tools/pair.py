#!/usr/bin/env python3
"""One command file against the real game and the renderer (docs/render.md sections 9 and 12):
the same commands, `{OUT}` in them replaced by each side's own folder, the replies side by side,
then each frame both took as one picture (the game left, the renderer right; with Pillow) and,
for each `state`, the cameras compared.

    pair.py --game HOST:PORT --render HOST:PORT --file CMDS OUT_DIR

OUT_DIR/game and OUT_DIR/render get the frames (`frame {OUT}/NAME.png`), OUT_DIR/pair the
pictures side by side with the mean difference of their pixels (0..255) in the name's list,
OUT_DIR/replies.txt the replies. A command whose reply is an error on either side stops the run
(exit 1). The game: headless/view.sh --listen PORT SAVE; the renderer: stellar-render --listen
PORT. Start the file with `timestep MS` for frames in lockstep (the input's frames exactly).
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ctl import Client  # noqa: E402


def camera_of(reply):
    """The camera of a `state` reply: target, yaw, pitch, distance in map units and degrees."""
    try:
        s = json.loads(reply[3:])
    except ValueError:
        return None
    c = s.get("camera")
    if not c:
        return None
    k = s.get("space_scale", 1)  # the game's state: its world units
    t = c["target"]
    return {
        "view": s.get("view"),
        "target": [round(v / k, 3) for v in t],
        "yaw": round(c["yaw"], 3),
        "pitch": round(c["pitch"], 3),
        "distance": round(c["distance"] / k, 3),
        "selected": s.get("selected"),
        "clock": s.get("clock"),
    }


def side_by_side(a, b, out):
    try:
        from PIL import Image, ImageChops, ImageStat
    except ImportError:
        return None
    ia, ib = Image.open(a).convert("RGB"), Image.open(b).convert("RGB")
    w, h = ia.width + ib.width, max(ia.height, ib.height)
    pic = Image.new("RGB", (w, h))
    pic.paste(ia, (0, 0))
    pic.paste(ib, (ia.width, 0))
    pic.save(out)
    if ia.size != ib.size:
        return None
    return sum(ImageStat.Stat(ImageChops.difference(ia, ib)).mean) / 3


def main(argv):
    args = {"--game": None, "--render": None, "--file": None}
    rest = []
    i = 0
    while i < len(argv):
        if argv[i] in args and i + 1 < len(argv):
            args[argv[i]] = argv[i + 1]
            i += 2
        else:
            rest.append(argv[i])
            i += 1
    if None in args.values() or len(rest) != 1:
        print(__doc__)
        return 2
    out = os.path.abspath(rest[0])
    sides = {"game": Client(args["--game"]), "render": Client(args["--render"])}
    for s in sides:
        os.makedirs(os.path.join(out, s), exist_ok=True)
    os.makedirs(os.path.join(out, "pair"), exist_ok=True)
    frames, log = [], []
    with open(args["--file"], encoding="utf-8") as f:
        commands = [l.strip() for l in f if l.strip() and not l.strip().startswith("#")]
    for cmd in commands:
        replies = {}
        for s, c in sides.items():
            reply, _, dt = c.send(cmd.replace("{OUT}", os.path.join(out, s)))
            replies[s] = reply
            log.append(f"{s:6} > {cmd}\n{s:6} {reply[:400]}  ({dt * 1000:.0f} ms)")
        print("\n".join(log[-2:]))
        if any(r.startswith("error") for r in replies.values()):
            print("an error: stopped")
            break
        if cmd.startswith("frame ") and "{OUT}" in cmd and not cmd.split()[1] == "-":
            frames.append(cmd.split()[1].replace("{OUT}/", ""))
        if cmd.startswith("state"):
            g, r = camera_of(replies["game"]), camera_of(replies["render"])
            line = f"  camera game   {g}\n  camera render {r}"
            print(line)
            log.append(line)
    with open(os.path.join(out, "replies.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(log) + "\n")
    print("\nframes (game | renderer), the mean difference of the pixels:")
    for name in frames:
        a, b = os.path.join(out, "game", name), os.path.join(out, "render", name)
        if os.path.exists(a) and os.path.exists(b):
            d = side_by_side(a, b, os.path.join(out, "pair", name))
            print(f"  pair/{name}  {'' if d is None else f'{d:.1f}'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

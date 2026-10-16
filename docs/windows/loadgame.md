# The Load Game window (interface/loadgame_view.gui)

The main menu's Load Game: `sim/render/lua/render/loadgame.lua` (through `render.frontend.load_window`
and `load_act`), the saves from `app.rs list_saves` with each save's `meta`. Marks: [V] read in the
game's code or seen in its frames, [I] inferred, [S] a stand-in.

## What it shows

| Part | Source | |
|---|---|---|
| sessions (LoadGameSessionEntry) | one per save folder (its name in lower case: CLoadGameView::BuildSessionsList @0x2f212e0) | [V] |
| order | stable descending sort by the file's time in whole seconds, sessions by their newest save (DescendingFileDateSort / DescendingFileDateGameSessionSort); ties keep the directory's order | [V] code + frames |
| an entry's name, date, file | its newest save: the meta's `name` and `date`, the file's name | [V] |
| flag | the meta's `flag` on GFX_empire_flag_64 (SetupFlagSprite), composed as render.empire_preview.flag_texture | [V] |
| portrait | the meta's `player_portrait` is a 3D portrait (CPortraitObject::SetPortrait): not drawn; leader_type_bg and the frame are | [S] |
| ironman_icon | `ironman = yes` in the meta (a save with it only in the gamestate shows none) | [V] frames |
| incompatible_save | the save's version under 4.5 or over the game's (SSaveGameMetaData::CheckIsBadVersion @0x1f1b8f0, CVersionNumber {4, 5}) | [V] |
| cloud_file | frame 1 (a local file) on every entry | [V] frames |
| selection | the first session when the window opens, its selected_overlay; a click selects another; no save selected (Load Selected greyed) | [V] frames |
| selected_window | the session's name, date, fleets (`meta_fleets`), planets (`meta_planets`), flag (GFX_empire_flag_128), its saves (LoadSaveGameEntry: name = file without .sav, date, file, fleets, planets, ironman / incompatible / cloud) | [V] |
| delete toggle | frame 3 while on; then each entry's Load Latest Save becomes its delete button and each save shows its delete button | [V] frames |
| other DLCs (HasOtherDLCs) | no marker in the frames (a save needing an unowned DLC shows like the others) | [V] frames |

Rows: sessions every 97 pixels (102, spacing -5), saves every 54 (58, spacing -4), cut to their
lists. Actions: `loadwin:session:N`, `loadwin:save:N`, `loadwin:delete`, `loadwin:latest:N` (loads
the session's newest save), `loadwin:load_selected`; the delete buttons do nothing (the game asks,
then deletes the files) and a double click does not load [I: not done].

Saves are listed from the folder of STELLAR_SAVE (or the default save), each folder of the user's
`Documents/Paradox Interactive/Stellaris/save games` and of `STELLAR_SAVE_GAMES` (a `save games`
folder: each subfolder a session), `C:\lfm\saves` and `/opt/stellaris-saves`. Names and dates come
from the meta (no longer from the gamestate's head, which meant reading every gamestate).

## Compared with the game

Headless at the main menu (view.sh --menu) with test saves in its user folder (made from
/opt/stellaris-saves: a version 3.14 save, an ironman meta, an ironman gamestate, an unowned DLC;
/root/ngf/mksaves.py, mk2.py on 10.5.0.24), the renderer with STELLAR_SAVE_GAMES on a copy (times
kept); the same clicks through pair.py: open, select a session, select a save, the delete toggle.
Pictures (game left): /root/ngf/lg/pair/pair on 10.5.0.24. The rows, texts, flags, icons, markers,
overlays and the details match; differences: the portraits (3D, not drawn), the session list's
scrollbar (not drawn), and the menu's version line ("Version:" missing, a pre-existing difference).

The window takes clicks once controls.rs has a `load click left select` binding (branch
fix-window-load).

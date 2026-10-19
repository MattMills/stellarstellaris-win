# Tooltips (4.5.2)

How the renderer shows the game's tooltips: when, where, what window, and where the texts come
from. Read from the Linux 4.5.2 build (addresses below) and checked against the real game's
frames (`headless/view.sh`: `move X Y`, `tick 120`, `frame PATH now`).

**[V]**: read in the game's code or files, or measured in its frames. **[I]**: inferred.

Code: `sim/render/src/tooltip.rs` (when, where, the window), `sim/render/lua/render/tooltip.lua`
(the texts built from the world, the providers), `sim/render/lua/render/tooltip_data.lua` (what
the texts need of the world, read on the simulation's thread into the outliner's view: `tips`),
`render/gui.lua` (an element's tooltip carried on its item), a small hook in `app.rs`.

## 1. The window (CTooltipManager, CTooltipWindow) [V]

- core.gui's `ToolTipWindow`: the background `GFX_tooltip_bg` (a cornered tile, 10 px corners,
  87 % opaque near-black), its `text` (cg_16b, white by default, borderSize 35 x 15, maxWidth
  500). The window is the text's size + 70 x 30; the text wraps at 430 px (spaces, line breaks;
  an icon is a word), at most 70 lines. Colour codes and £icons£ as in any GUI text.
- Shown once the cursor has rested 0.05 s on the target (NInterface::TOOLTIP_TIME, in
  unchecked_defines/00_interface.txt); it follows the cursor and goes when the cursor leaves the
  target. Moving to another target with a tooltip does not wait again in the game [V]; here a new
  target waits its 0.05 s [I: not noticeable].
- Placed at the cursor + (21, 24) (TOOLTIP_POSITION_OFFSET); moved left at the right edge, above
  the cursor at the bottom (its top at the cursor - 24 - its height), never off the top or left.
- An outliner row's (COutlinerMember::GetToolTip @0x2fed720): `outliner_tooltip_offset` (-130,
  -30) added and a flag set that right-aligns it: its right edge at the cursor + 21 - 130, its top
  at the cursor + 24 - 30 [V for the offset; I: the flag's meaning, by the game's frame].
- Not done here: the delayed part (pdx_tooltip_delayed, after 0.8 s under a line of dashes),
  locking by the middle button, concept links and nested tooltips, a tooltip's `desc` part (the
  game's frames of the top bar after 2 s show none), Escape closing it.

## 2. Where a text comes from (first found)

1. The `Tooltips` hook (App::tooltips: a later phase's texts through the modifier graph).
2. render.tooltip's providers, from the world (`view.tips`):
   - the top bar's resource groups (GetToolTipForTopBarResources @0x329d0b0): the resource's name
     (§H); Stored: amount / its max (strategic_resources `max`) [I: the max modifiers not summed];
     Monthly Gain (the month's balance); Produced and Consumed (the budget's income and expenses),
     each followed by its rows (NAMED_RESOURCE_TABLE "Name: 0.00"): the save's leaf categories
     summed into their level-0 economic category (the visible one with no visible ancestor:
     CEconomicCategory::UpdateLevel), in the categories' file order; Monthly Trades;
   - research (BuildTooltipForResources): a line per area with its monthly income;
   - the counters (empire size, station capacity, naval capacity): their header and value [I: the
     breakdowns not built];
   - the date and the speed buttons: the speed's name, "Click to resume" or "pause", the keys;
   - the map's things (CInGameIdler::BuildToolTip): a ship (CShip::GetToolTip @0x2abb830: its
     size and name, its class in the class's colour with its icon, the owner, hull, armor and
     shields as current/max, FTL), a fleet (CFleet::GetToolTip: a civilian fleet or a station as
     its lead ship, a military fleet its name, power, hull points and composition), a system
     (CGalacticObject::GetToolTip: name, type, "---", whose space), a planet or star
     (CPlanet::GetToolTip: name, class); a map label has its thing's;
   - the outliner's rows (their layout's `tooltips`): the fleet's, the station's ship, the
     colony's (CColony::GetToolTip: name, owner, population, dominant species), then the select
     hint (OUTLINER_MEMBER_SELECT_DESC). Group headers have none (as in the game).
3. The element's own: its window's `tooltips` (below), else its .gui `pdx_tooltip` / `tooltip` /
   `tooltipText` (one field in the game), a localisation key resolved with its `$KEY$`s; a button
   with a `shortcut` adds "Hotkey: KEY" (CTooltipManager) [V; the key drawn as text here, the
   game draws a key icon].
- A disabled button shows its tooltip as any other (the game has no separate disabled text; a
  view that explains why sets that text itself) [V].
- Elements that take no clicks (icons) have their tooltips too: tooltip.rs finds the topmost item
  with a tooltip under the cursor (the top bar's, then the windows').

## 3. A window's own tooltips

A window module gives the tooltips of its elements as it gives their texts: a `tooltips` table
in the options of `gui.layout` (or `WindowSpec::tooltips` from Rust), element path -> text:

```lua
local items, report = gui.layout(game_dir, db, "interface/my_view.gui", "my_view", screen, {
    texture_size = ctx.texture_size, loc = ctx.loc, text = text, actions = actions,
    tooltips = {
        ["/my_view/build_button"] = "MY_VIEW_BUILD_TOOLTIP",                 -- a key
        ["/my_view/cost"] = "Costs §Y" .. cost .. "§! £energy£",           -- or a text
        ["/my_view/disabled_button"] = can and "BUILD" or "§RNot enough energy§!",
    },
})
```

The value is a localisation key or a text (colour codes, £icons£, `$KEY$` references). It
replaces the .gui's own. For texts built when the cursor rests (not at layout), a module adds a
provider: `require("render.tooltip").add_element(LUA_PATTERN, function(path, captures...) return
text end)`.

## 4. Compared with the game (2210.01.01, game left)

- Energy: the same lines, values and colours (Stored 9084/25000, Monthly Gain, Produced with
  Base, Stations, Starbases, Trade Policy, Jobs; Consumed with Ships, Stations, Starbases,
  Buildings, Districts), the same place under the group. The gain and income's last digit can
  differ (the game recomputes them live: +75.36 against the save's +75.35).
- The date: "Paused / Click to resume / Mouse Hotkey / Hotkey: SPACE / Jump to next day", the
  same place.
- An outliner row (UOR Drifting Crab): the same lines and place, but for the game's ship
  modifiers block after a line of dashes (not built here).
- A star in the system view: its name and class.

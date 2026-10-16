-- render/windows/discoveries.lua : the Discoveries view (interface/discoveries_view.gui,
-- CDiscoveriesView), a left bar view (views.rs; ETopBarView 15, "discoveries").
-- docs/windows/events.md.
--
-- The Relics tab (CDiscoveriesView::SwitchToRelicsTab; CRelicsView, CMinorArtifactsView) [V for the
-- parts read, I where marked]: "Relics and Minor Artifacts"; the relics box (`relics_box`, the
-- narrow one at 1600 wide [I]): the relics found, the triumph text, a `relic_grid_entry` per relic
-- (3 a row, 184 x 194 slots) and empty frames up to 6 [I: by the frame]; the minor artifacts box:
-- the stockpile and the month's balance, an `artifact_action_grid_entry` per artifact action of
-- common/artifact_actions whose `potential` holds for the player
-- (CMinorArtifactsView::UpdateArtifactActionsGrid: CArtifactAction::IsPotential), stably sorted
-- by their cost (SSortArtifactActions compares the costs: the `_locked` ones, without a cost,
-- come first and read "??????"), 43 apart, their name and cost.

local gui = require("render.gui")
local source = require("stellar.script.source")

local M = {}

local FILE = "interface/discoveries_view.gui"

local function get(block, key)
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text:lower() == key then
            return e.value.text or e.value
        end
    end
    return nil
end

-- where the world is: the player's relics, minor artifacts and the artifact actions shown
function M.extract(game_dir)
    local world = require("engine.world")
    local data = require("render.windows.events_data")
    local pid = data.player()
    local c = world.object("country", pid)
    local relics = {}
    for _, r in ipairs(world.list(world.field(c or {}, "relics") or {})) do
        relics[#relics + 1] = (tostring(r):gsub('"', ""))
    end
    local stock = tonumber(world.path(c or {}, "modules", "standard_economy_module", "resources", "minor_artifacts")) or 0
    local balance = 0
    local cm = world.path(c or {}, "budget", "current_month", "balance")
    for _, b in ipairs(type(cm) == "table" and cm or {}) do
        if b.op and b.value and b.value.text == nil then
            balance = balance + (tonumber(world.field(b.value, "minor_artifacts")) or 0)
        end
    end
    -- the actions, in file order, with their cost
    local actions = {}
    local roots = { this = { kind = "country", id = pid }, root = { kind = "country", id = pid } }
    for _, f in ipairs(source.files(game_dir, "common/artifact_actions", "txt")) do
        local tree = source.parse(game_dir, f)
        local vars = {}
        for _, e in ipairs(tree or {}) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                vars[e.key.text] = tonumber(e.value.text)
            end
        end
        for _, e in ipairs(tree or {}) do
            if e.op and e.key and e.value.text == nil and e.key.text:sub(1, 1) ~= "@" then
                local b = e.value
                local pot = get(b, "potential")
                if pot == nil or data.trigger(pot, roots, pid) then
                    local cost = get(get(get(b, "resources") or {}, "cost") or {}, "minor_artifacts")
                    cost = cost and (vars[cost] or tonumber(cost)) or 0
                    actions[#actions + 1] = { key = e.key.text, cost = cost, allowed = data.trigger(get(b, "allow"), roots, pid) }
                end
            end
        end
    end
    -- a stable sort by cost
    for i, a in ipairs(actions) do
        a.order = i
    end
    table.sort(actions, function(a, b)
        if a.cost ~= b.cost then
            return a.cost < b.cost
        end
        return a.order < b.order
    end)
    return { relics = relics, minor_artifacts = stock, balance = balance, actions = actions }
end

local function number(v)
    v = math.floor((v or 0) + 0.5)
    return tostring(v)
end

-- M.build(ctx, data, state) -> items, report; state.tab: relics (the default), collection,
-- vivarium, astral_actions
function M.build(ctx, data, state)
    state = state or {}
    data = data or {}
    local loc, db = ctx.loc, ctx.db
    local items, report = {}, { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {} }
    local tab = state.tab or "relics"
    -- the text icon £minor_artifacts£: the resource's icon (no GFX_text_minor_artifacts is defined) [I]
    if not db.sprites.GFX_text_minor_artifacts and db.sprites.GFX_resource_minor_artifacts then
        db.sprites.GFX_text_minor_artifacts = db.sprites.GFX_resource_minor_artifacts
    end
    local root = "/discoveries_view"
    local hide = { relics_box_wide = true, active_triumph_text = true, active_triumph_value = true, progressbar = true }
    for _, t in ipairs({ "relics", "collection", "vivarium", "astral_actions" }) do
        hide[t == tab and ("tab_" .. t) or ("tab_" .. t .. "_active")] = true
    end
    -- the other tabs need their DLC or unlock: the game's frame shows the Relics tab alone [I]
    for _, t in ipairs({ "collection", "vivarium", "astral_actions" }) do
        if t ~= tab then
            hide["tab_" .. t] = true
        end
    end
    if tab ~= "relics" then
        hide.relics_window, hide.artifacts_window = true, true
    end
    if tab ~= "collection" then
        hide.collection_window = true
    end
    if tab ~= "vivarium" then
        hide.vivarium_window = true
    end
    if tab ~= "astral_actions" then
        hide.astral_actions_window = true
    end
    local box = root .. "/relics_window/relics_box"
    local text = {
        [root .. "/header"] = tab == "relics" and "RELICS_AND_ARTIFACTS" or "",
        [box .. "/relics_topbar/relics_topbar_left/relics_found_value"] = tostring(#(data.relics or {})),
        [root .. "/artifacts_window/artifacts_box/artifacts_topbar/amount"] =
            "£minor_artifacts£" .. number(data.minor_artifacts) .. " " .. ((data.balance or 0) >= 0 and "+" or "") .. number(data.balance),
    }
    local actions = {
        [root] = "view_set:noop=",
        [root .. "/close"] = "view_close",
    }
    for _, t in ipairs({ "relics", "collection", "vivarium", "astral_actions" }) do
        actions[root .. "/tab_" .. t] = "view_set:tab=" .. t
    end
    local wi, wr = gui.layout(ctx.game_dir, db, FILE, "discoveries_view", ctx.screen, {
        texture_size = ctx.texture_size, loc = loc, hide = hide, text = text, actions = actions,
    })
    gui.merge(items, report, wi, wr)
    if tab ~= "relics" then
        return items, report
    end
    -- the relics: one slot each, empty frames up to 6
    local grid = wr.rects[box .. "/relics_content/relics_grid"]
    if grid then
        local n = math.max(6, #(data.relics or {}))
        for i = 1, n do
            local relic = data.relics[i]
            local p = "/relics/" .. i
            local path = p .. "/relic_grid_entry"
            local ri, rr = gui.layout(ctx.game_dir, db, FILE, "relic_grid_entry", ctx.screen, {
                texture_size = ctx.texture_size, loc = loc, prefix = p,
                parent = { x = grid.x + 8 + ((i - 1) % 3) * 184, y = grid.y + math.floor((i - 1) / 3) * 194, w = 0, h = 0 },
                hide = relic and { frame_unused = true } or { frame = true, relic_portrait = true },
                sprites = relic and { [path .. "/relic_portrait"] = "GFX_relic_" .. relic } or nil,
            })
            gui.merge(items, report, ri, rr)
        end
    end
    -- the artifact actions
    local ag = wr.rects[root .. "/artifacts_window/artifacts_box/artifacts_content/artifact_actions_grid"]
    if ag then
        for i, a in ipairs(data.actions or {}) do
            local p = "/artifacts/" .. i
            local path = p .. "/artifact_action_grid_entry"
            local ai, ar = gui.layout(ctx.game_dir, db, FILE, "artifact_action_grid_entry", ctx.screen, {
                texture_size = ctx.texture_size, loc = loc, prefix = p,
                parent = { x = ag.x, y = ag.y + (i - 1) * 43, w = 0, h = 0 },
                text = {
                    [path .. "/title"] = a.key,
                    -- (a cost above the stockpile in red, as the frame shows [I])
                    [path .. "/cost"] = a.cost > 0 and ("£minor_artifacts£" .. ((data.minor_artifacts or 0) < a.cost and ("§R" .. number(a.cost) .. "§!") or number(a.cost))) or "",
                },
                -- (the button over the entry shows no frame in the game's frame [I]; its action would
                -- post the artifact action, which the simulation does not take)
                hide = { button = true },
            })
            gui.merge(items, report, ai, ar)
        end
    end
    return items, report
end

return M

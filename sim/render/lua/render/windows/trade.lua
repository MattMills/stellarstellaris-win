-- render/windows/trade.lua : the diplomatic trade window (interface/trade_view.gui, CTradeView;
-- docs/windows/economy.md), as it opens with nothing offered.
--
--   trade.extract(game_dir) -> data    the player and the countries it has met (views.rs)
--   trade.build(ctx, data, state) -> items, report
--
-- state: country (the recipient's id: CDiplomacyView::OpenTrade opens it for the country the
-- diplomacy view has selected; here `open_view trade country ID`), tab ("offer" | "demands",
-- without the wide mode).
--
-- CTradeView::Show/SetRecipient/Update [V]: the actor (the player: its flag and name), the
-- recipient (its flag, name, its ruler's portrait), "Gives" under each; above 1470 pixels of
-- width (NInterface TRADE_VIEW_WIDE_MODE_THRESHHOLD) the window is 1470 wide, the demands'
-- categories at trade_view_wide_mode_demands_pos and no tabs, else the Offer and Demands tabs;
-- both offer lists empty; the deal length hidden (no treaty); Propose disabled (an empty deal is
-- not proposable), Cancel enabled. The categories (ETradeCategory 0..10 in order, each side's
-- own) show those with items.

local gui = require("render.gui")

local trade = {}

-- a view of its own, not a top bar view's token (views.rs: opened by `open_view trade`)
trade.view = true
-- Escape closes the window (its close button's ESCAPE): no side windows
trade.escape_keys = {}

local FILE = "interface/trade_view.gui"
local V = "/trade_view"

-- the categories in their order (ETradeCategory; GFX_trade_cat_KEY, the title's key)
local CATEGORIES = {
    { key = "resources", title = "TRADE_CATEGORY_RESOURCES" },
    { key = "transfer_control", title = "TRADE_CATEGORY_TRANSFER_CONTROL" },
    { key = "transfer_leader", title = "TRADE_CATEGORY_TRANSFER_LEADER" },
    { key = "transfer_fleet", title = "TRADE_CATEGORY_TRANSFER_FLEET" },
    { key = "action", title = "TRADE_CATEGORY_TRADABLE_ACTION" },
    { key = "sensor", title = "tc_sensor" },
    { key = "loyalty", title = "TRADE_CATEGORY_LOYALTY", flat = true },
    { key = "specimens", title = "specimens" },
    { key = "join_war", title = "TRADE_CATEGORY_JOIN_WAR" },
    { key = "leave_war", title = "TRADE_CATEGORY_LEAVE_WAR" },
    { key = "allow_to_leave_war", title = "TRADE_CATEGORY_ALLOW_TO_LEAVE_WAR" },
}

-- the categories a country can give, with their items: the resources (tradable, in its stockpile)
-- [I: the others' items (systems, leaders, fleets, agreements, information, loyalty, specimens,
-- wars) not evaluated: not shown]
local function categories(world, tradable, c)
    local res = {}
    for k, v in world.statements(world.path(c, "modules", "standard_economy_module", "resources") or {}) do
        if tradable[k] and (tonumber(v) or 0) > 0 then
            res[#res + 1] = { key = k, stock = tonumber(v) }
        end
    end
    return { resources = #res > 0 and res or nil }
end

function trade.extract(game_dir)
    local world = require("engine.world")
    local galaxy = require("render.galaxy")
    local market = require("render.windows.market")
    local cid = require("render.topbar").player()
    local c = world.object("country", cid)
    local out = { country = cid, contacts = {} }
    if not c then
        return out
    end
    local tradable = {}
    for _, r in ipairs(market.definitions(game_dir).resources) do
        if r.tradable then
            tradable[r.key] = true
        end
    end
    out.name = galaxy.name_block(world.field(c, "name"))
    out.categories = categories(world, tradable, c)
    -- the countries met (relations_manager: contact = yes)
    local rm = world.field(c, "relations_manager")
    for _, r in ipairs(rm and world.fields(rm, "relation") or {}) do
        local other = type(r) == "table" and tonumber(world.field(r, "country"))
        local oc = other and world.object("country", other)
        if oc and world.field(r, "contact") == "yes" then
            out.contacts[#out.contacts + 1] = {
                id = other, name = galaxy.name_block(world.field(oc, "name")),
                communications = world.field(r, "communications") == "yes",
                categories = categories(world, tradable, oc),
            }
        end
    end
    return out
end

-- a comma list of the state as a set and its order
local function set_of(s)
    local set, order = {}, {}
    for x in tostring(s or ""):gmatch("[^,]+") do
        set[x] = true
        order[#order + 1] = x
    end
    return set, order
end

-- the list with x toggled in or out, as a state value
local function toggled(order, set, x)
    local out = {}
    for _, y in ipairs(order) do
        if y ~= x then
            out[#out + 1] = y
        end
    end
    if not set[x] then
        out[#out + 1] = x
    end
    return table.concat(out, ",")
end

-- The clicks (CTradeView [V], docs/windows/economy.md): a category's button opens or closes its
-- items (several open at once; state open_offer / open_demands: the category keys); an item's
-- button puts it in the side's offer list or takes it out (offer / demands: the items, "res:KEY"),
-- its button then in its active frame; an offered resource's - and + change its amount (state
-- amt_SIDE_KEY [I: a step of 1, the game's 10, 100 and 1000 with control and shift not read; the
-- start 0]), its close button takes it out; Propose, with something offered, posts the proposal
-- (CDiploActionProposeCommand [not done here: the AI's answer]) and closes the window as the
-- game does; Cancel and the close button close it (the deal cleared).
function trade.build(ctx, data, state)
    local names = require("render.names")
    data = data or {}
    state = state or {}
    local loc = ctx.loc
    local recipient
    for _, k in ipairs(data.contacts or {}) do
        if tostring(k.id) == state.country then
            recipient = k
        end
    end
    local wide = ctx.screen.width > 1470
    local hide, texts, actions, disabled, sizes, positions = {}, {}, {}, {}, {}, {}
    actions[V .. "/close"] = "view_close"
    actions[V .. "/cancel_button"] = "view_close"
    local offered = {}
    offered.offer = { set_of(state.offer) }
    offered.demands = { set_of(state.demands) }
    if #offered.offer[2] + #offered.demands[2] > 0 then
        actions[V .. "/confirm_button"] = "economy:trade_propose:" .. tostring(state.country)
    else
        -- (an empty deal is not proposable: ACTION_OFFER_TRADE_DEAL_EMPTY)
        disabled[V .. "/confirm_button"] = true
    end
    texts[V .. "/actor_name"] = data.name and names.format(loc, data.name) or ""
    texts[V .. "/recipient_name"] = recipient and recipient.name and names.format(loc, recipient.name) or ""
    -- (the recipient's ruler's portrait not drawn; the AI's acceptance and willingness not
    -- evaluated: not shown)
    for _, n in ipairs({ "portrait_room", "portrait_character", "their_satisfaction", "trade_willingness", "trade_willingness_value", "trade_deal_length", "trade_offer_edit_window" }) do
        hide[V .. "/" .. n] = true
    end
    local tab = state.tab == "demands" and "demands" or "offer"
    if wide then
        sizes[V] = { 1470, 640 }
        sizes[V .. "/diplo_trade_view_background_window"] = { 1470, 640 }
        positions[V .. "/demands_trade_categories_window"] = { 1220, 10 }
        for _, n in ipairs({ "offer_tab", "offer_tab_active", "demand_tab", "demand_tab_active" }) do
            hide[V .. "/" .. n] = true
        end
    else
        hide[V .. (tab == "offer" and "/offer_tab" or "/offer_tab_active")] = true
        hide[V .. (tab == "offer" and "/demand_tab_active" or "/demand_tab")] = true
        hide[V .. (tab == "offer" and "/demands_trade_categories_window" or "/offer_trade_categories_window")] = true
        actions[V .. "/offer_tab"] = "view_set:tab=offer"
        actions[V .. "/demand_tab"] = "view_set:tab=demands"
    end
    local items, report = gui.layout(ctx.game_dir, ctx.db, FILE, "trade_view", ctx.screen, {
        texture_size = ctx.texture_size, loc = loc, hide = hide, text = texts, actions = actions,
        disabled = disabled, sizes = sizes, positions = positions,
    })
    local function layout(window, prefix, x, y, spec)
        spec.texture_size, spec.loc, spec.prefix = ctx.texture_size, loc, prefix
        spec.parent = { x = x, y = y, w = 0, h = 0 }
        local ok, it, rp = pcall(gui.layout, ctx.game_dir, ctx.db, FILE, window, ctx.screen, spec)
        if ok then
            gui.merge(items, report, it, rp)
        end
    end
    local function resource_name(key)
        return "£" .. key .. "£ " .. ((loc and loc.has(key)) and loc.get(key) or key)
    end
    -- each side's categories down its list: trade_category_entry, 64 high, the list's spacing
    -- -18 [V gui]; an open one's items under it, trade_item_entry 32 high [I: their spacing]
    for _, side in ipairs({
        { "offer_trade_categories_window", data.categories, "offer" },
        { "demands_trade_categories_window", recipient and recipient.categories, "demands" },
    }) do
        local list = report.rects[V .. "/" .. side[1] .. "/trade_categories_list"]
        local open_set, open_order = set_of(state["open_" .. side[3]])
        local off_set, off_order = offered[side[3]][1], offered[side[3]][2]
        if list and side[2] and not hide[V .. "/" .. side[1]] then
            local y = list.y
            for i, cat in ipairs(CATEGORIES) do
                local catitems = side[2][cat.key]
                if catitems then
                    local prefix = V .. "/" .. side[1] .. "/trade_categories_list/" .. i
                    local p = prefix .. "/trade_category_entry"
                    local open = open_set[cat.key]
                    layout("trade_category_entry", prefix, list.x, y, {
                        text = { [p .. "/category_title"] = cat.title },
                        sprites = { [p .. "/trade_category_icon"] = "GFX_trade_cat_" .. cat.key },
                        hide = { [p .. "/dropdown_indicator"] = cat.flat or nil },
                        actions = { [p .. "/category_button"] = "view_set:open_" .. side[3] .. "=" .. toggled(open_order, open_set, cat.key) },
                    })
                    y = y + 64 - 18
                    if open and type(catitems) == "table" then
                        for k, it in ipairs(catitems) do
                            local id = "res:" .. it.key
                            local ip = prefix .. "/" .. k
                            local q = ip .. "/trade_item_entry"
                            layout("trade_item_entry", ip, list.x + 10, y, {
                                text = { [q .. "/item_title"] = resource_name(it.key) },
                                frames = { [q .. "/item_button"] = off_set[id] and 3 or nil },
                                actions = { [q .. "/item_button"] = "view_set:" .. side[3] .. "=" .. toggled(off_order, off_set, id) },
                            })
                            y = y + 32
                        end
                    end
                end
            end
        end
        -- the side's offer list (offer_trade_offer_window / demands_trade_offer_window): an
        -- offered resource's entry with its amount
        local window = side[3] == "offer" and "offer_trade_offer_window" or "demands_trade_offer_window"
        local olist = report.rects[V .. "/" .. window .. "/trade_offer_list"]
        if olist then
            local y = olist.y + 5
            for k, id in ipairs(off_order) do
                local key = id:match("^res:(.+)$")
                if key then
                    local ip = V .. "/" .. window .. "/trade_offer_list/" .. k
                    local q = ip .. "/trade_offer_editable_item_entry"
                    local akey = "amt_" .. side[3] .. "_" .. key
                    local amount = tonumber(state[akey]) or 0
                    layout("trade_offer_editable_item_entry", ip, olist.x, y, {
                        text = { [q .. "/item_name"] = resource_name(key), [q .. "/value"] = tostring(amount) },
                        actions = {
                            [q .. "/close_button"] = "view_set:" .. side[3] .. "=" .. toggled(off_order, off_set, id),
                            [q .. "/value_minus"] = "view_set:" .. akey .. "=" .. math.max(0, amount - 1),
                            [q .. "/value_plus"] = "view_set:" .. akey .. "=" .. (amount + 1),
                        },
                    })
                    y = y + 56
                end
            end
        end
    end
    return items, report
end

return trade

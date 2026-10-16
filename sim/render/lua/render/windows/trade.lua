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

-- the categories a country can give: the resources when it has a tradable one in its stockpile
-- [I: the others' items (systems, leaders, fleets, agreements, information, loyalty, specimens,
-- wars) not evaluated: not shown]
local function categories(world, tradable, c)
    local has = false
    for k, v in world.statements(world.path(c, "modules", "standard_economy_module", "resources") or {}) do
        if tradable[k] and (tonumber(v) or 0) > 0 then
            has = true
        end
    end
    return { resources = has }
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
    disabled[V .. "/confirm_button"] = true
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
    -- each side's categories down its list: trade_category_entry, 64 high, the list's spacing
    -- -18 [V gui], collapsed
    for _, side in ipairs({ { "offer_trade_categories_window", data.categories }, { "demands_trade_categories_window", recipient and recipient.categories } }) do
        local list = report.rects[V .. "/" .. side[1] .. "/trade_categories_list"]
        if list and side[2] and not hide[V .. "/" .. side[1]] then
            local y = list.y
            for i, cat in ipairs(CATEGORIES) do
                if side[2][cat.key] then
                    local prefix = V .. "/" .. side[1] .. "/trade_categories_list/" .. i
                    local p = prefix .. "/trade_category_entry"
                    local ok, it, rp = pcall(gui.layout, ctx.game_dir, ctx.db, FILE, "trade_category_entry", ctx.screen, {
                        texture_size = ctx.texture_size, loc = loc, prefix = prefix,
                        parent = { x = list.x, y = y, w = 0, h = 0 },
                        text = { [p .. "/category_title"] = cat.title },
                        sprites = { [p .. "/trade_category_icon"] = "GFX_trade_cat_" .. cat.key },
                        hide = { [p .. "/dropdown_indicator"] = cat.flat or nil },
                    })
                    if ok then
                        gui.merge(items, report, it, rp)
                    end
                    y = y + 64 - 18
                end
            end
        end
    end
    return items, report
end

return trade

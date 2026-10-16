-- render/windows/rename.lua : the rename dialogs the empire views open (docs/windows/empire.md
-- section 12; interface/rename_dialog.gui):
--
--   rename_dialog                    CRenameDialog: the empire (CEmpireRenameDialog), a sector
--                                    (CSectorRenameDialog), a leader (CLeaderRenameDialog)
--   rename_ruler_dialog              CRulerRenameDialog: the ruler or the heir, with the titles
--   rename_council_position_dialog   CCouncilPositionRenameDialog: the councillor and the position's
--                                    titles
--
-- The dialog is the view's state: rename = KIND:ID (country, sector, leader, ruler, heir,
-- position), rn_name / rn_male / rn_female the edit boxes' texts, rn_orig* what they started with,
-- rn_focus the box with the keyboard (UpdateEditBox: the name's box takes the focus). The texts are
-- kept percent-encoded (the state's actions are `view_set:K=V;...` and `cmd:...:ARG#...`).
-- A key typed goes to the focused box (views.rs: the view's text_key), cut to 32 characters
-- (OnEditboxChange); OK (RETURN) runs the view's command `rename` and closes the dialog, Cancel
-- (ESCAPE) closes it.

local C = require("render.windows.empire_common")

local R = {}

local FILE = "interface/rename_dialog.gui"
R.KEYS = { "rename", "rn_name", "rn_male", "rn_female", "rn_orig", "rn_orig_male", "rn_orig_female", "rn_focus", "rn_gender" }

-- a text percent-encoded for the state and the command's arguments, and decoded
function R.enc(s)
    return (tostring(s or ""):gsub("[%%:;#=|,%c]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

function R.dec(s)
    return (tostring(s or ""):gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

-- the action that opens the dialog for KIND:ID with its boxes' texts (the names as shown):
-- name, and for the ruler, the heir and a position the male and female titles (gender: whether
-- the female box shows)
function R.open(kind, id, name, male, female, gender)
    local p = {
        "rename=" .. kind .. ":" .. id,
        "rn_name=" .. R.enc(name), "rn_orig=" .. R.enc(name),
        "rn_focus=name",
    }
    if male then
        p[#p + 1] = "rn_male=" .. R.enc(male)
        p[#p + 1] = "rn_orig_male=" .. R.enc(male)
        p[#p + 1] = "rn_female=" .. R.enc(female or male)
        p[#p + 1] = "rn_orig_female=" .. R.enc(female or male)
        p[#p + 1] = "rn_gender=" .. (gender and "1" or "")
    end
    return "view_set:" .. table.concat(p, ";")
end

-- the dialog's state cleared
function R.close_action()
    local p = {}
    for _, k in ipairs(R.KEYS) do
        p[#p + 1] = k .. "="
    end
    return "view_set:" .. table.concat(p, ";")
end

local function utf8_len(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

-- the first n characters of a UTF-8 text
local function utf8_sub(s, n)
    local out, count = {}, 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        count = count + 1
        if count > n then
            break
        end
        out[#out + 1] = ch
    end
    return table.concat(out)
end

-- the boxes of the open dialog, in Tab order
local function boxes(state)
    local kind = (state.rename or ""):match("^([^:]+)")
    if kind == "ruler" or kind == "heir" or kind == "position" then
        local l = { "name", "male" }
        if state.rn_gender == "1" then
            l[#l + 1] = "female"
        end
        return l
    end
    return { "name" }
end

-- OK: the view's command with the texts (an unchanged box's text as `-`: the original name kept,
-- CRenameDialog::GetName) and the dialog closed
function R.accept_action(view, state)
    local kind, id = (state.rename or ""):match("^([^:]+):(.+)$")
    if not kind then
        return nil
    end
    local function arg(k, orig)
        local v = state["rn_" .. k] or ""
        return v == (state[orig] or "") and "-" or (v == "" and "~" or v)
    end
    return "cmd:" .. view .. ":rename:" .. kind .. ":" .. id .. ":" .. arg("name", "rn_orig") .. ":"
        .. arg("male", "rn_orig_male") .. ":" .. arg("female", "rn_orig_female") .. "#" .. R.close_action():sub(10)
end

-- whether OK may be pressed (CRenameDialog::CanRename: the name not empty; the position's and the
-- ruler's titles not empty)
function R.can_accept(state)
    for _, k in ipairs(boxes(state)) do
        if (state["rn_" .. k] or "") == "" then
            return false
        end
    end
    return true
end

-- views.rs: whether a text box of the view has the keyboard
function R.focus(state)
    return state.rename ~= nil and state.rename ~= ""
end

-- views.rs: a key typed (`text:C` a character, `key:NAME` an editing key) into the focused box:
-- the state's pairs to set and an action, or nil (the key not taken: ESCAPE goes to the view's
-- Escape, which closes the dialog)
function R.key(view, state, key)
    if not R.focus(state) then
        return nil
    end
    local f = state.rn_focus or "name"
    local cur = R.dec(state["rn_" .. f] or "")
    local verb, arg = key:match("^(%a+):(.*)$")
    if verb == "text" then
        cur = utf8_sub(cur .. arg, 32)
        return { ["rn_" .. f] = R.enc(cur) }
    elseif verb == "key" then
        if arg == "backspace" then
            cur = utf8_sub(cur, math.max(0, utf8_len(cur) - 1))
            return { ["rn_" .. f] = R.enc(cur) }
        elseif arg == "tab" then
            local l = boxes(state)
            for i, k in ipairs(l) do
                if k == f then
                    return { rn_focus = l[i % #l + 1] }
                end
            end
            return { rn_focus = "name" }
        elseif arg == "return" then
            if R.can_accept(state) then
                return {}, R.accept_action(view, state)
            end
            return {}
        elseif arg == "escape" then
            return nil
        end
    end
    return {}
end

-- the dialog drawn over the view (centred: the window's orientation and origo `center`)
function R.build(b, ctx, view, state, title)
    if not R.focus(state) then
        return
    end
    local kind = (state.rename or ""):match("^([^:]+)")
    local window, W = "rename_dialog", "/rename_dialog/"
    if kind == "ruler" or kind == "heir" then
        window, W = "rename_ruler_dialog", "/rename_ruler_dialog/"
    elseif kind == "position" then
        window, W = "rename_council_position_dialog", "/rename_council_position_dialog/"
    end
    local hide = { RandomizeButton = true }
    local text = {}
    -- the title (SetTitle): the empire's, a sector's, a leader's; the ruler's or heir's
    -- (RENAME_RULER_TITLE with $DESC$); the council position's is the .gui's
    title = title or ({ country = "RENAME_EMPIRE_TITLE", sector = "RENAME_SECTOR_TITLE", leader = "RENAME_LEADER_TITLE" })[kind]
    if not title and (kind == "ruler" or kind == "heir") then
        title = C.raw(ctx, "RENAME_RULER_TITLE"):gsub("%$DESC%$", (C.loc(ctx, kind == "heir" and "HEIR" or "RULER"):gsub("%%", "%%%%")))
    end
    if title then
        text[W .. "title"] = title
    end
    if kind == "ruler" or kind == "heir" then
        -- (CRulerRenameDialog::Update: HEIR_TITLE / RULER_TITLE by gender)
        text[W .. "title_male_label"] = kind == "heir" and "HEIR_TITLE_MALE" or "RULER_TITLE_MALE"
        text[W .. "title_female_label"] = kind == "heir" and "HEIR_TITLE_FEMALE" or "RULER_TITLE_FEMALE"
    elseif kind == "position" then
        text[W .. "title_male_label"] = state.rn_gender == "1" and "RENAME_COUNCILOR_TITLE_MALE" or "RENAME_COUNCILOR_TITLE_INDETERMINABLE"
    end
    if (kind == "ruler" or kind == "heir" or kind == "position") and state.rn_gender ~= "1" then
        hide.title_female_label = true
        hide.editbox_title_female = true
    end
    local ok = R.can_accept(state)
    local r = b:add(FILE, window, {
        hide = hide, text = text,
        disabled = not ok and { [W .. "AgreeButton"] = true } or nil,
        actions = {
            [W .. "DeclineButton"] = R.close_action(),
            [W .. "AgreeButton"] = ok and R.accept_action(view, state) or nil,
        },
    })
    -- the edit boxes: their texture (small_tiles_dialog), the text (the focused one with its caret),
    -- a click giving the box the keyboard
    local BOX = { name = "editbox", male = "editbox_title_male", female = "editbox_title_female" }
    for _, k in ipairs(boxes(state)) do
        local rect = r.rects[W .. BOX[k]]
        if rect then
            b:texture(W .. BOX[k] .. "/bg", "gfx/interface/tiles/small_tiles_dialog.dds", rect.x, rect.y, rect.w, rect.h)
            local s = R.dec(state["rn_" .. k] or "")
            if (state.rn_focus or "name") == k then
                s = s .. "|"
            end
            b.items[#b.items + 1] = {
                kind = "text", path = W .. BOX[k] .. "/text", font = "malgun_goth_24", text = s,
                spans = { { text = s, colour = { 1, 1, 1 } } }, x = rect.x + 4, y = rect.y, w = rect.w - 8, h = rect.h,
                format = "left", valign = "center", fixed = true,
            }
            local inv = ctx.db.sprites.GFX_invisible
            if inv and inv.texture then
                b.items[#b.items + 1] = {
                    kind = "sprite", path = W .. BOX[k] .. "/hit", sprite = "GFX_invisible", texture = inv.texture,
                    sprite_kind = "spriteType", frame = 1, frames = inv.frames or 1, x = rect.x, y = rect.y, w = rect.w, h = rect.h,
                    button = { name = BOX[k], action = "view_set:rn_focus=" .. k },
                }
            end
        end
    end
end

-- the hooks a view with the dialog takes (M.text_focus, M.text_key, its Escape keys)
function R.install(M, view)
    M.text_focus = R.focus
    M.text_key = function(state, key)
        return R.key(view, state, key)
    end
    local keys = M.escape_keys or {}
    for _, k in ipairs(R.KEYS) do
        keys[#keys + 1] = k
    end
    M.escape_keys = keys
    -- Escape with the dialog open: the dialog closed first (its DeclineButton: shortcut ESCAPE)
    local escape = M.escape
    M.escape = function(state)
        if R.focus(state) then
            return R.close_action()
        end
        return escape and escape(state) or nil
    end
end

return R

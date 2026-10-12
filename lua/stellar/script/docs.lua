-- docs.lua : the game's own documentation of its script engine.
--
-- Stellaris writes it when it starts (CGameApplication::PrintScriptingDocumentation), to
-- Documents\Paradox Interactive\Stellaris\logs\script_documentation: triggers.log, effects.log,
-- scopes.log (scope links: owner, capital_scope, ...), modifiers.log, localizations.log. An entry
-- of the first three is a paragraph:
--
--   name - description
--   <syntax lines, optional>
--   Supported Scopes: country ship fleet      (or "all")
--   Output Scope: planet                      (scopes.log only)
--
--   local docs = require("stellar.script.docs")
--   local d = docs.read(dir)   -- default: the directory above
--   d.triggers[name], d.effects[name], d.scopes[name] -> { name, description, syntax, scopes, output }
--   d.modifiers[name] -> category

local docs = {}

function docs.directory()
    local profile = os.getenv("USERPROFILE") or ""
    return profile .. "\\Documents\\Paradox Interactive\\Stellaris\\logs\\script_documentation"
end

local function read_file(path)
    local f = io.open(path, "rb")
    if f == nil then
        return nil
    end
    local text = f:read("*a")
    f:close()
    return (text:gsub("\r\n", "\n"))
end

local function split_words(s)
    local list = {}
    for w in s:gmatch("%S+") do
        list[#list + 1] = w
    end
    return list
end

-- The entries of triggers.log, effects.log or scopes.log: name -> entry, and the names in order.
-- After the log header and the "== X DOCUMENTATION ==" line (and, in scopes.log, an introduction),
-- an entry starts with a "name - description" line after a blank line and runs to the next one: its
-- syntax can contain blank lines. The files end with a "=====" line.
local function parse_entries(text)
    local body = text:match("DOCUMENTATION ==\n(.*)$") or text
    local by_name, order = {}, {}
    local current, blank = nil, true
    local function finish()
        if current then
            current.syntax = table.concat(current.syntax, "\n"):gsub("%s+$", "")
            current = nil
        end
    end
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        local name, description = line:match("^([%w_:%.@]+) %- (.*)$")
        if name and blank then
            finish()
            current = { name = name, description = description, syntax = {} }
            if by_name[name] == nil then
                order[#order + 1] = name
            end
            by_name[name] = current
        elseif line:match("^=+$") then
            finish()
        elseif current then
            local scopes = line:match("^Supported Scopes:%s*(.*)$")
            local output = line:match("^Output Scope:%s*(.*)$")
            local targets = line:match("^Supported Targets:%s*(.*)$")
            if scopes then
                current.scopes = split_words(scopes)
            elseif output then
                current.output = output
            elseif targets then
                current.targets = split_words(targets)
            elseif current.scopes == nil then
                current.syntax[#current.syntax + 1] = line
            end
        end
        blank = line == ""
    end
    finish()
    -- the introduction of scopes.log has no "Supported Scopes" line
    for i = #order, 1, -1 do
        local e = by_name[order[i]]
        if e.scopes == nil and e.output == nil and e.syntax == "" and e.description == "" then
            by_name[order[i]] = nil
            table.remove(order, i)
        end
    end
    return by_name, order
end

-- docs.read([dir]) -> docs | nil, message
function docs.read(dir)
    dir = dir or docs.directory()
    local d = {}
    for _, kind in ipairs({ "triggers", "effects", "scopes" }) do
        local text = read_file(dir .. "\\" .. kind .. ".log")
        if text == nil then
            return nil, "cannot read " .. dir .. "\\" .. kind .. ".log"
        end
        d[kind], d[kind .. "_order"] = parse_entries(text)
    end
    d.modifiers, d.modifiers_order = {}, {}
    local text = read_file(dir .. "\\modifiers.log")
    if text then
        for name, category in text:gmatch("\n%- ([%w_]+), Category: ([^\n]*)") do
            d.modifiers[name] = category
            d.modifiers_order[#d.modifiers_order + 1] = name
        end
    end
    return d
end

return docs

-- records.lua : a database's definitions read from the game's files, as records: the
-- representation the in-game builder (dbbuild.lua) and the simulation both read. Nothing here
-- touches the game's memory; it runs the same in the game, in the simulation and offline.
--
--   local recs, errors = records.read(game_dir, schema)
--   recs[i] = { index = i - 1, key = "dark_brown", file = "common/named_colors/00_basic_colors.txt",
--               line = 4, fields = { color = { r, g, b, a } } }
--
-- The order and the rules are the game's (TSingleObjectGameDatabase<...>::Init / LoadFile /
-- LoadFromReader, 4.5.2):
--   - the folder's .txt files in name order;
--   - each top-level statement `key = { ... }` is an object, numbered in order of first
--     appearance (_Index, its place in _Array);
--   - `inline_script = ...` at the top level is expanded in place (CreateInlineScriptReader);
--   - a key seen before (ReadExistingEntry): the object is made again at its index from the later
--     block (TSingleObjectGameDatabase), or the later block is read into it (schema.kind
--     "extendable", TExtendableObjectGameDatabase);
--   - anything else at the top level is the game's "Expected format is key={" error.
-- In an object's block (CPersistent::Read -> T::ReadMember(reader, token)), each statement whose key
-- is a field of the schema is read by the field's type; a later one replaces an earlier one; an
-- unknown key is the game's "Unexpected token" error.

local ffi = require("ffi")
local source = require("stellar.script.source")

local records = {}

local f32 = ffi.new("float[1]")
local function float(x)
    f32[0] = x
    return f32[0]
end
records.float = float

-- The value readers: script value (a pdxscript token or block) -> the field's value, or nil and an error

local readers = {}
records.readers = readers

-- CReader::Read(CColor&) (Linux 0x42e9ee0 inlined in CNamedColor::ReadMember 0x1db73f0): a
-- number token is a hex RGBA (CToken::ReadHexValue, CColor::SetRGBA); a block is 3 or 4 numbers,
-- each above 1.0 multiplied by 1/255 (as floats), the alpha 1.0 when there are 3.
local INV255 = float(1 / 255)
function readers.color(v)
    if v.text then
        local hex = v.text:match("^0[xX](%x+)$") or v.text:match("^(%x+)$")
        if not hex then
            return nil, "Malformed token"
        end
        local u = tonumber(hex, 16)
        -- SetRGBA(u): r in the high byte
        return { float(bit.band(bit.rshift(u, 24), 255) / 255), float(bit.band(bit.rshift(u, 16), 255) / 255),
            float(bit.band(bit.rshift(u, 8), 255) / 255), float(bit.band(u, 255) / 255) }
    end
    if v.type then
        return nil, "Malformed token" -- rgb { } / hsv { }: not a number after the '='
    end
    local c = {}
    for _, e in ipairs(v) do
        if not e.text then
            return nil, "Malformed token"
        end
        local x = tonumber(e.text)
        if x == nil then
            return nil, "Malformed token"
        end
        x = float(x)
        if x > 1.0 then
            x = float(x * INV255)
        end
        c[#c + 1] = x
    end
    if #c < 3 or #c > 4 then
        return nil, "Malformed token"
    end
    c[4] = c[4] or 1.0
    return c
end

function readers.string(v)
    if v.text == nil then
        return nil, "expected a string"
    end
    return v.text
end

function readers.int(v)
    local x = v.text and tonumber(v.text)
    if x == nil then
        return nil, "expected a number"
    end
    return math.floor(x)
end

function readers.bool(v)
    if v.text == "yes" then
        return true
    elseif v.text == "no" then
        return false
    end
    return nil, "expected yes or no"
end

-- a script member (a trigger, an effect, a script value, a weight): the record keeps the statement
-- itself (its tree, with its file and lines); what it means is not decided here (the simulation
-- evaluates the tree in Lua, the in-game builder has the game compile it)
function readers.script(v, f, old, statement, file)
    local out = { file = file }
    for _, s in ipairs(old or {}) do
        out[#out + 1] = s -- the same key again: the game reads it into the same member
    end
    out[#out + 1] = statement
    return out
end

-- the text of a file the records were read from (for script members: their exact lines)
local texts = {}
function records.file_text(game_dir, file)
    local t = texts[file]
    if t == nil then
        local fs = source.filesystem(game_dir)
        local path = fs:path(file)
        local h = path and io.open(path, "rb")
        t = h and h:read("*a") or false
        if h then
            h:close()
        end
        texts[file] = t
    end
    return t or nil
end

-- a word the game keeps as its token id (CReader + 0x278: the value's lexer token): the record
-- keeps the word, the builder asks the game's lexer for the id
function readers.token(v)
    if v.text == nil then
        return nil, "expected a word"
    end
    return v.text
end

-- a block of yes/no members (a CPersistent struct of bools read by CReader::Read(CPersistent&),
-- e.g. SBehaviour): { [key] = true/false }; the keys are checked against the field's members. A
-- second block reads into the same struct (old: what the first one set).
function readers.flags(v, f, old)
    if v.text then
        return nil, "expected a block"
    end
    local out = {}
    for k, x in pairs(old or {}) do
        out[k] = x
    end
    for _, e in ipairs(v) do
        if not (e.op and e.key) then
            return nil, "Malformed token"
        end
        local key = e.key.text
        if f.members[key] == nil then
            return nil, "Unexpected token " .. key
        end
        local b, err = readers.bool(e.value)
        if b == nil then
            return nil, err
        end
        out[key] = b
    end
    return out
end

-- the top-level statements of the folder, inline scripts expanded, in order
local function statements(fs, folder, errors)
    local out = {}
    for _, file in ipairs(source.files(fs, folder, "txt")) do
        local tree, message = source.parse(fs, file)
        if tree == nil then
            errors[#errors + 1] = message
        else
            local block = source.expand(fs, tree, errors) or tree
            for _, e in ipairs(block) do
                out[#out + 1] = { entry = e, file = file }
            end
        end
    end
    return out
end

-- records.read(game_dir, schema) -> recs, errors
function records.read(game_dir, schema)
    local fs = source.filesystem(game_dir)
    local errors, recs, by_key = {}, {}, {}
    local fields_by_key = {}
    for _, f in ipairs(schema.fields) do
        fields_by_key[f.key] = f
    end
    for _, s in ipairs(statements(fs, schema.folder, errors)) do
        local e = s.entry
        if schema.keys_only then
            -- KeysOnly (_Mode 1): every bare word of the file is a key, nothing is read for it
            if e.text and not by_key[e.text] then
                local r = { index = #recs, key = e.text, file = s.file, line = e.line, fields = {} }
                recs[#recs + 1] = r
                by_key[e.text] = r
            elseif not e.text then
                errors[#errors + 1] = string.format("%s:%d: not a key", s.file, e.line or 0)
            end
        elseif e.op == "=" and e.key and e.key.text and type(e.value) == "table" and e.value.text == nil then
            local key = e.key.text
            local r = by_key[key]
            if r == nil then
                r = { index = #recs, key = key, file = s.file, line = e.line, fields = {} }
                recs[#recs + 1] = r
                by_key[key] = r
            else
                -- ReadExistingEntry: TSingleObjectGameDatabase destroys the object and makes it again
                -- at its index (the later definition wins: "Object with key: %s already exists, using
                -- the one at %s"); TExtendableObjectGameDatabase reads into it (the definitions merge)
                r.duplicates = (r.duplicates or 0) + 1
                if schema.kind ~= "extendable" then
                    r.fields, r.file, r.line = {}, s.file, e.line
                    errors[#errors + 1] = string.format("Object with key: %s already exists, using the one at %s:%d",
                        key, s.file, e.line or 0)
                end
            end
            for _, m in ipairs(e.value) do
                local f = m.op and m.key and fields_by_key[m.key.text]
                if f then
                    local value, err = readers[f.type](m.value, f, r.fields[f.name], m, s.file)
                    if value == nil then
                        errors[#errors + 1] = string.format("%s:%d: %s: %s", s.file, m.line or 0, m.key.text, err)
                    else
                        r.fields[f.name] = value
                    end
                elseif m.op and m.key then
                    errors[#errors + 1] = string.format("%s:%d: Unexpected token %s", s.file, m.line or 0, m.key.text)
                end
            end
        elseif e.op and e.key and e.key.text and e.key.text:sub(1, 1) == "@" then
            -- a scripted variable of the file: nothing to build (the fields here do not use them)
        else
            errors[#errors + 1] = string.format("%s:%d: Expected format is \"key={\"", s.file, e.line or 0)
        end
    end
    return recs, errors
end

return records

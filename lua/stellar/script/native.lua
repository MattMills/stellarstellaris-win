-- native.lua : the script the game has compiled, read back into Lua trees (docs/script_engine.md).
--
--   local native = require("stellar.script.native")
--   local n = native.new(c, read)       -- c: a catalog after a census (stellar.script.catalog)
--   local node = n:trigger(object)      -- or n:effect(object)
--
-- A node is { name, vtable, location, children, target, display, tag, args, object }: name is the
-- keyword of the trigger or effect (catalog names, lower case: "and", "has_country_flag") or a
-- structural kind ("(scope trigger)", "(scripted trigger)", "(trigger block)", ...); location is
-- where the game read it from (_FileLocationDesc); children are the nodes of a collection (and, or,
-- not, blocks, scope changes, if, iterators, every effect); target is the scope chain of a scope
-- change ("owner", "root.owner?", "event_target:x"), display the game's own text of it; tag and
-- args are those of a scripted trigger or effect call.
-- Parameters a trigger or effect reads into its own members (has_country_flag's flag, limit,
-- count, ...) are not read: their layouts differ per class.

local memory = require("stellar.script.memory")
local u64, i32 = memory.u64, memory.i32

local native = {}
native.__index = native

-- Layouts in 4.5.2 (from the PDB)
local TRIGGER_LOCATION = 0x40          -- CTrigger::_FileLocationDesc (CString)
local TRIGGER_CHILDREN = 0x78          -- CTriggerCollectionBase::_Children (CPdxArray<CTrigger *>)
local SCOPE_TRIGGER_TARGET = 0xc8      -- CContextTrigger::_pTarget (CEventTarget *)
local SCRIPTED_TRIGGER = { args = 0x80, tag = 0x98, body = 0xd0 }
local EFFECT_CHILDREN = 0x8            -- CEffect is a CPdxArray<CEffect *>
local EFFECT_LOCATION = 0x28           -- CEffect::_FileLocationDesc
local SCOPE_EFFECT_TARGET = 0xc8       -- CContextEffect::_pTarget
local SCRIPTED_EFFECT = { args = 0xc8, tag = 0xe0, body = 0x118 }
-- if / else_if / else: CIfEffect keeps its else block in an embedded CEffect (_Else) and the next
-- else_if in _pElse; CIfTrigger keeps its limit in an embedded CAndTrigger (_DisplayTrigger) and
-- the next else_if / else in _pElse
local IF_EFFECT = { else_block = 0x180, next = 0x240 }
local IF_TRIGGER = { limit = 0xc0, next = 0x180 }
local IF_NAMES = { ["if"] = true, ["else_if"] = true, ["else"] = true }
-- CEventTarget: _DynamicFlag, _TokenString, _Token (its id), _pNext, _IsNullable
local EVENT_TARGET = { flag = 0x0, text = 0x30, token = 0x68, next = 0x188, nullable = 0x199, size = 0x1a0 }
local MAX_DEPTH = 64

-- triggers whose objects are collections, to learn the vtable of CPdxArray<CTrigger *> from
local COLLECTIONS = { ["and"] = true, ["or"] = true, ["not"] = true, ["nor"] = true, ["nand"] = true,
    ["(trigger block)"] = true, ["(scope trigger)"] = true }

function native.new(c, read)
    return setmetatable({ c = c, read = read, r = memory.strict(read) }, native)
end

-- The name of an object, by its vtable (catalog entries, then the structural classes of a census).
function native:name(object)
    local b = self.read(object, 8)
    if b == nil then
        return nil
    end
    local vtable = u64(b, 0)
    local e = self.c.by_vtable[vtable]
    if e then
        return e.name, vtable
    end
    return self.c.structural and self.c.structural[vtable] or nil, vtable
end

-- The scope chain of a CEventTarget, from its links (_pNext): text (`owner.ruler?`,
-- `event_target:x.species`), and the game's own _TokenString of the first link, which is display
-- text (it drops the `?` of chains and repeats the last link of event targets). A link is its token
-- (_Token: id at +0x68), a dynamic name (_DynamicFlag at +0: the x of event_target:x) and
-- _IsNullable (+0x199: the `?`).
function native:target(event_target)
    if event_target == 0 then
        return nil
    end
    local display = memory.cstring_object(self.read, event_target + EVENT_TARGET.text)
    local links, saved = {}, false
    while event_target ~= 0 and #links < 16 do
        local b = self.read(event_target, EVENT_TARGET.size)
        if b == nil then
            break
        end
        local name = self.c.tokens[i32(b, EVENT_TARGET.token)]
        local flag = memory.cstring_object(self.read, event_target + EVENT_TARGET.flag)
        local link
        if name == nil then
            -- a saved event target (event_target:x, event_target:x@root.owner) has no token: its
            -- name is in the game's table of saved targets (_SavedEventTarget)
            saved = saved or #links == 0
            link = "?"
        elseif flag and flag ~= "" then
            link = name .. ":" .. flag
        else
            link = name
        end
        if memory.u8(b, EVENT_TARGET.nullable) ~= 0 then
            link = link .. "?"
        end
        links[#links + 1] = link
        event_target = u64(b, EVENT_TARGET.next)
    end
    if saved and display then
        -- the display text is the chain as written, then the following links again: without them,
        -- it is the chain
        local rest = table.concat(links, ".", 2):gsub("%?", "")
        if rest ~= "" and display:sub(-#rest - 1) == "." .. rest then
            return display:sub(1, -#rest - 2), display
        end
        return display, display
    end
    return table.concat(links, "."), display
end

local function pointer_at(self, address)
    local b = self.read(address, 8)
    return b and u64(b, 0) or 0
end

function native:trigger(object, depth)
    depth = depth or 0
    local name, vtable = self:name(object)
    local node = { object = object, name = name or "?", vtable = vtable,
        location = memory.cstring_object(self.read, object + TRIGGER_LOCATION) }
    -- a collection keeps the vtable of CPdxArray<CTrigger *> at +0x78
    local array_vtable = pointer_at(self, object + TRIGGER_CHILDREN)
    if self.children_vtable == nil and COLLECTIONS[name] then
        self.children_vtable = array_vtable
    end
    if name == "(scope trigger)" then
        node.target, node.display = self:target(pointer_at(self, object + SCOPE_TRIGGER_TARGET))
    elseif name == "(scripted trigger)" then
        node.tag = memory.cstring_object(self.read, object + SCRIPTED_TRIGGER.tag)
        local b = self.read(object + SCRIPTED_TRIGGER.args + 20, 4)
        node.args = b and i32(b, 0) or 0
        node.body = pointer_at(self, object + SCRIPTED_TRIGGER.body)
    end
    if self.children_vtable and array_vtable == self.children_vtable and depth < MAX_DEPTH then
        node.children = {}
        for i, child in ipairs(memory.pointer_array(self.read, object + TRIGGER_CHILDREN, 100000) or {}) do
            node.children[i] = self:trigger(child, depth + 1)
        end
    end
    if IF_NAMES[name] and depth < MAX_DEPTH then
        node.limit = self:trigger(object + IF_TRIGGER.limit, depth + 1)
        local next_if = pointer_at(self, object + IF_TRIGGER.next)
        node.next = next_if ~= 0 and self:trigger(next_if, depth + 1) or nil
    end
    return node
end

function native:effect(object, depth)
    depth = depth or 0
    local name, vtable = self:name(object)
    local node = { object = object, name = name or "?", vtable = vtable,
        location = memory.cstring_object(self.read, object + EFFECT_LOCATION) }
    if name == "(scope effect)" then
        node.target, node.display = self:target(pointer_at(self, object + SCOPE_EFFECT_TARGET))
    elseif name == "(scripted effect)" then
        node.tag = memory.cstring_object(self.read, object + SCRIPTED_EFFECT.tag)
        local b = self.read(object + SCRIPTED_EFFECT.args + 20, 4)
        node.args = b and i32(b, 0) or 0
        node.body = pointer_at(self, object + SCRIPTED_EFFECT.body)
    end
    if depth < MAX_DEPTH then
        local children = memory.pointer_array(self.read, object + EFFECT_CHILDREN, 100000)
        if children and #children > 0 then
            node.children = {}
            for i, child in ipairs(children) do
                node.children[i] = self:effect(child, depth + 1)
            end
        end
        if IF_NAMES[name] then
            -- the else block is an embedded CEffect: its children are those of the else
            local else_children = memory.pointer_array(self.read, object + IF_EFFECT.else_block + EFFECT_CHILDREN, 100000)
            if else_children and #else_children > 0 then
                node.else_children = {}
                for i, child in ipairs(else_children) do
                    node.else_children[i] = self:effect(child, depth + 1)
                end
            end
            local next_if = pointer_at(self, object + IF_EFFECT.next)
            node.next = next_if ~= 0 and self:effect(next_if, depth + 1) or nil
        end
    end
    return node
end

return native

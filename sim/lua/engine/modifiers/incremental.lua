-- engine/modifiers/incremental.lua : the world's modifier graph kept from one month to the next.
-- engine.modifiers.world builds it whole from the world, twice (once without the parts whose
-- multiplier is another modifier's value, then with them, read from the first build); this keeps
-- one graph and changes only what changed, to the same values (STELLAR_MODIFIER_CHECK=1 compares
-- every node with a full rebuild every month; docs/modifier_incremental.md):
--
--   local inc = require("engine.modifiers.incremental")
--   local wg = inc.new({ defs = defs })        -- defs: the graph's definitions (stellar.graph.modifiers)
--   local changed = wg:update()                -- the world as it is now -> { [holder key] = true }
--   mw.values(wg, "Country", 0)                -- read as engine.modifiers.world's graphs are
--
-- An update:
-- 1. the world's nodes and links again (engine.modifiers.structure): this month's records, the
--    links each should have;
-- 2. pass 1: every holder's parts (engine.modifiers; the source is kept, so what it read from the
--    files stays cached) without other modifiers' values, compared with the month before's, and
--    summed by type where they differ. The holders whose parts consulted src.resolve_ref
--    (src.ref_used: a `mult = modifier:x` block, a colony's stability and amenities, a job's output
--    modifier) are "reading" holders;
-- 3. pass 2: the reading holders' parts again, the values read from G1, the graph of the pass-1
--    parts (the full rebuild's first build), made only for the holders read and their parents;
--    every other holder's pass-2 parts are its pass-1 parts, as in the full rebuild (nothing else
--    in its parts depends on src.resolve_ref). The triggers evaluated in pass 1 are not evaluated
--    again (src.trigger_memo: the same world, the same answers);
-- 4. only then is the graph read outside (G2) changed: gone holders destroyed, new ones made,
--    links made again where they differ, and a holder's own values changed by the difference of
--    its sums, type by type. Until then G2 is the month before's, as the full rebuild's previous
--    graph is while it builds, so a trigger reading a modifier (check_modifier_value, through the
--    engine's modifier source) reads what it read before;
-- 5. the holders whose values changed: those with a node whose value changed (the dirty nodes
--    computed, old and new compared), and those whose set of types may have changed (one of their
--    own or a parent's appeared or vanished, or a link changed) with everything below them.
-- Both graphs are stellar.graph.core graphs under stellar.graph.modifiers trees. A holder's own
-- values are one source per type (its parts summed), so a change marks only the changed types'
-- nodes. The values are fixed-point integers in doubles: the delta updates of the sums are exact.

local core = require("stellar.graph.core")
local gmod = require("stellar.graph.modifiers")
local modifiers = require("engine.modifiers")
local structure = require("engine.modifiers.structure")

local band = require("bit").band
local clock = RUST and RUST.clock or os.clock

local M = {}

local EMPTY = setmetatable({}, { __newindex = function() error("engine.modifiers.incremental: EMPTY is read-only", 2) end })

-- the sum of a holder's parts by type id, multipliers and filters applied as
-- engine.modifiers.world's build adds them (modifiers.fold, in the parts' order), zeros left out
local function total_of(parts, defs)
    local out = {}
    for _, part in ipairs(parts) do
        for t, v in pairs(modifiers.fold(part, defs)) do
            local id = defs:id(t)
            out[id] = (out[id] or 0) + v
        end
    end
    for id, v in pairs(out) do
        if v == 0 then
            out[id] = nil
        end
    end
    return out
end

local function same_map(a, b)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    for k, v in pairs(a) do
        if b[k] ~= v then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

-- two parts lists that add the same: the same multipliers, filters and values, in order (a part's
-- values are often the source's cached table of a definition: the same table)
local function same_parts(a, b)
    if a == nil or #a ~= #b then
        return false
    end
    for i = 1, #a do
        local x, y = a[i], b[i]
        if x.mult ~= y.mult or x.filter ~= y.filter or not same_map(x.values, y.values) then
            return false
        end
    end
    return true
end

-- a holder's own values from `old` to `new` ({ [type id] = value }, no zeros), one source per
-- type -> true when a type appeared or vanished
local function apply(tree, h, old, new)
    local set_changed = false
    for id, v in pairs(new) do
        local o = old[id]
        if o ~= v then
            tree:add(h, id, { [id] = v })
            if o == nil then
                set_changed = true
            end
        end
    end
    for id in pairs(old) do
        if new[id] == nil then
            tree:remove(h, id)
            set_changed = true
        end
    end
    return set_changed
end

local I = {}
I.__index = I

-- inc.new(opts) -> wg: opts.defs (the graph's definitions), opts.world (engine.world), opts.edefs
-- (engine.defs), opts.fs (the file system), opts.src (an engine.modifiers source), opts.parts_of
-- (parts of the categories engine.modifiers does not model, as engine.modifiers.world takes)
function M.new(opts)
    local self = setmetatable({}, I)
    self.defs = assert(opts.defs, "engine.modifiers.incremental: no definitions")
    self.world = opts.world or require("engine.world")
    self.edefs = opts.edefs or require("engine.defs")
    self.src = opts.src or modifiers.new({ types = self.defs, world = self.world, defs = self.edefs, fs = opts.fs })
    self.capture_parts = opts.parts_of
    self.g1, self.g2 = core.new(), core.new()
    self.tree1, self.tree2 = gmod.new(self.g1, self.defs), gmod.new(self.g2, self.defs)
    self.tree = self.tree2       -- what mw.values reads
    -- a record per holder of the month: key ("category:owner"), cat, owner, h1 / h2 (its G1 / G2
    -- holder), links (what it should read: { rec, mult, filter }), links1 / links2 (what its G1 /
    -- G2 holder reads), parts1 / total1 (pass 1), parts2 / total2 (pass 2, reading holders),
    -- want2 (its G2 values), applied1 / applied2 (what its G1 / G2 holder has)
    self.recs = {}               -- key -> record
    self.by_cat = {}             -- category -> owner -> record
    self.by_holder = {}          -- G2 holder -> record
    self.g1recs = {}             -- the records with a G1 holder
    self.memo = {}               -- G2 holder -> its types (mw.values), dropped when they may change
    self.epoch = 0
    self.modelled = {}
    for _, c in ipairs(modifiers.CATEGORIES) do
        self.modelled[c] = true
    end
    self.stats = { updates = 0, seconds = 0 }
    self.last = {}
    local tree2 = self.tree2
    -- G2's holder (as it is: until the end of an update, the month before's)
    function self.holder(category, owner)
        return tree2:find(category, owner) or (type(owner) ~= "number" and tree2:find(category, tonumber(owner))) or nil
    end
    self.types = function(h)
        return self:types_of(h)
    end
    return self
end

-- every type a holder can have (its own and its parents' that pass the link), as
-- engine.modifiers.world's, memoized from one update to the next
function I:types_of(h)
    local memo = self.memo
    local t = memo[h]
    if t ~= nil then
        return t
    end
    t = {}
    memo[h] = t
    local cats = self.defs.cats
    for ty, v in pairs(h.values) do
        if v ~= 0 then
            t[ty] = true
        end
    end
    for _, l in ipairs(h.parents) do
        for ty in pairs(self:types_of(l.parent)) do
            if l.mask == gmod.ALL or band(cats[ty] or 0, l.mask) ~= 0 then
                t[ty] = true
            end
        end
    end
    return t
end

-- the G1 holder of a record, made when first read, with its parents' (the graph of the pass-1
-- parts only needs what is read and what that reads)
function I:h1_of(rec)
    local h = rec.h1
    if h then
        return h
    end
    h = self.tree1:holder(rec.cat, rec.owner)
    rec.h1, rec.links1, rec.applied1 = h, EMPTY, EMPTY
    self.g1recs[#self.g1recs + 1] = rec
    self:sync1(rec)
    return h
end

-- a G1 holder made like its record: its links and its pass-1 sums
function I:sync1(rec)
    local h, tree1 = rec.h1, self.tree1
    if rec.links1 ~= rec.links then
        for _, l in ipairs(rec.links1) do
            if l.rec.h1 then
                tree1:unlink(h, l.rec.h1)
            end
        end
        rec.links1 = rec.links
        for _, l in ipairs(rec.links) do
            tree1:link_fixed(h, self:h1_of(l.rec), l.mult, l.filter)
        end
    end
    if rec.applied1 ~= rec.total1 then
        apply(tree1, h, rec.applied1, rec.total1)
        rec.applied1 = rec.total1
    end
end

-- wg:update() -> { [holder key] = true }: the holders whose values may differ from before the
-- update (their cached values are stale), the new and the gone ones among them
function I:update()
    local T0 = clock()
    local s = { holders = 0, added = 0, removed = 0, relinked = 0, parts1 = 0, reading = 0, parts2 = 0, applied = 0,
        types_changed = 0, below = 0, dirty = 0, changed = 0 }
    self.epoch = self.epoch + 1
    local E = self.epoch
    local recs, by_cat, tree1, tree2, defs = self.recs, self.by_cat, self.tree1, self.tree2, self.defs
    local changed = {}
    local t = clock()
    local st = structure.new(self.world, self.edefs)
    local src = self.src
    src:refresh(st)
    s.t_structure = clock() - t

    -- 1. this month's records and their links (G2 is not changed before step 4)
    t = clock()
    local order, gone = {}, {}
    for _, n in ipairs(st:nodes()) do
        local cat, owner = n.category, n.owner
        local bc = by_cat[cat]
        if bc == nil then
            bc = {}
            by_cat[cat] = bc
        end
        local rec = bc[owner]
        if rec == nil then
            local key = cat .. ":" .. owner
            rec = { key = key, cat = cat, owner = owner, links = EMPTY, links2 = EMPTY, total1 = EMPTY, want2 = EMPTY,
                applied2 = EMPTY }
            recs[key] = rec
            bc[owner] = rec
            changed[key] = true
            s.added = s.added + 1
        end
        if rec.seen ~= E then
            rec.seen = E
            order[#order + 1] = rec
        end
    end
    s.holders = #order
    for key, rec in pairs(recs) do
        if rec.seen ~= E then
            gone[#gone + 1] = rec
            recs[key] = nil
            by_cat[rec.cat][rec.owner] = nil
            rec.dead = true
            if rec.h1 then
                tree1:destroy(rec.h1)
                rec.h1 = nil
            end
            changed[key] = true
            s.removed = s.removed + 1
        end
    end
    local function rec_of(category, owner)
        local bc = by_cat[category]
        return bc and bc[owner]
    end
    for _, rec in ipairs(order) do
        local cur, n, same = rec.links, 0, true
        local parents = st:parents(rec.cat, rec.owner)
        for _, l in ipairs(parents) do
            local p = rec_of(l.category, l.owner)
            if p then
                n = n + 1
                local c = cur[n]
                if not (c and c.rec == p and c.mult == l.mult and c.filter == l.filter) then
                    same = false
                    break
                end
            end
        end
        if same and n ~= #cur then
            same = false
        end
        if not same then
            local list = {}
            for _, l in ipairs(parents) do
                local p = rec_of(l.category, l.owner)
                if p then
                    list[#list + 1] = { rec = p, mult = l.mult, filter = l.filter }
                end
            end
            rec.links = list
            s.relinked = s.relinked + 1
        end
    end
    s.t_links = clock() - t

    local modelled, capture = self.modelled, self.capture_parts
    local function parts_of(category, owner)
        if modelled[category] then
            return src:parts(category, owner)
        end
        return capture and capture(category, owner) or nil
    end
    local ok, err = pcall(src.scripts, src, function()
        src.trigger_memo = {}
        -- 2. pass 1
        t = clock()
        src.resolve_ref = nil
        for _, rec in ipairs(order) do
            src.ref_used = false
            local parts = parts_of(rec.cat, rec.owner) or EMPTY
            rec.reading = src.ref_used
            if not same_parts(rec.parts1, parts) then
                rec.parts1 = parts
                local total = total_of(parts, defs)
                if not same_map(rec.total1, total) then
                    rec.total1 = total
                    s.parts1 = s.parts1 + 1
                end
            end
        end
        src.ref_used = false
        s.t_pass1 = clock() - t
        -- G1 follows its records
        t = clock()
        local list = self.g1recs
        self.g1recs = {}
        for _, rec in ipairs(list) do
            if not rec.dead then
                self.g1recs[#self.g1recs + 1] = rec
            end
        end
        for _, rec in ipairs(self.g1recs) do
            self:sync1(rec)
        end
        -- 3. pass 2
        src.resolve_ref = function(ref)
            local c, owner = src:ref_node(ref)
            local bc = c and owner ~= nil and by_cat[c]
            local rec = bc and (bc[owner] or (type(owner) ~= "number" and bc[tonumber(owner)]))
            if not rec then
                return nil
            end
            return tree1:get(self:h1_of(rec), ref.type)
        end
        for _, rec in ipairs(order) do
            if rec.reading then
                s.reading = s.reading + 1
                local parts = parts_of(rec.cat, rec.owner) or EMPTY
                if not same_parts(rec.parts2, parts) then
                    rec.parts2 = parts
                    local total = total_of(parts, defs)
                    if not same_map(rec.total2, total) then
                        rec.total2 = total
                        s.parts2 = s.parts2 + 1
                    end
                end
                rec.want2 = rec.total2
            else
                rec.parts2, rec.total2 = nil, nil
                rec.want2 = rec.total1
            end
        end
        self.g1:flush()
        s.t_pass2 = clock() - t
    end)
    src.resolve_ref, src.ref_used, src.trigger_memo = nil, false, nil
    if not ok then
        error(err, 0)
    end

    -- 4. G2 made like the records: gone holders destroyed, new ones made, links and values
    t = clock()
    local memo, by_holder = self.memo, self.by_holder
    local typechg = {}
    for _, rec in ipairs(gone) do
        if rec.h2 then
            tree2:destroy(rec.h2)
            memo[rec.h2] = nil
            by_holder[rec.h2] = nil
        end
    end
    for _, rec in ipairs(order) do
        if rec.h2 == nil then
            rec.h2 = tree2:holder(rec.cat, rec.owner)
            by_holder[rec.h2] = rec
            typechg[#typechg + 1] = rec
        end
    end
    for _, rec in ipairs(order) do
        local h2 = rec.h2
        if rec.links2 ~= rec.links then
            for _, l in ipairs(rec.links2) do
                tree2:unlink(h2, l.rec.h2)   -- every link of the pair (a gone parent's are gone already)
            end
            rec.links2 = rec.links
            for _, l in ipairs(rec.links) do
                tree2:link_fixed(h2, l.rec.h2, l.mult, l.filter)
            end
            typechg[#typechg + 1] = rec
        end
        if rec.want2 ~= rec.applied2 then
            if apply(tree2, h2, rec.applied2, rec.want2) then
                typechg[#typechg + 1] = rec
            end
            rec.applied2 = rec.want2
            s.applied = s.applied + 1
        end
    end
    s.t_apply = clock() - t

    -- 5. what changed: the holders whose types may have changed and all below them (their
    -- memoized types dropped), then the nodes whose value changed
    t = clock()
    local seen, stack, ns = {}, {}, 0
    for _, rec in ipairs(typechg) do
        ns = ns + 1
        stack[ns] = rec.h2
    end
    s.types_changed = ns
    while ns > 0 do
        local h = stack[ns]
        stack[ns] = nil
        ns = ns - 1
        if not seen[h] then
            seen[h] = true
            memo[h] = nil
            local rec = by_holder[h]
            if rec then
                changed[rec.key] = true
            end
            s.below = s.below + 1
            for child in pairs(h.children) do
                ns = ns + 1
                stack[ns] = child
            end
        end
    end
    local g2, owner = self.g2, tree2.owner
    local nodes, olds, k = {}, {}, 0
    g2:each_pending(core.READ, function(n)
        k = k + 1
        nodes[k], olds[k] = n, g2:peek(n)
    end)
    g2:flush()
    s.dirty = k
    for i = 1, k do
        local n = nodes[i]
        if g2:alive(n) and g2:peek(n) ~= olds[i] then
            local rec = by_holder[owner[n]]
            if rec then
                changed[rec.key] = true
            end
        end
    end
    for _ in pairs(changed) do
        s.changed = s.changed + 1
    end
    s.t_changes = clock() - t
    s.seconds = clock() - T0
    self.st = st
    self.last = s
    self.stats.updates = self.stats.updates + 1
    self.stats.seconds = self.stats.seconds + s.seconds
    return changed
end

-- a line on the last update
function I:report()
    local s = self.last
    local ms = function(x) return (x or 0) * 1000 end
    return string.format("incremental update %d: %d holders (+%d -%d, %d relinked), pass 1 changed %d, %d reading (%d changed), %d applied, "
        .. "%d in G1; types changed %d (%d holders below), %d dirty nodes, %d holders changed; %.0f ms (structure %.0f, links %.0f, pass 1 %.0f, "
        .. "pass 2 %.0f, applied %.0f, changes %.0f)",
        self.stats.updates, s.holders or 0, s.added or 0, s.removed or 0, s.relinked or 0, s.parts1 or 0, s.reading or 0, s.parts2 or 0,
        s.applied or 0, #self.g1recs, s.types_changed or 0, s.below or 0, s.dirty or 0, s.changed or 0, ms(s.seconds), ms(s.t_structure),
        ms(s.t_links), ms(s.t_pass1), ms(s.t_pass2), ms(s.t_apply), ms(s.t_changes))
end

return M

-- databases.lua : the game's databases (common/..., the 80-100% phase of the startup load).
--
-- NNullObjAndDatabaseInitUtil::SetupDatabases (called by CGameApplication::InitGame) fills a table
-- on its stack, one SDatabaseObjectFunctions per database (48 bytes): its name and the functions
-- CreateInstance, DestroyInstance, CanInitialize (or null), InitInstance and PostReadInitInstance.
-- It then initializes them, one at a time on the thread that runs it: it picks the first database
-- left whose CanInitialize (its dependencies) is true, or that has none, logs "Initializing
-- Database: <name>" (to a null logger in release builds), calls CreateInstance and InitInstance
-- (which reads the database's files), and reports progress (current of total). Then it resolves
-- the deferred key references and calls every PostReadInitInstance.
--
-- databases.locate reads that table from the code of SetupDatabases: the name and functions are
-- stored with `lea reg, [rip+x]` / `mov [rbp+d], reg` (and a register that holds zero for a null).
--
--   local databases = require("stellar.databases")
--   local where = assert(databases.locate(image, stellar.read))
--   where.entries[i] = { name, create, destroy, can_initialize, init, post_read }

local fnmatch = require("fnmatch")
local resolve = require("stellar.resolve")

local databases = {}

local ENTRY_SIZE = 48

-- the number in an operand: 50h, 0x50 or 80
local function number(text)
    local hex = text:match("^(%x+)h$") or text:match("^0x(%x+)$")
    if hex then
        return tonumber(hex, 16)
    end
    return tonumber(text)
end

-- databases.locate(image, read) -> where | nil, message: setup (SetupDatabases) and entries, in the
-- order of the table
function databases.locate(image, read)
    local setup = resolve.functions(image)["NNullObjAndDatabaseInitUtil::SetupDatabases"]
    if not setup then
        return nil, "NNullObjAndDatabaseInitUtil::SetupDatabases not found"
    end
    local f = image:function_at(setup)
    if f == nil then
        return nil, "no function at SetupDatabases"
    end
    local code = read(f.address, f.end_address - f.address)
    if code == nil then
        return nil, "cannot read SetupDatabases"
    end
    -- what the registers hold (an address or 0), and the qwords stored in the frame
    local regs, stores = {}, {}
    local pos = 1
    while pos <= #code do
        local i = fnmatch.decode(code, f.address, pos)
        if i == nil then
            pos = pos + 1
        else
            local text = i.text
            local dest, src = text:match("^mov %[rbp%+(%w+)%],(%w+)$")
            if dest then
                -- the first store to a slot: the table is built first, the frame is reused after
                local offset = number(dest)
                if regs[src] ~= nil and offset and stores[offset] == nil then
                    stores[offset] = regs[src]
                end
            else
                local reg = text:match("^lea (%w+),%[") or text:match("^mov (%w+),")
                local a, b = text:match("^xor (%w+),(%w+)$")
                if a and a == b then
                    -- a zeroed register, and the 64-bit one it is part of
                    regs[a], regs[(a:gsub("d$", ""))] = 0, 0
                elseif reg and i.rip_relative and text:match("^lea ") then
                    regs[reg] = i.target
                elseif reg then
                    regs[reg] = nil
                end
                if i.flow == "call" or i.flow == "indirect_call" then
                    -- a call clobbers the volatile registers
                    for _, r in ipairs({ "rax", "rcx", "rdx", "r8", "r9", "r10", "r11" }) do
                        regs[r] = nil
                    end
                end
            end
            pos = pos + i.length
        end
    end
    -- entries: a name (a C string) followed by the functions
    local entries, seen = {}, {}
    local offsets = {}
    for d in pairs(stores) do
        offsets[#offsets + 1] = d
    end
    table.sort(offsets)
    for _, d in ipairs(offsets) do
        local name_at, create = stores[d], stores[d + 8]
        if name_at and name_at ~= 0 and create and create ~= 0 and stores[d + 32] and not seen[d] then
            local bytes = read(name_at, 64)
            local name = bytes and bytes:match("^([%w_:]+)%z")
            if name then
                entries[#entries + 1] = { name = name, create = create, destroy = stores[d + 16],
                    can_initialize = stores[d + 24] ~= 0 and stores[d + 24] or nil,
                    init = stores[d + 32], post_read = stores[d + 40] ~= 0 and stores[d + 40] or nil }
                for k = 0, ENTRY_SIZE - 8, 8 do
                    seen[d + k] = true
                end
            end
        end
    end
    if #entries == 0 then
        return nil, "no database table in SetupDatabases"
    end
    return { setup = setup, entries = entries }
end

-- databases.follow(read, address) -> the function a thunk jumps to (`jmp x` as its first
-- instruction, followed up to 4 times), or address itself
function databases.follow(read, address)
    for _ = 1, 4 do
        local bytes = address and read(address, 16)
        local i = bytes and fnmatch.decode(bytes, address)
        if i == nil or i.flow ~= "branch" or not i.target then
            break
        end
        address = i.target
    end
    return address
end

-- Whether the function at address does nothing (its first instruction returns): calling it again
-- is harmless, so it needs no hook to be skipped
local function returns_at_once(read, address)
    local bytes = address and read(address, 16)
    local i = bytes and fnmatch.decode(bytes, address)
    return i ~= nil and i.flow == "return"
end

-- How Lua calls a function of an entry so that the game's loop will not run it again: through the
-- trampoline of its mark (the mark's skip flag is set after), or directly if it does nothing.
-- Returns the address to call and the mark, or nil and why not.
local function callable(read, address, mark)
    if mark and mark.trampoline then
        return mark.trampoline, mark
    end
    if returns_at_once(read, address) then
        return address, nil
    end
    return nil, mark and (mark.error or (mark.shared and "shared with another database")) or "not marked"
end

-- databases.run(where, progress, read) -> initialized, stopped: the loop of SetupDatabases, in
-- Lua, before the game's: the first database left (in the table's order) whose CanInitialize is
-- true, or that has none, then its CreateInstance and InitInstance, then progress (the game's
-- std::function at `progress`). Each entry has its marks (create_mark, init_mark: their
-- trampolines and skip flags, stellar.loading). The game's loop then skips what Lua did. Lua does
-- only what it can give back: at a database whose CreateInstance or InitInstance it cannot call
-- that way, the loop stops (stopped says why), and the game's loop does the rest in its order.
function databases.run(where, progress, read)
    local stellar = require("stellar")
    local left = {}
    for i = 1, #where.entries do
        left[i] = i
    end
    local total, initialized = #where.entries, 0
    while #left > 0 do
        local pick
        for k, i in ipairs(left) do
            local e = where.entries[i]
            if e.can_initialize == nil or stellar.call(e.can_initialize) % 256 ~= 0 then
                pick = k
                break
            end
        end
        if pick == nil then
            return initialized, "no database left can initialize"
        end
        local e = where.entries[left[pick]]
        local create, create_mark = callable(read, e.create, e.create_mark)
        local init, init_mark = callable(read, e.init, e.init_mark)
        if create == nil or init == nil then
            return initialized, string.format("%s: %s", e.name, tostring(create == nil and create_mark or init_mark))
        end
        if create_mark then
            stellar.mark(create_mark.id)
        end
        stellar.call(create)
        stellar.call(init)
        if create_mark then
            stellar.set_entry_skip(create_mark.id, true)
        end
        if init_mark then
            stellar.set_entry_skip(init_mark.id, true)
        end
        table.remove(left, pick)
        initialized = initialized + 1
        stellar.call_progress(progress, initialized, total)
    end
    return initialized
end

return databases

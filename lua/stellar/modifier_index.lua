-- modifier_index.lua : the game's modifier definitions found by token through an index instead of
-- linear scans (src/dll/modifier_index.cpp; docs/modifiers.md).
--
-- CModifier::GetTypeFromToken, CPdxModifier::TryReadMember and CModifier::TryAddDynamicModifier
-- each scan _Definitions for a token. modifier_index.locate reads, from their code, where
-- _Definitions is and where each scan starts and where its results go; modifier_index.install
-- replaces GetTypeFromToken and puts a stub over the other two scans.
--
--   local modifier_index = require("stellar.modifier_index")
--   local where = assert(modifier_index.locate(found, stellar.read))
--   local results = modifier_index.install(where)

local fnmatch = require("fnmatch")

local modifier_index = {}

local READ_MEMBER = "CPdxModifier<enum ModifierType,enum ModifierCategory,CModifier,CDefaultPdxModifierValueReader>::TryReadMember"

-- the instructions at the start of a function: { address, length, text, flow, target, rip }
local function instructions(read, address, count)
    local out, bytes, pos = {}, read(address, 512), 1
    while bytes and pos <= #bytes - 15 and #out < count do
        local i = fnmatch.decode(bytes, address, pos)
        if i == nil then
            break
        end
        out[#out + 1] = { address = address + pos - 1, length = i.length, text = i.text, flow = i.flow,
            target = i.target, rip = i.rip_relative }
        pos = pos + i.length
    end
    return out
end

-- whether a 5-byte jmp at address fits in one aligned 8-byte word (code_hook writes it at once)
local function atomic(address)
    return address % 8 + 5 <= 8
end

-- modifier_index.locate(found, read) -> where | nil, message: the addresses for
-- stellar.modifier_index (see src/dll/modifier_index.cpp)
function modifier_index.locate(found, read)
    local get_type, add, read_member = found["CModifier::GetTypeFromToken"], found["CModifier::TryAddDynamicModifier"],
        found[READ_MEMBER]
    if not (get_type and add and read_member) then
        return nil, "GetTypeFromToken, TryAddDynamicModifier or TryReadMember not found"
    end
    -- GetTypeFromToken: mov rax, [data]; movsxd rdx, [size]
    local g = instructions(read, get_type, 4)
    if not (g[1] and g[1].rip and g[1].text:match("^mov rax,") and g[2] and g[2].rip and g[2].text:match("^movsxd ")) then
        return nil, "GetTypeFromToken does not start as in 4.5.2"
    end
    local where = { data = g[1].target, size = g[2].target, get_type = get_type }
    -- TryAddDynamicModifier: movsxd rax, [size]; test eax, eax; jle missing; ...; cmp [r8+90h], ebx; je found
    local a = instructions(read, add, 60)
    for k = 2, #a - 8 do
        if a[k].rip and a[k].target == where.size and a[k].text:match("^movsxd rax,") and a[k + 1].text == "test eax,eax"
            and a[k + 2].flow == "conditional_branch" then
            for j = k + 3, k + 7 do
                if a[j].text:match("^cmp %[r8%+90h%],ebx") and a[j + 1].flow == "conditional_branch" then
                    where.add_missing, where.add_found = a[k + 2].target, a[j + 1].target
                    if atomic(a[k].address) then
                        where.add_scan, where.add_prefix = a[k].address, false
                    elseif a[k - 1].text == "mov ebx,eax" and atomic(a[k - 1].address) then
                        where.add_scan, where.add_prefix = a[k - 1].address, true
                    end
                    break
                end
            end
            break
        end
    end
    -- TryReadMember: xor edi, edi; movsxd r9, [size]; test r9, r9; jle missing; ...; cmp [rax], r8d; je found
    local r = instructions(read, read_member, 60)
    for k = 1, #r - 8 do
        if r[k].text == "xor edi,edi" and r[k + 1].rip and r[k + 1].target == where.size and r[k + 2].text == "test r9,r9"
            and r[k + 3].flow == "conditional_branch" then
            for j = k + 4, k + 9 do
                if r[j].text == "cmp [rax],r8d" and r[j + 1].flow == "conditional_branch" then
                    where.read_missing, where.read_found = r[k + 3].target, r[j + 1].target
                    if atomic(r[k].address) then
                        where.read_scan = r[k].address
                    end
                    break
                end
            end
            break
        end
    end
    return where
end

-- modifier_index.install(where) -> results: { get_type, add, read }, each true or why not
function modifier_index.install(where)
    return require("stellar").modifier_index(where)
end

return modifier_index

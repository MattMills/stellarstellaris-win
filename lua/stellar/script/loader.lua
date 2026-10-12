-- loader.lua : the game's script text, read by Lua instead of the game's lexer.
--
-- The game reads every script text (files, inline scripts, the rewritten text of scripted triggers,
-- effects and values) with a CTextLexer over a CMemoryFile: its virtual GetTok gives the next
-- token to the C++ reader that builds the objects. This module locates GetTok and the vtable of
-- CMemoryFile in this build; the hook (src/dll/lexer_hook.cpp) asks Lua for the tokens of each
-- text once, then compares them with the game's (shadow mode) or gives them to the game instead
-- (replace mode). See docs/text_lexer.md.
--
--   local loader = require("stellar.script.loader")
--   local where = assert(loader.locate(image, stellar.read))

local fnmatch = require("fnmatch")
local resolve = require("stellar.resolve")

local loader = {}

-- The vtable a constructor stores last at offset 0 of its object (the most derived class's: a
-- constructor stores its bases' first): `lea reg, [rip+x]` then `mov qword ptr [this], reg`.
local function constructed_vtable(read, f)
    local code = read(f.address, f.end_address - f.address)
    if code == nil then
        return nil
    end
    local this = { rcx = true }
    local loaded, vtable = {}, nil
    local pos = 1
    while pos <= #code do
        local i = fnmatch.decode(code, f.address, pos)
        if i == nil then
            break
        end
        local text = i.text
        -- the object stays in rcx, or is copied to another register first (mov rbx,rcx); a
        -- register that is changed otherwise (add rcx,20h) no longer holds it
        local copy_to, copy_from = text:match("^mov (r%w+),(r%w+)$")
        local dest = text:match("^%a+ (r%w+),")
        if copy_to and this[copy_from] then
            this[copy_to] = true
        elseif dest and this[dest] then
            this[dest] = nil
        end
        local lea = text:match("^lea (r%w+),%[")
        if lea and i.rip_relative then
            loaded[lea] = i.target
        end
        -- iced writes `mov [rcx],rax` (the size is the register's)
        local base, reg = text:match("^mov %[(r%w+)%],(r%w+)$")
        if not base then
            base, reg = text:match("^mov qword ptr %[(r%w+)%],(r%w+)$")
        end
        if base and this[base] and loaded[reg] then
            vtable = loaded[reg]
        end
        if i.flow == "return" then
            break
        end
        pos = pos + i.length
    end
    return vtable
end

-- loader.locate(image, read) -> where | nil, message: get_tok (CTextLexer::GetTok) and
-- memory_file_vtable (the vtable of CMemoryFile)
function loader.locate(image, read)
    local found = resolve.functions(image)
    local get_tok, ctor = found["CTextLexer::GetTok"], found["CMemoryFile::CMemoryFile"]
    if not get_tok then
        return nil, "CTextLexer::GetTok not found"
    end
    if not ctor then
        return nil, "CMemoryFile::CMemoryFile not found"
    end
    local f = image:function_at(ctor)
    local vtable = f and constructed_vtable(read, f)
    if vtable == nil then
        return nil, "no vtable stored by CMemoryFile::CMemoryFile"
    end
    return { get_tok = get_tok, memory_file_vtable = vtable }
end

return loader

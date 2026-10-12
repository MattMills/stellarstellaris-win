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

local resolve = require("stellar.resolve")
local code = require("stellar.code")

local loader = {}

-- loader.locate(image, read) -> where | nil, message: get_tok (CTextLexer::GetTok) and
-- memory_file_vtable (the vtable of CMemoryFile). A constructor stores its bases' vtables in the
-- object first and its own last: the last `lea r64, [rip+x]` followed by `mov [reg], r64` in
-- CMemoryFile::CMemoryFile.
function loader.locate(image, read)
    local found = resolve.functions(image)
    local get_tok, ctor = found["CTextLexer::GetTok"], found["CMemoryFile::CMemoryFile"]
    if not get_tok then
        return nil, "CTextLexer::GetTok not found"
    end
    if not ctor then
        return nil, "CMemoryFile::CMemoryFile not found"
    end
    local patterns = code.bundle(read, image)
    local stores = patterns:register({ name = "vtable stores in CMemoryFile::CMemoryFile", in_function = ctor,
        signature = "48 8d [00...101] ?? ?? ?? ?? [0100100.] 89 [00......]", count = false })
    local report = patterns:run()
    if not report.ok then
        return nil, "sigmatch: " .. tostring(report.error)
    end
    local last
    for _, at in ipairs(stores.matches or {}) do
        if last == nil or at > last then
            last = at
        end
    end
    if last == nil then
        return nil, "no vtable stored by CMemoryFile::CMemoryFile"
    end
    return { get_tok = get_tok, memory_file_vtable = code.relative(read, last + 3, last + 7) }
end

return loader

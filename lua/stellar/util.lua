-- util.lua : small helpers for the stellar scripts.

local util = {}

-- Addresses are numbers; string.format("%x") does not take 64-bit values on every Lua.
function util.hex(n)
    if type(n) ~= "number" then
        return tostring(n)
    end
    local digits, s = "0123456789abcdef", ""
    repeat
        local d = n % 16
        s = digits:sub(d + 1, d + 1) .. s
        n = math.floor((n - d) / 16)
    until n == 0
    return "0x" .. s
end

-- The directory of a path ("a\\b\\c.dll" -> "a\\b").
function util.dirname(path)
    return path:match("^(.*)[/\\]") or "."
end

-- A monotonic clock in seconds (os.clock is CPU time).
local ok, ffi = pcall(require, "ffi")
if ok and ffi.os == "Windows" then
    ffi.cdef [[
        int QueryPerformanceCounter(int64_t *count);
        int QueryPerformanceFrequency(int64_t *frequency);
    ]]
    local frequency = ffi.new("int64_t[1]")
    ffi.C.QueryPerformanceFrequency(frequency)
    local scale = 1 / tonumber(frequency[0])
    local count = ffi.new("int64_t[1]")
    function util.now()
        ffi.C.QueryPerformanceCounter(count)
        return tonumber(count[0]) * scale
    end
    -- util.system_time() -> seconds since 1970 (the clock of the DLL's events and workers)
    ffi.cdef [[ void GetSystemTimePreciseAsFileTime(uint64_t *time); ]]
    local filetime = ffi.new("uint64_t[1]")
    function util.system_time()
        ffi.C.GetSystemTimePreciseAsFileTime(filetime)
        return tonumber(filetime[0] - 116444736000000000ULL) / 1e7
    end
else
    util.now = os.clock
    util.system_time = os.time
end

return util

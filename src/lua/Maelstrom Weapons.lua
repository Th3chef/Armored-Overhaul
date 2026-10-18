-- HD2-Addon: mods/chef/armored_overhaul_maelstrom_weapons
-- Armored Overhaul 3.6.2 - Maelstrom weapons: the TD-110 Maelstrom's main gun settings for two options, each its own
-- pick (its option addon sets ArmoredOverhaulMaelstromPicks): Maelstrom Fire Rate (a hold-reload choice of the main gun's
-- rounds per minute x1 / x1.5 / x2) and Maelstrom Single Belt (all its ammo on one belt, no reload). Written for Armored
-- Overhaul from the author's own Leveller & Solo Silo Demo Force 50 core (the same settings-table scan).
--
-- How it works: the game keeps its weapon settings in tables in memory (each behind a 24-byte 'LDLD' header; found by
-- their table type and layout, never by fixed addresses). The main gun (tank_storm_maingun, D58AE6A04EDB10DE: 12.5mm,
-- 1200 rpm, 300-round belt, 6 spare belts): its fire-mode record's rates (+4/+8/+12), its weapon data's left-input
-- function (+188, the right input, since 3.6.1 Test 6: the fire-rate choice), and its magazine record's belt
-- and spare belts. Every copy of a table is written and read back. Every 5 s the values are checked (set again if the
-- game put its own back); every 5 minutes a headers-only scan looks for moved or new tables. Turning it off in the Mod
-- Options Menu puts the game's values back (also kept in a process environment variable, so a copy of this addon loaded
-- again while the game runs knows them). A Maelstrom takes these when it is called in. Writes
-- ArmoredOverhaul-MaelstromWeapons.log.
-- (3.6.0: Maelstrom Missile Demolition was taken out before release: the missiles already break the walls it was for.)
if type(jit) == 'table' and type(jit.off) == 'function' then jit.off(true, true) end
-- (3.3.0) The logs folder (logs, caches and markers): Bingus Shared Loader v19's log_directory, else
-- %LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs as before (loader v15-v18). A global, so no addon gains a top-level local.
if not rawget(_G, 'ArmoredOverhaulLogsDir') then rawset(_G, 'ArmoredOverhaulLogsDir', function()
    local L = rawget(_G, 'CowboyBingusModLoader')
    local d = type(L) == 'table' and L.log_directory
    if type(d) == 'function' then local ok, v = pcall(d); d = ok and v or nil end
    if type(d) == 'string' and d ~= '' then return (d:gsub('[\\/]+$', '')) end
    local root = os.getenv and os.getenv('LOCALAPPDATA')
    return root and root ~= '' and (root .. '\\CowboyBingus\\Helldivers2\\Logs') or nil
end) end
local loader = rawget(_G, 'CowboyBingusModLoader')
if type(loader) ~= 'table' or type(loader.version) ~= 'number' or loader.version < 15 then return end
local TESTER = false
local VERSION = ({version = '3.6.2'}).version   -- (as the other addons write it, so test builds name themselves)

local GUN = { name = 'Maelstrom main gun', entity = 'D58AE6A04EDB10DE', belt = 300, mags = 6, rpm = 1200 }   -- (the game's belt, spare belts and rate)
local ENV_NAME = 'ARMORED_OVERHAUL_MAELSTROM_GAME'

-- The settings tables this addon reads. type = the table's type hash in its header; stride = record size in this game
-- build (all keyed: the size is worked out from the layout when a patch changes it).
local KINDS = {
    fire = { type = 0x45171B68, stride = 616, keyed = true },    -- +4 / +8 / +12 rounds per minute
    magazine = { type = 0xFB8D88A3, stride = 160, keyed = true },    -- +136 rounds per magazine, then magazines, refill, most
    weapondata = { type = 0x88E4DBB1, stride = 1232, keyed = true }, -- +184 / +188 the inputs' functions (2 = fire rate)
}
local KIND_NAMES = { 'fire', 'magazine', 'weapondata' }
local OPTIONAL_WAIT = 60   -- seconds to wait for the rest of the gun's tables once one of them is found

if rawget(_G, 'ArmoredOverhaulMaelstromWeapons') then return end
local S = { status = 'starting', frame = 0, version = VERSION, lines = {}, events = {}, checks = 0, resets = 0,
            options_menu = 'not installed (the mod manager\'s pick)' }
rawset(_G, 'ArmoredOverhaulMaelstromWeapons', S)

-- ---------------------------------------------------------------- helpers
local function u32(blob, offset)
    local a, b, c, d = blob:byte(offset + 1, offset + 4)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function u32_bytes(v)
    v = v % 4294967296
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function f32(bits)
    if not bits then return 0 end
    local sign = bits >= 2147483648 and -1 or 1
    if sign < 0 then bits = bits - 2147483648 end
    local exp, mant = math.floor(bits / 8388608), bits % 8388608
    if exp == 0 then return sign * mant * 2 ^ -149 end
    if exp == 255 then return 0 end
    return sign * (1 + mant / 8388608) * 2 ^ (exp - 127)
end

local function key_of(hex16)  -- entity hash as stored (u64 little-endian)
    return u32_bytes(tonumber(hex16:sub(9, 16), 16)) .. u32_bytes(tonumber(hex16:sub(1, 8), 16))
end

local NEEDLE = 'LDLD' .. u32_bytes(1)
local HEADER = 24

-- ---------------------------------------------------------------- log
local api = nil
local function event(text)
    S.events[#S.events + 1] = string.format('[%.1f s] %s', api and S.t0 and (api.now() - S.t0) or 0, text)
    if #S.events > (TESTER and 120 or 30) then table.remove(S.events, 1) end
    S.dirty = true
end

local function write_log()
    S.dirty = false
    pcall(function()
        local f = loader.open_log and loader.open_log('ArmoredOverhaul-MaelstromWeapons.log')
        if not f then return end
        local out = { 'Armored Overhaul - Maelstrom weapons (Fire Rate, Single Belt)', 'version: ' .. VERSION,
                      'running: ' .. string.format('%.0f s', api and S.t0 and (api.now() - S.t0) or 0),
                      'status: ' .. S.status, 'options menu: ' .. S.options_menu }
        if S.checks > 0 then
            out[#out + 1] = string.format('checks: %d (every 5 s); values as wanted: %d of %d; set again after the game reset them: %d',
                S.checks, S.held or 0, S.watched or 0, S.resets)
        end
        out[#out + 1] = ''
        for _, line in ipairs(S.lines) do out[#out + 1] = line end
        out[#out + 1] = ''
        out[#out + 1] = 'events:'
        for _, line in ipairs(S.events) do out[#out + 1] = '  ' .. line end
        f:write(table.concat(out, '\n') .. '\n')
        f:close()
    end)
end

-- ---------------------------------------------------------------- windows memory access
local function build_api()
    local ffi = require('ffi')
    for _, d in ipairs({
        'void *GetCurrentProcess(void);',
        'int ReadProcessMemory(void *p, const void *a, void *b, size_t n, size_t *r);',
        'int WriteProcessMemory(void *p, void *a, const void *b, size_t n, size_t *w);',
        'size_t VirtualQuery(const void *a, void *info, size_t n);',
        'int VirtualProtect(void *a, size_t n, uint32_t prot, uint32_t *old);',
        'int K32QueryWorkingSetEx(void *p, void *entries, uint32_t n);',
        'int QueryPerformanceCounter(int64_t *c);',
        'int QueryPerformanceFrequency(int64_t *f);',
        'int CreateDirectoryA(const char *path, void *sec);',
        'int32_t NtQueryVirtualMemory(void *p, const void *a, int cls, void *info, size_t n, size_t *r);',
        'unsigned long GetEnvironmentVariableA(const char *, char *, unsigned long);', 'int SetEnvironmentVariableA(const char *, const char *);',
        'void *GetModuleHandleA(const char *);',
    }) do pcall(ffi.cdef, d) end
    pcall(ffi.cdef, [[typedef struct { void *base; void *allocation_base; uint32_t allocation_protection;
        uint16_t partition; uint16_t reserved; size_t size; uint32_t state; uint32_t protection; uint32_t type; } AOMDRegion;]])
    local k32, nt = ffi.load('kernel32'), ffi.load('ntdll')
    local proc = k32.GetCurrentProcess()
    local got, info, ret = ffi.new('size_t[1]'), ffi.new('uint64_t[6]'), ffi.new('size_t[1]')
    local region, ws = ffi.new('AOMDRegion[1]'), ffi.new('uint64_t[2]')
    local ticks, freq = ffi.new('int64_t[1]'), ffi.new('int64_t[1]')
    k32.QueryPerformanceFrequency(freq)
    local per_second = tonumber(freq[0])
    local a = {}
    function a.read(address, n)
        local buf = ffi.new('uint8_t[?]', n)
        if k32.ReadProcessMemory(proc, ffi.cast('const void *', address), buf, n, got) == 0 or tonumber(got[0]) ~= n then return nil end
        return ffi.string(buf, n)
    end
    -- the allocation holding `address`: base, size, in use (constant cost, unlike VirtualQuery on big regions)
    function a.allocation(address)
        if nt.NtQueryVirtualMemory(proc, ffi.cast('const void *', address), 3, info, 48, ret) == 0 then
            local base, size = tonumber(info[0]), tonumber(info[2])
            if base and size and size > 0 then return base, size, true end
        end
        if k32.VirtualQuery(ffi.cast('const void *', address), ffi.cast('void *', region), ffi.sizeof('AOMDRegion')) == 0 then return nil end
        return tonumber(ffi.cast('uintptr_t', region[0].base)), tonumber(region[0].size), false
    end
    -- protection of a present page private to the game (0 when not present or shared)
    function a.protection(address)
        ws[0], ws[1] = address - address % 4096, 0
        if k32.K32QueryWorkingSetEx(proc, ffi.cast('void *', ws), 16) == 0 then return 0 end
        local attr = tonumber(ws[1] % 65536)
        if attr % 2 == 0 or attr >= 32768 then return 0 end
        return math.floor(attr / 16) % 2048
    end
    function a.write(address, bytes)
        if k32.VirtualQuery(ffi.cast('const void *', address), ffi.cast('void *', region), ffi.sizeof('AOMDRegion')) == 0 then return false end
        local prot = region[0].protection
        if region[0].state ~= 0x1000 or region[0].type ~= 0x20000 or (prot ~= 0x04 and prot ~= 0x02) then return false end
        local old = ffi.new('uint32_t[1]')
        if prot == 0x02 and k32.VirtualProtect(ffi.cast('void *', address), #bytes, 0x04, ffi.cast('void *', old)) == 0 then return false end
        local ok = k32.WriteProcessMemory(proc, ffi.cast('void *', address), bytes, #bytes, got) ~= 0 and tonumber(got[0]) == #bytes
        if prot == 0x02 then k32.VirtualProtect(ffi.cast('void *', address), #bytes, old[0], ffi.cast('void *', old)) end
        return ok
    end
    function a.now() k32.QueryPerformanceCounter(ticks); return tonumber(ticks[0]) / per_second end
    local envbuf = ffi.new('char[512]')
    function a.env_get(name)
        local n = k32.GetEnvironmentVariableA(name, envbuf, 512)
        if n == 0 or n >= 512 then return nil end
        return ffi.string(envbuf, n)
    end
    function a.env_set(name, value) k32.SetEnvironmentVariableA(name, value) end
    function a.mkdir(path) k32.CreateDirectoryA(path, nil) end
    function a.module(name) local m = k32.GetModuleHandleA(name); return m ~= nil and tonumber(ffi.cast('uintptr_t', m)) or nil end
    function a.address_of(s) return tonumber(ffi.cast('uintptr_t', ffi.cast('const char *', s))) end
    return a
end


-- ---------------------------------------------------------------- table parsing
-- Keyed table: buckets (u64 entity hash, u32 record index, u32 0), twice as many as entities, then
-- fixed-size records. Every candidate bucket count is tried; exactly one may fit. If none fits with
-- this build's record size (a patch changed it), the size is worked out from the layout instead.
local function parse_keyed(blob, spec)
    local total, count, live, top, offset, shapes = #blob, 0, 0, -1, 0, {}
    while offset + 16 <= total do
        local slot, pad = u32(blob, offset + 8), u32(blob, offset + 12)
        if pad ~= 0 or slot > 100000 then break end
        count = count + 1
        if (u32(blob, offset) ~= 0 or u32(blob, offset + 4) ~= 0) and not (spec.ignore and blob:sub(offset + 1, offset + 8) == spec.ignore) then
            live = live + 1
            if slot > top then top = slot end
        end
        offset = offset + 16
        if count == 2 * live and total - count * 16 > 0 then shapes[#shapes + 1] = { count, live, top } end
    end
    local function fits(stride)
        local out = {}
        for _, sh in ipairs(shapes) do
            local array = total - sh[1] * 16
            if array % stride == 0 and array / stride > sh[3] and array / stride <= sh[2] + 2 then out[#out + 1] = sh[1] end
        end
        return out
    end
    local stride, buckets = spec.stride, fits(spec.stride)
    if #buckets ~= 1 then
        -- derive: in the real bucket array each record index appears once, and the records that
        -- follow number the entities plus 0-2 spare ones. Shorter runs that fit are just the start
        -- of it, so the longest run decides; if its record size is not clear-cut, give up.
        local result = nil
        for _, sh in ipairs(shapes) do
            local c, live, top = sh[1], sh[2], sh[3]
            local array, seen, unique = total - c * 16, {}, true
            for k = 0, c - 1 do
                if (u32(blob, k * 16) ~= 0 or u32(blob, k * 16 + 4) ~= 0) and not (spec.ignore and blob:sub(k * 16 + 1, k * 16 + 8) == spec.ignore) then
                    local slot = u32(blob, k * 16 + 8)
                    if seen[slot] then unique = false break end
                    seen[slot] = true
                end
            end
            if unique and top <= live + 1 then
                local candidates = {}
                for records = math.max(live, top + 1), live + 2 do
                    if records > 0 and array % records == 0 and array / records >= 16 and array / records % 4 == 0 then
                        candidates[#candidates + 1] = array / records
                    end
                end
                result = #candidates == 1 and { c, candidates[1] } or (#candidates > 1 and 'unclear' or result)
            end
        end
        if type(result) ~= 'table' then return nil, 'record size changed and could not be worked out' end
        buckets, stride = { result[1] }, result[2]
        event(string.format('record size of the %s table changed: %d -> %d bytes', spec.name, spec.stride, stride))
    end
    local index, zero = {}, string.rep('\0', 8)
    for k = 0, buckets[1] - 1 do
        local key = blob:sub(k * 16 + 1, k * 16 + 8)
        if key ~= zero and not index[key] then index[key] = buckets[1] * 16 + u32(blob, k * 16 + 8) * stride end
    end
    return index, nil, stride, buckets[1]
end

-- ---------------------------------------------------------------- scan (runs in a coroutine)
local LOW = 0x80000000
local LIMIT = 0x7FFFFFFF0000
local BUDGET = 0.0008             -- seconds of scanning per frame
local found, by_type = {}, {}      -- name -> list of { address, payload, blob }
for _, name in ipairs(KIND_NAMES) do KINDS[name].name = name; by_type[KINDS[name].type] = name end

local slice_end = 0
local function pause()
    if api.now() >= slice_end then coroutine.yield() end
end

local function scan_pass(skip_low, sweep, headers_only)
    for _, name in ipairs(KIND_NAMES) do found[name] = {} end
    local seen = {}
    local function table_at(address)
        if seen[address] or (skip_low and address < LOW) then return nil end
        local head = api.read(address, HEADER)
        if not head or head:sub(1, 8) ~= NEEDLE then return nil end
        local kind, payload = u32(head, 8), u32(head, 12)
        if payload < 16 or payload > 64 * 1024 * 1024 then return nil end
        seen[address] = true
        local name = by_type[kind]
        if name then
            local blob = not headers_only and api.read(address + HEADER, payload) or nil
            if blob or headers_only then found[name][#found[name] + 1] = { address = address, payload = payload, blob = blob } end
        end
        return payload
    end
    -- the tables sit at the start of their allocations, most of them back to back in chains
    local chains, cursor = {}, 0
    while cursor < LIMIT do
        local base, size, used = api.allocation(cursor)
        if not base then break end
        cursor = math.max(base + size, cursor + 4096)
        if used and not (skip_low and base < LOW) then
            local p = api.protection(base)
            if p == 0x04 or p == 0x02 then
                local head = api.read(base, 16)
                if head and head:sub(1, 8) == NEEDLE then chains[#chains + 1] = base
                elseif head and head:sub(5, 12) == NEEDLE then chains[#chains + 1] = base + 4 end
            end
        end
        pause()
    end
    for _, at in ipairs(chains) do
        while at do
            local payload = table_at(at)
            local next_at = nil
            if payload then
                local gap = api.read(at + HEADER + payload, 24)
                for skip = 0, 16, 4 do
                    if gap and gap:sub(skip + 1, skip + 8) == NEEDLE then next_at = at + HEADER + payload + skip break end
                end
            end
            at = next_at
            pause()
        end
    end
    if sweep then  -- last resort: every readable private page
        cursor = 0
        while cursor < LIMIT do
            local base, size, used = api.allocation(cursor)
            if not base then break end
            cursor = math.max(base + size, cursor + 4096)
            if used and not (skip_low and base < LOW) then
                for page = base, base + size - 1, 65536 do
                    local p = api.protection(page)
                    if p == 0x04 or p == 0x02 then
                        local blob = api.read(page, math.min(65536, base + size - page))
                        local pos = 1
                        while blob do
                            local hit = blob:find(NEEDLE, pos, true)
                            if not hit then break end
                            table_at(page + hit - 1)
                            pos = hit + 1
                        end
                    end
                    pause()
                end
            end
        end
    end
    return #chains
end

-- Parses what a pass found: per kind, the first copy that parses, plus every copy of the same size.
local function parse_found()
    local T = {}
    for _, name in ipairs(KIND_NAMES) do
        local spec = KINDS[name]
        for _, c in ipairs(found[name]) do
            local index, why, stride, buckets
            index, why, stride, buckets = parse_keyed(c.blob, spec)
            if index then
                T[name] = { blob = c.blob, index = index, stride = stride, payload = c.payload, copies = {}, buckets = buckets }
                -- (3.6.0 review) a keyed table's other copies only when their look-up slots are byte for byte the same,
                -- so a record sits at the same place in each (a same-size table in another order is not a copy)
                local slots = buckets and c.blob:sub(1, buckets * 16)
                for _, other in ipairs(found[name]) do
                    if other.payload == c.payload and (not slots or other == c or (other.blob and other.blob:sub(1, buckets * 16) == slots)) then
                        T[name].copies[#T[name].copies + 1] = other.address
                    end
                end
                break
            end
            c.why = why
        end
        if not T[name] then
            T.absent = (T.absent and (T.absent .. ', ') or '') .. name .. (found[name][1] and (' (' .. #found[name] .. ' found, ' .. tostring(found[name][1].why) .. ')') or '')
        end
    end
    return T
end

-- What a pass found, in short: where the tables are. A refresh pass
-- reads headers only and re-applies only when this changes.
local function found_sig()
    local parts = {}
    for _, name in ipairs(KIND_NAMES) do
        local list = {}
        for _, c in ipairs(found[name]) do list[#list + 1] = string.format('%X:%d', c.address, c.payload) end
        parts[#parts + 1] = name .. '=' .. table.concat(list, ',')
    end
    return table.concat(parts, ' ')
end

-- ---------------------------------------------------------------- what is wanted
-- (Test 11, the tester: "Fire rate should only go from 1x, 1.5x, 2x. and only in the reload context menu, make Fire rate selector
-- a toggle in the mod options") Fire Rate on = the hold-reload choice of the game's rate x1 / x1.5 / x2 (1200 / 1800 /
-- 2400).
-- The picks come from the option addons (ArmoredOverhaulMaelstromPicks: rpm and belt = true), read when the
-- tables are applied; the Mod Options Menu turns each on or off in game.
-- (3.6.1 Test 7, the tester: "1800 starting is fine then") The list reads low, start, high and the gun starts on the middle
-- one, so for 1200 · 1800 · 2400 in order it starts at 1800 (x1.5); the low slot is the game's 1200 (3.6.1 Tests 2-6
-- started at 1200 with 1800 in the low slot: the list read out of order)
local RPM_START = 1.5
-- (3.6.1 Test 6, the tester: "would it be possible to move to the right context menu and then not fire a missile when change
-- the RPM with right click") The fire-rate choice is back on the RIGHT input (weapon data +188, as the FRV's MG-206 has
-- it; 3.6.0 Test 9 to 3.6.1 Test 5: the left, +184). Tank Core now holds both tank fire actions off while the menu is
-- open, so a right click there only picks a rate (the missiles fired with it in 3.6.0 Test 8).
local ROF_AT, ROF_OTHER = 188, 184
local function picks()
    local p = rawget(_G, 'ArmoredOverhaulMaelstromPicks')
    return type(p) == 'table' and p or {}
end
S.want = nil                -- {rpm = bool, belt = bool}
local function wanted()
    if not S.want then
        local p = picks()
        S.want = {rpm = p.rpm == true, belt = p.belt == true}
    end
    return S.want
end

local function f32_bits(x)
    if x == 0 then return 0 end
    local sign = x < 0 and 2147483648 or 0
    x = math.abs(x)
    local m, e = math.frexp(x)                 -- x = m * 2^e, 0.5 <= m < 1
    return sign + (e + 126) * 8388608 + math.floor((m * 2 - 1) * 8388608 + 0.5)
end

-- ---------------------------------------------------------------- the game's values (kept for a reloaded copy)
local kept = nil            -- 'kind:record:offset' -> the game's raw value (u32)
local function env_read()
    kept = {}
    local ok, v = pcall(api.env_get, ENV_NAME)
    if not ok or type(v) ~= 'string' then return end
    for k, val in v:gmatch('([%w:]+)=(%d+)') do kept[k] = tonumber(val) end
end
local function env_save()
    local t = {}
    for k, val in pairs(kept) do t[#t + 1] = k .. '=' .. val end
    table.sort(t)
    pcall(api.env_set, ENV_NAME, table.concat(t, ';'))
end

-- ---------------------------------------------------------------- the values written
-- A watched value: group ('rpm' / 'rpm_lo' / 'rpm_hi' / 'rof' / 'belt'), table kind, `rel` = its place in the table's payload, `idrel` /
-- `idb` = where the record's id is and what it must be (row tables), `game` = the game's raw value, `base` = the
-- game's value as a number (the float for rpm), `last` = what this addon wrote last.
local function desired(w)
    local want = wanted()
    if w.group == 'rpm' then return want.rpm and f32_bits(w.base * RPM_START) or w.game end
    -- (the hold-reload fire-rate choice: the game's rate as the low one, twice it as the high one, the function on)
    if w.group == 'rpm_lo' then return want.rpm and f32_bits(w.base) or w.game end
    if w.group == 'rpm_hi' then return want.rpm and f32_bits(w.base * 2) or w.game end
    if w.group == 'rof' then return want.rpm and 2 or w.game end
    if w.group == 'belt' then return want.belt and w.on or w.game end    -- (Single Belt: w.on = the value with it on)
    return w.game
end
-- writes `value` into every copy of the entry's table whose value there is the game's or the one written last (and
-- whose record has the right id, for row tables); returns how many copies were written
-- the value an entry has when its option is on (what this mod writes)
local function on_value(w)
    if w.group == 'rpm' then return f32_bits(w.base * RPM_START) end
    if w.group == 'rpm_lo' then return f32_bits(w.base) end
    if w.group == 'rpm_hi' then return f32_bits(w.base * 2) end
    if w.group == 'rof' then return 2 end
    return w.on
end
-- (3.6.0 Test 6) also into the game's own copy of the table (w.extra: the record's place there), which is what the game reads
-- (3.6.0 review) a place holding this mod's own value is written too, not only the game's or the last written: a rescan
-- or a reloaded copy makes fresh entries, and with the option off by then the mod's values were left in memory for good
local function write_entry(w, value)
    local bytes, done = u32_bytes(value), 0
    local function put(at, label)
        local cur = api.read(at, 4)
        local v = cur and u32(cur, 0)
        if v and v ~= value and (v == w.game or v == w.last or v == on_value(w)) then
            if api.write(at, bytes) and api.read(at, 4) == bytes then done = done + 1
            else event(string.format('write failed (%s %s %X)', w.kind, label, at)) end
        end
    end
    for _, block in ipairs(S.T[w.kind].copies) do
        local okid = true
        if w.idb then local r = api.read(block + HEADER + w.idrel, 4); okid = r == w.idb end
        if okid then put(block + HEADER + w.rel, 'table copy') end
    end
    if w.extra then put(w.extra, 'game copy') end
    w.last = value
    return done
end
local function held_now(w)
    local want = desired(w)
    local v = api.read(S.T[w.kind].copies[1] + HEADER + w.rel, 4)
    if not v or u32(v, 0) ~= want then return false end
    if w.extra then v = api.read(w.extra, 4); return v ~= nil and u32(v, 0) == want end
    return true
end

-- ---------------------------------------------------------------- the game's own copies (3.6.0 Test 6)
-- Test 5 showed the LDLD tables are not what the game reads for these: its settings root holds its own copy of each
-- (the fire-mode one at root+0xF12E80, magazine +0xF124A0, weapon data +0xF12BD8 on the October 2026 game). game.dll's
-- look-up of a component's record by entity starts: test rcx,rcx / je / mov rax,[rip+ROOT] / mov r8d,ecx /
-- mov r10,[rax+TABLE]. From that: the root's global and the table's place in the root. A copy counts as the table's
-- when its slots match the LDLD table's byte for byte (so each record sits at the same place in both).
local LIVE_KINDS = {'fire', 'magazine', 'weapondata'}
local KNOWN_GAME = {stamp = 0x6AB3B43F, fire = 0x514C10, magazine = 0x4F32F0, weapondata = 0x509570}
local HEAD_LEAD = '\68\139\193\76\139\144'     -- mov r8d,ecx / mov r10,[rax+TABLE]
local function u64_at(address)
    local b = api.read(address, 8)
    return b and (u32(b, 0) + u32(b, 4) * 4294967296) or nil
end
local function head_at(game, rva)
    local b = api.read(game + rva, 22)
    if not b or b:sub(1, 4) ~= '\72\133\201\116' or b:sub(6, 8) ~= '\72\139\5' or b:sub(13, 18) ~= HEAD_LEAD then return nil end
    local rel = u32(b, 8)
    if rel >= 2147483648 then rel = rel - 4294967296 end
    return {global = game + rva + 12 + rel, table_at = u32(b, 18), rva = rva}
end
S.heads = nil               -- {base = game.dll, how, list} (kept: the code doesn't move)
local function code_heads()
    if not api.module then return nil, 'no game module here' end
    local game = api.module('game.dll')
    if not game then return nil, 'game.dll not found' end
    if S.heads and S.heads.base == game then return S.heads end
    local mz = api.read(game, 0x40)
    local nt = mz and api.read(game + u32(mz, 0x3C), 0x58)
    if not nt or nt:sub(1, 4) ~= 'PE\0\0' then return nil, 'game.dll header not readable' end
    local stamp, size = u32(nt, 8), u32(nt, 0x50)
    local list, seen = {}, {}
    if stamp == KNOWN_GAME.stamp then
        for _, k in ipairs(LIVE_KINDS) do
            local h = head_at(game, KNOWN_GAME[k])
            if h then h.kind = k; list[#list + 1] = h; seen[h.rva] = true end
        end
    end
    local how = string.format('game.dll %08X, known build', stamp)
    if #list < #LIVE_KINDS then
        -- (a patched game) every look-up head in its code, 256 KB a step
        how = string.format('game.dll %08X, code scanned', stamp)
        local CH, at = 0x40000, 0x1000
        while at < size do
            local n = math.min(CH, size - at)
            local chunk = api.read(game + at, n)
            if chunk then
                local from = 1
                while true do
                    local hit = chunk:find(HEAD_LEAD, from, true)
                    if not hit then break end
                    local rva = at + hit - 1 - 12
                    if not seen[rva] then
                        seen[rva] = true
                        local h = head_at(game, rva)
                        if h then list[#list + 1] = h end
                    end
                    from = hit + 1
                end
                at = at + math.max(0x1000, n - 32)
            else
                at = at + 0x1000
            end
            pause()
        end
    end
    S.heads = {base = game, how = how, list = list}
    return S.heads
end
-- kind -> {global, table_at, tbl, same (the game reads the LDLD table itself), rva}; and a line per kind for the log
local function find_live(T)
    local live, lines = {}, {}
    local H, why = code_heads()
    if not H then lines[1] = 'game copies: not looked for (' .. why .. ')'; return live, lines end
    lines[1] = 'game copies (' .. H.how .. ', ' .. #H.list .. ' look-up' .. (#H.list == 1 and '' or 's') .. '):'
    for _, kind in ipairs(LIVE_KINDS) do
        local t = T[kind]
        if t and t.buckets then
            local want = t.blob:sub(1, t.buckets * 16)
            local hit, tried = nil, {}
            for pass = 1, 2 do
                for _, h in ipairs(H.list) do
                    local k = h.global .. ':' .. h.table_at
                    if not hit and not tried[k] and (pass == 2 or h.kind == kind) then
                        tried[k] = true
                        local root = u64_at(h.global)
                        local tbl = root and root > 65536 and u64_at(root + h.table_at)
                        if tbl and tbl > 65536 and api.read(tbl, #want) == want then
                            hit = {global = h.global, table_at = h.table_at, tbl = tbl, rva = h.rva}
                        end
                    end
                end
            end
            if hit then
                for _, block in ipairs(t.copies) do if block + HEADER == hit.tbl then hit.same = true end end
                live[kind] = hit
                lines[#lines + 1] = string.format('  %-10s game.dll+0x%X: root+0x%X -> %X (%s)', kind, hit.rva, hit.table_at, hit.tbl,
                    hit.same and 'the LDLD table itself' or 'a copy of its own')
            else
                lines[#lines + 1] = string.format('  %-10s NOT FOUND (no look-up\'s table has its %d slots)', kind, t.buckets)
            end
        end
    end
    return live, lines
end
-- the game's raw value for a place: kept by an earlier copy of this addon in this game when the place now holds the
-- game's or this mod's value, else the value now
local function game_value(key, now, ours)
    if not kept then env_read() end
    local g = kept[key]
    if g and (now == g or ours(now, g)) then return g end
    kept[key] = now; env_save()
    return now
end

-- ---------------------------------------------------------------- apply
local function hexdump(blob, at, n)
    local t = {}
    for o = 0, n - 4, 4 do t[#t + 1] = string.format('%08x', u32(blob, at + o) or 0) end
    return table.concat(t, ' ')
end
local function apply(T)
    if not kept then env_read() end
    local want = wanted()
    local lines, watch, changed = {}, {}, 0
    for _, name in ipairs(KIND_NAMES) do
        if T[name] then
            local n = 0
            for _ in pairs(T[name].index) do n = n + 1 end
            lines[#lines + 1] = string.format('table %-10s %d records, %d cop%s, record size %d', name,
                n, #T[name].copies, #T[name].copies == 1 and 'y' or 'ies', T[name].stride)
        else
            lines[#lines + 1] = string.format('table %-10s not found', name)
        end
    end
    S.T, S.live = {}, {}
    for _, name in ipairs(KIND_NAMES) do if T[name] then S.T[name] = {copies = T[name].copies, payload = T[name].payload} end end
    local p = picks()
    -- the main gun (3.6.0 Test 6): its rounds per minute (fire-mode record +4/+8/+12 floats: low / default / high), the
    -- hold-reload fire-rate choice (weapon data ROF_AT, the input's function: 2 = fire rate; the FRV's MG-206 has it on
    -- the right, +188; 3.6.0 Test 9 moved it to the left, +184, as the right button fired the missiles; 3.6.1 Test 6 back
    -- on the right, with Tank Core holding the tank's fire off while the menu is open);
    -- then the low and high rates are the game's and twice it) and its belt (magazine record +136: rounds, then
    -- magazines, refill, most). Each written in the LDLD table and in the game's own copy (the one the game reads).
    if p.rpm or p.belt then
        local live, live_lines = find_live(T)
        S.live = live
        local key = key_of(GUN.entity)
        local f = T.fire and T.fire.index[key]
        local m, wd = T.magazine and T.magazine.index[key], T.weapondata and T.weapondata.index[key]
        lines[#lines + 1] = ''
        lines[#lines + 1] = GUN.name .. (f and '' or ' (not in the fire-mode table)') .. (m and '' or ' (not in the magazine table)')
            .. (wd and '' or ' (not in the weapon-data table)')
        for _, l in ipairs(live_lines) do lines[#lines + 1] = '  ' .. l end
        if TESTER then
            if f then lines[#lines + 1] = '  fire-mode record: ' .. hexdump(T.fire.blob, f, math.min(160, T.fire.stride)) end
            if m then lines[#lines + 1] = '  magazine record: ' .. hexdump(T.magazine.blob, m, T.magazine.stride) end
        end
        -- a watched value at `rel` in kind's table: also at the same place in the game's own copy, when that is its own
        local function place(w)
            local lv = live[w.kind]
            if lv and not lv.same then w.extra = lv.tbl + w.rel end
            return w
        end
        local function live_now(kind, rel)   -- the game's copy's value when there is one, else the LDLD table's
            local lv = live[kind]
            local v = api.read(lv and lv.tbl + rel or (S.T[kind].copies[1] + HEADER + rel), 4)
            return v and u32(v, 0)
        end
        local where_note = function(kind) return live[kind] and '' or ' (LDLD table only: the game\'s copy not found)' end
        if p.rpm then
            -- (3.6.0 review) all or nothing: the middle rate is written only with the hold-reload choice (Test 13 wrote it
            -- even when the choice was refused), and only when the gun's rate is the game's 1200 (a patch that changed it,
            -- or moved the fields, is refused rather than scaled)
            local now = f and live_now('fire', f + 8)
            local game = now and game_value('fire:' .. GUN.entity .. ':8', now, function(v, g) local a, b = f32(v), f32(g); return b > 0 and math.abs(a / b - RPM_START) < 0.01 end)
            local base = game and f32(game)
            local mg = wd and T.weapondata.index[key_of('085C1EDB038EC24E')]
            local why = nil
            if not f then why = 'the gun is not in the fire-mode table'
            elseif not base or math.abs(base - GUN.rpm) > 0.5 then why = string.format('its rate at fire-mode +8 is %s, not the game\'s %d', base and string.format('%.0f', base) or '?', GUN.rpm)
            elseif not wd then why = 'the gun is not in the weapon-data table'
            elseif not mg or u32(T.weapondata.blob, mg + 188) ~= 2 then why = 'the MG-206\'s fire-rate function is not at weapon data +188'
            end
            local g_rof, g_lo, g_hi
            if not why then
                local rof_now, right_now = live_now('weapondata', wd + ROF_AT), live_now('weapondata', wd + ROF_OTHER)
                local lo_now, hi_now = live_now('fire', f + 4), live_now('fire', f + 12)
                if not (rof_now and right_now and lo_now and hi_now) then why = 'its records could not be read'
                else
                    g_rof = game_value('weapondata:' .. GUN.entity .. ':' .. ROF_AT, rof_now, function(v) return v == 2 end)
                    g_lo = game_value('fire:' .. GUN.entity .. ':4', lo_now, function(v) return v == f32_bits(base) end)
                    g_hi = game_value('fire:' .. GUN.entity .. ':12', hi_now, function(v) return v == f32_bits(base * 2) end)
                    if g_rof ~= 0 or right_now ~= 0 then why = 'the gun already has an input function'
                    elseif g_lo ~= 0 or g_hi ~= 0 then why = 'the gun already has low / high rates' end
                end
            end
            if why then
                lines[#lines + 1] = '  Maelstrom Fire Rate: not added (' .. why .. ')'
            else
                for _, e in ipairs({{'rpm', 'fire', f + 8, game}, {'rof', 'weapondata', wd + ROF_AT, g_rof}, {'rpm_lo', 'fire', f + 4, g_lo}, {'rpm_hi', 'fire', f + 12, g_hi}}) do
                    local w2 = place({group = e[1], kind = e[2], rel = e[3], game = e[4], base = base})
                    watch[#watch + 1] = w2
                    changed = changed + write_entry(w2, desired(w2))
                end
                lines[#lines + 1] = string.format('  rounds per minute (fire-mode +8, where it starts): the game\'s %.0f -> %s%s', base,
                    want.rpm and string.format('%.0f (x%g)', base * RPM_START, RPM_START) or 'the game\'s (off in the Mod Options Menu)', where_note('fire'))
                lines[#lines + 1] = string.format('  hold-reload fire-rate choice (weapon data +%d, the %s input -> 2; fire-mode +4 / +12 -> %.0f / %.0f): %s%s', ROF_AT, ROF_AT == 188 and 'right' or 'left', base, base * 2,
                    want.rpm and 'on' or 'off (the game\'s: none)', where_note('weapondata'))
                -- (3.6.1 release, the tester: "if you hold the context menu on the bastion, it also says Maelstrom on it ...
                -- you can just remove the label for maelstrom") 3.6.0 Test 10's menu title (the gun's id added to the
                -- encyclopedia look-up, pointing at the hull's entry) is gone: the game keeps the last title it showed, so
                -- the Bastion's menu said Maelstrom too. The menu shows what the game's own shows.
            end
        end
        if p.belt then
            -- (3.6.0 Test 7, the tester: "remove the reload entirely and put all 2100 rounds on 1 belt") Maelstrom Single Belt: the
            -- magazine record's rounds per belt (+136) become all the gun starts with (300 x (6 spare + 1) = 2100) and its
            -- spare belts (+140 start, +144 refill, +148 most) 0, so it never reloads (Test 8, the tester: "a maelstrom cant resupply?
            -- Reload shouldnt do anything, and instead it should allow you to change the RPM on the fly": with nothing to
            -- load, a tap of reload does nothing; holding it opens the Fire Rate option's fire-rate choice).
            -- Found in its magazine record as the game's 300, 6, 6, 6 (or this mod's own 2100, 0, 0, 0) only: (3.6.0 review)
            -- any other values (a patch) are refused rather than guessed at.
            local where = nil
            if m then
                local blob, stride = T.magazine.blob, T.magazine.stride
                for o = 0, stride - 16, 4 do
                    local a, b, c, d = u32(blob, m + o), u32(blob, m + o + 4), u32(blob, m + o + 8), u32(blob, m + o + 12)
                    if (a == GUN.belt and b == GUN.mags and c == GUN.mags and d == GUN.mags)
                        or (a == GUN.belt * (GUN.mags + 1) and b == 0 and c == 0 and d == 0) then
                        where = {kind = 'magazine', rel = m + o, o = o}
                        break
                    end
                end
            end
            local now = {}
            for k = 0, 3 do now[k] = where and live_now(where.kind, where.rel + 4 * k) end
            if where and not (now[0] and now[1] and now[2] and now[3]) then
                lines[#lines + 1] = '  belt: found, but its record could not be read (left alone)'
            elseif where then
                local function key(k) return where.kind .. ':' .. GUN.entity .. ':' .. (where.o + 4 * k) end
                local g_mags = game_value(key(1), now[1], function(v) return v == 0 end)
                local g_cap = game_value(key(0), now[0], function(v, g) return v == g * (g_mags + 1) end)
                local single = g_cap * (g_mags + 1)
                local g_refill = game_value(key(2), now[2], function(v) return v == 0 end)
                local g_max = game_value(key(3), now[3], function(v) return v == 0 end)
                for k, e in ipairs({{g_cap, single}, {g_mags, 0}, {g_refill, 0}, {g_max, 0}}) do
                    local w = place({group = 'belt', kind = where.kind, rel = where.rel + 4 * (k - 1), game = e[1], base = e[1], on = e[2]})
                    watch[#watch + 1] = w
                    changed = changed + write_entry(w, desired(w))
                end
                lines[#lines + 1] = string.format('  belt (%s +%d..+%d): the game\'s %d rounds, %d spare belts (refill %d, most %d) -> %s%s', where.kind, where.o, where.o + 12,
                    g_cap, g_mags, g_refill, g_max, want.belt and string.format('one belt of %d, no spare belts (no reload)', single)
                    or 'the game\'s (off in the Mod Options Menu)', where_note(where.kind))
            else
                lines[#lines + 1] = '  belt: NOT FOUND (not the game\'s 300 rounds and 6 spare belts in its magazine record)'
            end
        end
    end
    -- keep only what the checks need (addresses), not the table copies
    S.lines, S.watch, S.watched = lines, watch, #watch
    for _, name in ipairs(KIND_NAMES) do for _, c in ipairs(found[name]) do c.blob = nil end end
    return changed, #watch > 0
end

-- Every few seconds (and at once after a menu change): the tables are still there and hold what is wanted; set again
-- if the game put its own back, scan again if a table moved.
local function check()
    for kind, t in pairs(S.T) do
        for _, block in ipairs(t.copies) do
            local head = api.read(block, HEADER)
            if not head or head:sub(1, 8) ~= NEEDLE or u32(head, 8) ~= KINDS[kind].type or u32(head, 12) ~= t.payload then
                return 'moved'
            end
        end
    end
    for _, lv in pairs(S.live or {}) do
        local root = u64_at(lv.global)
        if not root or u64_at(root + lv.table_at) ~= lv.tbl then return 'moved' end
    end
    local held = 0
    local on = wanted().rpm             -- (turned off: the entries the other way round, so the name slot loses its id first)
    for i = on and 1 or #S.watch, on and #S.watch or 1, on and 1 or -1 do
        local w = S.watch[i]
        local want = desired(w)
        local before = w.last
        if write_entry(w, want) > 0 and before == want and want ~= w.game then
            S.resets = S.resets + 1
            event(string.format('%s value in the %s table was back at the game\'s; set again', w.group, w.kind))
        end
        if held_now(w) then held = held + 1 end
    end
    if S.switched then
        -- (Test 13) the change, in the log
        local want = wanted()
        event(string.format('changed in the Mod Options Menu: fire rate %s, single belt %s', want.rpm and 'on' or 'off', want.belt and 'on' or 'off'))
        S.switched = false
    end
    S.checks, S.last_check, S.held = S.checks + 1, api.now(), held
    return 'ok'
end

-- ---------------------------------------------------------------- main loop
-- (3.6.2 Test 4, the tester: "same with most of the Armored Overhaul modules") Once applied: the log written only when
-- something changes (3.6.1: every 60 s); the refresh pass through all memory every 5 minutes only for a table whose game
-- copy (the one the game reads, followed by its settings-root global at every check) wasn't found; nothing at all with
-- neither Maelstrom Fire Rate nor Single Belt picked. The values stay checked every 5 s (a handful of small reads): a
-- Maelstrom takes them as it is called in, wherever you are (3.6.2 review: Test 4 checked once a minute out of a tank).
local CHECK_EVERY, REFRESH = 5, 300
local function needs_refresh()
    for kind in pairs(S.T or {}) do if not (S.live and S.live[kind]) then return true end end
    return false
end
local function run()
    local skip_low = (api.address_of(NEEDLE) or LOW) < LOW
    local started, passes, shared_found = api.now(), 0, nil
    -- (3.6.0 review) a menu change cuts a wait short only once the tables are applied (before that, the next apply takes
    -- it anyway: Test 13 ran the search passes back to back, each with a fresh budget, while a menu value was waiting)
    local function wait(seconds)
        local until_t, yielded = api.now() + seconds, false
        while api.now() < until_t and not (S.switched and S.sig) do coroutine.yield(); yielded = true end
        if yielded then slice_end = api.now() + BUDGET end
    end
    local function watch()               -- checks every 5 s; returns when a table moved
        local refreshed = api.now()
        while true do
            wait(CHECK_EVERY)
            if check() == 'moved' then event('a settings table moved; scanning again'); S.sig, S.swept = nil, nil; return end
            if api.now() - refreshed >= REFRESH and needs_refresh() then
                refreshed = api.now()
                scan_pass(skip_low, false, true)
                if found_sig() ~= S.sig then event('the settings tables changed; scanning again'); S.sig, S.swept = nil, nil; return end
            end
        end
    end
    while true do
        if S.sig then
            watch()
            started, passes, shared_found = api.now(), 0, nil
        else
            passes = passes + 1
            local sweep = passes > 1 and (api.now() - started) > 180 and not S.swept
            if sweep then S.swept = true end
            local chains = scan_pass(skip_low, sweep)
            local T = parse_found()
            -- (3.6.0) every table is the gun's own: the wait for the rest starts once one of them is in (the game has
            -- loaded its settings), so a long load screen never counts towards it
            local any = false
            for _, name in ipairs(KIND_NAMES) do if T[name] then any = true end end
            if any then shared_found = shared_found or api.now() end
            -- the gun's tables can load a little apart: wait for all of them a while
            local all_in = true
            for _, name in ipairs(KIND_NAMES) do if not T[name] then all_in = false end end
            if shared_found and (all_in or api.now() - shared_found >= OPTIONAL_WAIT) then
                S.sig = found_sig()
                S.switched = false
                local n, ok = apply(T)
                S.status = string.format('%s; tables found in %.1f s (%d pass%s, %d table chains); %d value(s) written',
                    ok and 'active' or 'nothing to change (see below)', api.now() - started, passes, passes == 1 and '' or 'es', chains, n)
                event('tables found; ' .. n .. ' value(s) written')
                write_log()
            else
                S.status = 'searching (pass ' .. passes .. '); waiting for: ' .. (T.absent or 'the gun\'s tables')
                if passes == 1 or passes % 20 == 0 then event(S.status) end
                wait(passes < 60 and 0.5 or 5)
            end
        end
    end
end

-- ---------------------------------------------------------------- Mod Options Menu (3.0)
local menu_rows, menu_set, menu_link = {}, nil, nil
do
    local MENU_ORDER = {'speed', 'power', 'grip', 'steering', 'throttle', 'stability', 'collision', 'maelstrom', 'turret', 'autoloader', 'gunner_drive', 'driver_panel', 'camera', 'run_flat', 'indicator', 'loadout'}
    local hub = rawget(_G, 'ArmoredOverhaulMenu')
    if type(hub) ~= 'table' or type(hub.groups) ~= 'table' then hub = {groups = {}, done = {}}; rawset(_G, 'ArmoredOverhaulMenu', hub) end
    for _, g in ipairs({'maelstrom'}) do
        hub.groups[g] = {status = S,
            rows = function() local r = menu_rows[g]; if type(r) == 'function' then r = r() end; return r or {} end,
            set = function(key, value) return menu_set(key, value) end}
    end
    local function add(M, g)
        local e = hub.groups[g]
        if not e or hub.done[g] then return end
        hub.done[g] = true
        local okr, rows = pcall(e.rows)
        local st = e.status
        st.menu_added = st.menu_added or 0
        for _, r in ipairs(okr and rows or {}) do
            local id, spec, key = r[1], r[2], r[3]
            spec.mod = 'ARMORED OVERHAUL'
            local ok, done, why = pcall(M.register_option, id, spec)
            if ok and done then
                st.menu_added = st.menu_added + 1
                local okg, v = pcall(M.get, id)
                if okg and v ~= nil then pcall(e.set, key, v) end
                pcall(M.on_change, id, function(value) pcall(e.set, key, value) end)
            else
                st.menu_failed = id .. ': ' .. tostring(ok and why or done)
            end
        end
        st.options_menu = st.menu_added .. ' setting(s) in the MODS tab' .. (st.menu_failed and ('; not added: ' .. st.menu_failed) or '')
    end
    local at = 0
    menu_link = function(frame)
        if frame ~= true and frame < at then return end   -- (true: after_startup, at once)
        at = (frame == true and 0 or frame) + 60
        local mine = true
        for _, g in ipairs({'maelstrom'}) do if not hub.done[g] then mine = false end end
        if mine then at = math.huge; return end
        local M = rawget(_G, 'ModOptionsMenu')
        if type(M) ~= 'table' or M.api ~= 1 or type(M.register_option) ~= 'function' then return end
        for _, g in ipairs(MENU_ORDER) do pcall(add, M, g) end
        for g in pairs(hub.groups) do pcall(add, M, g) end   -- (a group not in MENU_ORDER: last)
    end
end
do
    local L = rawget(_G, 'CowboyBingusModLoader')
    if type(L) == 'table' and type(L.after_startup) == 'function' then pcall(L.after_startup, function() pcall(menu_link, true) end) end
end
-- the installed options' rows (built when the menu is found: the option addons have all loaded by then)
menu_rows.maelstrom = function()
    local p, rows = rawget(_G, 'ArmoredOverhaulMaelstromPicks'), {}
    if type(p) ~= 'table' then p = {} end
    if p.rpm == true then
        rows[#rows + 1] = {'armored_overhaul.maelstrom_fire_rate', {type = 'toggle', label = 'Maelstrom Fire Rate', default = true,
            description = 'Hold reload in the Maelstrom\'s gun seat to switch its main gun\'s fire rate on the fly: 1200, 1800 (where it starts) or 2400 rounds a minute (the game: 1200 only); the new rate pops up by the ammo bar as the menu closes. A change here reaches the next Maelstrom called in, not one already out. Off: the game\'s own.'}, 'rpm'}
    end
    if p.belt == true then
        rows[#rows + 1] = {'armored_overhaul.maelstrom_single_belt', {type = 'toggle', label = 'Maelstrom Single Belt', default = true,
            description = 'The Maelstrom\'s main gun carries all its ammo on one belt (2,100 rounds) and never reloads: reload does nothing (hold it for the fire-rate choice when Maelstrom Fire Rate is on). A change here reaches the next Maelstrom called in, not one already out. Off: the game\'s 300-round belts.'}, 'belt'}
    end
    return rows
end
-- A Maelstrom takes its belt and fire rate when it is called in, and one already out keeps them (Test 6). A Fire Rate /
-- Single Belt change applies at once, for the next Maelstrom called in (Tests 7-11 waited until none was out; Test 12,
-- the tester: a new tank dropped next to the old one got the old values).
local MAELSTROM_HULL = 'content/fac_helldivers/vehicles/tank_storm/tank_storm'
local function maelstrom_out()     -- true / false, nil when the engine can't tell (then changes apply at once)
    local SR = rawget(_G, 'stingray')
    local A, W = type(SR) == 'table' and SR.Application, type(SR) == 'table' and SR.World
    if type(A) ~= 'table' or type(W) ~= 'table' then return nil end
    local okw, world = pcall(A.main_world)
    if not okw or world == nil then return nil end
    local ok, list = pcall(W.units_by_resource, world, MAELSTROM_HULL)
    if not ok or type(list) ~= 'table' then return nil end
    return #list > 0
end
menu_set = function(key, v)
    local want = wanted()
    local val
    if key == 'rpm' then val = v == true or v == 1
    elseif key == 'belt' then val = v == true or v == 1
    else return end
    if want[key] == val then return end
    want[key] = val
    if maelstrom_out() == true then
        event(string.format('%s %s: for the next Maelstrom called in (the one out keeps what it was called in with)',
            key == 'rpm' and 'Maelstrom Fire Rate' or 'Maelstrom Single Belt', val and 'on' or 'off'))
    end
    S.switched = true; S.dirty = true
end

-- ---------------------------------------------------------------- start
local ok, failure = pcall(function()
    api = rawget(_G, 'ArmoredOverhaulMaelstromWeaponsTestApi') or build_api()
end)
if not ok then
    S.status = 'off: ' .. tostring(failure)
    write_log()
    return
end
S.running = true
S.t0 = api.now()

local worker = coroutine.create(run)
local next_flush = 0
local function tick()
    S.frame = S.frame + 1
    menu_link(S.frame)
    if S.frame < 120 or coroutine.status(worker) == 'dead' then return end
    if S.frame == 120 then
        local p = picks()
        if not (p.rpm or p.belt) then
            S.status, S.nothing = 'off: neither Maelstrom Fire Rate nor Maelstrom Single Belt is picked', true
            write_log()
        end
    end
    if S.nothing then return end
    slice_end = api.now() + BUDGET
    local fine, err = coroutine.resume(worker)
    if not fine then
        S.status = 'stopped after an error: ' .. tostring(err)
        event(S.status)
        write_log()
        return
    end
    local now = api.now()
    if S.dirty and now >= next_flush then next_flush = now + 1; write_log() end
end
S.tick = tick

local previous_update = update
if type(previous_update) ~= 'function' then S.status = 'off: the game update hook is unavailable'; write_log(); return end
local function after(fine, ...)
    if not fine then error((...), 0) end
    pcall(tick)
    return ...
end
update = function(...) return after(pcall(previous_update, ...)) end
write_log()

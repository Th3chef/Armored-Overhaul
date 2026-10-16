-- HD2-Addon: mods/chef/armored_overhaul_maelstrom_weapons
-- Armored Overhaul 3.6.0 - Maelstrom weapons: the TD-110 Maelstrom's settings for three options, each its own pick
-- (its option addon sets ArmoredOverhaulMaelstromPicks): Maelstrom Missile Demolition (the missiles of its two pods hit
-- with demolition force 40 instead of the game's 30 on a direct hit, so they break the walls and fences in their way),
-- Maelstrom Fire Rate (a hold-reload choice of the main gun's rounds per minute x1 / x1.5 / x2) and Maelstrom Single
-- Belt (all its ammo on one belt, no reload). Written for Armored Overhaul from the author's own Leveller & Solo Silo Demo
-- Force 50 core (the same settings-table scan).
--
-- How it works: the game keeps its weapon settings in tables in memory (each behind a 24-byte 'LDLD' header; found by
-- their table type and layout, never by fixed addresses). From the pods' weapon (tank_storm_silo, entity
-- 8AFF7F0793A5BCED) the fire-mode / rounds tables lead to its projectile (the 66mm Missile, 245), its direct-hit damage
-- record (237: 1100 damage, AP 6, demolition 30) and its impact explosion (148) and that explosion's damage record. Only
-- records that hold a value from FROM up to TO and that nothing else in the game uses are raised to TO (the blast's
-- record is shared, so only the direct hit changes). The main gun (tank_storm_maingun, D58AE6A04EDB10DE: 12.5mm, 1200
-- rpm, 300-round belt, 6 spare belts): its fire-mode record's rates (+4/+8/+12), its weapon data's left-input function
-- (+184: the fire-rate choice), one encyclopedia look-up slot (the menu's title) and its magazine record's belt and
-- spare belts. Every copy of a table is written and read back. Every 5 s the values are checked (set
-- again if the game put its own back); every 5 minutes a headers-only scan looks for moved or new tables. Turning it
-- off in the Mod Options Menu puts the game's values back (also kept in a process environment variable, so a copy of
-- this addon loaded again while the game runs knows them). Writes ArmoredOverhaul-MaelstromWeapons.log.
-- (Multiplayer: like the game's other hit rules, most likely decided by the host's game.)
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
local VERSION = ({version = '3.6.0'}).version   -- (as the other addons write it, so test builds name themselves)

-- The game's values we expect and the value we set: records from FROM up to (not including) TO are raised to TO.
local FROM, TO = 20, 40
local MISSILE = { name = 'Maelstrom missile pods', entity = '8AFF7F0793A5BCED' }
local GUN = { name = 'Maelstrom main gun', entity = 'D58AE6A04EDB10DE', belt = 300, mags = 6, rpm = 1200 }   -- (the game's belt, spare belts and rate)
local ENV_NAME = 'ARMORED_OVERHAUL_MAELSTROM_GAME'

-- The settings tables this addon reads. type = the table's type hash in its header; stride = record size in this game
-- build (row tables re-derive it when it changes and they carry no tail data).
local KINDS = {
    fire = { type = 0x45171B68, stride = 616, keyed = true, optional = true },    -- +0 projectile
    rounds = { type = 0x66081072, stride = 136, keyed = true, optional = true },  -- +64 projectile
    projectile = { type = 0xBD4042C2, stride = 272 },                -- +60 damage, +144 impact / +156 expiry explosion
    explosion = { type = 0x2AEA2592, stride = 152, tail = true },    -- +4 damage, +16/20/24 radii, +80 fragments, +84 fragment projectile
    damage = { type = 0xE0A72CF0, stride = 76 },                     -- +4 damage, +12 armor pen., +28 demolition
    magazine = { type = 0xFB8D88A3, stride = 160, keyed = true, optional = true },    -- +136 rounds per magazine, then magazines, refill, most
    weapondata = { type = 0x88E4DBB1, stride = 1232, keyed = true, optional = true }, -- +184 / +188 the inputs' functions (2 = fire rate)
    encyclopedia = { type = 0x8A40FE2F, stride = 56, keyed = true, optional = true },  -- an entity's names (+0 name, +8 upper, ...)
    explosive = { type = 0xF5CF9B8C, stride = 360, keyed = true, optional = true },    -- +36 / +40 the explosions a stratagem sets off
}
local KIND_NAMES = { 'fire', 'rounds', 'projectile', 'explosion', 'damage', 'magazine', 'weapondata', 'encyclopedia', 'explosive' }
local OPTIONAL_WAIT = 60   -- seconds to wait for the weapon's own tables after the shared ones are found
local AT = { fire_projectile = 0, rounds_projectile = 64, proj_damage = 60, proj_impact = 144, proj_expiry = 156,
             expl_damage = 4, expl_inner = 16, expl_outer = 20, expl_shock = 24, expl_frag_count = 80,
             expl_frag_projectile = 84, dmg_damage = 4, dmg_ap = 12, dmg_demolition = 28 }

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

local function hex_of(key)
    return string.format('%08X%08X', u32(key, 4), u32(key, 0))
end

-- (Test 10) the encyclopedia table may hold the gun's look-up slot this addon added (it shares the hull's record): not
-- counted as an entity of its own when the table's layout is worked out, so a later scan still reads the table
KINDS.encyclopedia.ignore = key_of(GUN.entity)
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
        local out = { 'Armored Overhaul - Maelstrom weapons (Missile Demolition, Fire Rate, Single Belt)', 'version: ' .. VERSION,
                      'running: ' .. string.format('%.0f s', api and S.t0 and (api.now() - S.t0) or 0),
                      'status: ' .. S.status, 'options menu: ' .. S.options_menu }
        if S.checks > 0 then
            out[#out + 1] = string.format('checks: %d (every 5 s); values as wanted: %d of %d; set again after the game reset them: %d',
                S.checks, S.held or 0, S.watched or 0, S.resets)
        end
        out[#out + 1] = ''
        for _, line in ipairs(S.lines) do out[#out + 1] = line end
        if S.research then out[#out + 1] = ''; out[#out + 1] = '-- tester: hold-reload fire rate research --'; out[#out + 1] = S.research end
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

-- Row table: u64, u32 row count, u32 0, then rows with a u32 id at +0 (then, with a tail, the data
-- the rows point to).
local function parse_rows(blob, spec)
    local rows = u32(blob, 8)
    if not rows or rows == 0 or u32(blob, 12) ~= 0 then return nil, 'not a row table' end
    local stride = spec.stride
    local size = 16 + rows * stride
    if not (size == #blob or (spec.tail and size <= #blob)) then
        if spec.tail or (#blob - 16) % rows ~= 0 then return nil, 'record size changed' end
        stride = (#blob - 16) / rows
        event(string.format('record size of the %s table changed: %d -> %d bytes', spec.name, spec.stride, stride))
    end
    local index = {}
    for row = 0, rows - 1 do
        local id = u32(blob, 16 + row * stride)
        if index[id] == nil then index[id] = 16 + row * stride end
    end
    return index, nil, stride
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

local function scan_pass(skip_low, sweep, headers_only, visit)
    for _, name in ipairs(KIND_NAMES) do found[name] = {} end
    local seen = {}
    local function table_at(address)
        if seen[address] or (skip_low and address < LOW) then return nil end
        local head = api.read(address, HEADER)
        if not head or head:sub(1, 8) ~= NEEDLE then return nil end
        local kind, payload = u32(head, 8), u32(head, 12)
        if payload < 16 or payload > 64 * 1024 * 1024 then return nil end
        seen[address] = true
        if visit then visit(address, kind, payload) end     -- (3.6.0 Test 5: the tester's research pass)
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
    local T, missing = {}, {}
    for _, name in ipairs(KIND_NAMES) do
        local spec = KINDS[name]
        for _, c in ipairs(found[name]) do
            local index, why, stride, buckets
            if spec.keyed then index, why, stride, buckets = parse_keyed(c.blob, spec)
            else index, why, stride = parse_rows(c.blob, spec) end
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
            local text = name .. (found[name][1] and (' (' .. #found[name] .. ' found, ' .. tostring(found[name][1].why) .. ')') or '')
            if spec.optional then T.absent = (T.absent and (T.absent .. ', ') or '') .. text
            else missing[#missing + 1] = text end
        end
    end
    return T, missing
end

-- What a pass found, in short: where the damage tables are and which tables exist. A refresh pass
-- reads headers only and re-applies only when this changes.
local function found_sig()
    local parts = {}
    for _, name in ipairs(KIND_NAMES) do
        local list = {}
        for _, c in ipairs(found[name]) do list[#list + 1] = name == 'damage' and string.format('%X:%d', c.address, c.payload) or '1' end
        parts[#parts + 1] = name .. '=' .. table.concat(list, ',')
    end
    return table.concat(parts, ' ')
end

-- ---------------------------------------------------------------- follow a weapon to its damage records
local function resolve(T, target)
    local key = key_of(target.entity)
    local out = { projectiles = {}, explosions = {}, damage = {}, order = {}, notes = {} }
    local queue = {}
    local function add_projectile(id, via)
        if id and id > 0 and not out.projectiles[id] then
            if not T.projectile.index[id] then out.notes[#out.notes + 1] = 'projectile ' .. id .. ' (' .. via .. ') not in the table'; return end
            out.projectiles[id] = via
            queue[#queue + 1] = { 'projectile', id, via }
        end
    end
    local function add_damage(id, via, explosion)
        if not id or id == 0 then return end
        local row = T.damage.index[id]
        if not row then out.notes[#out.notes + 1] = 'damage record ' .. id .. ' (' .. via .. ') not in the table'; return end
        if not out.damage[id] then
            out.damage[id] = { id = id, row = row, via = via, explosion = explosion }
            out.order[#out.order + 1] = id
        end
    end
    local r, f = T.rounds and T.rounds.index[key], T.fire and T.fire.index[key]
    if r then add_projectile(u32(T.rounds.blob, r + AT.rounds_projectile), 'rounds') end
    if f then add_projectile(u32(T.fire.blob, f + AT.fire_projectile), 'fire mode') end
    -- explosive record: the explosions it sets off (+36 main, +40 second)
    local e = target.explosive and T.explosive and T.explosive.index[key]
    if e then
        for _, x in ipairs({ { 36, 'explosive record (main)' }, { 40, 'explosive record (second)' } }) do
            local id = u32(T.explosive.blob, e + x[1])
            if id and id > 0 and T.explosion.index[id] and not out.explosions[id] then
                out.explosions[id] = x[2]
                queue[#queue + 1] = { 'explosion', id, x[2] }
            elseif id and id > 0 and not T.explosion.index[id] then
                out.notes[#out.notes + 1] = x[2] .. ' names explosion ' .. id .. ', which is not in the table'
            end
        end
    end
    if not r and not f and not target.explosions and #queue == 0 then
        return nil, (T.fire and ('weapon ' .. target.entity .. ' is not in the fire-mode tables') or 'its fire-mode table was not found')
    end
    -- cross-check (or, without the explosive record, the way in): recognise the explosions by their values
    for _, sig in ipairs((not r and not f) and target.explosions or {}) do
        local hits, xb, db = {}, T.explosion.blob, T.damage.blob
        for id, x in pairs(T.explosion.index) do
            local function near(off, want) return math.abs(f32(u32(xb, x + off)) - want) < 0.05 end
            if near(AT.expl_inner, sig[2]) and near(AT.expl_outer, sig[3]) and near(AT.expl_shock, sig[4]) then
                local d = T.damage.index[u32(xb, x + AT.expl_damage) or 0]
                if d and u32(db, d + AT.dmg_damage) == sig[5] and u32(db, d + AT.dmg_ap) == sig[6] then hits[#hits + 1] = id end
            end
        end
        if #hits == 1 and e then
            if not out.explosions[hits[1]] then
                out.notes[#out.notes + 1] = sig[1] .. ': its values now match explosion ' .. hits[1] .. ', which the explosive record does not name (game changed?)'
            end
        elseif #hits == 1 then
            out.explosions[hits[1]] = sig[1] .. ' (recognised by radius and damage)'
            queue[#queue + 1] = { 'explosion', hits[1], out.explosions[hits[1]] }
        elseif e then
            out.notes[#out.notes + 1] = sig[1] .. ': values changed since this build (explosive record used as is)'
        else
            out.notes[#out.notes + 1] = string.format('%s (radius %g/%g/%g m, damage %d, armour pen. %d): %d matches, need exactly 1',
                sig[1], sig[2], sig[3], sig[4], sig[5], sig[6], #hits)
        end
    end
    if #queue == 0 then return nil, 'not in the fire-mode tables and its explosions were not recognised: ' .. table.concat(out.notes, '; ') end
    local steps = 0
    while #queue > 0 and steps < 64 do
        steps = steps + 1
        local job = table.remove(queue, 1)
        if job[1] == 'projectile' then
            local p, pb = T.projectile.index[job[2]], T.projectile.blob
            add_damage(u32(pb, p + AT.proj_damage), job[3] .. ' -> projectile ' .. job[2] .. ' direct hit')
            for _, x in ipairs({ { AT.proj_impact, 'impact' }, { AT.proj_expiry, 'expiry' } }) do
                local id = u32(pb, p + x[1])
                if id and id > 0 and not out.explosions[id] then
                    if T.explosion.index[id] then
                        out.explosions[id] = job[3] .. ' -> projectile ' .. job[2] .. ' ' .. x[2]
                        queue[#queue + 1] = { 'explosion', id, out.explosions[id] }
                    else
                        out.notes[#out.notes + 1] = 'explosion ' .. id .. ' not in the table'
                    end
                end
            end
        else
            local x, xb = T.explosion.index[job[2]], T.explosion.blob
            add_damage(u32(xb, x + AT.expl_damage), job[3] .. ' explosion ' .. job[2], job[2])
            local count = u32(xb, x + AT.expl_frag_count) or 0
            if count > 0 and count <= 1000 then add_projectile(u32(xb, x + AT.expl_frag_projectile), job[3] .. ' explosion ' .. job[2] .. ' fragments') end
        end
    end
    if #out.order == 0 then return nil, 'no damage records found (the table layout may have changed)' end
    return out
end

-- What else uses these records: rows outside this weapon's chain that point at them.
local function sharing(T, chains)
    local mine_p, mine_x, mine_keys = {}, {}, {}
    for _, c in ipairs(chains) do
        for id in pairs(c.res.projectiles) do mine_p[id] = true end
        for id in pairs(c.res.explosions) do mine_x[id] = true end
        mine_keys[key_of(c.target.entity)] = true
    end
    local dmg_refs, proj_refs = {}, {}
    local function ref(t, id, who) if id and id > 0 then t[id] = t[id] or {}; table.insert(t[id], who) end end
    local pb, ps = T.projectile.blob, T.projectile.stride
    for row = 0, u32(pb, 8) - 1 do
        local o = 16 + row * ps
        local id = u32(pb, o)
        if not mine_p[id] then ref(dmg_refs, u32(pb, o + AT.proj_damage), 'projectile ' .. id) end
    end
    local xb, xs = T.explosion.blob, T.explosion.stride
    for row = 0, u32(xb, 8) - 1 do
        local o = 16 + row * xs
        local id = u32(xb, o)
        if not mine_x[id] then
            ref(dmg_refs, u32(xb, o + AT.expl_damage), 'explosion ' .. id)
            if (u32(xb, o + AT.expl_frag_count) or 0) > 0 then ref(proj_refs, u32(xb, o + AT.expl_frag_projectile), 'explosion ' .. id) end
        end
    end
    for _, k in ipairs({ { 'fire', AT.fire_projectile }, { 'rounds', AT.rounds_projectile } }) do
        local t = T[k[1]] or { index = {} }
        for key, o in pairs(t.index) do
            if not mine_keys[key] then ref(proj_refs, u32(t.blob, o + k[2]), 'weapon ' .. hex_of(key)) end
        end
    end
    return dmg_refs, proj_refs
end


-- ---------------------------------------------------------------- what is wanted
-- (Test 11, the tester: "Fire rate should only go from 1x, 1.5x, 2x. and only in the reload context menu, make Fire rate selector
-- a toggle in the mod options") Fire Rate on = the hold-reload choice of the game's rate x1 / x1.5 / x2 (1200 / 1800 /
-- 2400; it starts at the middle one, the game's default slot).
-- The picks come from the option addons (ArmoredOverhaulMaelstromPicks: missile, rpm and belt = true), read when the
-- tables are applied; the Mod Options Menu turns each on or off in game.
local RPM_MID = 1.5        -- the middle of the three rates (x1 / x1.5 / x2)
local function picks()
    local p = rawget(_G, 'ArmoredOverhaulMaelstromPicks')
    return type(p) == 'table' and p or {}
end
S.want = nil                -- {missile = bool, rpm = bool, belt = bool}
local function wanted()
    if not S.want then
        local p = picks()
        S.want = {missile = p.missile == true, rpm = p.rpm == true, belt = p.belt == true}
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
-- A watched value: group ('missile' / 'rpm' / 'belt'), table kind, `rel` = its place in the table's payload, `idrel` /
-- `idb` = where the record's id is and what it must be (row tables), `game` = the game's raw value, `base` = the
-- game's value as a number (the float for rpm), `last` = what this addon wrote last.
local function desired(w)
    local want = wanted()
    if w.group == 'missile' then return want.missile and TO or w.game end
    if w.group == 'rpm' then return want.rpm and f32_bits(w.base * RPM_MID) or w.game end
    -- (the hold-reload fire-rate choice: the game's rate as the low one, twice it as the high one, the function on)
    if w.group == 'rpm_lo' then return want.rpm and f32_bits(w.base) or w.game end
    if w.group == 'rpm_hi' then return want.rpm and f32_bits(w.base * 2) or w.game end
    if w.group == 'rof' then return want.rpm and 2 or w.game end
    if w.group == 'name' then return want.rpm and w.on or w.game end
    if w.group == 'belt' then return want.belt and w.on or w.game end    -- (Single Belt: w.on = the value with it on)
    return w.game
end
-- writes `value` into every copy of the entry's table whose value there is the game's or the one written last (and
-- whose record has the right id, for row tables); returns how many copies were written
-- the value an entry has when its option is on (what this mod writes)
local function on_value(w)
    if w.group == 'missile' then return TO end
    if w.group == 'rpm' then return f32_bits(w.base * RPM_MID) end
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
local HULL = 'B0C9FAF4AF8903F9'      -- the TD-110 Maelstrom (tank_storm)
local function slot_home(keyb, n)
    local lo, hi = u32(keyb, 0), u32(keyb, 4)
    return ((hi % n) * (4294967296 % n) + lo % n) % n
end
local function menu_title(T, want, place, watch)
    local E = T.encyclopedia
    if not E or not E.buckets then return 'menu title: the encyclopedia table not found' end
    local n, blob = E.buckets, E.blob
    local gun, hull = key_of(GUN.entity), key_of(HULL)
    local h = E.index[hull]
    if not h then return 'menu title: the Maelstrom hull is not in the encyclopedia table' end
    local hull_idx = (h - n * 16) / E.stride
    -- the game's look-up: the id's home slot, then the next ones, up to an empty one -> slot, 'here' / 'empty'
    local zero = string.rep('\0', 8)
    local function probe(key)
        local slot = slot_home(key, n)
        for _ = 1, n do
            local k = blob:sub(slot * 16 + 1, slot * 16 + 8)
            if k == key then return slot, 'here' end
            if k == zero then return slot, 'empty' end
            slot = slot + 1 == n and 0 or slot + 1
        end
    end
    -- (the look-up must find the hull and the FRV's MG-206 where the table has them, else the layout isn't as known)
    for _, hx in ipairs({HULL, '085C1EDB038EC24E'}) do
        local k = key_of(hx)
        local s2, f2 = probe(k)
        if E.index[k] and (f2 ~= 'here' or n * 16 + u32(blob, s2 * 16 + 8) * E.stride ~= E.index[k]) then
            return 'menu title: the encyclopedia look-up is not as known (left alone)'
        end
    end
    local slot, found = probe(gun)
    if not found then return 'menu title: no free slot in the encyclopedia look-up' end
    local o = slot * 16
    if found == 'here' and u32(blob, o + 8) ~= hull_idx then return 'menu title: the gun has its own encyclopedia entry now (left alone)' end
    -- (in order: the record index, then the id's halves; turned off, the other way round: the id first. Either way the
    -- slot is never the gun's id with another record's index)
    if found == 'empty' and (u32(blob, o + 8) ~= 0 or u32(blob, o + 12) ~= 0) then return 'menu title: the free slot is not empty (left alone)' end
    local ws = {}
    for _, e in ipairs({{8, hull_idx}, {4, u32(gun, 4)}, {0, u32(gun, 0)}}) do
        local w = place({group = 'name', kind = 'encyclopedia', rel = o + e[1], game = 0, base = 0, on = e[2]})
        watch[#watch + 1] = w
        ws[#ws + 1] = w
    end
    for i = want.rpm and 1 or #ws, want.rpm and #ws or 1, want.rpm and 1 or -1 do write_entry(ws[i], desired(ws[i])) end
    return string.format('menu title: the gun -> the Maelstrom hull\'s encyclopedia entry (record %d; look-up slot %d of %d%s): %s', hull_idx, slot, n,
        found == 'here' and ', already set' or '', want.rpm and 'on' or 'off')
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
            lines[#lines + 1] = string.format('table %-10s not found (optional)', name)
        end
    end
    S.T, S.live = {}, {}
    for _, name in ipairs(KIND_NAMES) do if T[name] then S.T[name] = {copies = T[name].copies, payload = T[name].payload} end end
    local p = picks()
    -- the missiles: demolition FROM-TO-1 -> TO on the hit and the blast (records nothing else uses: the hit, in this game)
    if p.missile then
        local res, why = resolve(T, MISSILE)
        lines[#lines + 1] = ''
        if not res then
            lines[#lines + 1] = MISSILE.name .. ': NOT FOUND - ' .. why
        else
            local dmg_refs, proj_refs = sharing(T, { { target = MISSILE, res = res } })
            local fired_by = {}          -- explosion id -> the projectiles (not the missiles') that set it off
            do
                local pb, ps = T.projectile.blob, T.projectile.stride
                for row = 0, u32(pb, 8) - 1 do
                    local o = 16 + row * ps
                    local pid = u32(pb, o)
                    if not res.projectiles[pid] then
                        for _, at in ipairs({AT.proj_impact, AT.proj_expiry}) do
                            local x = u32(pb, o + at)
                            if x and x > 0 then fired_by[x] = fired_by[x] or {}; table.insert(fired_by[x], 'projectile ' .. pid) end
                        end
                    end
                end
                for key, e in pairs(T.explosive and T.explosive.index or {}) do
                    for _, at in ipairs({36, 40}) do
                        local x = u32(T.explosive.blob, e + at)
                        if x and x > 0 then fired_by[x] = fired_by[x] or {}; table.insert(fired_by[x], 'stratagem ' .. hex_of(key)) end
                    end
                end
                if not T.explosive then fired_by.unknown = true end
                for _, l in pairs(fired_by) do if type(l) == 'table' then table.sort(l) end end
            end
            lines[#lines + 1] = MISSILE.name .. ' (Maelstrom Missile Demolition' .. (want.missile and ')' or ', off in the Mod Options Menu)')
            for id, via in pairs(res.projectiles) do
                local users = proj_refs[id]
                lines[#lines + 1] = '  projectile ' .. id .. ' via ' .. via .. (users and ('; also used by ' .. table.concat(users, ', ')) or '')
            end
            for _, id in ipairs(res.order) do
                local d = res.damage[id]
                local db, row = T.damage.blob, d.row
                local radii = ''
                if d.explosion then
                    local x = T.explosion.index[d.explosion]
                    radii = string.format(', radius %.1f / %.1f / %.1f m', f32(u32(T.explosion.blob, x + AT.expl_inner)),
                        f32(u32(T.explosion.blob, x + AT.expl_outer)), f32(u32(T.explosion.blob, x + AT.expl_shock)))
                end
                local live = api.read(T.damage.copies[1] + HEADER + row + AT.dmg_demolition, 4)
                local demo = live and u32(live, 0) or u32(db, row + AT.dmg_demolition)
                local text = string.format('  damage record %d (%s): damage %d, armor pen. %d, demolition %d%s', id, d.via,
                    u32(db, row + AT.dmg_damage), u32(db, row + AT.dmg_ap), demo, radii)
                local users = dmg_refs[id]
                -- (Test 11 raised a record whose other users are only explosions nothing sets off, for the blast (392,
                -- shared with explosion 371): Test 12, the tester: "the missle blast radius hasnt changed anything, put it back
                -- to how it was". Shared records are left alone again; the log still says who else uses them.)
                local named = {}
                for k, who in ipairs(users or {}) do
                    local pid = tonumber(who:match('^projectile (%d+)$') or '')
                    local xid = tonumber(who:match('^explosion (%d+)$') or '')
                    local fired = xid and (fired_by[xid] or (fired_by.unknown and {'unknown: the explosive table not found'}))
                    local radii = ''
                    local xr = xid and T.explosion.index[xid]
                    if xr then
                        radii = string.format(', radius %.1f / %.1f / %.1f m', f32(u32(T.explosion.blob, xr + AT.expl_inner)),
                            f32(u32(T.explosion.blob, xr + AT.expl_outer)), f32(u32(T.explosion.blob, xr + AT.expl_shock)))
                    end
                    named[k] = who .. radii .. (pid and proj_refs[pid] and (' (fired by ' .. table.concat(proj_refs[pid], ', ') .. ')') or '')
                        .. (xid and (fired and (' (fired by ' .. table.concat(fired, ', ') .. ')') or ' (no projectile fires it)') or '')
                end
                if users then text = text .. '; also used by ' .. table.concat(named, ', ') end
                if users then
                    -- used by something else in the game too (another weapon's hit or blast): left as the game has it
                    text = text .. ' -> left alone'
                else
                    local game = game_value('damage:' .. id .. ':' .. AT.dmg_demolition, demo, function(v) return v == TO end)
                    if game >= FROM and game < TO then
                        local w = {group = 'missile', kind = 'damage', rel = row + AT.dmg_demolition, idrel = row, idb = u32_bytes(id), game = game, base = game, id = id}
                        watch[#watch + 1] = w
                        local n = write_entry(w, desired(w))
                        changed = changed + n
                        text = text .. (want.missile and string.format(' -> %d (the game\'s %d; %d of %d copies written)', TO, game, n, #T.damage.copies)
                            or string.format(' -> the game\'s %d', game))
                    else
                        text = text .. string.format(' -> left alone (not %d-%d)', FROM, TO - 1)
                    end
                end
                lines[#lines + 1] = text
            end
            for _, n in ipairs(res.notes) do lines[#lines + 1] = '  note: ' .. n end
        end
    end
    -- the main gun (3.6.0 Test 6): its rounds per minute (fire-mode record +4/+8/+12 floats: low / default / high), the
    -- hold-reload fire-rate choice (weapon data +184, the LEFT input's function: 2 = fire rate; the FRV's MG-206 has it on
    -- the right, +188, but in the Maelstrom's gun seat the right button also fires the missiles: Test 9, the tester: "lets move
    -- that to the main fire button";
    -- then the low and high rates are the game's and twice it) and its belt (magazine record +136: rounds, then
    -- magazines, refill, most). Each written in the LDLD table and in the game's own copy (the one the game reads).
    if p.rpm or p.belt then
        local live, live_lines = find_live(T)
        S.live = live
        local key = key_of(GUN.entity)
        local f, r = T.fire and T.fire.index[key], T.rounds and T.rounds.index[key]
        local m, wd = T.magazine and T.magazine.index[key], T.weapondata and T.weapondata.index[key]
        lines[#lines + 1] = ''
        lines[#lines + 1] = GUN.name .. (f and '' or ' (not in the fire-mode table)') .. (m and '' or ' (not in the magazine table)')
            .. (wd and '' or ' (not in the weapon-data table)')
        for _, l in ipairs(live_lines) do lines[#lines + 1] = '  ' .. l end
        if TESTER then
            if f then lines[#lines + 1] = '  fire-mode record: ' .. hexdump(T.fire.blob, f, math.min(160, T.fire.stride)) end
            if m then lines[#lines + 1] = '  magazine record: ' .. hexdump(T.magazine.blob, m, T.magazine.stride) end
            if r then lines[#lines + 1] = '  rounds record: ' .. hexdump(T.rounds.blob, r, T.rounds.stride) end
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
            local game = now and game_value('fire:' .. GUN.entity .. ':8', now, function(v, g) local a, b = f32(v), f32(g); return b > 0 and math.abs(a / b - RPM_MID) < 0.01 end)
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
                local rof_now, right_now = live_now('weapondata', wd + 184), live_now('weapondata', wd + 188)
                local lo_now, hi_now = live_now('fire', f + 4), live_now('fire', f + 12)
                if not (rof_now and right_now and lo_now and hi_now) then why = 'its records could not be read'
                else
                    g_rof = game_value('weapondata:' .. GUN.entity .. ':184', rof_now, function(v) return v == 2 end)
                    g_lo = game_value('fire:' .. GUN.entity .. ':4', lo_now, function(v) return v == f32_bits(base) end)
                    g_hi = game_value('fire:' .. GUN.entity .. ':12', hi_now, function(v) return v == f32_bits(base * 2) end)
                    if g_rof ~= 0 or right_now ~= 0 then why = 'the gun already has an input function'
                    elseif g_lo ~= 0 or g_hi ~= 0 then why = 'the gun already has low / high rates' end
                end
            end
            if why then
                lines[#lines + 1] = '  Maelstrom Fire Rate: not added (' .. why .. ')'
            else
                for _, e in ipairs({{'rpm', 'fire', f + 8, game}, {'rof', 'weapondata', wd + 184, g_rof}, {'rpm_lo', 'fire', f + 4, g_lo}, {'rpm_hi', 'fire', f + 12, g_hi}}) do
                    local w2 = place({group = e[1], kind = e[2], rel = e[3], game = e[4], base = base})
                    watch[#watch + 1] = w2
                    changed = changed + write_entry(w2, desired(w2))
                end
                lines[#lines + 1] = string.format('  rounds per minute (fire-mode +8, the middle choice): the game\'s %.0f -> %s%s', base,
                    want.rpm and string.format('%.0f (x%g)', base * RPM_MID, RPM_MID) or 'the game\'s (off in the Mod Options Menu)', where_note('fire'))
                lines[#lines + 1] = string.format('  hold-reload fire-rate choice (weapon data +184, the left input -> 2; fire-mode +4 / +12 -> %.0f / %.0f): %s%s', base, base * 2,
                    want.rpm and 'on' or 'off (the game\'s: none)', where_note('weapondata'))
                -- (Test 10, the tester: "you can just put Maelstrom as the title for the context menu") The menu's title is the
                -- weapon's name from its encyclopedia entry; the gun has none (the menu kept the last weapon's name, e.g.
                -- the Verdict). One slot of the encyclopedia table's look-up gets the gun's id pointing at the Maelstrom
                -- hull's own entry ("Maelstrom" / "MAELSTROM"): no record written. The slot is where the game's look-up
                -- (id modulo the slot count, then the next ones) stops for the gun now, so no other look-up changes.
                lines[#lines + 1] = '  ' .. menu_title(T, want, place, watch)
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
        -- (Test 13, the tester: "I dont think the demo force of the missles is being put back when its turned off mid game")
        -- the change and what the game's tables hold right after it
        local want, now = wanted(), {}
        for _, w in ipairs(S.watch) do
            if w.group == 'missile' then
                local v = api.read(S.T.damage.copies[1] + HEADER + w.rel, 4)
                now[#now + 1] = string.format('damage record %d demolition %s', w.id or 0, v and tostring(u32(v, 0)) or '?')
            end
        end
        event(string.format('changed in the Mod Options Menu: missile demolition %s, fire rate %s, single belt %s%s', want.missile and 'on' or 'off',
            want.rpm and 'on' or 'off', want.belt and 'on' or 'off', #now > 0 and ('; now ' .. table.concat(now, ', ')) or ''))
        S.switched = false
    end
    S.checks, S.last_check, S.held = S.checks + 1, api.now(), held
    return 'ok'
end

-- ---------------------------------------------------------------- (tester) where the hold-reload fire-rate choice lives
-- (3.6.0 Test 5, the tester: "make the Maelstrom RPM adjustments available in-game while you hold the reload button,
-- similar to how the vanilla game handles RPM tweaks"). The game offers that choice for weapons whose WeaponData names
-- the ROF function (2) for an input (the FRV's MG-206, 085C1EDB038EC24E, has it on the right; so do the Liberator,
-- 587878FB76F4B9B1, and the Stalwart, A6A735ACCB4A327F), with the rounds per minute low / default / high. Tester builds
-- look once through every settings table for the keyed ones listing the Maelstrom's gun and those three, and log the
-- table types and the record offsets where all three hold 2 with 0 before it while the Maelstrom's holds 0.
local REF = {mg = '085C1EDB038EC24E', lib = '587878FB76F4B9B1', stal = 'A6A735ACCB4A327F'}
local function research(skip_low)
    local keys = {gun = key_of(GUN.entity)}
    for k, v in pairs(REF) do keys[k] = key_of(v) end
    local out = {}
    scan_pass(skip_low, false, true, function(address, kind, payload)
        if payload > 8 * 1024 * 1024 then return end
        local blob = api.read(address + HEADER, payload)
        if not blob or not blob:find(keys.gun, 1, true) or not blob:find(keys.mg, 1, true) then return end
        local index, why, stride = parse_keyed(blob, {stride = 4, name = string.format('%08X', kind)})
        if not index then out[#out + 1] = string.format('type %08X (%d bytes): lists the gun, not readable as keyed (%s)', kind, payload, tostring(why)); return end
        local g, m, l, s = index[keys.gun], index[keys.mg], index[keys.lib], index[keys.stal]
        local cand = {}
        if g and m then
            for o = 4, stride - 4, 4 do
                local function at(r) return r and u32(blob, r + o) end
                local function before(r) return r and u32(blob, r + o - 4) end
                if at(m) == 2 and before(m) == 0 and (not l or at(l) == 2) and (not s or at(s) == 2) and at(g) == 0 then cand[#cand + 1] = '+' .. o end
            end
        end
        out[#out + 1] = string.format('type %08X (%d bytes, record %d): gun %s, MG-206 %s, Liberator %s, Stalwart %s; ROF candidates: %s', kind, payload, stride,
            g and 'yes' or 'no', m and 'yes' or 'no', l and 'yes' or 'no', s and 'yes' or 'no', #cand > 0 and table.concat(cand, ' ') or 'none')
        if g then
            -- (Test 6) where the gun's record holds 1200.0 (its rate) or 300 (its belt); the weapon data in full
            local at = {}
            for o = 0, stride - 4, 4 do
                local v = u32(blob, g + o)
                if v == 0x44960000 then at[#at + 1] = '+' .. o .. '=1200.0' elseif v == 300 then at[#at + 1] = '+' .. o .. '=300' end
            end
            if #at > 0 then out[#out + 1] = '    gun record holds: ' .. table.concat(at, ' ') end
            local n = kind == KINDS.weapondata.type and stride or math.min(stride, 256)
            for o = 0, n - 4, 256 do out[#out + 1] = string.format('    gun record +%d: ', o) .. hexdump(blob, g + o, math.min(256, n - o)) end
        end
    end)
    S.research = #out > 0 and table.concat(out, '\n') or 'no table lists both the gun and the MG-206'
    S.dirty = true
end

-- ---------------------------------------------------------------- main loop
local REFRESH = 300   -- seconds between refresh passes (headers only) looking for moved or new tables
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
    local function watch_for(seconds)   -- checks every 5 s; false when a table moved
        for _ = 1, math.floor(seconds / 5) do
            wait(5)
            if check() == 'moved' then event('a settings table moved; scanning again'); S.sig, S.swept = nil, nil; return false end
            if api.now() >= (S.next_log or 0) then S.next_log = api.now() + 60; S.dirty = true end
        end
        return true
    end
    while true do
        if S.sig then
            if watch_for(REFRESH) then
                scan_pass(skip_low, false, true)
                if found_sig() ~= S.sig then event('the settings tables changed; scanning again'); S.sig, S.swept = nil, nil end
            end
            started, passes, shared_found = api.now(), 0, nil
        else
            passes = passes + 1
            local sweep = passes > 1 and (api.now() - started) > 180 and not S.swept
            if sweep then S.swept = true end
            local chains = scan_pass(skip_low, sweep)
            local T, missing = parse_found()
            if #missing == 0 then shared_found = shared_found or api.now() end
            -- the weapon's own tables can load a little later than the shared ones: wait for them a while
            local all_in = true
            for _, name in ipairs(KIND_NAMES) do if KINDS[name].optional and not T[name] then all_in = false end end
            if #missing == 0 and (all_in or api.now() - shared_found >= OPTIONAL_WAIT) then
                S.sig = found_sig()
                S.switched = false
                local n, ok = apply(T)
                S.status = string.format('%s; tables found in %.1f s (%d pass%s, %d table chains); %d value(s) written',
                    ok and 'active' or 'nothing to change (see below)', api.now() - started, passes, passes == 1 and '' or 'es', chains, n)
                event('tables found; ' .. n .. ' value(s) written')
                if TESTER and not S.researched then S.researched = true; research(skip_low); event('research pass done') end
                write_log()
                S.next_log = api.now() + 60
            else
                S.status = 'searching (pass ' .. passes .. '); waiting for: ' ..
                    (#missing > 0 and table.concat(missing, ', ') or (T.absent or 'the weapon\'s own tables'))
                if passes == 1 or passes % 20 == 0 then event(S.status) end
                wait(passes < 60 and 0.5 or 5)
            end
        end
    end
end

-- ---------------------------------------------------------------- Mod Options Menu (3.0)
local menu_rows, menu_set, menu_link = {}, nil, nil
do
    local MENU_ORDER = {'speed', 'power', 'grip', 'steering', 'throttle', 'stability', 'collision', 'missile', 'turret', 'autoloader', 'gunner_drive', 'driver_panel', 'camera', 'run_flat', 'indicator', 'loadout'}
    local hub = rawget(_G, 'ArmoredOverhaulMenu')
    if type(hub) ~= 'table' or type(hub.groups) ~= 'table' then hub = {groups = {}, done = {}}; rawset(_G, 'ArmoredOverhaulMenu', hub) end
    for _, g in ipairs({'missile'}) do
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
        for _, g in ipairs({'missile'}) do if not hub.done[g] then mine = false end end
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
menu_rows.missile = function()
    local p, rows = rawget(_G, 'ArmoredOverhaulMaelstromPicks'), {}
    if type(p) ~= 'table' then p = {} end
    if p.missile then
        rows[#rows + 1] = {'armored_overhaul.missile_demolition', {type = 'toggle', label = 'Maelstrom Missile Demolition', default = true,
            description = 'The Maelstrom\'s missiles hit with demolition force 40 instead of the game\'s 30, so they break tree branches, fences and walls in their way. Turning it off puts the game\'s own back.'}, 'missile'}
    end
    if p.rpm == true then
        rows[#rows + 1] = {'armored_overhaul.maelstrom_fire_rate', {type = 'toggle', label = 'Maelstrom Fire Rate', default = true,
            description = 'Hold reload in the Maelstrom\'s gun seat to switch its main gun\'s fire rate on the fly: 1200, 1800 or 2400 rounds a minute (the game: 1200 only). A change here reaches the next Maelstrom called in, not one already out. Off: the game\'s own.'}, 'rpm'}
    end
    if p.belt == true then
        rows[#rows + 1] = {'armored_overhaul.maelstrom_single_belt', {type = 'toggle', label = 'Maelstrom Single Belt', default = true,
            description = 'The Maelstrom\'s main gun carries all its ammo on one belt (2,100 rounds) and never reloads: reload does nothing (hold it for the fire-rate choice when Maelstrom Fire Rate is on). A change here reaches the next Maelstrom called in, not one already out. Off: the game\'s 300-round belts.'}, 'belt'}
    end
    return rows
end
-- A Maelstrom takes its belt and fire rate when it is called in, and one already out keeps them (Test 6). A Fire Rate /
-- Single Belt change applies at once, for the next Maelstrom called in (Tests 7-11 waited until none was out; Test 12,
-- the tester: a new tank dropped next to the old one got the old values). Missile Demolition is read at every hit: at once.
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
    if key == 'missile' then
        want.missile = v == true or v == 1
        S.switched = true; S.dirty = true
        return
    end
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

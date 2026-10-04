-- HD2-Addon: mods/chef/armored_overhaul_handling
-- Armored Overhaul 3.2.0 - Tank grip, Tank steering and Tank power options for the TD-220 Bastion and TD-110 Maelstrom
-- (one source, built once per option and strength; this copy is the 'grip' option, Maximum). Written from scratch.
--
-- How it works: the tanks drive on the engine's Havok vehicle kit. When a tank is set up, the game scales its Havok
-- wheels, engine and transmission by the tank's VehicleMotion settings (static VehicleMotionComponent table,
-- 0x1C8-byte records; tank values in brackets):
--   +0x164 wheel radius (0.9)          +0x168 wheel friction multiplier (0.7)          -> Tank grip
--   +0x16C steering rate (2.25): how fast the steering input may change per second      -> Tank steering
--   +0x15C engine torque scale (0.4): the engine's pulling power                        -> Tank power (1.3)
-- (+0x158 RPM scale sets the engine's speed; it stays the game's own.)
-- This addon finds that table through its generated accessor (hash % slot count, linear probe), looks the two tanks
-- up by entity hash and scales its fields. Tanks called in afterwards use the new values.
if type(jit) == 'table' and type(jit.off) == 'function' then jit.off(true, true) end
local PART = 'grip'
local TESTER = false
local PRESET, PRESET_NAME = 2.0, 'Maximum'   -- the strength picked in the mod manager (baked in per sub-option)
local PARTS = {
    grip = {global = 'ArmoredOverhaulHandling', file = 'TankHandling', title = 'Tank Grip', what = 'track grip',
            fields = {grip = 0x168}},
    steering = {global = 'ArmoredOverhaulSteering', file = 'TankSteering', title = 'Tank Steering', what = 'steering response',
                fields = {steering = 0x16C}},
    power = {global = 'ArmoredOverhaulPower', file = 'TankPower', title = 'Tank Power', what = 'engine pulling power',
             fields = {power = 0x15C}},
}
local P = PARTS[PART]
if not P or rawget(_G, P.global) then return end

local byte, min, max = string.byte, math.min, math.max
local TWO32 = 4294967296

local TANKS = {
    {key = 'bastion', name = 'Bastion', hi = 0x16474112, lo = 0x801385B6},
    {key = 'maelstrom', name = 'Maelstrom', hi = 0xB0C9FAF4, lo = 0xAF8903F9},
}
local FRICTION_AT, RADIUS_AT = 0x168, 0x164
local FIELD = P.fields
local FIELD_NAMES = {}
for k in pairs(FIELD) do FIELD_NAMES[#FIELD_NAMES + 1] = k end
table.sort(FIELD_NAMES)
local SPAN = 0                                       -- bytes from the record start to the end of the last field
for _, off in pairs(FIELD) do SPAN = max(SPAN, off + 4) end

-- Accessor shape (the VehicleMotion lookup, game.dll+0x507A00 in the Sept 2026 build). Immediates that may change
-- between game builds are wildcards and read back: settings-root offset, divide magic, slot count, stride, data offset.
local ACCESSOR = '48 85 C9 74 ?? 48 8B 05 ?? ?? ?? ?? 44 8B C1 4C 8B 90 ?? ?? ?? ?? 48 B8 ?? ?? ?? ?? ?? ?? ?? ?? 48 F7 E1'
local ACCESSOR_ANCHOR = '\x48\xF7\xE1\x48\x8B\xC1'
local ACCESSOR_ANCHOR_AT = 32
local TAIL = '8B 48 08 48 69 C1 ?? ?? ?? ?? 48 05 ?? ?? ?? ??'   -- mov ecx,[rax+8] / imul rax,rcx,stride / add rax,data
local SLOTS = '41 83 F9 ??'                                         -- cmp r9d, slot count
local KNOWN_RVA = 0x507A00
local KNOWN_TIMESTAMP = 0x6AB3B43F
-- (3.0.1 review) the game's own values on that build (both tanks): what is found there must be these, or it was
-- already scaled (an earlier copy of this addon whose Lua was rebuilt while the game kept running)
local VANILLA = {grip = 0.7, steering = 2.25, power = 0.4}
local STRENGTHS = {1.25, 1.5, 2}             -- (3.1.1 review) every option's three strengths (see the originals in apply)
local MAX_TRIES = 5
local CHECK_EVERY = 120     -- frames between checks while something is still missing or being written (~2 s)
local SETTLED_EVERY = 600   -- ... once both tanks hold the preset (~10 s): anything the game reset is put back

local state = {version = '3.2.0', status = 'starting', table = 'unresolved', how = 'none', slots = 0, game = 'unchecked',
               last_error = 'none',
               applied = 0, errors = 0, preset = 'unread', tanks = {}, frames = 0, clock = 0,
               options_menu = 'not installed (the mod manager\'s pick is used)'}
rawset(_G, P.global, state)

local loader = rawget(_G, 'CowboyBingusModLoader')
if type(loader) ~= 'table' or type(loader.version) ~= 'number' or loader.version < 15 then return end
local ok_ffi, ffi = pcall(require, 'ffi')
if not ok_ffi or not ffi.abi('win') or not ffi.abi('64bit') then return end

-- Own function-pointer types, so another mod's declarations can't clash with ours.
pcall(ffi.cdef, [[
    typedef struct { void *base; void *allocation_base; uint32_t allocation_protection; uint16_t partition;
        uint16_t reserved; size_t size; uint32_t state; uint32_t protection; uint32_t type; } TtRegion;
]])
-- The kernel32 functions below have to be declared before they can be looked up (1.1.0 relied on another mod having
-- declared them, and failed to load without it: "missing declaration for symbol 'GetModuleHandleA'"). Each is
-- declared on its own; if another mod already declared one (with its own types), that declaration is used, since
-- the function is cast to this addon's own pointer type anyway.
for _, decl in ipairs({'void *GetModuleHandleA(const char *);', 'void *GetCurrentProcess(void);',
        'int ReadProcessMemory(void *, const void *, void *, size_t, size_t *);',
        'size_t VirtualQuery(const void *, void *, size_t);', 'int VirtualProtect(void *, size_t, uint32_t, uint32_t *);'}) do
    pcall(ffi.cdef, decl)
end
local k32 = ffi.load('kernel32')
local GetModuleHandleA = ffi.cast('void *(*)(const char *)', k32.GetModuleHandleA)
local GetCurrentProcess = ffi.cast('void *(*)(void)', k32.GetCurrentProcess)
local ReadProcessMemory = ffi.cast('int (*)(void *, const void *, void *, size_t, size_t *)', k32.ReadProcessMemory)
local VirtualQuery = ffi.cast('size_t (*)(const void *, void *, size_t)', k32.VirtualQuery)
local VirtualProtect = ffi.cast('int (*)(void *, size_t, uint32_t, uint32_t *)', k32.VirtualProtect)
local U8 = ffi.typeof('uint8_t *')
local F32P = ffi.typeof('float *')
local process = GetCurrentProcess()
local BUF_SIZE = 0x40400
local buf = ffi.new('uint8_t[?]', BUF_SIZE)
local got = ffi.new('size_t[1]')
local region = ffi.new('TtRegion[1]')

local function num(p) return tonumber(ffi.cast('uintptr_t', p)) end
local function read(address, size)
    if address == nil or size <= 0 or size > BUF_SIZE then return nil end
    if ReadProcessMemory(process, address, buf, size, got) == 0 or got[0] ~= size then return nil end
    return ffi.string(buf, size)
end
local function u32(s, o)
    if not s or o < 0 or o + 4 > #s then return nil end
    local a, b, c, d = byte(s, o + 1, o + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function i32(s, o) local v = u32(s, o); return v and (v >= 0x80000000 and v - TWO32 or v) end
local function ptr(s, o)
    local lo, hi = u32(s, o or 0), u32(s, (o or 0) + 4)
    if not lo or not hi or hi >= 0x8000 then return nil end
    local v = hi * TWO32 + lo
    if v < 0x10000 then return nil end
    return ffi.cast(U8, v)
end
local box = ffi.new('uint8_t[4]')
local box_f = ffi.cast(F32P, box)
local function f32(s, o)
    if not s or o + 4 > #s then return nil end
    box[0], box[1], box[2], box[3] = byte(s, o + 1, o + 4)
    return tonumber(box_f[0])
end
-- Writes floats into game data. Read/write pages are written directly; read-only data pages are opened for the
-- write and restored straight after. Code, guard, no-access and reserved memory are never touched.
local old_prot = ffi.new('uint32_t[1]')
local function page_info(address, size)
    if VirtualQuery(address, region, ffi.sizeof('TtRegion')) == 0 then return nil end
    local r = region[0]
    if r.state ~= 0x1000 or num(address) + size > num(r.base) + tonumber(r.size) then return nil end
    return r.protection, r.type
end
local function poke(address, fields, values)
    local p = ffi.cast(F32P, address)
    for k, off in pairs(fields) do p[off / 4] = values[k] end
end
local function write_floats(address, size, fields, values)
    local prot, kind = page_info(address, size)
    if not prot then return false, 'memory not committed' end
    local how = string.format('page 0x%X/0x%X', prot, kind)
    if kind ~= 0x20000 and kind ~= 0x40000 and kind ~= 0x1000000 then return false, how end
    -- (3.0 review) 4 read/write; 8 write-copy (a module's data before its first write: writing makes the page
    -- this process's own copy, as any write by the game does)
    if prot == 4 or prot == 8 then poke(address, fields, values); return true, how end
    if prot ~= 2 then return false, how end
    local opened = VirtualProtect(address, size, 4, old_prot) ~= 0
    if not opened then opened = VirtualProtect(address, size, 8, old_prot) ~= 0 end
    if not opened then return false, how .. ', open refused' end
    local restore = old_prot[0]
    local ok = pcall(poke, address, fields, values)
    -- (3.0 review) the old protection put back, checked: a page left writable is said in the log
    local back = VirtualProtect(address, size, restore, old_prot) ~= 0
    if not back then state.errors = state.errors + 1; state.last_error = how .. ': opened for a write, its protection could not be put back' end
    return ok, how .. (back and ' (opened for the write)' or ' (opened for the write; putting its protection back failed)')
end

local function parse(text)
    local out = {}
    for t in text:gmatch('%S+') do out[#out + 1] = t == '??' and -1 or tonumber(t, 16) end
    return out
end
local ACC_MASK, TAIL_MASK = parse(ACCESSOR), parse(TAIL)
local function matches(s, start, mask)
    if start < 1 or start + #mask - 1 > #s then return false end
    for i = 1, #mask do
        local w = mask[i]
        if w >= 0 and byte(s, start + i - 1) ~= w then return false end
    end
    return true
end

local SLOTS_MASK = parse(SLOTS)

-- ---------------------------------------------------------------- logging
local function log()
    pcall(function()
        local f = loader.open_log and loader.open_log('ArmoredOverhaul-' .. P.file .. '.log')
        if not f then return end
        -- what a bug report needs: the game build, how the vehicle settings were found, the preset, each
        -- tank's values now (and the game's own), errors
        f:write('Armored Overhaul - ', P.title, '\n', 'version: ', state.version, '\n', 'status: ', state.status, '\n',
            'game: ', state.game, '\n', 'found: ', state.how, '\n', 'preset: ', state.preset, '\n')
        for _, t in ipairs(TANKS) do f:write(t.name, ': ', state.tanks[t.key] or 'not found', '\n') end
        f:write('options menu: ', state.options_menu, '\n', 'errors: ', state.errors, '\n', 'last error: ', state.last_error, '\n')
        if TESTER then
            f:write('-- tester details --\n', 'table: ', state.table, ' (', state.slots, ' slots)\n', 'writes: ', state.applied,
                '\n', 'frames: ', state.frames, '\n')
        end
        f:close()
    end)
end

-- ---------------------------------------------------------------- preset
-- Both tanks get the multiplier of the sub-option picked in the mod manager (no settings file).
state.preset = string.format('%s (%s times the game\'s %s, picked in the mod manager)', PRESET_NAME, tostring(PRESET), P.what)
local mult = PRESET            -- (3.0) the multiplier in use: the mod manager's pick, or the Mod Options Menu's

-- ---------------------------------------------------------------- finding the table
local game, image_size, timestamp

-- After a game update the search runs once; what it finds is saved per game build (timestamp and size), so later
-- launches of the same build skip it. The saved place is checked again before it is used.
local CACHE_HEADER = 'armored overhaul ' .. P.file:lower() .. ' 1'
local function cache_path()
    local root = os.getenv and os.getenv('LOCALAPPDATA')
    return root and root ~= '' and (root .. '\\CowboyBingus\\Helldivers2\\Logs\\ArmoredOverhaul-' .. P.file .. '.cache') or nil
end
local function build_tag() return string.format('%08X-%X', timestamp, image_size) end
-- (3.1.1 review) Each tank's game values, kept for the life of the game's process (its environment block, which a reload of
-- the game's Lua doesn't touch; gone when the game closes), tagged with the game build: a copy of this addon loaded again
-- in the same session takes them from there, on any build (3.1.0 could only tell scaled values on the Sept 2026 build).
local keep_get, keep_set
do
    for _, decl in ipairs({'uint32_t GetEnvironmentVariableA(const char *, char *, uint32_t);',
            'int SetEnvironmentVariableA(const char *, const char *);'}) do pcall(ffi.cdef, decl) end
    local okg, get = pcall(function() return ffi.cast('uint32_t (*)(const char *, char *, uint32_t)', k32.GetEnvironmentVariableA) end)
    local oks, set = pcall(function() return ffi.cast('int (*)(const char *, const char *)', k32.SetEnvironmentVariableA) end)
    local ebuf = ffi.new('char[256]')
    local function name(key) return 'ARMORED_OVERHAUL_' .. PART:upper() .. '_' .. key:upper() end
    keep_get = function(key)
        if not (okg and get ~= nil) then return nil end
        local n = get(name(key), ebuf, 256)
        if n == 0 or n >= 256 then return nil end
        local tag, rest = ffi.string(ebuf, n):match('^([^|]+)|(.*)$')
        if tag ~= build_tag() then return nil end
        local out, i = {}, 0
        for v in rest:gmatch('[^,]+') do
            i = i + 1
            local x = tonumber(v)
            if not FIELD_NAMES[i] or not x then return nil end
            out[FIELD_NAMES[i]] = x
        end
        return i == #FIELD_NAMES and out or nil
    end
    keep_set = function(key, values)
        if not (oks and set ~= nil) then return end
        local parts = {}
        for i, k in ipairs(FIELD_NAMES) do parts[i] = string.format('%.9g', values[k]) end
        set(name(key), build_tag() .. '|' .. table.concat(parts, ','))
    end
end

-- Grip, steering and power look for the same vehicle-settings table. After a game update only one of them searches the
-- game code; the other waits and takes its candidates (and takes the search over if the first one stops).
local SHARED_STALL = 120
local shared = rawget(_G, 'ArmoredOverhaulVehicleMotion')
if type(shared) ~= 'table' then shared = {}; rawset(_G, 'ArmoredOverhaulVehicleMotion', shared) end
local wait = {beat = nil, since = 0}         -- the last search step seen from the other option, and when
local function cache_load()
    local path = cache_path()
    local f = path and io and io.open and io.open(path, 'r')
    if not f then return nil end
    local text = f:read('*a'); f:close()
    local head, tag, rva = text:match('^([^\n]*)\n([^\n]*)\naccessor=(%x+)')
    if head ~= CACHE_HEADER or tag ~= build_tag() then return nil end
    return tonumber(rva, 16)
end
local function cache_save(rva)
    local path = cache_path()
    local f = path and io and io.open and io.open(path, 'w')
    if not f then return end
    f:write(CACHE_HEADER, '\n', build_tag(), '\n', string.format('accessor=%X', rva), '\n')
    f:close()
end

local function accessor_at(rva)
    local s = read(game + rva, 0xC0)
    if not s or not matches(s, 1, ACC_MASK) then return nil end
    local tail_at, slots_at
    for i = #ACC_MASK + 1, #s - #TAIL_MASK + 1 do
        if not slots_at and matches(s, i, SLOTS_MASK) then slots_at = i end
        if slots_at and matches(s, i, TAIL_MASK) then tail_at = i; break end
    end
    if not tail_at then return nil end
    local stride = u32(s, tail_at + 5)                  -- tail_at is 1-based; u32 takes 0-based offsets
    local data = u32(s, tail_at + 11)
    local slots = byte(s, slots_at + 3)
    local root_rva = rva + 12 + i32(s, 8)               -- mov rax,[rip+disp] ends at pattern offset 12
    local root_off = u32(s, 18)
    if not stride or stride < FRICTION_AT + 4 or stride > 0x4000 or slots < 1 or data ~= slots * 16 then return nil end
    return {root = game + root_rva, root_off = root_off, slots = slots, data = data, stride = stride}
end

local function table_base(acc)
    local root = ptr(read(acc.root, 8), 0)
    if not root then return nil end
    return ptr(read(root + acc.root_off, 8), 0)
end

local function hash_mod(hi, lo, n) return ((hi % n) * (TWO32 % n) + lo) % n end

local function find_record(base, acc, t)
    local slot = hash_mod(t.hi, t.lo, acc.slots)
    for _ = 1, acc.slots do
        local s = read(base + slot * 16, 12)
        if not s then return nil end
        local lo, hi = u32(s, 0), u32(s, 4)
        if lo == t.lo and hi == t.hi then
            local index = u32(s, 8)
            if index >= acc.slots * 4 then return nil end
            return base + acc.data + index * acc.stride
        end
        if lo == 0 and hi == 0 then return nil, 'absent' end      -- (3.1.1 review: not in the table, as opposed to unreadable)
        slot = slot + 1
        if slot >= acc.slots then slot = 0 end
    end
    return nil, 'absent'
end

-- A tank record is accepted only if its wheel radius and friction multiplier look like the tank's, and every field
-- this option changes is in a believable range. Returns the fields' current values.
local LIMITS = {grip = {0.001, 50}, steering = {0.05, 200}, power = {0.01, 20}}
local function sane(record)
    local s = read(record + 0x158, 0x28)             -- +0x158 .. +0x17F: every field either option reads
    if not s then return nil end
    local radius, friction = f32(s, RADIUS_AT - 0x158), f32(s, FRICTION_AT - 0x158)
    if not (radius and radius > 0.3 and radius < 3 and friction > 0.001 and friction < 50) then return nil end
    local v = {}
    for k, off in pairs(FIELD) do
        local x, lim = f32(s, off - 0x158), LIMITS[k]
        if not x or x < lim[1] or x > lim[2] then return nil end
        v[k] = x
    end
    return v
end

-- Compatibility search after a game patch: one 256 KB chunk of game code per frame.
local scan = {offset = 0x1000, hits = {}}
local function scan_step()
    local size = min(0x40000 + 0x100, image_size - scan.offset)
    if size <= 0 then return true end
    -- (3.0.1 review) a page that can't be queried is stepped over (it ended the search, with the rest unsearched)
    if VirtualQuery(game + scan.offset, region, ffi.sizeof('TtRegion')) == 0 then
        scan.offset = scan.offset + 0x1000; return scan.offset >= image_size
    end
    local r = region[0]
    local region_end = num(r.base) + tonumber(r.size) - num(game)
    local exec = r.state == 0x1000 and (r.protection == 0x20 or r.protection == 0x40 or r.protection == 0x10)
    if not exec then scan.offset = max(scan.offset + 0x1000, region_end); return scan.offset >= image_size end
    size = min(size, region_end - scan.offset)
    local s = read(game + scan.offset, size)
    if s then
        local at = 1
        while true do
            local f = s:find(ACCESSOR_ANCHOR, at, true)
            if not f then break end
            local start = f - ACCESSOR_ANCHOR_AT
            if matches(s, start, ACC_MASK) then scan.hits[#scan.hits + 1] = scan.offset + start - 1 end
            at = f + 1
        end
    end
    scan.offset = scan.offset + min(0x40000, size)
    return scan.offset >= image_size
end

local function resolve(rvas)
    local second = nil
    for _, rva in ipairs(rvas) do
        local acc = accessor_at(rva)
        local base = acc and table_base(acc)
        if base then
            local good, absent = 0, 0
            for _, t in ipairs(TANKS) do
                local rec, why = find_record(base, acc, t)
                if rec and sane(rec) then good = good + 1 elseif why == 'absent' then absent = absent + 1 end
            end
            if good == #TANKS then return acc, base, rva end
            -- (3.1.1 review) a table where one tank is sane and the other isn't in it at all (a game update changed that
            -- tank) is kept as a second choice; one where a tank is there but not sane is another component's table (the
            -- search finds several accessors over the same settings root) and is never taken
            if good > 0 and good + absent == #TANKS and not second then second = {acc, base, rva} end
        end
    end
    if second then return second[1], second[2], second[3] end
end

-- ---------------------------------------------------------------- applying
local acc, base
local originals, tries, wants, shown_values = {}, {}, {}, {}
-- (3.0 review) another mod writing the same values: a tank this addon had set, found changed back 3 times within a
-- minute, is left alone (2.1 rewrote it every 10 s for ever) until the next pick in the Mod Options Menu
-- (3.0.1 review: menu_set starts over; a mod still changing it is found again within ~3 checks)
local fight = {set = {}, backs = {}}
-- (3.1.1 review) per tank, what it holds that this addon put there (written, or already the wanted values): what the
-- shutdown compares with. Kept apart from fight.set, which a menu pick clears.
local held = {}
local settled = false           -- true once both tanks hold the preset
local function differs(a, b)
    for _, k in ipairs(FIELD_NAMES) do if math.abs(a[k] - b[k]) > 1e-4 then return true end end
    return false
end
local function apply()
    -- (2.0.1 review) the table is looked up again each time (two small reads): if the game ever rebuilds it (a mission
    -- loading), the new one is used rather than the one found first
    local b = table_base(acc)
    if b ~= nil and num(b) ~= num(base) then base = b; tries, shown_values, held = {}, {}, {}; fight = {set = {}, backs = {}} end
    local changed, open = 0, 0
    for _, t in ipairs(TANKS) do
        local rec, why = find_record(base, acc, t)
        local current = rec and sane(rec)
        if not current then
            -- (3.1.1 review) a tank this game version's table doesn't have at all doesn't keep the option checking every 2 s
            state.tanks[t.key] = why == 'absent' and 'not found (not in this game version\'s vehicle settings)' or 'not found'
            shown_values[t.key] = nil
            if why ~= 'absent' then open = open + 1 end
        else
            if not originals[t.key] then
                -- (3.1.1 review) the game's own values: kept by an earlier copy this session if there was one; else what is
                -- there, unless it is exactly the game's own times one of the option's strengths (an earlier copy's value
                -- whose kept copy is gone): then the game's own. Any other value (another mod's, or a game data change) is
                -- taken as it is (3.1.0, on the Sept 2026 build, replaced any value that wasn't the game's own).
                local okk, o = pcall(keep_get, t.key)
                if not (okk and o) then
                    o = current
                    -- (on the Sept 2026 build only, whose own values VANILLA holds: after a game update a new value of the
                    -- game's could be one of those multiples by chance, and the kept values cover a reload there)
                    for _, k in ipairs(timestamp == KNOWN_TIMESTAMP and FIELD_NAMES or {}) do
                        for _, m in ipairs(STRENGTHS) do
                            if math.abs(current[k] - VANILLA[k] * m) < 1e-4 then
                                o = {}
                                for _, f in ipairs(FIELD_NAMES) do o[f] = VANILLA[f] end
                                state.errors = state.errors + 1
                                state.last_error = string.format('%s: %s found at %.3f, the game\'s %.3f x%g (left by an earlier copy): the game\'s own used',
                                    t.name, k, current[k], VANILLA[k], m)
                                break
                            end
                        end
                        if o ~= current then break end
                    end
                    pcall(keep_set, t.key, o)
                end
                originals[t.key] = o
                local want = {}
                for _, k in ipairs(FIELD_NAMES) do want[k] = o[k] * mult end
                wants[t.key] = want
            end
            local o, want = originals[t.key], wants[t.key]
            local problem, now = nil, current
            if fight.set[t.key] and differs(current, fight.set[t.key]) then   -- changed since this addon wrote it
                local bk = fight.backs[t.key] or {}
                fight.backs[t.key] = bk
                bk[#bk + 1] = state.clock                -- (3.1.1 review: seconds; 3600 frames was 15 s at 240 fps)
                while state.clock - bk[1] > 60 do table.remove(bk, 1) end
                if #bk >= 3 and (tries[t.key] or 0) < MAX_TRIES then
                    tries[t.key] = MAX_TRIES; state.errors = state.errors + 1
                    state.last_error = t.name .. ': another mod keeps changing it back: left alone'
                end
            end
            if not differs(current, want) then fight.set[t.key] = current; held[t.key] = current end   -- (3.1.1 review: for the shutdown)
            if differs(current, want) then
                open = open + 1
                if (tries[t.key] or 0) < MAX_TRIES then
                    local ok, how = write_floats(rec, SPAN, FIELD, want)
                    now = sane(rec) or current
                    if ok and not differs(now, want) then
                        changed = changed + 1; tries[t.key] = nil; fight.set[t.key] = now; held[t.key] = now; state.applied = state.applied + 1; open = open - 1
                    else
                        tries[t.key] = (tries[t.key] or 0) + 1; state.errors = state.errors + 1
                        state.last_error = t.name .. ': write failed: ' .. tostring(how)
                        problem = 'write failed: ' .. tostring(how)
                    end
                else
                    problem = 'gave up'; open = open - 1      -- (3.0 review: left alone, not checked every 2 s)
                end
            end
            -- the log text is only rebuilt when a value or problem changed
            local sig = problem or ''
            for _, k in ipairs(FIELD_NAMES) do sig = sig .. string.format('|%.4f', now[k]) end
            if sig ~= shown_values[t.key] then
                shown_values[t.key] = sig
                local parts = {}
                for _, k in ipairs(FIELD_NAMES) do
                    parts[#parts + 1] = string.format('%s x%.2f (%.3f, game %.3f)', k, now[k] / o[k], now[k], o[k])
                end
                state.tanks[t.key] = table.concat(parts, ', ') .. (problem and ' [' .. problem .. ']' or '')
            end
        end
    end
    settled = open == 0
    return changed
end

-- ---------------------------------------------------------------- main loop
local phase = 'gate'
local next_check = 0
-- ---------------------------------------------------------------- Mod Options Menu (3.0)
-- With CowboyBingus's Mod Options Menu installed, these settings show in the game's MODS tab under ARMORED OVERHAUL
-- and the menu keeps their values; without it nothing changes (the mod manager's picks and the defaults are used).
-- (Its API, from the menu's own source: register_option(id, spec), get(id), on_change(id, fn), api = 1.)
-- The menu lists rows in the order they are added, and the addons load in no set order, so every addon publishes
-- its rows in _G.ArmoredOverhaulMenu and the first one to find the menu adds them all, in the mod manager's option
-- order (MENU_ORDER). The menu may load after the addons: it is looked for once a second until found.
-- menu_rows[group]: {{id, spec, key}, ...} or a function making it; menu_set(key, value) applies a value.
local menu_rows, menu_set, menu_link = {}, nil, nil
do
    local MENU_ORDER = {'power', 'grip', 'steering', 'turret', 'autoloader', 'gunner_drive', 'driver_panel', 'camera', 'indicator'}
    local hub = rawget(_G, 'ArmoredOverhaulMenu')
    if type(hub) ~= 'table' or type(hub.groups) ~= 'table' then hub = {groups = {}, done = {}}; rawset(_G, 'ArmoredOverhaulMenu', hub) end
    for _, g in ipairs({'grip'}) do
        hub.groups[g] = {status = state,
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
        if frame < at then return end
        at = frame + 60
        local mine = true
        for _, g in ipairs({'grip'}) do if not hub.done[g] then mine = false end end
        if mine then at = math.huge; return end
        local M = rawget(_G, 'ModOptionsMenu')
        if type(M) ~= 'table' or M.api ~= 1 or type(M.register_option) ~= 'function' then return end
        -- (3.0.1 review) each group on its own pcall: a malformed group from another (older) copy can't stop this addon
        for _, g in ipairs(MENU_ORDER) do pcall(add, M, g) end
        for g in pairs(hub.groups) do pcall(add, M, g) end   -- (a group not in MENU_ORDER: last)
    end
end
-- (3.0) the menu holds the mod manager's own options only, with their names and choices (plus Off), in the
-- mod manager's order; it fine-tunes what is installed.
local MENU_CHOICES, MENU_MULTS = {'Off', 'Moderate (x1.25)', 'Strong (x1.5)', 'Maximum (x2)'}, {1, 1.25, 1.5, 2}
local MENU_PICK = 2
for i, m in ipairs(MENU_MULTS) do if i > 1 and math.abs(m - PRESET) < 1e-6 then MENU_PICK = i end end
-- One row, the option as the mod manager shows it; it starts at the pick (the id carries it, so another pick in the
-- mod manager starts from its own). Off = the game's own values. Tanks called in after a change use it.
menu_rows.grip = {
    {'armored_overhaul.' .. PART .. '.' .. PRESET_NAME:lower(), {type = 'choice', label = 'Tank Grip', choices = MENU_CHOICES,
        default = MENU_PICK, description = 'More track grip for the Bastion and Maelstrom: less sliding on slopes and in turns. Tanks called in after a change use it.'}, 'mult'},
}
menu_set = function(key, v)
    if key ~= 'mult' or not MENU_MULTS[v] then return end
    mult = MENU_MULTS[v]
    for k, o in pairs(originals) do
        local w = wants[k] or {}
        for _, f in ipairs(FIELD_NAMES) do w[f] = o[f] * mult end
        wants[k] = w
    end
    -- (3.0.1 review) a pick is a new decision: a tank given up on (another mod changing it back, or failed writes) is
    -- tried again (before, later picks, Off too, were silently ignored for it while the log said they applied)
    tries = {}; fight = {set = {}, backs = {}}
    state.preset = v == MENU_PICK and string.format('%s (%s times the game\'s %s, picked in the mod manager)', PRESET_NAME, tostring(PRESET), P.what)
        or (v == 1 and string.format('off: the game\'s own %s (Mod Options Menu)', P.what)
        or string.format('%s (%g times the game\'s %s, Mod Options Menu)', MENU_CHOICES[v], mult, P.what))
    next_check = 0
end
local shown
local function tick()
    state.frames = state.frames + 1
    menu_link(state.frames)
    if state.frames < next_check then return end
    if phase == 'gate' then
        local m = GetModuleHandleA('game.dll')
        if m == nil then next_check = state.frames + 60; return end
        game = ffi.cast(U8, m)
        local dos = read(game, 0x40)
        local pe = dos and u32(dos, 0x3C)
        local hdr = pe and read(game + pe, 0x60)
        image_size, timestamp = hdr and u32(hdr, 0x50), hdr and u32(hdr, 8)
        if image_size and timestamp then state.game = string.format('%08X-%X', timestamp, image_size) end
        if not image_size then state.status = 'game.dll header unreadable'; phase = 'off'; log(); return end
        phase = timestamp == KNOWN_TIMESTAMP and 'known' or 'scan'
        state.how = phase == 'known' and 'known build' or 'searching game code'
        if phase == 'scan' then
            local rva = cache_load()
            if rva and rva < image_size and accessor_at(rva) then
                scan.hits = {rva}; phase = 'scanned'; state.how = 'saved from an earlier search'
            end
        end
    end
    if phase == 'known' then
        if accessor_at(KNOWN_RVA) then scan.hits = {KNOWN_RVA}; phase = 'scanned'
        else phase = 'scan'; state.how = 'searching game code' end
    end
    if phase == 'scan' then
        local tag = build_tag()
        if shared.tag == tag and shared.done then
            scan.hits = {}
            for i, h in ipairs(shared.hits) do scan.hits[i] = h end
            phase = 'scanned'
        elseif shared.tag == tag and shared.owner ~= PART
            and (shared.beat ~= wait.beat or state.frames - wait.since <= SHARED_STALL) then
            -- the other option is searching: wait for it (it moves `beat` every step)
            if shared.beat ~= wait.beat then wait.beat, wait.since = shared.beat, state.frames end
            return
        else
            if shared.owner ~= PART or shared.tag ~= tag then
                shared.owner, shared.tag, shared.done, shared.hits = PART, tag, false, nil
            end
            shared.beat = (shared.beat or 0) + 1
            if scan_step() then phase = 'scanned'; shared.hits, shared.done = scan.hits, true end
            if phase ~= 'scanned' then return end
        end
    end
    if phase == 'scanned' then
        local rva
        acc, base, rva = resolve(scan.hits)
        if not acc then
            state.status = string.format('waiting for the vehicle settings (%d candidate accessors)', #scan.hits)
            next_check = state.frames + 120
            if state.status ~= shown then shown = state.status; log() end     -- (2.0.1 review: not every 2 s while waiting)
            return
        end
        if state.how == 'searching game code' then
            state.how = string.format('found by search at game.dll+0x%X', rva); cache_save(rva)
        end
        phase = 'ready'
    end
    if phase == 'ready' then
        state.table = string.format('0x%X', num(base))
        state.slots = acc.slots
        local okA, changed = pcall(apply)
        if not okA then state.errors = state.errors + 1; state.last_error = tostring(changed); state.status = 'error: ' .. tostring(changed)
        else
            -- (2.0.1 review) 'active' only says so when every tank was found
            local missing = 0
            for _, t in ipairs(TANKS) do if state.tanks[t.key] == 'not found' then missing = missing + 1 end end
            state.status = missing == 0 and 'active' or string.format('active, %d tank(s) not found (see below)', missing)
        end
        -- (3.0.1 review) the options menu and the preset are in it: a menu linked late (with the pick's value) is logged
        local summary = state.status .. state.errors .. state.options_menu .. state.preset
        for _, t in ipairs(TANKS) do summary = summary .. (state.tanks[t.key] or '') end
        if summary ~= shown then shown = summary; log() end
        next_check = state.frames + ((okA and settled) and SETTLED_EVERY or CHECK_EVERY)
    end
end

local previous_update = update
if type(previous_update) ~= 'function' then return end
local function after(ok, ...)
    if not ok then error((...), 0) end
    local okT, err = pcall(tick)
    if not okT then state.errors = state.errors + 1; state.last_error = tostring(err); state.status = 'error: ' .. tostring(err); phase = 'off'; log() end
    return ...
end
update = function(dt, ...)
    state.clock = state.clock + ((type(dt) == 'number' and dt > 0 and dt < 0.5) and dt or 1 / 60)   -- (3.1.1 review: seconds)
    return after(pcall(previous_update, dt, ...))
end
-- (3.0.1 review) the game closing (or this Lua being rebuilt): the game's own values are put back, so a new copy of
-- this addon never reads already-scaled values as the game's (x1.5 became x2.25). Only values this addon holds are
-- written back (another mod's are left to it), through the same page-checked write; the previous shutdown is called.
do
    local previous_shutdown = shutdown
    shutdown = function(...)
        pcall(function()
            if not acc or not base or phase == 'closed' then return end
            phase = 'closed'                                -- (nothing is written after this)
            local b = table_base(acc) or base
            for _, t in ipairs(TANKS) do
                -- (3.1.1 review) put back where the tank holds what this addon wrote last (3.1.0 compared with the wanted
                -- values, which a menu pick changes a frame before they are written: then nothing was put back)
                local o, h = originals[t.key], held[t.key]
                local rec = o and h and find_record(b, acc, t)
                local current = rec and sane(rec)
                if current and differs(current, o) and not differs(current, h) then
                    local ok, how = write_floats(rec, SPAN, FIELD, o)
                    if not ok then state.errors = state.errors + 1; state.last_error = t.name .. ': putting the game\'s values back failed: ' .. tostring(how) end
                end
            end
            state.status = 'stopped (game closing): the game\'s own values put back'
            log()
        end)
        if type(previous_shutdown) == 'function' then return previous_shutdown(...) end
    end
end
log()

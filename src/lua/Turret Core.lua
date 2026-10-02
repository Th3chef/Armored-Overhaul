-- HD2-Addon: mods/chef/armored_overhaul_mbt_turrets
-- Armored Overhaul 3.0.0 - Turret core: the turret settings of the TD-220 Bastion and the TD-110 Maelstrom guns,
-- shared by four options (2.0). Each option ships this core plus a small flag addon that says what it wants, in
-- ArmoredOverhaulTurretOptions:
--   MBT Turrets       (mbt = true):        the guns turn all the way round (with the turret models, whose whole top
--                                          turns with the gun)
--   Turret traverse   (traverse = x):      the left/right turn speed times x
--   Turret elevation  (elevation = x):     the up/down speed times x
--   Turret aim range  (range = {lo, hi}):  how far down and up the guns aim (degrees)
-- Whatever no picked option asks for stays the game's own. Written from scratch.
--
-- How it works: every turret's settings live in the game's static TurretComponent table (the same data Filediver
-- ships as TurretComponentData: a 16-byte {entity hash, index} slot array followed by 0x4C-byte records). The
-- game reads it through a small generated accessor (hash % slot count, linear probe). This addon finds that
-- accessor by its code shape, takes the table and slot count from its immediates, looks the four tank guns up
-- by entity hash and widens each gun's left/right arc. Tanks called in afterwards use it.
-- Record: +0x08 yaw speed (deg/s), +0x0C pitch speed, +0x14/+0x18 pitch min/max, +0x1C/+0x20 yaw min/max.
-- The game seals that table read-only after loading, so a record's page is opened for the write and sealed again.
--
-- The gun only turns toward where the gunner camera looks, and the tank gunner camera is held to +/-40 degrees by
-- its preset in the game's camera preset table (0x90-byte records numbered by id; +0x4C/+0x50 pitch min/max,
-- +0x54/+0x58 yaw min/max). The addon widens that one preset's left/right range to all the way round.
if type(jit) == 'table' and type(jit.off) == 'function' then jit.off(true, true) end
if rawget(_G, 'ArmoredOverhaulMBTTurrets') then return end
local TESTER = false

local byte, min, max = string.byte, math.min, math.max
local TWO32 = 4294967296

local GUNS = {
    -- tank, name, entity hash (hi, lo)
    {tank = 'bastion', name = 'Bastion main gun', hi = 0x1FA1F596, lo = 0x769225C2},
    {tank = 'bastion', name = 'Bastion second gun', hi = 0x439F9E65, lo = 0xC18567DA},
    {tank = 'maelstrom', name = 'Maelstrom main gun', hi = 0xD58AE6A0, lo = 0x4EDB10DE},
    {tank = 'maelstrom', name = 'Maelstrom laser designator', hi = 0xC36B5B37, lo = 0xC058DBDD},
}
local RECORD_SIZE = 0x4C
local FIELD = {yaw_speed = 0x08, pitch_speed = 0x0C, pitch_min = 0x14, pitch_max = 0x18, yaw_min = 0x1C, yaw_max = 0x20}

-- MBT Turrets: the left/right arc goes all the way round (the game's is +/-20 degrees). How far down the gun aims
-- is the Tank Turret Aim Range option's (2.1 Test 7: MBT Turrets no longer lowers it to 6 below).
local ARC = 180
-- The picked options (set by their flag addons when the game loads; read again at every check)
local menu_opts = {}            -- (3.0) set from the Mod Options Menu
local function options()
    local o = rawget(_G, 'ArmoredOverhaulTurretOptions')
    if type(o) ~= 'table' then return {} end
    local out = {mbt = o.mbt == true}
    if type(o.traverse) == 'number' and o.traverse >= 0.25 and o.traverse <= 10 then out.traverse = o.traverse end
    if type(o.elevation) == 'number' and o.elevation >= 0.25 and o.elevation <= 10 then out.elevation = o.elevation end
    local r = o.range
    if type(r) == 'table' and type(r[1]) == 'number' and type(r[2]) == 'number' and r[1] >= -45 and r[1] < r[2] and r[2] <= 80 then
        out.range = {r[1], r[2]}
    end
    -- (3.0) the Mod Options Menu's values, for the options that are installed (see menu_rows)
    local m = menu_opts
    if out.mbt and m.mbt ~= nil then out.mbt = m.mbt end
    if out.traverse and m.traverse ~= nil then out.traverse = m.traverse or nil end         -- (false: Off)
    if out.elevation and m.elevation ~= nil then out.elevation = m.elevation or nil end
    if out.range and m.range ~= nil then out.range = m.range and {m.range[1], m.range[2]} or nil end
    return out
end
local function options_text(o)
    local t = {}
    if o.mbt then t[#t + 1] = 'MBT Turrets (all the way round)' end
    if o.traverse then t[#t + 1] = string.format('traverse x%g', o.traverse) end
    if o.elevation then t[#t + 1] = string.format('elevation speed x%g', o.elevation) end
    if o.range then t[#t + 1] = string.format('aim range %g..%g deg', o.range[1], o.range[2]) end
    return #t > 0 and table.concat(t, ', ') or 'none picked (everything stays the game\'s own)'
end

-- Accessor shape (sub_50B430 in the Sept 2026 build). Immediates that may change between game builds are
-- wildcards and read back: settings-root offset, divide magic, shift, slot count, stride, data offset.
local ACCESSOR = '48 85 C9 74 ?? 48 8B 05 ?? ?? ?? ?? 44 8B C1 4C 8B 90 ?? ?? ?? ?? 48 B8 ?? ?? ?? ?? ?? ?? ?? ?? '
    .. '48 F7 E1 48 C1 EA ?? 69 C2 ?? ?? ?? ?? 44 2B C0 45 33 C9'
local ACCESSOR_ANCHOR = '\x48\xF7\xE1\x48\xC1\xEA'
local ACCESSOR_ANCHOR_AT = 32                       -- 0-based offset of the anchor in the pattern
local TAIL = '8B 48 08 48 6B C1 ?? 48 05 ?? ?? ?? ??'  -- mov ecx,[rax+8] / imul rax,rcx,stride / add rax,data
local KNOWN_RVA = 0x50B430
local KNOWN_TIMESTAMP = 0x6AB3B43F

-- Gunner camera preset. Known build: table at game.dll+0x32F9990, tank gunner preset id 26. Other builds: the
-- preset is found in the game's writable data by its vanilla limits, then checked against its numbered neighbours.
local CAMERA_KNOWN_RVA = 0x32F9990
local CAMERA_KNOWN_ID = 26
local CAMERA_STRIDE = 0x90
local CAMERA_LIMITS_AT = 0x4C
local CAMERA_VANILLA = '\x00\x00\x70\xC1\x00\x00\xC8\x41\x00\x00\x20\xC2\x00\x00\x20\x42' -- -15 25 -40 40
local MAX_TRIES = 5     -- failed writes per item before giving up

local state = {version = '3.0.0', status = 'starting', table = 'unresolved', how = 'none', slots = 0, game = 'unchecked',
               last_error = 'none',
               applied = 0, errors = 0, guns = {}, frames = 0,
               camera = 'not found yet', options = 'not read yet', options_menu = 'not installed (the mod manager\'s picks are used)'}
rawset(_G, 'ArmoredOverhaulMBTTurrets', state)

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
    -- (3.0 review) the old protection put back, checked: a page left writable is said in the result
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

-- ---------------------------------------------------------------- logging
local function log()
    pcall(function()
        local f = loader.open_log and loader.open_log('ArmoredOverhaul-MBTTurrets.log')
        if not f then return end
        -- what a bug report needs: the game build, how the turret settings were found, each gun's values now, errors
        f:write('Armored Overhaul - Turret settings (Tank MBT Turrets, Tank Turret Traverse, Tank Turret Elevation, Tank Turret Aim Range)\n',
            'version: ', state.version, '\n', 'status: ', state.status, '\n', 'game: ', state.game, '\n', 'found: ', state.how,
            '\n', 'options: ', state.options, '\n', 'options menu: ', state.options_menu, '\n')
        for _, g in ipairs(GUNS) do f:write(g.name, ': ', state.guns[g.name] or 'not found', '\n') end
        f:write('gunner view: ', state.camera, '\n', 'errors: ', state.errors, '\n', 'last error: ', state.last_error, '\n')
        if TESTER then
            f:write('-- tester details --\n', 'table: ', state.table, ' (', state.slots, ' slots)\n', 'writes: ', state.applied,
                '\n', 'frames: ', state.frames, '\n')
        end
        f:close()
    end)
end

-- ---------------------------------------------------------------- finding the table
local game, image_size, timestamp

-- After a game update the search runs once; what it finds is saved per game build (timestamp and size), so later
-- launches of the same build skip it. The saved places are checked again before they are used.
local CACHE_HEADER = 'armored overhaul mbt turrets 1'
local found_rvas = {}          -- accessor / camera: offsets in game.dll found by the search this session
local function cache_path()
    local root = os.getenv and os.getenv('LOCALAPPDATA')
    return root and root ~= '' and (root .. '\\CowboyBingus\\Helldivers2\\Logs\\ArmoredOverhaul-MBTTurrets.cache') or nil
end
local function build_tag() return string.format('%08X-%X', timestamp, image_size) end
local function cache_load()
    local path = cache_path()
    local f = path and io and io.open and io.open(path, 'r')
    if not f then return {} end
    local text = f:read('*a'); f:close()
    local head, tag = text:match('^([^\n]*)\n([^\n]*)\n')
    if head ~= CACHE_HEADER or tag ~= build_tag() then return {} end
    local out = {}
    for k, v in text:gmatch('(%a+)=(%x+)') do out[k] = tonumber(v, 16) end
    return out
end
local saved = {}                -- what the cache file held at start-up
local function cache_save()
    local path = cache_path()
    local f = path and io and io.open and io.open(path, 'w')
    if not f then return end
    f:write(CACHE_HEADER, '\n', build_tag(), '\n')
    -- (3.0 review) a place taken from the file is written back too: 2.1 kept only what this session searched for, so
    -- after a game patch the two places could take turns being searched for again at every start
    for _, k in ipairs({'accessor', 'camera'}) do
        local v = found_rvas[k] or saved[k]
        if v then f:write(k, '=', string.format('%X', v), '\n') end
    end
    f:close()
end

local function accessor_at(rva)
    local s = read(game + rva, 0xA0)
    if not s or not matches(s, 1, ACC_MASK) then return nil end
    local tail_at
    for i = #ACC_MASK + 1, #s - #TAIL_MASK + 1 do
        if matches(s, i, TAIL_MASK) then tail_at = i; break end
    end
    if not tail_at then return nil end
    local stride = byte(s, tail_at + 6)
    local data = u32(s, tail_at + 8)            -- tail_at is 1-based; u32 takes 0-based offsets
    local root_rva = rva + 12 + i32(s, 8)               -- mov rax,[rip+disp] ends at pattern offset 12
    local root_off = u32(s, 18)
    local slots = u32(s, 41)
    if stride ~= RECORD_SIZE or not slots or slots < 1 or slots > 0x10000 or data ~= slots * 16 then return nil end
    return {root = game + root_rva, root_off = root_off, slots = slots, data = data}
end

local function table_base(acc)
    local root = ptr(read(acc.root, 8), 0)
    if not root then return nil end
    return ptr(read(root + acc.root_off, 8), 0)
end

-- hash % slots for a 64-bit hash given as two 32-bit halves (exact in doubles).
local function hash_mod(hi, lo, n) return ((hi % n) * (TWO32 % n) + lo) % n end

local function find_record(base, acc, gun)
    local slot = hash_mod(gun.hi, gun.lo, acc.slots)
    for _ = 1, acc.slots do
        local s = read(base + slot * 16, 12)
        if not s then return nil end
        local lo, hi = u32(s, 0), u32(s, 4)
        if lo == gun.lo and hi == gun.hi then
            local index = u32(s, 8)
            if index >= acc.slots * 4 then return nil end
            return base + acc.data + index * RECORD_SIZE
        end
        if lo == 0 and hi == 0 then return nil end
        slot = slot + 1
        if slot >= acc.slots then slot = 0 end
    end
end

local function sane(record)
    local s = read(record, RECORD_SIZE)
    if not s then return nil end
    local v = {}
    for k, off in pairs(FIELD) do v[k] = f32(s, off) end
    if not (v.yaw_speed and v.yaw_speed > 0 and v.yaw_speed < 2000 and v.pitch_speed > 0 and v.pitch_speed < 2000
        and v.yaw_min >= -180 and v.yaw_max <= 180 and v.yaw_min < v.yaw_max
        and v.pitch_min >= -90 and v.pitch_max <= 90 and v.pitch_min < v.pitch_max) then return nil end
    return v
end

-- Compatibility search after a game patch: one 256 KB chunk of game code per frame.
local scan = {offset = 0x1000, hits = {}}
local function scan_step()
    local size = min(0x40000 + 0x100, image_size - scan.offset)
    if size <= 0 then return true end
    if VirtualQuery(game + scan.offset, region, ffi.sizeof('TtRegion')) == 0 then return true end
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

-- Picks the accessor whose table holds all four tank guns with sane turret records.
local function resolve(rvas)
    for _, rva in ipairs(rvas) do
        local acc = accessor_at(rva)
        local base = acc and table_base(acc)
        if base then
            local all = true
            for _, g in ipairs(GUNS) do
                local rec = find_record(base, acc, g)
                if not rec or not sane(rec) then all = false; break end
            end
            if all then return acc, base, rva end
        end
    end
end

-- ---------------------------------------------------------------- gunner camera preset
local function camera_limits(s, o)
    local v = {pitch_min = f32(s, o + 0x4C), pitch_max = f32(s, o + 0x50), yaw_min = f32(s, o + 0x54), yaw_max = f32(s, o + 0x58)}
    if not (v.yaw_max and v.pitch_min >= -90 and v.pitch_max <= 90 and v.pitch_min < v.pitch_max
        and v.yaw_min >= -180 and v.yaw_max <= 180 and v.yaw_min < v.yaw_max) then return nil end
    return v
end
-- A preset is accepted only between its numbered neighbours (id - 1 before it, id + 1 after it).
local function camera_check(rec)
    local s = read(rec - CAMERA_STRIDE, CAMERA_STRIDE * 3)
    if not s then return nil end
    local id = u32(s, CAMERA_STRIDE)
    if not id or id < 1 or id > 0x1000 or u32(s, 0) ~= id - 1 or u32(s, CAMERA_STRIDE * 2) ~= id + 1 then return nil end
    if not camera_limits(s, 0) or not camera_limits(s, CAMERA_STRIDE * 2) then return nil end
    return camera_limits(s, CAMERA_STRIDE), id
end

-- Other builds: one 256 KB chunk of the game's writable data per frame, looking for the vanilla limits.
local cscan = {offset = 0x1000}
local function camera_scan_step()
    local size = min(0x40000 + 0x10, image_size - cscan.offset)
    if size <= 0 then return true end
    if VirtualQuery(game + cscan.offset, region, ffi.sizeof('TtRegion')) == 0 then return true end
    local r = region[0]
    local region_end = num(r.base) + tonumber(r.size) - num(game)
    if not (r.state == 0x1000 and (r.protection == 4 or r.protection == 8)) then
        cscan.offset = max(cscan.offset + 0x1000, region_end); return cscan.offset >= image_size
    end
    size = min(size, region_end - cscan.offset)
    local s = read(game + cscan.offset, size)
    if s then
        local at = 1
        while true do
            local f = s:find(CAMERA_VANILLA, at, true)
            if not f then break end
            local rec = game + cscan.offset + f - 1 - CAMERA_LIMITS_AT
            if camera_check(rec) then cscan.found = rec; return true end
            at = f + 1
        end
    end
    cscan.offset = cscan.offset + min(0x40000, size)
    return cscan.offset >= image_size
end

local camera, camera_phase   -- camera: preset record address; phase: nil, 'scan', 'done'
local function camera_step()
    if camera_phase == 'done' then return end
    if not camera_phase then
        if timestamp == KNOWN_TIMESTAMP then
            local rec = game + CAMERA_KNOWN_RVA + CAMERA_KNOWN_ID * CAMERA_STRIDE
            local _, id = camera_check(rec)
            if id == CAMERA_KNOWN_ID then camera = rec; camera_phase = 'done'; return end
        end
        if saved.camera and saved.camera + CAMERA_STRIDE * 2 <= image_size and camera_check(game + saved.camera) then
            camera, camera_phase = game + saved.camera, 'done'; return
        end
        camera_phase = 'scan'
    end
    if camera_scan_step() then
        camera, camera_phase = cscan.found, 'done'
        if camera then found_rvas.camera = num(camera) - num(game); cache_save()
        else state.camera = 'preset not found (gun limits still apply, the view stays at +/-40)' end
    end
end

-- ---------------------------------------------------------------- applying
local acc, base
local originals = {}   -- item name -> vanilla values (read once)
local tries = {}       -- item name -> failed writes
-- (3.0 review) another mod writing the same values: an item this addon had set, found changed back 3 times within a
-- minute, is left to the other mod for the rest of the mission (2.1 rewrote it every 2 s for ever) and the log says so
local FOUGHT, FIGHT_BACKS, FIGHT_WINDOW = 'another mod keeps changing it: left alone', 3, 3600
local fight = {set = {}, backs = {}, off = {}}
-- What the picked options ask for; everything else stays the game's own.
local opts = {}
local function wanted_for(gun)
    local o = originals[gun.name]
    local w = {yaw_speed = o.yaw_speed * (opts.traverse or 1), pitch_speed = o.pitch_speed * (opts.elevation or 1),
               yaw_min = opts.mbt and -ARC or o.yaw_min, yaw_max = opts.mbt and ARC or o.yaw_max,
               pitch_min = o.pitch_min, pitch_max = o.pitch_max}
    if opts.range then w.pitch_min, w.pitch_max = opts.range[1], opts.range[2] end
    return w
end

-- The gunner view turns all the way round with MBT Turrets, looks at least 5 degrees lower than the lowest gun
-- angle and as high as the highest one (the gun only goes where the view looks).
local function camera_wanted()
    local o = originals.camera
    local lo, hi = o.pitch_min, o.pitch_max
    if opts.range then lo, hi = min(lo, opts.range[1] - 5), max(hi, opts.range[2]) end
    return {yaw_min = opts.mbt and -180 or o.yaw_min, yaw_max = opts.mbt and 180 or o.yaw_max, pitch_min = lo, pitch_max = hi}
end

local function differs(fields, a, b)
    for k in pairs(fields) do if math.abs(a[k] - b[k]) > 1e-3 then return true end end
    return false
end

-- Writes one item if it differs from what the settings ask for. Returns 1 when something was written.
local function put(name, address, size, fields, current, want, reread)
    if not differs(fields, current, want) then return 0, current end
    if fight.off[name] then return 0, current, FOUGHT end
    if fight.set[name] and differs(fields, current, fight.set[name]) then   -- changed since this addon wrote it
        local b = fight.backs[name] or {}
        fight.backs[name] = b
        b[#b + 1] = state.frames
        while state.frames - b[1] > FIGHT_WINDOW do table.remove(b, 1) end
        if #b >= FIGHT_BACKS then
            fight.off[name] = true; state.errors = state.errors + 1; state.last_error = name .. ': ' .. FOUGHT
            return 0, current, FOUGHT
        end
    end
    if (tries[name] or 0) >= MAX_TRIES then return 0, current, 'gave up' end
    local ok, how = write_floats(address, size, fields, want)
    local now = reread()
    if ok and now and not differs(fields, now, want) then
        tries[name] = nil; fight.set[name] = now
        state.applied = state.applied + 1
        return 1, now
    end
    tries[name] = (tries[name] or 0) + 1
    state.errors = state.errors + 1
    state.last_error = name .. ': write failed: ' .. tostring(how)
    return 0, now or current, 'write failed: ' .. tostring(how)
end

local settled = false          -- true once every gun and the camera match what the option asks for
local function apply()
    -- (2.0.1 review) the table is looked up again each time (two small reads): if the game ever rebuilds it (a mission
    -- loading), the new one is used rather than the one found first
    local b = table_base(acc)
    if b ~= nil and num(b) ~= num(base) then base = b; tries = {}; fight = {set = {}, backs = {}, off = {}} end
    opts = options()
    state.options = options_text(opts)
    local changed, open = 0, 0
    for _, g in ipairs(GUNS) do
        local rec = find_record(base, acc, g)
        local current = rec and sane(rec)
        if not current then
            state.guns[g.name] = 'not found'; open = open + 1
        else
            originals[g.name] = originals[g.name] or current
            local n, now, problem = put(g.name, rec, RECORD_SIZE, FIELD, current, wanted_for(g),
                function() return sane(rec) end)
            changed = changed + n
            if problem and problem ~= FOUGHT then open = open + 1 end
            state.guns[g.name] = string.format('turn %.0f deg/s, elevation %.0f deg/s, arc %.0f..%.0f, angle %.0f..%.0f',
                now.yaw_speed, now.pitch_speed, now.yaw_min, now.yaw_max, now.pitch_min, now.pitch_max)
                .. (problem and ' [' .. problem .. ']' or '')
        end
    end
    if camera_phase ~= 'done' then open = open + 1 end
    if camera then
        local current = camera_check(camera)
        if not current then
            state.camera = 'preset no longer valid'; open = open + 1
        else
            originals.camera = originals.camera or current
            local n, now, problem = put('camera', camera + CAMERA_LIMITS_AT, 16,
                {pitch_min = 0, pitch_max = 4, yaw_min = 8, yaw_max = 12}, current, camera_wanted(),
                function() return (camera_check(camera)) end)
            changed = changed + n
            if problem and problem ~= FOUGHT then open = open + 1 end
            state.camera = string.format('view pitch %.0f..%.0f, turn %.0f..%.0f', now.pitch_min, now.pitch_max,
                now.yaw_min, now.yaw_max) .. (n > 0 and ' (re-enter the gunner seat)' or '')
                .. (problem and ' [' .. problem .. ']' or '')
        end
    end
    settled = open == 0 and changed == 0
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
    local MENU_ORDER = {'power', 'grip', 'steering', 'turret', 'autoloader', 'gunner_drive', 'camera', 'indicator'}
    local hub = rawget(_G, 'ArmoredOverhaulMenu')
    if type(hub) ~= 'table' or type(hub.groups) ~= 'table' then hub = {groups = {}, done = {}}; rawset(_G, 'ArmoredOverhaulMenu', hub) end
    for _, g in ipairs({'turret'}) do
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
        for _, g in ipairs({'turret'}) do if not hub.done[g] then mine = false end end
        if mine then at = math.huge; return end
        local M = rawget(_G, 'ModOptionsMenu')
        if type(M) ~= 'table' or M.api ~= 1 or type(M.register_option) ~= 'function' then return end
        for _, g in ipairs(MENU_ORDER) do add(M, g) end
        for g in pairs(hub.groups) do add(M, g) end          -- (a group not in MENU_ORDER: last)
    end
end
-- (3.0) the menu holds the mod manager's own options only, with their names and choices (plus Off), in the
-- mod manager's order; it fine-tunes what is installed.
local RANGES = {{-6, 30}, {-10, 35}, {-15, 45}}       -- Tank Turret Aim Range: Wide, Wider, Widest
local SPEEDS = {1.25, 1.5, 2}                          -- Traverse and Elevation: Quick, Fast, Very fast
local function tag(v) return (string.format('%g', v):gsub('%.', '_')) end
local function pick_of(list, v)
    for i, x in ipairs(list) do
        if type(x) == 'table' and type(v) == 'table' and x[1] == v[1] and x[2] == v[2] or x == v then return i + 1 end
    end
    return 2
end
-- The turret options installed, as the mod manager shows them, each starting at its pick (the id carries it).
-- Off = the game's own. A change is applied within a frame (the gunner view with it).
menu_rows.turret = function()
    local o, rows = rawget(_G, 'ArmoredOverhaulTurretOptions'), {}
    if type(o) ~= 'table' then return rows end
    if o.mbt == true then
        rows[#rows + 1] = {'armored_overhaul.turret.mbt', {type = 'toggle', label = 'Tank MBT Turrets', default = true,
            description = 'The Bastion and Maelstrom turrets turn all the way round like a main battle tank. The Maelstrom\'s missile pods and smoke launchers turn with it. Only you see the new turrets, and their armor always looks undamaged.'}, 'mbt'}
    end
    if type(o.traverse) == 'number' then
        rows[#rows + 1] = {'armored_overhaul.turret.traverse.' .. tag(o.traverse), {type = 'choice', label = 'Tank Turret Traverse',
            choices = {'Off', 'Quick (x1.25)', 'Fast (x1.5)', 'Very fast (x2)'}, default = pick_of(SPEEDS, o.traverse),
            description = 'How fast the Bastion and Maelstrom turrets turn (the game: 25 degrees a second). Works with or without MBT Turrets.'}, 'traverse'}
    end
    if type(o.elevation) == 'number' then
        rows[#rows + 1] = {'armored_overhaul.turret.elevation.' .. tag(o.elevation), {type = 'choice', label = 'Tank Turret Elevation',
            choices = {'Off', 'Quick (x1.25)', 'Fast (x1.5)', 'Very fast (x2)'}, default = pick_of(SPEEDS, o.elevation),
            description = 'How fast the Bastion and Maelstrom guns move up and down (the game: 35 degrees a second).'}, 'elevation'}
    end
    if type(o.range) == 'table' then
        local pick = pick_of(RANGES, o.range)
        rows[#rows + 1] = {'armored_overhaul.turret.aim_range.' .. (pick - 1), {type = 'choice', label = 'Tank Turret Aim Range',
            choices = {'Off', 'Wide (-6..+30 deg)', 'Wider (-10..+35 deg)', 'Widest (-15..+45 deg)'}, default = pick,
            description = 'How far down and up the Bastion and Maelstrom guns aim (the game: 3 below to 25 above).'}, 'range'}
    end
    return rows
end
menu_set = function(key, v)
    if key == 'mbt' then menu_opts.mbt = v == true or v == 1
    elseif key == 'range' then menu_opts.range = RANGES[v - 1] or false
    elseif key == 'traverse' or key == 'elevation' then menu_opts[key] = SPEEDS[v - 1] or false end
    next_check = 0                                       -- (applied at the next frame)
end
local shown
local function tick()
    state.frames = state.frames + 1
    menu_link(state.frames)
    if phase ~= 'gate' and phase ~= 'off' then camera_step() end
    if state.frames < next_check then return end
    if phase == 'gate' then
        local m = GetModuleHandleA('game.dll')
        if m == nil then next_check = state.frames + 60; return end
        game = ffi.cast(U8, m)
        local dos = read(game, 0x40)
        local pe = dos and u32(dos, 0x3C)
        local hdr = pe and read(game + pe, 0x60)
        image_size, timestamp = hdr and u32(hdr, 0x50), hdr and u32(hdr, 8)
        if not image_size then state.status = 'game.dll header unreadable'; phase = 'off'; log(); return end
        state.game = string.format('%08X-%X', timestamp, image_size)
        phase = timestamp == KNOWN_TIMESTAMP and 'known' or 'scan'
        state.how = phase == 'known' and 'known build' or 'searching game code'
        if phase == 'scan' then
            saved = cache_load()
            if saved.accessor and saved.accessor < image_size and accessor_at(saved.accessor) then
                scan.hits = {saved.accessor}; phase = 'scanned'; state.how = 'saved from an earlier search'
            end
        end
    end
    if phase == 'known' then
        -- Known build: the accessor is checked in place; the table itself may load later (retried below).
        if accessor_at(KNOWN_RVA) then scan.hits = {KNOWN_RVA}; phase = 'scanned'
        else phase = 'scan'; state.how = 'searching game code' end
    end
    if phase == 'scan' then
        if scan_step() then phase = 'scanned' end
        if phase ~= 'scanned' then return end
    end
    if phase == 'scanned' then
        local rva
        acc, base, rva = resolve(scan.hits)
        if not acc then
            -- The settings table may not be loaded yet: retry the candidates every 2 seconds.
            state.status = string.format('waiting for the turret table (%d candidate accessors)', #scan.hits)
            next_check = state.frames + 120
            if state.status ~= shown then shown = state.status; log() end     -- (2.0.1 review: not every 2 s while waiting)
            return
        end
        if state.how == 'searching game code' then
            state.how = string.format('found by search at game.dll+0x%X', rva)
            found_rvas.accessor = rva; cache_save()
        end
        phase = 'ready'
    end
    if phase == 'ready' then
        -- Every ~2 seconds (every ~10 once everything is in place): put back anything that differs.
        state.table = string.format('0x%X', num(base))
        state.slots = acc.slots
        do
            local okA, changed = pcall(apply)
            if not okA then state.errors = state.errors + 1; state.last_error = tostring(changed); state.status = 'error: ' .. tostring(changed)
            else
                -- (2.0.1 review) 'active' only says so when every gun was found
                local missing = 0
                for _, g in ipairs(GUNS) do if state.guns[g.name] == 'not found' then missing = missing + 1 end end
                state.status = missing == 0 and 'active' or string.format('active, %d gun(s) not found (see below)', missing)
            end
            local summary = state.status .. state.camera .. state.errors .. state.options
            for _, g in ipairs(GUNS) do summary = summary .. (state.guns[g.name] or '') end
            if summary ~= shown then shown = summary; log() end
        end
        next_check = state.frames + (settled and 600 or 120)
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
update = function(...) return after(pcall(previous_update, ...)) end
log()

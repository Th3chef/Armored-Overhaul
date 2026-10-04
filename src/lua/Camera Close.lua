-- HD2-Addon: mods/chef/armored_overhaul_gunner_camera
-- Armored Overhaul 3.2.0 - Gunner camera option (Close): how far behind the turret the tank
-- gunner's camera follows, for the TD-220 Bastion and TD-110 Maelstrom. Written from scratch.
--
-- How it works: the tank gunner view is one preset in the game's camera preset table (0x90-byte records numbered by
-- id; the tank gunner preset is id 26 in the Sept 2026 build). Its camera offset from the turret pivot is +0x34
-- side, +0x38 forward (negative = behind; -1 m for the gunner) and +0x3C up (2 m). This addon moves the camera half a
-- metre lower and further back, then the picked number of metres further back along a shallow 10 degree rise, so you
-- see more of the tank and around it. The game turns that offset with the hull, not the turret (at its own 1 m nobody notices; further back
-- the camera ended up beside the turret when it turned): while you sit in a tank gunner seat the offset is turned
-- with the turret every frame (the turret angle comes from the shared turret tracker; your seat from Tank Core), so
-- the camera stays behind the turret. Height is not changed by the turning. (Tests: +0x24..+0x2C made no visible difference; +0x3C alone only raised the camera.) The turret
-- limits in the same preset (+0x4C..+0x58) belong to MBT Turrets and are not touched here. (3.2.0) The mouse wheel moves the camera in and
-- out from the pick while you sit in the gunner seat, and zooms in on the crosshair from the closest point (see the zoom block).
if type(jit) == 'table' and type(jit.off) == 'function' then jit.off(true, true) end
if rawget(_G, 'ArmoredOverhaulGunnerCamera') then return end
local TESTER = false
local PRESET, PRESET_NAME = -0.5, 'Close'

local byte, min, max = string.byte, math.min, math.max

local STRIDE = 0x90
local KNOWN_RVA, KNOWN_ID, KNOWN_TIMESTAMP = 0x32F9990, 26, 0x6AB3B43F
local FIELD = {side = 0x34, back = 0x38, up = 0x3C}
local FIELD_NAMES = {'side', 'back', 'up'}
local ANGLE_STEP = math.rad(0.25)    -- the offset is rewritten when the turret has turned this much
local SEAT_FRESH, CORE_STALL = 45, 60
-- the gunner preset's own values +0x04..+0x1F (they identify it in other game builds; neither option writes them)
local PREFIX = '\x00\x00\x80\x3E\x00\x00\x80\x3E\x00\x00\x00\x40\x00\x00\xC0\x3F\x00\x00\x00\x00\x9A\x99\x19\x3E\x9A\x99\x19\x3E'
local MAX_TRIES = 5
local confirmed, fight_backs = false, {}   -- (3.0 review) see apply
local written = {side = 0, back = 0, up = 0}   -- what this addon wrote last (apply or the turning)
-- (1.2.2) Every preset sits half a metre lower and half a metre further back than the game's gunner view (1 m back,
-- 2 m up), and moves back along a 10 degree rise (1.2.0-1.2.1: from the game's view, along 25 degrees): more behind the
-- tank and less above it, for more of the surroundings in view.
local RISE, BASE_BACK, BASE_DOWN = math.rad(10), 0.5, 0.5
local distance = PRESET          -- (3.0) metres back along the rise: the mod manager's pick, or the menu's (nil: Off)
local CHECK_EVERY, SETTLED_EVERY = 120, 600

local state = {version = '3.2.0', status = 'starting', how = 'none', game = 'unchecked', last_error = 'none',
               applied = 0, errors = 0, frames = 0, clock = 0, view = 'not found yet', where = 'none', turning = 'not in a gunner seat yet',
               turns = 0, tank = 'none',
               preset = string.format('%s (picked in the mod manager)', PRESET_NAME),
               options_menu = 'not installed (the distance picked in the mod manager is used)'}
rawset(_G, 'ArmoredOverhaulGunnerCamera', state)

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
local function poke(address, values, fields)
    local p = ffi.cast(F32P, address)
    for k, off in pairs(fields or FIELD) do if values[k] then p[off / 4] = values[k] end end
end
local function write_floats(address, size, values, fields)
    local prot, kind = page_info(address, size)
    if not prot then return false, 'memory not committed' end
    -- (3.0 review) 4 read/write; 8 write-copy (a module's data before its first write: writing makes the page
    -- this process's own copy, as any write by the game does)
    -- (3.1.1 review) the common case first, with no text made (3.1.0 formatted it on every turning write)
    local data = kind == 0x20000 or kind == 0x40000 or kind == 0x1000000
    if data and (prot == 4 or prot == 8) then poke(address, values, fields); return true, 'page writable' end
    local how = string.format('page 0x%X/0x%X', prot, kind)
    if not data then return false, how end
    if prot ~= 2 then return false, how end
    local opened = VirtualProtect(address, size, 4, old_prot) ~= 0
    if not opened then opened = VirtualProtect(address, size, 8, old_prot) ~= 0 end
    if not opened then return false, how .. ', open refused' end
    local restore = old_prot[0]
    local ok = pcall(poke, address, values, fields)
    -- (3.0 review) the old protection put back, checked: a page left writable is said in the result
    local back = VirtualProtect(address, size, restore, old_prot) ~= 0
    if not back then state.errors = state.errors + 1; state.last_error = how .. ': opened for a write, its protection could not be put back' end
    return ok, how .. (back and ' (opened for the write)' or ' (opened for the write; putting its protection back failed)')
end

-- ---------------------------------------------------------------- logging
local function log()
    pcall(function()
        local f = loader.open_log and loader.open_log('ArmoredOverhaul-GunnerCamera.log')
        if not f then return end
        -- what a bug report needs: the game build, how the gunner preset was found, the preset picked, the distances
        f:write('Armored Overhaul - Gunner Camera\n', 'version: ', state.version, '\n', 'status: ', state.status, '\n',
            'game: ', state.game, '\n', 'found: ', state.how, '\n', 'preset: ', state.preset, '\n',
            'gunner view: ', state.view, '\n', 'turning with the turret: ', state.turning, '\n', 'scroll zoom: ', state.zoom, '\n',
            state.zoom_seen and ('crosshair zoom check: ' .. state.zoom_seen .. '\n') or '',
            'zoom keys: ', tostring(state.zoom_keys), '\n', 'zoom readout: ', tostring(state.readout), '\n',
            'options menu: ', state.options_menu, '\n', 'errors: ', state.errors, '\n', 'last error: ', state.last_error, '\n')
        if TESTER then
            f:write('-- tester details --\n', 'preset record: ', state.where, '\n', 'writes: ', state.applied, '\n',
                'turn writes: ', state.turns, '\n', 'tank: ', state.tank, '\n', 'frames: ', state.frames, '\n',
                'zoom api: ', tostring(state.zoom_api), '\n', 'zoom wheel: ', tostring(state.zoom_raw), '\n',
                'zoom camera: ', tostring(state.zoom_camera), '\n', 'zoom field of view: ', tostring(state.zoom_fov), '\n')
        end
        f:close()
    end)
end

-- ---------------------------------------------------------------- finding the gunner preset
local game, image_size, timestamp
local function build_tag() return string.format('%08X-%X', timestamp, image_size) end
local CACHE_HEADER = 'armored overhaul gunner camera 1'
local function cache_path()
    local root = os.getenv and os.getenv('LOCALAPPDATA')
    return root and root ~= '' and (root .. '\\CowboyBingus\\Helldivers2\\Logs\\ArmoredOverhaul-GunnerCamera.cache') or nil
end
local function cache_load()
    local path = cache_path()
    local f = path and io and io.open and io.open(path, 'r')
    if not f then return nil end
    local text = f:read('*a'); f:close()
    local head, tag, rva = text:match('^([^\n]*)\n([^\n]*)\npreset=(%x+)')
    if head ~= CACHE_HEADER or tag ~= build_tag() then return nil end
    return tonumber(rva, 16)
end
local function cache_save(rva)
    local path = cache_path()
    local f = path and io and io.open and io.open(path, 'w')
    if not f then return end
    f:write(CACHE_HEADER, '\n', build_tag(), '\n', string.format('preset=%X', rva), '\n')
    f:close()
end

-- (3.1.1 review) The game's own gunner view offset, kept for the life of the game's process (its environment block, which a
-- reload of the game's Lua doesn't touch; gone when the game closes). A copy of this addon loaded again in the same session
-- (a mod manager redeploy with the game open) takes it from there: 3.1.0 read back what the first copy wrote as the game's
-- own, so each redeploy moved the camera further (Far: another 2.5 m back), and one done in a turned turret's gunner seat
-- kept the camera off to the side. Tagged with the game build.
local keep_get, keep_set, fov_keep_get, fov_keep_set
do
    for _, decl in ipairs({'uint32_t GetEnvironmentVariableA(const char *, char *, uint32_t);',
            'int SetEnvironmentVariableA(const char *, const char *);'}) do pcall(ffi.cdef, decl) end
    local okg, get = pcall(function() return ffi.cast('uint32_t (*)(const char *, char *, uint32_t)', k32.GetEnvironmentVariableA) end)
    local oks, set = pcall(function() return ffi.cast('int (*)(const char *, const char *)', k32.SetEnvironmentVariableA) end)
    local ebuf = ffi.new('char[256]')
    local KEY = 'ARMORED_OVERHAUL_GUNNER_VIEW'
    keep_get = function()
        if not (okg and get ~= nil) then return nil end
        local n = get(KEY, ebuf, 256)
        if n == 0 or n >= 256 then return nil end
        local tag, a, b, c = ffi.string(ebuf, n):match('^([^|]+)|([^,]+),([^,]+),([^,]+)$')
        a, b, c = tonumber(a), tonumber(b), tonumber(c)
        if tag ~= build_tag() or not (a and b and c) then return nil end
        return {side = a, back = b, up = c}
    end
    keep_set = function(v)
        if not (oks and set ~= nil) then return end
        set(KEY, string.format('%s|%.9g,%.9g,%.9g', build_tag(), v.side, v.back, v.up))
    end
    -- (3.2.0 Test 8) the gunner view's own field-of-view multipliers, the same way (see the zoom block)
    local FOV_KEY = 'ARMORED_OVERHAUL_GUNNER_FOV'
    fov_keep_get = function()
        if not (okg and get ~= nil) then return nil end
        local n = get(FOV_KEY, ebuf, 256)
        if n == 0 or n >= 256 then return nil end
        local tag, a, b, c = ffi.string(ebuf, n):match('^([^|]+)|([^,]+),([^,]+),([^,]+)$')
        a, b, c = tonumber(a), tonumber(b), tonumber(c)
        if tag ~= build_tag() or not (a and b and c) then return nil end
        return {a = a, b = b, c = c}
    end
    fov_keep_set = function(v)
        if not (oks and set ~= nil) then return end
        set(FOV_KEY, string.format('%s|%.9g,%.9g,%.9g', build_tag(), v.a, v.b, v.c))
    end
end

local function distances(s, o)
    local v = {}
    for _, k in ipairs(FIELD_NAMES) do
        local x = f32(s, o + FIELD[k])
        if not x or not (x >= -200 and x <= 200) then return nil end      -- (3.0.1 review: NaN rejected too)
        v[k] = x
    end
    return v
end
-- A preset is accepted only with its own prefix and between its numbered neighbours (id - 1 and id + 1).
-- `loose` (the known game build, at the known place): the prefix may differ - another camera mod may have changed the
-- gunner view's other values (1.2.2: 1.2.0-1.2.1 then switched themselves off, and a user saw no change on Far).
-- (3.0.1 review) every re-check once the preset was found is loose too, on every build (see apply).
local prefix_differs = false
local function check(rec, loose)
    local s = read(rec - STRIDE, STRIDE * 3)
    if not s then return nil end
    local id = u32(s, STRIDE)
    if not id or id < 1 or id > 0x1000 or u32(s, 0) ~= id - 1 or u32(s, STRIDE * 2) ~= id + 1 then return nil end
    -- (3.1.0 Test 28) the first two values (the view's look speed, 0.25) may be the turret core's: Tank Turret
    -- Traverse / Elevation speed the view up with the turret; the rest must match
    local head_ok = s:sub(STRIDE + 5, STRIDE + 12) == PREFIX:sub(1, 8)
    if not head_ok then
        local y, p = f32(s, STRIDE + 4), f32(s, STRIDE + 8)
        head_ok = y and p and y >= 0.05 and y <= 2 and p >= 0.05 and p <= 2
    end
    if not head_ok or s:sub(STRIDE + 13, STRIDE + 4 + #PREFIX) ~= PREFIX:sub(9) then
        if not loose then return nil end
        prefix_differs = true
    end
    return distances(s, STRIDE), id
end

-- (3.0.1 review) The turret limits at +0x4C (pitch min/max, yaw min/max) as the game has them (-15..25, -40..40) or as
-- the Turret core widens them (yaw all the way round or 90 each side, pitch lower and higher): the preset's second signature.
local function limits_ok(s, o)
    local p0, p1, y0, y1 = f32(s, o + 0x4C), f32(s, o + 0x50), f32(s, o + 0x54), f32(s, o + 0x58)
    if not (y1 and p0 >= -90 and p0 <= -15 and p1 >= 25 and p1 <= 90) then return false end
    -- (3.1.0 Test 26) or the MBT Turrets 180 choice's +-90
    return y0 == -40 and y1 == 40 or y0 == -180 and y1 == 180 or y0 == -90 and y1 == 90
end
-- Other builds: one 256 KB chunk of the game's writable data per frame, looking for the preset's prefix.
-- (3.0.1 review) every match is kept (3.0.1 took the first): one with the limits too wins, else a single match with the
-- prefix only; more than one: not certain, left alone (see scan_pick)
local scan = {offset = 0x1000, both = {}, one = {}}
local function scan_step()
    local size = min(0x40000 + 0x40, image_size - scan.offset)
    if size <= 0 then return true end
    if VirtualQuery(game + scan.offset, region, ffi.sizeof('TtRegion')) == 0 then return true end
    local r = region[0]
    local region_end = num(r.base) + tonumber(r.size) - num(game)
    if not (r.state == 0x1000 and (r.protection == 4 or r.protection == 8 or r.protection == 2)) then
        scan.offset = max(scan.offset + 0x1000, region_end); return scan.offset >= image_size
    end
    size = min(size, region_end - scan.offset)
    local s = read(game + scan.offset, size)
    if s then
        local at = 1
        while true do
            local f = s:find(PREFIX, at, true)
            if not f then break end
            local rec = game + scan.offset + f - 1 - 4
            -- (a match in the overlap with the next chunk is taken there)
            if f - 1 < 0x40000 and check(rec) then
                local list = limits_ok(read(rec, STRIDE), 0) and scan.both or scan.one
                list[#list + 1] = rec
            end
            at = f + 1
        end
    end
    scan.offset = scan.offset + min(0x40000, size)
    return scan.offset >= image_size
end
local function scan_pick()
    if #scan.both == 1 then return scan.both[1] end
    if #scan.both == 0 and #scan.one == 1 then return scan.one[1] end
    return nil, #scan.both + #scan.one
end

-- ---------------------------------------------------------------- turret tracker (shared source: turret_tracker.lua.inc)
-- Finds the tank you sit in and reads which way its turret points compared to the hull, through the engine's Lua
-- API: the hull by its unit resource (World.units_by_resource), the gun by its unit or by its turning bone
-- ('traverse') near the hull, and the angle as the gun's forward direction measured in the hull's own frame.
-- With two or more of the same tank out, yours is the one nearest your camera. Used by the Turret indicator, the
-- Gunner camera and the Driver panel (each has its own copy and its own search).
local TT = {
    TANKS = {
        [0x2B] = {name = 'Bastion', hull = 'content/fac_helldivers/vehicles/tank/tank'},
        [0x2C] = {name = 'Maelstrom', hull = 'content/fac_helldivers/vehicles/tank_storm/tank_storm',
                  gun = 'content/fac_helldivers/vehicles/tank_storm/armaments/tank_storm_maingun/tank_storm_maingun'},
    },
    -- (2.1) the FRV is in the Turret indicator's and Driver panel's copies (HULLS); the Gunner camera is tanks only
    HULLS = {},
    GUN_NODE = 'traverse',       -- the gun's turning bone (the whole turret turns with it)
    GUN_REACH = 5.0,             -- metres: a gun must be this close to the hull to belong to it
    FIND_EVERY = 30,             -- frames between searches while seated and not yet found
    FIND_SLOW = 300,             -- ... after FIND_MISSES misses in a row (a search can go through every unit)
    FIND_MISSES = 5,
    found = {unit = nil, gun = nil, gun_node = 1, kind = nil, next_find = 0, misses = 0, miss_kind = nil},
    tank = 'none', pick = 'none', pick_note = nil, finds = 0, gen = 0, errors = 0, last_error = nil,
}
function TT.api()
    local SR = rawget(_G, 'stingray')
    if type(SR) ~= 'table' then return nil end
    return SR.Unit, SR.World, SR.Quaternion, SR.Camera, SR.Vector3
end
local function tt_xyz(v) return v.x, v.y, v.z end
local function tt_comps(v)
    local ok, x, y, z = pcall(tt_xyz, v)             -- (2.0.1 review: no new function made on every call)
    if ok and type(x) == 'number' then return x, y, z end
    local V3 = select(5, TT.api())
    -- (3.1.1 review) through pcall too: a value in another form after a game update errored here, outside any pcall
    if V3 and type(V3.to_elements) == 'function' then
        local ok2, a, b, c = pcall(V3.to_elements, v)
        if ok2 and type(a) == 'number' then return a, b, c end
    end
    return nil
end
local function tt_dist2(a, b)
    local ax, ay, az = tt_comps(a); local bx, by, bz = tt_comps(b)
    if not ax or not bx then return 1e9 end
    return (ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2
end
function TT.alive(u)
    if u == nil then return false end
    local U = TT.api()
    local ok, r = pcall(U.alive, u); return ok and r
end
local function tt_units_of(world, res)
    local _, W = TT.api()
    local ok, list = pcall(W.units_by_resource, world, res)
    if ok and type(list) == 'table' then return list end
    return {}
end
-- Two or more of the same tank out: yours is the one nearest your camera (cameras belonging to the tanks
-- themselves are skipped). Without a usable camera the first tank is kept, and pick_note says so.
local function tt_pick_hull(hulls, guns, all, name)
    local U, _, _, CAM = TT.api()
    local skip = {}
    for _, h in ipairs(hulls) do skip[h] = true end
    for _, g in ipairs(guns or {}) do skip[g] = true end
    local cam_pos = {}
    if U.num_cameras and U.camera and CAM and CAM.world_position then
        for _, u in ipairs(all) do
            if not skip[u] then
                local okn, n = pcall(U.num_cameras, u)
                if okn and type(n) == 'number' and n > 0 then
                    for i = 1, math.min(n, 4) do
                        local okc, c = pcall(U.camera, u, i)
                        if not (okc and c ~= nil) then okc, c = pcall(U.camera, u, i - 1) end
                        local okp, p = false, nil
                        if okc and c ~= nil then okp, p = pcall(CAM.world_position, c) end
                        if okp and p ~= nil then cam_pos[#cam_pos + 1] = p end
                    end
                end
            end
        end
    end
    local best, bd = nil, 30 * 30                     -- a camera more than 30 m from every tank is not yours
    for i, h in ipairs(hulls) do
        local okh, hp = pcall(U.world_position, h, 1)
        if okh then
            for _, p in ipairs(cam_pos) do
                local d = tt_dist2(p, hp)
                if d < bd then best, bd = i, d end
            end
        end
    end
    if best then
        TT.pick = string.format('%d %ss out: the one %.1f m from your camera (%d camera(s))', #hulls, name, math.sqrt(bd), #cam_pos)
        return hulls[best]
    end
    TT.pick = string.format('%d %ss out, no camera near them (%d camera(s)): using the first', #hulls, name, #cam_pos)
    TT.pick_note = TT.pick
    return hulls[1]
end
-- Your tank's hull (nil if none is out), the tank's gun units if their name is known, and a function listing every
-- unit (fetched once, only if needed)
local function tt_hull_of(world, t)
    local _, W = TT.api()
    local hulls = tt_units_of(world, t.hull)
    if #hulls == 0 then return nil end
    local guns = t.gun and tt_units_of(world, t.gun) or nil
    local all
    local function every_unit()
        if not all then
            all = {}
            if type(W.units) == 'function' then local ok, l = pcall(W.units, world); if ok and type(l) == 'table' then all = l end end
        end
        return all
    end
    local hull = hulls[1]
    if #hulls > 1 then hull = tt_pick_hull(hulls, guns, every_unit(), t.name) else TT.pick = 'one ' .. t.name .. ' out' end
    return hull, guns, every_unit
end
local function tt_find_tank(world, kind)
    local U = TT.api()
    local t = TT.TANKS[kind] or TT.HULLS[kind]
    local node = t.gun_node or TT.GUN_NODE
    TT.finds = TT.finds + 1
    local hull, guns, every_unit = tt_hull_of(world, t)
    if not hull then TT.tank = t.name .. ': hull not found'; return false end
    local hpos = U.world_position(hull, 1)
    local candidates = guns
    if not candidates or #candidates == 0 then
        -- the gun unit's name is not known for every tank: look for a unit with a turning bone near the hull
        local all = every_unit()
        candidates = {}
        for _, u in ipairs(all) do
            if u ~= hull then
                local okn, has = pcall(U.has_node, u, node)
                if okn and has and tt_dist2(U.world_position(u, 1), hpos) < TT.GUN_REACH * TT.GUN_REACH then candidates[#candidates + 1] = u end
            end
        end
    end
    -- nearest wins; a unit without meshes (the Bastion's second gun sits on the same mount as its cannon) only when
    -- there is nothing else (1.2.1: 1.2.0 could pick it, depending on the unit list order)
    local gun, best = nil, TT.GUN_REACH * TT.GUN_REACH * 2
    for _, u in ipairs(candidates) do
        local d = tt_dist2(U.world_position(u, 1), hpos)
        if d < TT.GUN_REACH * TT.GUN_REACH then
            if U.num_meshes then local okm, nm = pcall(U.num_meshes, u); if okm and nm == 0 then d = d + TT.GUN_REACH * TT.GUN_REACH end end
            if d < best then gun, best = u, d end
        end
    end
    if not gun then TT.tank = t.name .. ': gun not found'; return false end
    local okn, idx = pcall(U.node, gun, node)
    local f = TT.found
    f.unit, f.gun, f.kind, f.gun_node = hull, gun, kind, okn and idx or 1
    TT.tank = t.name .. ' found' .. (okn and '' or ' (no ' .. node .. ' node; using the gun root)')
    TT.gen = TT.gen + 1
    return true
end
local function tt_read_angle()
    local U, _, Q = TT.api()
    local f = TT.found
    local qh = U.world_rotation(f.unit, 1)
    local qg = U.world_rotation(f.gun, f.gun_node)
    local fx, fy, fz = tt_comps(Q.forward(qh))
    local rx, ry, rz = tt_comps(Q.right(qh))
    local gx, gy, gz = tt_comps(Q.forward(qg))
    if not fx or not rx or not gx then return nil end
    -- (1.2.2 review) the hull's axes kept as plain numbers for the Gunner camera's level offset (its up axis only when
    -- a camera asked for it), so the hull's rotation is read once a frame
    local ax = TT.axes
    ax.ok = false
    local pub = rawget(_G, 'ArmoredOverhaulTurretAngle')
    -- (3.0 review) tanks only: the Gunner camera that asks for it is tanks only (an FRV read it every frame)
    if (TT.want_up or (type(pub) == 'table' and pub.want_up)) and Q.up and TT.TANKS[TT.found.kind] then
        local ux, uy, uz = tt_comps(Q.up(qh))
        if ux then
            ax.fx, ax.fy, ax.fz, ax.rx, ax.ry, ax.rz, ax.ux, ax.uy, ax.uz = fx, fy, fz, rx, ry, rz, ux, uy, uz
            ax.ok = true
        end
    end
    return math.atan2(gx * rx + gy * ry + gz * rz, gx * fx + gy * fy + gz * fz)
end
TT.axes = {ok = false}
-- Forget the tank (you left the seat).
function TT.reset()
    local f = TT.found
    f.unit, f.gun, f.miss_kind = nil, nil, nil
    if TT.hull_found then TT.hull_found.unit, TT.hull_found.kind = nil, nil end
end
-- The turret angle in radians (0 = straight ahead, positive = to the right) for the tank of seat `kind`, or nil and
-- why: 'looking' (not found yet; searched often at first, then every 5 s), 'error' or 'no angle'. `frame` is the
-- caller's frame counter. TT.gen changes whenever a (new) tank is found.
function TT.angle(world, kind, frame)
    local f = TT.found
    TT.axes.ok = false
    if f.kind ~= kind or not TT.alive(f.unit) or not TT.alive(f.gun) then
        f.unit, f.gun = nil, nil
        if f.miss_kind ~= kind then f.miss_kind, f.misses, f.next_find = kind, 0, 0 end
        if frame < f.next_find then return nil, 'looking' end
        local okf, ok = pcall(tt_find_tank, world, kind)
        if not okf then TT.errors = TT.errors + 1; TT.last_error = 'tank search failed: ' .. tostring(ok); ok = false end
        if not ok then
            f.misses = f.misses + 1
            f.next_find = frame + (f.misses >= TT.FIND_MISSES and TT.FIND_SLOW or TT.FIND_EVERY)
            return nil, 'looking'
        end
        f.misses, f.next_find = 0, 0
    end
    local oka, a = pcall(tt_read_angle)
    if not oka then
        -- (2.0.1 review) the next search waits as after a miss: 2.0 searched again every frame while the read kept
        -- failing (on the Bastion a search can go through every unit)
        TT.errors = TT.errors + 1; TT.last_error = 'turret angle failed: ' .. tostring(a); f.unit = nil
        f.misses = f.misses + 1
        f.next_find = frame + (f.misses >= TT.FIND_MISSES and TT.FIND_SLOW or TT.FIND_EVERY)
        return nil, 'error'
    end
    if not a then return nil, 'no angle' end
    return a
end
-- The same, shared between the Turret indicator and the Gunner camera: the first of them to read the angle in a
-- frame (`key` = Tank Core's frame counter) publishes it as ArmoredOverhaulTurretAngle and the other uses it,
-- so the tank is looked up and its angle read once a frame with both options on. (Each still has its own search
-- for when it runs first.)
function TT.shared_angle(world, kind, frame, key)
    local pub = rawget(_G, 'ArmoredOverhaulTurretAngle')
    if type(pub) == 'table' and pub.key == key and pub.kind == kind then
        TT.tank, TT.pick = pub.tank, pub.pick
        local pa, ax = pub.axes, TT.axes
        ax.ok = type(pa) == 'table' and pa.ok == true
        if ax.ok then ax.fx, ax.fy, ax.fz, ax.rx, ax.ry, ax.rz, ax.ux, ax.uy, ax.uz = pa.fx, pa.fy, pa.fz, pa.rx, pa.ry, pa.rz, pa.ux, pa.uy, pa.uz end
        if TT.want_up then pub.want_up = true end
        return pub.angle, pub.why
    end
    local angle, why = TT.angle(world, kind, frame)
    if type(pub) ~= 'table' then pub = {}; rawset(_G, 'ArmoredOverhaulTurretAngle', pub) end
    pub.key, pub.kind, pub.angle, pub.why, pub.tank, pub.pick = key, kind, angle, why, TT.tank, TT.pick
    pub.hull = angle and TT.found.unit or nil
    -- (the hull's axes, numbers only, for this frame)
    local ax, pa = TT.axes, pub.axes
    if type(pa) ~= 'table' then pa = {}; pub.axes = pa end
    pa.ok = angle ~= nil and ax.ok
    if pa.ok then pa.fx, pa.fy, pa.fz, pa.rx, pa.ry, pa.rz, pa.ux, pa.uy, pa.uz = ax.fx, ax.fy, ax.fz, ax.rx, ax.ry, ax.rz, ax.ux, ax.uy, ax.uz end
    if TT.want_up then pub.want_up = true end
    return angle, why
end
-- (1.2.2) A unit's axes in the world (forward, right, up; x right, y forward, z up), for the Gunner camera's level
-- offset. Nil if the rotation can't be read.
function TT.basis(unit, out)
    local U, _, Q = TT.api()
    if not Q.up then return nil end
    local q = U.world_rotation(unit, 1)
    local fx, fy, fz = tt_comps(Q.forward(q))
    local rx, ry, rz = tt_comps(Q.right(q))
    local ux, uy, uz = tt_comps(Q.up(q))
    if not fx or not rx or not ux then return nil end
    out.fx, out.fy, out.fz, out.rx, out.ry, out.rz, out.ux, out.uy, out.uz = fx, fy, fz, rx, ry, rz, ux, uy, uz
    return out
end
-- (1.2.2) Only the hull of your tank (the Driver panel measures the speed from how it moves): the one the Turret
-- indicator or Gunner camera published this frame (`key` = Tank Core's frame counter), else its own search (the same
-- pick of your tank; searched every 30 frames at first, then every 5 s). Forgotten with TT.reset.
TT.hull_found = {unit = nil, kind = nil, next_find = 0, misses = 0}
function TT.hull(world, kind, frame, key)
    local h = TT.hull_found
    if h.unit ~= nil and h.kind == kind and TT.alive(h.unit) then return h.unit end
    h.unit = nil
    if h.kind ~= kind then h.kind, h.misses, h.next_find = kind, 0, 0 end
    local pub = rawget(_G, 'ArmoredOverhaulTurretAngle')
    if type(pub) == 'table' and pub.key == key and pub.kind == kind and pub.hull ~= nil and TT.alive(pub.hull) then
        h.unit = pub.hull; TT.tank = pub.tank; TT.pick = pub.pick
        return h.unit
    end
    if frame < h.next_find then return nil end
    TT.finds = TT.finds + 1
    local t = TT.TANKS[kind] or TT.HULLS[kind]
    if not t then return nil end
    local okf, hull = pcall(tt_hull_of, world, t)
    if not okf then TT.errors = TT.errors + 1; TT.last_error = 'hull search failed: ' .. tostring(hull); hull = nil end
    if hull == nil then
        TT.tank = t.name .. ': hull not found'
        h.misses = h.misses + 1
        h.next_find = frame + (h.misses >= TT.FIND_MISSES and TT.FIND_SLOW or TT.FIND_EVERY)
        return nil
    end
    TT.tank = t.name .. ' hull found'
    h.unit, h.misses, h.next_find = hull, 0, 0
    TT.gen = TT.gen + 1
    return hull
end


-- ---------------------------------------------------------------- applying
local rec, original, want
local tries = 0
local settled = false
local blocked = false        -- (2.0.1 review) the record is left alone: gave up, or no longer a valid preset
local target = {}            -- what the record should hold now (the base offset turned with the turret)
local function differs(a, b)
    -- (3.0.1 review) written so a NaN counts as different (it compared as equal before, so it was never corrected)
    for _, k in ipairs(FIELD_NAMES) do if not (math.abs(a[k] - b[k]) <= 1e-3) then return true end end
    return false
end
-- The base offset (straight behind the turret) turned by the turret angle `a` (radians, positive = right; x is
-- the hull's right, y its front): the camera goes round to stay behind the turret, at the same distance and height.
local function set_target(a)
    local c, s = math.cos(a), math.sin(a)
    target.side = want.side * c + want.back * s
    target.back = want.back * c - want.side * s
    target.up = want.up
end
-- (1.2.2) The same, kept level: the game applies the offset in the tank's own frame, pitch and roll included, so with
-- the nose up the camera sank behind or under the tank the further back it was (a user: "the gunner can't aim at
-- anything" on a steep slope). The offset wanted in the world (behind the turret's heading, height straight up) is
-- turned into the tank's frame with its axes `B`. Near-vertical turret headings use the plain turn.
-- (3.0.1 Test 4) Only the climb is levelled: with the turret pointing downhill the camera follows the slope again (it
-- sits up the slope behind the turret, as the game's own view does), since a level camera stayed down at the turret's
-- height and the tank's own hull hid the ground ahead (a user: "impossible to see ahead of the tank when you're going
-- downhill" with the further cameras). Roll stays levelled either way; level ground is unchanged.
local function set_target_level(a, B)
    local c, s = math.cos(a), math.sin(a)
    local gx, gy = B.fx * c + B.rx * s, B.fy * c + B.ry * s          -- the turret's heading in the world, flattened
    local gz = B.fz * c + B.rz * s                                   -- and its climb (negative: pointing downhill)
    local l = math.sqrt(gx * gx + gy * gy)
    if l < 0.2 then return set_target(a) end
    local rx, ry = gy / l, -gx / l                                   -- right of the heading, level
    local px, py, pz = gx / l, gy / l, 0                             -- along the heading: level when climbing...
    if gz < 0 then local n = math.sqrt(l * l + gz * gz); px, py, pz = gx / n, gy / n, gz / n end   -- ...down the slope
    local ux, uy, uz = ry * pz, -rx * pz, rx * py - ry * px          -- up, square to both (straight up when level)
    local wx = rx * want.side + px * want.back + ux * want.up
    local wy = ry * want.side + py * want.back + uy * want.up
    local wz = pz * want.back + uz * want.up
    target.side = wx * B.rx + wy * B.ry + wz * B.rz
    target.back = wx * B.fx + wy * B.fy + wz * B.fz
    target.up = wx * B.ux + wy * B.uy + wz * B.uz
end
-- (3.0.1 review) the page is looked at before every write (they are rare: a quarter degree of turret turn or a
-- centimetre); 3.0.1 looked every 10 s and wrote straight through in between, into a page that may have turned read-only
local function write(values) return write_floats(rec, FIELD.up + 4, values) end
local function note_written()               -- (the target was written and read back)
    written.side, written.back, written.up = target.side, target.back, target.up
    written.counted = false                 -- (3.0.1 review) a change after it may be counted as a fight-back again
end
local function apply()
    -- (3.0.1 review) once found, the record is checked by its numbered neighbours only, on every build: another camera
    -- mod changing the gunner view's other values (+0x04..+0x1F) later no longer makes it 'no longer valid' (3.0.1:
    -- then it stopped turning and could leave the camera turned sideways for the session)
    local now, id = check(rec, true)
    if not now then
        -- its neighbours still in place but its distances unreadable (NaN, out of range): straight behind is written
        -- once before it is left alone, so it is not left turned sideways
        if id and original and not state.rescued then
            state.rescued = true; set_target(0)
            local ok = write(target)
            if ok then note_written() end
        end
        state.view = 'preset no longer valid'; settled = false; blocked = true; return 0
    end
    if not original then
        local okk, kept = pcall(keep_get)
        if okk and kept then original = kept else original = now; pcall(keep_set, now) end
        local o = original                  -- (the distances below are from the game's own view)
        want = {}
        want.side = o.side
        want.back = distance and (o.back - BASE_BACK - distance * math.cos(RISE)) or o.back   -- more negative = further behind
        want.up = distance and (o.up - BASE_DOWN + distance * math.sin(RISE)) or o.up        -- (distance nil: the game's own)
        set_target(0)
    end
    local changed, problem = 0, nil
    if confirmed and not written.counted and differs(now, written) and differs(now, target) then   -- (not when it already holds what we want)
        -- (3.0 review) changed since this addon last wrote it: another mod (or the game) wrote it. Three times within a
        -- minute and it is left alone (the 'gave up' below); 2.1 rewrote it every 10 s for ever
        -- (3.0.1 review) one change counted once until this addon writes it again: a write that keeps failing is not
        -- another mod changing it back
        written.counted = true
        fight_backs[#fight_backs + 1] = state.clock           -- (3.1.1 review: seconds; 3600 frames was 15 s at 240 fps)
        while state.clock - fight_backs[1] > 60 do table.remove(fight_backs, 1) end
        if #fight_backs >= 3 then tries = MAX_TRIES; state.fought = true end
    end
    if differs(now, target) then
        if tries < MAX_TRIES then
            local ok, how = write(target)
            now = check(rec, true) or now
            if ok and not differs(now, target) then
                changed, tries, confirmed = 1, 0, true; state.applied = state.applied + 1
                note_written()
            else
                tries = tries + 1; state.errors = state.errors + 1; state.last_fail = tostring(how)
                state.last_error = 'write failed: ' .. tostring(how); problem = 'write failed: ' .. tostring(how)
            end
        else
            problem = 'gave up'
        end
    elseif not confirmed then
        -- (3.1.1 review) already what this option wants (an earlier copy's write, before a reload): taken as this copy's own,
        -- so its shutdown puts the game's view back and a change by another mod is counted (3.1.0: only after a write)
        confirmed = true; note_written()
    end
    state.view = string.format('camera %.2f m %s and %.2f m up from the turret (game %.2f m back, %.2f m up)', math.abs(want.back),
        want.back <= 0 and 'back' or 'forward', want.up, math.abs(original.back), original.up)
        .. (problem and ' [' .. problem .. ']' or '')
    if problem == 'gave up' and not state.fight_noted then
        -- the record keeps being changed back: something else (another mod) writes the gunner camera too
        -- (3.0.1 review) or this addon's own writes kept failing: said as such (3.0.1 always blamed another mod)
        state.fight_noted = true
        state.last_error = state.fought and 'the gunner camera keeps being changed back (another camera mod?): stopped writing it'
            or ('the gunner camera writes kept failing: stopped (last: ' .. tostring(state.last_fail) .. ')')
    end
    settled = not problem or problem == 'gave up'      -- (3.0 review: given up = left alone, not checked every 2 s)
    -- (2.0.1 review) once it has given up, turning with the turret stops writing too (2.0 kept writing it every turn,
    -- fighting whatever else writes the gunner camera)
    blocked = problem == 'gave up'
    return changed
end

-- Every frame: the turret angle and the tank's tilt while you sit in a tank gunner seat (straight back otherwise), and
-- the offset rewritten when it has moved a centimetre (1.2.0-1.2.1: a quarter of a degree of turret turn).
local seat_watch = {}
local last_step, retry_at
local basis, level = {}, false
-- (the tracker keeps the hull's up axis too, for the level offset; 3.0.1 review: only while a distance is picked)
TT.want_up = distance ~= nil
-- (3.0 review) the turning text, rebuilt only when what it says changes (2.1: every frame in the gunner seat)
local turning_was = {}
local function turning_text(found, tank, extra)
    local w = turning_was
    if w[1] == found and w[2] == tank and w[3] == extra then return end
    w[1], w[2], w[3] = found, tank, extra
    state.turning = found and ('yes (' .. tank .. (extra and ', kept level' or ', not level: tilt unreadable') .. ')')
        or ('not yet: ' .. tostring(extra) .. ' (' .. tank .. ')')
end
-- ---------------------------------------------------------------- scroll-wheel zoom (3.2.0)
-- (3.2.0) In the gunner seat the mouse wheel moves the camera in and out: the picked distance (Close .. Farthest)
-- is where it starts each time you sit down, every notch moves it ZOOM.step metres along the same 10 degree rise
-- (wheel up = closer), and it glides there (ZOOM.speed m/s) so it feels smooth. From the closest distance, more wheel
-- up zooms the view itself in on the crosshair, and wheel down zooms back out before the camera moves back again.
-- (Test 6: more zoom wanted) the crosshair zoom goes in 1.25x steps up to 10x (Test 5: 1.5,
-- 2, 3, 4) and glides between steps like the distance does.
-- (Test 8) The crosshair zoom narrows the gunner view preset's own field-of-view multipliers (+0x5C, +0x60, +0x64; 1.0 for
-- the gunner view; the game's own scope view preset has 0.25, aim views 0.8-0.9, sprint views up to 1.4), the game's own
-- value divided by the zoom; they are put back as you zoom out, leave the seat or the game closes, if they still hold
-- what this addon wrote. (Tests 5-7 set the camera's field of view through Camera.set_vertical_fov: the game works its
-- field of view out again every frame - setting x preset multiplier - so it never showed.) The first time you zoom in,
-- the camera's field of view is read before and 0.6 s after: if it didn't narrow, the crosshair zoom is not used for
-- the rest of the game and the wheel moves the camera only (Test 7: steps that don't show felt like a "buffer"
-- before the camera moved back).
local ZOOM = {step = 0.5, min = -0.5, max = 7, speed = 8, fovs = {}, glide = 12, search_every = 2}
do local f = 1.25; while f < 10 do ZOOM.fovs[#ZOOM.fovs + 1] = f; f = f * 1.25 end; ZOOM.fovs[#ZOOM.fovs + 1] = 10 end
local zoom = {seated = false, extra = 0, d = nil, t = nil, idx = nil, level = 0, f = 1, notches = 0}
local FOVF = {a = 0x5C, b = 0x60, c = 0x64}
-- orig: the game's own multipliers; ours: what was written last; works: nil (not checked yet), true, false (not shown)
local fov = {orig = nil, ours = nil, kept = 0, reset = 0, works = nil, base = nil, check_at = nil}
-- (Test 9) A crash can't be caught in Lua (Test 8 crashed the game at the first zoom in), so a small marker file says
-- what was being tried: 'checking' (the camera check) or 'zooming' (the first field-of-view write of the game), and
-- what got through. Found still 'checking' or 'zooming' at the next start, that step is left out for this version of the
-- mod ('nocheck': the zoom without the check; 'off': no crosshair zoom, the wheel moves the camera only). With the check
-- left out, the zoom's own markers keep saying so ('nocheckzooming', then 'nocheck').
local function zmark(text)
    local root = os.getenv and os.getenv('LOCALAPPDATA')
    if not root or root == '' or not (io and io.open) then return nil end
    local path = root .. '\\CowboyBingus\\Helldivers2\\Logs\\ArmoredOverhaul-GunnerCamera.zoomcheck'
    local f = io.open(path, text and 'w' or 'r')
    if not f then return nil end
    if text then f:write(text, ' ', state.version, '\n'); f:close(); return end
    local t = f:read('*a'); f:close(); return t
end
do
    local ok, last = pcall(zmark)
    local word = ok and type(last) == 'string' and last:match('^(%a+) ' .. state.version:gsub('%p', '%%%0') .. '\n')
    if word == 'checking' or word == 'nocheck' then
        fov.no_check = true; pcall(zmark, 'nocheck')
        state.zoom_seen = 'the camera check is left out: the game closed during it before'
    elseif word == 'zooming' or word == 'nocheckzooming' or word == 'off' then
        fov.works = false; pcall(zmark, 'off')
        state.zoom_seen = 'crosshair zoom not used: the game closed as it zoomed in before'
    end
end
state.zoom = 'not used yet'
local function set_want(d)
    want.side = original.side
    want.back = original.back - BASE_BACK - d * math.cos(RISE)
    want.up = original.up - BASE_DOWN + d * math.sin(RISE)
end
-- the wheel's notches this frame (wheel up positive); nil when the engine has no mouse wheel
local function wheel()
    local SR = rawget(_G, 'stingray')
    local M = type(SR) == 'table' and SR.Mouse
    if not M then return nil end
    if zoom.idx == nil then
        local ok, i = pcall(M.axis_index, 'wheel')
        zoom.idx = (ok and type(i) == 'number') and i or false
        if TESTER then state.zoom_api = zoom.idx and ('wheel axis ' .. zoom.idx) or 'no wheel axis' end
    end
    if not zoom.idx then return nil end
    local ok, v = pcall(M.axis, zoom.idx)
    if not ok or v == nil then return 0 end
    local x, y, z = tt_comps(v)
    local n = y or 0
    if n == 0 and z and z ~= 0 then n = z end            -- (whichever component the engine puts the wheel in)
    if TESTER and n ~= 0 and zoom.notches < 12 then
        zoom.notches = zoom.notches + 1
        state.zoom_raw = string.format('wheel %s %s %s', tostring(x), tostring(y), tostring(z))
    end
    if n > 0 then return math.max(1, math.floor(n + 0.5)) elseif n < 0 then return math.min(-1, math.ceil(n - 0.5)) end
    return 0
end
-- The field of view of every camera on units within 30 m of the tank, read only ({{fov, note}, ...}); for the check
-- that the crosshair zoom shows (twice a game at most) and the Tester log.
local function camera_fovs()
    local U, W, _, CAM = TT.api()
    local hull = TT.found.unit
    if not (U and W and CAM and U.num_cameras and U.camera and CAM.world_position and CAM.vertical_fov and W.units) then return nil, 'no camera API' end
    local okw, world = pcall(rawget(_G, 'stingray').Application.main_world)
    if not okw or world == nil or hull == nil then return nil, 'no world or tank' end
    local okl, all = pcall(W.units, world)
    local okh, hp = pcall(U.world_position, hull, 1)
    if not okl or type(all) ~= 'table' or not okh then return nil, 'units unreadable' end
    local out = {}
    for _, u in ipairs(all) do
        local okn, n = pcall(U.num_cameras, u)
        if okn and type(n) == 'number' and n > 0 then
            for i = 1, math.min(n, 4) do                  -- (Test 9: 1-based; Test 8 asked for camera 0 and the game crashed)
                local okc, c = pcall(U.camera, u, i)
                local okp, p = false, nil
                if okc and c ~= nil then okp, p = pcall(CAM.world_position, c) end
                if okp and p ~= nil then
                    local dd = math.sqrt(tt_dist2(p, hp))
                    local okf, fv = pcall(CAM.vertical_fov, c)
                    if dd < 30 and okf and type(fv) == 'number' then
                        out[#out + 1] = {u = u, i = i, fov = fv, note = string.format('%s%.1f m, camera %d, fov %.3f', u == hull and 'the tank: ' or '', dd, i, fv)}
                    end
                end
            end
        end
    end
    return out
end
local function fov_read()
    local s = read(rec + FOVF.a, 12)
    local a, b, c = f32(s, 0), f32(s, 4), f32(s, 8)
    if not (a and b and c and a > 0.01 and a < 5 and b > 0.01 and b < 5 and c > 0.01 and c < 5) then return nil end
    return {a = a, b = b, c = c}
end
local function fov_differs(x, y) return not (math.abs(x.a - y.a) < 1e-5 and math.abs(x.b - y.b) < 1e-5 and math.abs(x.c - y.c) < 1e-5) end
-- the gunner view's field of view for zoom factor `f` (1 = the game's own), checked every frame while zoomed
local function apply_fov(f)
    if not fov.orig then
        if f <= 1.0005 then return true end
        local okk, kept = pcall(fov_keep_get)
        if okk and kept then fov.orig = kept
        else
            fov.orig = fov_read()
            if not fov.orig then return false, 'field of view unreadable' end
            pcall(fov_keep_set, fov.orig)
        end
    end
    local now = fov_read()
    if not now then return false, 'field of view unreadable' end
    local o = fov.orig
    if f <= 1.0005 then                                     -- (the game's own back, if it still holds ours)
        if fov.ours and not fov_differs(now, fov.ours) then write_floats(rec, FOVF.c + 4, o, FOVF) end
        fov.ours = nil
        return true
    end
    local want_f = {a = o.a / f, b = o.b / f, c = o.c / f}
    if fov.ours then if fov_differs(now, fov.ours) then fov.reset = fov.reset + 1 else fov.kept = fov.kept + 1 end end
    if fov_differs(now, want_f) then
        if not fov.marked then fov.marked = 'zooming'; pcall(zmark, fov.no_check and 'nocheckzooming' or 'zooming') end   -- (cleared the next frame: see zoom_frame)
        local ok, how = write_floats(rec, FOVF.c + 4, want_f, FOVF)
        if not ok then return false, 'write failed: ' .. tostring(how) end
    end
    fov.ours = want_f
    if TESTER then state.zoom_fov = string.format('preset x%.3f/%.3f/%.3f (game %.3f/%.3f/%.3f); kept %d frames, set back by the game %d',
        want_f.a, want_f.b, want_f.c, o.a, o.b, o.c, fov.kept, fov.reset) end
    return true
end
-- (Test 8) the first zoom in: the cameras' field of view before (base) and 0.6 s after; narrowed = the zoom shows
local function fov_check(f)
    if fov.works ~= nil or fov.no_check then return end
    if not fov.base then
        pcall(zmark, 'checking')
        local cams, why = camera_fovs()
        pcall(zmark, 'checked')
        fov.base = cams or {}; fov.check_at = state.clock + 0.6
        if TESTER then state.zoom_camera = cams and (#cams .. ' camera(s) within 30 m before: ' .. table.concat((function()
            local t = {}; for k = 1, math.min(#cams, 6) do t[k] = cams[k].note end; return t end)(), '; ')) or tostring(why) end
        return
    end
    if state.clock < fov.check_at or f < 1.15 then return end
    pcall(zmark, 'checking')
    local cams = camera_fovs() or {}
    pcall(zmark, 'checked')
    local before, after = nil, nil
    for _, e in ipairs(cams) do
        for _, b in ipairs(fov.base) do
            if b.u == e.u and b.i == e.i and b.fov > 0 and e.fov < b.fov * 0.93 then before, after = b.fov, e.fov end
        end
    end
    if #fov.base == 0 or #cams == 0 then
        fov.works = true; state.zoom_seen = 'no camera found to check: the crosshair zoom is kept'
    elseif before then
        fov.works = true; state.zoom_seen = string.format('the camera\'s field of view went from %.3f to %.3f: the crosshair zoom shows', before, after)
    else
        fov.works = false; state.zoom_seen = string.format('the camera\'s field of view stayed %.3f: the crosshair zoom is not used, the wheel moves the camera only', cams[1].fov)
    end
end
-- ---------------------------------------------------------------- zoom keys and readout (3.2.0)
-- (3.2.0) With CowboyBingus's Mod Bindings Menu installed, "Gunner Camera: Zoom In" and "Gunner Camera: Zoom Out" are in
-- the game's controls (tab MODS, section ARMORED OVERHAUL; keyboard or controller): a press is one wheel notch, held
-- it repeats (after 0.35 s, every 0.1 s). The menu is looked for once a second until found; is_down is asked only in
-- the gunner seat. (Its API: _G.ModBindingsMenu {api = 1, register_binding(id, label, slot, options), is_down(id), ready()}.)
local ZB = {api = nil, at = 0, prefix = 'armored_overhaul.gunner_camera.', keys = {}, dirs = {zoom_in = 1, zoom_out = -1},
            held = {}, next = {}}
state.zoom_keys = 'Mod Bindings Menu not installed (the mouse wheel zooms)'
local function zb_link()
    if ZB.api or state.frames < ZB.at then return end
    ZB.at = state.frames + 60
    local B = rawget(_G, 'ModBindingsMenu')
    if type(B) ~= 'table' or B.api ~= 1 or type(B.register_binding) ~= 'function' or type(B.is_down) ~= 'function' then return end
    local failed
    for _, k in ipairs({{'zoom_in', 'Gunner Camera: Zoom In'}, {'zoom_out', 'Gunner Camera: Zoom Out'}}) do
        local ok, done, why = pcall(B.register_binding, ZB.prefix .. k[1], k[2], nil, {category = 'ARMORED OVERHAUL'})
        if ok and done then ZB.keys[#ZB.keys + 1] = k[1] else failed = k[1] .. ': ' .. tostring(ok and why or done) end
    end
    if #ZB.keys == 0 then state.zoom_keys = 'Mod Bindings Menu found, no binding added yet (tried again once a second): ' .. tostring(failed); return end
    ZB.api = B
    state.zoom_keys = #ZB.keys .. ' zoom binding(s) in the controls, tab MODS' .. (failed and ('; not added: ' .. failed) or '')
end
-- the bound zoom keys' notches this frame (zoom in positive), 0 without the menu or while it isn't ready
local function zb_notches()
    local B = ZB.api
    if not B then return 0 end
    local okr, ready = true, true
    if type(B.ready) == 'function' then okr, ready = pcall(B.ready) end
    if not (okr and ready) then return 0 end
    local n = 0
    for _, k in ipairs(ZB.keys) do
        local ok, d = pcall(B.is_down, ZB.prefix .. k)
        if ok and d == true then
            if not ZB.held[k] then
                ZB.held[k], ZB.next[k], n = true, state.clock + 0.35, n + ZB.dirs[k]
                if not ZB.used then ZB.used = true; state.zoom_keys = state.zoom_keys .. '; used' end
            elseif state.clock >= ZB.next[k] then ZB.next[k], n = state.clock + 0.1, n + ZB.dirs[k] end
        else ZB.held[k] = nil end
    end
    return n
end
-- (3.2.0) The crosshair zoom shown as "x2.4" just below and right of the crosshair, in the game's HUD font, whenever it
-- changes; it fades out after RO.hold s. Drawn the way the Driver Panel draws (HD2 HUD+'s method): a screen GUI in the
-- game's overlay world (the one in Application.worlds() that isn't the main world), the font, material and atlas Tank
-- Core publishes (ArmoredOverhaulUIFont), ids and colors made fresh every frame they are used (they only live for one
-- frame), the atlas bound to the material every frame shown. Only the font is used (no readout without it). A marker
-- file (ArmoredOverhaul-GunnerCamera.fontcheck) says 'trying' until it has shown 120 frames or the game closes normally;
-- still 'trying' at the next start (the game closed while it showed): no readout that start, tried again the next.
local RO = {gui = nil, world = nil, check_at = 0, texts = nil, shown = nil, at = -1e9, hold = 1.2, fade = 0.4,
            mark = nil, frames = 0, w = 1920, h = 1080, slot = '88bac99b00000000', cap = 0.72}
state.readout = 'not shown yet'
local function ro_mark(text)
    local root = os.getenv and os.getenv('LOCALAPPDATA')
    if not root or root == '' or not (io and io.open) then return nil end
    local f = io.open(root .. '\\CowboyBingus\\Helldivers2\\Logs\\ArmoredOverhaul-GunnerCamera.fontcheck', text and 'w' or 'r')
    if not f then return nil end
    if text then f:write(text, ' ', state.version, '\n'); f:close(); return end
    local t = f:read('*a'); f:close(); return t
end
do
    local ok, last = pcall(ro_mark)
    if ok and type(last) == 'string' and last:find('^trying') then
        RO.off = 'left out this start: the game closed while it showed last time (tried again next start)'
        state.readout = RO.off; pcall(ro_mark, 'skipped')
    end
end
-- (3.2.0 review) the GUI's world still in Application.worlds(), checked every frame the readout touches the GUI (as
-- the Driver Panel does): a world gone (a mission loaded or left) takes its GUI with it, so it is forgotten, never
-- touched (Test 11 only checked once a second, so for up to a second a gone GUI could be drawn into)
local function ro_alive(SR)
    if not RO.gui then return false end
    if RO.alive_frame == state.frames then return true end
    local okw, worlds = pcall(SR.Application.worlds)
    if not okw or type(worlds) ~= 'table' then return false end             -- (unreadable: not touched this frame)
    for i = 1, #worlds do if worlds[i] == RO.world then RO.alive_frame = state.frames; return true end end
    RO.gui, RO.world, RO.texts, RO.shown = nil, nil, nil, nil
    return false
end
local function ro_clear()
    local SR = rawget(_G, 'stingray')
    if RO.texts and SR and SR.Gui and ro_alive(SR) then for _, t in ipairs(RO.texts) do pcall(SR.Gui.destroy_text, RO.gui, t) end end
    RO.texts, RO.shown = nil, nil
end
-- the overlay world's screen GUI, checked once a second (a GUI whose world is gone is forgotten, never touched)
local function ro_gui(SR)
    if RO.gui and state.clock < RO.check_at then return RO.gui end
    RO.check_at = state.clock + 1
    local A, W, G = SR.Application, SR.World, SR.Gui
    for _, n in ipairs({'back_buffer_size', 'resolution'}) do
        local f = (n == 'resolution' and G and G.resolution) or (A and A[n])
        if f then
            local ok, w, h = pcall(f)
            if ok and type(w) == 'number' and type(h) == 'number' and w > 100 and h > 100 then RO.w, RO.h = w, h; break end
        end
    end
    local okm, main = pcall(A.main_world)
    local okw, worlds = pcall(A.worlds)
    if not okw or type(worlds) ~= 'table' then return nil end
    local target, live = nil, false
    for i = 1, #worlds do
        local x = worlds[i]
        if x ~= nil and x ~= main and not target then target = x end
        if RO.world ~= nil and x == RO.world then live = true end
    end
    if RO.gui and live then return RO.gui end
    RO.gui, RO.world, RO.texts, RO.shown = nil, nil, nil, nil
    if not target or not W.create_screen_gui then return nil end
    local ok, g = pcall(W.create_screen_gui, target, 'scale', 1, 1)
    if not ok or g == nil then state.readout = 'no screen GUI: ' .. tostring(g); return nil end
    RO.gui, RO.world = g, target
    return g
end
-- every frame: drawn while the zoom changed within hold + fade seconds and you sit in the gunner seat
local function readout(seated)
    local age = state.clock - RO.at
    if RO.off or not seated or age > RO.hold + RO.fade then
        if RO.texts then ro_clear() end
        return
    end
    local SR = rawget(_G, 'stingray')
    local pub = rawget(_G, 'ArmoredOverhaulUIFont')
    if type(SR) ~= 'table' or type(pub) ~= 'table' or not (pub.font and pub.material and pub.atlas) then state.readout = 'waiting for the game\'s HUD font (Tank Core)'; return end
    local G, ID, M, A, C, V3 = SR.Gui, SR.IdString64, SR.Material, SR.Application, SR.Color, SR.Vector3
    if not (G and G.text and G.update_text and G.destroy_text and G.material and ID and ID.from_hex and M and M.set_texture and A and A.can_get and C and V3) then
        RO.off = 'off: this game version lacks a text function'; state.readout = RO.off; return
    end
    local g = ro_gui(SR)
    if not g or not ro_alive(SR) then return end
    local f, m, a, slot = ID.from_hex(pub.font), ID.from_hex(pub.material), ID.from_hex(pub.atlas), ID.from_hex(RO.slot)
    if not RO.mark then
        for _, r in ipairs({{'font', f}, {'material', m}, {'texture', a}}) do
            local okc, loaded = pcall(A.can_get, r[1], r[2])
            if not okc or loaded ~= true then state.readout = 'waiting: the HUD ' .. r[1] .. ' is not loaded'; return end
        end
        RO.mark = 'trying'; pcall(ro_mark, 'trying')
    end
    local mh = G.material(g, m)
    if mh ~= nil then M.set_texture(mh, slot, a) end
    local str = zoom.level > 0 and string.format(ZOOM.fovs[zoom.level] < 9.95 and 'x%.1f' or 'x%.0f', ZOOM.fovs[zoom.level]) or 'x1'
    local k = age <= RO.hold and 1 or math.max(0, 1 - (age - RO.hold) / RO.fade)
    if RO.texts then
        RO.frames = RO.frames + 1
        if RO.mark == 'trying' and RO.frames >= 120 then RO.mark = 'ok'; pcall(ro_mark, 'ok') end
    end
    if RO.shown == str and k == 1 and RO.texts then return end
    local size = RO.h * 0.02 / RO.cap
    local x, y = RO.w * 0.5 + RO.h * 0.035, RO.h * 0.5 - RO.h * 0.05
    local sh = math.max(1, RO.h * 0.0015)
    local col, shade = C(math.floor(235 * k + 0.5), 215, 220, 224), C(math.floor(110 * k + 0.5), 0, 0, 0)
    if RO.texts then
        G.update_text(g, RO.texts[1], str, f, size, m, V3(x + sh, y - sh, 3), shade)
        G.update_text(g, RO.texts[2], str, f, size, m, V3(x, y, 4), col)
    else
        local t1 = G.text(g, str, f, size, m, V3(x + sh, y - sh, 3), shade)
        local t2 = G.text(g, str, f, size, m, V3(x, y, 4), col)
        RO.texts = {t1, t2}
    end
    RO.shown = str
    state.readout = 'shown in the game\'s HUD font'
end

-- every frame in a tank gunner seat (seated true) or out of it
local function zoom_frame(seated)
    if not seated or not distance or not original then
        if zoom.seated then
            zoom.seated = false
            if fov.ours then pcall(apply_fov, 1) end
            zoom.level, zoom.f = 0, 1
            if original and distance then set_want(distance) end
        end
        if RO.texts then pcall(readout, false) end
        return
    end
    if not zoom.seated then                                 -- (sat down: the picked distance again)
        zoom.seated, zoom.extra, zoom.d, zoom.t, zoom.level, zoom.f = true, 0, distance, state.clock, 0, 1
    end
    local n = (wheel() or 0) + zb_notches()
    local level_was = zoom.level
    local lo, hi = ZOOM.min - distance, ZOOM.max - distance
    while n > 0 do                                          -- wheel up: closer, then the crosshair zoom
        if zoom.extra > lo + 1e-6 then zoom.extra = math.max(lo, zoom.extra - ZOOM.step)
        elseif zoom.level < #ZOOM.fovs and fov.works ~= false then zoom.level = zoom.level + 1 end
        n = n - 1
    end
    while n < 0 do                                          -- wheel down: the crosshair zoom out first, then back
        if zoom.level > 0 then zoom.level = zoom.level - 1
        else zoom.extra = math.min(hi, zoom.extra + ZOOM.step) end
        n = n + 1
    end
    local goal = distance + zoom.extra
    local dt = math.max(0, state.clock - (zoom.t or state.clock)); zoom.t = state.clock
    if zoom.d ~= goal then
        local step = ZOOM.speed * dt
        zoom.d = math.abs(goal - zoom.d) <= step and goal or zoom.d + (goal > zoom.d and step or -step)
        set_want(zoom.d)
    end
    -- the crosshair zoom glides to its step (in log space, so every step takes the same time)
    local goalf = zoom.level > 0 and ZOOM.fovs[zoom.level] or 1
    if zoom.f ~= goalf then
        local lf, lg = math.log(zoom.f), math.log(goalf)
        lf = lf + (lg - lf) * math.min(1, dt * ZOOM.glide)
        zoom.f = math.abs(lf - lg) < 0.002 and goalf or math.exp(lf)
    end
    if fov.marked == 'zooming' then fov.marked = 'zoomed'; pcall(zmark, fov.no_check and 'nocheck' or 'zoomed') end   -- (the write before this frame went through)
    if zoom.f > 1.0005 and fov.works == nil then pcall(fov_check, zoom.f) end
    if zoom.f > 1.0005 or fov.ours then
        local ok, done, why = pcall(apply_fov, zoom.f)
        if not ok or not done then fov.works = false; state.zoom_seen = 'crosshair zoom: ' .. tostring(ok and why or done) end
    end
    if fov.works == false and zoom.level > 0 then
        zoom.level, zoom.f = 0, 1; pcall(apply_fov, 1)
    end
    if zoom.level ~= level_was then RO.at = state.clock end     -- (the readout shows the new zoom)
    local okr, rerr = pcall(readout, true)
    if not okr then RO.off = 'off after an error: ' .. tostring(rerr); state.readout = RO.off; pcall(ro_clear) end
    -- (3.2.0 review) the log's zoom line made only when what it says changes (Test 11: every frame in the seat)
    local zkey = zoom.level * 1000 + math.floor((zoom.d - distance) * 10 + 0.5) + (fov.works == false and 0.5 or 0)
    if zkey ~= zoom.key then
        zoom.key = zkey
        state.zoom = (zoom.level > 0 and string.format('crosshair zoom x%.1f', goalf)
            or string.format('camera %.1f m further than the pick', zoom.d - distance))
            .. (fov.works == false and ' (crosshair zoom not used: see the check below)' or '')
    end
end

local function follow_turret()
    local seat, core = rawget(_G, 'ArmoredOverhaulSeat'), rawget(_G, 'ArmoredOverhaulGunnerDrive')
    local a, hold = 0, false
    if type(seat) == 'table' and type(core) == 'table' then
        local cf = core.frames or 0
        if cf ~= seat_watch.frames then seat_watch.frames, seat_watch.seen = cf, state.frames end
        local core_ok = core.phase ~= 'off' and state.frames - (seat_watch.seen or state.frames) <= CORE_STALL
        local seated = core_ok and seat.role == 2 and seat.kind and TT.TANKS[seat.kind] and cf - (seat.frame or -1e9) <= SEAT_FRESH
        pcall(zoom_frame, seated and not blocked and distance ~= nil)
        if seated and (blocked or not distance) then
            -- (3.0.1 review) nothing to turn (left alone, or Off in the menu): the turret is not tracked (3.0.1 tracked it
            -- every frame first); Off writes the game's own view, straight behind, once below
            level = false; turning_was[1] = nil; seat_watch.kind = nil
            state.turning = blocked and 'no: the gunner camera is left alone (see last error)' or 'straight behind (Off in the Mod Options Menu)'
        elseif seated then
            -- (3.0 review) the main world only when this frame's angle isn't shared yet (the Vehicle Indicator usually
            -- reads it first), or the hull has to be searched below
            local SR = rawget(_G, 'stingray')
            local pub = rawget(_G, 'ArmoredOverhaulTurretAngle')
            local world, okw = nil, true
            if not (type(pub) == 'table' and pub.key == cf and pub.kind == seat.kind) then okw, world = pcall(SR.Application.main_world) end
            local angle, why = nil, 'no world'
            if okw and (world ~= nil or type(pub) == 'table' and pub.key == cf) then angle, why = TT.shared_angle(world, seat.kind, state.frames, cf) end
            state.tank = TT.tank
            level = false
            if angle then
                a = angle
                local ax = TT.axes
                if ax.ok then                                   -- (read with the angle: no extra engine calls)
                    basis.fx, basis.fy, basis.fz, basis.rx, basis.ry, basis.rz, basis.ux, basis.uy, basis.uz =
                        ax.fx, ax.fy, ax.fz, ax.rx, ax.ry, ax.rz, ax.ux, ax.uy, ax.uz
                    level = true
                else
                    local hull = TT.found.unit
                    if hull == nil or not TT.alive(hull) then
                        if world == nil then okw, world = pcall(SR.Application.main_world); if not okw then world = nil end end
                        if world ~= nil then hull = TT.hull(world, seat.kind, state.frames, cf) end
                    end
                    if hull ~= nil then local okb, B = pcall(TT.basis, hull, basis); level = okb and B ~= nil end
                end
                turning_text(true, TT.tank, level)
                -- (3.0.1 review) the seat and tank the angle was read for (a unit handle, not a per-frame value)
                local pubnow = rawget(_G, 'ArmoredOverhaulTurretAngle')
                seat_watch.kind, seat_watch.vehicle = seat.kind, seat.vehicle
                seat_watch.hull = type(pubnow) == 'table' and pubnow.key == cf and pubnow.hull or TT.found.unit
            else
                turning_text(false, TT.tank, why)
                -- (3.0.1 review) no angle this frame (the tank looked up again: 0.5 to 5 s) in the same seat of the same,
                -- still alive tank: the camera stays where it is (3.0.1 snapped it behind the hull meanwhile)
                hold = seat_watch.kind == seat.kind and seat_watch.vehicle == seat.vehicle and TT.alive(seat_watch.hull)
            end
        else
            TT.reset(); level = false; turning_was[1] = nil; seat_watch.kind = nil
            state.turning = 'straight behind (not in a tank gunner seat)'
        end
    else
        pcall(zoom_frame, false)
        state.turning = 'no: Tank Core is not running (it comes with this option)'; turning_was[1] = nil; seat_watch.kind = nil
    end
    if blocked or hold or state.frames < (retry_at or 0) then return end
    -- (3.0 review) Off in the menu: the game's own view, straight behind, never turned or levelled
    if not distance then set_target(0) elseif level then set_target_level(a, basis) else set_target(math.floor(a / ANGLE_STEP + 0.5) * ANGLE_STEP) end
    if last_step and math.abs(target.side - written.side) < 0.01 and math.abs(target.back - written.back) < 0.01
        and math.abs(target.up - written.up) < 0.01 then return end
    local ok, how = write(target)
    if ok then
        last_step, retry_at = true, nil; state.turns = state.turns + 1
        note_written()
    else                                                      -- (a failed write is tried again after a second)
        retry_at, last_step = state.frames + 60, nil        -- (what the record holds is unknown: written again)
        state.errors = state.errors + 1; state.last_error = 'turning write failed: ' .. tostring(how)
    end
end

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
    for _, g in ipairs({'camera'}) do
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
        for _, g in ipairs({'camera'}) do if not hub.done[g] then mine = false end end
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
local next_check = 0                                    -- (main loop: frame of the next check; set by the menu too)
local MENU_PRESETS = {false, -0.5, 2, 4, 6}             -- Off (the game's own view), Close, Far, Farther, Farthest
local MENU_PICK = 2
for i, d in ipairs(MENU_PRESETS) do if d == PRESET then MENU_PICK = i end end
-- The option as the mod manager shows it, starting at the pick (the id carries it). The game takes a new distance the
-- next time you sit in the gunner seat.
menu_rows.camera = {
    {'armored_overhaul.camera.' .. PRESET_NAME:lower(), {type = 'choice', label = 'Tank Gunner Camera',
        choices = {'Off', 'Close (1 m behind)', 'Far (3.5 m behind)', 'Farther (5.4 m behind)', 'Farthest (7.4 m behind)'}, default = MENU_PICK, description = 'Puts the Bastion and Maelstrom gunner camera lower and further back so you see more around the tank. It stays behind the turret as it turns. The pick is where the camera starts: the mouse wheel (or the Mod Bindings Menu\'s Zoom In / Zoom Out keys) moves it closer or further back, and from the closest point zooms in on the crosshair.'}, 'distance'},
}
menu_set = function(key, v)
    if key ~= 'distance' or MENU_PRESETS[v] == nil then return end
    distance = MENU_PRESETS[v] or nil
    state.preset = v == MENU_PICK and string.format('%s (picked in the mod manager)', PRESET_NAME)
        or (distance and ({'Close (1 m behind)', 'Far (3.5 m behind)', 'Farther (5.4 m behind)', 'Farthest (7.4 m behind)'})[v - 1] .. ' (Mod Options Menu)' or 'off: the game\'s own view (Mod Options Menu)')
    zoom.seated = false                                  -- (3.2.0) the new distance is the zoom's new start
    if fov.ours then pcall(apply_fov, 1) end
    zoom.level, zoom.f = 0, 1
    if original then
        want.back = distance and (original.back - BASE_BACK - distance * math.cos(RISE)) or original.back
        want.up = distance and (original.up - BASE_DOWN + distance * math.sin(RISE)) or original.up
        set_target(0); settled = false; last_step = nil
    end
    -- (3.0.1 review) checked at the next frame, as the Turret core does (3.0.1: up to 10 s later after a turning error)
    next_check = 0
    -- (3.0.1 review) the hull's up axis is asked for only while a distance is picked (Off: the Vehicle Indicator stops
    -- reading it for this addon)
    TT.want_up = distance ~= nil
    local pub = rawget(_G, 'ArmoredOverhaulTurretAngle')
    if not distance and type(pub) == 'table' then pub.want_up = nil end
end

-- ---------------------------------------------------------------- main loop
local phase = 'gate'
local shown
local function tick()
    state.frames = state.frames + 1
    menu_link(state.frames)
    pcall(zb_link)
    if phase == 'ready' and original and not state.turn_failed then
        local okF, err = pcall(follow_turret)
        if not okF then
            state.errors = state.errors + 1; state.last_error = 'turning: ' .. tostring(err); state.turn_failed = true
            state.turning = 'off after an error (the camera stays straight behind)'; set_target(0)
            local okw, wrote = true, false
            if not blocked then okw, wrote = pcall(write, target) end              -- (3.0 review: not after giving up)
            if okw and wrote then note_written() end
            log()
        end
    end
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
        state.game = build_tag()
        if timestamp == KNOWN_TIMESTAMP then
            local r = game + KNOWN_RVA + KNOWN_ID * STRIDE
            local _, id = check(r, true)
            if id == KNOWN_ID then
                rec = r; phase = 'ready'; state.loose = prefix_differs
                state.how = 'known build' .. (prefix_differs and ' (its other gunner view values are not the game\'s own: '
                    .. 'another mod may change the gunner camera too)' or '')
            end
        end
        if not rec then
            local rva = cache_load()
            if rva and rva + STRIDE * 2 <= image_size and check(game + rva) then
                rec = game + rva; state.how = 'saved from an earlier search'; phase = 'ready'
            else
                phase = 'scan'; state.how = 'searching game data'
            end
        end
    end
    if phase == 'scan' then
        if not scan_step() then return end
        local found, n = scan_pick()
        if not found then
            phase = 'off'; state.status = (n or 0) > 1 and string.format('not active: %d places in the game data look like the gunner '
                .. 'camera preset, so none is changed', n) or 'not active: the gunner camera preset was not found in this game version'
            state.view = 'the game\'s own'; log(); return
        end
        rec = found; phase = 'ready'
        state.how = string.format('found by search at game.dll+0x%X', num(rec) - num(game)); cache_save(num(rec) - num(game))
    end
    if phase == 'ready' then
        state.where = string.format('game.dll+0x%X', num(rec) - num(game))
        local okA, changed = pcall(apply)
        if not okA then state.errors = state.errors + 1; state.last_error = tostring(changed); state.status = 'error: ' .. tostring(changed)
        else state.status = 'active' end
        -- (3.0.1 review) the options menu and the preset too: a menu linked later is in the log
        local summary = state.status .. state.view .. state.errors .. state.turning .. state.options_menu .. state.preset .. tostring(state.zoom) .. tostring(state.zoom_keys) .. tostring(state.readout)
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
-- (3.1.1 review) the game closing (or this Lua being rebuilt): the game's own gunner view is put back if the preset still
-- holds what this addon wrote (another mod's offset is left to it), as Power/Grip/Steering do
do
    local previous_shutdown = shutdown
    shutdown = function(...)
        pcall(function()
            if phase ~= 'ready' or not (rec and original and confirmed) then return end
            phase = 'closed'                                -- (nothing is written after this)
            if fov.ours then pcall(apply_fov, 1) end        -- (3.2.0: the gunner view's field of view, if zoomed)
            if RO.mark == 'trying' then pcall(ro_mark, 'ok') end   -- (closed normally: the readout didn't crash it)
            local now = check(rec, true)
            if now and not differs(now, written) and differs(now, original) then
                local ok, how = write_floats(rec, FIELD.up + 4, original)
                if not ok then state.errors = state.errors + 1; state.last_error = 'putting the game\'s view back failed: ' .. tostring(how) end
            end
            state.status = 'stopped (game closing): the game\'s own view put back'
            log()
        end)
        if type(previous_shutdown) == 'function' then return previous_shutdown(...) end
    end
end
log()

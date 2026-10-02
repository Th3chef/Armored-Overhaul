-- HD2-Addon: mods/chef/armored_overhaul_gunner_camera
-- Armored Overhaul 3.1.0 - Gunner camera option (Close): how far behind the turret the tank
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
-- limits in the same preset (+0x4C..+0x58) belong to MBT Turrets and are not touched here. The view uses the new distance from the next time you take the gunner seat.
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

local state = {version = '3.1.0', status = 'starting', how = 'none', game = 'unchecked', last_error = 'none',
               applied = 0, errors = 0, frames = 0, view = 'not found yet', where = 'none', turning = 'not in a gunner seat yet',
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
local function poke(address, values)
    local p = ffi.cast(F32P, address)
    for k, off in pairs(FIELD) do if values[k] then p[off / 4] = values[k] end end
end
local function write_floats(address, size, values)
    local prot, kind = page_info(address, size)
    if not prot then return false, 'memory not committed' end
    local how = string.format('page 0x%X/0x%X', prot, kind)
    if kind ~= 0x20000 and kind ~= 0x40000 and kind ~= 0x1000000 then return false, how end
    -- (3.0 review) 4 read/write; 8 write-copy (a module's data before its first write: writing makes the page
    -- this process's own copy, as any write by the game does)
    if prot == 4 or prot == 8 then poke(address, values); return true, how end
    if prot ~= 2 then return false, how end
    local opened = VirtualProtect(address, size, 4, old_prot) ~= 0
    if not opened then opened = VirtualProtect(address, size, 8, old_prot) ~= 0 end
    if not opened then return false, how .. ', open refused' end
    local restore = old_prot[0]
    local ok = pcall(poke, address, values)
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
            'gunner view: ', state.view, '\n', 'turning with the turret: ', state.turning, '\n',
            'options menu: ', state.options_menu, '\n', 'errors: ', state.errors, '\n', 'last error: ', state.last_error, '\n')
        if TESTER then
            f:write('-- tester details --\n', 'preset record: ', state.where, '\n', 'writes: ', state.applied, '\n',
                'turn writes: ', state.turns, '\n', 'tank: ', state.tank, '\n', 'frames: ', state.frames, '\n')
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
    if V3 and type(V3.to_elements) == 'function' then return V3.to_elements(v) end
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
        original, want = now, {}
        want.side = now.side
        want.back = distance and (now.back - BASE_BACK - distance * math.cos(RISE)) or now.back   -- more negative = further behind
        want.up = distance and (now.up - BASE_DOWN + distance * math.sin(RISE)) or now.up        -- (distance nil: the game's own)
        set_target(0)
    end
    local changed, problem = 0, nil
    if confirmed and not written.counted and differs(now, written) and differs(now, target) then   -- (not when it already holds what we want)
        -- (3.0 review) changed since this addon last wrote it: another mod (or the game) wrote it. Three times within a
        -- minute and it is left alone (the 'gave up' below); 2.1 rewrote it every 10 s for ever
        -- (3.0.1 review) one change counted once until this addon writes it again: a write that keeps failing is not
        -- another mod changing it back
        written.counted = true
        fight_backs[#fight_backs + 1] = state.frames
        while state.frames - fight_backs[1] > 3600 do table.remove(fight_backs, 1) end
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
local function follow_turret()
    local seat, core = rawget(_G, 'ArmoredOverhaulSeat'), rawget(_G, 'ArmoredOverhaulGunnerDrive')
    local a, hold = 0, false
    if type(seat) == 'table' and type(core) == 'table' then
        local cf = core.frames or 0
        if cf ~= seat_watch.frames then seat_watch.frames, seat_watch.seen = cf, state.frames end
        local core_ok = core.phase ~= 'off' and state.frames - (seat_watch.seen or state.frames) <= CORE_STALL
        local seated = core_ok and seat.role == 2 and seat.kind and TT.TANKS[seat.kind] and cf - (seat.frame or -1e9) <= SEAT_FRESH
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
    local MENU_ORDER = {'power', 'grip', 'steering', 'turret', 'autoloader', 'gunner_drive', 'camera', 'indicator'}
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
        choices = {'Off', 'Close (1 m behind)', 'Far (3.5 m behind)', 'Farther (5.4 m behind)', 'Farthest (7.4 m behind)'}, default = MENU_PICK, description = 'Puts the Bastion and Maelstrom gunner camera lower and further back so you see more around the tank. It stays behind the turret as it turns.'}, 'distance'},
}
menu_set = function(key, v)
    if key ~= 'distance' or MENU_PRESETS[v] == nil then return end
    distance = MENU_PRESETS[v] or nil
    state.preset = v == MENU_PICK and string.format('%s (picked in the mod manager)', PRESET_NAME)
        or (distance and ({'Close (1 m behind)', 'Far (3.5 m behind)', 'Farther (5.4 m behind)', 'Farthest (7.4 m behind)'})[v - 1] .. ' (Mod Options Menu)' or 'off: the game\'s own view (Mod Options Menu)')
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
        local summary = state.status .. state.view .. state.errors .. state.turning .. state.options_menu .. state.preset
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
update = function(...) return after(pcall(previous_update, ...)) end
log()

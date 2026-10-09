-- HD2-Addon: mods/chef/armored_overhaul_shift
-- Armored Overhaul 3.4.0 - Tank Top Speed, Tank Engine Torque, Tank Grip, Tank Stability and the gear changes of Tank
-- Throttle Response, for the TD-220 Bastion and TD-110 Maelstrom (one source, built once per option and strength;
-- this copy is the 'shift' option, Quicker). Written from scratch.
--
-- How it works: a tank drives on the engine's Havok vehicle kit. These options change it live, on the tank you sit in
-- (any seat), through the game's own vehicle physics interface - the same calls the game makes when a tank is set up
-- (game.dll+0x7194C0):
--   the tank's handle: interface [game.dll+0x3326310] slot 0 (physics id, 0x10, out) -> [out+0x20]
--   engine get / set: interface [game.dll+0x3326320] slots 0x80 / 0x88 (handle, 0x28-byte engine block:
--   +0x8 max rpm, +0xC max torque)
--   wheel get / set: slots 0x40 / 0x48 (handle, wheel 0..9, 0x2C-byte wheel block: +0xC friction, +0x14 max friction)
--   transmission get / set: slots 0x90 / 0x98 (handle, 0x14-byte block: +0x10 clutch delay, 0.3 s)
-- (Test 29) Tank Stability is downforce. the tester: "work more on keeping the tank flat on the ground. It should feel heavy
-- properly, but in this game its got a floaty physics". The tank's Havok aerodynamics (the hull physics' "VRA " block:
-- air density 15, frontal area 8, drag 14, lift 0 on both tanks) are read and set live through slots 0x20 / 0x28
-- (handle, density, drag, lift: the game's own call at game.dll+0x718E20 scales the density by its air factor, the two
-- floats at +0x654 / +0x658 of the tank's record below; the read gives the resource's density, so the part scales it
-- the same way before it sends it - 3.4.0 review). A
-- negative lift coefficient presses the hull down with 0.5 x density x area x lift x speed squared (Havok's convention:
-- its vehicle demo uses -0.3 for downforce); it acts at the centre of mass, so it adds weight without leaning the hull.
-- The pick is the tank's weight at 45 km/h: Stable x1.5, Steady x2, Planted x3 (half that extra at 32 km/h, a tenth at
-- 14 km/h). (Test 36's lift test, lift raised by 15.7: the tester "felt lighter than usual, but the vanilla tank already feels
-- light": the call reaches the physics and a positive lift lifts, so the negative one presses down; Test 32's x1.15 to
-- x1.5 were too little to notice: Test 37 x1.5 / x2 / x3.)
-- The torque roll and pitch factors, row +0x630 / +0x634 of the tank's 0x670-byte record (the component's +0x70), are
-- handed to the physics every frame (game.dll+0x71750D; 1 and 1 on both tanks). (Test 23, the tester: "keeping the tank on the
-- ground with all the extra torque") The extra drive is kept from tipping the hull back: every part but shift sets
-- them to
--   roll  = the tank's own (Tests 24-28: x Stability; Test 29, the tester: "lets leave that at 1")
--   pitch = the tank's own / (Top Speed x Engine Torque)
-- so the extra pulling power tips the hull back no more than the game's own (all parts agree on it). (Test 24) The roll
-- factor is no longer lowered: Test 23 (roll 0.2) still leaned 43 deg outward in a 38 km/h, 40 deg/s turn, and in 3.1.0
-- cutting the hull's roll factor in the physics file made the tanks tippier (the game's centre of mass sits below the
-- ground, so the tracks' grip leans the hull into a turn). Grip and Stability leave it alone.
-- (Tank Turn Radius, Tests 20-22, is gone: the tank's Havok steering object couldn't be found from game.dll's data; the
-- wider turns at speed were fixed in Tank Suspension's physics instead.)
-- Tank Top Speed raises the engine's max rpm and torque together (its top speed is held by the engine's power curve,
-- not by its gearing: 3.4.0 tests, max rpm x1.5 and torque x1.5 40 km/h against 35). Tank Engine Torque raises the
-- torque (pulling power: quicker off the line and up slopes); with both, the torque is the two multiplied. Tank Grip
-- raises every wheel's friction and max friction. The 'shift' part (in the Tank Throttle Response option, next to the
-- VehicleMotion let-off rates of the Steering source) cuts the clutch delay, following that option's pick. (3.4.0 Test 20: Engine Torque - Tank Power until 3.3.0 - and Grip were
-- scaled in the game's VehicleMotion table, which only tanks called in afterwards used; the tester: "lets implement all of
-- those" - now they change the tank you are in at once.)
-- The tank is found in the networked vehicle component [game.dll+0x3326458] (map +0x40, entries +0x58, entry +0xC
-- the physics id). The three places are read from the game's own code (pattern below), so they follow a game update
-- (3.4.0 review: on a build it doesn't know, the first part to find them shares the place with the others, which check
-- the code there instead of searching game.dll again).
-- The tank keeps the change when you get out. Each tank's own values are kept, so Off (Mod Options Menu) puts them back,
-- and so does the game closing (3.4.0 review: every value this part changed, where the tank still holds what it wrote).
if type(jit) == 'table' and type(jit.off) == 'function' then jit.off(true, true) end
local TESTER = false
local PART = 'shift'
local PRESET, PRESET_NAME = 0.2, 'Quicker'   -- the strength picked in the mod manager (baked in per sub-option)
-- (Test 20) the five options: their global (the Driver Panel's handling check and the other parts read it), log, title,
-- menu row (id kept from the earlier copies, so a saved pick keeps its place) and the choices
local PARTS = {
    speed = {global = 'ArmoredOverhaulTopSpeed', file = 'TankSpeed', title = 'Tank Top Speed', what = 'engine\'s max rpm and torque',
             menu = 'speed', choices = {'Off', 'Fast (x1.1)', 'Faster (x1.15)', 'Fastest (x1.3)'}, mults = {1, 1.1, 1.15, 1.3},
             description = 'A faster Bastion and Maelstrom: more engine speed and pulling power, forward and in reverse. Changes the tank you are in at once.'},
    torque = {global = 'ArmoredOverhaulPower', file = 'TankPower', title = 'Tank Engine Torque', what = 'engine torque',
              menu = 'power', choices = {'Off', 'Strong (x1.2)', 'Stronger (x1.35)', 'Strongest (x1.5)'}, mults = {1, 1.2, 1.35, 1.5},
              description = 'More engine torque for the Bastion and Maelstrom: quicker off the line and up slopes. Changes the tank you are in at once.'},
    grip = {global = 'ArmoredOverhaulHandling', file = 'TankHandling', title = 'Tank Grip', what = 'track grip',
            menu = 'grip', choices = {'Off', 'Moderate (x1.2)', 'Strong (x1.35)', 'Maximum (x1.5)'}, mults = {1, 1.2, 1.35, 1.5},
            description = 'More track grip for the Bastion and Maelstrom: less sliding on slopes and in turns. Changes the tank you are in at once.'},
    -- (Test 20) no menu row of its own: it follows Tank Throttle Response's pick (the Steering source's 'throttle' part)
    shift = {global = 'ArmoredOverhaulShift', file = 'TankShift', title = 'Tank Throttle Response (gear changes)', what = 'clutch delay',
             follow = 'ArmoredOverhaulThrottle', choices = {'Off', 'Quick', 'Quicker', 'Instant'}, mults = {1, 0.5, 0.2, 0}},
    -- (Test 29) downforce: the tank pressed down harder the faster it goes (the multiplier is its weight at 45 km/h; see the
    -- top). Tests 24-28 raised the roll factor instead (the tester: x2 "rolled easier"; "leave that at 1")
    stability = {global = 'ArmoredOverhaulStability', file = 'TankStability', title = 'Tank Stability', what = 'weight at 45 km/h, from downforce',
                 menu = 'stability', choices = {'Off', 'Stable', 'Steady', 'Planted'}, mults = {1, 1.5, 2, 3},   -- (Test 37: were 1.15 / 1.3 / 1.5)
                 description = 'Keeps the Bastion and Maelstrom on the ground: pressed down harder the faster they go, so they stay flat over crests and bumps instead of floating. Changes the tank you are in at once.'},
}
local P = PARTS[PART]
if not P or rawget(_G, P.global) then return end

local byte, min, max, floor = string.byte, math.min, math.max, math.floor
local TWO32 = 4294967296
local KNOWN_RVA, KNOWN_TIMESTAMP = 0x719554, 0x6AB3B43F
-- The game's tank engine on that build (both tanks): a tank found with another max rpm was boosted already (an
-- earlier copy of this addon whose Lua was rebuilt while the game kept running): its own values are worked back.
local VANILLA_MAX_RPM, VANILLA_TORQUE = 5000, 4000
local VANILLA_FRICTION, VANILLA_MAX_FRICTION = 0.5, 1.5            -- (every wheel, both tanks)
local WHEEL_SIZE, FRICTION_AT, MAX_FRICTION_AT, MAX_WHEELS = 0x2C, 0xC, 0x14, 10
local TRANS_SIZE, CLUTCH_AT, VANILLA_CLUTCH = 0x14, 0x10, 0.3
local ROW_SIZE, ROLL_AT, VANILLA_ROLL, VANILLA_PITCH = 0x670, 0x630, 1, 1
-- (3.4.0 review) the record's air factor: the game sends density x (+0x654 x +0x658) (game.dll+0x718E20)
local AIR_AT = 0x654
-- (Test 29) Tank Stability's downforce: both hulls 30000 kg, frontal area 8, lift 0, air density 15, drag 14 (the hull
-- physics' own); the pick is the tank's weight at 45 km/h
local HULL_MASS, GRAVITY, FRONTAL_AREA, REF_SPEED, VANILLA_LIFT = 30000, 9.81, 8, 12.5, 0
local VANILLA_DENSITY, VANILLA_DRAG = 15, 14
-- mov rax,[rbx+58h] / mov rbx,[rax+rcx*8] / mov rcx,rbx / call (accessor) / mov r9,[rip+INFO] / lea r8,[rbp+x] /
-- mov ecx,[rbx+0Ch] / mov edx,10h / mov rdi,rax / call [r9] / ... / mov rax,[rip+API] / ... / call [rax+80h]
local SITE = '48 8B 43 58 48 8B 1C C8 48 8B CB E8 ?? ?? ?? ?? 4C 8B 0D ?? ?? ?? ?? 4C 8D 45 ?? 8B 4B 0C BA 10 00 00 00 48 8B F8 41 FF 11 48 8B 4D ?? 48 8D 55 ?? 33 C0 0F 57 C0 8B 19 8B CB 48 89 45 ?? 89 45 ?? 48 8B 05 ?? ?? ?? ?? 0F 11 45 ?? 0F 11 45 ?? 0F 11 45 ?? FF 90 80 00 00 00'
local SITE_ANCHOR, SITE_ANCHOR_AT = '\xBA\x10\x00\x00\x00\x48\x8B\xF8\x41\xFF\x11', 0x1E
local INFO_DISP, API_DISP = 0x13, 0x44           -- (rip-relative: next instruction at +0x17 / +0x48)
-- the same function's map lookup, up to 0x100 bytes before: cmp edx,[rip+x] / mov rbx,[rip+COMPONENT] / jne / ...
local LOOKUP = '3B 15 ?? ?? ?? ?? 48 8B 1D ?? ?? ?? ?? 75 ?? B8 FF FF FF FF EB ?? 44 8B 4B 48 33 C9 44 8B 53 50'
local LOOKUP_DISP = 0x9                          -- (next instruction at +0xD)
local ENGINE_SIZE, MAX_RPM_AT, TORQUE_AT = 0x28, 0x8, 0xC
local TANK_KINDS = {[0x2B] = 'Bastion', [0x2C] = 'Maelstrom'}
-- frames between looks at the tank you are in (~2 s): a new tank, or one the game set up again under the same handle
-- (every value read back and put right; 3.4.0 review: Stability's lift, which the game's read doesn't show, is sent at
-- every look for that)
local CHECK_EVERY = 120
local MAX_TANKS = 8

local state = {version = '3.4.0', status = 'starting', game = 'unchecked', found = 'not yet', preset = 'unread',
               tanks = {}, errors = 0, last_error = 'none', frames = 0, writes = 0,
               options_menu = 'not installed (the mod manager\'s pick is used)'}
state.part, state.live_mult = PART, 1            -- (Test 20: what this part multiplies now, for the other parts)
rawset(_G, P.global, state)
-- (Test 20) every live part's own record of each tank's own values (shared: the first part to see a tank keeps them)
local OWN = rawget(_G, 'ArmoredOverhaulLiveOwn')
if type(OWN) ~= 'table' then OWN = {}; rawset(_G, 'ArmoredOverhaulLiveOwn', OWN) end
-- (3.4.0 review) the places the first part found, by game build (the others check the code there instead of searching)
local PLACES = rawget(_G, 'ArmoredOverhaulLivePlaces')
if type(PLACES) ~= 'table' then PLACES = {}; rawset(_G, 'ArmoredOverhaulLivePlaces', PLACES) end

-- (3.3.0) The logs folder: Bingus Shared Loader v19's log_directory, else %LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs.
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
local ok_ffi, ffi = pcall(require, 'ffi')
if not ok_ffi or not ffi.abi('win') or not ffi.abi('64bit') then return end
pcall(ffi.cdef, [[
    typedef struct { void *base; void *allocation_base; uint32_t allocation_protection; uint16_t partition;
        uint16_t reserved; size_t size; uint32_t state; uint32_t protection; uint32_t type; } TsRegion;
]])
-- (1.1.0 lesson) each kernel32 function declared on its own before it is looked up
for _, decl in ipairs({'void *GetModuleHandleA(const char *);', 'void *GetCurrentProcess(void);',
        'int ReadProcessMemory(void *, const void *, void *, size_t, size_t *);',
        'size_t VirtualQuery(const void *, void *, size_t);'}) do
    pcall(ffi.cdef, decl)
end
local okk, k32 = pcall(ffi.load, 'kernel32')
if not okk then return end
local GetModuleHandleA = ffi.cast('void *(*)(const char *)', k32.GetModuleHandleA)
local GetCurrentProcess = ffi.cast('void *(*)(void)', k32.GetCurrentProcess)
local ReadProcessMemory = ffi.cast('int (*)(void *, const void *, void *, size_t, size_t *)', k32.ReadProcessMemory)
local VirtualQuery = ffi.cast('size_t (*)(const void *, void *, size_t)', k32.VirtualQuery)
local U8 = ffi.typeof('uint8_t *')
local process = GetCurrentProcess()
local BUF_SIZE = 0x40400
local buf = ffi.new('uint8_t[?]', BUF_SIZE)
local got = ffi.new('size_t[1]')
local region = ffi.new('TsRegion[1]')
-- own function-pointer types: another mod's declarations can't clash with them
local INFO_FN = ffi.typeof('int64_t (*)(uint32_t, uint32_t, void *)')
local ENGINE_FN = ffi.typeof('void (*)(uint32_t, void *)')
local WHEEL_FN = ffi.typeof('void (*)(uint32_t, uint32_t, void *)')
local AERO_GET_FN = ffi.typeof('void (*)(uint32_t, float *, float *, float *)')   -- (Test 29: Tank Stability)
local AERO_SET_FN = ffi.typeof('void (*)(uint32_t, float, float, float)')
local info_out = ffi.new('uint8_t[256]')
local engine_buf = ffi.new('uint8_t[64]')

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
local fbox = ffi.new('float[1]')
-- (3.4.0 review) nil for a missing or short read (the checks below then say no, not throw)
local function f32(s, o)
    if type(s) ~= 'string' or o < 0 or o + 4 > #s then return nil end
    ffi.copy(fbox, ffi.cast('const char *', s) + o, 4); return tonumber(fbox[0])
end
local function with_f32(s, o, v)
    fbox[0] = v
    return s:sub(1, o) .. ffi.string(fbox, 4) .. s:sub(o + 5)
end
-- executable code (a function the game's own table points at): checked before every first call through it
local function is_code(p)
    if p == nil or VirtualQuery(p, region, ffi.sizeof('TsRegion')) == 0 then return false end
    local r = region[0]
    return r.state == 0x1000 and bit.band(r.protection, 0xF0) ~= 0 and bit.band(r.protection, 0x101) == 0
end

-- (Test 20) game data the parts write (the torque factors): committed read/write heap, the whole span in one region
local function writable(p, n)
    if p == nil or VirtualQuery(p, region, ffi.sizeof('TsRegion')) == 0 then return false end
    local r = region[0]
    return r.state == 0x1000 and (r.protection == 4 or r.protection == 0x40) and (r.type == 0x20000 or r.type == 0x40000)
        and num(p) + n <= num(r.base) + tonumber(r.size)
end
local function poke(p, values)
    local f = ffi.cast('float *', p)
    for i, v in ipairs(values) do f[i - 1] = v end
end

local function parse(text)
    local out = {}
    for t in text:gmatch('%S+') do out[#out + 1] = t == '??' and -1 or tonumber(t, 16) end
    return out
end
local SITE_MASK, LOOKUP_MASK = parse(SITE), parse(LOOKUP)
local function matches(s, start, mask)
    if start < 1 or start + #mask - 1 > #s then return false end
    for i = 1, #mask do
        local w = mask[i]
        if w >= 0 and byte(s, start + i - 1) ~= w then return false end
    end
    return true
end

-- ---------------------------------------------------------------- logging
local tanks, order               -- (see applying)
local function log()
    pcall(function()
        local f = loader.open_log and loader.open_log('ArmoredOverhaul-' .. P.file .. '.log')
        if not f then return end
        f:write('Armored Overhaul - ', P.title, '\n', 'version: ', state.version, '\n', 'status: ', state.status, '\n',
            'game: ', state.game, '\n', 'found: ', state.found, '\n', 'preset: ', state.preset, '\n')
        local any = false
        for _, vehicle in ipairs(order) do
            if state.tanks[vehicle] then f:write(state.tanks[vehicle], '\n'); any = true end
        end
        if not any then f:write('tanks: none sat in yet\n') end
        f:write('options menu: ', state.options_menu, '\n', 'errors: ', state.errors, '\n', 'last error: ', state.last_error, '\n')
        if TESTER then f:write('-- tester details --\n', 'writes: ', state.writes, '\n', 'frames: ', state.frames, '\n') end
        f:close()
    end)
end
local function fail(what)
    state.errors = state.errors + 1
    state.last_error = what
end

-- ---------------------------------------------------------------- finding the game's places
local game, image_size, timestamp
local G = {}                 -- info, api, component (addresses of the three pointers in game.dll)
local scan = {at = nil}      -- a search through game.dll, a few pieces a frame
local function site_at(base_rva, s, i)
    -- s: bytes read from game.dll at rva base_rva; i: 1-based index of the site's first byte
    if not matches(s, i, SITE_MASK) then return false end
    local site = base_rva + i - 1
    local info = site + 0x17 + i32(s, i - 1 + INFO_DISP)
    local api = site + 0x48 + i32(s, i - 1 + API_DISP)
    -- the map lookup, up to 0x100 bytes before the site
    local before = read(game + site - 0x100, 0x100)
    if not before then return false end
    for j = 0x100 - #LOOKUP_MASK + 1, 1, -1 do
        if matches(before, j, LOOKUP_MASK) then
            local at = site - 0x100 + j - 1
            G.info, G.api, G.component = info, api, at + 0xD + i32(before, j - 1 + LOOKUP_DISP)
            G.site = site
            return true
        end
    end
    return false
end
local function find_step()
    -- first the known place (this build), then the place another part found on this build (its code checked as the
    -- known place's is), then the whole of game.dll, 16 pieces of 256 KB a frame
    if not scan.at then
        scan.at = 0x1000
        local s = read(game + KNOWN_RVA, #SITE_MASK)
        if s and site_at(KNOWN_RVA, s, 1) then return 'at its known place' end
    end
    local shared = PLACES[state.game]
    local at = type(shared) == 'table' and tonumber(shared.site)
    if at and at ~= scan.tried and at >= 0x1000 and at + #SITE_MASK <= image_size then
        scan.tried = at
        local s = read(game + at, #SITE_MASK)
        if s and site_at(at, s, 1) then return 'where another part found it' end
    end
    for _ = 1, 16 do
        if scan.at >= image_size then return false end
        local n = min(0x40000 + 0x100, image_size - scan.at)
        local s = read(game + scan.at, n)
        if s then
            local from = 1
            while true do
                local k = s:find(SITE_ANCHOR, from, true)
                if not k then break end
                if k - SITE_ANCHOR_AT >= 1 and site_at(scan.at, s, k - SITE_ANCHOR_AT) then return 'by its code pattern' end
                from = k + 1
            end
        end
        scan.at = scan.at + 0x40000
    end
    return nil
end

-- ---------------------------------------------------------------- the tank's engine
local fns = {}
local function fn(slot_table, slot, ctype)
    local key = slot_table .. slot
    if fns[key] then return fns[key] end
    local tbl = ptr(read(game + G[slot_table], 8))
    local p = tbl and ptr(read(tbl + slot, 8))
    if not p or not is_code(p) then return nil end
    fns[key] = ffi.cast(ctype, p)
    return fns[key]
end
local function handle_of(vehicle)
    local comp = ptr(read(game + G.component, 8))
    local hdr = comp and read(comp + 0x40, 0x20)
    if not hdr then return nil, 'vehicle list unreadable' end
    local entries, cap, empty, mult = ptr(hdr, 0), u32(hdr, 8), u32(hdr, 12), u32(hdr, 16)
    if not entries or cap == 0 or cap > 0x100000 then return nil, 'vehicle list empty' end
    local start = tonumber(ffi.cast('uint32_t', ffi.cast('uint64_t', vehicle) * mult))
    local idx
    for i = 0, min(cap, 64) - 1 do
        local e = read(entries + ((start + i) % cap) * 8, 8)
        if not e then return nil, 'vehicle list unreadable' end
        local k = u32(e, 0)
        if k == empty then break end
        if k == vehicle then idx = u32(e, 4); break end
    end
    if not idx or idx > 0xFFFF then return nil, 'tank not in the vehicle list' end
    local per = ptr(hdr, 0x18)
    local ent = per and ptr(read(per + idx * 8, 8))
    local rec = ent and read(ent, 0x10)
    if not rec then return nil, 'tank record unreadable' end
    local info = fn('info', 0, INFO_FN)
    if not info then return nil, 'physics lookup not found' end
    ffi.fill(info_out, 256)
    info(u32(rec, 0xC), 0x10, info_out)
    local hp = ptr(ffi.string(info_out + 0x20, 8))
    local h = hp and read(hp, 4)
    if not h then return nil, 'no physics handle' end
    return u32(h, 0), idx, comp
end
-- (Test 20) the tank's 0x670-byte record (component +0x70, by its index)
local function row_of(comp, idx)
    local rows = comp and ptr(read(comp + 0x70, 8))
    return rows and rows + idx * ROW_SIZE
end
local function get_block(h, slot, size)
    local f = fn('api', slot, ENGINE_FN)
    if not f then return nil end
    ffi.fill(engine_buf, 64)
    f(h, engine_buf)
    return ffi.string(engine_buf, size)
end
local function set_block(h, slot, s)
    local f = fn('api', slot, ENGINE_FN)
    if not f then return false end
    ffi.fill(engine_buf, 64)
    ffi.copy(engine_buf, s, #s)
    f(h, engine_buf)
    return true
end
local function get_engine(h) return get_block(h, 0x80, ENGINE_SIZE) end
local function set_engine(h, s) return set_block(h, 0x88, s) end
local function get_trans(h) return get_block(h, 0x90, TRANS_SIZE) end
local function set_trans(h, s) return set_block(h, 0x98, s) end
local function is_trans(s)
    local down, up, clutch = f32(s, 0), f32(s, 4), f32(s, CLUTCH_AT)
    if not (down and up and clutch) then return false end
    return down > 10 and down < 50000 and up > down and up < 50000 and clutch >= 0 and clutch < 10
end
-- (3.4.0 review) an engine block that looks like one (max rpm and torque in range) before anything is worked from it
local function is_engine(s)
    local rpm, tq = f32(s, MAX_RPM_AT), f32(s, TORQUE_AT)
    if not (rpm and tq) then return false end
    return rpm > 100 and rpm < 50000 and tq > 10 and tq < 1e6
end

-- (Test 20) a wheel's block (wheel i: 0..9, the indices the game's own per-wheel handlers use)
local wheel_buf = ffi.new('uint8_t[64]')
local function get_wheel(h, i)
    local f = fn('api', 0x40, WHEEL_FN)
    if not f then return nil end
    ffi.fill(wheel_buf, 64)
    f(h, i, wheel_buf)
    return ffi.string(wheel_buf, WHEEL_SIZE)
end
local function set_wheel(h, i, s)
    local f = fn('api', 0x48, WHEEL_FN)
    if not f then return false end
    ffi.fill(wheel_buf, 64)
    ffi.copy(wheel_buf, s, #s)
    f(h, i, wheel_buf)
    return true
end
local function is_wheel(s)
    local r, m, fr, mf = f32(s, 0), f32(s, 8), f32(s, FRICTION_AT), f32(s, MAX_FRICTION_AT)
    if not (r and m and fr and mf) then return false end
    return r > 0.05 and r < 3 and m >= 1 and m < 100000 and fr >= 0 and fr < 20 and mf >= 0 and mf < 50
end
-- (Test 29) the aerodynamics (Tank Stability): slot 0x20 reads air density, drag and lift; slot 0x28 sets them (by value)
local aero_buf = ffi.new('float[3]')
local function get_aero(h)
    local f = fn('api', 0x20, AERO_GET_FN)
    if not f then return nil end
    aero_buf[0], aero_buf[1], aero_buf[2] = -1, -1, -1e9
    f(h, aero_buf, aero_buf + 1, aero_buf + 2)
    return {aero_buf[0], aero_buf[1], aero_buf[2]}
end
local function set_aero(h, density, drag, lift)
    local f = fn('api', 0x28, AERO_SET_FN)
    if not f then return false end
    f(h, density, drag, lift)
    return true
end
local function is_aero(a)
    if type(a) ~= 'table' or type(a[1]) ~= 'number' or type(a[2]) ~= 'number' or type(a[3]) ~= 'number' then return false end
    return a[1] > 0.01 and a[1] < 1000 and a[2] >= 0 and a[2] < 1000 and a[3] > -1000 and a[3] < 1000
end
-- (3.4.0 review) the tank's air factor, as the game's own call works it (record +0x654 x +0x658; 1 when unreadable or
-- out of range): the read gives the resource's density, the physics holds it times this
local function air_factor(comp, idx)
    local row = row_of(comp, idx)
    local v = row and read(row + AIR_AT, 8)
    local a, b = f32(v, 0), f32(v, 4)
    if not (a and b and a > 0 and a < 100 and b > 0 and b < 100) then return 1 end
    return a * b
end
-- downforce (newtons, negative = down) of a lift coefficient at 45 km/h, and the lift that gives the picked weight there
local function downforce(density, lift) return 0.5 * density * FRONTAL_AREA * lift * REF_SPEED * REF_SPEED end
local function wanted_lift(own, density, m)
    if m == 1 then return own end
    return own - (m - 1) * HULL_MASS * GRAVITY / (0.5 * density * FRONTAL_AREA * REF_SPEED * REF_SPEED)
end

-- ---------------------------------------------------------------- applying
local mult = PRESET
state.live_mult = mult
tanks, order = {}, {}            -- vehicle id -> {h, own, name, note}
-- the other live part's multiplier (Top Speed and Engine Torque both set the torque: it is their product)
local function other(global)
    local st = rawget(_G, global)
    local m = type(st) == 'table' and tonumber(st.live_mult)
    return (m and m > 0.1 and m < 10) and m or 1
end
-- what the engine block should hold: from the tank's own block, max rpm x Top Speed, torque x Top Speed x Engine Torque
local function wanted_engine(own)
    local s = PART == 'speed' and mult or other('ArmoredOverhaulTopSpeed')
    local q = PART == 'torque' and mult or other('ArmoredOverhaulPower')
    local e = own
    if s ~= 1 then e = with_f32(e, MAX_RPM_AT, f32(own, MAX_RPM_AT) * s) end
    if s * q ~= 1 then e = with_f32(e, TORQUE_AT, f32(own, TORQUE_AT) * s * q) end
    return e
end
-- the tank's own engine block: on the known build its rpm and torque are the game's (whatever another part or an earlier
-- copy wrote); on others what it held when a live part first saw it
local function own_engine(key, now)
    local o = OWN[key]
    if o and o.engine then return o.engine, o.note end
    local own, note = now, nil
    if timestamp == KNOWN_TIMESTAMP then
        local rpm, tq = f32(now, MAX_RPM_AT), f32(now, TORQUE_AT)
        if math.abs(rpm - VANILLA_MAX_RPM) > 1 or math.abs(tq - VANILLA_TORQUE) > 1 then
            own = with_f32(with_f32(now, MAX_RPM_AT, VANILLA_MAX_RPM), TORQUE_AT, VANILLA_TORQUE)
            note = string.format(' (found at %.0f rpm / %.0f torque: the game\'s own taken)', rpm, tq)
        end
    end
    OWN[key] = OWN[key] or {}
    OWN[key].engine, OWN[key].note = own, note
    return own, note
end
local function own_wheels(key, h)
    local o = OWN[key]
    if o and o.wheels then return o.wheels end
    local list = {}
    for i = 0, MAX_WHEELS - 1 do
        local w = get_wheel(h, i)
        if not w or not is_wheel(w) then break end
        if timestamp == KNOWN_TIMESTAMP then w = with_f32(with_f32(w, FRICTION_AT, VANILLA_FRICTION), MAX_FRICTION_AT, VANILLA_MAX_FRICTION) end
        list[#list + 1] = w
    end
    if #list == 0 then return nil end
    OWN[key] = OWN[key] or {}
    OWN[key].wheels = list
    return list
end
-- (Test 20) the gearbox: its own block (on the known build its clutch delay is the game's 0.3 s, whatever was written)
local function own_trans(key, now)
    local o = OWN[key]
    if o and o.trans then return o.trans end
    local own = now
    if timestamp == KNOWN_TIMESTAMP then own = with_f32(now, CLUTCH_AT, VANILLA_CLUTCH) end
    OWN[key] = OWN[key] or {}
    OWN[key].trans = own
    return own
end
-- (3.4.0 review) the log line is made again only when something it shows changed (not at every look)
local function unchanged(t, ...)
    local k, n = t.shown, select('#', ...)
    if k and k.n == n then
        local same = true
        for i = 1, n do if k[i] ~= select(i, ...) then same = false; break end end
        if same then return true end
    end
    t.shown = {n = n, ...}
    return false
end
local function describe(t, now)
    local roll, pitch = t.tilt_now and t.tilt_now[1], t.tilt_now and t.tilt_now[2]
    local sent = PART == 'stability' and (t.aero_sent or now[3]) or nil
    if PART == 'stability' then
        if unchanged(t, now[1], now[2], now[3], sent, t.aero_own, t.aero_density, t.aero_drag, roll, pitch, t.tilt_skip) then return end
    elseif unchanged(t, now, t.own, t.own1, t.wheels, t.note, roll, pitch, t.tilt_skip) then return end
    local head = string.format('%s 0x%X: ', t.name, t.vehicle)
    local tail = (t.tilt_skip and '; torque factors not confirmed on this game version (left alone)')
        or (roll and string.format('; torque roll %.3f, pitch %.3f', roll, pitch)) or ''
    if PART == 'grip' then
        state.tanks[t.vehicle] = head .. string.format('%d wheels, friction %.3f / max %.3f (their own %.3f / %.3f)%s',
            t.wheels or 0, f32(now, FRICTION_AT), f32(now, MAX_FRICTION_AT), f32(t.own1, FRICTION_AT), f32(t.own1, MAX_FRICTION_AT), t.note or '') .. tail
    elseif PART == 'shift' then
        state.tanks[t.vehicle] = head .. string.format('clutch delay %.3f s (its own %.3f s)', f32(now, CLUTCH_AT), f32(t.own, CLUTCH_AT))
    elseif PART == 'stability' then
        local d = t.aero_density
        state.tanks[t.vehicle] = head .. string.format('lift %.2f sent (the game reads back %.2f; its own %.2f; air density %.3g (x%.3g the tank\'s air factor), drag %.3g): pressed down with %.0f kN at 45 km/h, x%.2f its weight',
            sent, now[3], t.aero_own, d, t.aero_factor or 1, t.aero_drag, -downforce(d, sent - t.aero_own) / 1000, 1 - downforce(d, sent - t.aero_own) / (HULL_MASS * GRAVITY)) .. tail
    else
        state.tanks[t.vehicle] = head .. string.format('max rpm %.0f, torque %.0f (its own %.0f / %.0f)%s',
            f32(now, MAX_RPM_AT), f32(now, TORQUE_AT), f32(t.own, MAX_RPM_AT), f32(t.own, TORQUE_AT), t.note or '') .. tail
    end
end
local function remember(vehicle, h, name)
    local t = tanks[vehicle]
    if t and t.h == h then return t end
    if not t then
        order[#order + 1] = vehicle
        if #order > MAX_TANKS then local old = table.remove(order, 1); tanks[old] = nil; state.tanks[old] = nil end
    end
    t = {vehicle = vehicle, h = h, key = string.format('%X:%X', vehicle, h), name = name or (t and t.name) or 'tank'}
    tanks[vehicle] = t
    return t
end
local function far(a, b) return math.abs(a[1] - b[1]) > 1e-5 or math.abs(a[2] - b[2]) > 1e-5 end
-- two floats of game data (the record's torque factors): written when not what is wanted, read back
local function put_pair(t, at, want, what)
    if not writable(at, 8) then return nil, what .. ': memory not writable' end
    poke(at, want)
    state.writes = state.writes + 1
    local v = read(at, 8)
    local now = v and {f32(v, 0), f32(v, 4)}
    if not now or far(now, want) then fail(string.format('%s 0x%X: the %s did not take the new values', t.name, t.vehicle, what)) end
    return now or want
end
-- (Test 23) the torque factors every part sets (see the top), from the tank's own: whichever part looks last writes the
-- same values (each reads the others' multipliers), so they never fight
local function wanted_tilt(own)
    local sp = PART == 'speed' and mult or other('ArmoredOverhaulTopSpeed')
    local q = PART == 'torque' and mult or other('ArmoredOverhaulPower')
    return {own[1], own[2] / (sp * q)}                 -- (Test 29: the roll factor the tank's own again)
end
local function apply_tilt(t, idx, comp)
    local row = row_of(comp, idx)
    local v = row and read(row + ROLL_AT, 8)
    if not v then return false, 'record unreadable' end
    local now = {f32(v, 0), f32(v, 4)}
    if not (now[1] and now[2] and now[1] >= 0 and now[1] < 20 and now[2] >= 0 and now[2] < 20) then return false, 'torque factors out of range' end
    -- (3.4.0 review) the record's place is known on the known build only: on another, written only where it reads about
    -- 1 and 1 (the game's own) or what this part, or another live part, wrote there last (they all write the same
    -- values); else left alone, and said in the log
    local wrote = OWN[t.key] and OWN[t.key].tilt_held
    if timestamp ~= KNOWN_TIMESTAMP and not (math.abs(now[1] - 1) < 0.05 and math.abs(now[2] - 1) < 0.05)
            and not (t.held and not far(now, t.held)) and not (wrote and not far(now, wrote)) then
        t.tilt_now, t.tilt_skip = nil, true
        return true
    end
    t.tilt_skip = nil
    OWN[t.key] = OWN[t.key] or {}
    if not OWN[t.key].tilt then
        OWN[t.key].tilt = timestamp == KNOWN_TIMESTAMP and {VANILLA_ROLL, VANILLA_PITCH} or now
    end
    t.tilt_own, t.at = OWN[t.key].tilt, row + ROLL_AT
    local want = wanted_tilt(t.tilt_own)
    if far(now, want) then
        local done, why = put_pair(t, t.at, want, 'torque factors')
        if not done then return false, why end
        now = done
    end
    t.held, t.tilt_now, OWN[t.key].tilt_held = now, now, now
    return true
end
local apply_part = {}
apply_part.grip = function(t, h, idx, comp)
    local own = own_wheels(t.key, h)
    if not own then return false, 'wheels unreadable' end
    t.wheels, t.own1, t.own_wheels, t.want_wheels = #own, own[1], own, {}
    local first
    for i, w in ipairs(own) do
        local want = mult == 1 and w or with_f32(with_f32(w, FRICTION_AT, f32(w, FRICTION_AT) * mult), MAX_FRICTION_AT, f32(w, MAX_FRICTION_AT) * mult)
        t.want_wheels[i] = want                -- (3.4.0 review: put back at shutdown where the wheel still holds it)
        local now = get_wheel(h, i - 1)
        if not now then return false, 'wheel unreadable' end
        if now ~= want then
            if not set_wheel(h, i - 1, want) then return false, 'wheel write not found' end
            state.writes = state.writes + 1
            now = get_wheel(h, i - 1)
            if now ~= want then fail(string.format('%s 0x%X: wheel %d did not take the new values', t.name, t.vehicle, i - 1)) end
        end
        first = first or now
    end
    local ok, why = apply_tilt(t, idx, comp)
    describe(t, first)
    if not ok then return false, why end
    return true
end
apply_part.shift = function(t, h)
    local now = get_trans(h)
    if not now or not is_trans(now) then return false, 'transmission unreadable' end
    t.own = own_trans(t.key, now)
    local want = with_f32(t.own, CLUTCH_AT, f32(t.own, CLUTCH_AT) * mult)
    t.want_trans = want
    if now ~= want then
        if not set_trans(h, want) then return false, 'transmission write not found' end
        state.writes = state.writes + 1
        now = get_trans(h)
        if now ~= want then fail(string.format('%s 0x%X: the transmission did not take the new values', t.name, t.vehicle)) end
    end
    describe(t, now or want)
    return true
end
apply_part.stability = function(t, h, idx, comp)
    local now = get_aero(h)
    if not is_aero(now) then return false, 'aerodynamics unreadable' end
    local o = OWN[t.key] or {}
    OWN[t.key] = o
    local known = timestamp == KNOWN_TIMESTAMP
    if o.lift == nil then o.lift = known and VANILLA_LIFT or now[3] end
    -- (3.4.0 review) density and drag: the tank's own (the resource's, as the read gives them), the density times the
    -- tank's air factor as the game's own call sends it (the read's density was sent back unscaled before)
    if o.density == nil then o.density, o.drag = known and VANILLA_DENSITY or now[1], known and VANILLA_DRAG or now[2] end
    t.aero_factor = air_factor(comp, idx)
    t.aero_own, t.aero_drag, t.aero_density = o.lift, o.drag, o.density * t.aero_factor
    local want = wanted_lift(t.aero_own, t.aero_density, mult)
    -- (Test 30) Test 29: the read after the write still gives the old lift (160 times); Test 36 showed the call reaches
    -- the physics (a positive lift lifted the tank). (3.4.0 review) Where the read doesn't follow the write, a lift the
    -- game put back can't be seen: the lift is sent at every look (one call each ~2 s); where it does, only when the read
    -- shows something else, as the other parts do
    if not t.aero_echo or math.abs(now[3] - want) > 1e-3 or math.abs(now[1] - t.aero_density) > 1e-3 then
        if not set_aero(h, t.aero_density, t.aero_drag, want) then return false, 'aerodynamics write not found' end
        state.writes = state.writes + 1
        t.aero_sent = want
        -- (the read follows the write when it showed another lift before and shows the new one now: checked once)
        if t.aero_echo == nil and math.abs(now[3] - want) > 1e-3 then
            local back = get_aero(h)
            if is_aero(back) then t.aero_echo = math.abs(back[3] - want) < 1e-3; now = back end
        end
    end
    t.aero_held = t.aero_sent or now[3]
    local ok, why = apply_tilt(t, idx, comp)
    describe(t, now)
    if not ok then return false, why end
    return true
end
local function apply_engine(t, h, idx, comp)
    local now = get_engine(h)
    if not now then return false, 'engine unreadable' end
    -- (3.4.0 review) nothing is worked from, or written over, a block that doesn't look like an engine's
    if not is_engine(now) then return false, 'engine values out of range' end
    t.own, t.note = own_engine(t.key, now)
    local want = wanted_engine(t.own)
    if not is_engine(t.own) or not is_engine(want) then return false, 'engine values out of range' end
    t.want = want                          -- (put back at shutdown where the engine still holds it)
    if now ~= want then
        if not set_engine(h, want) then return false, 'engine write not found' end
        state.writes = state.writes + 1
        now = get_engine(h)
        if now ~= want then fail(string.format('%s 0x%X: the engine did not take the new values', t.name, t.vehicle)) end
    end
    local ok, why = apply_tilt(t, idx, comp)
    describe(t, now or want)
    if not ok then return false, why end
    return true
end
apply_part.speed, apply_part.torque = apply_engine, apply_engine
-- one tank: found again, its values read; written when they aren't what this part wants
local function apply(vehicle, name)
    local h, idx, comp = handle_of(vehicle)
    if not h then return false, idx end
    return apply_part[PART](remember(vehicle, h, name), h, idx, comp)
end

-- ---------------------------------------------------------------- Mod Options Menu (3.0) - as the other options
local menu_rows, menu_set, menu_link = {}, nil, nil
do
    local MENU_ORDER = {'speed', 'power', 'grip', 'steering', 'throttle', 'stability', 'turret', 'autoloader', 'gunner_drive', 'driver_panel', 'camera', 'indicator', 'loadout'}
    local hub = rawget(_G, 'ArmoredOverhaulMenu')
    if type(hub) ~= 'table' or type(hub.groups) ~= 'table' then hub = {groups = {}, done = {}}; rawset(_G, 'ArmoredOverhaulMenu', hub) end
    if P.menu then hub.groups[P.menu] = {status = state,
        rows = function() local r = menu_rows[P.menu]; if type(r) == 'function' then r = r() end; return r or {} end,
        set = function(key, value) return menu_set(key, value) end} end
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
        if frame ~= true and frame < at then return end
        at = (frame == true and 0 or frame) + 60
        if not P.menu or hub.done[P.menu] then at = math.huge; return end
        local M = rawget(_G, 'ModOptionsMenu')
        if type(M) ~= 'table' or M.api ~= 1 or type(M.register_option) ~= 'function' then return end
        for _, g in ipairs(MENU_ORDER) do pcall(add, M, g) end
        for g in pairs(hub.groups) do pcall(add, M, g) end
    end
    local L = rawget(_G, 'CowboyBingusModLoader')
    if type(L) == 'table' and type(L.after_startup) == 'function' then pcall(L.after_startup, function() pcall(menu_link, true) end) end
end
-- (3.4.0 Test 7, the tester: "2x is too fast") Top Speed's Fastest was x1.5; (Test 22, the tester: "50% is a little excessive") it is
-- x1.25 on both tanks, with Fast x1.1 and Faster x1.15; (Test 28, the tester: "fastest can be 1.3") Fastest x1.3
local MENU_CHOICES, MENU_MULTS = P.choices, P.mults
local MENU_PICK = 2
for i, m in ipairs(MENU_MULTS) do if i > 1 and math.abs(m - PRESET) < 1e-6 then MENU_PICK = i end end
if P.menu then menu_rows[P.menu] = {
    {'armored_overhaul.' .. P.menu .. '.' .. PRESET_NAME:lower(), {type = 'choice', label = P.title, choices = MENU_CHOICES,
        default = MENU_PICK, description = P.description}, 'mult'},
} else state.options_menu = 'follows ' .. P.follow:gsub('^ArmoredOverhaul', '') .. ' (no row of its own)' end
local function preset_text(v)
    if P.follow and v == 1 then return string.format('off: the tanks\' own %s (Tank Throttle Response off)', P.what) end
    if P.follow then return string.format('%s (%g times the %s, from Tank Throttle Response)', MENU_CHOICES[v], MENU_MULTS[v], P.what) end
    if v == MENU_PICK then return string.format('%s (%s times the %s, picked in the mod manager)', PRESET_NAME, tostring(PRESET), P.what) end
    if v == 1 then return string.format('off: the tanks\' own %s (Mod Options Menu)', P.what) end
    return string.format('%s (%g times the %s, Mod Options Menu)', MENU_CHOICES[v], MENU_MULTS[v], P.what)
end
state.preset = preset_text(MENU_PICK)
local next_check = 0
local log_if_changed
menu_set = function(key, v)
    if key ~= 'mult' or not MENU_MULTS[v] then return end
    mult = MENU_MULTS[v]
    state.live_mult = mult
    state.preset = preset_text(v)
    -- every tank this addon has changed gets the new value now (Off: its own engine back)
    if G.api then
        for _, vehicle in ipairs(order) do
            local t = tanks[vehicle]
            if t then local ok, why = pcall(apply, vehicle, t.name); if not ok then fail(tostring(why)) end end
        end
    end
    -- the tank you are in at the next frame, unless it was just changed above (3.4.0 review: it was changed twice)
    local seat = rawget(_G, 'ArmoredOverhaulSeat')
    local sv = type(seat) == 'table' and tonumber(seat.vehicle)
    if not (G.api and sv and tanks[sv]) then next_check = 0 end
    log_if_changed()
end

-- ---------------------------------------------------------------- each frame
local phase = 'gate'
local last_summary
-- the log is written when what it says changes (not every look)
log_if_changed = function()
    local parts = {state.status, state.preset, state.errors, state.options_menu}
    for _, vehicle in ipairs(order) do parts[#parts + 1] = state.tanks[vehicle] end
    local summary = table.concat(parts, '|')
    if summary ~= last_summary then last_summary = summary; log() end
end
local followed                    -- (shift) the pick last taken from the option it follows
local last_problem
local function tick()
    state.frames = state.frames + 1
    menu_link(state.frames)
    if P.follow then
        local st = rawget(_G, P.follow)
        local c = type(st) == 'table' and tonumber(st.choice)
        if c and MENU_MULTS[c] and c ~= followed then followed = c; menu_set('mult', c) end
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
        if not image_size then next_check = state.frames + 60; return end
        state.game = string.format('%08X-%X', timestamp, image_size)
        phase, state.status = 'find', 'looking for the vehicle physics'
    end
    if phase == 'find' then
        local how = find_step()
        if how == nil then return end                     -- (still looking: next frame)
        if not how then
            phase, state.status, state.found = 'off', 'off: the vehicle physics was not found in this game version', 'not found'
            log(); return
        end
        state.found = string.format('%s (game.dll+0x%X)', how, G.site)
        -- (3.4.0 review) shared with the other parts on this build (they check the code there instead of searching)
        PLACES[state.game] = {site = G.site, info = G.info, api = G.api, component = G.component}
        phase, state.status = 'run', 'ready'
        log()
    end
    if phase ~= 'run' then return end
    next_check = state.frames + CHECK_EVERY
    local seat = rawget(_G, 'ArmoredOverhaulSeat')
    if type(seat) ~= 'table' then state.status = 'ready (Tank Core not loaded: no tank to change)'; return end
    local vehicle, kind = tonumber(seat.vehicle) or 0, tonumber(seat.kind) or 0
    local name = TANK_KINDS[kind]
    if vehicle == 0 or not name then log_if_changed(); return end
    local ok, done, why = pcall(apply, vehicle, name)
    local problem = not ok and tostring(done) or (not done and name .. ': ' .. tostring(why)) or nil
    -- (Test 20) a problem that stays is counted once, not every look
    if problem and problem ~= last_problem then fail(problem) end
    last_problem = problem
    state.status = problem and ('running; ' .. problem) or 'running'
    log_if_changed()
end

local previous_update = update
if type(previous_update) ~= 'function' then return end
-- (3.4.0 review) an error that repeats every frame is counted, but written to the log only when it changes or every 5 s
local tick_error, tick_error_quiet = nil, 0
update = function(dt, ...)
    local ok, err = pcall(tick)
    if not ok then
        err = tostring(err)
        fail(err)
        tick_error_quiet = tick_error_quiet - (tonumber(dt) or 1 / 60)
        if err ~= tick_error or tick_error_quiet <= 0 then tick_error, tick_error_quiet = err, 5; log() end
    end
    return previous_update(dt, ...)
end
-- (Test 20) the game closing or this Lua being rebuilt puts each tank's own values back where it still holds what this
-- part wrote (the first part to shut down does it; the others then find them changed and leave them). (3.4.0 review)
-- Every value this part changes (engine, wheels, gearbox, lift and the torque factors, not the torque factors alone);
-- the tank found again first (one destroyed since, or its handle reused, is left alone: no call on a stale handle);
-- each tank on its own (one failing doesn't stop the others); the log says what was left.
-- one value: put back when it still holds what this part wanted; nil when done or already its own, else why not
local function put_back(now, want, own, put)
    if want == nil or own == nil or want == own then return nil end
    if now == nil then return 'unreadable' end
    if now == want then put(own); return nil end
    if now ~= own then return 'changed since' end
    return nil
end
local function restore_tank(vehicle, t)
    local h, idx, comp = handle_of(vehicle)
    if not h or h ~= t.h then return 'gone' end
    local left
    -- the torque factors first (game data in the tank's record, no call: only where the record is still this tank's)
    local row = t.at and t.held and t.tilt_own and row_of(comp, idx)
    if row and num(row + ROLL_AT) == num(t.at) and far(t.held, t.tilt_own) then
        local v = read(t.at, 8)
        local a, b = f32(v, 0), f32(v, 4)
        if not (a and b) then left = left or 'unreadable'
        elseif not far({a, b}, t.held) then if writable(t.at, 8) then poke(t.at, t.tilt_own) else left = left or 'not writable' end
        elseif far({a, b}, t.tilt_own) then left = left or 'changed since' end
    end
    if PART == 'speed' or PART == 'torque' then
        left = put_back(get_engine(h), t.want, t.own, function(s) set_engine(h, s) end) or left
    elseif PART == 'grip' and t.want_wheels and t.own_wheels then
        for i, want in ipairs(t.want_wheels) do
            left = put_back(get_wheel(h, i - 1), want, t.own_wheels[i], function(s) set_wheel(h, i - 1, s) end) or left
        end
    elseif PART == 'shift' then
        left = put_back(get_trans(h), t.want_trans, t.own, function(s) set_trans(h, s) end) or left
    elseif PART == 'stability' and t.aero_held and t.aero_own and math.abs(t.aero_held - t.aero_own) > 1e-3 then   -- (Test 29) the lift
        local a = get_aero(h)
        if not is_aero(a) then left = 'unreadable'
        elseif math.abs(a[3] - t.aero_held) < 1e-3 or not t.aero_echo then set_aero(h, t.aero_density, t.aero_drag, t.aero_own)
        elseif math.abs(a[3] - t.aero_own) > 1e-3 then left = 'changed since' end
    end
    return left
end
local previous_shutdown = shutdown
shutdown = function(...)
    local back, left = 0, {}
    if G.api then
        for _, vehicle in ipairs(order) do
            local t = tanks[vehicle]
            if t then
                local ok, why = pcall(restore_tank, vehicle, t)
                if not ok then why = 'error: ' .. tostring(why) end
                if why then left[#left + 1] = string.format('%s 0x%X %s', t.name, vehicle, why) else back = back + 1 end
            end
        end
    end
    state.status = #left == 0 and 'stopped (game closing): the tanks\' own values put back'
        or string.format('stopped (game closing): own values put back on %d tank(s); left as they are: %s', back, table.concat(left, ', '))
    log()
    if type(previous_shutdown) == 'function' then return previous_shutdown(...) end
end

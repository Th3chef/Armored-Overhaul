-- HD2-Addon: mods/chef/armored_overhaul_collision_damage
-- Armored Overhaul 3.6.2 - Tank Collision Damage Boost: the TD-220 Bastion and TD-110 Maelstrom break the walls, fences and
-- buildings they drive into instead of stopping dead against them. Written from scratch. (Named Tank Wall Breaking until
-- 3.5.0 Test 3: the tester named it Tank Collision Damage Boost, since it breaks small buildings too.)
--
-- How the game decides (game.dll, Sept 2026 build; the field meanings from its code, the values from the game's own
-- data): every vehicle has a collision-damage record (VehicleCollisionDamageComponent, 0xD0 bytes, in the settings the
-- game loads at start). When a vehicle hits something, the game builds the hit from that record: among other things
-- its +0x14 and +0x18 go into the hit as the low-speed and full-speed demolition (how strong a thing the hit can break;
-- the speed between the record's own speed limits picks between them). The game's destructibles break by tiers: small
-- arms; grenades, heavy machine guns, cars and mechs; autocannons, Chargers, recoilless rifles and light armored
-- vehicles; Striders and Eagle rockets; orbital bombardment; Hellbombs. Both tanks have 25 and 35 there, the same as
-- the FRV, so a tank breaks what a car breaks and stops dead against a wall.
-- This sets both values, for the two tank hulls only, from how fast the tanks are really going (see CURVE below): up
-- to 40, the tier of autocannons and Chargers (walls, fences and small buildings; the tester's cap), in the loaded
-- settings. The game reads the record at every hit, so tanks already out change at once, and a Mod Options Menu change
-- too. The game's values go back when the game closes or the option is turned off in the menu. Nothing else in the
-- record (the damage the tank takes or deals, its speed limits) is changed.
-- Finding it: the settings accessor for this component (looks a resource id up in the component's slot list and returns
-- its record: stride 0xD0, records after the slots) by its code shape, at its known place on the known build first;
-- the table from its settings-root global; the two hulls by their resource ids; each record checked against the
-- game's own values before anything is written. Writes ArmoredOverhaul-CollisionDamage.log.
-- (Multiplayer: like the game's other hit rules this is most likely decided by the host's game.)
if type(jit) == 'table' and type(jit.off) == 'function' then jit.off(true, true) end
if rawget(_G, 'ArmoredOverhaulCollisionDamage') then return end
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
-- (3.5.0 Test 2, the tester: "lets not add any settings to the wall breaking, it should just be toggleable, and the demo
-- force should be 40 at most") one setting, on or off.
-- (Test 5, the tester: "is there a way to only apply it past a certain speed?") The game blends a hit's demolition
-- between +0x14 and +0x18 by a fraction it works out from the hit (game.dll+0x129D9F5: low * (1 - t) + full * t,
-- rounded), but that fraction is near 1 for any real contact: Test 5 (25 -> 40) broke a 40 wall with a nudge.
-- (Test 6, the tester: "lets have it scale mid range is 30 and 3/4 and up is 40"; "the default is currently 25";
-- "demolition damage should not go higher than 40") So the scaling is done here instead, from how fast each tank is
-- really going: every frame each tank type's demolition is set (both values alike, so the game's own blend changes
-- nothing) from the fastest tank of that type out, along CURVE. Speed: the hull's root node, sideways only (a falling
-- tank isn't fast), the highest of the last PEAK_HOLD seconds (so the hit in the frames the tank stops still counts).
local REF_KMH = 35                             -- the tanks' full speed (the game's own speed range for these hits)
-- (3.5.0 release, the tester: "actually, lets do 30/35/40")
local CURVE = {{0, 30}, {0.5, 35}, {0.75, 40}} -- {fraction of REF_KMH, demolition}; 40 from 3/4 up, never above 40
local CAP = 40
local PEAK_HOLD = 0.25             -- (Test 7, the tester: "it seems to stay on the high demo for a little long before its reduced
                                   -- again": Test 6 held 0.4 s, 3.5.0 0.15 s; 3.5.1 Test 3, the tester: "too short. .25 seconds is fine")
local GAME = {25, 35}                          -- the game's own values for both tanks (Sept 2026 build)
local RING = 128                               -- speed samples kept per tank (PEAK_HOLD at up to ~500 frames a second; 3.5.0: 64)

local S = {version = '3.6.2', status = 'starting', game = 'unchecked', found = 'not yet', how = 'none',
           tanks = 'not yet', writes = 0, reapplied = 0, errors = 0, last_error = 'none',
           options_menu = 'not installed (the mod manager\'s pick)', frames = 0}
rawset(_G, 'ArmoredOverhaulCollisionDamage', S)

local function log()
    pcall(function()
        local f = loader.open_log and loader.open_log('ArmoredOverhaul-CollisionDamage.log')
        if not f then return end
        f:write('Armored Overhaul - Tank Collision Damage Boost\n', 'version: ', S.version, '\n', 'status: ', S.status, '\n',
            'game: ', S.game, '\n', 'found: ', S.found, ' (', S.how, ')\n',
            'tanks: ', S.tanks, '\n', S.speed and ('speed: ' .. S.speed .. '\n') or '', 'followed: ', tostring(S.driving or 'not driving yet'), '\n', 'put back after the game reset them: ', S.reapplied, '\n',
            'options menu: ', S.options_menu, '\n', 'errors: ', S.errors, '\n', 'last error: ', S.last_error, '\n')
        if TESTER then f:write('-- tester details --\n', 'frames: ', S.frames, '\n', 'writes: ', S.writes, '\n', tostring(S.detail or ''), '\n') end
        f:close()
    end)
end

local have_ffi, ffi = pcall(require, 'ffi')
if not have_ffi or not ffi.abi('win') or not ffi.abi('64bit') then S.status = 'off (needs 64-bit Windows LuaJIT)'; log(); return end
for _, decl in ipairs({'void *GetModuleHandleA(const char *);', 'size_t VirtualQuery(const void *, void *, size_t);',
        'int VirtualProtect(void *, size_t, unsigned long, unsigned long *);',
        'unsigned long GetEnvironmentVariableA(const char *, char *, unsigned long);', 'int SetEnvironmentVariableA(const char *, const char *);'}) do pcall(ffi.cdef, decl) end
pcall(ffi.cdef, 'typedef struct { void *base; void *alloc; uint32_t aprot; uint16_t part; uint16_t res; size_t size; uint32_t state; uint32_t prot; uint32_t type; } AOCDRegion;')
local okk, k32 = pcall(ffi.load, 'kernel32')
if not okk then S.status = 'off (kernel32 not available)'; log(); return end
local U8 = ffi.typeof('uint8_t *')
local mbi = ffi.new('AOCDRegion')
local old = ffi.new('unsigned long[1]')

-- readable(p, n): every page of [p, p+n) committed and readable (not guard / no-access)
local function readable(p, n)
    if p == nil then return false end
    local a = tonumber(ffi.cast('uintptr_t', p))
    if a < 0x10000 or a > 0x7FFFFFFFFFFF then return false end
    local e = a + n
    while a < e do
        if k32.VirtualQuery(ffi.cast('void *', a), ffi.cast('void *', mbi), ffi.sizeof(mbi)) == 0 then return false end
        if mbi.state ~= 0x1000 or bit.band(mbi.prot, 0xEE) == 0 or bit.band(mbi.prot, 0x101) ~= 0 then return false end
        a = tonumber(ffi.cast('uintptr_t', mbi.base)) + tonumber(mbi.size)
    end
    return true
end
local function u32(p) return ffi.cast('uint32_t *', p)[0] end
local function s32(p) return ffi.cast('int32_t *', p)[0] end
local function f32(p) return tonumber(ffi.cast('float *', p)[0]) end
local function ptr(p)
    local v = ffi.cast('uint8_t **', p)[0]
    return (v ~= nil and readable(v, 8)) and v or nil
end
-- writes two floats (a record's +0x14 and +0x18), opening a read-only page for the write only
local function write_pair(p, a, b)
    if k32.VirtualQuery(ffi.cast('void *', p), ffi.cast('void *', mbi), ffi.sizeof(mbi)) == 0 then return false end
    if mbi.state ~= 0x1000 or bit.band(mbi.prot, 0x101) ~= 0 then return false end
    local writable = bit.band(mbi.prot, 0xCC) ~= 0
    if not writable and k32.VirtualProtect(ffi.cast('void *', p), 8, 0x04, ffi.cast('void *', old)) == 0 then return false end
    local f = ffi.cast('float *', p)
    f[0], f[1] = a, b
    if not writable then local o2 = ffi.new('unsigned long[1]'); k32.VirtualProtect(ffi.cast('void *', p), 8, old[0], ffi.cast('void *', o2)) end
    S.writes = S.writes + 1
    return true
end

-- ---------------------------------------------------------------- the settings accessor
local function compile(s)
    local b, m = {}, {}
    for t in s:gmatch('%S+') do b[#b + 1] = t == '??' and 0 or tonumber(t, 16); m[#m + 1] = t ~= '??' end
    return {bytes = b, mask = m, n = #b}
end
-- test rcx,rcx / je / mov rax,[rip+ROOT] / mov r8d,ecx / mov r10,[rax+TABLE] / mov rax,MAGIC / mul rcx (the slot
-- count's modulo follows, its shape set by the slot count) ... and, within 0x90 bytes, the record step:
-- mov ecx,[rax+8] / imul rax,rcx,0D0h / add rax,FIRST / add rax,r10 / ret
local HEAD = compile('48 85 C9 74 ?? 48 8B 05 ?? ?? ?? ?? 44 8B C1 4C 8B 90 ?? ?? ?? ?? 48 B8 ?? ?? ?? ?? ?? ?? ?? ?? 48 F7 E1')
local STEP = compile('8B 48 08 48 69 C1 D0 00 00 00 48 05 ?? ?? ?? ?? 49 03 C2 C3')
local STEP_LEAD = '\139\72\8\72\105\193\208\0\0\0\72\5'
local KNOWN = {stamp = 0x6AB3B43F, head = 0x50FD30}
local STRIDE = 0xD0
local function matches(p, pat)
    for i = 1, pat.n do if pat.mask[i] and p[i - 1] ~= pat.bytes[i] then return false end end
    return true
end
local game, image_size, stamp
-- the accessor at rva: {root = the settings-root global, table_at = the table's offset in the root, first = where the
-- records start in the table (after the slots, 16 bytes each)}, or nil
local function accessor_at(rva)
    local p = game + rva
    if rva < 0x1000 or rva > image_size - 0xA0 or not matches(p, HEAD) then return nil end
    for k = 0x23, 0x90 do
        if matches(p + k, STEP) then
            local first = u32(p + k + 12)
            if first < 0x80 or first > 0x10000 or first % 16 ~= 0 then return nil end
            return {root = p + 12 + s32(p + 8), table_at = u32(p + 18), first = first, rva = rva}
        end
    end
end
-- (patched game) one 256 KB piece of game code per frame: the record step's fixed bytes looked for with string.find,
-- then the head looked for up to 0x90 bytes before it
local scan = {at = 0x1000, hits = {}}
local function scan_step()
    local a = scan.at
    if a >= image_size - 0xA0 then return true end
    if k32.VirtualQuery(ffi.cast('void *', game + a), ffi.cast('void *', mbi), ffi.sizeof(mbi)) == 0 then scan.at = a + 0x1000; return false end
    local rb = tonumber(ffi.cast('uintptr_t', mbi.base)) - tonumber(ffi.cast('uintptr_t', game))
    local re = math.min(rb + tonumber(mbi.size), image_size - 0xA0)
    local code = mbi.state == 0x1000 and bit.band(mbi.prot, 0xF0) ~= 0 and bit.band(mbi.prot, 0x101) == 0
    if not code then scan.at = math.max(re, a + 0x1000); return false end
    local n = math.min(0x40000, re - a)
    local chunk = ffi.string(game + a, n + 0x20)
    local from = 1
    while true do
        local hit = chunk:find(STEP_LEAD, from, true)
        if not hit or hit > n then break end
        local step_rva = a + hit - 1
        for back = 0x23, 0x90 do
            local acc = accessor_at(step_rva - back)
            if acc then scan.hits[#scan.hits + 1] = acc; break end
        end
        from = hit + 1
    end
    scan.at = a + n
    return scan.at >= image_size - 0xA0
end

-- ---------------------------------------------------------------- the two tank hulls' records
local HULLS = {{name = 'Bastion', lo = 0x801385B6, hi = 0x16474112}, {name = 'Maelstrom', lo = 0xAF8903F9, hi = 0xB0C9FAF4}}
-- the game's own record values this checks before writing (the rest of the tanks' record: speeds, damage)
local CHECK = {[0x04] = 10, [0x08] = 25, [0x0C] = 20, [0x10] = 2000, [0x1C] = 20, [0x20] = 60, [0x24] = 35, [0x28] = 60}
local held = {}             -- hull name -> {rec, tbl, game = {low, full}, from, now = the value written last, set}
-- (3.5.0 review) The game's own values are also kept in a process environment variable: a copy of this addon loaded
-- again while the game runs (its Lua rebuilt) finds this mod's values in the records, and takes the game's from there.
local ENV_NAME = 'ARMORED_OVERHAUL_COLLISION_GAME'
local kept = nil            -- hull name -> {low, full}, from the variable (read once)
local function env_read()
    kept = {}
    local buf = ffi.new('char[256]')
    local ok, n = pcall(k32.GetEnvironmentVariableA, ENV_NAME, buf, 256)
    if not ok or not n or n == 0 or n >= 256 then return end
    for name, a, b in ffi.string(buf, n):gmatch('(%a+)=([%d%.]+),([%d%.]+)') do kept[name] = {tonumber(a), tonumber(b)} end
end
local function env_save()
    local t = {}
    for name, hd in pairs(held) do t[#t + 1] = string.format('%s=%g,%g', name, hd.game[1], hd.game[2]) end
    table.sort(t)
    pcall(k32.SetEnvironmentVariableA, ENV_NAME, table.concat(t, ';'))
end
local found = nil           -- the accessor
local want_on = true        -- the Mod Options Menu's value (on unless turned off there)
local next_check = 0        -- the frame of the next look at the settings
-- this mod's values: the same at both ends, between the curve's lowest and CAP
local function ours(a, b)
    return math.abs(a - b) < 1e-3 and a >= CURVE[1][2] - 1e-3 and a <= CAP + 1e-3
end
-- demolition for a speed (km/h), along CURVE, at most CAP
local function demolition(kmh)
    local f = kmh / REF_KMH
    if f <= CURVE[1][1] then return CURVE[1][2] end
    for i = 2, #CURVE do
        local a, b = CURVE[i - 1], CURVE[i]
        if f <= b[1] then return math.floor(a[2] + (b[2] - a[2]) * (f - a[1]) / (b[1] - a[1]) + 0.5) end
    end
    return math.min(CAP, CURVE[#CURVE][2])
end
local wanted = {}           -- hull name -> demolition wanted now (from its fastest tank)
local function record_of(tbl, h)
    local slots = found.first / 16
    for i = 0, slots - 1 do
        local e = tbl + 16 * i
        if u32(e) == h.lo and u32(e + 4) == h.hi then
            local idx = u32(e + 8)
            local rec = tbl + found.first + STRIDE * idx
            if idx < slots and readable(rec, STRIDE) then return rec end
            return nil, 'its record index is out of range'
        end
    end
    return nil, 'not in the list'
end
-- the records checked and the wanted values written; returns how many tanks were set and a line for the log
local function apply()
    local root = readable(found.root, 8) and ptr(found.root)
    local tbl = root and readable(root + found.table_at, 8) and ptr(root + found.table_at)
    if not tbl or not readable(tbl, found.first) then return 0, 'the settings are not loaded yet' end
    local parts, n = {}, 0
    for _, h in ipairs(HULLS) do
        local rec, why = record_of(tbl, h)
        local line
        if rec then
            local bad = nil
            for off, v in pairs(CHECK) do if math.abs(f32(rec + off) - v) > 1e-3 then bad = string.format('+0x%X is %g, not %g', off, f32(rec + off), v) end end
            local a, b = f32(rec + 0x14), f32(rec + 0x18)
            local hd = held[h.name]
            if hd and hd.rec ~= rec then
                -- (3.5.0 review) the game loaded its settings again: the game's values there again counted as a reset
                if hd.set and want_on and math.abs(a - hd.game[1]) < 1e-3 and math.abs(b - hd.game[2]) < 1e-3 then S.reapplied = S.reapplied + 1 end
                hd = nil
            end
            if not hd and not bad then
                -- the game's values. (3.5.0 review) Kept by an earlier copy of this addon in this game (see ENV_NAME), else as
                -- read; read values that look like this mod's with nothing kept: the known build's own
                local game, from
                if not kept then env_read() end
                local k = kept[h.name]
                local sane = a >= 0 and b >= a and b <= 100
                if k then game, from = {k[1], k[2]}, 'kept'
                elseif sane and not (ours(a, b) and stamp == KNOWN.stamp) then game, from = {a, b}, 'read'
                elseif sane then game, from = {GAME[1], GAME[2]}, 'known build'
                else bad = string.format('values %g, %g not as expected', a, b) end
                -- (3.5.0 review) a game already giving the tanks 40 or more at full speed is left as it is: never above
                -- the cap, never below the game
                if game and game[2] >= CAP - 1e-3 then bad = string.format('the game\'s own is already %g', game[2]) end
                if game and not bad then hd = {rec = rec, tbl = tbl, game = game, from = from} end
                held[h.name] = hd
                if hd then env_save() end
            end
            if bad then
                line = h.name .. ': left alone (' .. bad .. ')'
            else
                local w = math.min(CAP, math.max(wanted[h.name] or CURVE[1][2], hd.game[1]))   -- (never below the game's low value)
                local ta, tb = w, w
                if not want_on then ta, tb = hd.game[1], hd.game[2] end
                if math.abs(a - ta) > 1e-3 or math.abs(b - tb) > 1e-3 then
                    -- (set before, wanted still, and the game's values there again: the game put them back)
                    local reset = hd.set and want_on and math.abs(a - hd.game[1]) < 1e-3 and math.abs(b - hd.game[2]) < 1e-3
                    if not write_pair(rec + 0x14, ta, tb) then error('write refused for the ' .. h.name) end
                    if reset then S.reapplied = S.reapplied + 1 end
                end
                hd.set = want_on
                hd.now = want_on and w or nil
                n = n + 1
                line = want_on and string.format('%s %d standing, %d at half speed, %d from 3/4 speed (the game\'s %g -> %g, %s)', h.name,
                    CURVE[1][2], CURVE[2][2], CURVE[3][2], hd.game[1], hd.game[2], hd.from)
                    or string.format('%s: the game\'s own %g -> %g', h.name, hd.game[1], hd.game[2])
            end
        else
            line = h.name .. ': ' .. why
        end
        parts[#parts + 1] = line
    end
    return n, table.concat(parts, '; ')
end
local function restore()
    -- ((3.5.1 review) only into the table the values were written to: a table the game loaded again since may be
    -- somewhere else, and its old place reused)
    local root = found and readable(found.root, 8) and ptr(found.root)
    local tbl = root and readable(root + found.table_at, 8) and ptr(root + found.table_at)
    for _, hd in pairs(held) do
        if hd.set and tbl and tbl == hd.tbl and readable(hd.rec + 0x14, 8) and ours(f32(hd.rec + 0x14), f32(hd.rec + 0x18)) then
            pcall(write_pair, hd.rec + 0x14, hd.game[1], hd.game[2])
            hd.set = false
        end
    end
end

-- ---------------------------------------------------------------- Mod Options Menu (3.0)
local menu_rows, menu_set, menu_link = {}, nil, nil
do
    local MENU_ORDER = {'speed', 'power', 'grip', 'steering', 'throttle', 'stability', 'collision', 'maelstrom', 'turret', 'autoloader', 'gunner_drive', 'driver_panel', 'camera', 'run_flat', 'indicator', 'loadout'}
    local hub = rawget(_G, 'ArmoredOverhaulMenu')
    if type(hub) ~= 'table' or type(hub.groups) ~= 'table' then hub = {groups = {}, done = {}}; rawset(_G, 'ArmoredOverhaulMenu', hub) end
    for _, g in ipairs({'collision'}) do
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
        for _, g in ipairs({'collision'}) do if not hub.done[g] then mine = false end end
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
-- one switch, on when installed; off = the game's own
menu_rows.collision = {
    {'armored_overhaul.collision_damage', {type = 'toggle', label = 'Tank Collision Damage Boost', default = true,
        description = 'The faster the Bastion and Maelstrom drive into things, the harder they hit: demolition force 30 when crawling, 35 at half speed, 40 from three-quarter speed (walls, fences, small buildings). Works for the tank you drive; turning it off puts the game\'s own back.'}, 'on'},
}
menu_set = function(key, v)
    if key ~= 'on' then return end
    want_on = v == true or v == 1
    next_check = 0                                 -- (applied at the next frame)
end

-- ---------------------------------------------------------------- (3.5.0 Test 6) how fast each tank is going
local HULL_RES = {Bastion = 'content/fac_helldivers/vehicles/tank/tank', Maelstrom = 'content/fac_helldivers/vehicles/tank_storm/tank_storm'}
local SR, A, W, U, V3 = nil, nil, nil, nil, nil
local speed_api = 'unchecked'
local function speed_api_ok()
    if speed_api == 'ok' then return true end
    if speed_api ~= 'unchecked' then return false end
    SR = rawget(_G, 'stingray')
    A, W, U, V3 = SR and SR.Application, SR and SR.World, SR and SR.Unit, SR and SR.Vector3
    for _, f in ipairs({A and A.main_world, A and A.time_since_launch, W and W.units_by_resource, U and U.world_position,
                        U and U.alive, U and U.node, U and U.has_node, V3 and V3.to_elements}) do
        if type(f) ~= 'function' and type(f) ~= 'userdata' then speed_api = 'missing'; S.speed = 'off: this game build lacks what it needs (tanks keep the crawling value)'; return false end
    end
    speed_api = 'ok'
    return true
end
local tanks = {}            -- unit -> {kind, root, x, y, t, pt/pk = ring of RING (time, km/h) samples, i}
local next_list = 0
local fastest_seen = {}     -- hull name -> highest km/h seen (Tester log)
local out = {}              -- (3.5.0 review) reused each frame: name -> km/h of the fastest
-- each tank's sideways speed this frame (km/h), the highest of the last PEAK_HOLD s; returns name -> km/h of the fastest
-- (3.5.1 Test 15) the tester: "the collision boost should only apply while driving a tank. A tank that isnt being
-- driven doesnt need it running". Tank Core (now part of this option) publishes your seat: only while you drive a
-- Bastion or Maelstrom (the driver's seat, or its gunner seat with Gunner Drive driving) is a tank followed, only that
-- kind, and only your own tank when the Turret indicator / Gunner camera say which it is. Otherwise nothing is looked
-- up or followed and both tanks stay at the crawling value. Without Tank Core's seat (an old copy) every tank, as before.
local KIND_NAME = {[0x2B] = 'Bastion', [0x2C] = 'Maelstrom'}
local drive = {kind = nil, was = nil}
local function driving_kind()
    local seat = rawget(_G, 'ArmoredOverhaulSeat')
    if type(seat) ~= 'table' or seat.live == false then return 'any' end      -- ((3.6.2 review) Tank Core stopped: as without it)
    local name = KIND_NAME[seat.kind]
    if name and (seat.role == 1 or seat.role == 4 or seat.driving == true) then return name end
    return nil
end
local function speeds()
    out.Bastion, out.Maelstrom = nil, nil
    local want = driving_kind()
    if want ~= drive.was then                  -- (started or stopped driving, or another tank: looked up at once)
        drive.was = want; next_list = 0
        for u in pairs(tanks) do tanks[u] = nil end
        S.driving = want == nil and 'not driving: nothing followed' or (want == 'any' and 'every tank (no seat from Tank Core)' or ('driving a ' .. want))
    end
    if not want then return out end
    if not speed_api_ok() then return out end
    local okn, now = pcall(A.time_since_launch)
    if not okn or type(now) ~= 'number' then return out end
    if now >= next_list then                       -- the tanks out, looked for every 2 s
        next_list = now + 2      -- ((3.5.1 Test 14) every 2 s, was 0.5: the tester, "taking up a lot of performance")
        local okw, world = pcall(A.main_world)     -- ((Test 14) only here: 3.5.0-Test 13 asked for it every frame)
        if not okw or not world then return out end
        local seen = {}
        local pub = rawget(_G, 'ArmoredOverhaulTurretAngle')
        local mine = want ~= 'any' and type(pub) == 'table' and KIND_NAME[pub.kind] == want and pub.hull or nil
        for name, res in pairs(HULL_RES) do
            local ok, us = false, nil
            if want == 'any' or want == name then ok, us = pcall(W.units_by_resource, world, res) end
            for _, u in ipairs(ok and type(us) == 'table' and us or {}) do
                if mine == nil or u == mine then seen[u] = true end
                if seen[u] and not tanks[u] then
                    local okh, has = pcall(U.has_node, u, 'root')
                    local okr, root = false, nil
                    if okh and has then okr, root = pcall(U.node, u, 'root') end
                    local e = {kind = name, root = (okr and type(root) == 'number') and root or 1, pt = {}, pk = {}, i = 0}
                    for k = 1, RING do e.pt[k], e.pk[k] = -1e9, 0 end
                    tanks[u] = e
                end
            end
        end
        for u in pairs(tanks) do
            local oka, alive = pcall(U.alive, u)
            if not seen[u] or not (oka and alive) then tanks[u] = nil end
        end
    end
    -- ((3.5.1 Test 14) a tank's 'alive' is asked at the 2 s list; every frame only its place: a unit gone since fails
    -- the read and is dropped. Three engine calls a frame with one tank out, was five)
    for u, e in pairs(tanks) do
        do
            local okp, p = pcall(U.world_position, u, e.root)
            local okx, x, y = false, nil, nil
            if okp then okx, x, y = pcall(V3.to_elements, p) end
            if not okp then tanks[u] = nil
            elseif okx and type(x) == 'number' and type(y) == 'number' then
                if e.t and now > e.t then
                    local kmh = math.sqrt((x - e.x) ^ 2 + (y - e.y) ^ 2) / (now - e.t) * 3.6
                    if kmh < 200 then                                  -- (not a jump: a respawn or a teleport)
                        e.i = e.i % RING + 1
                        e.pt[e.i], e.pk[e.i] = now, kmh
                        if TESTER and kmh > (fastest_seen[e.kind] or 0) then fastest_seen[e.kind] = kmh end
                    end
                end
                e.x, e.y, e.t = x, y, now
                local top, since = 0, now - PEAK_HOLD
                local pt, pk = e.pt, e.pk
                -- (3.5.1 review) newest first, stopping at the first sample older than the hold: the samples are in time order
                -- round the ring (about 15 a frame at 60 fps; 3.5.0 looked at all of them every frame)
                local k = e.i
                for _ = 1, RING do
                    if k < 1 or pt[k] < since then break end
                    if pk[k] > top then top = pk[k] end
                    k = k > 1 and k - 1 or RING
                end
                out[e.kind] = math.max(out[e.kind] or 0, top)
            end
        end
    end
    return out
end
-- the table the records are in, as the game has it now (nil if it moved or isn't there)
local function table_now()
    local root = readable(found.root, 8) and ptr(found.root)
    return root and readable(root + found.table_at, 8) and ptr(root + found.table_at)
end
-- (3.5.1 Test 14) the tester: "tank collision damage boost is taking up a lot of performance". Test 13 asked Windows
-- (VirtualQuery) about 45 times a second just to see the table hadn't moved (every 6 frames, and before writes). The
-- settings-root global is in game.dll's own data, always there, so it is read directly; the root object it points to
-- is checked once each time that pointer changes, and its table pointer is then read directly too. Only compared with
-- the table this addon wrote to (apply checked that one), never read through unless it is that one.
local fast = {root = nil, ok = false}
local function table_fast()
    local g = tonumber(ffi.cast('uintptr_t', found.root)) - tonumber(ffi.cast('uintptr_t', game))
    if g < 0x1000 or g + 8 > image_size then return table_now() end          -- (not in game.dll's image: the slow way)
    local root = ffi.cast('uint8_t **', found.root)[0]
    if root == nil then fast.root = nil; return nil end
    if root ~= fast.root then fast.root, fast.ok = root, readable(root + found.table_at, 8) end
    if not fast.ok then return nil end
    local t = ffi.cast('uint8_t **', root + found.table_at)[0]
    return t ~= nil and t or nil
end
local refused = 0
-- every frame: each tank type's demolition from its fastest tank, written when it changes. (3.5.0 review) Before a
-- write the table is checked to be where it was (a reloaded table goes to apply at once, nothing written to the old
-- one); twice a second the values are checked to be still this mod's (the game putting its own back is caught).
local function follow_speed()
    local v = speeds()
    local verify = S.frames % 30 == 0
    -- (3.5.1 Test 3) the game's settings loaded again into a new table: looked for every 6 frames (3.5.0 noticed it only at
    -- the next change of value, which the longer hold now delays, or the half-second check)
    if S.frames % 6 == 0 then
        local hd0 = held[HULLS[1].name] or held[HULLS[2].name]
        if hd0 and hd0.tbl and table_fast() ~= hd0.tbl then next_check = 0 end
    end
    for _, h in ipairs(HULLS) do
        local d = demolition(v[h.name] or 0)
        wanted[h.name] = d
        local hd = held[h.name]
        if hd and want_on and refused < 5 then
            local w = math.min(CAP, math.max(d, hd.game[1]))
            if verify and hd.now and table_fast() == hd.tbl and math.abs(f32(hd.rec + 0x14) - hd.now) > 1e-3 then
                hd.now = nil; next_check = 0                         -- (apply looks at it this frame)
            elseif hd.now ~= w then
                if table_fast() ~= hd.tbl then next_check = 0
                else
                    local a, b = f32(hd.rec + 0x14), f32(hd.rec + 0x18)
                    if ours(a, b) or (math.abs(a - hd.game[1]) < 1e-3 and math.abs(b - hd.game[2]) < 1e-3) then
                        if write_pair(hd.rec + 0x14, w, w) then hd.now = w; hd.set = true
                        else
                            refused = refused + 1; S.errors = S.errors + 1; S.last_error = 'write refused for the ' .. h.name
                            if refused >= 5 then S.speed = 'stopped: the game refused the writes'; log() end
                        end
                        if TESTER then S.speed_writes = (S.speed_writes or 0) + 1 end
                    end
                end
            end
        end
    end
    if TESTER then S.detail = string.format('fastest seen: Bastion %.1f km/h, Maelstrom %.1f km/h; speed writes %d', fastest_seen.Bastion or 0, fastest_seen.Maelstrom or 0, S.speed_writes or 0) end
end

local phase, shown = 'gate', nil
-- (3.6.2 Test 4, the tester: "Im also seeing Tank collision boost running in the background while im not even in a game.
-- It shouldnt even really run unless a tank is being driven") With Tank Core's seat (part of this option), nothing runs
-- until you drive a Bastion or Maelstrom: no look-up of the game's code, no settings checks, no speed. The values go in
-- as you start driving (the game reads them at every hit) and the game's own go back as you stop. Without the seat (an
-- old Tank Core) every tank, as before.
local idle = {on = false}
local function tick()
    S.frames = S.frames + 1
    menu_link(S.frames)
    if driving_kind() == nil then
        if not idle.on then
            idle.on = true
            pcall(restore)
            for _, hd in pairs(held) do hd.now = nil end
            drive.was = nil
            for u in pairs(tanks) do tanks[u] = nil end
            S.driving = 'not driving: nothing followed'
            if phase ~= 'off' then S.status = 'idle: the game\'s own values until you drive a Bastion or Maelstrom' end
            log()
        end
        return
    end
    if idle.on then idle.on = false; next_check = 0 end
    if phase == 'run' and want_on and next(held) then follow_speed() end
    if S.frames < next_check then return end
    if phase == 'gate' then
        local m = k32.GetModuleHandleA('game.dll')
        if m == nil then next_check = S.frames + 60; return end
        game = ffi.cast(U8, m)
        local pe = u32(game + 0x3C)
        image_size, stamp = u32(game + pe + 0x50), u32(game + pe + 8)
        S.game = string.format('%08X-%X', stamp, image_size)
        phase = 'scan'
        if stamp == KNOWN.stamp then
            found = accessor_at(KNOWN.head)
            if found then S.how = 'known build'; phase = 'run' end
        end
        if phase == 'scan' then S.how = 'searching game code'; S.status = 'searching game code' end
    end
    if phase == 'scan' then
        if not scan_step() then return end
        phase, scan.tries = 'choose', 0
    end
    -- ((3.5.1 review) the candidates are kept and looked at again every 2 s while the vehicle settings aren't loaded yet:
    -- before, with more than one candidate, the option turned itself off for the session when the search ended first)
    if phase == 'choose' then
        -- the one whose table lists both tank hulls (another component with the same record size would not)
        for _, acc in ipairs(scan.hits) do
            found = acc
            local root = readable(acc.root, 8) and ptr(acc.root)
            local tbl = root and readable(root + acc.table_at, 8) and ptr(root + acc.table_at)
            if tbl and readable(tbl, acc.first) and record_of(tbl, HULLS[1]) and record_of(tbl, HULLS[2]) then break end
            found = nil
        end
        if not found and #scan.hits == 1 then found = scan.hits[1] end      -- (settings not loaded yet: checked below)
        if not found and #scan.hits > 1 and scan.tries < 150 then          -- (up to 5 minutes)
            scan.tries = scan.tries + 1; next_check = S.frames + 120
            local text = string.format('waiting for the vehicle settings to tell %d candidates apart', #scan.hits)
            if S.status ~= text then S.status = text; log() end
            return
        end
        if not found then
            S.status = string.format('off: this game build\'s vehicle collision settings not recognized (%d candidate(s))', #scan.hits)
            phase = 'off'; log(); return
        end
        S.how = 'found by search'; phase = 'run'
    end
    if phase == 'run' then
        S.found = string.format('settings accessor game.dll+0x%X (table at root+0x%X, records from +0x%X)', found.rva, found.table_at, found.first)
        next_check = S.frames + 300                -- every ~5 s: settings the game loaded again get it again
        local n, line = apply()
        S.tanks = line
        S.status = n == 0 and 'waiting for the vehicle settings' or (want_on and 'on' or 'off (Mod Options Menu): the game\'s own')
        if n == 0 then next_check = S.frames + 120 end
        local text = S.status .. S.tanks .. S.reapplied .. S.options_menu .. tostring(S.driving)
        if text ~= shown then shown = text; log() end
    end
end

local previous_update = update
if type(previous_update) ~= 'function' then return end
local broken = false
local function after(ok, ...)
    if not ok then error((...), 0) end
    if not broken then
        local okT, err = pcall(tick)
        if not okT then
            broken = true; S.errors = S.errors + 1; S.last_error = tostring(err); S.status = 'stopped after an error'
            pcall(restore); log()
        end
    end
    return ...
end
update = function(...) return after(pcall(previous_update, ...)) end
do
    local previous_shutdown = shutdown
    shutdown = function(...)
        pcall(restore)                             -- the game's own values back as the game closes
        if type(previous_shutdown) == 'function' then return previous_shutdown(...) end
    end
end
log()

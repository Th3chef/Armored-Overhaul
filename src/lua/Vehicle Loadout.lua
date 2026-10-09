-- HD2-Addon: mods/chef/armored_overhaul_vehicle_loadout
-- Armored Overhaul 3.4.0 - Vehicle Loadout option: lets you pick more than one tank, exosuit or FRV in your stratagem
-- loadout. Written from scratch.
--
-- How the game limits it (game.dll, Sept 2026 build): each stratagem has a data record (the stratagem list,
-- game.dll+0x37CB600: one pointer per stratagem type; its 32-bit flags at +0x104). Three of those flags (bits 20, 21 and
-- 22 on that build) make "pick only one" groups: when you pick a stratagem with one of them, the loadout screen looks
-- for a slot already holding a stratagem with the same flag and puts the new pick there instead (small helpers at
-- game.dll+0x189DCF0, one per flag, find that slot). Tanks, exosuits and FRVs carry those flags.
-- This addon clears those group flags on the vehicle stratagems only (types named Dropoff + Tank / CombatWalker / Frv),
-- so the loadout screen no longer swaps them out, and puts them back when the option is turned off in the Mod Options
-- Menu or the game closes. Nothing else reads those flags (only those helpers and the loadout screen's own copy of
-- the check), so stratagem uses, cooldowns and calling them in are the game's own.
-- Finding things: the helpers (their code gives the list's place and each flag's bit) and the stratagem names
-- (the loadout debug printer at game.dll+0x135D398 reads the name table) by code pattern, on the known build at
-- their known places first. Writes ArmoredOverhaul-VehicleLoadout.log.
if type(jit) == 'table' and type(jit.off) == 'function' then jit.off(true, true) end
if rawget(_G, 'ArmoredOverhaulVehicleLoadout') then return end
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

local S = {version = '3.4.0', status = 'starting', game = 'unchecked', found = 'not yet', how = 'none',
           vehicles = 'none yet', groups = 'none yet', changed = 0, errors = 0, last_error = 'none',
           options_menu = 'not installed (on)', frames = 0}
rawset(_G, 'ArmoredOverhaulVehicleLoadout', S)

local function log()
    pcall(function()
        local f = loader.open_log and loader.open_log('ArmoredOverhaul-VehicleLoadout.log')
        if not f then return end
        f:write('Armored Overhaul - Vehicle Loadout (more than one tank, exosuit or FRV)\n',
            'version: ', S.version, '\n', 'status: ', S.status, '\n', 'game: ', S.game, '\n', 'found: ', S.found, ' (', S.how, ')\n',
            'vehicle stratagems: ', S.vehicles, '\n', '"pick only one" groups on them: ', S.groups, '\n',
            'options menu: ', S.options_menu, '\n', 'errors: ', S.errors, '\n', 'last error: ', S.last_error, '\n')
        if TESTER then f:write('-- tester details --\n', 'frames: ', S.frames, '\n', 'flag writes: ', S.changed, '\n', tostring(S.detail or ''), '\n') end
        f:close()
    end)
end

local have_ffi, ffi = pcall(require, 'ffi')
if not have_ffi or not ffi.abi('win') or not ffi.abi('64bit') then S.status = 'off (needs 64-bit Windows LuaJIT)'; log(); return end
for _, decl in ipairs({'void *GetModuleHandleA(const char *);', 'size_t VirtualQuery(const void *, void *, size_t);',
        'int VirtualProtect(void *, size_t, unsigned long, unsigned long *);',
        'unsigned long GetEnvironmentVariableA(const char *, char *, unsigned long);', 'int SetEnvironmentVariableA(const char *, const char *);'}) do pcall(ffi.cdef, decl) end
pcall(ffi.cdef, 'typedef struct { void *base; void *alloc; uint32_t aprot; uint16_t part; uint16_t res; size_t size; uint32_t state; uint32_t prot; uint32_t type; } AOVLRegion;')
local okk, k32 = pcall(ffi.load, 'kernel32')
if not okk then S.status = 'off (kernel32 not available)'; log(); return end
local U8 = ffi.typeof('uint8_t *')
local mbi = ffi.new('AOVLRegion')
local old = ffi.new('unsigned long[1]')

-- readable(p, n): every page of [p, p+n) committed and readable (not guard / no-access)
local function readable(p, n)
    if p == nil then return false end
    local a = tonumber(ffi.cast('uintptr_t', p))
    if a < 0x10000 or a > 0x7FFFFFFFFFFF then return false end
    local e = a + n
    while a < e do
        if k32.VirtualQuery(ffi.cast('void *', a), mbi, ffi.sizeof(mbi)) == 0 then return false end
        if mbi.state ~= 0x1000 or bit.band(mbi.prot, 0xEE) == 0 or bit.band(mbi.prot, 0x101) ~= 0 then return false end
        a = tonumber(ffi.cast('uintptr_t', mbi.base)) + tonumber(mbi.size)
    end
    return true
end
local function u32(p) return ffi.cast('uint32_t *', p)[0] end
local function s32(p) return ffi.cast('int32_t *', p)[0] end
-- write a 32-bit value, opening a read-only page for the write only
local function write32(p, v)
    if k32.VirtualQuery(p, mbi, ffi.sizeof(mbi)) == 0 then return false end
    local writable = bit.band(mbi.prot, 0xCC) ~= 0
    if not writable and k32.VirtualProtect(p, 4, 0x04, old) == 0 then return false end
    ffi.cast('uint32_t *', p)[0] = v
    if not writable then local o2 = ffi.new('unsigned long[1]'); k32.VirtualProtect(p, 4, old[0], o2) end
    S.changed = S.changed + 1
    return true
end

-- code patterns ('??' = any byte)
local function compile(s)
    local b, m = {}, {}
    for t in s:gmatch('%S+') do b[#b + 1] = t == '??' and 0 or tonumber(t, 16); m[#m + 1] = t ~= '??' end
    return {bytes = b, mask = m, n = #b}
end
local HELPER = compile('33 D2 4C 8D 05 ?? ?? ?? ?? 48 81 C1 ?? ?? ?? ?? 4C 8D 0D ?? ?? ?? ?? 8B 01 85 C0 75 05 49 8B C0 EB 04 49 8B 04 C1 F7 80 04 01 00 00')
local NAMES = compile('8B 16 4C 8B 40 10 49 8B 94 D5 ?? ?? ?? ?? 41 FF 90 70 04 00 00')
local KNOWN = {stamp = 0x6AB3B43F, helpers = {0x189DCF0, 0x189DD40, 0x189DD90}, names = 0x135D398}
local function matches(p, pat)
    for i = 1, pat.n do if pat.mask[i] and p[i - 1] ~= pat.bytes[i] then return false end end
    return true
end

local game, image_size, stamp
local found = nil           -- {registry = ptr, masks = {bits}, names = ptr}
local scan = {at = 0x1000, helpers = {}, names = nil, names_list = {}}
local function from_helpers(list, names_at)
    local masks, reg = {}, nil
    for _, h in ipairs(list) do
        local p = game + h
        local r = p + 0x17 + s32(p + 0x13)           -- lea r9, [rip + disp]: the stratagem list
        if reg and r ~= reg then return nil, 'helpers disagree about the stratagem list' end
        reg = r
        masks[#masks + 1] = u32(p + 0x2C)            -- test dword ptr [rax + 0x104], mask
    end
    local names = game + u32(game + names_at + 10)   -- mov rdx, [r13 + rdx*8 + table] (r13 = game.dll)
    return {registry = reg, masks = masks, names = names}
end
-- (patched game) one 256 KB piece of game code per frame: each pattern's fixed first bytes are looked for with
-- string.find, the rest checked in place
local ANCHORS = {{pat = HELPER, lead = '\51\210\76\141\5', many = 3}, {pat = NAMES, lead = '\139\22\76\139\64\16\73\139\148\213', many = 1}}
local function scan_step()
    local a = scan.at
    if a >= image_size - 0x40 then return true end
    if k32.VirtualQuery(game + a, mbi, ffi.sizeof(mbi)) == 0 then scan.at = a + 0x1000; return false end
    local rb = tonumber(ffi.cast('uintptr_t', mbi.base)) - tonumber(ffi.cast('uintptr_t', game))
    local re = math.min(rb + tonumber(mbi.size), image_size - 0x40)
    local code = mbi.state == 0x1000 and bit.band(mbi.prot, 0xF0) ~= 0 and bit.band(mbi.prot, 0x101) == 0
    if not code then scan.at = math.max(re, a + 0x1000); return false end
    local n = math.min(0x40000, re - a)
    local chunk = ffi.string(game + a, n + 0x40)
    for i, an in ipairs(ANCHORS) do
        local list = i == 1 and scan.helpers or scan.names_list
        local from = 1
        while #list < an.many do
            local hit = chunk:find(an.lead, from, true)
            if not hit or hit > n then break end
            if matches(game + a + hit - 1, an.pat) then list[#list + 1] = a + hit - 1 end
            from = hit + 1
        end
    end
    scan.at = a + n
    scan.names = scan.names_list[1]
    return scan.at >= image_size - 0x40 or (#scan.helpers >= 3 and scan.names ~= nil)
end

-- the stratagem name table: type -> name (read once). (3.3.0 review) A name in an unexpected form is skipped, not
-- the end of the list (a game update adding one would have hidden every vehicle after it); 8 in a row end it.
local NAME_MAX = 400
local names = {}
local vtypes = {}           -- (3.3.0 review) the vehicle stratagems' types, listed once (apply looked at all ~150)
-- a vehicle stratagem's kind: each kind is one of the game's "pick only one" groups
local function kind_of(nm)
    if nm == nil or not nm:find('^Dropoff') then return nil end
    if nm:find('CombatWalker', 1, true) then return 'CombatWalker' end
    if nm:find('Tank', 1, true) then return 'Tank' end
    if nm:find('Frv', 1, true) then return 'Frv' end
end
local function read_names()
    local bad = 0
    for i = 0, NAME_MAX - 1 do
        local pp = found.names + 8 * i
        if not readable(pp, 8) then break end
        local sp = ffi.cast('const char **', pp)[0]
        local nm
        if readable(sp, 1) then
            local ok, v = pcall(ffi.string, sp)
            if ok and #v > 0 and #v <= 80 and not v:find('[^%w_]') then nm = v end
        end
        if nm then names[i], bad = nm, 0 else bad = bad + 1; if bad >= 8 then break end end
    end
    vtypes = {}
    for t = 1, NAME_MAX - 1 do if kind_of(names[t]) then vtypes[#vtypes + 1] = t end end
end

-- per vehicle stratagem: its record and the group flags the game gave it (put back when turned off)
local held = {}             -- type -> {entry = ptr, groups = bits}
local want_on = true        -- the Mod Options Menu's value (on unless turned off there)
-- (3.3.0 review) The game's group flags are also kept in a process environment variable: a copy of this addon loaded
-- again while the game runs (its Lua rebuilt) finds them already cleared by the earlier copy, and could not put the
-- limit back. It takes them from there; failing that from another vehicle of the same kind that still has them, or the
-- known build's (tanks bit 22, exosuits bit 20, FRVs bit 21 on the Sept 2026 build).
local ENV_NAME = 'ARMORED_OVERHAUL_VEHICLE_GROUPS'
local KNOWN_KIND = {Tank = 0x400000, CombatWalker = 0x100000, Frv = 0x200000}
local kept = nil            -- type -> bits, from the variable (read once)
local function env_read()
    kept = {}
    local buf = ffi.new('char[512]')
    local ok, n = pcall(k32.GetEnvironmentVariableA, ENV_NAME, buf, 512)
    if not ok or not n or n == 0 or n >= 512 then return end
    for t, b in ffi.string(buf, n):gmatch('(%d+):(%x+)') do kept[tonumber(t)] = tonumber(b, 16) end
end
local saved = nil
local function env_save()
    local t = {}
    for ty, h in pairs(held) do if h.groups ~= 0 then t[#t + 1] = ty .. ':' .. bit.tohex(h.groups, 8) end end
    table.sort(t)
    local v = table.concat(t, ',')
    if v ~= saved and #v < 500 then saved = v; pcall(k32.SetEnvironmentVariableA, ENV_NAME, v) end
end
local function apply()
    local all = 0
    for _, m in ipairs(found.masks) do all = bit.bor(all, m) end
    if not kept then env_read() end
    -- the records, and each kind's group as the game still has it on any of its vehicles
    local rec, by_kind = {}, {}
    for _, t in ipairs(vtypes) do
        local pp = found.registry + 8 * t
        local e = readable(pp, 8) and ffi.cast('uint8_t **', pp)[0] or nil
        if e ~= nil and readable(e + 0x104, 4) and u32(e) == t then
            rec[t] = e
            local h = held[t]
            local g = (h and h.entry == e) and h.groups or bit.band(u32(e + 0x104), all)
            if g ~= 0 then by_kind[kind_of(names[t])] = g end
        end
    end
    local list, groups = {}, {}
    for _, t in ipairs(vtypes) do
        local nm, e = names[t], rec[t]
        if e then
            local h = held[t]
            if not h or h.entry ~= e then
                local g, from = bit.band(u32(e + 0x104), all), 'game'
                if g == 0 then          -- already cleared: an earlier copy of this addon (see above)
                    local kd = kind_of(nm)
                    local kb = KNOWN_KIND[kd]
                    if kept[t] and bit.band(kept[t], all) == kept[t] then g, from = kept[t], 'kept'
                    elseif by_kind[kd] then g, from = by_kind[kd], 'same kind'
                    elseif stamp == KNOWN.stamp and bit.band(kb, all) == kb then g, from = kb, 'known build'
                    else from = 'unknown' end
                end
                h = {entry = e, groups = g, from = from}
                held[t] = h
            end
            local now = u32(e + 0x104)
            local target = want_on and bit.band(now, bit.bnot(all)) or bit.bor(now, h.groups)
            if target ~= now and not write32(e + 0x104, target) then error('write refused for ' .. nm) end
            list[#list + 1] = nm
            if h.groups ~= 0 then groups[#groups + 1] = string.format('%s %s%s', nm, bit.tohex(h.groups, 8), h.from ~= 'game' and (' (' .. h.from .. ')') or '') end
        end
    end
    env_save()
    S.vehicles = #list > 0 and (#list .. ' (' .. table.concat(list, ', ') .. ')') or 'none found'
    S.groups = #groups > 0 and table.concat(groups, ', ') or 'none (already cleared, or the game has no limit)'
    return #list
end
local function restore()
    for _, h in pairs(held) do
        if readable(h.entry + 0x104, 4) then
            local now = u32(h.entry + 0x104)
            if bit.bor(now, h.groups) ~= now then pcall(write32, h.entry + 0x104, bit.bor(now, h.groups)) end
        end
    end
end

-- ---------------------------------------------------------------- Mod Options Menu (3.0)
local menu_rows, menu_set, menu_link = {}, nil, nil
do
    local MENU_ORDER = {'speed', 'power', 'grip', 'steering', 'throttle', 'stability', 'turret', 'autoloader', 'gunner_drive', 'driver_panel', 'camera', 'indicator', 'loadout'}
    local hub = rawget(_G, 'ArmoredOverhaulMenu')
    if type(hub) ~= 'table' or type(hub.groups) ~= 'table' then hub = {groups = {}, done = {}}; rawset(_G, 'ArmoredOverhaulMenu', hub) end
    for _, g in ipairs({'loadout'}) do
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
        for _, g in ipairs({'loadout'}) do if not hub.done[g] then mine = false end end
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
menu_rows.loadout = {
    {'armored_overhaul.vehicle_loadout', {type = 'toggle', label = 'Vehicle Loadout', default = true,
        description = 'Pick more than one tank, exosuit or FRV in your stratagem loadout (the game puts a second one in the first one\'s slot). Changes at once; turning it off puts the game\'s limit back.'}, 'on'},
}
local next_check = 0
menu_set = function(key, v)
    if key ~= 'on' then return end
    want_on = v == true or v == 1
    next_check = 0                                 -- (applied at the next frame)
end

-- ---------------------------------------------------------------- frame
local phase, shown = 'gate', nil
local function tick()
    S.frames = S.frames + 1
    menu_link(S.frames)
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
            local ok = true
            for _, h in ipairs(KNOWN.helpers) do if not matches(game + h, HELPER) then ok = false end end
            if ok and matches(game + KNOWN.names, NAMES) then
                found = from_helpers(KNOWN.helpers, KNOWN.names); S.how = 'known build'; phase = 'names'
            end
        end
        if phase == 'scan' then S.how = 'searching game code'; S.status = 'searching game code' end
    end
    if phase == 'scan' then
        if not scan_step() then return end
        if #scan.helpers < 3 or not scan.names then
            S.status = string.format('off: this game build\'s loadout check not recognized (%d of 3 helpers, names %s)', #scan.helpers, scan.names and 'found' or 'not found')
            phase = 'off'; log(); return
        end
        local why; found, why = from_helpers(scan.helpers, scan.names)
        if not found then S.status = 'off: ' .. why; phase = 'off'; log(); return end
        S.how = 'found by search'; phase = 'names'
    end
    if phase == 'names' then
        S.found = string.format('stratagem list game.dll+0x%X, groups %s', tonumber(ffi.cast('uintptr_t', found.registry)) - tonumber(ffi.cast('uintptr_t', game)),
            table.concat((function() local t = {} for i, m in ipairs(found.masks) do t[i] = bit.tohex(m, 8) end return t end)(), ' '))
        read_names()
        if not next(names) then S.status = 'waiting for the stratagem names'; next_check = S.frames + 120; return end
        phase = 'run'
    end
    if phase == 'run' then
        next_check = S.frames + 600                -- every ~10 s: a record the game rebuilt gets it again
        local n = apply()
        S.status = n == 0 and 'waiting for the stratagem list' or (want_on and 'on: more than one vehicle can be picked' or 'off (Mod Options Menu): the game\'s limit')
        if n == 0 then next_check = S.frames + 120 end
        if S.status ~= shown then shown = S.status; log() end
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
        pcall(restore)                             -- the game's own flags back as the game closes
        if type(previous_shutdown) == 'function' then return previous_shutdown(...) end
    end
end
log()

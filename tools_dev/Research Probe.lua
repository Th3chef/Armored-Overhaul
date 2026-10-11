-- HD2-Addon: mods/chef/armored_overhaul_research_probe
if not rawget(_G, 'ArmoredOverhaulTestLog') then rawset(_G, 'ArmoredOverhaulTestLog', function(name)   -- (test build: logs in Logs\test)
    local dir = rawget(_G, 'ArmoredOverhaulLogsDir')
    local root = dir and dir()                       -- (3.3.0) the loader's log folder (v19), else LOCALAPPDATA's
    if root and root ~= '' and type(package) == 'table' and type(package.config) == 'string' and package.config:sub(1, 1) == '\\' then
        local f = io.open(root .. '\\test\\' .. name, 'w')
        if f then return f end
    end
    local L = rawget(_G, 'CowboyBingusModLoader')
    return type(L) == 'table' and L.open_log and L.open_log(name)
end) end
-- Armored Overhaul TEST BUILDS ONLY (never in a release): read-only research for the solo-only build and Exosuits.
-- Lists the engine's Lua API by name (global tables and their function names; nothing is called except the World
-- unit look-ups below, each in a pcall) and counts units for a few candidate helldiver unit names, so we can tell how
-- many players are in the mission. Writes ArmoredOverhaul-Probe.log once at start and again in each mission world.
-- (Test 8) Also logs the stratagem registry once (see registry below).
local loader = rawget(_G, 'CowboyBingusModLoader')
if type(loader) ~= 'table' or rawget(_G, 'ArmoredOverhaulProbe') then return end
rawset(_G, 'ArmoredOverhaulProbe', true)
local KEYS = {'lobby', 'members', 'network', 'peer', 'player', 'session', 'steam', 'party', 'squad', 'mission', 'profile', 'account',
              'friend', 'presence', 'match', 'host', 'client', 'game'}
local CANDIDATES = {'content/fac_helldivers/cha_helldiver/helldiver', 'content/fac_helldivers/helldiver/helldiver',
                    'content/fac_helldivers/characters/helldiver/helldiver', 'content/fac_helldivers/cha_helldiver/cha_helldiver',
                    'content/fac_helldivers/vehicles/combat_walker/combat_walker'}
local out = {}
local function add(s) out[#out + 1] = s end
local function api()
    local names = {}
    for k, v in pairs(_G) do if type(k) == 'string' and (type(v) == 'table' or type(v) == 'userdata') then names[#names + 1] = k end end
    table.sort(names)
    add('global tables (' .. #names .. '): ' .. table.concat(names, ' '))
    for _, k in ipairs(names) do
        local lk, hit = k:lower(), false
        for _, w in ipairs(KEYS) do if lk:find(w, 1, true) then hit = true end end
        if hit then
            local fns = {}
            local ok = pcall(function() for f, v in pairs(_G[k]) do if type(f) == 'string' then fns[#fns + 1] = f .. (type(v) == 'function' and '()' or '') end end end)
            table.sort(fns)
            add(k .. ': ' .. (ok and table.concat(fns, ' ') or 'not listable'))
        end
    end
end
local function units(tag)
    local SR = rawget(_G, 'stingray')               -- (Test 5) the engine API lives under stingray (Test 4: no checks ran)
    local A, W = SR and SR.Application, SR and SR.World
    if type(A) ~= 'table' or type(W) ~= 'table' or not A.main_world then return add(tag .. ': no main world API') end
    local okw, world = pcall(A.main_world)
    if not okw or world == nil then return add(tag .. ': no main world') end
    local okn, all = pcall(W.units, world)
    add(string.format('%s: %s units in the main world', tag, okn and type(all) == 'table' and tostring(#all) or '?'))
    for _, c in ipairs(CANDIDATES) do
        local ok, list = pcall(W.units_by_resource, world, c)
        add(string.format('  %s: %s', c, ok and type(list) == 'table' and tostring(#list) or ('error ' .. tostring(list))))
    end
end
local function write()
    pcall(function()
        local f = rawget(_G, 'ArmoredOverhaulTestLog')('ArmoredOverhaul-Probe.log')
        if not f then return end
        f:write('Armored Overhaul - research probe (test builds only, read only)\n', table.concat(out, '\n'), '\n'); f:close()
    end)
end
-- (Test 5) the first write waits a second: at load the other addons haven't set up the logs-folder helper yet (Test 4's
-- probe log landed in the main Logs folder)
local function fields(name, t, texts)
    local ks = {}
    pcall(function() for k, v in pairs(t) do ks[#ks + 1] = tostring(k) .. '=' .. ((type(v) == 'number' or type(v) == 'boolean' or (texts and type(v) == 'string')) and tostring(v) or type(v)) end end)   -- (no text values: no player names)
    table.sort(ks); add(name .. ': ' .. table.concat(ks, ' '))
end
local function startup()
    api()
    fields('loader', loader, true)            -- (the loader's own texts: its revision name)
    -- tables some other mod keeps about the lobby (names and kinds only; read only)
    for k, v in pairs(_G) do
        if type(k) == 'string' and type(v) == 'table' then
            for _, sub in ipairs({'lobby', 'members', 'peers', 'players'}) do
                local okv, t = pcall(function() return v[sub] end)
                if okv and type(t) == 'table' then fields(k .. '.' .. sub, t) end
            end
        end
    end
end
-- (Test 8) the stratagem registry, for the "more than one vehicle in the loadout" research: game.dll+0x37CB600 is an
-- array of pointers (index = a loadout slot's stratagem number); each entry starts with the stratagem's type (enum names
-- at game.dll+0x21D4AA0). Every entry's first 0x140 bytes are logged once, as hex, with its type name, so the field that
-- marks tanks and exosuits as one "vehicle" group can be found. Read only: each page is checked readable first.
local function registry()
    local okf, ffi = pcall(require, 'ffi')
    if not okf then return add('registry: no ffi') end
    for _, decl in ipairs({'void *GetModuleHandleA(const char *);', 'size_t VirtualQuery(const void *, void *, size_t);'}) do pcall(ffi.cdef, decl) end
    pcall(ffi.cdef, 'typedef struct { void *base; void *alloc; uint32_t aprot; uint32_t pad0; size_t size; uint32_t state; uint32_t prot; uint32_t type; uint32_t pad1; } ProbeRegion;')
    local k32 = ffi.load('kernel32')
    local game = ffi.cast('uint8_t *', k32.GetModuleHandleA('game.dll'))
    if game == nil then return add('registry: no game.dll') end
    local mbi = ffi.new('ProbeRegion')
    local function readable(p, n)
        if p == nil then return false end
        local a = ffi.cast('uintptr_t', p)
        if a < 0x10000 or a > 0x7FFFFFFFFFFF then return false end
        local e = a + n
        while a < e do
            if k32.VirtualQuery(ffi.cast('void *', a), mbi, ffi.sizeof(mbi)) == 0 then return false end
            if mbi.state ~= 0x1000 or bit.band(mbi.prot, 0xEE) == 0 or bit.band(mbi.prot, 0x101) ~= 0 then return false end
            a = ffi.cast('uintptr_t', mbi.base) + mbi.size
        end
        return true
    end
    local names = {}
    for i = 0, 400 do
        local pp = game + 0x21D4AA0 + 8 * i
        if not readable(pp, 8) then break end
        local sp = ffi.cast('const char **', pp)[0]
        if not readable(sp, 1) then break end
        local okn, nm = pcall(ffi.string, sp)
        if not okn or #nm == 0 or #nm > 80 then break end
        names[i] = nm
    end
    local tab = game + 0x37CB600
    local n = 0
    for i = 0, 1023 do
        if not readable(tab + 8 * i, 8) then break end
        local e = ffi.cast('uint8_t **', tab + 8 * i)[0]
        if e ~= nil and readable(e, 0x140) then
            local t = ffi.cast('uint32_t *', e)[0]
            local hex = {}
            for o = 0, 0x13F do hex[#hex + 1] = string.format('%02x', e[o]) end
            add(string.format('reg %d type %d %s: %s', i, t, tostring(names[t] or '?'), table.concat(hex)))
            n = n + 1
        end
    end
    add(string.format('registry: %d entries, %d type names', n, #names))
end
local frames, last_world, checks = 0, nil, 0
local previous_update = update
if type(previous_update) ~= 'function' then return end
update = function(dt, ...)
    frames = frames + 1
    if frames == 60 then pcall(startup); write() end
    if frames == 600 then local okr, er = pcall(registry); if not okr then add('registry error: ' .. tostring(er)) end; write() end
    if frames % 600 == 0 and checks < 40 then          -- every ~10 s: a new main world (a mission) gets its counts
        pcall(function()
            local world = stingray.Application.main_world()
            if world ~= last_world or frames % 3600 == 0 then
                last_world = world; checks = checks + 1
                units(string.format('check %d (frame %d)', checks, frames)); write()
            end
        end)
    end
    return previous_update(dt, ...)
end

-- HD2-Addon: mods/chef/armored_overhaul_run_flat
-- Armored Overhaul 3.6.0 - FRV Run-Flat Tires: the M-102 and M-103 FRVs' tires never pop. Written from scratch.
--
-- How the game decides (game.dll, Sept 2026 build; field meanings from the game's own health settings, offsets from
-- its code): every unit with health has a health settings record (HealthComponent, 0x5650 bytes, in the settings the
-- game loads at start), with up to 38 damageable zones of 0x228 bytes from +0x208. A zone's maximum health is at
-- zone +0xE8 and the byte at zone +0xF0 is its "immortal" flag: "this zone cannot die until the entire entity dies".
-- The game's zone damage code (game.dll+0x9240A5) reads that byte: an immortal zone that would die stays alive (down,
-- not destroyed) while the vehicle lives. On both FRVs the first four zones are the tires (350 health each, front
-- left, front right, rear left, rear right: the same four parts Tank Core reads for the Vehicle Indicator).
-- This sets the tires' immortal flag in the FRVs' loaded settings, so a tire can't pop; Tank Core (part of this
-- option) also tops the tires of the FRV you ride in back up to full, so they never show damage. Nothing else in the
-- records is changed. The game's values go back when the game closes or the option is turned off in the menu.
-- Each FRV the game has called in may also hold its own copy of these settings (made from the shared record when it
-- spawns, game.dll+0x929B57; kept in the runtime health component, looked up by game.dll+0x507920): those copies are
-- set too, a few hundred at a time over the frames.
-- Finding it: the settings accessor for this component (looks a resource id up in the component's slot list and
-- returns its record: stride 0x5650, records after the slots) by its code shape, at its known place on the known build
-- first; the FRVs by their resource ids; each record checked against the game's own values before anything is written.
-- Writes ArmoredOverhaul-RunFlat.log.
-- (Multiplayer: damage is decided by the host's game, so this works when you host or play alone.)
if type(jit) == 'table' and type(jit.off) == 'function' then jit.off(true, true) end
if rawget(_G, 'ArmoredOverhaulRunFlat') then return end
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

local S = {version = '3.6.0', status = 'starting', game = 'unchecked', found = 'not yet', how = 'none',
           frvs = 'not yet', copies = 'not looked at yet', copies_found = 'not looked for yet', writes = 0, reapplied = 0,
           errors = 0, last_error = 'none', options_menu = 'not installed (the mod manager\'s pick)', frames = 0,
           on = false, tire_full = nil}
-- (S.on and S.tire_full are read by Tank Core: it tops the tires of the FRV you ride in back up to tire_full while on)
rawset(_G, 'ArmoredOverhaulRunFlat', S)

local function log()
    pcall(function()
        local f = loader.open_log and loader.open_log('ArmoredOverhaul-RunFlat.log')
        if not f then return end
        f:write('Armored Overhaul - FRV Run-Flat Tires\n', 'version: ', S.version, '\n', 'status: ', S.status, '\n',
            'game: ', S.game, '\n', 'found: ', S.found, ' (', S.how, ')\n',
            'FRVs: ', S.frvs, '\n', 'per-FRV copies: ', S.copies, '\n', 'per-FRV copy table: ', S.copies_found, '\n',
            'put back after the game reset them: ', S.reapplied, '\n',
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
pcall(ffi.cdef, 'typedef struct { void *base; void *alloc; uint32_t aprot; uint16_t part; uint16_t res; size_t size; uint32_t state; uint32_t prot; uint32_t type; } AORFRegion;')
local okk, k32 = pcall(ffi.load, 'kernel32')
if not okk then S.status = 'off (kernel32 not available)'; log(); return end
local U8 = ffi.typeof('uint8_t *')
local U32P, S32P = ffi.typeof('uint32_t *'), ffi.typeof('int32_t *')
local mbi = ffi.new('AORFRegion')
local old = ffi.new('unsigned long[1]')
local old2 = ffi.new('unsigned long[1]')

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
local function u32(p) return ffi.cast(U32P, p)[0] end
local function s32(p) return ffi.cast(S32P, p)[0] end
local function ptr(p)
    local v = ffi.cast('uint8_t **', p)[0]
    return (v ~= nil and readable(v, 8)) and v or nil
end
-- writes one byte, opening a read-only page for the write only
local function write_byte(p, v)
    if k32.VirtualQuery(ffi.cast('void *', p), ffi.cast('void *', mbi), ffi.sizeof(mbi)) == 0 then return false end
    if mbi.state ~= 0x1000 or bit.band(mbi.prot, 0x101) ~= 0 then return false end
    local writable = bit.band(mbi.prot, 0xCC) ~= 0
    if not writable and k32.VirtualProtect(ffi.cast('void *', p), 1, 0x04, ffi.cast('void *', old)) == 0 then return false end
    ffi.cast(U8, p)[0] = v
    if not writable then k32.VirtualProtect(ffi.cast('void *', p), 1, old[0], ffi.cast('void *', old2)) end
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
-- count's modulo follows) ... and, within 0x90 bytes, the record step:
-- mov ecx,[rax+8] / imul rax,rcx,STRIDE / add rax,FIRST / add rax,r10 / ret
local HEAD = compile('48 85 C9 74 ?? 48 8B 05 ?? ?? ?? ?? 44 8B C1 4C 8B 90 ?? ?? ?? ?? 48 B8 ?? ?? ?? ?? ?? ?? ?? ?? 48 F7 E1')
local STEP = compile('8B 48 08 48 69 C1 ?? ?? ?? ?? 48 05 ?? ?? ?? ?? 49 03 C2 C3')
local STEP_LEAD = '\139\72\8\72\105\193'
-- the per-FRV copies' look-up (game.dll+0x507920) ends: ... imul rax,rax,STRIDE / add rax,[r11+ARRAY] / add rsp,28h / ret /
-- mov rcx,[r10] / add rsp,28h / jmp ACCESSOR (the shared record when the entity has no copy of its own)
local TAIL_LEAD = '\73\139\10\72\131\196\40\233'
local KNOWN = {stamp = 0x6AB3B43F, head = 0x507430, tail = 0x5079E5}
local game, image_size, stamp
local function matches(p, pat)
    for i = 1, pat.n do if pat.mask[i] and p[i - 1] ~= pat.bytes[i] then return false end end
    return true
end
-- the accessor at rva: {root = the settings-root global, table_at = the table's offset in the root, first = where the
-- records start in the table (after the slots, 16 bytes each), stride = the record size}, or nil
local function accessor_at(rva, checked)
    local p = game + rva
    -- ((3.6.0 review) the bytes it reads checked first (`checked`: the caller checked them): after a patch a hit can sit
    -- next to an unreadable region)
    if rva < 0x1000 or rva > image_size - 0xA0 or not (checked or readable(p, 0xA4)) or not matches(p, HEAD) then return nil end
    for k = 0x23, 0x90 do
        if matches(p + k, STEP) then
            local first, stride = u32(p + k + 12), u32(p + k + 6)
            if first < 0x80 or first > 0x100000 or first % 16 ~= 0 then return nil end
            if stride < 0x4000 or stride > 0x8000 then return nil end      -- (the health settings record: 0x5650 today)
            return {root = p + 12 + s32(p + 8), table_at = u32(p + 18), first = first, stride = stride, rva = rva}
        end
    end
end
local function bytes_are(p, s)
    for i = 1, #s do if p[i - 1] ~= s:byte(i) then return false end end
    return true
end
-- the per-FRV copies' look-up from its tail at rva (see TAIL_LEAD): {global = the runtime health component's global,
-- map = its copies map (entries pointer; capacity +8, empty key +0xC), arr = the copies' array}, or nil
local function tail_at(rva, acc)
    if rva < 0xD0 or rva > image_size - 0x20 or not readable(game + rva - 0xD0, 0xE0) then return nil end
    local p = game + rva
    if not bytes_are(p, TAIL_LEAD) or rva + 12 + s32(p + 8) ~= acc.rva then return nil end
    if p[-1] ~= 0xC3 or not bytes_are(p - 5, '\72\131\196\40') or not bytes_are(p - 12, '\73\3\131') or not bytes_are(p - 19, '\72\105\192') then return nil end
    if u32(p - 16) ~= acc.stride then return nil end
    local arr = u32(p - 9)
    local global, map
    for back = 20, 0xD0 do
        local q = p - back
        if not global and bytes_are(q, '\76\139\29') then global = q + 7 + s32(q + 3) end
        if not map and bytes_are(q, '\73\139\187') then map = u32(q + 3) end
    end
    if not global or not map or arr < 0x10 or arr > 0x100000 or map > 0x100000 then return nil end
    -- (the capacity and empty key right after the entries pointer, as the look-up reads them)
    local cap_ok, empty_ok = false, false
    for back = 20, 0xD0 do
        local q = p - back
        if bytes_are(q, '\69\139\139') and u32(q + 3) == map + 8 then cap_ok = true end
        if bytes_are(q, '\65\139\179') and u32(q + 3) == map + 12 then empty_ok = true end
    end
    if not cap_ok or not empty_ok then return nil end
    return {global = global, map = map, arr = arr, rva = rva}
end
-- (patched game) one 256 KB piece of game code per frame: the record step's fixed bytes looked for with string.find,
-- then the head looked for up to 0x90 bytes before it; the copies' look-up tails kept for after the choice
local scan = {at = 0x1000, hits = {}, tails = {}}
local function scan_step()
    local a = scan.at
    if a >= image_size - 0xA0 then return true end
    if k32.VirtualQuery(ffi.cast('void *', game + a), ffi.cast('void *', mbi), ffi.sizeof(mbi)) == 0 then scan.at = a + 0x1000; return false end
    local rb = tonumber(ffi.cast('uintptr_t', mbi.base)) - tonumber(ffi.cast('uintptr_t', game))
    local re = math.min(rb + tonumber(mbi.size), image_size - 0xA0)
    -- (3.6.0 review: 0xE0, not 0xF0: an execute-only page (0x10) can't be read)
    local code = mbi.state == 0x1000 and bit.band(mbi.prot, 0xE0) ~= 0 and bit.band(mbi.prot, 0x101) == 0
    if not code then scan.at = math.max(re, a + 0x1000); return false end
    local n = math.min(0x40000, re - a)
    local tail = readable(game + a + n, 0x20) and 0x20 or 0      -- (3.6.0 review: not past the region's end unchecked)
    local chunk = ffi.string(game + a, n + tail)
    local from = 1
    while true do
        local hit = chunk:find(STEP_LEAD, from, true)
        if not hit or hit > n then break end
        local step_rva = a + hit - 1
        -- (one check for every head place before this hit and the bytes each reads)
        if step_rva >= 0x1000 + 0x90 and readable(game + step_rva - 0x90, 0x90 - 0x23 + 0xA4) then
            for back = 0x23, 0x90 do
                local acc = accessor_at(step_rva - back, true)
                if acc then scan.hits[#scan.hits + 1] = acc; break end
            end
        end
        from = hit + 1
    end
    from = 1
    while #scan.tails < 64 do
        local hit = chunk:find(TAIL_LEAD, from, true)
        if not hit or hit > n then break end
        scan.tails[#scan.tails + 1] = a + hit - 1
        from = hit + 1
    end
    scan.at = a + n
    return scan.at >= image_size - 0xA0
end

-- ---------------------------------------------------------------- the FRVs' records
-- each zone: 0x228 bytes from +0x208; its name hash at zone +0x60, its maximum health at +0xE8, immortal at +0xF0
-- (then four more flags, 0 or 1). The first four zones are the tires.
local Z = {stride = 0x228, name = 0x268, health = 0x2F0, immortal = 0x2F8, tires = 4, hp = 350, sig = 8}
local FRVS = {{name = 'M-102', lo = 0xD3EBEFB9, hi = 0xCC21C7FF}, {name = 'M-103', lo = 0x8640432E, hi = 0x9B214037},
              {name = 'M-104', lo = 0xD8717FE5, hi = 0x2D85BFE3, optional = true}}   -- (the M-104 isn't in the game now)
local found = nil           -- the accessor
local copies_at = nil       -- the per-FRV copies' look-up (tail_at)
local held = {}             -- FRV name -> {rec, tbl, game = {4 bytes}, from, sig, set}
local want_on = true        -- the Mod Options Menu's value (on unless turned off there)
local next_check = 0        -- the frame of the next look at the settings
local TWO32 = 4294967296
-- the record of a resource id: the game's own look-up (the id's slot = id modulo the slot count, then the next ones)
local function record_of(tbl, v)
    local n = found.first / 16
    local slot = ((v.hi % n) * (TWO32 % n) + v.lo % n) % n
    for _ = 1, n do
        local e = tbl + 16 * slot
        local lo, hi = u32(e), u32(e + 4)
        if lo == v.lo and hi == v.hi then
            local idx = u32(e + 8)
            local rec = tbl + found.first + found.stride * idx
            if idx < n and readable(rec, found.stride) then return rec end
            return nil, 'its record index is out of range'
        end
        if lo == 0 and hi == 0 then break end
        slot = slot + 1 == n and 0 or slot + 1
    end
    return nil, 'not in the list'
end
-- the tire zones of a record checked: nil and the reason when not as the game has them
local function check_zones(rec)
    for k = 0, Z.tires - 1 do
        local z = rec + k * Z.stride
        local hp = s32(z + Z.health)
        if hp ~= Z.hp then return string.format('zone %d health is %d, not %d', k, hp, Z.hp) end
        if u32(z + Z.name) == 0 then return string.format('zone %d has no name', k) end
        for b = 0, 4 do
            if z[Z.immortal + b] > 1 then return string.format('zone %d flag +0x%X is %d', k, 0xF0 + b, z[Z.immortal + b]) end
        end
    end
end
-- the first Z.sig zones' names: what a per-FRV copy is recognized by
local function signature(rec)
    local t = {}
    for k = 0, Z.sig - 1 do t[#t + 1] = ffi.string(rec + Z.name + k * Z.stride, 4) end
    return table.concat(t)
end
-- (as in Tank Collision Damage Boost) the game's own values are also kept in a process environment variable: a copy of
-- this addon loaded again while the game runs finds this mod's flags in the records, and takes the game's from there
local ENV_NAME = 'ARMORED_OVERHAUL_RUNFLAT_GAME'
local kept = nil
local function env_read()
    kept = {}
    local buf = ffi.new('char[256]')
    local ok, n = pcall(k32.GetEnvironmentVariableA, ENV_NAME, buf, 256)
    if not ok or not n or n == 0 or n >= 256 then return end
    for name, bits in ffi.string(buf, n):gmatch('([%w%-]+)=([01]+)') do
        if #bits == Z.tires then kept[name] = {} for k = 1, Z.tires do kept[name][k] = tonumber(bits:sub(k, k)) end end
    end
end
local function env_save()
    local t = {}
    for name, hd in pairs(held) do t[#t + 1] = name .. '=' .. table.concat(hd.game) end
    table.sort(t)
    pcall(k32.SetEnvironmentVariableA, ENV_NAME, table.concat(t, ';'))
end
local function table_now()
    local root = readable(found.root, 8) and ptr(found.root)
    return root and readable(root + found.table_at, 8) and ptr(root + found.table_at)
end
-- the flags written as wanted in each FRV's record; returns how many FRVs were set and a line for the log
local function apply()
    local tbl = table_now()
    if not tbl or not readable(tbl, found.first) then return 0, 'the settings are not loaded yet' end
    local parts, n, set = {}, 0, {}
    for _, v in ipairs(FRVS) do
        local rec, why = record_of(tbl, v)
        local line
        if rec then
            local bad = check_zones(rec)
            local hd = held[v.name]
            if hd and hd.rec ~= rec then
                -- the game loaded its settings again: the game's values there again counted as a reset
                if hd.set and want_on and not bad then
                    local same = true
                    for k = 0, Z.tires - 1 do if rec[Z.immortal + k * Z.stride] ~= hd.game[k + 1] then same = false end end
                    if same and hd.game[1] == 0 then S.reapplied = S.reapplied + 1 end
                end
                hd = nil
            end
            if not hd and not bad then
                -- the game's values: kept by an earlier copy of this addon in this game (see ENV_NAME), else as read;
                -- all four set with nothing kept on the known build: the known build's own (none set)
                if not kept then env_read() end
                local now, any = {}, false
                for k = 0, Z.tires - 1 do now[k + 1] = rec[Z.immortal + k * Z.stride]; if now[k + 1] == 1 then any = true end end
                local g, from
                if kept[v.name] then g, from = kept[v.name], 'kept'
                elseif any and stamp == KNOWN.stamp then g, from = {0, 0, 0, 0}, 'known build'
                else g, from = now, 'read' end
                hd = {rec = rec, tbl = tbl, game = g, from = from, sig = signature(rec)}
                held[v.name] = hd
                env_save()
            end
            if bad then
                line = v.name .. ': left alone (' .. bad .. ')'
            else
                local reset = false
                for k = 0, Z.tires - 1 do
                    local p = rec + Z.immortal + k * Z.stride
                    local want = want_on and 1 or hd.game[k + 1]
                    if p[0] ~= want then
                        if hd.set and want_on and p[0] == hd.game[k + 1] then reset = true end
                        if not write_byte(p, want) then error('write refused for the ' .. v.name) end
                    end
                end
                if reset then S.reapplied = S.reapplied + 1 end
                hd.set = want_on
                if want_on then set[v.name] = s32(rec + Z.health) end      -- (3.6.0 review) its tire maximum, for Tank Core
                n = n + 1
                local gs = table.concat(hd.game)
                line = want_on and string.format('%s: 4 tires set (the game\'s flags %s, %s)', v.name, gs, hd.from)
                    or string.format('%s: the game\'s own flags %s', v.name, gs)
            end
        elseif v.optional and why == 'not in the list' then
            line = v.name .. ': not in the game'
        else
            line = v.name .. ': ' .. why
        end
        parts[#parts + 1] = line
    end
    -- (3.6.0 review) which FRVs were set, with each one's tire maximum: Tank Core keeps only those full (Test 13 kept
    -- every FRV's tires at 350, a "left alone" one too)
    S.on = want_on and n > 0
    S.set = S.on and set or {}
    S.tire_full = S.on and Z.hp or nil
    return n, table.concat(parts, '; ')
end
local function restore()
    -- only into the table the flags were written to (a table the game loaded again since may be somewhere else)
    local tbl = found and table_now()
    for _, hd in pairs(held) do
        if hd.set and tbl and tbl == hd.tbl and readable(hd.rec + Z.name, Z.tires * Z.stride) and not check_zones(hd.rec) then
            for k = 0, Z.tires - 1 do
                local p = hd.rec + Z.immortal + k * Z.stride
                if p[0] ~= hd.game[k + 1] then pcall(write_byte, p, hd.game[k + 1]) end
            end
            hd.set = false
        end
    end
    S.on, S.tire_full, S.set = false, nil, {}
end

-- ---------------------------------------------------------------- the FRVs' own copies
-- The runtime health component (the global the look-up reads) keeps a map of entity -> copy (8-byte entries: the
-- entity id, the copy's index; capacity at +8, empty key at +0xC) and the copies' array. Every 5 s a pass goes
-- through the map, 512 entries a frame: a copy whose first eight zone names match an FRV's record and whose tires
-- are as the game has them gets the same flags as the shared record (on: set; off: the game's own).
local cp = {i = 0, cap = 0, next_at = 0}
local copy_line = nil
-- (3.6.0 review) the map as the game has it now (read every frame of a pass: a map the game moved or resized since the
-- pass started ends the pass, so freed memory is never walked)
local function copies_map()
    local g = readable(copies_at.global, 8) and ptr(copies_at.global)
    local entries = g and readable(g + copies_at.map, 16) and ptr(g + copies_at.map)
    local cap = entries and u32(g + copies_at.map + 8) or 0
    local arr = g and readable(g + copies_at.arr, 8) and ptr(g + copies_at.arr)
    return entries, cap, arr, g
end
-- (3.6.0 review) readable() with the last region it found kept for this frame: one memory query per region, not one or
-- two per copy (Test 13: up to 1024 a frame during a pass)
local rc = {lo = 0, hi = 0}
local function readable_here(p, n)
    local a = tonumber(ffi.cast('uintptr_t', p))
    if a >= rc.lo and a + n <= rc.hi then return true end
    if not readable(p, n) then return false end
    if k32.VirtualQuery(ffi.cast('void *', a), ffi.cast('void *', mbi), ffi.sizeof(mbi)) ~= 0 then
        rc.lo = tonumber(ffi.cast('uintptr_t', mbi.base)); rc.hi = rc.lo + tonumber(mbi.size)
    end
    return true
end
local function copies_step()
    if not copies_at or not next(held) then return end
    rc.lo, rc.hi = 0, 0
    if cp.i < cp.cap then
        local entries, cap, arr = copies_map()
        if entries ~= cp.entries or arr ~= cp.arr or cap ~= cp.cap then cp.i, cp.cap, cp.next_at = 0, 0, S.frames + 30; return end
    end
    if cp.i >= cp.cap then
        if S.frames < cp.next_at then return end
        cp.next_at = S.frames + 300
        local entries, cap, arr, g = copies_map()
        if not entries or not arr or cap == 0 or cap > 0x100000 then
            cp.cap, cp.i = 0, 0
            S.copies = 'none yet'
            return
        end
        cp = {i = 0, cap = cap, entries = entries, empty = u32(g + copies_at.map + 12), arr = arr, next_at = cp.next_at,
              all = 0, frv = 0, set = 0}
    end
    local n = math.min(512, cp.cap - cp.i)
    if not readable(cp.entries + 8 * cp.i, 8 * n) then cp.i = cp.cap; return end
    local e = ffi.cast(U32P, cp.entries + 8 * cp.i)
    for j = 0, n - 1 do
        local key, idx = e[2 * j], e[2 * j + 1]
        if key ~= cp.empty and idx ~= 0xFFFFFFFF and idx < 0x100000 then
            cp.all = cp.all + 1
            local rec = cp.arr + idx * found.stride
            if readable_here(rec + Z.name, (Z.sig - 1) * Z.stride + 8) and s32(rec + Z.health) == Z.hp then
                local sig = signature(rec)
                for _, hd in pairs(held) do
                    if hd.sig == sig and not check_zones(rec) then
                        cp.frv = cp.frv + 1
                        for k = 0, Z.tires - 1 do
                            local p = rec + Z.immortal + k * Z.stride
                            local want = want_on and 1 or hd.game[k + 1]
                            if p[0] ~= want then
                                if write_byte(p, want) then cp.set = cp.set + 1
                                else S.errors = S.errors + 1; S.last_error = 'a per-FRV copy refused the write' end
                            end
                        end
                        break
                    end
                end
            end
        end
    end
    cp.i = cp.i + n
    if cp.i >= cp.cap then
        S.copies = string.format('%d FRV(s) with a copy of their own (%d flag(s) written this pass); %d copies in all', cp.frv, cp.set, cp.all)
        local text = cp.frv .. ' ' .. cp.set        -- ((3.6.0 review) not the count of all copies: it changes all the time)
        if text ~= copy_line then copy_line = text; log() end
    end
end

-- ---------------------------------------------------------------- Mod Options Menu (3.0)
local menu_rows, menu_set, menu_link = {}, nil, nil
do
    local MENU_ORDER = {'speed', 'power', 'grip', 'steering', 'throttle', 'stability', 'collision', 'maelstrom', 'turret', 'autoloader', 'gunner_drive', 'driver_panel', 'camera', 'run_flat', 'indicator', 'loadout'}
    local hub = rawget(_G, 'ArmoredOverhaulMenu')
    if type(hub) ~= 'table' or type(hub.groups) ~= 'table' then hub = {groups = {}, done = {}}; rawset(_G, 'ArmoredOverhaulMenu', hub) end
    for _, g in ipairs({'run_flat'}) do
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
        for _, g in ipairs({'run_flat'}) do if not hub.done[g] then mine = false end end
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
menu_rows.run_flat = {
    {'armored_overhaul.run_flat', {type = 'toggle', label = 'FRV Run-Flat Tires', default = true,
        description = 'The M-102 and M-103 FRVs\' tires never pop, and the tires of the FRV you ride in stay at full health. Works when you host or play alone (in someone else\'s game their game decides). Turning it off puts the game\'s own back.'}, 'on'},
}
menu_set = function(key, v)
    if key ~= 'on' then return end
    want_on = v == true or v == 1
    next_check = 0                                 -- (applied at the next frame)
    cp.i, cp.cap, cp.next_at = 0, 0, 0            -- (and a new pass through the copies)
end

local phase, shown = 'gate', nil
local function tick()
    S.frames = S.frames + 1
    menu_link(S.frames)
    if phase == 'run' then copies_step() end
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
            if found then
                S.how = 'known build'; phase = 'run'
                copies_at = tail_at(KNOWN.tail, found)
                if not copies_at then S.copies = 'not handled (the per-FRV copies\' look-up was not found)' end
            end
        end
        if phase == 'scan' then S.how = 'searching game code'; S.status = 'searching game code' end
    end
    if phase == 'scan' then
        if not scan_step() then return end
        phase, scan.tries = 'choose', 0
    end
    -- the candidates are looked at again every 2 s while the settings aren't loaded yet
    if phase == 'choose' then
        -- the one whose table lists the M-102 with its tires as the game has them
        for _, acc in ipairs(scan.hits) do
            found = acc
            local root = readable(acc.root, 8) and ptr(acc.root)
            local tbl = root and readable(root + acc.table_at, 8) and ptr(root + acc.table_at)
            local rec = tbl and readable(tbl, acc.first) and record_of(tbl, FRVS[1])
            if rec and not check_zones(rec) then break end
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
            S.status = string.format('off: this game build\'s health settings not recognized (%d candidate(s))', #scan.hits)
            phase = 'off'; log(); return
        end
        for _, t in ipairs(scan.tails) do copies_at = copies_at or tail_at(t, found) end
        if not copies_at then S.copies = 'not handled (the per-FRV copies\' look-up was not found)' end
        S.how = 'found by search'; phase = 'run'
    end
    if phase == 'run' then
        S.found = string.format('settings accessor game.dll+0x%X (table at root+0x%X, records of 0x%X from +0x%X)', found.rva, found.table_at, found.stride, found.first)
        S.copies_found = copies_at and string.format('look-up game.dll+0x%X (health global game.dll+0x%X, map +0x%X, copies +0x%X)', copies_at.rva,
            tonumber(ffi.cast('uintptr_t', copies_at.global)) - tonumber(ffi.cast('uintptr_t', game)), copies_at.map, copies_at.arr)
            or 'not found: only FRVs called in after the settings are set get it'
        next_check = S.frames + 300                -- every ~5 s: settings the game loaded again get it again
        local n, line = apply()
        S.frvs = line
        S.status = n == 0 and 'waiting for the vehicle settings' or (want_on and 'on' or 'off (Mod Options Menu): the game\'s own')
        if n == 0 then next_check = S.frames + 120 end
        if TESTER and n > 0 then
            local parts = {}
            for name, hd in pairs(held) do
                parts[#parts + 1] = string.format('%s main health %d, zone names %s', name, s32(hd.rec), (hd.sig:gsub('.', function(c) return string.format('%02x', c:byte()) end)))
            end
            table.sort(parts)
            S.detail = table.concat(parts, '\n')
        end
        local text = S.status .. S.frvs .. S.reapplied .. S.options_menu
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

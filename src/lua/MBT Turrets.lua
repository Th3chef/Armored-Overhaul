-- HD2-Addon: mods/chef/armored_overhaul_turret_360
-- Armored Overhaul 3.1.1 - Tank MBT Turrets: turret option flag (read by the turret core,
-- mods/chef/armored_overhaul_mbt_turrets) and, since 3.1.0, the turret turner.
-- (3.1.0) The turret models are the game's own tank hulls with everything above the roof line tied to the hull's
-- second gun mount (node b7e9b43d); the guns, missile pods and smoke launchers are the game's own units on their own
-- mounts. Every frame, for every Bastion and Maelstrom out, this turns that mount to the main gun's heading and carries
-- the Maelstrom's pod and smoke launcher mounts round the turret's axis, so the turret armour, pods and launchers follow
-- the gun. Because the armour stays on the hull, the game's own camo and damage looks apply to it. The second gun on
-- that mount (the Bastion's second gun, the Maelstrom's laser designator) has its own left/right locked by the turret
-- core, so it points where the main gun does. Writes ArmoredOverhaul-TurretModels.log.
-- (Test 21) The Bastion's gun search keeps the gun with a model (see find_gun).
-- (Test 22) Each hull's turn rate on the ground and the turret's against the hull are measured every frame; the log
-- gives the fastest seen. (Test 24) They are no longer used to raise the turret's speed: the game takes that when the
-- tank is called in (Test 22's log: speed written up to +95 deg/s, the turret never past the option's 50).
-- (Test 31) Mount help: the game holds a tank gun's own left/right turn to about 46 deg/s whatever its settings say
-- (Tests 22-30). While the gun turns at that limit, its mount (hull node e30c5711, which carries the whole gun) is
-- turned the same way too, by up to the rest of the Tank Turret Traverse speed (Very fast: 75 - 46). Once the gun no
-- longer turns at its limit, the mount goes back to straight at no more than 15 deg/s, which the gun easily makes up, so
-- nothing stays turned and the barrel ends where the crosshair is. With MBT Turrets 360 only (the 180 choice's limits
-- are measured from the mount). The log gives the most help given.
-- (Test 20) The gunner's seat (node d967cc83, 1.66 m behind the turret's axis, the same in both hulls, found by the Test 19
-- seat probe) is carried round with the turret too: the helldiver in it stayed put on the hull, so with the turret turned
-- 180 deg the helmet showed through the gun slot. Optional: if the seat node isn't where the game had it, the turret
-- still turns, without it.
local o = rawget(_G, 'ArmoredOverhaulTurretOptions')
if type(o) ~= 'table' then o = {}; rawset(_G, 'ArmoredOverhaulTurretOptions', o) end
o.mbt = true

if type(jit) == 'table' and type(jit.off) == 'function' then jit.off(true, true) end
if rawget(_G, 'ArmoredOverhaulTurretTurner') then return end
local loader = rawget(_G, 'CowboyBingusModLoader')
if type(loader) ~= 'table' or type(loader.version) ~= 'number' or loader.version < 15 then return end
local TESTER = false

local S = {version = '3.1.1', status = 'starting', api = 'unchecked', frames = 0, errors = 0, last_error = 'none',
           tanks = 0, turned = 0, no_gun = 0, bad_nodes = 0, gun_searches = 0, no_seat = 0}
rawset(_G, 'ArmoredOverhaulTurretTurner', S)
S.clock = 0                        -- (3.1.1 review) seconds of game time (summed from the update's dt)
-- (3.1.1 review) S.yaw_rate (no reader since Test 24) is gone; hull -> heading / gun unit only in Tester builds (the probe)
if TESTER then S.angle, S.gun = {}, {} end
local seen = {}                    -- tank name -> {turret = fastest turret turn against the hull, hull = fastest hull turn}

-- node places, 0-based in the hull's node list (read from the game's unit files), the engine's numbering found from
-- the 'root' node (0-based 45); each one is checked against its local position before it is used
local AXIS_X, AXIS_Y = 0.0, -1.959                     -- the gun mounts' axis in the hull's frame
local HULLS = {
    {name = 'Bastion', res = 'content/fac_helldivers/vehicles/tank/tank',
     turn = {k = 159, x = 0, y = -1.959, z = 1.363}, carry = {{k = 183, x = 0.013, y = -3.622, z = 0.353, optional = true}}},
    {name = 'Maelstrom', res = 'content/fac_helldivers/vehicles/tank_storm/tank_storm',
     gun = 'content/fac_helldivers/vehicles/tank_storm/armaments/tank_storm_maingun/tank_storm_maingun',
     turn = {k = 159, x = 0, y = -1.959, z = 1.363},
     carry = {{k = 218, x = 0, y = -2.816, z = 1.917}, {k = 219, x = -1.422, y = -4.511, z = 1.804},
              {k = 220, x = 1.422, y = -4.511, z = 1.804}, {k = 183, x = 0.013, y = -3.622, z = 0.353, optional = true}}},
}
local GUN_MOUNT = {k = 158, x = 0, y = -1.959, z = 1.363}  -- where the main gun sits (to find it)
-- (3.1.1 review) in seconds (3.1.0 counted frames: the 2 s wait before a new hull's gun is looked for - Test 9's crash
-- margin - was 0.5 s at 240 fps, and the Bastion's whole-world search ran 4 times a second while a gun was missing)
local HULL_EVERY, GUN_EVERY, GUN_WAIT = 0.5, 1, 2           -- s between looking for hulls / for a missing gun;
                                                           -- s after a hull appears before its gun is looked for
local GUN_MISSES, GUN_SLOW = 5, 10                          -- after 5 misses in a row, a missing gun is looked for every 10 s

local GUN_CAP = math.deg(0.8)        -- (Test 31) deg/s: a tank gun's own top turn (measured 46-49; 0.8 rad/s)
local help_seen = {extra = 0, offset = 0, times = 0}     -- (Test 31) the most mount help given, for the log
local function log()
    pcall(function()
        local f = loader.open_log and loader.open_log('ArmoredOverhaul-TurretModels.log')
        if not f then return end
        f:write('Armored Overhaul - turret models (Tank MBT Turrets)\n', 'version: ', S.version, '\n', 'status: ', S.status, '\n',
            'api: ', S.api, '\n', 'tanks out: ', S.tanks, ' (turrets turning: ', S.turned, ', gun not found: ', S.no_gun,
            ', hull not as expected: ', S.bad_nodes, ')\n', 'gunner seats turned with the turret: ', S.turned - S.no_seat, (S.no_seat > 0 and (' (' .. S.no_seat .. ' seat node(s) not found: those gunners stay put)') or ''), '\n', 'errors: ', S.errors, '\n', 'last error: ', S.last_error, '\n')
        if S.search_note then f:write('note: ', S.search_note, '\n') end
        if S.recovered then f:write('turrets found already turned when this started (the game\'s Lua reloaded): ', S.recovered, ', put right\n') end
        if help_seen.times > 0 then
            f:write(string.format('mount help (the gun at its own %.0f deg/s limit): %d time(s), up to %.0f deg/s more, the mount turned up to %.0f deg\n',
                GUN_CAP, help_seen.times, help_seen.extra, help_seen.offset))
        end
        for _, h in ipairs(HULLS) do
            local m = seen[h.name]
            if m then f:write(string.format('%s: turret turned up to %.0f deg/s against the hull (smoothed), the hull up to %.0f deg/s on the ground\n', h.name, m.turret, m.hull)) end
        end
        if TESTER then f:write('-- tester details --\n', 'frames: ', S.frames, '\n', 'gun searches: ', S.gun_searches, '\n') end
        f:close()
    end)
end

local A, W, U, Q, V3
local function api_ok()
    if S.api == 'ok' then return true end
    if S.api ~= 'unchecked' then return false end
    local SR = rawget(_G, 'stingray')
    if type(SR) ~= 'table' then S.api = 'missing: stingray'; S.status = 'off'; return false end
    A, W, U, Q, V3 = SR.Application, SR.World, SR.Unit, SR.Quaternion, SR.Vector3
    local missing = {}
    for _, n in ipairs({{U, 'Unit', 'local_position'}, {U, 'Unit', 'local_rotation'}, {U, 'Unit', 'set_local_position'},
                        {U, 'Unit', 'set_local_rotation'}, {U, 'Unit', 'world_rotation'}, {U, 'Unit', 'world_position'},
                        {U, 'Unit', 'node'}, {U, 'Unit', 'has_node'}, {U, 'Unit', 'alive'}, {W, 'World', 'units_by_resource'},
                        {W, 'World', 'units'}, {A, 'Application', 'main_world'}, {Q, 'Quaternion', 'multiply'},
                        {Q, 'Quaternion', 'to_elements'}, {Q, 'Quaternion', 'from_elements'}, {Q, 'Quaternion', 'forward'},
                        {Q, 'Quaternion', 'right'}, {V3, 'Vector3', 'to_elements'}}) do
        if type(n[1]) ~= 'table' or (type(n[1][n[3]]) ~= 'function' and type(n[1][n[3]]) ~= 'userdata') then
            missing[#missing + 1] = n[2] .. '.' .. n[3]
        end
    end
    if #missing > 0 then S.api = 'missing: ' .. table.concat(missing, ', '); S.status = 'off (this game build lacks what it needs)'; return false end
    S.api = 'ok'
    return true
end

-- (Test 9) a marker around the whole-world gun search (the Bastion's): if the game closed during one, the next start
-- skips it once (the Bastion's turret then stays put) and says so; the start after tries again
local function marker(write)
    local root = os.getenv and os.getenv('LOCALAPPDATA')
    if not root or root == '' or not io or not io.open then return nil end
    local path = root .. '\\CowboyBingus\\Helldivers2\\Logs\\ArmoredOverhaul-TurretModels.searchcheck'
    if write then local f = io.open(path, 'w'); if f then f:write(write); f:close() end; return end
    local f = io.open(path, 'r'); if not f then return nil end
    local t = f:read('*a'); f:close(); return t
end
local skip_world_search = false
do
    local last = marker()
    if last and last:find('searching', 1, true) then
        skip_world_search = true; S.search_note = 'the last whole-world gun search ended with the game closing: skipped this start'
        marker('skipped once\n')
    end
end

local function xyz(v) local ok, x, y, z = pcall(V3.to_elements, v); if ok then return x, y, z end end
local function quat(q) local ok, x, y, z, w = pcall(Q.to_elements, q); if ok and type(w) == 'number' then return {x, y, z, w} end end

local function now_s()
    local ok, t = pcall(A.time_since_launch)
    if ok and type(t) == 'number' then return t end
    return S.clock                     -- (3.1.1 review: 3.1.0 used frames / 60, wrong at any other frame rate)
end
local function wrap(a) return (a + math.pi) % (2 * math.pi) - math.pi end
-- per hull: turn rates (smoothed over about 6 frames), deg/s
local function rates(e, a, h, t, hy)
    -- (3.1.0 review) the last reading is kept in fields (no new table every frame)
    local lt, lhy, la = e.last_t, e.last_hy, e.last_a
    e.last_t, e.last_hy, e.last_a = t, hy, a
    if not (lt and hy and lhy and a and la) then return end
    local dt = t - lt
    if dt <= 0.001 or dt > 0.5 then return end
    local hr, tr = math.deg(wrap(hy - lhy)) / dt, math.deg(wrap(a - la)) / dt
    e.hr = (e.hr or 0) + (hr - (e.hr or 0)) * 0.3
    e.tr = (e.tr or 0) + (tr - (e.tr or 0)) * 0.3
    local m = seen[h.name] or {turret = 0, hull = 0}; seen[h.name] = m
    if math.abs(e.tr) > m.turret + 1 or math.abs(e.hr) > m.hull + 1 then
        m.turret, m.hull = math.max(m.turret, math.abs(e.tr)), math.max(m.hull, math.abs(e.hr)); S.seen_changed = true
    end
end

-- per hull unit: its nodes (index, rest position, rest rotation as numbers) and its gun
-- (3.1.1 review) a plain table, emptied of units that are gone (see tick): 3.1.0's weak keys never let go (each entry
-- pointed back at its own unit), and a new tank the game put at a destroyed one's place would have taken over its entry
local hulls = {}

local function node_at(u, base, want)
    local i = base + want.k
    local ok, p = pcall(U.local_position, u, i)
    if not ok or p == nil then return nil end
    local x, y, z = xyz(p)
    if not x or math.abs(x - want.x) > 0.01 or math.abs(y - want.y) > 0.01 or math.abs(z - want.z) > 0.01 then return nil end
    local q = quat(select(2, pcall(U.local_rotation, u, i)))
    if not q then return nil end
    return {i = i, x = x, y = y, z = z, q = q}
end

-- (3.1.1 review) A carried node already turned round the axis (the game's Lua rebuilt with the game open while a
-- turret was turned: this copy finds the last copy's pose): its turn angle, or nil if it isn't the wanted node turned.
local function turned_by(u, i, want)
    local ok, p = pcall(U.local_position, u, i)
    local x, y, z = xyz(ok and p)
    if not x or math.abs(z - want.z) > 0.01 then return nil end
    local wx, wy, nx, ny = want.x - AXIS_X, want.y - AXIS_Y, x - AXIS_X, y - AXIS_Y
    local r = math.sqrt(wx * wx + wy * wy)
    if r < 0.2 or math.abs(math.sqrt(nx * nx + ny * ny) - r) > 0.01 then return nil end
    return math.atan2(ny, nx) - math.atan2(wy, wx)
end
local function unturn(n, a)               -- the rest rotation of a node now turned by a
    if a == 0 then return n end
    local q = quat(select(2, pcall(Q.multiply, Q(V3(0, 0, 1), -a), Q.from_elements(n.q[1], n.q[2], n.q[3], n.q[4]))))
    if q then n.q = q end
    return n
end
local function setup(u, h)
    -- (Test 9) the first gun search waits 2 seconds after the hull appears (it is called in, not yet settled)
    local e = {kind = h, ok = false, gun = nil, trav = nil, next_gun = S.clock + GUN_WAIT, gun_misses = 0}
    local okh, has = pcall(U.has_node, u, 'root')
    if not (okh and has) then return e end
    local okr, root = pcall(U.node, u, 'root')
    if not (okr and type(root) == 'number') then return e end
    local base = root - 45
    e.turn = node_at(u, base, h.turn)
    e.mount = node_at(u, base, GUN_MOUNT)
    e.carry = {}
    -- (3.1.1 review) carried nodes found turned (all by the same angle): taken back to rest, and the turn node with them
    local a0
    for _, c in ipairs(h.carry) do
        local n = node_at(u, base, c)
        if not n then
            local a = turned_by(u, base + c.k, c)
            if a and (a0 == nil or math.abs(math.atan2(math.sin(a - a0), math.cos(a - a0))) < 0.01) then
                a0 = a0 or a
                local q = quat(select(2, pcall(U.local_rotation, u, base + c.k)))
                if q then n = {i = base + c.k, x = c.x, y = c.y, z = c.z, q = q, turned = true} end
            end
        end
        if n then e.carry[#e.carry + 1] = n
        elseif c.optional then e.no_seat = true
        else return e end
    end
    if a0 then
        for _, n in ipairs(e.carry) do if n.turned then unturn(n, a0); n.turned = nil end end
        if e.turn then unturn(e.turn, a0) end
        S.recovered = (S.recovered or 0) + 1
    end
    e.ok = e.turn ~= nil and e.mount ~= nil
    return e
end

-- the main gun: the unit with a 'traverse' node standing on the hull's gun mount
local function find_gun(u, e, world)
    S.gun_searches = S.gun_searches + 1
    local okm, mp = pcall(U.world_position, u, e.mount.i)
    local mx, my, mz = xyz(okm and mp)
    if not mx then return end
    local list
    if e.kind.gun then
        local ok, l = pcall(W.units_by_resource, world, e.kind.gun); list = ok and l
    end
    local whole = false
    if type(list) ~= 'table' or #list == 0 then
        if skip_world_search then return end
        local ok, l = pcall(W.units, world); list = ok and l; whole = true
    end
    if type(list) ~= 'table' then return end
    if whole then marker('searching\n') end
    -- (Test 9) only units with a 'traverse' node are asked where they are, as the Turret indicator does: Test 8 asked
    -- every unit in the world and the game crashed when a Bastion was called in (some units can't be asked that)
    -- (Test 21) the Bastion's second gun stands on the turning mount, at the same place as the cannon, and has no
    -- model: Test 20 took it (whichever came first in the list), and the turret then followed a gun that turns with it
    -- and spun on its own. Every gun on the mount is looked at and the one with the most meshes (the cannon) is kept.
    local best, best_meshes
    for _, g in ipairs(list) do
        if g ~= u then
            local okh, has = pcall(U.has_node, g, 'traverse')
            if okh and has then
                local okp, p = pcall(U.world_position, g, 1)
                local x, y, z = xyz(okp and p)
                if x and (x - mx) ^ 2 + (y - my) ^ 2 + (z - mz) ^ 2 < 0.09 then
                    local okn, ti = pcall(U.node, g, 'traverse')
                    local okc, meshes = pcall(U.num_meshes, g)
                    meshes = okc and type(meshes) == 'number' and meshes or 0
                    if okn and type(ti) == 'number' and (not best or meshes > best_meshes) then best, best_meshes, e.trav = g, meshes, ti end
                end
            end
        end
    end
    e.gun = best
    if whole then marker('ok\n') end
end

local function dot(ax, ay, az, bx, by, bz) return ax * bx + ay * by + az * bz end

-- the main gun's heading in the hull's frame (radians, + = turned left, as a rotation about the hull's up axis)
local function heading(u, e)
    local okh, hr = pcall(U.world_rotation, u, 1)
    local okg, gr = pcall(U.world_rotation, e.gun, e.trav)
    if not (okh and okg) then return nil end
    local fx, fy, fz = xyz(Q.forward(gr))
    local rx, ry, rz = xyz(Q.right(hr)); local hx, hy, hz = xyz(Q.forward(hr))
    if not (fx and rx and hx) then return nil end
    local a, b = dot(fx, fy, fz, rx, ry, rz), dot(fx, fy, fz, hx, hy, hz)
    if a * a + b * b < 1e-6 then return nil end
    return math.atan2(-a, b), (hx * hx + hy * hy >= 1e-4) and math.atan2(hy, hx) or nil   -- (and the hull's heading on the ground, for rates)
end

-- (Test 31) mount help; see the header
local HELP_ACCEL, HELP_RETURN = 200, 6
-- (Test 32) In testing "the gunner camera seems to bug out a bit when turning fast with high traverse ... seems to almost
-- overshoot". The help eased off at 200 deg/s/s once the gun stopped straining (near the crosshair), so the mount kept
-- turning for about 0.15 s and carried the turret, and the camera behind it, past the crosshair (4.6 deg in the sim with
-- a gun that eases in). It now stops at once (2000 deg/s/s) as soon as the gun's own turn drops under 90% of its limit
-- (read with less smoothing), and the mount goes back to straight at 6 deg/s (15 left a gun that eases in 3-4 deg
-- behind the crosshair while it went back).
local HELP_STOP = 2000
local function set_mount(u, e, m)
    if e.ms == m then return end          -- (3.1.0 review) written only when it changes (straight most of the time)
    local q = e.mount.q
    local ok = pcall(U.set_local_rotation, u, e.mount.i, Q.multiply(Q(V3(0, 0, 1), m), Q.from_elements(q[1], q[2], q[3], q[4])))
    e.ms = ok and m or nil                -- (3.1.1 review: a write that failed is tried again next frame)
end
local function help(u, e, a, t)
    local o = rawget(_G, 'ArmoredOverhaulTurretOptions')
    local core = rawget(_G, 'ArmoredOverhaulMBTTurrets')
    local trav = type(core) == 'table' and type(core.traverse_now) == 'number' and core.traverse_now or nil
    local on = trav and type(o) == 'table' and o.mbt == true and o.mbt_arc == nil
    local m = e.m or 0
    local lt, ltn = e.hl_t, e.hl_tn
    e.hl_t, e.hl_tn = t, a - m
    if not (lt and on) then
        if m ~= 0 then e.m, e.mr = 0, 0; set_mount(u, e, 0) end
        e.acc_d, e.acc_t = 0, 0
        return
    end
    local dt = t - lt
    if dt <= 0.001 or dt > 0.5 then e.acc_d, e.acc_t = 0, 0; return end
    -- the gun's own turn against its mount. (3.1.1 review) measured over at least 1/30 s: the game may step the gun at
    -- a fixed rate below the frame rate, so at 144-240 fps most frames read 0 and the help barely started (reach 3.6 s)
    e.acc_d, e.acc_t = (e.acc_d or 0) + wrap(a - m - ltn), (e.acc_t or 0) + dt
    if e.acc_t >= 1 / 30 - 1e-6 then
        local rt = math.deg(e.acc_d) / e.acc_t
        e.acc_d, e.acc_t = 0, 0
        e.rt = (e.rt or 0) + (rt - (e.rt or 0)) * 0.3
        e.rf = (e.rf or 0) + (rt - (e.rf or 0)) * 0.7              -- (Test 32) quicker, to stop in time
    end
    e.rt, e.rf = e.rt or 0, e.rf or 0
    local extra = 25 * trav - GUN_CAP
    local want
    local straining = e.helping and math.abs(e.rf) >= 0.9 * GUN_CAP and e.rf * (e.mr or 0) >= 0
        or not e.helping and math.abs(e.rt) >= 0.8 * GUN_CAP
    if extra > 2 and straining then
        want = (e.rt > 0 and 1 or -1) * extra
        if not e.helping then e.helping = true; help_seen.times = help_seen.times + 1 end
    else
        e.helping = false
        want = math.max(-HELP_RETURN, math.min(HELP_RETURN, -math.deg(m) * 1))
    end
    local mr = e.mr or 0
    -- speeding up (same direction, more): HELP_ACCEL; slowing down or turning round: HELP_STOP
    local step = ((want * mr >= 0 and math.abs(want) > math.abs(mr)) and HELP_ACCEL or HELP_STOP) * dt
    mr = mr + math.max(-step, math.min(step, want - mr))
    e.mr = mr
    m = wrap(m + math.rad(mr * dt))
    if math.abs(m) < 1e-5 and math.abs(mr) < 1e-3 then m = 0 end
    e.m = m
    -- (3.1.1 review) e.hl_tn keeps the gun's own heading against its mount as read this frame (a - the mount it stood on);
    -- 3.1.0 reset it to a - the new mount here, so the next frame's "gun's own turn" included the mount's own push, and
    -- the help went on pushing until the gun slowed under ~12 deg/s instead of 41 (2 deg overshoot with a gun that eases in)
    set_mount(u, e, m)
    if math.abs(mr) > help_seen.extra + 1 or math.abs(math.deg(m)) > help_seen.offset + 1 then
        help_seen.extra = math.max(help_seen.extra, math.abs(mr)); help_seen.offset = math.max(help_seen.offset, math.abs(math.deg(m)))
        S.seen_changed = true
    end
end

local function turn(u, e, a)
    -- (3.1.0 review) the turret hasn't moved since the last write (within 0.006 deg): nothing to write
    if e.ta and math.abs(a - e.ta) < 1e-4 then return end
    local yaw = Q(V3(0, 0, 1), a)
    local t = e.turn
    local ok = pcall(U.set_local_rotation, u, t.i, Q.multiply(yaw, Q.from_elements(t.q[1], t.q[2], t.q[3], t.q[4])))
    local c, s = math.cos(a), math.sin(a)
    for _, n in ipairs(e.carry) do
        local dx, dy = n.x - AXIS_X, n.y - AXIS_Y
        ok = pcall(U.set_local_position, u, n.i, V3(AXIS_X + dx * c - dy * s, AXIS_Y + dx * s + dy * c, n.z)) and ok
        ok = pcall(U.set_local_rotation, u, n.i, Q.multiply(yaw, Q.from_elements(n.q[1], n.q[2], n.q[3], n.q[4]))) and ok
    end
    e.ta = ok and a or nil                -- (3.1.1 review: only a pose that was written is skipped next time)
end
-- (3.1.1 review) every node back at its rest pose (the shutdown below)
local function rest(u, e)
    pcall(U.set_local_rotation, u, e.turn.i, Q.from_elements(e.turn.q[1], e.turn.q[2], e.turn.q[3], e.turn.q[4]))
    pcall(U.set_local_rotation, u, e.mount.i, Q.from_elements(e.mount.q[1], e.mount.q[2], e.mount.q[3], e.mount.q[4]))
    for _, n in ipairs(e.carry) do
        pcall(U.set_local_position, u, n.i, V3(n.x, n.y, n.z))
        pcall(U.set_local_rotation, u, n.i, Q.from_elements(n.q[1], n.q[2], n.q[3], n.q[4]))
    end
    e.ta, e.ms = nil, nil
end

local list, next_list, shown = {}, 0, -1
local function tick()
    S.frames = S.frames + 1
    if not api_ok() then if S.frames == 1 then log() end; return end
    local world = A.main_world()
    if world == nil then return end
    if S.clock >= next_list then
        next_list = S.clock + HULL_EVERY
        list = {}
        local listed = {}
        for _, h in ipairs(HULLS) do
            local ok, us = pcall(W.units_by_resource, world, h.res)
            for _, u in ipairs(ok and type(us) == 'table' and us or {}) do list[#list + 1] = {u = u, h = h}; listed[u] = true end
        end
        -- (3.1.1 review) units no longer out are forgotten; the rest are written again once (e.ta / e.ms cleared), so a pose
        -- the game itself put back (a turret parked since) is set right within half a second
        for u, e in pairs(hulls) do
            if not listed[u] then hulls[u] = nil else e.ta, e.ms = nil, nil end
        end
    end
    local tanks, turned, no_gun, bad, no_seat = 0, 0, 0, 0, 0
    local t_now = nil
    for _, it in ipairs(list) do
        local u = it.u
        local oka, alive = pcall(U.alive, u)
        if oka and alive then
            tanks = tanks + 1
            local e = hulls[u]
            if e and e.kind ~= it.h then e = nil end          -- (3.1.1 review: another tank at that unit's place)
            if not e then e = setup(u, it.h); hulls[u] = e end
            if not e.ok then bad = bad + 1
            else
                if e.gun then
                    local okg, ga = pcall(U.alive, e.gun)
                    if not (okg and ga) then e.gun = nil end
                end
                if not e.gun and S.clock >= e.next_gun then
                    find_gun(u, e, world)
                    -- (3.1.1 review) a gun that stays missing is looked for less often (the Bastion's search asks the whole world)
                    e.gun_misses = e.gun and 0 or e.gun_misses + 1
                    e.next_gun = S.clock + (e.gun_misses >= GUN_MISSES and GUN_SLOW or GUN_EVERY)
                end
                local a, hy
                if e.gun then a, hy = heading(u, e) end
                if a then turn(u, e, a); turned = turned + 1; if e.no_seat then no_seat = no_seat + 1 end else no_gun = no_gun + 1 end
                if TESTER then S.angle[u], S.gun[u] = a, e.gun end
                if a then t_now = t_now or now_s(); rates(e, a, it.h, t_now, hy); help(u, e, a, t_now) else e.last_t, e.hl_t = nil, nil; if (e.m or 0) ~= 0 then e.m, e.mr = 0, 0; set_mount(u, e, 0) end end
            end
        elseif oka then
            hulls[u] = nil                                       -- (3.1.1 review: a destroyed tank's entry goes at once)
        end
    end
    -- (3.1.0 review) the log is rewritten when a count changes (compared as numbers: no new text every frame)
    local changed = tanks ~= S.tanks or turned ~= S.turned or no_gun ~= S.no_gun or bad ~= S.bad_nodes or no_seat ~= S.no_seat
        or S.errors ~= shown
    S.tanks, S.turned, S.no_gun, S.bad_nodes, S.no_seat = tanks, turned, no_gun, bad, no_seat
    S.status = tanks == 0 and 'no tank out' or (turned == tanks and 'turning' or 'turning, some turrets not (see below)')
    if changed or (S.seen_changed and S.clock >= (S.next_seen_log or 0)) then
        shown = S.errors; S.seen_changed = false; S.next_seen_log = S.clock + 2; log()
    end
end

local previous_update = update
if type(previous_update) ~= 'function' then return end
local function after(ok, ...)
    if not ok then error((...), 0) end
    local okT, err = pcall(tick)
    if not okT then
        S.errors = S.errors + 1; S.last_error = tostring(err); S.status = 'error: ' .. tostring(err)
        if S.errors <= 20 then log() end
    end
    return ...
end
update = function(dt, ...)
    S.clock = S.clock + ((type(dt) == 'number' and dt > 0 and dt < 0.5) and dt or 1 / 60)   -- (3.1.1 review: seconds)
    return after(pcall(previous_update, dt, ...))
end
-- (3.1.1 review) the game closing (or this Lua being rebuilt): every turret still out is put back at rest, so a new copy
-- of this addon finds the hulls as the game made them (see setup for when this doesn't run)
do
    local previous_shutdown = shutdown
    shutdown = function(...)
        pcall(function()
            if S.api ~= 'ok' then return end
            for u, e in pairs(hulls) do
                local oka, alive = pcall(U.alive, u)
                if oka and alive and e.ok then rest(u, e) end
            end
            hulls = {}
            S.status = 'stopped (game closing): turrets put back at rest'
        end)
        if type(previous_shutdown) == 'function' then return previous_shutdown(...) end
    end
end
log()

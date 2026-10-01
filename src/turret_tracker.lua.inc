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
local function tt_comps(v)
    local ok, x, y, z = pcall(function() return v.x, v.y, v.z end)
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
        TT.pick = string.format('%d %s tanks out: the one %.1f m from your camera (%d camera(s))', #hulls, name, math.sqrt(bd), #cam_pos)
        return hulls[best]
    end
    TT.pick = string.format('%d %s tanks out, no camera near them (%d camera(s)): using the first', #hulls, name, #cam_pos)
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
    local t = TT.TANKS[kind]
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
                local okn, has = pcall(U.has_node, u, TT.GUN_NODE)
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
    local okn, idx = pcall(U.node, gun, TT.GUN_NODE)
    local f = TT.found
    f.unit, f.gun, f.kind, f.gun_node = hull, gun, kind, okn and idx or 1
    TT.tank = t.name .. ' found' .. (okn and '' or ' (no traverse node; using the gun root)')
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
    if (TT.want_up or (type(pub) == 'table' and pub.want_up)) and Q.up then
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
    if not oka then TT.errors = TT.errors + 1; TT.last_error = 'turret angle failed: ' .. tostring(a); f.unit = nil; return nil, 'error' end
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
    local t = TT.TANKS[kind]
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

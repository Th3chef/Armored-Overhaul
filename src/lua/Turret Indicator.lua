-- HD2-Addon: mods/chef/armored_overhaul_indicator
-- Armored Overhaul 3.2.0 - Vehicle Indicator option: while you sit in a TD-220 Bastion, TD-110 Maelstrom, M-102
-- FRV or M-103 Supply FRV (any seat), a small outline on your screen shows which way the turret points compared to the
-- hull, like a real tank's display, colored by the vehicle's health (the FRV's tires too). The turret always points
-- up; the hull outline turns around it, with a notch at its front. Drawn only on your screen. Written from scratch.
-- (Built from indicator.lua.in, which holds the Turret indicator and the driver panel: they share the drawing code.)
--
-- Drawn the way HD2 HUD+ puts its widgets on screen: a retained screen GUI created in the game's overlay
-- world (the world in Application.worlds() that is not the main game world; Test 3 drew into the main world, which
-- never shows), with World.create_screen_gui(world, 'scale', 1, 1). Screen-GUI triangles take their points as
-- Vector3(x, depth, y) with y up from the bottom of the screen, and a layer. Shapes are only rebuilt when what they
-- show changes.
--
-- Where you sit comes from the Tank Core addon (it reads the game's seat table and publishes the seat as
-- ArmoredOverhaulSeat). The tank's hull and gun are found through the engine's Lua API (World.units_by_resource and
-- the gun's 'traverse' node). With two or more of the same tank out, yours is the one nearest your camera.
if type(jit) == 'table' and type(jit.off) == 'function' then jit.off(true, true) end
if rawget(_G, 'ArmoredOverhaulIndicator') then return end

local TESTER = false
local cos, sin, sqrt, floor, max, pi = math.cos, math.sin, math.sqrt, math.floor, math.max, math.pi

local SEAT_FRESH = 45                -- frames a published seat stays valid (the core refreshes it every few frames)
local RECHECK_EVERY = 60             -- frames between checks of the overlay world and the screen size
local CORE_STALL = 60                -- frames without a Tank Core update before its seat is no longer trusted

local TITLE, LOG_FILE = 'Vehicle Indicator', 'ArmoredOverhaul-TurretIndicator.log'
-- (3.0.0) no settings file (2.0-2.1 wrote and read ArmoredOverhaul-TurretIndicator.cfg; a file an older version
-- wrote is left alone and not read). (3.0) The Mod Options Menu can turn it off (see menu_rows). x, y: the outline's centre as shares of the screen (0 = left / bottom edge);
-- size: the hull's length as a share of the screen height; dock: just left of the driver panel when its addon runs.
-- (Test 6: moved off the bottom centre, where it covered the game's kill chain counter; thinner and see-through)
local SETTINGS = {show = 1, x = 0.1, y = 0.3, size = 0.075, opacity = 0.55, health = 1, dock = 1, skull = 1}
local PANEL_DEFAULT = {x = 0.5, y = 0.1, size = 0.022}   -- (3.1.0 Test 26) the Driver Panel's default place (its SETTINGS)

local S = {version = '3.2.0', status = 'starting', api = 'unchecked', gui = 'none', tank = 'none', seat = 'none',
           angle = 'none', shapes = 'none', last_error = 'none', frames = 0, drawn = 0, finds = 0, errors = 0,
           options_menu = 'not installed (the defaults are used)',
           pick = 'none', gear = 'hidden', panel = 'none', font = 'not needed yet', input = 'keyboard', input_api = 'unchecked',
           speed = 'not measured yet', speed_check = 'none', health = 'not shown yet', tires = 'not in an FRV yet', skull = 'not shown yet', dock = 'not shown yet'}
rawset(_G, 'ArmoredOverhaulIndicator', S)

local loader = rawget(_G, 'CowboyBingusModLoader')
if type(loader) ~= 'table' or type(loader.version) ~= 'number' or loader.version < 15 then return end
local SR = rawget(_G, 'stingray')

-- ---------------------------------------------------------------- log and settings
-- The log is what a user attaches to a bug report: whether the engine offers what the option needs, where it
-- draws, the settings, your seat and tank, and what went wrong. Tester builds add counters and details.
local LOG_MAIN = {'version', 'status', 'api', 'gui', 'options_menu', 'seat', 'tank', 'pick', 'angle', 'health', 'tires', 'skull', 'dock', 'errors', 'last_error'}
local LOG_TESTER = {'frames', 'drawn', 'finds', 'shapes', 'hulls', 'hull_changes', 'tilts', 'tips'}
local notes, test_notes = {}, {}
local function note(s)
    for _, n in ipairs(notes) do if n == s then return end end
    if #notes < 20 then notes[#notes + 1] = s end
end
local function test_note(s) if #test_notes < 20 then test_notes[#test_notes + 1] = s end end
-- (3.0.1 review) the file is written only when its text changed (3.0 rewrote it on every tank search, every 5 s
-- while a gun could not be found)
local log_text
local function log()
    pcall(function()
        local b = {'Armored Overhaul - ', TITLE, '\n'}
        for _, k in ipairs(LOG_MAIN) do b[#b + 1] = (k:gsub('_', ' ')) .. ': ' .. tostring(S[k]) .. '\n' end
        for _, n in ipairs(notes) do b[#b + 1] = 'note: ' .. n .. '\n' end
        if TESTER then
            b[#b + 1] = '-- tester details --\n'
            for _, k in ipairs(LOG_TESTER) do b[#b + 1] = k .. ': ' .. tostring(S[k]) .. '\n' end
            for _, n in ipairs(test_notes) do b[#b + 1] = 'note: ' .. n .. '\n' end
        end
        local text = table.concat(b)
        if text == log_text then return end
        local f = loader.open_log and loader.open_log(LOG_FILE)
        if not f then return end
        f:write(text)
        f:close()
        log_text = text
    end)
end

local function logs_path(name)
    local root = os.getenv and os.getenv('LOCALAPPDATA')
    return root and root ~= '' and (root .. '\\CowboyBingus\\Helldivers2\\Logs\\' .. name) or nil
end
local settings = {sig = 0}             -- the values in use; sig changes with every change (the outline is redrawn)
for k, v in pairs(SETTINGS) do settings[k] = v end
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
    for _, g in ipairs({'indicator'}) do
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
        if frame < at then return end
        at = frame + 60
        local mine = true
        for _, g in ipairs({'indicator'}) do if not hub.done[g] then mine = false end end
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
menu_rows.indicator = {
    {'armored_overhaul.indicator', {type = 'toggle', label = 'Vehicle Indicator', default = true, description = 'A small outline of your vehicle shows where the gun points compared to the hull, colored by health (blue to red). Works in the Bastion, the Maelstrom, the M-102 FRV and the M-103 Supply FRV, in any seat; the FRVs\' tires each show their own health and go clear when popped. Only you see it.'}, 'show'},
}
menu_set = function(key, v)
    if key == 'show' then settings.show = (v == true or v == 1) and 1 or 0; settings.sig = settings.sig + 1 end
end

-- ---------------------------------------------------------------- engine API (checked once; the option stays off
-- and says why if this game build lacks something)
local A, W, U, G, Q, V3, V2, C
local function api_ok()
    if S.api == 'ok' then return true end
    if S.api ~= 'unchecked' then return false end
    if type(SR) ~= 'table' then S.api = 'missing: stingray'; return false end
    A, W, U, G, Q, V3, V2, C = SR.Application, SR.World, SR.Unit, SR.Gui, SR.Quaternion, SR.Vector3, SR.Vector2, SR.Color
    local need = {
        {A, 'Application', 'main_world'}, {A, 'Application', 'worlds'}, {W, 'World', 'create_screen_gui'},
        {G, 'Gui', 'triangle'}, {G, 'Gui', 'destroy_triangle'},
        {W, 'World', 'units_by_resource'}, {U, 'Unit', 'world_rotation'}, {U, 'Unit', 'world_position'}, {U, 'Unit', 'alive'},
        {U, 'Unit', 'node'}, {U, 'Unit', 'has_node'}, {Q, 'Quaternion', 'forward'}, {Q, 'Quaternion', 'right'},
    }
    local missing = {}
    for _, n in ipairs(need) do
        if type(n[1]) ~= 'table' or (type(n[1][n[3]]) ~= 'function' and type(n[1][n[3]]) ~= 'userdata') then
            missing[#missing + 1] = n[2] .. '.' .. n[3]
        end
    end
    local okv = pcall(V3, 1, 2, 3)
    local okc = pcall(C, 255, 1, 2, 3)
    if not okv then missing[#missing + 1] = 'Vector3()' end
    if not okc then missing[#missing + 1] = 'Color()' end
    if #missing > 0 then S.api = 'missing: ' .. table.concat(missing, ', '); S.status = 'off (this game build lacks what it needs)'; return false end
    S.api = 'ok'
    -- (tester builds) which mesh and material functions this game build offers: research for turret damage looks,
    -- which would copy the hull's damage state (its material's DamageMaskSelector / VehicleDamage) onto the turret
    if TESTER then
        pcall(function()
            local function names(t, pat)
                local out = {}
                if type(t) == 'table' then for k in pairs(t) do if type(k) == 'string' and (not pat or k:lower():find(pat)) then out[#out + 1] = k end end end
                table.sort(out)
                return #out > 0 and table.concat(out, ' ') or '-'
            end
            test_note('api: Unit mesh/material: ' .. names(U, 'mesh') .. ' | ' .. names(U, 'material'))
            test_note('api: Mesh: ' .. names(SR.Mesh))
            test_note('api: Material: ' .. names(SR.Material))
            test_note('api: Camera: ' .. names(SR.Camera) .. ' | Application: ' .. names(A))
        end)
    end
    return true
end



-- ---------------------------------------------------------------- the overlay screen GUI (as HD2 HUD+ does it)
local LAYER, DEPTH = 3, 0
local TRI_MATERIAL = 'core/performance_hud/debug'   -- the engine's own debug GUI material (used if a plain triangle fails)
local ov = {world = nil, gui = nil, ids = {}, bitmaps = {}, key = nil, style = nil, visible = nil}
local draw_fails = 0                                -- drawing failures this session (turn it off at a limit)
-- One look at the engine's world list: the overlay world (the one that is not the main world), and whether `w` is
-- still in the list (nil: the list could not be read, so not known).
local function scan_worlds(main, w)
    local okw, worlds = pcall(A.worlds)
    if not okw or type(worlds) ~= 'table' then return nil, 0, nil end     -- (3.0.1 review: not known, not 'gone')
    local target, live = nil, false
    for i = 1, #worlds do
        local x = worlds[i]
        if x ~= nil and x ~= main and not target then target = x end
        if w ~= nil and x == w then live = true end
    end
    return target, #worlds, live
end
-- (2.0.1 review) Everything this addon keeps of a screen GUI, forgotten without touching the engine: for a GUI whose
-- world is gone (2.0 forgot only part of it, then later destroyed the old skull and panel ids on the new GUI).
local function forget_gui()
    ov.gui, ov.world, ov.visible, ov.alive_frame = nil, nil, nil, nil
    ov.ids, ov.bitmaps, ov.key = {}, {}, nil
end
-- (2.0.1 review) Before shapes are destroyed or the GUI hidden outside the draw path (leaving the seat, errors): is the
-- GUI's world still one of the engine's worlds? Checked at most once a frame; a GUI whose world is gone is forgotten,
-- never touched. (The draw path relies on overlay_gui's own check, which also runs at once when the main world changes.)
local function gui_alive()
    if not ov.gui then return false end
    if ov.alive_frame == S.frames then return true end
    local _, _, live = scan_worlds(nil, ov.world)
    -- (3.0.1 review) the world list unreadable: not touched now, but kept (3.0 forgot it and left its shapes on screen)
    if live == nil then return false end
    if not live then forget_gui(); return false end
    ov.alive_frame = S.frames
    return true
end
local function clear_shapes(checked)
    if ov.gui and not checked and not gui_alive() then return end
    if ov.gui then for _, id in ipairs(ov.ids) do pcall(G.destroy_triangle, ov.gui, id) end end
    if ov.gui and ov.bitmaps then for _, id in ipairs(ov.bitmaps) do pcall(G.destroy_bitmap, ov.gui, id) end end
    ov.ids, ov.key, ov.bitmaps = {}, nil, {}
end
local function set_visible(v)
    if ov.gui and ov.visible ~= v and G.set_visible and gui_alive() then
        if pcall(G.set_visible, ov.gui, v) then ov.visible = v end
    end
end
local function overlay_gui(main)
    if ov.gui and S.frames < (ov.next_check or 0) then return ov.gui end     -- checked once a second
    if main == nil then return nil end
    ov.next_check = S.frames + RECHECK_EVERY
    local target, count, live = scan_worlds(main, ov.world)
    -- (3.0.1 review) the world list unreadable: nothing drawn this frame, the GUI kept, and checked again next frame
    if live == nil then ov.next_check = 0; S.gui = 'world list unreadable'; return nil end
    -- (2.0.1 review) a GUI whose world is still there and isn't the main world is kept, even when another world now
    -- comes first in the list (2.0 moved it to whichever non-main world came first)
    if ov.gui and live and ov.world ~= main then ov.alive_frame = S.frames; return ov.gui end
    -- the old GUI goes with its world; a GUI in a world that is gone is forgotten, never touched
    if ov.gui and live then
        clear_shapes(true)
        if W.destroy_gui then pcall(W.destroy_gui, ov.world, ov.gui) else pcall(G.set_visible, ov.gui, false) end
    end
    forget_gui()
    if not target then S.gui = 'no overlay world (' .. tostring(count) .. ' world(s))'; return nil end
    local ok, g = pcall(W.create_screen_gui, target, 'scale', 1, 1)
    if not ok or g == nil then S.gui = 'create_screen_gui failed: ' .. tostring(g); return nil end
    ov.gui, ov.world, ov.alive_frame = g, target, S.frames
    S.gui = string.format('screen gui in the overlay world (%d world(s))', count)
    return g
end
local function read_screen_size()
    if G.resolution then
        local ok, w, h = pcall(G.resolution)
        if ok and type(w) == 'number' and type(h) == 'number' and w > 100 and h > 100 then return w, h end
    end
    for _, n in ipairs({'back_buffer_size', 'resolution'}) do
        local f = A and A[n]
        if f then
            local ok, w, h = pcall(f)
            if ok and type(w) == 'number' and type(h) == 'number' and w > 100 and h > 100 then return w, h end
        end
    end
    return 1920, 1080
end
local screen = {w = 1920, h = 1080, next_check = 0}
local function screen_size()                                  -- checked once a second
    if S.frames >= screen.next_check then screen.w, screen.h = read_screen_size(); screen.next_check = S.frames + RECHECK_EVERY end
    return screen.w, screen.h
end
local function P(x, y) return V3(x, DEPTH, y) end         -- a screen point: x from the left, y up from the bottom
local function tri(g, a, b, c, color)
    local id
    if ov.style == nil or ov.style == 'plain' then
        local ok, r = pcall(G.triangle, g, a, b, c, LAYER, color)
        if ok then ov.style = 'plain'; id = r
        elseif ov.style == nil then
            ov.style = 'material'; note('plain Gui.triangle failed (' .. tostring(r) .. '); using ' .. TRI_MATERIAL)
        else error(r) end
    end
    if ov.style == 'material' then
        local uv = V2(0, 0)
        id = G.triangle(g, a, b, c, LAYER, color, TRI_MATERIAL, uv, uv, uv)
    end
    if id ~= nil then local sink = ov.sink or ov.ids; sink[#sink + 1] = id end
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
    -- (2.1) the FRV (FRV Gunner Drive): the Driver panel measures its speed (TT.hull) and the Turret indicator shows
    -- its machine gun's direction and its health. Kept apart from TANKS: the Gunner camera is tanks only.
    HULLS = {[0x1A] = {name = 'FRV', hull = 'content/fac_helldivers/vehicles/frv/frv',
                       gun = 'content/fac_helldivers/vehicles/frv/armaments/frv_mg/frv_mg', gun_node = 'horizontal_axis'}},
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
    -- (3.1.1 review: the Vehicle Indicator never asks for the up axis itself; the Gunner camera sets pub.want_up)
    return angle, why
end

local TANKS = TT.TANKS
local FRV_KIND = 0x1A          -- (2.1) the FRV: its outline (FRV shape, its gun, its tires) shows in any seat
-- (2.1 Test 15) the FRVs: the M-102 and the M-103 Supply FRV (0x1B). The M-103 has no gun: its outline points
-- ahead (angle 0, nothing to track) and is drawn without the gun line
local FRV_KINDS = {[FRV_KIND] = 'FRV', [0x1B] = 'M-103 Supply FRV'}
local GUNLESS = {[0x1B] = true}
local GUNLESS_TEXT = 'M-103 Supply FRV (no gun: shown pointing ahead)'
-- (2.1 Test 13) each FRV tire's band (Tank Core's SEAT_PUB.tires: share of full health, -1 popped): 1-5 the health
-- bands, 0 popped, 6 not known (the hull's color); kept as one number too, so a change redraws the outline
local core_watch = {}

-- ---------------------------------------------------------------- drawing
-- (made in each frame that draws, never kept from one frame to the next: the engine's Color, Vector3 and
-- IdString64 values only live for the frame they are made in)
local GREY, YELLOW, SHADOW
local colors_frame
local function colors(opacity)
    if colors_frame == S.frames then return end
    colors_frame = S.frames
    GREY = C(floor(235 * opacity + 0.5), 215, 220, 224)
    YELLOW = C(floor(245 * opacity + 0.5), 255, 231, 16)
    SHADOW = C(floor(110 * opacity + 0.5), 0, 0, 0)
end
-- (1.3) the hull outline's color by the tank's health (Tank Core reads it as the game's driver HUD does): above 80%
-- blue, above 60% green, above 40% yellow, above 20% orange, else red
local HEALTH_BANDS = {{0.8, 'blue', 60, 150, 255}, {0.6, 'green', 70, 210, 90}, {0.4, 'yellow', 255, 225, 30},
                      {0.2, 'orange', 255, 140, 20}, {-1, 'red', 235, 45, 35}}
local function health_band(share)
    if type(share) ~= 'number' then return nil end
    for i, b in ipairs(HEALTH_BANDS) do if share > b[1] then return i end end
    return #HEALTH_BANDS
end
local tire_bands = {6, 6, 6, 6}
local TIRE_NAMES = {'front left', 'front right', 'rear left', 'rear right'}
local WHEEL_X, WHEEL_Y = {-1, 1, -1, 1}, {1, 1, -1, -1}
local function tire_code(seat, use_health)
    local t, code = seat.tires, 0
    for i = 1, 4 do
        local s = type(t) == 'table' and t[i] or nil
        local b = 6
        if s == -1 then b = 0 elseif use_health and type(s) == 'number' then b = health_band(s) or 6 end
        tire_bands[i] = b; code = code * 8 + b
    end
    return code
end

-- a thick line from (x1,y1) to (x2,y2) as two triangles
local function line(g, x1, y1, x2, y2, w, color)
    local dx, dy = x2 - x1, y2 - y1
    local l = sqrt(dx * dx + dy * dy)
    if l < 1e-3 then return end
    local nx, ny = -dy / l * w / 2, dx / l * w / 2
    local a, b = P(x1 + nx, y1 + ny), P(x2 + nx, y2 + ny)
    local c, d = P(x2 - nx, y2 - ny), P(x1 - nx, y1 - ny)
    tri(g, a, b, c, color); tri(g, a, c, d, color)
end

-- (2.0) The turret drawn as the game's own round-eyed Helldivers skull. The game loads its skull images only in the
-- menu (2.0.0 Test 5-7: the menu's header_icon and the mission HUD's skull both 'not loaded' in a mission), so the
-- option ships a copy of the menu's header skull as its own texture (mods/chef/armored_overhaul_skull, c150fa7273a7e9b7,
-- 64 px white with alpha, in the option's Turret Skull folder). It is drawn with one of the game's single-texture UI materials that
-- is loaded in a mission (first that can_get finds: content/ui/shared/misc/yellow_logo e2d6ed90906c1e8b, then the
-- HUD's skull material c99891cc3dd4e438; texture slot 3aa8b87e in both), whose copy in this screen GUI gets the skull
-- bound every drawing frame (Gui.material + Material.set_texture), the way the driver panel uses the HUD font.
-- Ids are made fresh each frame (they only live for the frame). Safety net as for the font: a marker file says
-- 'trying' until the skull has been shown 600 frames; if the game closed in between, the next start uses the octagon
-- once. (settings.skull = 0 would turn it off; it is fixed on.)
local SKULLS = {
    {name = 'the skull', mat = 'e2d6ed90906c1e8b', tex = 'c150fa7273a7e9b7', slot = '3aa8b87e00000000', scale = 0.42},
    {name = 'the skull (HUD material)', mat = 'c99891cc3dd4e438', tex = 'c150fa7273a7e9b7', slot = '3aa8b87e00000000', scale = 0.42},
}
local sk = {}
local function skullcheck(write)
    local path = logs_path('ArmoredOverhaul-TurretIndicator.skullcheck')
    if not path or not io or not io.open then return nil end
    if write then local f = io.open(path, 'w'); if f then f:write(write); f:close() end; return end
    local f = io.open(path, 'r'); if not f then return nil end
    local t = f:read('*a'); f:close(); return t
end
local function loaded(kind, hex)
    local okid, v = pcall(SR.IdString64.from_hex, hex)
    if not okid then return false end
    local okc, yes = pcall(A.can_get, kind, v)
    return okc and yes == true
end
-- the skull marker says ok after 600 frames on screen, or when the skull leaves the screen normally after 30 or more
local function skull_proven()
    if sk.watch and sk.watch <= 570 then sk.watch = nil; skullcheck('ok\n') end
end
-- (3.0.1 review) the skull refused without the game closing: the octagon for now, and the marker no longer says
-- 'trying' (3.0 left it, so the next start skipped the skull, saying the game had closed)
local function skull_refused(why)
    sk.off, sk.why, sk.watch, S.skull = true, why, nil, why
    skullcheck('refused\n')
end
-- the material for this frame (with the skull bound to it when the pick needs that) and its size scale, or nil (octagon)
local function skull_material(g, set)
    if set.skull < 0.5 then S.skull = 'off'; return nil end
    if sk.gui ~= g then
        -- (3.0.1 review) a try in the previous GUI (a mission loaded or left) is settled first: its 'trying' marker
        -- read as a crash here (this GUI went to the octagon) and at the next start
        if sk.watch then skull_proven(); if sk.watch then skullcheck('interrupted\n') end end
        sk = {gui = g}
        local last = skullcheck()
        if last and last:find('^trying') then
            skullcheck('skipped once\n'); S.skull = 'octagon for now (the last try ended with the game closing; tried again next start)'
            sk.off = true; sk.why = S.skull; return nil
        end
        local ID, M = SR.IdString64, SR.Material
        if not (ID and ID.from_hex and G.bitmap and G.destroy_bitmap and A.can_get and V2) then
            S.skull = 'octagon (this game version lacks a bitmap function)'; sk.off = true; sk.why = S.skull; return nil
        end
        local tried = {}
        for _, c in ipairs(SKULLS) do
            local lm, lt = loaded('material', c.mat), not c.tex or loaded('texture', c.tex)
            local ok = lm and lt and (not c.tex or (G.material and M and M.set_texture ~= nil))
            tried[#tried + 1] = 'material ' .. c.mat .. (lm and ' loaded' or ' not loaded')
                .. (c.tex and (', texture ' .. c.tex .. (lt and ' loaded' or ' not loaded')) or '')
            if ok and not sk.pick then sk.pick = c end
        end
        sk.tried = table.concat(tried, '; ')
        if not sk.pick then S.skull = 'octagon (no skull loaded: ' .. sk.tried .. ')'; sk.off = true; sk.why = S.skull; return nil end
        skullcheck('trying\n'); sk.watch = 600
    end
    if sk.off then S.skull = sk.why or S.skull; return nil end
    if sk.frame ~= S.frames then
        sk.frame, sk.m = S.frames, nil
        local c, ID = sk.pick, SR.IdString64
        local okm, m = pcall(ID.from_hex, c.mat)
        if not okm or not m then skull_refused('octagon (ids unusable)'); return nil end
        if c.tex then
            local okt, t = pcall(ID.from_hex, c.tex)
            local oks, slot = pcall(ID.from_hex, c.slot)
            local okg, mh = false, nil
            if okt and oks then okg, mh = pcall(G.material, g, m) end
            if not okg or mh == nil or not pcall(SR.Material.set_texture, mh, slot, t) then skull_refused('octagon (the UI material was refused)'); return nil end
        end
        sk.m = m
    end
    return sk.m, sk.pick.scale
end
local function draw(g, sw, sh, set, angle, band, frv, tires, nogun, place)
    colors(set.opacity)
    local b = band and HEALTH_BANDS[band]
    local HULL = b and C(floor(245 * set.opacity + 0.5), b[3], b[4], b[5]) or GREY
    local cx, cy = set.x * sw, set.y * sh
    local L = set.size * sh                          -- hull length in pixels
    -- (2.0) docked: just left of the driver panel (its left edge is 6.3 letter heights left of its centre, and its
    -- middle 0.5 below it), with room for the outline turned any way (0.6 hull lengths) and a gap. (3.0.1 review)
    -- `place`: the panel's place when tick found the panel can show in this vehicle, else nil (its own spot)
    if place then
        local u = place.size * sh
        cx, cy = place.x * sw - 6.3 * u - 1.2 * u - 0.6 * L, place.y * sh - 0.5 * u
    end
    local Wd = L * 0.62
    -- (2.0) the hull outline is drawn thick, like the tank's armour, so its health color reads at a glance; the
    -- corners are filled so the thick sides join cleanly (1.1-1.3: thin lines, max(1.2, L x 0.018))
    local th = max(3, L * 0.065)
    -- the turret always points up, so the hull turns the other way round: a turret turned right leaves the hull's
    -- front to the left. Screen y goes up, so a positive angle here turns the hull anticlockwise.
    local a = angle
    local ca, sa = cos(a), sin(a)
    local function R(x, y) return cx + x * ca - y * sa, cy + x * sa + y * ca end
    local hx, hy = Wd / 2, L / 2
    -- the armour: four mitred quads between the outer and the inner edge (no overlaps, so the see-through color is
    -- even all round), and the front marker as a filled wedge inside the front edge
    local function quad(ax, ay, bx, by, cx2, cy2, dx, dy, col)
        local x1, y1 = R(ax, ay); local x2, y2 = R(bx, by); local x3, y3 = R(cx2, cy2); local x4, y4 = R(dx, dy)
        local p1, p3 = P(x1, y1), P(x3, y3)           -- (3.0 review: the shared corners made once, 4 points not 6)
        tri(g, p1, P(x2, y2), p3, col); tri(g, p1, p3, P(x4, y4), col)
    end
    for pass = 1, 2 do
        local col = pass == 1 and SHADOW or HULL
        local grow = pass == 1 and 1 or 0                                    -- the dark edge: 1 px all round
        local ox, oy, ix, iy = hx + th / 2 + grow, hy + th / 2 + grow, hx - th / 2 - grow, hy - th / 2 - grow
        quad(-ox, -oy, ox, -oy, ix, -iy, -ix, -iy, col)                       -- back
        quad(ox, -oy, ox, oy, ix, iy, ix, -iy, col)                           -- right
        quad(ox, oy, -ox, oy, -ix, iy, ix, iy, col)                           -- front
        quad(-ox, oy, -ox, -oy, -ix, -iy, -ix, iy, col)                       -- left
        -- (2.1) the FRV: a wheel outside each corner, so it reads as the FRV at a glance. (Test 13) Each tire in its
        -- own health color (the hull's when not known); a popped tire is clear: only a thin outline
        if frv then
            local ww, wl = L * 0.07 + grow, L * 0.13 + grow
            for i = 1, 4 do                    -- front left, front right, rear left, rear right (WHEEL_X/Y: no tables made)
                local wxc, wyc = WHEEL_X[i] * (hx + th / 2 + L * 0.06), WHEEL_Y[i] * hy * 0.68
                local tb = tires and tires[i] or 6
                if tb == 0 then
                    if pass == 2 then
                        local lw = max(1, L * 0.014)
                        local ax, ay = R(wxc - ww, wyc - wl); local bx, by = R(wxc + ww, wyc - wl)
                        local cx2, cy2 = R(wxc + ww, wyc + wl); local dx, dy = R(wxc - ww, wyc + wl)
                        line(g, ax, ay, bx, by, lw, GREY); line(g, bx, by, cx2, cy2, lw, GREY)
                        line(g, cx2, cy2, dx, dy, lw, GREY); line(g, dx, dy, ax, ay, lw, GREY)
                    end
                else
                    local tc = col
                    if pass == 2 and tb >= 1 and tb <= 5 then
                        local hb = HEALTH_BANDS[tb]; tc = C(floor(245 * set.opacity + 0.5), hb[3], hb[4], hb[5])
                    end
                    quad(wxc - ww, wyc - wl, wxc + ww, wyc - wl, wxc + ww, wyc + wl, wxc - ww, wyc + wl, tc)
                end
            end
        end
        local fy = hy - th / 2
        local wx, wy = hx * 0.42 + grow, fy - L * 0.15 - grow
        local x1, y1 = R(-wx, fy); local x2, y2 = R(wx, fy); local x3, y3 = R(0, wy)
        tri(g, P(x1, y1), P(x2, y2), P(x3, y3), col)
    end
    th = max(1.2, L * 0.018)                         -- (the gun line below keeps its own width)
    -- turret: the game's skull icon (else a filled octagon), with the gun pointing straight up
    local r = L * 0.11
    local skm, scale = skull_material(g, set)
    if skm then
        local size = L * scale
        local okb, id = pcall(G.bitmap, g, skm, V3(cx - size / 2, cy - size / 2, LAYER + 2), V2(size, size), C(floor(255 * set.opacity + 0.5), 255, 255, 255))
        if okb and id ~= nil then
            -- (3.0.1 review) the log text made once per GUI (3.0: on every redraw, every frame while the turret turns)
            ov.bitmaps[#ov.bitmaps + 1] = id
            if not sk.text then sk.text = sk.pick.name .. ' (' .. sk.tried .. ')' end
            S.skull = sk.text
            -- the gun line from the skull's top (drawn after the skull: the bitmap sits a layer above the lines anyway)
            -- (2.0.1 review: drawn only once the skull is up, so a refused skull no longer leaves two gun lines)
            for pass = 1, nogun and 0 or 2 do
                line(g, cx, cy + L * 0.17, cx, cy + L * 0.6, pass == 1 and th * 1.4 + 1.5 or th * 1.4, pass == 1 and SHADOW or YELLOW)
            end
            return
        end
        skull_refused('octagon (bitmap refused: ' .. tostring(id) .. ')')
    end
    for pass = 1, 2 do
        local col, rr = pass == 1 and SHADOW or YELLOW, pass == 1 and r + 1 or r
        local c0 = P(cx, cy)
        for k = 0, 7 do
            local t1, t2 = k * pi / 4, (k + 1) * pi / 4
            tri(g, c0, P(cx + rr * cos(t1), cy + rr * sin(t1)), P(cx + rr * cos(t2), cy + rr * sin(t2)), col)
        end
        if not nogun then line(g, cx, cy, cx, cy + L * 0.6, pass == 1 and th * 1.4 + 1.5 or th * 1.4, col) end
    end
end


-- ---------------------------------------------------------------- main loop
local last_logged
local seat_shown = {}
local function seat_text(seat)
    if seat_shown.kind ~= seat.kind or seat_shown.role ~= seat.role then
        seat_shown.kind, seat_shown.role = seat.kind, seat.role
        local v = TANKS[seat.kind] or TT.HULLS[seat.kind]
        seat_shown.text = (v and v.name or FRV_KINDS[seat.kind] or 'vehicle') .. ', ' .. (seat.role == 2 and 'gunner seat'
            or ((seat.role == 1 or seat.role == 4) and 'driver seat' or ('seat role ' .. tostring(seat.role))))
    end
    return seat_shown.text
end
local function tracker_errors()
    if TT.pick_note then note(TT.pick_note); TT.pick_note = nil end
    if TT.errors ~= (core_watch.tt_errors or 0) then
        S.errors = S.errors + TT.errors - (core_watch.tt_errors or 0); core_watch.tt_errors = TT.errors; S.last_error = TT.last_error
    end
end
-- Tank Core's seat, if Tank Core is running (its frame counter moves every frame; a stopped core's seat is not
-- trusted). Returns the seat (nil when not in a supported tank), Tank Core's frame counter, and whether it runs.
-- frv: the FRVs count as seats too (2.1: the outline shows in the tanks and the FRVs, in any seat).
local function core_seat(frv)
    local seat, core = rawget(_G, 'ArmoredOverhaulSeat'), rawget(_G, 'ArmoredOverhaulGunnerDrive')
    if type(seat) ~= 'table' or type(core) ~= 'table' then return nil, nil, false, 'waiting for Tank Core (seat reader)' end
    local cf = core.frames or 0
    if cf ~= core_watch.frames then core_watch.frames, core_watch.seen = cf, S.frames end
    core_watch.gd = core.gd_flags          -- (3.0.1 review) Gunner Drive's vehicles: 1 tanks, 2 the FRV (for docking)
    local core_ok = core.phase ~= 'off' and S.frames - (core_watch.seen or S.frames) <= CORE_STALL
    if not core_ok then return nil, cf, false, 'waiting: Tank Core is not running (' .. tostring(core.status) .. ')' end
    local seated = seat.kind and (TANKS[seat.kind] or (frv and FRV_KINDS[seat.kind])) and cf - (seat.frame or -1e9) <= SEAT_FRESH
    return seated and seat or nil, cf, true, 'watching'
end

-- (3.0.1 Test 13, tester builds) The Maelstrom's hull is sometimes missing from the moment it is called in (only its
-- turret shows, on any skin; rare, other players see it too). Every 2 s, for every Bastion and Maelstrom in the
-- world, the number of meshes and which of them the engine has hidden (Mesh.visibility), in the log: 'hulls' now and
-- 'hull_changes' (the last 8 changes), to see whether the game hides the meshes when it happens.
local hullwatch = {next = 0, last = {}, changes = {}}
local function hull_watch()
    if S.frames < hullwatch.next then return end
    hullwatch.next = S.frames + 120
    local SA, SW, SU, SM = SR and SR.Application, SR and SR.World, SR and SR.Unit, SR and SR.Mesh
    if not (SA and SW and SU and SM) then S.hulls = 'engine tables missing'; return end
    local okw, world = pcall(SA.main_world)
    if not okw or world == nil then return end
    local parts, now = {}, {}
    for _, kind in ipairs({0x2B, 0x2C}) do
        local t = TT.TANKS[kind]
        local oku, units = pcall(SW.units_by_resource, world, t.hull)
        if oku and type(units) == 'table' then
            for i, u in ipairs(units) do
                local okn, n = pcall(SU.num_meshes, u)
                local hidden, failed = {}, nil
                if okn and type(n) == 'number' then
                    for m = 1, n do
                        local okm, mesh = pcall(SU.mesh, u, m)
                        if not okm then okm, mesh = pcall(SU.mesh, u, m - 1) end
                        if okm and mesh then
                            local okv, vis = pcall(SM.visibility, mesh)
                            if not okv then failed = tostring(vis) elseif vis == false then hidden[#hidden + 1] = m end
                        else failed = 'mesh ' .. m .. ': ' .. tostring(mesh) end
                    end
                end
                local key = t.name .. ' ' .. i
                local text = string.format('%s: %s meshes, hidden %s%s', key, tostring(n), #hidden > 0 and table.concat(hidden, ',') or 'none',
                    failed and (' (' .. failed .. ')') or '')
                parts[#parts + 1] = text
                now[key] = text
                if hullwatch.last[key] ~= text then
                    if #hullwatch.changes >= 8 then table.remove(hullwatch.changes, 1) end
                    hullwatch.changes[#hullwatch.changes + 1] = 'f' .. S.frames .. ' ' .. text
                end
            end
        end
    end
    hullwatch.last = now
    local was = S.hulls
    S.hulls = #parts > 0 and table.concat(parts, '; ') or 'no tanks in the world'
    S.hull_changes = #hullwatch.changes > 0 and table.concat(hullwatch.changes, ' | ') or 'none'
    if S.hulls ~= was then log() end
end

-- (3.0.1, tester builds) For reports of tanks tipping over. Ten times a second, for every
-- Bastion and Maelstrom in the world, how far the hull leans (its up axis against the world's; roll < 0: its right
-- side down; pitch > 0: nose up), with its speed, turn rate and rise/fall measured from its movement. 'tilts': the
-- most each tank leaned (since the game started). 'tips' (the last 8): each time a hull leans past 35 degrees, what it was doing
-- in the second before (speed, turning, rising or falling, lean), and then whether it came back or went over.
local rollwatch = {next = 0, tanks = setmetatable({}, {__mode = 'k'}), tips = {}, TIP = 35, OVER = 100, BACK = 20, KEEP = 10}
local function roll_watch()
    if S.frames < rollwatch.next then return end
    rollwatch.next = S.frames + 6
    local SA, SW, SU, SQ = SR and SR.Application, SR and SR.World, SR and SR.Unit, SR and SR.Quaternion
    if not (SA and SW and SU and SQ and SQ.up) then S.tilts = 'engine tables missing'; return end
    local okw, world = pcall(SA.main_world)
    if not okw or world == nil then return end
    local okt, now = pcall(SA.time_since_launch)
    if not okt or type(now) ~= 'number' then now = S.frames / 60 end
    local deg, R = math.deg, rollwatch
    local function tip(text)
        if #R.tips >= 8 then table.remove(R.tips, 1) end
        R.tips[#R.tips + 1] = 'f' .. S.frames .. ' ' .. text
        S.tips = table.concat(R.tips, ' | ')
    end
    local parts, changed = {}, false
    for _, kind in ipairs({0x2B, 0x2C}) do
        local t = TT.TANKS[kind]
        local oku, units = pcall(SW.units_by_resource, world, t.hull)
        if oku and type(units) == 'table' then
            for i, u in ipairs(units) do
                local q = SU.world_rotation(u, 1)
                local _, _, uz = tt_comps(SQ.up(q))     -- (only the heights of the axes are needed)
                local fx, fy, fz = tt_comps(SQ.forward(q))
                local _, _, rz = tt_comps(SQ.right(q))
                local p = SU.world_position(u, 1)
                local px, py, pz = tt_comps(p)
                if uz and fz and rz and pz then
                    local w = R.tanks[u]
                    if not w then w = {max = 0, side = 0, n = 0, hist = {}, state = 'level'}; R.tanks[u] = w end
                    local lean = deg(math.acos(math.max(-1, math.min(1, uz))))
                    local roll = deg(math.asin(math.max(-1, math.min(1, rz))))
                    local pitch = deg(math.asin(math.max(-1, math.min(1, fz))))
                    local heading = math.atan2(fx, fy)
                    local speed, turn, climb = 0, 0, 0
                    if w.t and now > w.t then
                        local dt = now - w.t
                        speed = math.sqrt((px - w.x) ^ 2 + (py - w.y) ^ 2) / dt
                        local dh = heading - w.h
                        if dh > math.pi then dh = dh - 2 * math.pi elseif dh < -math.pi then dh = dh + 2 * math.pi end
                        turn, climb = deg(dh) / dt, (pz - w.z) / dt
                        if speed > 60 then speed, turn, climb = 0, 0, 0 end        -- (a teleport or a respawn, not driving)
                    end
                    w.t, w.x, w.y, w.z, w.h = now, px, py, pz, heading
                    w.n = w.n % R.KEEP + 1
                    local h = w.hist[w.n]                -- plain numbers kept; the text is only made for a tip
                    if not h then h = {}; w.hist[w.n] = h end
                    h[1], h[2], h[3], h[4], h[5] = speed * 3.6, turn, climb, roll, pitch
                    if lean > w.max then w.max, w.side = lean, roll; changed = true end
                    local name = t.name .. ' ' .. i
                    if w.state == 'level' and lean > R.TIP then
                        w.state, w.peak = 'tipping', lean
                        local before = {}
                        for k = 1, R.KEEP do
                            local e = w.hist[(w.n + k - 1) % R.KEEP + 1]
                            if e then
                                before[#before + 1] = string.format('%.0f km/h, turning %+.0f deg/s, %+.1f m/s up, roll %+.0f pitch %+.0f',
                                    e[1], e[2], e[3], e[4], e[5])
                            end
                        end
                        tip(string.format('%s leaned past %d (%s side down: roll %+.0f, pitch %+.0f); the second before: %s', name, R.TIP,
                            roll < 0 and 'right' or 'left', roll, pitch, table.concat(before, ' / ')))
                        changed = true
                    elseif w.state == 'tipping' then
                        if lean > w.peak then w.peak = lean end
                        if lean > R.OVER then w.state = 'over'; tip(name .. ' went over (lean ' .. string.format('%.0f', lean) .. ')'); changed = true
                        elseif lean < R.BACK then w.state = 'level'; tip(string.format('%s came back (most %.0f)', name, w.peak)); changed = true end
                    elseif w.state == 'over' and lean < R.BACK then
                        w.state = 'level'; tip(name .. ' upright again'); changed = true
                    end
                    parts[#parts + 1] = name; parts[#parts + 1] = w; parts[#parts + 1] = lean
                end
            end
        end
    end
    S.tips = S.tips or 'none'
    -- the text is only rebuilt when something worth logging changed (the log is written then)
    if changed or not S.tilts then
        local txt = {}
        for k = 1, #parts, 3 do
            local w = parts[k + 1]
            txt[#txt + 1] = string.format('%s: most %.0f (roll %+.0f), now %.0f', parts[k], w.max, w.side, parts[k + 2])
        end
        S.tilts = #txt > 0 and table.concat(txt, '; ') or 'no tanks in the world'
        log()
    end
end

local function tick()
    S.frames = S.frames + 1
    menu_link(S.frames)
    if TESTER then pcall(hull_watch); pcall(roll_watch) end
    local seat, cf, core_ok, idle = core_seat(true)
    local turned_off = seat and settings.show < 0.5
    if turned_off then seat, idle = nil, 'off (turned off in the Mod Options Menu)' end
    if not seat then
        TT.reset()
        skull_proven()
        if ov.gui and #ov.ids > 0 then clear_shapes() end
        set_visible(false)
        S.seat = turned_off and 'in a vehicle (the indicator is off)' or (core_ok and 'not in a vehicle' or 'unknown')
        -- (3.0.1 review) last_logged kept up to date (3.0: sitting back in wrote nothing, and the file kept the idle
        -- status for up to 30 s); an option that is off for good (the engine lacks something, drawing failed) keeps
        -- saying so (3.0: the idle text replaced it)
        if S.api == 'ok' or S.api == 'unchecked' then S.status = idle end
        if S.status ~= last_logged then last_logged = S.status; log() end
        return
    end
    if not api_ok() then if S.status ~= last_logged then last_logged = S.status; log() end return end

    local okw, world = pcall(A.main_world)
    -- (2.0.1 review) no main world: hidden, not left frozen on screen; a new main world (a mission loaded or left):
    -- the screen GUI is checked at once rather than within the second
    if not okw or world == nil then set_visible(false); S.status = 'no world'; return end
    if world ~= ov.main then ov.main = world; ov.next_check = 0 end
    S.seat = seat_text(seat)
    local finds = TT.finds
    local angle, why, measured = nil, nil, false
    if GUNLESS[seat.kind] then
        angle = 0; S.tank, S.pick = GUNLESS_TEXT, 'not needed'
    else
        angle, why = TT.shared_angle(world, seat.kind, S.frames, cf)
        S.tank, S.pick = TT.tank, TT.pick
        measured = angle ~= nil
        -- (2.1 review) an FRV whose gun isn't found (yet) is still shown, pointing ahead with no gun line, like the M-103
        if not angle and FRV_KINDS[seat.kind] then angle = 0 end
    end
    S.finds = TT.finds
    tracker_errors()
    if TT.gen ~= ov.tt_gen then                                -- a (new) tank found: everything drawn fresh for it
        ov.tt_gen = TT.gen
        if ov.gui and #ov.ids > 0 then clear_shapes() end
    end
    if TT.finds ~= finds then log() end
    if not angle then
        skull_proven()
        if ov.gui and #ov.ids > 0 then clear_shapes() end
        set_visible(false)
        S.status = why == 'looking' and 'looking for the vehicle' or (why == 'no angle' and 'cannot read the turret angle' or 'turret angle failed')
        if S.status ~= last_logged then last_logged = S.status; log() end
        return
    end
    local nogun = not measured
    local g = overlay_gui(world)
    if not g then S.status = 'no screen gui'; if S.status ~= last_logged then last_logged = S.status; log() end return end
    local sw, sh = screen_size()
    -- rebuild the shapes only when something changed (1-degree steps; 2.0.1 review: 2.0 used half degrees, about a third
    -- of a pixel at the default size, so a turning turret was redrawn every frame)
    -- (3.0 review) the FRV in 2-degree steps: its outline (wheels too) costs about 1.7 times a tank's, it shows in
    -- every seat, and its gun turns fast
    local step = FRV_KINDS[seat.kind] and floor(angle * 90 / pi + 0.5) * 2 or floor(angle * 180 / pi + 0.5)
    local band = settings.health >= 0.5 and health_band(seat.health) or nil
    -- (2.0) docked next to the driver panel: redrawn when the panel moves, is resized, shown or hidden
    -- (compared as numbers: no text made every frame)
    -- (3.0.1 review) only where the panel can show: its addon runs (place.show: false once it stopped or is off) and
    -- Gunner Drive drives this vehicle (Tank Core's gd_flags: Off in the Mod Options Menu, or the M-103, which is
    -- never driven: 3.0 docked next to a panel that never showed)
    local place, dock, px, py, ps = settings.dock >= 0.5 and rawget(_G, 'ArmoredOverhaulDriverPanelPlace'), 0, 0, 0, 0
    -- (3.1.0 Test 26) in the driver's seat of any vehicle the outline sits where it docks beside the Gunner Drive
    -- panel: the panel's own place (its menu position, whether or not it shows here), or the panel's default place
    -- when its addon isn't installed
    if settings.dock >= 0.5 and (seat.role == 1 or seat.role == 4) then
        local q = type(place) == 'table' and type(place.x) == 'number' and type(place.y) == 'number'
            and type(place.size) == 'number' and place or PANEL_DEFAULT
        place, dock, px, py, ps = q, 5, q.x, q.y, q.size
    elseif type(place) == 'table' and type(place.x) == 'number' then
        local gd = core_watch.gd
        local driven = TANKS[seat.kind] and (type(gd) ~= 'number' or gd % 2 == 1)
            or (seat.kind == FRV_KIND and (type(gd) ~= 'number' or gd >= 2))
        if not place.show then dock = 2
        elseif not driven then dock = 4
        else dock, px, py, ps = 3, place.x, place.y, place.size end
    elseif settings.dock >= 0.5 then dock = 1 end
    local tires = FRV_KINDS[seat.kind] and tire_code(seat, settings.health >= 0.5) or nil
    if (not ov.key or step ~= ov.step or sw ~= ov.sw or sh ~= ov.sh or settings.sig ~= ov.sig or band ~= ov.band
        or dock ~= ov.dock or px ~= ov.px or py ~= ov.py or ps ~= ov.ps or ov.kind ~= seat.kind or ov.nogun ~= nogun
        or (tires and tires ~= ov.tires)) and S.frames >= (ov.retry_at or 0) then
        clear_shapes(true)
        ov.kind = seat.kind
        ov.frv, ov.nogun = FRV_KINDS[seat.kind] ~= nil, nogun
        ov.tires = tires
        local okd, err = pcall(draw, g, sw, sh, settings, angle, band, ov.frv, ov.frv and tire_bands or nil, nogun, (dock == 3 or dock == 5) and place or nil)
        if not okd then
            S.errors = S.errors + 1; S.last_error = 'drawing failed: ' .. tostring(err); clear_shapes(true)
            -- (2.0.1 review) only drawing failures count towards turning it off (2.0 counted the tracker's too)
            -- (3.1.1 review) failures in a row, tried again half a second later (3.1.0 counted every failure of the session
            -- and retried the next frame: five quick ones, or five spread over a long session, turned it off for good)
            draw_fails = draw_fails + 1
            ov.retry_at = S.frames + 30
            if draw_fails >= 5 then
                S.api = 'drawing failed'; S.status = 'off (drawing failed, see the notes)'
                if sk.watch then sk.watch = nil; pcall(skullcheck, 'refused\n') end    -- (3.1.1 review: not left 'trying')
            end
            log(); return
        end
        draw_fails, ov.retry_at = 0, nil
        ov.key, ov.step, ov.sw, ov.sh, ov.sig, ov.band, ov.dock, ov.px, ov.py, ov.ps = true, step, sw, sh, settings.sig, band, dock, px, py, ps
        S.dock = dock == 0 and 'off (the menu\'s position is used)'
            or (dock == 1 and 'its position (the driver panel is not installed)')
            or (dock == 2 and 'its position (the driver panel is not running)')
            or (dock == 4 and 'its position (no driver panel in this vehicle: Gunner Drive is off for it)')
            or (dock == 5 and 'left of the driver panel\'s place (driver seat)') or 'left of the driver panel'
        -- (3.0 review) the log texts only when what they say changed (2.1: every redraw); the shape counts are tester-only
        local hk = band and (band * 1000 + floor(seat.health * 100 + 0.5)) or (settings.health >= 0.5 and -1 or -2)
        if hk ~= ov.health_logged then
            ov.health_logged = hk
            S.health = band and string.format('%s (%.0f%%)', HEALTH_BANDS[band][2], seat.health * 100)
                or (settings.health >= 0.5 and 'not known (gray outline)' or 'off')
        end
        if TESTER then S.shapes = string.format('screen %dx%d, %d shapes, %d bitmaps, triangles %s', sw, sh, #ov.ids, #ov.bitmaps, tostring(ov.style)) end
        -- (3.0 review) from what was drawn (2.1: a failed draw left it stale, and a tank kept the FRV's text)
        if not ov.frv then
            if ov.tires_shown ~= false then ov.tires_shown = false; S.tires = 'not in an FRV' end
        elseif tires ~= ov.tires_shown then
            ov.tires_shown = tires
            local parts = {}
            for i = 1, 4 do
                local b = tire_bands[i]
                parts[i] = TIRE_NAMES[i] .. ' ' .. (b == 0 and 'popped' or (b == 6 and 'not known' or HEALTH_BANDS[b][2]))
            end
            S.tires = table.concat(parts, ', ')
        end
    end
    set_visible(true)
    S.drawn = S.drawn + 1
    S.status = 'showing'
    -- the skull's safety marker: 'ok' once it has been on screen 600 frames
    if sk.watch and #ov.bitmaps > 0 then
        sk.watch = sk.watch - 1
        if sk.watch <= 0 then sk.watch = 0; skull_proven() end
    end
    if S.frames % 30 == 0 then                       -- (3.0 review: the text only when the whole degree changed)
        local ak = measured and floor(angle * 180 / pi + 0.5) or (GUNLESS[seat.kind] and 'gunless' or 'unmeasured')
        if ak ~= ov.angle_logged then
            ov.angle_logged = ak
            S.angle = measured and string.format('%.0f deg (0 = turret straight ahead)', angle * 180 / pi)
                or (GUNLESS[seat.kind] and 'no gun (shown pointing ahead)' or 'not measured (shown pointing ahead)')
        end
    end
    if S.status ~= last_logged or S.frames % 1800 == 0 then last_logged = S.status; log() end
end

local previous_update = update
if type(previous_update) ~= 'function' then return end
local broken = false
local function after(ok, ...)
    if not ok then error((...), 0) end
    if not broken then
        local okT, err = pcall(tick)
        if not okT then
            broken = true; S.errors = S.errors + 1; S.last_error = tostring(err); S.status = 'stopped after an error: ' .. tostring(err)
            -- (3.1.1 review) a skull try under way is settled (3.1.0 left 'trying': the next start skipped the skull as if the
            -- game had closed)
            if sk.watch then sk.watch = nil; pcall(skullcheck, 'refused\n') end
            pcall(set_visible, false)                       -- (2.0.1 review: not left frozen on screen)
            log()
        end
    end
    return ...
end
update = function(...) return after(pcall(previous_update, ...)) end
log()

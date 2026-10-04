-- HD2-Addon: mods/chef/armored_overhaul_driver_panel
-- Armored Overhaul 3.2.0 - Driver Panel option (3.2.0: its own option; 1.2.2-3.1.1 part of Gunner Drive): while you drive a TD-220 Bastion,
-- TD-110 Maelstrom or M-102 FRV from the gunner seat, a panel like the game's own driver HUD shows the gear selector,
-- the gear, the rpm, the speed and the fuel (and the Maelstrom's smoke rounds). Drawn only on your screen. Written
-- from scratch. (1.2.2: it was part of the Turret indicator until 1.2.1, and turning that option off took the panel too.)
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
if rawget(_G, 'ArmoredOverhaulDriverPanel') then return end

local TESTER = false
local sqrt, floor, min, max = math.sqrt, math.floor, math.min, math.max

local SEAT_FRESH = 45                -- frames a published seat stays valid (the core refreshes it every few frames)
local RECHECK_EVERY = 60             -- frames between checks of the overlay world and the screen size
local CORE_STALL = 60                -- frames without a Tank Core update before its seat is no longer trusted

local TITLE, LOG_FILE = 'Driver Panel', 'ArmoredOverhaul-DriverPanel.log'
-- (3.0.0) no settings file (1.2.2-2.1 wrote and read ArmoredOverhaul-DriverPanel.cfg; a file an older version
-- wrote is left alone and not read); these are fixed. x, y: the panel's centre as shares of the screen (0 = left / bottom edge);
-- size: the gear letters' height as a share of the screen height. (3.0.1 review: show and game_font, always on, went
-- with the code that could only run with them off)
local SETTINGS = {x = 0.5, y = 0.1, size = 0.022, opacity = 0.55}

local S = {version = '3.2.0', status = 'starting', api = 'unchecked', gui = 'none', tank = 'none', seat = 'none',
           last_error = 'none', frames = 0, drawn = 0, finds = 0, errors = 0,
           pick = 'none', gear = 'hidden', panel = 'none', font = 'not needed yet', input = 'keyboard', input_api = 'unchecked',
           speed = 'not measured yet', speed_check = 'none', options_menu = 'not installed (the defaults are used)'}
rawset(_G, 'ArmoredOverhaulDriverPanel', S)
-- (3.1.1 review) While the panel shows, the 'gear' line (selector, gear, rpm, speed, fuel) is made when it is read (the log,
-- or a test), from the last values drawn: 3.1.0 made the text on every live redraw, up to 40 times a second at 240 fps.
local gear_text = nil
setmetatable(S, {__index = function(_, k)
    if k == 'gear' and gear_text then local ok, s = pcall(gear_text); return ok and s or '?' end
end})

local loader = rawget(_G, 'CowboyBingusModLoader')
if type(loader) ~= 'table' or type(loader.version) ~= 'number' or loader.version < 15 then return end
local SR = rawget(_G, 'stingray')

-- ---------------------------------------------------------------- log and settings
-- The log is what a user attaches to a bug report: whether the engine offers what the option needs, where it
-- draws, the settings, your seat and tank, and what went wrong. Tester builds add counters and details.
local LOG_MAIN = {'version', 'status', 'api', 'gui', 'options_menu', 'seat', 'gear', 'speed', 'font', 'input', 'errors', 'last_error'}
local LOG_TESTER = {'frames', 'drawn', 'panel', 'speed_check', 'tank', 'pick', 'finds', 'input_api'}
local notes, test_notes = {}, {}
local function note(s)
    for _, n in ipairs(notes) do if n == s then return end end
    if #notes < 20 then notes[#notes + 1] = s end
end
-- (3.0.1 review) the file is written only when its text changed (3.0 rewrote it on every hull search, every 5 s
-- while the hull could not be found)
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
local settings = {sig = 0}             -- the values in use; sig changes with every change (the panel is redrawn)
for k, v in pairs(SETTINGS) do settings[k] = v end
-- (2.0) where the panel sits, for the Vehicle Indicator (it docks just left of it). (3.0.1 review) show: the panel
-- runs; false once it is off (the engine lacks something, drawing failed) or stopped after an error (3.0: always
-- true). The Indicator also docks only in a vehicle Gunner Drive drives (Tank Core's gd_flags).
local PLACE = {x = settings.x, y = settings.y, size = settings.size, show = true}
rawset(_G, 'ArmoredOverhaulDriverPanelPlace', PLACE)


-- ---------------------------------------------------------------- Mod Options Menu (3.2.0)
-- (3.2.0) The Driver Panel is its own option now (a commenter asked for a way to turn it off); with CowboyBingus's Mod
-- Options Menu installed it can be turned off in game too (MODS, ARMORED OVERHAUL, right after Gunner Drive). Same
-- hub as the other addons: every addon publishes its rows in _G.ArmoredOverhaulMenu and the first one to find the menu
-- adds them all in the mod manager's option order (MENU_ORDER).
local panel_on = true
local menu_link
do
    local MENU_ORDER = {'power', 'grip', 'steering', 'turret', 'autoloader', 'gunner_drive', 'driver_panel', 'camera', 'indicator'}
    local hub = rawget(_G, 'ArmoredOverhaulMenu')
    if type(hub) ~= 'table' or type(hub.groups) ~= 'table' then hub = {groups = {}, done = {}}; rawset(_G, 'ArmoredOverhaulMenu', hub) end
    hub.groups.driver_panel = {status = S,
        rows = function()
            return {{'armored_overhaul.driver_panel', {type = 'toggle', label = 'Driver Panel', default = true,
                description = 'While you drive from the gunner seat with Gunner Drive, a panel like the driver\'s own HUD shows the gear, rpm, speed, fuel and the Maelstrom\'s smoke rounds. It only shows while you are the one driving. Only you see it.'}, 'show'}}
        end,
        set = function(key, v) if key == 'show' then panel_on = (v == true or v == 1) end end}
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
        if hub.done.driver_panel then at = math.huge; return end
        local M = rawget(_G, 'ModOptionsMenu')
        if type(M) ~= 'table' or M.api ~= 1 or type(M.register_option) ~= 'function' then return end
        for _, g in ipairs(MENU_ORDER) do pcall(add, M, g) end
        for g in pairs(hub.groups) do pcall(add, M, g) end   -- (a group not in MENU_ORDER: last)
    end
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
    return true
end

local function xyz(v) return v.x, v.y, v.z end
local function comps(v)
    local ok, x, y, z = pcall(xyz, v)
    if ok and type(x) == 'number' then return x, y, z end
    -- (3.1.1 review) through pcall too: a value in another form after a game update errored here, outside any pcall
    if V3 and type(V3.to_elements) == 'function' then
        local ok2, a, b, c = pcall(V3.to_elements, v)
        if ok2 and type(a) == 'number' then return a, b, c end
    end
    return nil
end


-- ---------------------------------------------------------------- the overlay screen GUI (as HD2 HUD+ does it)
local LAYER, DEPTH = 3, 0
local TRI_MATERIAL = 'core/performance_hud/debug'   -- the engine's own debug GUI material (used if a plain triangle fails)
local ov = {world = nil, gui = nil, key = nil, style = nil, visible = nil}
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
    ov.key = nil
    ov.hud, ov.hud_t, ov.hkey, ov.hudl, ov.hudl_t, ov.lkey, ov.slots, ov.items = {}, {}, nil, {}, {}, nil, nil, nil
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
-- the driver panel (gears, rpm, speed, fuel) is its own group: it changes far more often than the outline
-- (two parts: the frame, labels and selector, which rarely change, and the live values: rpm, speed, fuel)
-- (texts drawn with the game's HUD font are kept in their own lists: they are destroyed with Gui.destroy_text)
local function clear_texts(list)
    if ov.gui and list and #list > 0 then
        for _, id in ipairs(list) do pcall(G.destroy_text, ov.gui, id) end
    end
end
local function clear_slots()
    if ov.slots then
        local list = {}
        for _, t in pairs(ov.slots) do list[#list + 1] = t.shadow; list[#list + 1] = t.text end
        clear_texts(list)
    end
    ov.slots = nil
end
local function clear_items()
    if ov.items then
        for _, it in pairs(ov.items) do
            if ov.gui then for _, id in ipairs(it.ids) do pcall(G.destroy_triangle, ov.gui, id) end end
        end
    end
    ov.items = nil
end
local function clear_live()
    if ov.gui and ov.hudl then for _, id in ipairs(ov.hudl) do pcall(G.destroy_triangle, ov.gui, id) end end
    clear_texts(ov.hudl_t)
    ov.hudl, ov.hudl_t, ov.lkey = {}, {}, nil
end
local function clear_hud(checked)
    if ov.gui and not checked and not gui_alive() then return end
    if ov.gui and ov.hud then for _, id in ipairs(ov.hud) do pcall(G.destroy_triangle, ov.gui, id) end end
    clear_texts(ov.hud_t)
    ov.hud, ov.hud_t, ov.hkey = {}, {}, nil
    clear_live()
    clear_slots()
    clear_items()
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
        ov.key = nil; clear_hud(true)        -- (3.1.1 review: the panel only draws into its own lists)
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
    if id ~= nil and ov.sink then local sink = ov.sink; sink[#sink + 1] = id end
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
    FIND_EVERY = 30,             -- frames between searches while seated and not yet found
    FIND_SLOW = 300,             -- ... after FIND_MISSES misses in a row (a search can go through every unit)
    FIND_MISSES = 5,
    tank = 'none', pick = 'none', pick_note = nil, finds = 0, errors = 0, last_error = nil,
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
-- Forget the tank (you left the seat).
function TT.reset()
    if TT.hull_found then TT.hull_found.unit, TT.hull_found.kind = nil, nil end
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
    if type(world) == 'function' then world = world() end         -- (a getter works too)
    if world == nil then return nil end
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
    return hull
end

local TANKS = TT.TANKS
local FRV_KIND = 0x1A          -- (2.1) FRV Gunner Drive: the driver panel and the outline (FRV shape, its gun) show in the FRV too
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


-- ---------------------------------------------------------------- driver panel
-- While you drive from the gunner seat (Gunner Drive) a panel like the game's own driver HUD sits near the bottom of
-- the screen: the gear selector (R N D 1 2, with the shift keys), and under it the gear the transmission is in, an
-- rpm bar, the speed and a fuel bar. Hidden whenever someone else drives (they have the game's own HUD).
-- Glyphs are strokes in a 0.6 x 1 box (x right, y up).
local GLYPHS = {
    R = {{0, 0, 0, 1, 0.42, 1, 0.6, 0.84, 0.6, 0.66, 0.42, 0.5, 0, 0.5}, {0.28, 0.5, 0.6, 0}},
    N = {{0, 0, 0, 1, 0.6, 0, 0.6, 1}},
    D = {{0, 0, 0, 1, 0.34, 1, 0.6, 0.76, 0.6, 0.24, 0.34, 0, 0, 0}},
    C = {{0.6, 0.84, 0.44, 1, 0.16, 1, 0, 0.84, 0, 0.16, 0.16, 0, 0.44, 0, 0.6, 0.16}},
    T = {{0, 1, 0.6, 1}, {0.3, 1, 0.3, 0}},
    L = {{0, 1, 0, 0, 0.56, 0}},
    P = {{0, 0, 0, 1, 0.44, 1, 0.6, 0.84, 0.6, 0.66, 0.44, 0.5, 0, 0.5}},
    M = {{0, 0, 0, 1, 0.3, 0.45, 0.6, 1, 0.6, 0}},
    K = {{0, 0, 0, 1}, {0.6, 1, 0, 0.4}, {0.2, 0.6, 0.6, 0}},
    H = {{0, 0, 0, 1}, {0.6, 0, 0.6, 1}, {0, 0.5, 0.6, 0.5}},
    ['-'] = {{0.08, 0.5, 0.52, 0.5}},          -- (3.0.1 review) gear not known, fuel '- L', a negative speed (3.0: blank)
    ['^'] = {{0.3, 1, 0, 0.56, 0.16, 0.56, 0.16, 0, 0.44, 0, 0.44, 0.56, 0.6, 0.56, 0.3, 1}},   -- the shift key
    ['0'] = {{0.12, 0, 0.48, 0, 0.6, 0.14, 0.6, 0.86, 0.48, 1, 0.12, 1, 0, 0.86, 0, 0.14, 0.12, 0}},
    ['1'] = {{0.12, 0.8, 0.34, 1, 0.34, 0}},
    ['2'] = {{0.02, 0.8, 0.18, 1, 0.44, 1, 0.6, 0.84, 0.6, 0.64, 0, 0, 0.6, 0}},
    ['3'] = {{0, 1, 0.6, 1, 0.26, 0.56, 0.44, 0.56, 0.6, 0.4, 0.6, 0.16, 0.44, 0, 0.12, 0, 0, 0.1}},
    ['4'] = {{0.46, 0, 0.46, 1, 0, 0.32, 0.6, 0.32}},
    ['5'] = {{0.6, 1, 0.04, 1, 0.02, 0.56, 0.42, 0.6, 0.6, 0.42, 0.6, 0.16, 0.44, 0, 0.12, 0, 0, 0.1}},
    ['6'] = {{0.56, 0.94, 0.4, 1, 0.16, 1, 0, 0.8, 0, 0.16, 0.16, 0, 0.44, 0, 0.6, 0.16, 0.6, 0.38, 0.44, 0.54, 0.16, 0.54, 0, 0.4}},
    ['7'] = {{0, 1, 0.6, 1, 0.2, 0}},
    ['8'] = {{0.12, 0.54, 0, 0.66, 0, 0.88, 0.12, 1, 0.48, 1, 0.6, 0.88, 0.6, 0.66, 0.48, 0.54, 0.12, 0.54, 0, 0.42, 0, 0.12,
              0.12, 0, 0.48, 0, 0.6, 0.12, 0.6, 0.42, 0.48, 0.54}},
    ['9'] = {{0.04, 0.06, 0.2, 0, 0.44, 0, 0.6, 0.2, 0.6, 0.84, 0.44, 1, 0.16, 1, 0, 0.84, 0, 0.62, 0.16, 0.46, 0.44, 0.46, 0.6, 0.6}},
}
local SELECTOR = {'R', 'N', 'D', '1', '2'}   -- the game's selector positions 0..4
local RPM_MAX = 5000                          -- the tanks' engines rev to 5000
local fuel_full = {}                          -- litres when first seen, per tank (the bar's full mark)

local function glyph(g, ch, x, y, h, w, color)
    for _, stroke in ipairs(GLYPHS[ch] or {}) do
        for i = 1, #stroke - 3, 2 do
            line(g, x + stroke[i] * h, y + stroke[i + 1] * h, x + stroke[i + 2] * h, y + stroke[i + 3] * h, w, color)
        end
    end
end
local function text_width(str, h) return (#str * 0.82 - 0.22) * h end

-- The game's own HUD font (Tank Core reads which font, material and glyph atlas the game's HUD uses and publishes
-- them as ArmoredOverhaulUIFont). The atlas is bound to the material's glyph slot, as the game's HUD code does.
-- Without it (not read yet, or this engine lacks a text function) the panel uses the stroke letters above.
local FONT_SLOT = '88bac99b00000000'
local CAP = 0.72                                      -- the font's capital height as a share of its size
local ft = {}
-- The engine's ids (IdString64), like its vectors and colors, only live for the frame they are made in: the font
-- and material ids are made from their hex names every frame the panel is shown, and the atlas bound again, as
-- HD2 HUD+ does (1.2 Tests 5-7 kept them from one frame to the next and crashed at the panel's first refresh).
-- Safety net: each resource is checked with Application.can_get before first use, and a small marker file is
-- written before the first use and updated once the panel has been shown 600 frames in the font (or 'refused' when
-- the font is given up without the game closing). If the game closed in between, the marker still says 'trying':
-- the next start uses the built-in letters once and tries the font again the start after that (a crash for any
-- other reason then never turns the font off for good).
local MARK_TAG = '[ids per frame]'
local function fontcheck_path() return logs_path('ArmoredOverhaul-DriverPanel.fontcheck') end
local function fontcheck(write)
    local path = fontcheck_path()
    if not path or not io or not io.open then return nil end
    if write then local f = io.open(path, 'w'); if f then f:write(write); f:close() end; return end
    local f = io.open(path, 'r'); if not f then return nil end
    local t = f:read('*a'); f:close(); return t
end
-- (3.0.1 review) the font given up without the game closing (its ids could not be made, or drawing in it failed):
-- the marker says 'refused', so the next start tries it again (3.0 left 'trying': the next start skipped the font,
-- saying the game had closed)
local function font_refused(why)
    if ft.ok and ft.key then fontcheck('refused ' .. ft.key .. '\n') end
    ft.ok, ov.watch, S.font = false, 0, why
end
local font_proven
local function font_ready(g, set)
    if ft.gui == g then return ft.ok == true end
    local pub = rawget(_G, 'ArmoredOverhaulUIFont')
    if type(pub) ~= 'table' or not pub.font then S.font = 'stroke letters (the game\'s HUD font not read yet)'; return false end
    -- (3.0.1 review) a try in the previous GUI (a mission loaded or left) is settled first: its 'trying' marker read
    -- as a crash here (this GUI went to the stroke letters) and at the next start
    if ft.ok and (ov.watch or 0) > 0 then
        font_proven('(shown, then the screen GUI changed)')
        if (ov.watch or 0) > 0 then fontcheck('interrupted ' .. ft.key .. '\n'); ov.watch = 0 end
    end
    ft = {gui = g}
    local key = pub.font .. ' ' .. pub.material .. ' ' .. pub.atlas
    local last = fontcheck()
    if last and last:find('^trying') and last:find(key, 1, true) and last:find(MARK_TAG, 1, true) then
        fontcheck('skipped once ' .. key .. ' ' .. MARK_TAG .. '\n')
        S.font = 'stroke letters for now (the last drive in the game font ended with the game closing; the font is '
            .. 'tried again next start)'
        return false
    end
    local ID, M = SR.IdString64, SR.Material
    if not (ID and ID.from_hex and G.text and G.destroy_text and G.material and M and M.set_texture and A.can_get) then
        S.font = 'stroke letters (this game version lacks a text function)'; return false
    end
    local function id(hex) local ok, v = pcall(ID.from_hex, hex); return ok and v or nil end
    local f, m, a, slot = id(pub.font), id(pub.material), id(pub.atlas), id(FONT_SLOT)
    if not (f and m and a and slot) then S.font = 'stroke letters (font ids unusable)'; return false end
    -- every resource must be loaded, and of the right type, before the engine is asked to use it
    for _, r in ipairs({{'font', f, pub.font}, {'material', m, pub.material}, {'texture', a, pub.atlas}}) do
        local okc, loaded = pcall(A.can_get, r[1], r[2])
        if not okc or loaded ~= true then
            S.font = string.format('stroke letters (%s %s: %s)', r[1], r[3], okc and 'not loaded' or ('check failed: ' .. tostring(loaded)))
            return false
        end
    end
    fontcheck('trying ' .. key .. ' ' .. MARK_TAG .. '\n')
    local okm, mh = pcall(G.material, g, m)
    if okm and mh ~= nil then pcall(M.set_texture, mh, slot, a) end
    colors(set.opacity)
    local okt, probe = pcall(G.text, g, 'R', f, 20, m, V3(-200, -200, LAYER), GREY)
    if not okt or probe == nil then
        fontcheck('refused ' .. key .. '\n')
        S.font = 'stroke letters (the game font was refused: ' .. tostring(probe) .. ')'; return false
    end
    pcall(G.destroy_text, g, probe)
    ft.ok, ft.font, ft.material, ft.key, ft.frame = true, f, m, key, S.frames
    ft.hex = {pub.font, pub.material, pub.atlas}
    ov.watch = 600                         -- frames in the font before the marker says ok
    S.font = 'the game\'s HUD font (' .. key .. ')'
    log()
    return true
end
-- The font's ids for this frame (made fresh each frame; the atlas bound again to the material, as HD2 HUD+ does).
-- False if they can't be made, and the panel goes back to the stroke letters.
local function font_frame(g)
    if ft.frame == S.frames then return ft.font ~= nil end
    ft.frame, ft.font, ft.material = S.frames, nil, nil
    local ID, M = SR.IdString64, SR.Material
    local okf, f = pcall(ID.from_hex, ft.hex[1])
    local okm, m = pcall(ID.from_hex, ft.hex[2])
    local oka, a = pcall(ID.from_hex, ft.hex[3])
    local oks, slot = pcall(ID.from_hex, FONT_SLOT)
    if not (okf and okm and oka and oks and f and m and a and slot) then return false end
    local okg, mh = pcall(G.material, g, m)
    if okg and mh ~= nil then pcall(M.set_texture, mh, slot, a) end
    ft.font, ft.material = f, m
    return true
end
local function text_x(g, str, x, h, size, align)
    local tw
    if G.text_extents then
        local okx, lo, hi = pcall(G.text_extents, g, str, ft.font, size)
        if okx and lo ~= nil and hi ~= nil then
            local lx, hx = comps(lo), comps(hi)
            if lx and hx then tw = hx - lx end
        end
    end
    tw = tw or text_width(str, h)
    return align == 'c' and x - tw / 2 or (align == 'r' and x - tw or x)
end
-- A changing value keeps its texts, updated in place with Gui.update_text (as HD2 HUD+ updates its numbers), and
-- only when what it shows changes (text, place, size or color); texts are destroyed when the panel goes away.
local function font_text(g, str, x, y, h, color, align, slot, key)
    local held = slot and ov.slots and ov.slots[slot]
    if held and held.key == key then return end
    local size = h / CAP
    local x0 = text_x(g, str, x, h, size, align)
    local shade = max(1, h * 0.06)
    local at_s, at_t = V3(x0 + shade, y - shade, LAYER), V3(x0, y, LAYER + 1)
    if held and G.update_text and not ov.no_update then
        local ok1 = pcall(G.update_text, g, held.shadow, str, ft.font, size, ft.material, at_s, SHADOW)
        local ok2 = pcall(G.update_text, g, held.text, str, ft.font, size, ft.material, at_t, color)
        if ok1 and ok2 then held.key = key; return end
        ov.no_update = true; note('Gui.update_text failed; values are redrawn instead')
    end
    -- (2.0.1 review) held texts not updated in place go now: 2.0 left them drawn under the new ones. (3.0.1 review)
    -- Every slot's, also once updates stopped (3.0: only the slot whose update failed; the others' old values stayed)
    if held then
        pcall(G.destroy_text, g, held.shadow); pcall(G.destroy_text, g, held.text)
        ov.slots[slot], held = nil, nil
    end
    local a = G.text(g, str, ft.font, size, ft.material, at_s, SHADOW)
    -- (3.0.1 review) the text over its shadow refused: the shadow goes too (3.0 kept it nowhere, left on screen)
    local okb, b = pcall(G.text, g, str, ft.font, size, ft.material, at_t, color)
    if not okb then
        if a ~= nil then pcall(G.destroy_text, g, a) end
        error(b, 0)
    end
    if slot and not ov.no_update then
        ov.slots = ov.slots or {}
        ov.slots[slot] = {shadow = a, text = b, key = key}
        return
    end
    local sink = ov.tsink or {}
    if a ~= nil then sink[#sink + 1] = a end
    if b ~= nil then sink[#sink + 1] = b end
end
-- A live value drawn in stroke letters (or a bar) keeps its own triangles and is only redrawn when what it shows
-- changes (1.2 review: redrawing every value together cost about 240 engine calls a frame while the rpm moved).
local function item_begin(slot, key)
    ov.items = ov.items or {}
    local it = ov.items[slot]
    if it and it.key == key then return false end
    if it then for _, id in ipairs(it.ids) do pcall(G.destroy_triangle, ov.gui, id) end end
    it = {key = key, ids = {}}
    ov.items[slot] = it
    ov.item_prev, ov.sink = ov.sink, it.ids
    return true
end
local function item_end() ov.sink, ov.item_prev = ov.item_prev, nil end
-- text with a dark edge; align 'l', 'c' or 'r' around x; y is the baseline
-- (slot: a live value, kept and only redrawn when what it shows changes)
local SEL_SLOTS = {'sel1', 'sel2', 'sel3', 'sel4', 'sel5'}
local function text(g, str, x, y, h, w, color, align, slot)
    -- (3.0 review) position, size and screen changes clear every slot (a frame redraw), so the text, its color and
    -- height are enough here (2.1: a formatted key of all five on every live redraw)
    local key = slot and (str .. (color == YELLOW and '|y|' or '|g|') .. h)
    -- (2.0.1 final review) the font's ids are made fresh for the frame that draws (font_frame does nothing more when
    -- they already are): engine ids from an earlier frame must never reach the engine
    if ft.ok and ft.gui == g and str ~= '^' and font_frame(g) then return font_text(g, str, x, y, h, color, align, slot, key) end
    if slot and not item_begin(slot, key) then return end
    local tw = text_width(str, h)
    local x0 = align == 'c' and x - tw / 2 or (align == 'r' and x - tw or x)
    for pass = 1, 2 do
        for i = 1, #str do
            local ch = str:sub(i, i)
            if ch ~= ' ' then glyph(g, ch, x0 + (i - 1) * 0.82 * h, y, h, pass == 1 and w + 1.5 or w, pass == 1 and SHADOW or color) end
        end
    end
    if slot then item_end() end
end
local function rect(g, x1, y1, x2, y2, color)
    local a, b, c, d = P(x1, y1), P(x2, y1), P(x2, y2), P(x1, y2)
    tri(g, a, b, c, color); tri(g, a, c, d, color)
end
local function frame_box(g, x1, y1, x2, y2, w, color)
    line(g, x1, y1, x2, y1, w, color); line(g, x2, y1, x2, y2, w, color)
    line(g, x2, y2, x1, y2, w, color); line(g, x1, y2, x1, y1, w, color)
end
local function bar(g, x1, x2, y, hgt, frac, w, color)
    rect(g, x1 - 1, y - 1, x2 + 1, y + hgt + 1, SHADOW)
    frame_box(g, x1, y, x2, y + hgt, w, GREY)
    frac = max(0, min(1, frac or 0))
    if frac > 0 then rect(g, x1, y, x1 + (x2 - x1) * frac, y + hgt, color) end
end

-- d: {selector = 0..4 or nil, gear = -1.. or nil, rpm, speed (km/h), fuel (litres), full (litres), smoke (rounds left,
-- Maelstrom only), smoke_full, frv (2.1: drawn like the game's FRV driver HUD: the current selector letter large and
-- white instead of yellow, and quarter marks on the rpm bar as on the fuel bar)}
-- part 'frame': separators, selector row, key hints, bar frames and labels; part 'live': the values
local function draw_panel(g, sw, sh, set, d, part)
    colors(set.opacity)
    local u = set.size * sh                       -- selector letter height
    local cx, cy = set.x * sw, set.y * sh
    local th = max(1.4, u * 0.075)
    local half = 6.3 * u
    local y2 = cy - 1.55 * u
    local small = 0.45 * u
    local lx1, lx2 = cx - half, cx - 2.2 * u
    local rx1, rx2 = cx + 2.2 * u, cx + half
    local y1 = cy + 0.3 * u
    local step = 1.25 * u
    if part == 'live' then
        -- row 1: the selector letters, the current one large and yellow
        local x = cx - step * 2
        for i, ch in ipairs(SELECTOR) do
            local on = d.selector == i - 1
            local h = on and 1.3 * u or 0.8 * u
            text(g, ch, x + (i - 1) * step - 0.3 * h, y1 - (on and 0.12 * u or 0), h, on and th * 1.6 or th, (on and not d.frv) and YELLOW or GREY, 'l', SEL_SLOTS[i])
        end
        local cur = d.selector == 1 and 'N' or (d.gear == -1 and 'R' or (d.gear and tostring(min(9, d.gear + 1)) or '-'))
        text(g, cur, lx1, y2 + 0.45 * u, 0.85 * u, th * 1.4, GREY, 'l', 'gear')
        local f = max(0, min(1, (d.rpm or 0) / RPM_MAX))
        local wpx = floor((lx2 - lx1) * f + 0.5)                  -- bars move in whole pixels
        if item_begin('rpmbar', wpx) then if wpx > 0 then rect(g, lx1, y2, lx1 + wpx, y2 + 0.28 * u, GREY) end; item_end() end
        text(g, tostring(floor((d.rpm or 0) / 50 + 0.5) * 50), lx1, y2 - 0.7 * u, small, th * 0.9, GREY, 'l', 'rpm')
        text(g, tostring(floor((d.speed or 0) + 0.5)), cx, y2 - 0.05 * u, 0.9 * u, th * 1.4, GREY, 'c', 'speed')
        f = d.fuel and d.full and d.full > 0 and max(0, min(1, d.fuel / d.full)) or 0
        wpx = floor((rx2 - rx1) * f + 0.5)
        if item_begin('fuelbar', wpx) then if wpx > 0 then rect(g, rx1, y2, rx1 + wpx, y2 + 0.28 * u, GREY) end; item_end() end
        text(g, (d.fuel and tostring(floor(d.fuel + 0.5)) or '-') .. ' L', rx2, y2 - 0.7 * u, small, th * 0.9, GREY, 'r', 'fuel')
        -- (1.2.2) the Maelstrom's smoke: a tall bar right of the panel, like the game's driver HUD, the count below
        if d.smoke then
            local sx1, sx2, sy1, sy2 = cx + half + 0.9 * u, cx + half + 1.35 * u, y2, cy + 1.45 * u
            f = max(0, min(1, d.smoke / max(1, d.smoke_full or d.smoke)))
            local hpx = floor((sy2 - sy1) * f + 0.5)
            if item_begin('smokebar', hpx) then if hpx > 0 then rect(g, sx1, sy1, sx2, sy1 + hpx, GREY) end; item_end() end
            text(g, tostring(floor(d.smoke + 0.5)), (sx1 + sx2) / 2, y2 - 0.9 * u, 0.6 * u, th, GREY, 'c', 'smoke')
        end
        return
    end
    -- separators above and below, like the game's panel
    rect(g, cx - half, cy + 1.75 * u, cx + half, cy + 1.75 * u + max(1, th * 0.6), GREY)
    rect(g, cx - half, cy - 2.75 * u, cx + half, cy - 2.75 * u + max(1, th * 0.6), GREY)
    -- row 1: CTRL [the selector letters: live part] shift (the keyboard's shift keys: left out on a controller)
    if not d.controller then
        local kh = 0.42 * u
        local kx = cx - step * 2 - 0.9 * u
        text(g, 'CTRL', kx - 0.25 * u, y1 + 0.1 * u, kh, th * 0.8, GREY, 'r')
        frame_box(g, kx - text_width('CTRL', kh) - 0.45 * u, y1 - 0.12 * u, kx - 0.05 * u, y1 + 0.72 * u, th * 0.7, GREY)
        local sx = cx + step * 2 + 0.9 * u
        glyph(g, '^', sx + 0.18 * u, y1 + 0.02 * u, 0.6 * u, th * 0.8, GREY)
        frame_box(g, sx, y1 - 0.12 * u, sx + 0.72 * u, y1 + 0.72 * u, th * 0.7, GREY)
    end
    -- row 2 frames and labels: rpm bar | speed | fuel bar (the values are the 'live' part)
    bar(g, lx1, lx2, y2, 0.28 * u, 0, th * 0.7, GREY)
    if d.frv then for i = 1, 3 do rect(g, lx1 + (lx2 - lx1) * i / 4 - th * 0.35, y2 - 0.08 * u, lx1 + (lx2 - lx1) * i / 4 + th * 0.35, y2, GREY) end end
    text(g, 'RPM', lx2, y2 - 0.7 * u, small, th * 0.9, GREY, 'r')
    text(g, 'KMH', cx, y2 - 0.7 * u, small, th * 0.9, GREY, 'c')
    bar(g, rx1, rx2, y2, 0.28 * u, 0, th * 0.7, GREY)
    for i = 1, 3 do rect(g, rx1 + (rx2 - rx1) * i / 4 - th * 0.35, y2 - 0.08 * u, rx1 + (rx2 - rx1) * i / 4 + th * 0.35, y2, GREY) end
    -- (3.2.0) no 'another player controls this tank' line any more: the panel hides then (see tick)
    if d.smoke then
        local sx1, sx2, sy1, sy2 = cx + half + 0.9 * u, cx + half + 1.35 * u, y2, cy + 1.45 * u
        rect(g, sx1 - 1, sy1 - 1, sx2 + 1, sy2 + 1, SHADOW)
        frame_box(g, sx1 - 0.12 * u, sy1 - 0.12 * u, sx2 + 0.12 * u, sy2 + 0.12 * u, th * 0.7, GREY)
    end
end

-- ---------------------------------------------------------------- keyboard or controller
-- The panel's key hints (CTRL and shift) are the keyboard's gear keys; on a controller they are left out. The device
-- is the one you used last (the engine's Keyboard, Mouse and Pad1..Pad8 input objects: a button press, a stick or
-- trigger moved, or the mouse moved), looked at every 5 frames while the panel is shown. Keyboard until a controller
-- is used; if the engine lacks these objects the hints stay.
-- (1.2.1: only controllers the engine reports as connected are read - looked up once a second - and each input
-- object's functions are looked up once; with all eight controller slots read every time the check cost about
-- 8 engine calls a frame, now about 1-2)
local input = {device = 'keyboard', next = 0, pads = nil, pads_next = 0, dev = {}, no_axes = {}}
local PAD_AXES, MOUSE_AXES = {'left', 'right', 'left_trigger', 'right_trigger'}, {'mouse'}
-- (sticks and triggers: past a third of their range; the mouse: a real movement, not a pixel of jitter)
local function index_of(dev, k) return dev[k] end
local function field(dev, k) local ok, v = pcall(index_of, dev, k); return ok and v or nil end
-- an input object's functions and axis numbers, looked up once (safely: an object the engine gives as plain
-- userdata can't be indexed without an error)
local function device_fns(dev, names)
    local d = input.dev[dev]
    if d then return d end
    d = {any = field(dev, 'any_pressed'), axis = field(dev, 'axis'), active = field(dev, 'active'), idx = {}}
    local axis_index = field(dev, 'axis_index')
    if d.axis and axis_index then
        for _, n in ipairs(names) do local ok, i = pcall(axis_index, n); if ok and type(i) == 'number' then d.idx[#d.idx + 1] = i end end
    end
    input.dev[dev] = d
    return d
end
local function used(dev, names, least)
    if type(dev) ~= 'table' and type(dev) ~= 'userdata' then return false end
    local d = device_fns(dev, names)
    if d.any then local ok, r = pcall(d.any); if ok and r then return true end end
    for _, i in ipairs(d.idx) do
        local ok, v = pcall(d.axis, i)
        if ok and v ~= nil then
            local x, y, z = comps(v)
            if x and math.abs(x) + math.abs(y or 0) + math.abs(z or 0) > least then return true end
        end
    end
    return false
end
local function connected_pads()
    if input.pads and S.frames < input.pads_next then return input.pads end
    input.pads_next = S.frames + RECHECK_EVERY
    local pads = {}
    for n = 1, 8 do
        local pad = field(SR, 'Pad' .. n)
        if pad == nil then break end
        local d = device_fns(pad, PAD_AXES)
        -- (3.1.1 review) only a pad that says it is connected is read (3.1.0 read every pad whose `active` was missing
        -- or failed: all eight, after a game update that changed it)
        local on
        -- (no way to ask - no `active`, or it fails: the first pad only, as one controller)
        if d.active then local ok, r = pcall(d.active); on = (ok and r == true) or (not ok and n == 1)
        else on = n == 1 end
        if on then pads[#pads + 1] = pad end
    end
    input.pads = pads
    return pads
end
-- (3.0.1 review) a key or mouse button pressed this frame (the input object's any_pressed, looked up already)
local function pressed(dev)
    local d = dev and input.dev[dev]
    if not (d and d.any) then return false end
    local ok, r = pcall(d.any)
    return ok and r == true
end
local function input_device()
    if S.frames < input.next then
        -- (3.0.1 review) on a controller the keyboard's and mouse's buttons are looked at every frame (one or two
        -- calls, only then): a press can show on its first frame only, and 3.0 missed about 4 in 5, so the key hints
        -- did not come back
        if input.device ~= 'controller' or not (pressed(input.kb) or pressed(input.mouse)) then return input.device end
        input.device = 'keyboard'
    else
        input.next = S.frames + 5
        if not SR then return input.device end
        if not input.kb then input.kb, input.mouse = field(SR, 'Keyboard') or false, field(SR, 'Mouse') or false end
        if used(input.kb, input.no_axes, 1) or used(input.mouse, MOUSE_AXES, 4) then   -- (3.0.1 review: no table made each time)
            input.device = 'keyboard'
        else
            for _, pad in ipairs(connected_pads()) do
                if used(pad, PAD_AXES, 0.3) then input.device = 'controller'; break end
            end
        end
    end
    if S.input ~= input.device then
        S.input = input.device
        if TESTER then S.input_api = (input.kb and 'Keyboard ' or '') .. (input.mouse and 'Mouse ' or '') .. #connected_pads() .. ' controller(s) connected' end
        log()
    end
    return input.device
end

-- ---------------------------------------------------------------- main loop
local last_logged
local seat_shown = {}
local function seat_text(seat)
    if seat_shown.kind ~= seat.kind or seat_shown.role ~= seat.role then
        seat_shown.kind, seat_shown.role = seat.kind, seat.role
        seat_shown.text = (TANKS[seat.kind] or TT.HULLS[seat.kind]).name .. ', ' .. (seat.role == 2 and 'gunner seat'
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
-- frv: the FRV counts as a seat too (the driver panel; the turret outline is tanks only).
local function core_seat(frv)
    local seat, core = rawget(_G, 'ArmoredOverhaulSeat'), rawget(_G, 'ArmoredOverhaulGunnerDrive')
    if type(seat) ~= 'table' or type(core) ~= 'table' then return nil, nil, false, 'waiting for Tank Core (seat reader)' end
    local cf = core.frames or 0
    if cf ~= core_watch.frames then core_watch.frames, core_watch.seen = cf, S.frames end
    local core_ok = core.phase ~= 'off' and S.frames - (core_watch.seen or S.frames) <= CORE_STALL
    if not core_ok then return nil, cf, false, 'waiting: Tank Core is not running (' .. tostring(core.status) .. ')' end
    local seated = seat.kind and (TANKS[seat.kind] or (frv and seat.kind == FRV_KIND)) and cf - (seat.frame or -1e9) <= SEAT_FRESH
    return seated and seat or nil, cf, true, 'watching'
end

-- ---------------------------------------------------------------- speed
-- (1.2.2) The speed is measured from how far the tank's hull moves, sampled every 6 frames against the game's clock
-- and smoothed. 1.2.0-1.2.1 showed the game's own speed figure times 3.6, taking it for metres a second, and a user saw
-- 112 km/h. Without the hull or a clock the game's figure is shown as it is (tester builds log both, to compare).
local SPEED_EVERY = 0.1          -- (3.1.1 review) seconds (3.1.0: 6 frames, 25 ms at 240 fps)
local spd = {hull = nil, x = nil, y = nil, z = nil, t = nil, kmh = nil, next = 0, src = nil, check_at = 0}
local clock = {t = 0, n = 0}          -- the update's frame times, added up (if the engine has no game clock)
local function game_time()
    if A.time_since_launch then
        local ok, t = pcall(A.time_since_launch)
        if ok and type(t) == 'number' then return t, 'game clock' end
    end
    if clock.n > 30 then return clock.t, 'frame times' end
    return nil
end
local function speed_reset() spd.hull, spd.kmh, spd.t, spd.next = nil, nil, nil, 0 end
-- (3.1.1 review) the panel's own timing in seconds: the update's frame times added up (no engine call), else frames at
-- 60 when the update gives none. The game's clock is read only when the speed is measured (every 0.1 s), as in 3.1.0.
local function panel_time()
    if clock.n > 0 then return clock.t end
    return S.frames / 60
end
local function measure_speed(world, seat, key, now)
    if now < spd.next then return spd.kmh end
    spd.next = now + SPEED_EVERY
    local hull
    if U and U.world_position and U.alive and W.units_by_resource then hull = TT.hull(world, seat.kind, S.frames, key) end
    S.tank, S.pick, S.finds = TT.tank, TT.pick, TT.finds
    local t, src = game_time()                          -- (no clock: the game's figure, as before)
    local x, y, z
    if hull ~= nil and t then
        local okp, p = pcall(U.world_position, hull, 1)
        if okp and p ~= nil then x, y, z = comps(p) end
    end
    -- (3.0.1 review) what the text would say is compared first, and the text made only when it changes (3.0: built
    -- every 6 frames)
    local how = not x and (hull == nil and 1 or (t and 2 or 3)) or src
    if how ~= spd.src then
        spd.src = how
        S.speed = how == 1 and 'the game\'s figure (the tank\'s hull not found)' or (how == 2 and 'the game\'s figure (the hull\'s position unreadable)'
            or (how == 3 and 'the game\'s figure (no clock)' or ('measured from the hull\'s movement (' .. src .. ')')))
    end
    if not x then speed_reset(); spd.next = now + SPEED_EVERY; return nil end
    if spd.hull == hull and spd.t and t > spd.t then
        local dt = t - spd.t
        local v = sqrt((x - spd.x) ^ 2 + (y - spd.y) ^ 2 + (z - spd.z) ^ 2) / dt * 3.6
        if dt < 1 and v < 250 then                       -- (else the tank was moved, or the game paused: skipped)
            spd.kmh = spd.kmh and spd.kmh * 0.4 + v * 0.6 or v
        end
    end
    spd.hull, spd.x, spd.y, spd.z, spd.t = hull, x, y, z, t
    -- (tester builds) the game's own figure next to the measured speed, while moving
    if TESTER and spd.kmh and spd.kmh > 5 and S.frames >= spd.check_at and tonumber(seat.speed) then
        spd.check_at = S.frames + 60
        local raw = tonumber(seat.speed)
        S.speed_check = string.format('game figure %.1f, measured %.1f km/h (game figure / measured = %.2f)', raw, spd.kmh, raw / spd.kmh)
    end
    return spd.kmh
end

local panel = {}
local hud_now, hud_was, live_now, live_was, live_gen = {}, {}, {}, {}, 0
local function differs(a, b)
    for i = 1, 8 do if a[i] ~= b[i] then return true end end
    return false
end
-- (2.0) the font marker also says ok when the panel is hidden normally after 30 frames or more in the font (1.2.1-2.0
-- Test 8: only after 600 frames, so leaving the seat sooner and quitting looked like a crash at the next start)
function font_proven(how)
    if ft.ok and (ov.watch or 0) > 0 and ov.watch <= 570 then
        ov.watch = 0
        fontcheck('ok ' .. ft.key .. ' ' .. MARK_TAG .. '\n')
        S.font = 'the game\'s HUD font (' .. ft.key .. '), proven ' .. how; log()
    end
end
local function hide_panel(gear_why)
    font_proven('(shown, then hidden normally)')
    if ov.hkey or ov.lkey or ov.slots or ov.items or (ov.hud and #ov.hud > 0) then clear_hud() end
    set_visible(false)
    gear_text = nil; S.gear = gear_why
end
-- the last values drawn, for the 'gear' line (numbers only; the text is made when read)
local gs = {}
local function gear_line()
    return string.format('selector %s, gear %s, %d rpm, %d km/h, fuel %s%s', gs.selector and SELECTOR[gs.selector + 1] or '?',
        gs.gear == -1 and 'R' or (gs.gear and tostring(gs.gear + 1) or '?'), floor(gs.rpm + 0.5), floor(gs.speed + 0.5),
        gs.fuel and string.format('%.0f L', gs.fuel) or '?', (gs.smoke and string.format(', smoke %d', gs.smoke) or '')
        .. (gs.remote and (gs.frv and ', another player controls this FRV' or ', another player controls this tank') or ''))
end
-- The main world, asked for once a frame (3.0.1 review: every frame while the panel shows, as the Vehicle Indicator
-- does, so a new main world has the screen GUI checked at once; 2.0-3.0 asked only on the frames that needed it and
-- could draw into a GUI whose world had gone in between). (3.0 review) Made once (2.1: a new function every frame);
-- `wc` is cleared at the start of every frame (never kept from one frame to the next).
local wc
local function world_now()
    if wc == nil then local okw, w = pcall(A.main_world); wc = okw and w or false end
    return wc or nil
end
local function tick()
    S.frames = S.frames + 1
    wc = nil
    menu_link(S.frames)
    local seat, cf, core_ok, idle = core_seat(true)
    -- (3.2.0) shown only while you are the one driving: not when another player's game runs the vehicle (they drove it
    -- last, so it doesn't answer you; 1.3-3.1.1 showed the panel with a warning), and not when turned off in the menu
    local off = not panel_on
    -- (the Vehicle Indicator docks beside the panel only while the panel can show: off in the menu, it sits on its own)
    if off ~= (PLACE.menu_off or false) then
        PLACE.menu_off = off
        if off then PLACE.show = false elseif S.api == 'ok' or S.api == 'unchecked' then PLACE.show = true end
    end
    if off or not seat or seat.driving ~= true or seat.remote == true then
        TT.reset(); speed_reset()
        hide_panel(off and 'hidden (turned off in the Mod Options Menu)' or (not seat and 'hidden (not in a vehicle)')
            or (seat.driving ~= true and 'hidden (not driving from the gunner seat)') or 'hidden (another player\'s game runs this vehicle)')
        if off then idle = 'off (turned off in the Mod Options Menu)' end
        S.seat = seat and seat_text(seat) or (core_ok and 'not in a vehicle' or 'unknown')
        -- (3.0.1 review) last_logged kept up to date (3.0: driving again wrote nothing, and the file kept the waiting
        -- text for up to 30 s); a panel that is off for good (the engine lacks something, drawing failed) keeps
        -- saying so (3.0: the waiting text replaced it)
        if S.api == 'ok' or S.api == 'unchecked' then
            S.status = off and idle or (seat and (seat.driving == true and 'waiting (another player\'s game runs this vehicle: take the driver seat once to get it back)'
                or 'waiting (you are not driving from the gunner seat)') or idle)
        end
        if S.status ~= last_logged then last_logged = S.status; log() end
        return
    end
    if not api_ok() then
        PLACE.show = false                                  -- (3.0.1 review) off: the Indicator does not dock
        if S.status ~= last_logged then last_logged = S.status; log() end
        return
    end
    S.seat = seat_text(seat)
    local world = world_now()
    if world == nil then
        set_visible(false)
        S.status = 'no world'
        if S.status ~= last_logged then last_logged = S.status; log() end
        return
    end
    if world ~= ov.main then ov.main = world; ov.next_check = 0 end     -- (3.0.1 review) a new main world: checked now
    local g = overlay_gui(world)
    if not g then
        set_visible(false)                                  -- (2.0.1 review: not left frozen on screen)
        S.status = 'no screen gui'
        if S.status ~= last_logged then last_logged = S.status; log() end
        return
    end
    local sw, sh = screen_size()
    local finds = TT.finds
    local now = panel_time()
    local measured = measure_speed(world, seat, cf, now)
    tracker_errors()
    if TT.finds ~= finds then log() end
    -- redrawn when a shown value changes, at most every 6 frames
    local d = panel
    d.selector = type(seat.selector) == 'number' and seat.selector or nil
    d.gear = type(seat.gear) == 'number' and seat.gear or nil
    -- (3.1.1 review) values out of range (an odd read: NaN, or a huge number) are not shown and don't become the fuel
    -- bar's full mark (3.1.0 kept one for the session: the bar read near empty in every tank of that kind)
    local rpm, fuel = tonumber(seat.rpm), tonumber(seat.fuel)
    d.rpm = (rpm and rpm >= 0 and rpm < 100000) and rpm or 0
    d.fuel = (fuel and fuel >= 0 and fuel < 100000) and fuel or nil
    d.speed = measured or tonumber(seat.speed) or 0
    if not (d.speed >= 0 and d.speed < 1000) then d.speed = 0 end
    if d.fuel then fuel_full[seat.kind] = max(fuel_full[seat.kind] or 0, d.fuel) end
    d.full = fuel_full[seat.kind]
    d.smoke = type(seat.smoke) == 'number' and seat.smoke or nil
    d.smoke_full = type(seat.smoke_full) == 'number' and seat.smoke_full or nil
    d.controller = input_device() == 'controller'
    d.remote = seat.remote == true
    d.frv = seat.kind == FRV_KIND
    -- (2.0.1 review) What decides a redraw is compared value by value: the frame (screen, settings, keyboard or
    -- controller, smoke, remote, font) and the live values. 2.0 built two long text keys every frame for this.
    local H, Lv = hud_now, live_now
    -- the game font once it can be used (the panel is redrawn in it when it becomes ready)
    local font = font_ready(g, settings)
    H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8] = sw, sh, settings.sig, d.controller, d.smoke ~= nil, d.remote, font, d.frv
    Lv[1], Lv[2], Lv[3], Lv[4] = d.gear or false, d.selector or false, floor(d.rpm / 50 + 0.5), floor(d.speed + 0.5)
    Lv[5], Lv[6], Lv[7] = d.fuel and floor(d.fuel + 0.5) or false, d.smoke or false, d.smoke_full or false
    local frame_due = not ov.hkey or differs(H, hud_was)
    -- (3.1.1 review) the live values at most 10 times a second (3.1.0: every 6 frames, 40 times a second at 240 fps)
    local live_due = frame_due or (now >= (ov.lnext or 0) and (not ov.lkey or differs(Lv, live_was)))
    -- (3.1.1 review) after a failed drawing, half a second before the next try (see below)
    if now < (ov.retry_at or 0) then frame_due, live_due = false, false end
    -- (2.0.1 review) the font's ids are made only on frames that draw text (2.0: every frame)
    if font and (frame_due or live_due) and not font_frame(g) then
        font_refused('stroke letters (the game font ids could not be made)')
        font, H[7], frame_due, live_due = false, false, true, true
    end
    local okp, perr = true, nil
    if frame_due then
        clear_hud(true)
        ov.sink, ov.tsink = ov.hud, ov.hud_t
        okp, perr = pcall(draw_panel, g, sw, sh, settings, d, 'frame')
        ov.sink, ov.tsink = nil, nil
        ov.hkey = okp or nil
        if okp then for i = 1, 8 do hud_was[i] = H[i] end end
    end
    if okp and live_due then
        clear_live()
        ov.sink, ov.tsink = ov.hudl, ov.hudl_t
        okp, perr = pcall(draw_panel, g, sw, sh, settings, d, 'live')
        ov.sink, ov.tsink = nil, nil
        live_gen = live_gen + 1
        ov.lkey, ov.lnext = okp and live_gen or nil, now + 0.1
        if okp then for i = 1, 7 do live_was[i] = Lv[i] end end
    end
    if ft.ok and (ov.watch or 0) > 0 then
        ov.watch = ov.watch - 1
        if ov.watch == 0 then ov.watch = 1; font_proven('for 600 frames') end
    end
    if not okp then
        S.errors = S.errors + 1; S.last_error = 'driver panel failed: ' .. tostring(perr); clear_hud(true)
        if ft.ok then font_refused('stroke letters (the game font failed: ' .. tostring(perr) .. ')') end
        -- (3.1.1 review) failures in a row, tried again half a second later (3.1.0 counted every failure of the session and
        -- retried the next frame: 20 spread over a long session, or a problem lasting 20 frames, turned it off for good)
        draw_fails = draw_fails + 1
        ov.retry_at = now + 0.5
        if draw_fails >= 20 then S.api = 'drawing failed'; S.status = 'off (drawing failed, see the notes)'; PLACE.show = false; log() end
        return
    end
    if frame_due or live_due then draw_fails, ov.retry_at = 0, nil end
    -- (the log text on each live redraw, at most every 6 frames; 3.0 review: the shape counts are tester-only)
    if ov.logged ~= ov.lkey then
        ov.logged = ov.lkey
        gs.selector, gs.gear, gs.rpm, gs.speed, gs.fuel, gs.smoke, gs.remote, gs.frv = d.selector, d.gear, d.rpm, d.speed, d.fuel, d.smoke, d.remote, d.frv
        if gear_text ~= gear_line then rawset(S, 'gear', nil); gear_text = gear_line end
        if TESTER then
            local live_n, texts_n = #(ov.hudl or {}), #(ov.hud_t or {}) + #(ov.hudl_t or {})
            for _, it in pairs(ov.items or {}) do live_n = live_n + #it.ids end
            for _ in pairs(ov.slots or {}) do texts_n = texts_n + 2 end
            S.panel = string.format('%d frame + %d live shapes, %d texts', #(ov.hud or {}), live_n, texts_n)
        end
    end
    set_visible(true)
    S.drawn = S.drawn + 1
    S.status = 'showing'
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
            -- (3.1.1 review) a font try under way is settled (3.1.0 left 'trying': the next start skipped the font as if
            -- the game had closed)
            if ft.ok then pcall(font_refused, 'stroke letters (stopped after an error)') end
            PLACE.show = false                              -- (3.0.1 review) the Indicator no longer docks next to it
            pcall(set_visible, false)                       -- (2.0.1 review: not left frozen on screen)
            log()
        end
    end
    return ...
end
update = function(dt, ...)
    if type(dt) == 'number' and dt > 0 and dt < 1 then clock.t, clock.n = clock.t + dt, clock.n + 1 end
    return after(pcall(previous_update, dt, ...))
end
log()

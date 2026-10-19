-- HD2-Addon: mods/chef/armored_overhaul_fire_rate_display
-- Armored Overhaul 3.7.0 - Fire Rate Display (part of the Maelstrom Fire Rate option): when the TD-110 Maelstrom gun's
-- fire rate changes (the hold-reload choice: 1200, 1800 or 2400 rounds a minute), the new rate pops up next to the gun's
-- ammo bar for a moment, then fades. Drawn only on your screen. Written from scratch.
--
-- The rate comes from the Tank Core addon (ArmoredOverhaulSeat.rate_rpm / rate_seq): rate_seq goes up when Tank Core
-- reads a new choice from the game: as the hold-reload menu closes (3.6.1 Test 14), or (3.6.2, a controller) once the
-- game's setting has held a new rate for a second. Firing never pops it up (3.6.2 Test 2).
--
-- Drawn the way HD2 HUD+ puts its widgets on screen (a retained screen GUI in the game's overlay world, made with
-- World.create_screen_gui(world, 'scale', 1, 1)), in the game's own HUD font when Tank Core has read it, else in stroke
-- letters. The engine's ids, vectors and colors only live for the frame they are made in: they are made fresh in every
-- frame that draws.
if type(jit) == 'table' and type(jit.off) == 'function' then jit.off(true, true) end
if rawget(_G, 'ArmoredOverhaulFireRateDisplay') then return end

local TESTER = false
local sqrt, floor, max, min = math.sqrt, math.floor, math.max, math.min

local SEAT_FRESH = 45                -- frames a published seat stays valid (the core refreshes it every few frames)
local RECHECK_EVERY = 60             -- frames between checks of the overlay world and the screen size
local CORE_STALL = 60                -- frames without a Tank Core update before its seat is no longer trusted
local MAELSTROM, GUNNER = 0x2C, 2

-- Where and how long. The game's HUD draws the gun's ammo bar beside the crosshair (screen middle), its bullet mark
-- 0.147 of the screen height left of the middle (my screenshot, 2000 x 838): the text ends PLACE.gap of the height
-- left of the middle, centered on the bar's middle. HOLD seconds fully shown, then FADE seconds fading out.
local PLACE = {gap = 0.165, size = 0.016, opacity = 0.9}
local HOLD, FADE = 2.5, 1.0

local TITLE, LOG_FILE = 'Fire Rate Display', 'ArmoredOverhaul-FireRateDisplay.log'
local S = {version = '3.7.0', status = 'starting', api = 'unchecked', gui = 'none', seat = 'none', font = 'not needed yet',
           shown = 'nothing yet', times_shown = 0, place = 'not drawn yet', last_error = 'none', frames = 0, errors = 0, drawn = 0}
rawset(_G, 'ArmoredOverhaulFireRateDisplay', S)

-- The logs folder (the same helper every Armored Overhaul addon defines, so none gains a top-level local)
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
local SR = rawget(_G, 'stingray')

-- ---------------------------------------------------------------- log
local LOG_MAIN = {'version', 'status', 'api', 'gui', 'seat', 'font', 'shown', 'times_shown', 'place', 'errors', 'last_error'}
local LOG_TESTER = {'frames', 'drawn'}
local notes = {}
local function note(s)
    for _, n in ipairs(notes) do if n == s then return end end
    if #notes < 20 then notes[#notes + 1] = s end
end
local log_text
local function log()
    pcall(function()
        local b = {'Armored Overhaul - ', TITLE, '\n'}
        for _, k in ipairs(LOG_MAIN) do b[#b + 1] = (k:gsub('_', ' ')) .. ': ' .. tostring(S[k]) .. '\n' end
        for _, n in ipairs(notes) do b[#b + 1] = 'note: ' .. n .. '\n' end
        if TESTER then
            b[#b + 1] = '-- tester details --\n'
            for _, k in ipairs(LOG_TESTER) do b[#b + 1] = k .. ': ' .. tostring(S[k]) .. '\n' end
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
    local root = rawget(_G, 'ArmoredOverhaulLogsDir')()
    return root and root ~= '' and (root .. '\\' .. name) or nil
end

-- ---------------------------------------------------------------- engine API (checked once)
local A, W, G, V3, V2, C
local function api_ok()
    if S.api == 'ok' then return true end
    if S.api ~= 'unchecked' then return false end
    if type(SR) ~= 'table' then S.api = 'missing: stingray'; return false end
    A, W, G, V3, V2, C = SR.Application, SR.World, SR.Gui, SR.Vector3, SR.Vector2, SR.Color
    local need = {{A, 'Application', 'main_world'}, {A, 'Application', 'worlds'}, {W, 'World', 'create_screen_gui'},
                  {G, 'Gui', 'triangle'}, {G, 'Gui', 'destroy_triangle'}}
    local missing = {}
    for _, n in ipairs(need) do
        if type(n[1]) ~= 'table' or (type(n[1][n[3]]) ~= 'function' and type(n[1][n[3]]) ~= 'userdata') then
            missing[#missing + 1] = n[2] .. '.' .. n[3]
        end
    end
    if not pcall(V3, 1, 2, 3) then missing[#missing + 1] = 'Vector3()' end
    if not pcall(C, 255, 1, 2, 3) then missing[#missing + 1] = 'Color()' end
    if #missing > 0 then S.api = 'missing: ' .. table.concat(missing, ', '); S.status = 'off (this game build lacks what it needs)'; return false end
    S.api = 'ok'
    return true
end
local function xyz(v) return v.x, v.y, v.z end
local function comps(v)
    local ok, x, y, z = pcall(xyz, v)
    if ok and type(x) == 'number' then return x, y, z end
    if V3 and type(V3.to_elements) == 'function' then
        local ok2, a, b, c = pcall(V3.to_elements, v)
        if ok2 and type(a) == 'number' then return a, b, c end
    end
    return nil
end

-- ---------------------------------------------------------------- the overlay screen GUI (as HD2 HUD+ does it)
local LAYER, DEPTH = 3, 0
local TRI_MATERIAL = 'core/performance_hud/debug'
local ov = {world = nil, gui = nil, visible = nil, texts = nil, tris = nil, key = nil}
local draw_fails = 0
local function scan_worlds(main, w)
    local okw, worlds = pcall(A.worlds)
    if not okw or type(worlds) ~= 'table' then return nil, 0, nil end
    local target, live = nil, false
    for i = 1, #worlds do
        local x = worlds[i]
        if x ~= nil and x ~= main and not target then target = x end
        if w ~= nil and x == w then live = true end
    end
    return target, #worlds, live
end
local function forget_gui() ov.gui, ov.world, ov.visible, ov.alive_frame, ov.texts, ov.tris, ov.key = nil, nil, nil, nil, nil, nil, nil end
local function gui_alive()
    if not ov.gui then return false end
    if ov.alive_frame == S.frames then return true end
    local _, _, live = scan_worlds(nil, ov.world)
    if live == nil then return false end
    if not live then forget_gui(); return false end
    ov.alive_frame = S.frames
    return true
end
-- the shown rate's texts (game font) or triangles (stroke letters), destroyed
local function clear(checked)
    if ov.gui and (checked or gui_alive()) then
        for _, id in ipairs(ov.texts or {}) do pcall(G.destroy_text, ov.gui, id) end
        for _, id in ipairs(ov.tris or {}) do pcall(G.destroy_triangle, ov.gui, id) end
    end
    ov.texts, ov.tris, ov.key = nil, nil, nil
end
local function set_visible(v)
    if ov.gui and ov.visible ~= v and G.set_visible and gui_alive() then
        if pcall(G.set_visible, ov.gui, v) then ov.visible = v end
    end
end
local function overlay_gui(main)
    if ov.gui and S.frames < (ov.next_check or 0) then return ov.gui end
    if main == nil then return nil end
    ov.next_check = S.frames + RECHECK_EVERY
    local target, count, live = scan_worlds(main, ov.world)
    if live == nil then ov.next_check = 0; S.gui = 'world list unreadable'; return nil end
    if ov.gui and live and ov.world ~= main then ov.alive_frame = S.frames; return ov.gui end
    if ov.gui and live then
        clear(true)
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
local function screen_size()
    if S.frames >= screen.next_check then screen.w, screen.h = read_screen_size(); screen.next_check = S.frames + RECHECK_EVERY end
    return screen.w, screen.h
end
local function P(x, y) return V3(x, DEPTH, y) end         -- a screen point: x from the left, y up from the bottom
local function tri(g, a, b, c, color)
    local id
    if ov.style == nil or ov.style == 'plain' then
        local ok, r = pcall(G.triangle, g, a, b, c, LAYER, color)
        if ok then ov.style = 'plain'; id = r
        elseif ov.style == nil then ov.style = 'material'; note('plain Gui.triangle failed (' .. tostring(r) .. '); using ' .. TRI_MATERIAL)
        else error(r) end
    end
    if ov.style == 'material' then
        local uv = V2(0, 0)
        id = G.triangle(g, a, b, c, LAYER, color, TRI_MATERIAL, uv, uv, uv)
    end
    if id ~= nil then local t = ov.tris; t[#t + 1] = id end
end
local function line(g, x1, y1, x2, y2, w, color)
    local dx, dy = x2 - x1, y2 - y1
    local l = sqrt(dx * dx + dy * dy)
    if l < 1e-3 then return end
    local nx, ny = -dy / l * w / 2, dx / l * w / 2
    local a, b = P(x1 + nx, y1 + ny), P(x2 + nx, y2 + ny)
    local c, d = P(x2 - nx, y2 - ny), P(x1 - nx, y1 - ny)
    tri(g, a, b, c, color); tri(g, a, c, d, color)
end

-- ---------------------------------------------------------------- stroke letters (until the game's font is usable)
-- (the Driver Panel's: strokes in a 0.6 x 1 box, x right, y up)
local GLYPHS = {
    R = {{0, 0, 0, 1, 0.42, 1, 0.6, 0.84, 0.6, 0.66, 0.42, 0.5, 0, 0.5}, {0.28, 0.5, 0.6, 0}},
    P = {{0, 0, 0, 1, 0.44, 1, 0.6, 0.84, 0.6, 0.66, 0.44, 0.5, 0, 0.5}},
    M = {{0, 0, 0, 1, 0.3, 0.45, 0.6, 1, 0.6, 0}},
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
local function text_width(str, h) return (#str * 0.82 - 0.22) * h end
local function stroke_text(g, str, x_right, y, h, color, shadow)
    local x0 = x_right - text_width(str, h)
    local w = max(1.5, h * 0.13)
    for pass = 1, 2 do
        for i = 1, #str do
            for _, stroke in ipairs(GLYPHS[str:sub(i, i)] or {}) do
                for k = 1, #stroke - 3, 2 do
                    local px = x0 + (i - 1) * 0.82 * h
                    line(g, px + stroke[k] * h, y + stroke[k + 1] * h, px + stroke[k + 2] * h, y + stroke[k + 3] * h,
                         pass == 1 and w + 1.5 or w, pass == 1 and shadow or color)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------- the game's HUD font (as the Driver Panel uses it)
-- Tank Core publishes the HUD's font, material and glyph atlas (ArmoredOverhaulUIFont); the atlas is bound to the
-- material's glyph slot in every frame that draws. Safety net as the Driver Panel's: each resource checked with
-- Application.can_get first, and a marker file says 'trying' until the font has been shown for a while; if the game
-- closed in between, the next start uses the stroke letters once.
local FONT_SLOT = '88bac99b00000000'
local CAP = 0.72
local MARK_TAG = '[ids per frame]'
local ft = {}
local function fontcheck(write)
    local path = logs_path('ArmoredOverhaul-FireRateDisplay.fontcheck')
    if not path or not io or not io.open then return nil end
    if write then local f = io.open(path, 'w'); if f then f:write(write); f:close() end; return end
    local f = io.open(path, 'r'); if not f then return nil end
    local t = f:read('*a'); f:close(); return t
end
local function font_refused(why)
    if ft.ok and ft.key then fontcheck('refused ' .. ft.key .. '\n') end
    ft.ok, ft.watch, S.font = false, 0, why
end
local function font_proven(how)
    if ft.ok and (ft.watch or 0) > 0 then
        ft.watch = 0
        fontcheck('ok ' .. ft.key .. ' ' .. MARK_TAG .. '\n')
        S.font = 'the game\'s HUD font (' .. ft.key .. '), proven ' .. how; log()
    end
end
local function font_ready(g)
    if ft.gui == g then return ft.ok == true end
    local pub = rawget(_G, 'ArmoredOverhaulUIFont')
    if type(pub) ~= 'table' or not pub.font then S.font = 'stroke letters (the game\'s HUD font not read yet)'; return false end
    if ft.ok and (ft.watch or 0) > 0 then font_proven('(shown, then the screen GUI changed)') end
    ft = {gui = g}
    local key = pub.font .. ' ' .. pub.material .. ' ' .. pub.atlas
    local last = fontcheck()
    if S.font_skip == key or (last and last:find('^trying') and last:find(key, 1, true) and last:find(MARK_TAG, 1, true)) then
        if S.font_skip ~= key then fontcheck('skipped once ' .. key .. ' ' .. MARK_TAG .. '\n'); S.font_skip = key end
        S.font = 'stroke letters for now (the last time in the game font ended with the game closing; tried again next start)'
        return false
    end
    local ID, M = SR.IdString64, SR.Material
    if not (ID and ID.from_hex and G.text and G.destroy_text and G.material and M and M.set_texture and A.can_get) then
        S.font = 'stroke letters (this game version lacks a text function)'; return false
    end
    local function id(hex) local ok, v = pcall(ID.from_hex, hex); return ok and v or nil end
    local f, m, a, slot = id(pub.font), id(pub.material), id(pub.atlas), id(FONT_SLOT)
    if not (f and m and a and slot) then S.font = 'stroke letters (font ids unusable)'; return false end
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
    local okt, probe = pcall(G.text, g, '1', f, 20, m, V3(-200, -200, LAYER), C(0, 0, 0, 0))
    if not okt or probe == nil then
        fontcheck('refused ' .. key .. '\n')
        S.font = 'stroke letters (the game font was refused: ' .. tostring(probe) .. ')'; return false
    end
    pcall(G.destroy_text, g, probe)
    ft.ok, ft.key, ft.hex, ft.watch = true, key, {pub.font, pub.material, pub.atlas}, 600
    S.font = 'the game\'s HUD font (' .. key .. ')'
    log()
    return true
end
-- the font's ids for this frame (made fresh; the atlas bound again to the material)
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

-- ---------------------------------------------------------------- drawing the rate
-- The text is made once per pop (two texts: a shadow and the text) and only its color is changed while it fades
-- (Gui.update_text, when the shown alpha step changes); in stroke letters it is redrawn at 16 alpha steps.
local function draw(g, sw, sh, str, alpha, font)
    local h = max(10, PLACE.size * sh)
    local xr = sw / 2 - PLACE.gap * sh
    if ov.place_at ~= sw * 100000 + sh then             -- (3.6.1 Test 7: where it is drawn; written when the screen size changes)
        ov.place_at = sw * 100000 + sh
        S.place = string.format('text ends at x %.0f, middle at y %.0f (from the bottom), %.0f px tall, on a %dx%d screen', xr, sh / 2, h, sw, sh)
    end
    local y = sh / 2 - h / 2
    local a = floor(255 * PLACE.opacity * alpha + 0.5)
    local col, shade = C(a, 235, 238, 240), C(floor(a * 0.55), 0, 0, 0)
    if font then
        local size = h / CAP
        local x0 = xr - text_width(str, h)
        if G.text_extents then
            local okx, lo, hi = pcall(G.text_extents, g, str, ft.font, size)
            if okx and lo ~= nil and hi ~= nil then
                local lx, hx = comps(lo), comps(hi)
                if lx and hx then x0 = xr - (hx - lx) end
            end
        end
        local d = max(1, h * 0.08)
        local at_s, at_t = V3(x0 + d, y - d, LAYER), V3(x0, y, LAYER + 1)
        local key = str .. '|' .. sw .. 'x' .. sh
        if ov.texts and ov.key == key and G.update_text and not ov.no_update then
            local ok1 = pcall(G.update_text, g, ov.texts[1], str, ft.font, size, ft.material, at_s, shade)
            local ok2 = pcall(G.update_text, g, ov.texts[2], str, ft.font, size, ft.material, at_t, col)
            if ok1 and ok2 then return end
            ov.no_update = true; note('Gui.update_text failed; the text is made again instead')
        end
        clear(true)
        local t1 = G.text(g, str, ft.font, size, ft.material, at_s, shade)
        local okb, t2 = pcall(G.text, g, str, ft.font, size, ft.material, at_t, col)
        if not okb then if t1 ~= nil then pcall(G.destroy_text, g, t1) end; error(t2, 0) end
        ov.texts, ov.key = {t1, t2}, key
    else
        clear(true)
        ov.tris = {}
        stroke_text(g, str, xr, y, h, col, shade)
    end
end

-- ---------------------------------------------------------------- main loop
local clock = {t = 0, n = 0}
local function now() return clock.n > 0 and clock.t or S.frames / 60 end
local core_watch = {}
local pop = {seen = nil, rpm = nil, t0 = nil, step = nil}
local last_logged
local wc
local function hide(why, done)
    if ov.texts or ov.tris then clear() end
    if done and ft.ok and (ft.watch or 0) > 0 then font_proven('(shown and faded out)') end
    set_visible(false)
    pop.t0, pop.step = nil, nil
    S.status = why
end
local function tick()
    S.frames = S.frames + 1
    wc = nil
    local seat, core = rawget(_G, 'ArmoredOverhaulSeat'), rawget(_G, 'ArmoredOverhaulGunnerDrive')
    if type(seat) ~= 'table' or type(core) ~= 'table' then hide('waiting for Tank Core'); return end
    local cf = core.frames or 0
    if cf ~= core_watch.frames then core_watch.frames, core_watch.seen = cf, S.frames end
    local core_ok = core.phase ~= 'off' and S.frames - (core_watch.seen or S.frames) <= CORE_STALL
    local seq = tonumber(seat.rate_seq)
    if pop.seen == nil then pop.seen = seq end
    if seq and pop.seen and seq ~= pop.seen then
        pop.seen = seq
        local rpm = tonumber(seat.rate_rpm)
        if rpm then pop.rpm, pop.t0, pop.step = rpm, now(), nil; S.times_shown = S.times_shown + 1; S.shown = string.format('%d RPM (frame %d)', rpm, S.frames) end
    end
    local in_gun = core_ok and seat.kind == MAELSTROM and seat.role == GUNNER and cf - (seat.frame or -1e9) <= SEAT_FRESH
    S.seat = in_gun and 'Maelstrom gunner seat' or 'not in a Maelstrom gunner seat'
    local age = pop.t0 and now() - pop.t0
    if not in_gun or not age or age >= HOLD + FADE then
        local why = in_gun and 'ready (shows when the rate changes)' or 'waiting (not in a Maelstrom gunner seat)'
        if pop.t0 or ov.texts or ov.tris or S.status ~= why then hide(why, age and age >= HOLD + FADE) end
        if S.status ~= last_logged then last_logged = S.status; log() end
        return
    end
    if not api_ok() then if S.status ~= last_logged then last_logged = S.status; log() end; return end
    if wc == nil then local okw, w = pcall(A.main_world); wc = okw and w or false end
    local world = wc or nil
    if world == nil then set_visible(false); S.status = 'no world'; return end
    if world ~= ov.main then ov.main = world; ov.next_check = 0 end
    local g = overlay_gui(world)
    if not g then set_visible(false); S.status = 'no screen gui'; return end
    local sw, sh = screen_size()
    local alpha = age < HOLD and 1 or max(0, 1 - (age - HOLD) / FADE)
    local font = font_ready(g)
    local steps = font and 255 or 16
    local step = floor(alpha * steps + 0.5)
    local key = pop.rpm .. '|' .. sw .. 'x' .. sh .. '|' .. tostring(font)
    if step == pop.step and key == pop.key and (ov.texts or ov.tris) then return end      -- nothing to change on screen this frame
    if not gui_alive() then ov.next_check = 0; return end
    if font and not font_frame(g) then font_refused('stroke letters (the game font ids could not be made)'); font = false end
    local ok, err = pcall(draw, g, sw, sh, string.format('%d RPM', pop.rpm), step / steps, font)
    if not ok then
        S.errors = S.errors + 1; S.last_error = 'drawing failed: ' .. tostring(err); clear(true)
        if ft.ok then font_refused('stroke letters (the game font failed: ' .. tostring(err) .. ')') end
        draw_fails = draw_fails + 1
        if draw_fails >= 20 then S.api = 'drawing failed'; S.status = 'off (drawing failed, see the last error)'; log() end
        return
    end
    draw_fails = 0
    pop.step, pop.key = step, key
    set_visible(true)
    S.drawn = S.drawn + 1
    S.status = 'showing ' .. pop.rpm .. ' RPM'
    if S.status ~= last_logged then last_logged = S.status; log() end
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
            if ft.ok then pcall(font_refused, 'stroke letters (stopped after an error)') end
            pcall(set_visible, false)
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

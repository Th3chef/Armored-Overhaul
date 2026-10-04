-- HD2-Addon: mods/chef/armored_overhaul_gunner_drive
-- Armored Overhaul 3.2.0 - Tank Core: reads which vehicle seat you sit in (published for the Vehicle
-- Indicator, the Gunner Camera and the driver panel) and, with the Gunner Drive option's flags installed, lets you
-- drive the TD-220 Bastion, the TD-110 Maelstrom and the M-102 FRV from the gunner seat when nobody is driving; also
-- the horn, the Maelstrom's smoke, the Autoloader and the vehicle's health. Written from scratch.
--
-- You stay the gunner the whole time (gunner HUD, turret camera, aiming and fire keys are the game's own).
-- While you sit alone in a supported gunner seat, this addon copies your driving keys into the vehicle's
-- driver-input record every frame - the same record the game's own driver code fills for a real driver.
-- When you leave the seat, open a menu or someone takes the wheel, the record is cleared and the real driver
-- (if any) takes over. Only your own seat is used, and nothing is written into other players' state.
--
-- Game structures used (all offsets are read from, or checked against, the game's code at start-up):
--   seat table     [seat global]  map {entries,cap,empty,mult} at +0x20 (player -> row), rows at +0x48,
--                  64-byte rows: +0x00 vehicle, +0x04 seat kind, +0x08 role (2 gunner, 1/4 driver), +0x30 moving
--   vehicle table  [vehicle global] map at +0x38 (vehicle -> index), 48-byte driver-input records at +0x58,
--                  0xD28-byte vehicle states at +0x68 (the game's vehicle update keeps the gear at +0xC1C:
--                  -1 reverse, 0.. forward gears; the same value it sends to the engine sound as vehicle_gear)
--   players        [player global] slot map at +0xF8, controllers +0x53D8B0 (0x1238 each), input blocks +0x150
--                  (0xA7AEC each); a controller's vehicle state is at +0x468 and holds the player at +0x2C
if type(jit) == 'table' and type(jit.off) == 'function' then jit.off(true, true) end

local byte, floor, min, max = string.byte, math.floor, math.min, math.max
local TWO32 = 4294967296
local TESTER = false

-- Tank seat kinds (everything tank-only: tank health, Autoloader, smoke) and the gunner role.
-- (2.1) The FRV (seat kind 0x1A) is driven from its gunner seat only with the FRV Gunner Drive option's flag;
-- DRIVEN names every kind a drive can happen in.
local VEHICLES = {[0x2B] = 'Bastion', [0x2C] = 'Maelstrom'}
local FRV_KIND = 0x1A
local DRIVEN = {[0x2B] = 'Bastion', [0x2C] = 'Maelstrom', [FRV_KIND] = 'FRV'}
-- (2.1 Test 15) the FRVs published for the Vehicle Indicator (any seat): the M-102 (0x1A) and the M-103 Supply FRV
-- (0x1B, found in Test 13; it has the M-102's four 350 tires at the same place). The M-104 is not in the game now.
local FRV_KINDS = {[FRV_KIND] = 'FRV', [0x1B] = 'M-103 Supply FRV'}
local GUNNER, DRIVER_ROLES = 2, {[1] = true, [4] = true}
-- The options' flag addons: Gunner Drive (tanks) and FRV Gunner Drive. A seat kind is driven when its option is on.
-- (3.0) With the Mod Options Menu installed, the Gunner Drive and Autoloader options can be changed in game (menu_opts).
local menu_opts = {}
local function tank_drive_on() return rawget(_G, 'ArmoredOverhaulGunnerDriveOn') == true and menu_opts.tanks ~= false end
local function frv_drive_on() return rawget(_G, 'ArmoredOverhaulFRVDriveOn') == true and menu_opts.frv ~= false end
local drive_available = true     -- (3.1.1 review) false when this game version's driving code wasn't found (see resolve_globals)
local function drive_wanted(kind)
    if not drive_available then return false end
    if kind == FRV_KIND then return frv_drive_on() end
    return VEHICLES[kind] ~= nil and tank_drive_on()
end
-- The seat kinds whose rows are read: the tanks and the FRVs, in any seat (the Vehicle Indicator). (2.1 review) Test
-- builds read every vehicle's seats, to log the kinds of vehicles the mod doesn't know yet (the M-104 FRV, when it
-- is back in the game); release builds don't, so a teammate in an exosuit costs nothing while you're on foot.
local function watched(kind) return DRIVEN[kind] ~= nil or FRV_KINDS[kind] ~= nil or (TESTER and kind ~= nil and kind ~= 0) end

local TUNING = {
    settle_polls = 2,        -- same seat seen this many polls in a row before driving starts
    settle_every = 2,        -- (3.0.1 review) frames between polls while your seat moves or a new seat settles
    drive_seat_every = 3,    -- frames between seat-table checks while driving (your keys are copied every frame)
    idle_every = 6,          -- frames between polls while nobody sits in a supported vehicle
    menu_every = 30,         -- frames between polls while there is no seat table (ship, menus)
    refresh_every = 300,     -- frames before page checks (and the invalid-entity id) are re-validated
    player_every = 30,       -- frames before the local player lookup is redone
    report_every = 1800,     -- frames between routine log rewrites
}

-- ------------------------------------------------------------------------------------------ pure helpers
-- (u32 multiply mod 2^32 in doubles; game hash maps: slot = (key * mult + i) mod cap, empty marker, key/value)
local function mulmod32(a, b)
    local a1, a0 = floor(a / 65536), a % 65536
    local b1, b0 = floor(b / 65536), b % 65536
    return (((a1 * b0 + a0 * b1) % 65536) * 65536 + a0 * b0) % TWO32
end

local function hashmap_find(key, cap, empty, mult, get_slot, max_probe)
    if cap < 1 or cap > 0x1000000 or cap % 1 ~= 0 then return nil, 'bad capacity' end
    local p2 = 1
    while p2 < cap do p2 = p2 * 2 end
    if p2 ~= cap then return nil, 'capacity not a power of two' end
    if key == empty then return nil, 'key is the empty marker' end
    local start = mulmod32(key, mult)
    for i = 0, min(cap, max_probe or 64) - 1 do
        local slot = (start + i) % cap
        local k, v = get_slot(slot)
        if k == nil then return nil, 'unreadable' end
        if k == empty then return nil, 'absent' end
        if k == key then
            if v == 0xFFFFFFFF then return nil, 'no index' end
            return v, slot
        end
    end
    return nil, 'absent'
end

-- What to do with the local player's seat row, given every other occupied row.
local function seat_verdict(mine, others)
    if not mine or mine.role == 0 or not DRIVEN[mine.kind] then return 'not_seated' end
    if mine.vehicle == 0 or mine.vehicle >= 0xFFFFFF00 then return 'bad_vehicle' end
    for _, o in ipairs(others) do
        if o.vehicle == mine.vehicle and DRIVER_ROLES[o.role] then return 'has_driver' end
    end
    if mine.moving ~= 0 then return 'moving_seat' end
    if mine.role ~= GUNNER then return 'other_seat' end
    return 'drive'
end

local function hexbytes(text)
    local out = {}
    for t in text:gmatch('%S+') do out[#out + 1] = t == '??' and -1 or tonumber(t, 16) end
    return out
end

local function fits(s, at, mask)
    if at < 1 or at + #mask - 1 > #s then return false end
    for i = 1, #mask do
        local b = mask[i]
        if b >= 0 and byte(s, at + i - 1) ~= b then return false end
    end
    return true
end

local function le32(s, o)
    if not s or o < 0 or o + 4 > #s then return nil end
    local a, b, c, d = byte(s, o + 1, o + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

if rawget(_G, 'ArmoredOverhaulGunnerDriveTest') then
    return {mulmod32 = mulmod32, hashmap_find = hashmap_find, seat_verdict = seat_verdict, hexbytes = hexbytes,
            fits = fits, le32 = le32}
end
if rawget(_G, 'ArmoredOverhaulGunnerDrive') then return end

-- ------------------------------------------------------------------------------------------ code sites
-- Each site: where it is in the known build, its bytes (?? = changes between builds), and what it proves.
local KNOWN_BUILD = {timestamp = 0x6AB3B43F, sizes = {[0x4744000] = true, [0x4747000] = true}}
local SITES = {
    seat = {rva = 0xA7D7FB, anchor_at = 21, anchor_len = 8, pattern = [[41 8B 5E 2C 41 0F 28 C1 F3 41 0F 58 46 1C 48 8B 35 ?? ?? ?? ?? F3 41 0F 11 46 1C 3B 1D ?? ?? ?? ?? 74 ?? 48 8D 4E 20 41 B0 01 8B D3 E8 ?? ?? ?? ?? 48 85 C0 74 ?? 39 18 75 ?? 8B 40 04 EB ?? 8B C7 44 8B E8 49 C1 E5 06 4C 03 6E 48 4C 89 6D 88 41 8B 5D 00]]},
    player = {rva = 0xA7D73B, anchor_at = 16, anchor_len = 8, pattern = [[3B 1D ?? ?? ?? ?? 4C 8B F1 48 8B 35 ?? ?? ?? ?? F3 44 0F 11 4C 24 50 75 ?? BF FF FF FF FF 8B C7 41 8B 5E 2C 4C 8D BE B0 D8 53 00 48 8B 35 ?? ?? ?? ?? 8B C8 48 69 C1 38 12 00 00 4C 03 F8 3B 1D ?? ?? ?? ?? 4C 89 7C 24 58 74 ?? 48 8D 8E F8 00 00 00 41 B0 01 8B D3 E8 ?? ?? ?? ?? 48 85 C0 74 ?? 39 18 75 ?? 8B 40 04 EB ?? 48 8D 8E F8 00 00 00 41 B0 01 8B D3 E8 ?? ?? ?? ?? BF FF FF FF FF 48 85 C0 74 ?? 39 18 75 ?? 8B 40 04 EB ?? 8B C7 8B C8 4C 8D A6 50 01 00 00 48 69 C1 EC 7A 0A 00 49 8B CE 4C 89 AC 24 28 02 00 00]]},
    blocked = {rva = 0xA7E02F, anchor_at = 42, anchor_len = 6, pattern = [[48 8B 4C 24 58 48 81 C1 D0 08 00 00 E8 ?? ?? ?? ?? 84 C0 0F 85 ?? ?? ?? ?? F3 41 0F 10 46 18 48 8D 4D A0 0F 2F 05 ?? ?? ?? ?? BA 24 00 00 00 76 ?? E8 ?? ?? ?? ?? 4C 8B 7D 80 48 8D 55 A0 49 8D 8F 80 0F 00 00 E8 ?? ?? ?? ?? 84 C0 75 ?? 48 8D 55 A0 49 8D 8F 80 0F 00 00 E8 ?? ?? ?? ?? 41 B0 01 48 8D 55 A0 49 8B CF E8 ?? ?? ?? ?? F3 41 0F 10 46 18 F3 41 0F 5C C1 F3 41 0F 11 46 18 EB ?? E8 ?? ?? ?? ?? 48 8B 4D 80 48 8D 55 A0 45 33 C0 E8 ?? ?? ?? ?? BA 24 00 00 00 48 8D 4D A0 E8 ?? ?? ?? ?? 48 8B 74 24 58 48 8D 55 A0 48 8D 8E D0 0F 00 00 E8 ?? ?? ?? ?? 84 C0 0F 85 ?? ?? ?? ?? 41 38 46 11 0F 85 ?? ?? ?? ?? BA 21 00 00 00 48 8D 4D A0 E8 ?? ?? ?? ?? 48 8D 55 A0 48 8D 8E D0 0F 00 00 E8 ?? ?? ?? ?? 84 C0 0F 85 ?? ?? ?? ??]]},
    uiblock = {rva = 0xA8E780, anchor_at = 144, anchor_len = 55, pattern = [[48 83 EC 08 8B 41 28 3B 05 ?? ?? ?? ?? 75 ?? 32 C0 48 83 C4 08 C3 3B 05 ?? ?? ?? ?? 4C 8B 15 ?? ?? ?? ?? 75 ?? B8 FF FF FF FF EB ?? 45 8B 8A 00 01 00 00 45 33 C0 48 89 5C 24 10 41 8B 9A 08 01 00 00 48 89 6C 24 18 0F AF D8 41 8D 69 FF 48 89 74 24 20 48 89 3C 24 45 85 C9 74 ?? 49 8B BA F8 00 00 00 41 8B B2 04 01 00 00 66 0F 1F 44 00 00 8B CD 41 8D 14 18 48 23 D1 8B 0C D7 4C 8D 1C D7 3B CE 74 ?? 3B C8 74 ?? 41 FF C0 45 3B C1 72 ?? B8 FF FF FF FF 48 8B 74 24 20 48 8B 6C 24 18 48 8B 5C 24 10 48 8B 3C 24 8B C8 48 69 C1 38 12 00 00 42 8B 84 10 88 E8 53 00 48 C1 E8 09 24 01 48 83 C4 08 C3 3B C8 75 ?? 41 8B 43 04 EB ??]]},
    drive = {rva = 0xA7E42F, anchor_at = 360, anchor_len = 15, pattern = [[3B 1D ?? ?? ?? ?? F3 41 0F 10 BC 24 E0 7A 0A 00 F2 41 0F 10 B4 24 E0 7A 0A 00 45 8B BC 24 E8 7A 0A 00 74 ?? 48 8D 4E 38 41 B0 01 8B D3 E8 ?? ?? ?? ?? 48 85 C0 74 ?? 39 18 75 ?? 8B 40 04 EB ?? 8B C7 8B C8 48 8B 46 58 48 8B 35 ?? ?? ?? ?? 48 8D 14 49 48 03 D2 F2 0F 11 34 D0 44 89 7C D0 08 3B 1D ?? ?? ?? ?? F2 41 0F 10 B4 24 D4 7A 0A 00 45 8B BC 24 DC 7A 0A 00 74 ?? 48 8D 4E 38 41 B0 01 8B D3 E8 ?? ?? ?? ?? 48 85 C0 74 ?? 39 18 75 ?? 8B 40 04 EB ?? 8B C7 8B C8 48 8B 46 58 48 8D 14 49 48 B9 04 00 00 00 02 00 00 00 48 03 D2 F2 0F 11 74 D0 0C 44 89 7C D0 14 E8 ?? ?? ?? ?? 48 8B 35 ?? ?? ?? ?? 8B C0 48 C1 E0 05 3B 1D ?? ?? ?? ?? F3 42 0F 10 B4 20 AC 33 00 00 74 ?? 48 8D 4E 38 41 B0 01 8B D3 E8 ?? ?? ?? ?? 48 85 C0 74 ?? 39 18 75 ?? 8B 40 04 EB ?? 8B C7 8B C8 48 8B 46 58 48 8D 14 49 48 B9 04 00 00 00 03 00 00 00 48 03 D2 F3 0F 11 74 D0 18 E8 ?? ?? ?? ?? 48 8B 35 ?? ?? ?? ?? 8B C0 48 C1 E0 05 3B 1D ?? ?? ?? ?? F3 42 0F 10 B4 20 AC 33 00 00 74 ?? 48 8D 4E 38 41 B0 01 8B D3 E8 ?? ?? ?? ?? 48 85 C0 74 ?? 39 18 75 ?? 8B 40 04 EB ?? 8B C7 8B C8 48 8B 46 58 48 8B 35 ?? ?? ?? ?? 48 8D 14 49 48 03 D2 F3 0F 11 74 D0 1C 3B 1D ?? ?? ?? ?? 74 ?? 48 8D 4E 38 41 B0 01 8B D3 E8 ?? ?? ?? ?? 48 85 C0 74 ?? 39 18 75 ?? 8B 40 04 EB ?? 8B C7 8B C8 48 8B 46 58 48 8B 35 ?? ?? ?? ?? 48 8D 14 49 48 03 D2 F3 0F 11 7C D0 20 3B 1D ?? ?? ?? ?? 74 ?? 48 8D 4E 38 41 B0 01 8B D3 E8 ?? ?? ?? ?? 48 85 C0 74 ?? 39 18 75 ?? 8B 40 04 EB ?? 8B C7 8B C8 48 8B 46 58 48 8D 14 49 48 B9 04 00 00 00 06 00 00 00 48 03 D2 C6 44 D0 2C 01 E8 ?? ?? ?? ?? 48 8B 35 ?? ?? ?? ?? 8B C0 48 C1 E0 05 3B 1D ?? ?? ?? ?? 46 0F B6 BC 20 A8 33 00 00 74 ?? 48 8D 4E 38 41 B0 01 8B D3 E8 ?? ?? ?? ?? 48 85 C0 74 ?? 39 18 75 ?? 8B 40 04 EB ?? 8B C7 8B C8 48 8B 46 58 48 8D 14 49 48 B9 04 00 00 00 04 00 00 00 48 03 D2 44 88 7C D0 2D E8 ?? ?? ?? ?? 48 8B 35 ?? ?? ?? ?? 8B C0 48 C1 E0 05 3B 1D ?? ?? ?? ?? 46 0F B6 BC 20 A8 33 00 00 74 ?? 48 8D 4E 38 41 B0 01 8B D3 E8 ?? ?? ?? ?? 48 85 C0 74 ?? 39 18 75 ?? 8B 40 04 EB ?? 8B C7 8B C8 48 8B 46 58 48 8D 14 49 48 B9 04 00 00 00 05 00 00 00 48 03 D2 44 88 7C D0 2E E8 ?? ?? ?? ?? 48 8B 35 ?? ?? ?? ?? 8B C0 48 C1 E0 05 3B 1D ?? ?? ?? ?? 46 0F B6 BC 20 A8 33 00 00 74 ?? 48 8D 4E 38 41 B0 01 8B D3 E8 ?? ?? ?? ?? 48 85 C0 74 ?? 39 18 75 ?? 8B 40 04 EB ?? 8B C7 8B C8 45 0F 57 ED 48 8B 46 58 48 8D 14 49 48 03 D2 44 88 7C D0 2F]]},
}
-- (3.1.1 review) Only the seat reader's places are needed for the addon to run (the Vehicle Indicator, Gunner Camera,
-- Autoloader and health read the seat): seat and player. The driving code's places (driver input, and the two input
-- checks that prove the tags) only turn Gunner Drive on: if a game update changes those alone, everything else keeps
-- working (3.1.0 needed all five, so a change to the 776-byte driving code would have stopped every option).
local SITE_ORDER = {'seat', 'player'}
local DRIVE_ORDER = {'blocked', 'uiblock', 'drive'}
-- RIP-relative globals inside the patterns: {site, displacement position, instruction end}
local GLOBALS = {
    seats = {{'seat', 17, 21}},
    players = {{'player', 12, 16}},
    -- (3.1.1 review) the invalid-entity id: the same compare starts the player code and is in the seat code (3.1.0 took it
    -- from the driving code); the two must agree, and the driving code's (below) with them
    sentinel = {{'player', 2, 6}, {'seat', 29, 33}},
}
local DRIVE_GLOBALS = {
    sentinel = {{'drive', 2, 6}},
    vehicles = {{'drive', 75, 79}, {'drive', 194, 198}, {'drive', 289, 293}, {'drive', 356, 360},
                {'drive', 420, 424}, {'drive', 511, 515}, {'drive', 604, 608}, {'drive', 697, 701}},
}
-- Optional places (1.2): the game's engine switch, the vehicle state layout and gear read, the networked vehicle
-- component and its gear selector. Found the same way as the sites above; one that is missing only turns its own
-- feature off (Gunner Drive itself keeps working).
SITES.engine = {rva = 0x6FE480, anchor_at = 188, anchor_len = 21, pattern = [[48 89 5C 24 10 48 89 6C 24 20 44 88 44 24 18 48 89 4C 24 08 56 41 54 41 55 41 56 41 57 48 83 EC 60 3B 15 ?? ?? ?? ?? 8B DA 4C 8B 35 ?? ?? ?? ?? 74 ?? 45 8B 46 40 33 C9 45 8B 4E 48 44 0F AF CB 41 8D 70 FF 45 85 C0 74 ?? 4D 8B 56 38 45 8B 5E 44 0F 1F 40 00 66 66 66 0F 1F 84 00 00 00 00 00 8B C6 42 8D 14 09 48 23 D0 41 8B 04 D2 41 3B C3 0F 84 ?? ?? ?? ?? 3B C3 0F 84 ?? ?? ?? ?? FF C1 41 3B C8 72 ?? B8 FF FF FF FF 8B C8 49 8B 46 50 4C 69 E9 28 0D 00 00 4C 8B 24 C8 4D 03 6E 68 48 89 8C 24 90 00 00 00 49 8B CC E8 ?? ?? ?? ?? 8B D3 49 8B CE 48 8B E8 E8 ?? ?? ?? ?? 44 0F B6 84 24 A0 00 00 00 4C 8B F8 45 38 85 18 0D 00 00 0F 84 ?? ?? ?? ?? 48 8B 0D ?? ?? ?? ?? 48 8B 51 18]]}
SITES.layout = {rva = 0x6FF100, anchor_at = 0, anchor_len = 53, pattern = [[8B C8 49 8B 47 50 48 89 4D C0 48 8B 1C C8 49 8B 47 70 4D 8B 7F 68 48 69 C9 28 0D 00 00 8B 73 0C 4C 03 F9 48 89 5D 80 48 8B CB 4C 89 7D 20 48 89 85 80 01 00 00]]}
SITES.gearread = {rva = 0x70102A, anchor_at = 0, anchor_len = 11, pattern = [[41 8B 87 1C 0C 00 00 89 45 A0 74 ?? 48 8B 45 90 48 8B 40 50 48 8B 0C F8 F6 41 14 01 74 ?? F3 0F 10 85 20 03 00 00 F3 41 0F 11 87 20 0C 00 00 F3 0F 10 8D 28 03 00 00 F3 41 0F 11 8F 24 0C 00 00 83 BD 40 03 00 00 00 74 ?? 41 C7 87 1C 0C 00 00 FF FF FF FF EB ?? F3 0F 2C 85 2C 03 00 00 41 89 87 1C 0C 00 00]]}
SITES.component = {rva = 0x719E3E, anchor_at = 27, anchor_len = 7, pattern = [[8B 42 08 45 33 E4 3B 05 ?? ?? ?? ?? 4D 8B F1 48 8B 2D ?? ?? ?? ?? 4D 8B F8 74 ?? 44 8B 4D 48 41 8B D4]]}
SITES.selector = {rva = 0x71A0EF, anchor_at = 0, anchor_len = 68, pattern = [[48 8B 45 78 44 89 64 03 44 48 8B 45 78 8B 4C 03 44 89 0E 8B 07 48 03 C0 41 C7 04 C6 A4 F9 B8 8D 41 C7 44 C6 04 01 00 00 00 49 89 74 C6 08 48 83 C6 04 FF 07 48 8B 45 78 C7 44 03 48 02 00 00 00 48 8B 45 78]]}
-- the game's own HUD text: its UI draw code loads the font's material owner, font and glyph atlas together
SITES.uifont = {rva = 0x1388026, anchor_at = 17, anchor_len = 9, pattern = [[48 BA 4A 16 02 A2 03 86 F1 F7 48 8B 1D ?? ?? ?? ?? 44 0F 28 E6 F3 44 0F 59 25 ?? ?? ?? ?? 48 8B 3D ?? ?? ?? ?? F3 45 0F 10 8E 24 01 00 00 48 8B 35 ?? ?? ?? ??]]}
-- (1.3) the tank's health: the game's driver HUD code reads it as current / maximum health from the component at the
-- global it loads here (map +0x1030 keyed by the vehicle; records of 0x1B8 at +0x1058, current health int at +0x14;
-- records of 0x1C at +0x1060, maximum health int at +0x14)
SITES.health = {rva = 0x702544, anchor_at = 112, anchor_len = 16, pattern = [[41 8B 44 24 08 3B 05 ?? ?? ?? ?? 4C 8B 1D ?? ?? ?? ?? 74 ?? 45 8B 8B 38 10 00 00 8B D7 45 8B 93 40 10 00 00 44 0F AF D0 41 8D 71 FF 45 85 C9 74 ?? 49 8B 9B 30 10 00 00 41 8B BB 3C 10 00 00 0F 1F 40 00 66 0F 1F 84 00 00 00 00 00 8B CE 46 8D 04 12 4C 23 C1 42 8B 0C C3 3B CF 0F 84 ?? ?? ?? ?? 3B C8 0F 84 ?? ?? ?? ?? FF C2 41 3B D1 72 ?? 48 8B 75 A8 B8 FF FF FF FF 48 8B 5D E8 4C 8D 05 ?? ?? ?? ?? 8B D0 49 8B 83 58 10 00 00 48 69 CA B8 01 00 00 66 0F 6E 5C 01 14 49 8B 83 60 10 00 00 48 6B CA 1C 0F 5B DB 48 8B D6 66 0F 6E 44 01 14 48 8B CB]]}
-- (2.1) the Autoloader: the game's own reload start (the function the reload key calls for a weapon: it looks the
-- weapon up in the weapon reload table, checks it can reload, works out the reload time with your perks and starts it),
-- the ammo table (rounds in the magazine) and the trigger table (your weapon slots). The tables are taken from the
-- code, like the places above, so a game update that moves them doesn't break the option.
SITES.reload = {rva = 0x774B60, anchor_at = 166, anchor_len = 16, pattern = [[48 8B C4 44 88 40 18 48 89 48 08 56 57 41 55 48 81 EC B0 00 00 00 8B 3D ?? ?? ?? ?? 8B F2 4C 8B 2D ?? ?? ?? ?? 3B D7 0F 84 ?? ?? ?? ?? 45 8B 4D 28 45 8B 55 30 48 89 58 20 4C 89 70 D0 45 33 F6 44 0F AF D6 41 8D 59 FF 41 8B CE 45 85 C9 0F 84 ?? ?? ?? ?? 4D 8B 45 20 45 8B 5D 2C 0F 1F 40 00 8B C3 42 8D 14 11 48 23 D0 41 8B 04 D0 41 3B C3 74 ?? 3B C6 74 ?? FF C1 41 3B C9 72 ?? E9 ?? ?? ?? ?? 3B C6 0F 85 ?? ?? ?? ?? 41 8B 44 D0 04 89 84 24 D0 00 00 00 83 F8 FF 0F 84 ?? ?? ?? ?? 4C 8B 15 ?? ?? ?? ?? 8B C8 49 8B 45 38 48 89 AC 24 A8 00 00 00 8B 2D ?? ?? ?? ?? 4C 89 A4 24 A0 00 00 00 4C 8B 24 C8 4C 89 BC 24 90 00 00 00 41 8B 44 24 08 3B C5 74 ?? 45 8B 4A 20 41 8B D6]]}
SITES.ammo = {rva = 0x7769D1, anchor_at = 26, anchor_len = 23, pattern = [[E8 ?? ?? ?? ?? 3B 1D ?? ?? ?? ?? 8B E8 0F 84 ?? ?? ?? ?? 48 8B 35 ?? ?? ?? ?? 41 8B CC 44 8B 46 28 44 8B 4E 30 44 0F AF CB 45 8D 70 FF 45 85 C0 74 ?? 4C 8B 56 20 44 8B 5E 2C 44 89 AC 24 88 00 00 00 0F 1F 40 00 66 0F 1F 84 00 00 00 00 00 41 8B C6 42 8D 14 09 48 23 D0 41 8B 04 D2 41 3B C3 74 ?? 3B C3 74 ?? FF C1 41 3B C8 72 ??]]}
SITES.trigger = {rva = 0x786BE0, anchor_at = 0, anchor_len = 18, pattern = [[48 89 4C 24 08 53 55 56 57 41 54 48 83 EC 30 48 8B 3D ?? ?? ?? ?? 45 33 C9 3B 15 ?? ?? ?? ?? 4C 89 6C 24 68 4C 89 74 24 28 4C 89 7C 24 20 45 8B F8 74 ?? 44 8B 57 38 45 8B C1 8B 5F 40 0F AF DA 45 8D 72 FF 45 85 D2 74 ?? 48 8B 77 30 8B 6F 3C 41 8B C6 41 8D 0C 18 48 23 C8 8B 04 CE 4C 8D 1C CE 3B C5 74 ?? 3B C2 74 ?? 41 FF C0 45 3B C2 72 ?? B8 FF FF FF FF 44 8B D8 4B 8D 0C BF 4D 69 C3 D0 01 00 00 44 8B D0 48 03 C9 4C 03 47 60 49 C1 E2 05 4C 03 57 58 4C 89 5C 24 60 41 8B 44 C8 04]]}
-- (2.1) the horn: the function the driver's horn key calls (it sets the vehicle's horn byte in the vehicle buttons
-- component, which it loads here)
SITES.horn = {rva = 0x70E7B0, anchor_at = 36, anchor_len = 20, pattern = [[41 56 3B 15 ?? ?? ?? ?? 45 0F B6 F0 4C 8B 1D ?? ?? ?? ?? 75 ?? B8 FF FF FF FF 8B C8 49 8B 43 50 48 8D 14 89 44 88 44 90 06 41 5E C3 45 8B 4B 38 45 33 C0 48 89 5C 24 10 41 8B 5B 40 48 89 6C 24 18 0F AF DA 41 8D 69 FF 48 89 74 24 20 48 89 7C 24 28 45 85 C9 74 ?? 49 8B 7B 30 41 8B 73 3C 90 8B C5 41 8D 0C 18 48 23 C8 8B 04 CF 4C 8D 14 CF 3B C6 74 ?? 3B C2 74 ?? 41 FF C0 45 3B C1 72 ?? B8 FF FF FF FF 48 8B 74 24 20 48 8B 6C 24 18 48 8B 5C 24 10 48 8B 7C 24 28 8B C8 49 8B 43 50 48 8D 14 89 44 88 74 90 06 41 5E C3 3B C2 75 ?? 41 8B 42 04 EB ??]]}
-- (3.1.1 review) the smoke launcher's release (the trigger release call) and the main-gun table (loaded by the game's
-- main-gun lookup), for smoke on any game build
SITES.release = {rva = 0x786DF0, anchor_at = 18, anchor_len = 33, pattern = [[40 53 57 41 54 41 57 48 83 EC 28 44 8B 0D ?? ?? ?? ?? 45 33 D2 48 89 6C 24 58 48 8B F9 48 89 74 24 60 4C 89 6C 24 68 4C 89 74 24 20 45 8B E0 41 3B D1 74 ?? 44 8B 59 38 45 8B C2 8B 59 40 0F AF DA 45 8D 73 FF 45 85 DB 74 ?? 48 8B 71 30 8B 69 3C 41 8B C6 41 8D 0C 18 48 23 C8 8B 04 CE 48 8D 0C CE]]}
SITES.guns = {rva = 0x77E8C0, anchor_at = 69, anchor_len = 31, pattern = [[48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 41 56 41 57 48 83 EC 20 8B 05 ?? ?? ?? ?? 33 F6 8B DA 3B D0 74 ?? 48 8B 0D ?? ?? ?? ?? 44 8B C6 44 8B 49 30 44 8B 59 38 44 0F AF DB 45 8D 71 FF 45 85 C9 74 ?? 48 8B 79 28 8B 69 34 0F 1F 40 00 41 8B CE 43 8D 14 18 48 23 D1 8B 0C D7 4C 8D 14 D7 3B CD 74 ?? 3B CB 74 ?? 41 FF C0 45 3B C1 72 ?? EB ?? 3B CB 75 ?? 41 83 7A 04 FF 0F 85 ?? ?? ?? ??]]}
local EXTRA_ORDER = {'engine', 'layout', 'gearread', 'component', 'selector', 'uifont', 'health', 'reload', 'ammo', 'trigger', 'horn',
                     'release', 'guns'}
local ALL_ORDER = {}
for _, n in ipairs(SITE_ORDER) do ALL_ORDER[#ALL_ORDER + 1] = n end
for _, n in ipairs(DRIVE_ORDER) do ALL_ORDER[#ALL_ORDER + 1] = n end
for _, n in ipairs(EXTRA_ORDER) do ALL_ORDER[#ALL_ORDER + 1] = n end
for _, name in ipairs(ALL_ORDER) do
    local s = SITES[name]
    s.mask = hexbytes(s.pattern)
    local chars = {}
    for i = 1, s.anchor_len do chars[i] = string.char(s.mask[s.anchor_at + i]) end
    s.anchor = table.concat(chars)
end

-- Layout constants proven by the patterns above.
local SEAT = {map = 0x20, rows = 0x48, count = 0x0C, count2 = 0x10, stride = 0x40, vehicle = 0x00, kind = 0x04,
              role = 0x08, moving = 0x30, max_rows = 256}
local VEH = {map = 0x38, data = 0x58, stride = 0x30, states = 0x68, fuel = 0x70, state_size = 0xD28, gear = 0xC1C,
             started = 0xD18}
local PLAYERS = {map = 0xF8, controllers = 0x53D8B0, controller_size = 0x1238, inputs = 0x150,
                 input_size = 0xA7AEC, slots = 8, vstate = 0x468, entity = 0x2C, leaving = 0x11, tags = 0xFD0}
local INPUT = {actions = 0x33A8, action_size = 32, forward = 2, reverse = 3, look_b = 0xA7AD4,
               buttons = {[0x2D] = 6, [0x2E] = 4, [0x2F] = 5}}
local BUTTON_FIELDS, BUTTON_ACTIONS, button_values = {}, {}, {}   -- the same pairs as arrays (no per-frame tables)
for field, action in pairs(INPUT.buttons) do BUTTON_FIELDS[#BUTTON_FIELDS + 1] = field; BUTTON_ACTIONS[#BUTTON_ACTIONS + 1] = action end
local BLOCK_BITS = {0x21, 0x24, 64 + 9}   -- driver-code input tags and the UI-has-input tag

-- ------------------------------------------------------------------------------------------ state + loader
-- (3.0.1 review) time: the game time in seconds (see tick), for the waits that must not depend on the frame rate
local S = {version = '3.2.0', status = 'starting', phase = 'start', locate = 'pending', extras = 'pending', frames = 0, polls = 0, time = 0,
           gunner_drive = 'unknown', last_error = 'none',
           reads = 0, page_checks = 0, errors = 0, seat = 'none', vehicle = 'none', verdict = 'none',
           drive_frames = 0, drive_paused = 0, sessions = 0, last_input = 'none',
           local_slot = 'none', game = 'unchecked', response = 'not driven yet', overwritten = 0,
           options_menu = 'not installed (everything installed is on)', brakes = 'not needed yet'}
rawset(_G, 'ArmoredOverhaulGunnerDrive', S)

local loader = rawget(_G, 'CowboyBingusModLoader')
if type(loader) ~= 'table' or type(loader.version) ~= 'number' or loader.version < 15 then
    print('[Armored Overhaul] Tank Core needs Bingus Shared Loader v15 or newer'); return
end
local have_ffi, ffi = pcall(require, 'ffi')
if not have_ffi or not ffi.abi('win') or not ffi.abi('64bit') then return end

pcall(ffi.cdef, [[typedef struct { void *base; void *allocation_base; uint32_t allocation_protection;
    uint16_t partition; uint16_t reserved; size_t size; uint32_t state; uint32_t protection; uint32_t type; } SvdcRegion;]])
-- The kernel32 functions below have to be declared before they can be looked up (1.1.0 relied on another mod having
-- declared them, and failed to load without it: "missing declaration for symbol 'GetModuleHandleA'"). Each is
-- declared on its own; if another mod already declared one (with its own types), that declaration is used, since
-- the function is cast to this addon's own pointer type anyway.
for _, decl in ipairs({'void *GetModuleHandleA(const char *);', 'void *GetCurrentProcess(void);',
        'int ReadProcessMemory(void *, const void *, void *, size_t, size_t *);',
        'size_t VirtualQuery(const void *, void *, size_t);'}) do
    pcall(ffi.cdef, decl)
end
local k32 = ffi.load('kernel32')
local GetModuleHandleA = ffi.cast('void *(*)(const char *)', k32.GetModuleHandleA)
local ReadProcessMemory = ffi.cast('int (*)(void *, const void *, void *, size_t, size_t *)', k32.ReadProcessMemory)
local VirtualQuery = ffi.cast('size_t (*)(const void *, void *, size_t)', k32.VirtualQuery)
local self_process = ffi.cast('void *(*)(void)', k32.GetCurrentProcess)()
local BYTEP, U32P, F32P = ffi.typeof('uint8_t *'), ffi.typeof('uint32_t *'), ffi.typeof('float *')
local REGION_BYTES = ffi.sizeof('SvdcRegion')
local region = ffi.new('SvdcRegion[1]')

-- ------------------------------------------------------------------------------------------ memory access
local BUF = 0x40400                         -- 256 KB scan window + overlap for the longest pattern
local mem = ffi.new('uint8_t[?]', BUF)
-- (3.0 review) made once: jit is off, so every cast or pointer sum makes a new object, and a cast given as text
-- parses its type each time. ReadProcessMemory fails as a whole on a partial copy, so no byte count is kept.
local MEMF = ffi.cast(F32P, mem)
local UPTR = ffi.typeof('uintptr_t')

local function addr(p) return tonumber(ffi.cast(UPTR, p)) end
local function as_ptr(n) return ffi.cast(BYTEP, n) end

-- Copies `n` bytes into `mem` (valid until the next fetch); false if any byte is unreadable.
local function fetch(p, n)
    if p == nil or n <= 0 or n > BUF then return false end
    S.reads = S.reads + 1
    return ReadProcessMemory(self_process, p, mem, n, nil) ~= 0
end
local function fetch_str(p, n) return fetch(p, n) and ffi.string(mem, n) or nil end
local function mem_u32(o) return mem[o] + mem[o + 1] * 256 + mem[o + 2] * 65536 + mem[o + 3] * 16777216 end   -- (no objects made)
local function fetch_u32(p) return fetch(p, 4) and mem_u32(0) or nil end
local function mem_ptr(o)
    local lo, hi = mem_u32(o), mem_u32(o + 4)
    if hi >= 0x8000 then return nil end
    local v = hi * TWO32 + lo
    return v >= 0x10000 and as_ptr(v) or nil
end
local function fetch_ptr(p) return fetch(p, 8) and mem_ptr(0) or nil end

-- Plain read/write data pages only (never changes protection). Results are kept per exact range (start address
-- and length) for a while. (3.0.1 review) `fresh`: asked now, the kept results neither used nor changed (the error
-- handler, which must not rely on anything the failed frame may have left behind).
local page_ok = {}
local page_ok_count = 0
local function data_pages(p, n, fresh)
    local key = addr(p)
    local seen = not fresh and page_ok[key]
    if seen and seen.n == n and S.frames - seen.frame < TUNING.refresh_every then return true end
    local cursor, left = addr(p), n
    while left > 0 do
        S.page_checks = S.page_checks + 1
        if VirtualQuery(as_ptr(cursor), region, REGION_BYTES) ~= REGION_BYTES then return false end
        local r = region[0]
        if r.state ~= 0x1000 or r.type ~= 0x20000 or (r.protection ~= 4 and r.protection ~= 8) then return false end
        local room = addr(r.base) + tonumber(r.size) - cursor
        if room <= 0 then return false end
        cursor, left = cursor + min(room, left), left - min(room, left)
    end
    if fresh then return true end
    if page_ok_count >= 64 then page_ok, page_ok_count, seen = {}, 0, nil end
    if seen then seen.n, seen.frame = n, S.frames
    else page_ok[key] = {n = n, frame = S.frames}; page_ok_count = page_ok_count + 1 end
    return true
end

local function str_ptr(s, o)
    local lo, hi = le32(s, o), le32(s, o + 4)
    if not lo or not hi or hi >= 0x8000 then return nil end
    local v = hi * TWO32 + lo
    return v >= 0x10000 and as_ptr(v) or nil
end

-- Hash map lookup; `hdr` is an already-read copy of the owning object and `at` the map's offset in it.
-- `memo` keeps the last slot, so a repeat lookup costs one read.
local function map_get(hdr, at, key, memo)
    local lo, hi, cap, empty, mult = le32(hdr, at), le32(hdr, at + 4), le32(hdr, at + 8), le32(hdr, at + 12), le32(hdr, at + 16)
    if memo and memo.key == key and memo.lo == lo and memo.hi == hi and memo.cap == cap and lo and cap and empty and mult
        and fetch(memo.slot_ptr, 8) and mem_u32(0) == key and mem_u32(4) == memo.value then
        return memo.value
    end
    local entries = str_ptr(hdr, at)
    if not entries or not cap or not empty or not mult then return nil, 'map empty' end
    local eid = addr(entries)
    local value, slot = hashmap_find(key, cap, empty, mult, function(i)
        if not fetch(entries + i * 8, 8) then return nil end
        return mem_u32(0), mem_u32(4)
    end)
    if value and memo then memo.key, memo.entries, memo.cap, memo.slot, memo.value, memo.lo, memo.hi, memo.slot_ptr = key, eid, cap, slot, value, lo, hi, entries + slot * 8 end
    return value, slot
end

-- ------------------------------------------------------------------------------------------ log
-- The log is what a user attaches to a bug report: what the addon found in this game build, where you sat and
-- what it did, and the last error. Tester builds add the counters and per-frame details used during development.
local LOG_MAIN = {'version', 'status', 'game', 'locate', 'extras', 'gunner_drive', 'options_menu', 'seat', 'verdict', 'sessions', 'drive_frames',
    'response', 'overwritten', 'control', 'engine', 'smoke', 'horn', 'controller', 'bindings', 'bindings_used', 'health', 'kinds', 'autoloader', 'reloads', 'brakes', 'errors', 'last_error'}
local LABELS = {locate = 'found', options_menu = 'options menu', gunner_drive = 'gunner drive option', seat = 'last vehicle seat', verdict = 'seat check',
                engine = 'engine (gunner seat)', extras = 'game places found', smoke = 'Maelstrom smoke (Mouse 3, right stick click or a bound key, gunner seat)',
                sessions = 'times driven from the gunner seat', drive_frames = 'frames driven',
                response = 'tank answers the throttle', health = 'vehicle health (Vehicle Indicator color)',
                autoloader = 'autoloader (gunner seat)', horn = 'horn (F, left stick click or a bound key, gunner seat)', controller = 'controller (gunner seat)', bindings = 'key bindings (Mod Bindings Menu)', bindings_used = 'bound keys used (gunner seat)', tires = 'last vehicle parts at +0xF8 (FRV tires)', kinds = 'vehicle kinds you sat in', kinds_others = 'vehicle kinds other players sat in', reloads = 'reloads started by the autoloader (one per empty magazine)', brakes = 'braked to a stop as you got out (Gunner Drive)', control = 'who runs the tank (multiplayer)', overwritten = 'driving input replaced by the game (frames)'}
-- The last few drive starts and stops (1.2: players report Gunner Drive stops working after someone else drove)
local history = {}
local function hist(what)
    if #history >= 12 then table.remove(history, 1) end
    history[#history + 1] = string.format('f%d %s', S.frames, what)
end
-- (tester) the last Mouse 3 smoke steps, one line each
-- (3.1.1 Test 2) look = true: the launcher look-ups and driver-seat checks, kept apart in smoke_trace.look (in 3.1.1
-- the presses pushed the look-up out of the 24 smoke steps)
local smoke_trace = {look = {}}
local function strace(what, look)
    if not TESTER then return end
    local t, cap = look and smoke_trace.look or smoke_trace, look and 60 or 24
    if #t >= cap then table.remove(t, 1) end
    t[#t + 1] = string.format('f%d %s', S.frames, what)
end
-- (tester) the last autoloader steps: the magazine running dry, each reload start, the magazine filling again
local auto_trace = {}
local function atrace(what)
    if not TESTER then return end
    if #auto_trace >= 24 then table.remove(auto_trace, 1) end
    auto_trace[#auto_trace + 1] = string.format('f%d %s', S.frames, what)
end
-- (tester, 3.0) the driving input, one line each time it changes: what the game's driver code writes for a real
-- driver (driver seat, keyboard or controller), and in the gunner seat what the game's input gives and what Gunner
-- Drive writes; also the player's input tags (to find the ones the map, the tac-pad and the emote wheel set)
local input_trace = {}
local function itrace(what)
    if not TESTER then return end
    if #input_trace >= 40 then table.remove(input_trace, 1) end
    input_trace[#input_trace + 1] = string.format('f%d %s', S.frames, what)
end
local LOG_TESTER = {'pad_buttons', 'tires', 'kinds_others', 'phase', 'vehicle', 'local_slot', 'drive_paused', 'last_input',
    'frames', 'polls', 'reads', 'page_checks', 'gear_read', 'engine_starts', 'hud_font', 'smoke_shots'}
local logged = {}
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
    for _, g in ipairs({'autoloader', 'gunner_drive'}) do
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
        for _, g in ipairs({'autoloader', 'gunner_drive'}) do if not hub.done[g] then mine = false end end
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
menu_rows.autoloader = function()
    if rawget(_G, 'ArmoredOverhaulAutoloaderOn') ~= true then return {} end
    return {{'armored_overhaul.autoloader', {type = 'toggle', label = 'Tank Autoloader', default = true, description = 'The Bastion and Maelstrom main gun reloads by itself when it runs dry, at the normal reload speed (perks count). You can still reload by hand.'}, 'autoloader'}}
end
-- Gunner Drive: the vehicles installed in the mod manager (its sub-options Tanks and FRV / Tanks / FRV), or Off;
-- starts at the pick (the id carries it)
local GD = {{name = 'Off', tanks = false, frv = false}}
menu_rows.gunner_drive = function()
    local tanks, frv = rawget(_G, 'ArmoredOverhaulGunnerDriveOn') == true, rawget(_G, 'ArmoredOverhaulFRVDriveOn') == true
    if not tanks and not frv then return {} end
    GD = {{name = 'Off', tanks = false, frv = false}}        -- (3.1.1 review: built afresh; 3.1.0 appended to it each call)
    if tanks and frv then GD[#GD + 1] = {name = 'Tanks and FRV', tanks = true, frv = true} end
    if tanks then GD[#GD + 1] = {name = 'Tanks', tanks = true, frv = false} end
    if frv then GD[#GD + 1] = {name = 'FRV', tanks = false, frv = true} end
    local names = {}
    for i, c in ipairs(GD) do names[i] = c.name end
    return {{'armored_overhaul.gunner_drive.' .. (tanks and frv and 'both' or (tanks and 'tanks' or 'frv')), {type = 'choice',
        label = 'Gunner Drive', choices = names, default = 2, description = 'Drive from the gunner seat when the driver seat is empty: your movement keys drive, shift and CTRL change gear, Space is the handbrake. F sounds the horn; Mouse 3 pops the Maelstrom\'s smoke. Controller: the left stick drives, its click is the horn, the right stick click pops smoke. Set your own keys with the Mod Bindings Menu. A teammate who takes the wheel drives. Pick which vehicles.'}, 'gunner_drive'}}
end
menu_set = function(key, v)
    if key == 'autoloader' then menu_opts.autoloader = v == true or v == 1
    elseif key == 'gunner_drive' and GD[v] then menu_opts.tanks, menu_opts.frv = GD[v].tanks, GD[v].frv end
end

local function write_log(force)
    if not force and logged.status == S.status and logged.phase == S.phase and logged.verdict == S.verdict then return end
    logged.status, logged.phase, logged.verdict = S.status, S.phase, S.verdict
    pcall(function()
        local f = loader.open_log and loader.open_log('ArmoredOverhaul-GunnerDrive.log')
        if not f then return end
        local lines = {}
        for _, k in ipairs(LOG_MAIN) do lines[#lines + 1] = (LABELS[k] or k:gsub('_', ' ')) .. ': ' .. tostring(S[k]) end
        if #history > 0 then
            lines[#lines + 1] = '-- drive history (last ' .. #history .. ') --'
            for _, l in ipairs(history) do lines[#lines + 1] = l end
        end
        if TESTER then
            lines[#lines + 1] = '-- tester details --'
            for _, k in ipairs(LOG_TESTER) do lines[#lines + 1] = k .. ': ' .. tostring(S[k]) end
            if #smoke_trace.look > 0 then
                lines[#lines + 1] = '-- smoke look-ups (last ' .. #smoke_trace.look .. ') --'
                for _, l in ipairs(smoke_trace.look) do lines[#lines + 1] = l end
            end
            if #smoke_trace > 0 then
                lines[#lines + 1] = '-- smoke steps (last ' .. #smoke_trace .. ') --'
                for _, l in ipairs(smoke_trace) do lines[#lines + 1] = l end
            end
            if #auto_trace > 0 then
                lines[#lines + 1] = '-- autoloader steps (last ' .. #auto_trace .. ') --'
                for _, l in ipairs(auto_trace) do lines[#lines + 1] = l end
            end
            if #input_trace > 0 then
                lines[#lines + 1] = '-- driving input (last ' .. #input_trace .. ') --'
                for _, l in ipairs(input_trace) do lines[#lines + 1] = l end
            end
        end
        f:write('Armored Overhaul - Tank Core / Tank and FRV Gunner Drive\n', table.concat(lines, '\n'), '\n')
        f:close()
    end)
end

-- ------------------------------------------------------------------------------------------ locating
local game, image_size
local G = {}                                -- resolved globals: seats, players, vehicles, sentinel (pointers)

local function site_bytes(name, rva)
    local s = fetch_str(game + rva, #SITES[name].mask)
    return s and fits(s, 1, SITES[name].mask) and s or nil
end

-- (3.1.1 review: one helper; the decode was written out five times) the game.dll offset a RIP-relative instruction in
-- site bytes `s` (found at `rva`) points at: its 4-byte displacement at `at`, the instruction ending at `ends`
local function rip_rva(s, rva, at, ends)
    local d = s and le32(s, at)
    if not d then return nil end
    d = d >= 0x80000000 and d - TWO32 or d
    local t = rva + ends + d
    return (t > 0 and t + 8 <= image_size) and t or nil
end
-- every global in `list` from its references (all of them agreeing, and with what `found` already holds)
local function resolve_refs(rvas, list, found)
    for gname, refs in pairs(list) do
        local target = found[gname]
        for _, ref in ipairs(refs) do
            local site, disp_at, ends = ref[1], ref[2], ref[3]
            local s = rvas[site] and site_bytes(site, rvas[site])
            if not s then return nil, site .. ' pattern' end
            local t = rip_rva(s, rvas[site], disp_at, ends)
            if not t or (target and t ~= target) then return nil, gname .. ' reference' end
            target = t
        end
        found[gname] = target
    end
    return found
end
local drive_missing = nil          -- (3.1.1 review) why Gunner Drive's places weren't found (nil: found)
local function resolve_globals(rvas)
    for _, name in ipairs(SITE_ORDER) do
        if not (rvas[name] and site_bytes(name, rvas[name])) then return nil, name .. ' pattern' end
    end
    local found, why = resolve_refs(rvas, GLOBALS, {})
    if not found then return nil, why end
    drive_missing = nil
    for _, name in ipairs(DRIVE_ORDER) do
        if not (rvas[name] and site_bytes(name, rvas[name])) then drive_missing = name .. ' pattern'; break end
    end
    if not drive_missing then
        local d, dwhy = resolve_refs(rvas, DRIVE_GLOBALS, {sentinel = found.sentinel})
        if d then found.vehicles = d.vehicles else drive_missing = dwhy end
    end
    drive_available = drive_missing == nil
    return found
end

local function bind(found)
    for k, rva in pairs(found) do G[k] = game + rva end
end

-- The optional places: each checked against its pattern; FEAT says what this game version supports.
local FEAT = {}
local function resolve_extras(rvas)
    local ok, have = {}, {}
    for _, n in ipairs(EXTRA_ORDER) do
        local rva = rvas and rvas[n]
        if rva and rva > 0 and rva + #SITES[n].mask <= image_size and site_bytes(n, rva) then ok[n] = rva end
    end
    -- the game global a found place's RIP-relative load points at (nil if the place wasn't found)
    local function global_at(name, at, ends)
        local t = ok[name] and rip_rva(site_bytes(name, ok[name]), ok[name], at, ends)
        return t and (game + t) or nil
    end
    FEAT.engine = ok.engine and (game + ok.engine) or nil
    FEAT.panel = (ok.layout and ok.gearread) and true or nil
    FEAT.component = global_at('component', 18, 22)                   -- mov rbp, [rip+disp] ends at pattern offset 22
    FEAT.selector = (FEAT.component and ok.selector) and true or nil
    FEAT.font = nil
    local owner, font, atlas = global_at('uifont', 13, 17), global_at('uifont', 33, 37), global_at('uifont', 49, 53)
    if owner and font and atlas then FEAT.font = {owner = owner, font = font, atlas = atlas} end
    FEAT.health = global_at('health', 14, 18)                         -- mov r11, [rip+disp] ends at pattern offset 18
    -- (2.1) the Autoloader's places: the reload start and the tables its code loads (reload table, operators, ammo,
    -- triggers); all of them, or the option stays off
    FEAT.reload = nil
    if ok.reload and ok.ammo and ok.trigger then
        local mgr, oper = global_at('reload', 33, 37), global_at('reload', 162, 166)     -- mov r13 / mov r10, [rip+disp]
        local ammo, trig = global_at('ammo', 22, 26), global_at('trigger', 18, 22)       -- mov rsi / mov rdi, [rip+disp]
        if mgr and oper and ammo and trig then FEAT.reload = {fn = game + ok.reload, mgr = mgr, oper = oper, ammo = ammo, trigger = trig} end
    end
    FEAT.horn = ok.horn and global_at('horn', 15, 19) or nil                -- mov r11, [rip+disp] (the component)
    -- (3.1.1 review) the Maelstrom's smoke: its trigger, operator, gun-and-smoke and ammo tables are the Autoloader's
    -- (same globals), the press is the trigger place; the release and the main-gun table have their own places. Found
    -- by pattern like the rest, so smoke keeps working after a game update (3.1.0: the Sept 2026 build only).
    FEAT.smoke = nil
    if FEAT.reload and ok.release and ok.guns then
        local guns = global_at('guns', 41, 45)                                       -- mov rcx, [rip+disp]
        if guns then FEAT.smoke = {trig = FEAT.reload.trigger, oper = FEAT.reload.oper, pair = FEAT.reload.mgr,
            ammo = FEAT.reload.ammo, guns = guns, press = game + ok.trigger, release = game + ok.release} end
    end
    for _, pair in ipairs({{'engine switch', FEAT.engine}, {'instruments', FEAT.panel}, {'gear selector', FEAT.selector},
                           {'HUD font', FEAT.font}, {'tank health', FEAT.health}, {'autoloader', FEAT.reload},
                           {'horn', FEAT.horn}, {'smoke launcher', FEAT.smoke}, {'Gunner Drive', drive_available}}) do
        have[#have + 1] = pair[1] .. (pair[2] and ' found' or ' not found')
    end
    if not drive_available then have[#have] = have[#have] .. ' (' .. tostring(drive_missing) .. ': the seat reader only)' end
    S.extras = table.concat(have, ', ')
    return ok
end

local function cache_file()
    local root = os.getenv and os.getenv('LOCALAPPDATA')
    return root and root ~= '' and (root .. '\\CowboyBingus\\Helldivers2\\Logs\\ArmoredOverhaul-GunnerDrive.cache') or nil
end
local function cache_load(tag)
    local path = cache_file()
    local f = path and io and io.open and io.open(path, 'r')
    if not f then return nil end
    local text = f:read('*a'); f:close()
    -- (2.1 review) 'sites 2': a cache saved by 2.0.1 after a game update lacks the 2.1 places (autoloader, horn),
    -- and taking it would leave them off for good; it is searched again instead
    -- (3.1.1 review) 'sites 3': the smoke places (release, guns) added; an older cache is searched again once
    if not text:find('^armored overhaul gunner drive sites 3\n' .. tag:gsub('%p', '%%%0') .. '\n') then return nil end
    local out = {}
    for k, v in text:gmatch('(%a+)=(%x+)') do out[k] = tonumber(v, 16) end
    return out
end
local function cache_save(tag, rvas)
    local path = cache_file()
    local f = path and io and io.open and io.open(path, 'w')
    if not f then return end
    f:write('armored overhaul gunner drive sites 3\n', tag, '\n')
    for _, name in ipairs(ALL_ORDER) do if rvas[name] then f:write(name, '=', string.format('%X', rvas[name]), '\n') end end
    f:close()
end

-- Search of the whole game code after a patch (one 256 KB step per frame).
local search = {at = 0x1000, hits = {}}
for _, name in ipairs(ALL_ORDER) do search.hits[name] = {} end
local function search_step()
    if search.at >= image_size then return true end
    if VirtualQuery(game + search.at, region, REGION_BYTES) ~= REGION_BYTES then search.at = image_size; return true end
    local r = region[0]
    local stop = min(image_size, addr(r.base) + tonumber(r.size) - addr(game))
    local code = r.state == 0x1000 and (r.protection == 0x10 or r.protection == 0x20 or r.protection == 0x40)
    if not code then search.at = max(search.at + 0x1000, stop); return search.at >= image_size end
    local n = min(0x40000 + 0x400, stop - search.at)
    local s = fetch_str(game + search.at, n)
    if s then
        for _, name in ipairs(ALL_ORDER) do
            local site, from = SITES[name], 1
            while true do
                local hit = s:find(site.anchor, from, true)
                if not hit then break end
                local start = hit - site.anchor_at
                if fits(s, start, site.mask) then
                    local rva = search.at + start - 1
                    local list = search.hits[name]
                    if list[#list] ~= rva then list[#list + 1] = rva end
                end
                from = hit + 1
            end
        end
    end
    search.at = search.at + min(0x40000, n)
    return search.at >= image_size
end

-- ------------------------------------------------------------------------------------------ game state
local memo = {players = {}, rows = {}, vehicle = {}}
local cached = {}                          -- manager pointers with the frame they were read
local me_cache                             -- (the local player; see local_player)

-- (2.0.1 review) A manager pointer is read from its game global once per frame (1.0-2.0.0 kept it for 300 frames).
-- When the game replaces a manager - a mission ending or loading - every page check and the player cache are
-- dropped at once, so nothing is ever written through, or checked against, a table the game has let go of.
local function manager(name)
    local c = cached[name]
    if c and c.frame == S.frames then return c.ptr end
    local lo, hi
    if fetch(G[name], 8) then lo, hi = mem_u32(0), mem_u32(4) end
    if c and lo and c.lo == lo and c.hi == hi then c.frame = S.frames; return c.ptr end
    local p = lo and mem_ptr(0) or nil
    if c and c.ptr ~= nil and (p == nil or p ~= c.ptr) then          -- (pointers compare by address)
        page_ok, page_ok_count, me_cache = {}, 0, nil
    end
    if not c then c = {}; cached[name] = c end
    c.ptr, c.frame, c.lo, c.hi = p, S.frames, lo, hi
    return p
end

local sentinel, sentinel_at = nil, 0
local function invalid_entity()
    -- (3.1.1 review) re-read every refresh_every frames (3.1.0 only on frames that were multiples of it, which polls a few
    -- frames apart could miss for the whole session)
    if not sentinel or S.frames >= sentinel_at then sentinel = fetch_u32(G.sentinel); sentinel_at = S.frames + TUNING.refresh_every end
    return sentinel
end

-- The local player's controller/input block (cached briefly; our entity only changes when we respawn).
local function local_player()
    if me_cache and S.frames - me_cache.frame < TUNING.player_every then return me_cache end
    me_cache = nil
    local players = manager('players')
    if not players then return nil, 'no player manager' end
    local hdr = fetch_str(players + PLAYERS.map, 0x18)
    if not hdr then cached.players = nil; return nil, 'player map unreadable' end
    for slot = 0, PLAYERS.slots - 1 do
        local controller = players + PLAYERS.controllers + slot * PLAYERS.controller_size
        local entity = fetch_u32(controller + PLAYERS.vstate + PLAYERS.entity)
        if entity and entity ~= 0 and entity ~= invalid_entity() then
            if map_get(hdr, 0, entity, memo.players) == slot then
                local input = players + PLAYERS.inputs + slot * PLAYERS.input_size
                -- (3.0 review) the addresses read every driving frame, worked out here once
                me_cache = {frame = S.frames, slot = slot, entity = entity, controller = controller, input = input,
                            tags_at = controller + PLAYERS.vstate + PLAYERS.leaving, actions_at = input + INPUT.actions,
                            look_at = input + INPUT.look_b}
                S.local_slot = slot
                return me_cache
            end
        end
    end
    S.local_slot = 'none'
    return nil, 'local player not found'
end

-- Reads the seat table once: our row (by player entity) plus every other occupied row. The local player is
-- only looked up when somebody sits in a supported vehicle. The result tables are reused from poll to poll
-- (nothing keeps them past the poll), so reading the seats makes no garbage.
local seat_out, seat_others, seat_pool = {}, {}, {}
-- (3.0 review) the rows are read into a buffer of their own (2.1: a new string of every row each poll); `mem` can't
-- hold them, the player and map look-ups below read through it
local SEATBUF = ffi.new('uint8_t[?]', SEAT.max_rows * SEAT.stride)
local function sb32(o) return SEATBUF[o] + SEATBUF[o + 1] * 256 + SEATBUF[o + 2] * 65536 + SEATBUF[o + 3] * 16777216 end
local function seat_row(n, i)
    local row = seat_pool[n]
    if not row then row = {}; seat_pool[n] = row end
    local o = i * SEAT.stride
    row.index, row.vehicle, row.kind, row.role = i, sb32(o + SEAT.vehicle), sb32(o + SEAT.kind), sb32(o + SEAT.role)
    row.moving = SEATBUF[o + SEAT.moving] + SEATBUF[o + SEAT.moving + 1] * 256
    return row
end
local function read_seats()
    local seats = manager('seats')
    if not seats then return nil, 'no seat table' end
    local hdr = fetch_str(seats, SEAT.rows + 8)
    if not hdr then cached.seats = nil; return nil, 'seat table unreadable' end
    local count = min(le32(hdr, SEAT.count), le32(hdr, SEAT.count2))
    local rows = str_ptr(hdr, SEAT.rows)
    if not rows or count > SEAT.max_rows then cached.seats = nil; return nil, 'seat table layout' end
    local out, others = seat_out, seat_others
    for i = #others, 1, -1 do others[i] = nil end
    out.anyone, out.me, out.mine, out.others = false, nil, nil, others
    if count == 0 then return out end
    if not data_pages(rows, count * SEAT.stride) then return nil, 'seat rows not plain data' end
    S.reads = S.reads + 1
    if ReadProcessMemory(self_process, rows, SEATBUF, count * SEAT.stride, nil) == 0 then return nil, 'seat rows unreadable' end
    for i = 0, count - 1 do
        local o = i * SEAT.stride
        if watched(sb32(o + SEAT.kind)) and sb32(o + SEAT.role) ~= 0 then out.anyone = true; break end
    end
    if not out.anyone then return out end
    local me = local_player()
    out.me = me
    -- (2.0.1 review) every occupied row is listed even when yours isn't found (you on foot): 2.0.0 returned an empty
    -- list then, so a teammate who took the driver seat while you climbed out had the engine switched off under them
    local index = me and map_get(hdr, SEAT.map, me.entity, memo.rows)
    if index and index >= count then index = nil end
    local used = 0
    for i = 0, count - 1 do
        if i == index or sb32(i * SEAT.stride + SEAT.role) ~= 0 then
            used = used + 1
            local row = seat_row(used, i)
            if i == index then out.mine = row else others[#others + 1] = row end
        end
    end
    return out
end

-- The vehicle's driver-input record (checked every frame: records move when vehicles come and go).
-- Also returns the vehicle's index and the table header copy (for the gear, read from the same table).
-- (3.1.1 review) The last look-up is reused while the table's header (its map, data, state and fuel pointers) and the
-- vehicle's map slot still say the same: one header read and one slot read a frame, and far fewer new Lua objects
-- (3.1.0 made a 64-byte string and about 7 pointer objects every driving frame). When the slot changed (the game moved
-- the vehicle in its table) the header is read again before the full look-up: the slot read has replaced it in `mem`.
local HDR_N = VEH.fuel - VEH.map + 8
local DATA_AT, STATES_AT, FUEL_AT = VEH.data - VEH.map, VEH.states - VEH.map, VEH.fuel - VEH.map
local HDR_WORDS = {0, 4, 8, DATA_AT, DATA_AT + 4, STATES_AT, STATES_AT + 4, FUEL_AT, FUEL_AT + 4}
local dr = {h = {}}
local function driver_record(vehicle)
    local vehicles = manager('vehicles')
    if not vehicles then return nil, 'no vehicle table' end
    if dr.mgr ~= vehicles then dr.mgr, dr.at, dr.record = vehicles, vehicles + VEH.map, nil end
    if not fetch(dr.at, HDR_N) then cached.vehicles = nil; dr.record = nil; return nil, 'vehicle table unreadable' end
    if dr.record and dr.vehicle == vehicle then
        local same, h = true, dr.h
        for i = 1, #HDR_WORDS do if mem_u32(HDR_WORDS[i]) ~= h[i] then same = false; break end end
        if same then
            local seen = page_ok[dr.key]
            if fetch(dr.slot, 8) and mem_u32(0) == vehicle and mem_u32(4) == dr.index
                and ((seen and seen.n == VEH.stride and S.frames - seen.frame < TUNING.refresh_every) or data_pages(dr.record, VEH.stride)) then
                return dr.record, dr.index, dr.hdr
            end
            -- (mem now holds the slot, not the header)
            if not fetch(dr.at, HDR_N) then cached.vehicles = nil; dr.record = nil; return nil, 'vehicle table unreadable' end
        end
    end
    dr.record = nil
    local hdr = ffi.string(mem, HDR_N)
    local index, slot = map_get(hdr, 0, vehicle, memo.vehicle)
    if not index then return nil, slot end
    local data = str_ptr(hdr, DATA_AT)
    if not data or index > 0xFFFF then return nil, 'vehicle data' end
    local record = data + index * VEH.stride
    if not data_pages(record, VEH.stride) then return nil, 'record not plain data' end
    local entries = str_ptr(hdr, 0)
    local s = memo.vehicle.key == vehicle and memo.vehicle.slot or slot
    if entries and s then
        for i = 1, #HDR_WORDS do dr.h[i] = le32(hdr, HDR_WORDS[i]) end
        dr.vehicle, dr.index, dr.hdr, dr.slot, dr.record, dr.key = vehicle, index, hdr, entries + s * 8, record, addr(record)
    end
    return record, index, hdr
end

-- The driver's instruments, as the game's own driver HUD shows them (read every 4 frames while you drive from the
-- gunner seat). Vehicle state (0xD28 bytes each at +0x68): +0xC1C gear (-1 reverse, 0 first), +0xC20 rpm, +0xC24
-- the game's speed figure, +0xD18 engine started. Fuel: 8-byte entries at +0x70, litres at +4 (the game burns it while the
-- driver flag is set, and stops the engine when it runs out). Reads are safe anywhere (ReadProcessMemory just fails),
-- so there is no page check here (Test 1 had one, and the gear never showed).
local function read_instruments(index, hdr, out)
    if not FEAT.panel then S.gear_read = 'not found in this game version'; return false end
    local states = str_ptr(hdr, VEH.states - VEH.map)
    if not states then S.gear_read = 'no state table'; return false end
    local st = states + index * VEH.state_size
    if not fetch(st + VEH.gear, 12) then S.gear_read = 'unreadable'; return false end
    local g = mem_u32(0)
    if g >= 0x80000000 then g = g - TWO32 end
    out.gear = (g >= -1 and g <= 8) and g or nil
    out.rpm = MEMF[1]                                    -- (3.0 review: the precast view of mem)
    if not (out.rpm >= 0 and out.rpm < 100000) then out.rpm = nil end   -- (3.1.1 review: NaN or an odd read, not published)
    -- (published as it is: 1.2.0-1.2.1 took it for metres a second and multiplied it by 3.6, and a user saw 112 km/h;
    -- the driver panel now measures the speed from the hull's movement and only falls back on this figure)
    out.speed = math.abs(MEMF[2])
    if not (out.speed < 1000) then out.speed = nil end
    local fuels = str_ptr(hdr, VEH.fuel - VEH.map)
    out.fuel = (fuels and fetch(fuels + index * 8 + 4, 4)) and MEMF[0] or nil
    if out.fuel and not (out.fuel >= 0 and out.fuel < 100000) then out.fuel = nil end   -- (3.1.1 review, as health is)
    S.gear_read = out.gear and 'ok' or ('gear out of range: ' .. g)
    return true
end
local function engine_started(index, hdr)
    if not FEAT.panel then return nil end
    local states = str_ptr(hdr, VEH.states - VEH.map)
    if not states or not fetch(states + index * VEH.state_size + VEH.started, 1) then return nil end
    return mem[0] ~= 0
end

-- ------------------------------------------------------------------------------------------ engine (1.2 Test 4)
-- The game starts and stops a tank's engine with one function (game.dll+0x6FE480 in the Sept 2026 build: vehicle
-- entity, on/off; it plays the start or stop sound, runs the start-up timer and tells the network). It does nothing
-- when the engine is already in that state. The seat code calls it when a driver gets in or out; Gunner Drive calls
-- it the same way when it starts and stops driving. (Test 2 tried a component flag instead: the game cleared it every
-- frame, and a real driver doesn't set it either.) Found by its code pattern like the other places (the whole
-- pattern is checked before it is ever called).
-- (2.0.1) Only called for a tank that is still in the game's vehicle table, looked up fresh right before the call:
-- the switch looks the tank up itself and, for one that is gone, reads far outside the table and closes the game.
-- 2.0.0 crashed this way on returning to the ship while driving from the gunner seat (the tank is taken apart, its
-- record lookup fails, and stopping then switched off the engine of a tank that no longer existed).
local set_engine
local function engine_switch(vehicle, on)
    if not FEAT.engine then return false, 'the engine switch was not found in this game version' end
    if vehicle == nil or not driver_record(vehicle) then return false, 'the tank is gone' end
    if not set_engine then set_engine = ffi.cast('void (*)(void *, uint32_t, uint8_t)', FEAT.engine) end
    set_engine(nil, vehicle, on and 1 or 0)
    return true
end

-- The game's HUD font, for the driver panel: the font, its material and its glyph atlas, as
-- resource hashes (the font and atlas globals hold them; the material is at +0x18 of the owner the global points to).
-- Published as 16-digit hex strings once they are set (they are filled in when the game's UI starts).
local FONT_PUB = {}
rawset(_G, 'ArmoredOverhaulUIFont', FONT_PUB)
local function hex64(p) return fetch(p, 8) and string.format('%08x%08x', mem_u32(4), mem_u32(0)) or nil end
local function read_font()
    if not FEAT.font or FONT_PUB.font then return end
    local font, atlas = hex64(FEAT.font.font), hex64(FEAT.font.atlas)
    local owner = fetch_ptr(FEAT.font.owner)
    local material = owner and hex64(owner + 0x18)
    local zero = '0000000000000000'
    if font and atlas and material and font ~= zero and atlas ~= zero and material ~= zero then
        FONT_PUB.font, FONT_PUB.material, FONT_PUB.atlas = font, material, atlas
        S.hud_font = string.format('font %s, material %s, atlas %s', font, material, atlas)
    end
end

-- The gear selector (R N D 1 2), from the networked vehicle component [game.dll+0x3326458]: map at +0x40,
-- 0x58-byte records at +0x78, selector at +0x48 (0 R, 1 N, 2 D, 3 first, 4 second; the component starts at D).
local COMPONENT = {map = 0x40, recs = 0x78, stride = 0x58, selector = 0x48}
local component_memo = {}
local function selector_at(vehicle)
    if not FEAT.selector then return nil end
    local comp = fetch_ptr(FEAT.component)
    local hdr = comp and fetch_str(comp + COMPONENT.map, COMPONENT.recs - COMPONENT.map + 8)
    if not hdr then return nil end
    local index = map_get(hdr, 0, vehicle, component_memo)
    local recs = str_ptr(hdr, COMPONENT.recs - COMPONENT.map)
    if not index or not recs or index > 0xFFFF then return nil end
    return recs + index * COMPONENT.stride + COMPONENT.selector
end

-- ------------------------------------------------------------------------------------------ controllers (2.1)
-- Gunner Drive on a controller, Halo style: the left stick drives - forward drives forward, back reverses, left
-- and right steer - the left stick click sounds the horn and the right stick click pops the Maelstrom's smoke (3.0;
-- 2.1.0 Tests 19-20: the right bumper, the game's mark button). The keyboard
-- keeps W/S/A/D, F and Mouse 3. In the driver-input record the forward drive is +0x18 and the reverse +0x1C (0..1
-- each: W and S), and the steering is the look vector's x at +0x00 and +0x20 (-1 left .. 1 right: A and D), as the
-- game's driver code writes them (seen in 2.1.0 Test 9). The engine's Pad1..Pad8, only those it reports as connected
-- (looked up once a second); each pad's functions, buttons and stick looked up once, safely (an input object given as
-- plain userdata errors when indexed).
local pads = {dead = 0.2, dead_y = 0.1, horn = {'left_thumb', 'l3', 'left_stick', 'left_stick_press', 'ls'},
              smoke = {'right_thumb', 'r3', 'right_stick', 'right_stick_press', 'rs'}}
S.controller = 'not used yet'
do
    local list, list_at, cache = {}, -1, {}
    -- (3.0 review) a controller only counts while the game's window is in front: the engine reads a pad even while
    -- you are alt-tabbed out (the keyboard's keys reach the game only while it has the focus). Checked every 15
    -- frames; without the window functions the pad always counts.
    local focus, focus_at, focus_fn = true, -1, nil
    do
        for _, decl in ipairs({'void *GetForegroundWindow(void);', 'uint32_t GetWindowThreadProcessId(void *, uint32_t *);',
                'uint32_t GetCurrentProcessId(void);'}) do
            pcall(ffi.cdef, decl)
        end
        local function sym(lib, name) return lib[name] end
        local oku, user32 = pcall(ffi.load, 'user32')
        local ok1, fgw, ok2, wtp
        if oku then ok1, fgw = pcall(sym, user32, 'GetForegroundWindow'); ok2, wtp = pcall(sym, user32, 'GetWindowThreadProcessId') end
        local ok3, gcp = pcall(sym, k32, 'GetCurrentProcessId')
        if ok1 and ok2 and ok3 then
            local fg = ffi.cast('void *(*)(void)', fgw)
            local owner = ffi.cast('uint32_t (*)(void *, uint32_t *)', wtp)
            local mine = tonumber(ffi.cast('uint32_t (*)(void)', gcp)())
            local pid = ffi.new('uint32_t[1]')
            focus_fn = function()
                local h = fg()
                if h == nil then return false end
                pid[0] = 0; owner(h, pid)
                return tonumber(pid[0]) == mine
            end
        end
    end
    local function focused()
        if not focus_fn then return true end
        if S.frames >= focus_at then
            focus_at = S.frames + 15
            local ok, r = pcall(focus_fn)
            local now = not ok or r == true
            if now ~= focus then focus = now; itrace(now and 'game window in front again' or 'game window in the background: controller ignored') end
        end
        return focus
    end
    pads.focused = focused          -- (3.0.1 review) for the bound keys too (see binds.poll)
    local function get(o, k) return o[k] end
    local function fld(o, k) local ok, v = pcall(get, o, k); return ok and v or nil end
    local function xy(v) return v.x, v.y end
    local function first(f, names)
        if not f then return nil end
        for _, n in ipairs(names) do local ok, i = pcall(f, n); if ok and type(i) == 'number' then return i end end
    end
    local function info(pad)
        local d = cache[pad]
        if d then return d end
        d = {button = fld(pad, 'button'), active = fld(pad, 'active'), axis = fld(pad, 'axis')}
        local bi, ai = fld(pad, 'button_index'), fld(pad, 'axis_index')
        d.horn, d.smoke, d.left = first(bi, pads.horn), first(bi, pads.smoke), first(ai, {'left'})
        if TESTER and not pads.listed then                   -- (tester) the controller's button names, once
            pads.listed = true
            local nb, bn = fld(pad, 'num_buttons'), fld(pad, 'button_name')
            local okn, n = pcall(nb or error)
            local out = {}
            if okn and type(n) == 'number' and bn then
                for i = 0, min(n, 40) - 1 do local okb, nm = pcall(bn, i); out[#out + 1] = i .. '=' .. tostring(okb and nm or '?') end
            end
            S.pad_buttons = (#out > 0 and table.concat(out, ' ') or 'not listed') .. string.format('; horn %s, smoke %s, stick %s',
                tostring(d.horn), tostring(d.smoke), tostring(d.left))
        end
        cache[pad] = d
        return d
    end
    local function connected()
        if S.frames < list_at then return list end
        list_at = S.frames + 60
        list = {}
        local SR = rawget(_G, 'stingray')
        if type(SR) ~= 'table' then return list end
        for n = 1, 8 do
            local pad = fld(SR, 'Pad' .. n)
            if pad == nil then break end
            local d = info(pad)
            local on = true
            -- (3.1.1 review) a pad whose `active` fails is taken as not connected; with no `active` at all, the first pad
            -- only (3.1.0 read every pad then: all eight, after a game update that changed it)
            if d.active then local ok, r = pcall(d.active); on = ok and r == true else on = n == 1 end
            if on then list[#list + 1] = d end
        end
        return list
    end
    -- a connected controller holding the button ('horn' or 'smoke')
    function pads.button(which)
        if not focused() then return false end
        for _, d in ipairs(connected()) do
            local i = d[which]
            if i and d.button then
                local ok, v = pcall(d.button, i)
                if ok and type(v) == 'number' and v > 0.5 then return true end
            end
        end
        return false
    end
    -- the left stick of a connected controller pushed past the dead zone: x (right +), y (forward +), rescaled to 0..1
    -- past it; nil when no stick is pushed
    function pads.stick()
        if not focused() then return nil end
        for _, d in ipairs(connected()) do
            if d.left and d.axis then
                local ok, v = pcall(d.axis, d.left)
                local okc, x, y = false, nil, nil
                if ok and v ~= nil then okc, x, y = pcall(xy, v) end      -- (a frame value: read at once, never kept)
                if okc and type(x) == 'number' and type(y) == 'number' then
                    local m = math.sqrt(x * x + y * y)
                    if m > pads.dead then
                        local k = min(1, (m - pads.dead) / (1 - pads.dead)) / m
                        return x * k, y * k
                    end
                end
            end
        end
    end
end

-- ------------------------------------------------------------------------------------------ key bindings (3.0.1)
-- With CowboyBingus's Mod Bindings Menu installed, Gunner Drive's controls get their own lines in the game's key and
-- controller binding pages (tab MODS, section ARMORED OVERHAUL), each named "Gunner Drive: ...": Forward, Back,
-- Steer Left, Steer Right, Shift Up, Shift Down, Handbrake (3.2.0), Horn and Smoke (Maelstrom; only with the tanks'
-- Gunner Drive installed). They start with no key; a key or button set there works as well as the built-in ones (the
-- movement keys, shift / CTRL, Space, F, Mouse 3, the stick),
-- which always stay. (Its API, from the menu's own source: _G.ModBindingsMenu {api = 1, version = 3,
-- register_binding(id, label, slot, options), is_down(id), ready()}; a binding without a slot gets a free one and
-- keeps it in later sessions.) The menu may load after this addon: it is looked for once a second until found, and
-- only once the Gunner Drive option is known to be installed. is_down is asked only while you drive.
-- (3.2.0) every Gunner Drive key bindable: Shift Up, Shift Down and Handbrake
-- too: held into the driver record's buttons as the game's own keys put them there (Space = +0x2D, the gear keys
-- +0x2E / +0x2F; see INPUT.buttons). Which of the two gear bytes shifts up is checked against the gear selector the
-- first time a bound gear key moves it, and swapped if it went the other way (log: key bindings).
local binds = {list = {{'forward', 'Gunner Drive: Forward'}, {'back', 'Gunner Drive: Back'},
                       {'left', 'Gunner Drive: Steer Left'}, {'right', 'Gunner Drive: Steer Right'},
                       {'gear_up', 'Gunner Drive: Shift Up'}, {'gear_down', 'Gunner Drive: Shift Down'},
                       {'handbrake', 'Gunner Drive: Handbrake'},
                       {'horn', 'Gunner Drive: Horn'}, {'smoke', 'Gunner Drive: Smoke (Maelstrom)'}},
               api = nil, at = 0, keys = {}, ids = {}, down = {}, used = {},
               gear = {up = 0x2F, down = 0x2E, handbrake = 0x2D, sel = nil, from = nil, dir = nil, check_at = nil, held = false, learned = false}}
S.bindings, S.bindings_used = 'Mod Bindings Menu not installed (the built-in keys work)', 'none yet'
function binds.link(frame)
    if binds.api or frame < binds.at then return end
    binds.at = frame + 60
    local tanks, frv = rawget(_G, 'ArmoredOverhaulGunnerDriveOn') == true, rawget(_G, 'ArmoredOverhaulFRVDriveOn') == true
    if not tanks and not frv then return end
    local B = rawget(_G, 'ModBindingsMenu')
    if type(B) ~= 'table' or B.api ~= 1 or type(B.register_binding) ~= 'function' or type(B.is_down) ~= 'function' then return end
    -- (3.0.1 review) the menu is taken only once a binding is registered: when none could be, it is tried again a
    -- second later (3.0.0 took it at once and never tried again)
    local failed
    for _, b in ipairs(binds.list) do
        if b[1] ~= 'smoke' or tanks then
            local id = 'armored_overhaul.gunner_drive.' .. b[1]
            local ok, done, why = pcall(B.register_binding, id, b[2], nil, {category = 'ARMORED OVERHAUL'})
            if ok and done then
                binds.keys[#binds.keys + 1], binds.ids[#binds.ids + 1] = b[1], id
            else
                failed = b[1] .. ': ' .. tostring(ok and why or done)
            end
        end
    end
    if #binds.keys == 0 then
        S.bindings = 'Mod Bindings Menu found, no binding added yet (tried again once a second): ' .. tostring(failed)
        return
    end
    binds.api = B
    S.bindings = #binds.keys .. ' Gunner Drive binding(s) in the controls, tab MODS' .. (failed and ('; not added: ' .. failed) or '')
    hist('Mod Bindings Menu found: ' .. S.bindings)
end
-- once per driving frame: which bound keys are held (none while the menu isn't ready, e.g. an unsupported game build)
-- (3.0.1 review) and none while the game's window is in the background, like a controller (see pads)
function binds.poll()
    local B, down = binds.api, binds.down
    if not B then return end
    local okr, ready = true, true
    if pads.focused and not pads.focused() then ready = false
    elseif type(B.ready) == 'function' then okr, ready = pcall(B.ready) end
    for i, k in ipairs(binds.keys) do
        local v = false
        if okr and ready then
            local ok, r = pcall(B.is_down, binds.ids[i])
            v = ok and r == true
        end
        if v and not binds.used[k] then
            binds.used[k] = true
            local u = {}
            for _, b in ipairs(binds.list) do if binds.used[b[1]] then u[#u + 1] = b[1] end end
            S.bindings_used = table.concat(u, ', ')
        end
        if TESTER and v ~= (down[k] or false) then itrace('binding ' .. k .. (v and ' down' or ' up')) end
        down[k] = v
    end
end
-- (3.2.0) the bound Handbrake / Shift Up / Shift Down, held into the driver record (after the game's own buttons are
-- copied in); a bound gear key's first press notes the selector, checked half a second later (see binds.learn)
function binds.buttons(record)
    local d, g = binds.down, binds.gear
    if d.handbrake then record[g.handbrake] = 1 end
    local dir = d.gear_up and 'up' or (d.gear_down and 'down') or nil
    if dir and not g.held and not g.learned and not g.check_at and g.sel
        and record[0x2E] == 0 and record[0x2F] == 0 then         -- (not while the game's own gear keys are held)
        g.from, g.dir, g.check_at = g.sel, dir, S.time + 0.5
    end
    g.held = dir ~= nil
    if d.gear_up then record[g.up] = 1 end
    if d.gear_down then record[g.down] = 1 end
end
-- (with the instruments, every 4 frames) the gear selector now: 0 R, 1 N, 2 D, 3 first, 4 second
function binds.learn(sel)
    local g = binds.gear
    g.sel = sel
    if not g.check_at or S.time < g.check_at then return end
    g.check_at = nil
    if not (sel and g.from) or sel == g.from then return end     -- (didn't move: top or bottom gear; asked again next press)
    g.learned = true
    if (sel > g.from) ~= (g.dir == 'up') then g.up, g.down = g.down, g.up end
    local note = string.format('bound Shift Up = record +0x%X (checked: the gear went %s)', g.up, sel > g.from and 'up' or 'down')
    S.bindings = S.bindings .. '; ' .. note
    hist(note)
end
-- the bound driving keys as a stick: x (right +), y (forward +), or nil when none is held. (3.0.1 review) A diagonal
-- (Forward + Steer Left) stays full forward and full steering, as W + A give it: scaling it to length 1 made bound keys
-- drive at two thirds throttle while turning
function binds.axes()
    local d = binds.down
    local x = (d.right and 1 or 0) - (d.left and 1 or 0)
    local y = (d.forward and 1 or 0) - (d.back and 1 or 0)
    if x == 0 and y == 0 then return nil end
    return x, y
end

local input_note, tag_note
do
    local last_in, tag_was = {}, {}
    local VF = 'look A %.2f %.2f %.2f, look B %.2f %.2f %.2f, forward %.2f, reverse %.2f, +0x20 %.2f'
    -- (tester) the record's input floats (`f`: a float pointer to it), one line when they change
    input_note = function(where, f)
        local s = string.format(VF, f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8])
        if last_in[where] == s then return end
        last_in[where] = s
        local sx, sy = pads.stick()
        itrace(where .. ': ' .. s .. (sx and string.format(' (left stick %.2f %.2f)', sx, sy) or ''))
    end
    -- (tester) the input tags (4 words at `at` in mem), one line when they change
    tag_note = function(at)
        local changed = false
        for i = 0, 3 do
            local w = mem_u32(at + i * 4)
            if w ~= tag_was[i] then tag_was[i] = w; changed = true end
        end
        if changed then itrace(string.format('input tags %08x %08x %08x %08x', tag_was[0], tag_was[1], tag_was[2], tag_was[3])) end
    end
end

local function clear_record(record)
    local w = ffi.cast(U32P, record)
    for i = 0, 8 do w[i] = 0 end            -- +0x00 .. +0x23: look vectors, forward, reverse, look A x
    for o = 0x2C, 0x2F do record[o] = 0 end -- driver flag and buttons
end

local function input_paused(me)
    local from = PLAYERS.vstate + PLAYERS.leaving
    if not fetch(me.tags_at, PLAYERS.tags + 16 - from) then return true end
    if mem[0] ~= 0 then return true end                        -- leaving the seat
    local tags = PLAYERS.tags - from
    if TESTER then tag_note(tags) end
    for _, bit in ipairs(BLOCK_BITS) do
        local word = mem_u32(tags + floor(bit / 32) * 4)
        if floor(word / 2 ^ (bit % 32)) % 2 == 1 then return true end
    end
    return false
end

local look = ffi.new('uint8_t[24]')
local LF = ffi.cast(F32P, look)                 -- (3.0 review: cast once) look B at [0..2], look A at [3..5]
local FWD_I = (INPUT.forward * INPUT.action_size + 4) / 4    -- the actions' values as float indexes into mem
local REV_I = (INPUT.reverse * INPUT.action_size + 4) / 4
local last = {}
local function feed(me, record)
    if record ~= last.record then last.record, last.f = record, ffi.cast(F32P, record) end   -- (cast once per record)
    local f = last.f
    -- what we wrote last frame should still be there; if the game replaced it, something else feeds this tank
    -- (another player's game running it, for one). Counted for the log. Read directly: this is the record we
    -- write every frame (its page was checked by driver_record).
    if last.forward and (f[6] ~= last.forward or f[7] ~= last.reverse) then
        S.overwritten = S.overwritten + 1
        if S.overwritten == 1 or S.overwritten % 600 == 0 then hist('driving input replaced by the game (' .. S.overwritten .. ' frames so far)') end
    end
    last.paused = input_paused(me)
    if last.paused then
        clear_record(record); last.forward, last.reverse = 0, 0
        S.drive_paused = S.drive_paused + 1
        return true
    end
    local size = INPUT.action_size
    if not fetch(me.actions_at, size * 7) then return false, 'input unreadable' end
    local forward, reverse = MEMF[FWD_I], MEMF[REV_I]
    for i = 1, #BUTTON_FIELDS do button_values[i] = mem[BUTTON_ACTIONS[i] * size] end
    S.reads = S.reads + 1
    if ReadProcessMemory(self_process, me.look_at, look, 24, nil) == 0 then return false, 'look unreadable' end
    -- the record as the game's driver code fills it (game.dll 0xA7E435-0xA7E621): +0x00 look A, +0x0C look B,
    -- +0x18 forward (W), +0x1C reverse (S), +0x20 look A x, +0x2C driver flag, buttons
    f[0], f[1], f[2], f[3], f[4], f[5] = LF[3], LF[4], LF[5], LF[0], LF[1], LF[2]
    f[6], f[7], f[8] = forward, reverse, LF[3]
    record[0x2C] = 1
    for i = 1, #BUTTON_FIELDS do record[BUTTON_FIELDS[i]] = button_values[i] end
    if TESTER and S.frames % 5 == 0 then input_note('gunner seat, from the game', f) end
    local sx, sy = pads.stick()
    binds.poll()
    binds.buttons(record)
    local bx, by = binds.axes()                  -- (3.0.1) the Gunner Drive keys from the Mod Bindings Menu: as a stick
    if bx then
        if not sx then sx, sy = bx, by
        else
            if math.abs(bx) > math.abs(sx) then sx = bx end
            if math.abs(by) > math.abs(sy) then sy = by end
        end
    end
    if sx then                                  -- (2.1) a controller's left stick drives (see pads)
        -- (3.0 review) forward and back past a small dead zone of their own, so a stick pushed hard left or right no
        -- longer creeps forward; the stick steers only when pushed further than A/D (it used to override them)
        local dz, y = pads.dead_y, 0
        if sy > dz then y = (sy - dz) / (1 - dz) elseif sy < -dz then y = (sy + dz) / (1 - dz) end
        if y > 0 then f[6] = max(f[6], y) elseif y < 0 then f[7] = max(f[7], -y) end
        local kx = LF[3]
        if math.abs(sx) >= math.abs(kx) then f[0], f[8] = sx, sx end
        -- (3.0: the stick didn't turn a stopped tank on the spot, A/D do) with no driving key held, the whole look
        -- vector as a driver's stick gives it (x the steering, y the push, no z); with W/S/A/D held the keys' own y
        -- and z stay (3.0 review: W plus a sideways stick turned on the spot instead of curving)
        if forward == 0 and reverse == 0 and math.abs(kx) < 0.01 then f[1], f[2] = y, 0 end
        if S.controller == 'not used yet' and not bx then S.controller = 'used (the left stick drives)' end
        if TESTER and S.frames % 5 == 0 then input_note('gunner seat, written', f) end
    end
    last.forward, last.reverse = f[6], f[7]
    S.drive_frames = S.drive_frames + 1
    -- (3.0 review) what is written, controller included (2.1: the keyboard's values only)
    if TESTER and S.frames % 30 == 0 then S.last_input = string.format('forward %.2f reverse %.2f steer %.2f%s', f[6], f[7], f[0], sx and ' (left stick)' or '') end
    return true
end

local drive = nil      -- {vehicle, kind, me, ...} while we are feeding a vehicle
-- The seat you sit in, published for the Vehicle Indicator, Gunner Camera and driver panel (see publish below);
-- driving/gear while you drive from the gunner seat.
local SEAT_PUB = {kind = nil, role = 0, vehicle = 0, frame = 0, driving = false, gear = nil, selector = nil, rpm = nil,
                  speed = nil, fuel = nil, engine = nil, smoke = nil, smoke_full = nil, remote = false}
S.engine, S.engine_starts, S.gear_read, S.hud_font = 'not driven yet', 0, 'not read yet', 'not read yet'
S.control = 'no other driver seen'
rawset(_G, 'ArmoredOverhaulSeat', SEAT_PUB)
-- (3.1.1 review: one place; it was written out twice) the driving fields: nothing driven any more
local function clear_drive_pub()
    SEAT_PUB.driving, SEAT_PUB.gear, SEAT_PUB.selector, SEAT_PUB.rpm, SEAT_PUB.speed, SEAT_PUB.fuel, SEAT_PUB.engine, SEAT_PUB.smoke, SEAT_PUB.smoke_full, SEAT_PUB.remote = false
end
local last_driver, last_driver_n = {}, 0     -- (1.3) who drove each vehicle last: 'me' / 'other' (see note_drivers)

-- ------------------------------------------------------------------------------------------ smoke (1.2.2)
-- The Maelstrom's smoke launcher from the gunner seat: Mouse 3 (controller: the right stick click, 3.0) while you drive. The driver fires it with the fire key,
-- which presses one of the five trigger slots on the player's own character (trigger component [game+0x3326420]:
-- map +0x30, 0x1D0-byte records at +0x60, five 0x50-byte slots, weapon at +0); the game only fires a weapon for the
-- player named in its operator entry ([game+0x3326730]: map +0x18, one u32 per weapon at +0x38). While Mouse 3 is held
-- the smoke launcher goes in a free slot of yours (2-4) with you as its operator, and that slot is pressed and released
-- with the game's own trigger calls (game.dll+0x786BE0 press(_, you, slot), +0x786DF0 release(trigger manager, you,
-- slot)). 3 s after you let go - or at once when you stop driving - the operator entry and your whole slot are put
-- back. The operator entry is only taken while it is free (nobody, or you): a teammate who takes the driver seat keeps
-- the launcher (1.2.2 review: it was re-set to you every 10 frames for those 3 s).
-- Which weapon is the smoke launcher: tank id + 3, or the one exactly one place after your gun in the gun-and-smoke
-- table [game+0x3326A70] (map +0x20), that has an entry in the ammo table [game+0x3326648] (map +0x20) and is not a main gun
-- ([game+0x33267A0], map +0x28). (Tests 10-12: the weapon one place before the gun belongs to something else; Tests 7-9
-- also remembered the launcher from the driver seat, dropped because the game reuses tank ids.)
-- Rounds left: u32 at [ammo table +0x48] + index x 16, read every 30 frames and just after each press and release.
-- Known game build only: the tables move with game updates, and then Mouse 3 does nothing and the log says so.
-- a game global's table pointer and its header (the smoke launcher and the Autoloader)
local function mgr_hdr(global, n)
    local p = fetch_ptr(global)
    return p and fetch_str(p, n), p
end
-- (2.1 review) the smoke launcher, scoped: only what is used further down is a top-level local
local SMK, smoke, smoke_rounds, keys, field, button_of, pressed, smoke_restore, smoke_frame
do
-- (3.1.1 review) the tables and calls come from FEAT.smoke (found by pattern); SMK keeps the constants
SMK = {kind = 0x2C, restore = 3, retry = 300}   -- (3.0.1 review: restore in seconds)
local NOSMOKE = {}     -- (no smoke places in this game version: every table look-up finds nothing)
smoke = {id = nil, vehicle = nil, next_find = 0, held = false, active = nil, full = {}, memo = {}, check = 0, rounds_at = 0}
S.smoke, S.smoke_shots = 'not used yet', 0
-- the key of the entry holding `value` in the map at `at` of header `h`
local function map_key(h, at, value)
    local entries, cap, empty = str_ptr(h, at), le32(h, at + 8), le32(h, at + 12)
    if not entries or not cap or cap < 1 or cap > 0x4000 then return nil end
    local s = fetch_str(entries, cap * 8)
    if not s then return nil end
    for i = 0, cap - 1 do
        local k = le32(s, i * 8)
        if k ~= empty and le32(s, i * 8 + 4) == value then return k end
    end
end
-- your trigger record and the trigger manager
local function my_trigger(entity)
    local th, T = mgr_hdr((FEAT.smoke or NOSMOKE).trig, 0x70)
    local ti = th and map_get(th, 0x30, entity)
    local recs = th and str_ptr(th, 0x60)
    if not ti or not recs then return nil end
    return recs + ti * 0x1D0, T
end
local function operator_at(w)
    local oh = mgr_hdr((FEAT.smoke or NOSMOKE).oper, 0x40)
    local idx = oh and map_get(oh, 0x18, w)
    local arr = oh and str_ptr(oh, 0x38)
    if not idx or not arr then return nil end
    return arr + idx * 4
end
local function set_u32(p, v)
    if p == nil or not data_pages(p, 4) then return false end
    ffi.cast(U32P, p)[0] = v
    return true
end
smoke_rounds = function(w)
    local ah = mgr_hdr((FEAT.smoke or NOSMOKE).ammo, 0x50)
    local idx = ah and map_get(ah, 0x20, w, smoke.memo)
    local arr = ah and str_ptr(ah, 0x48)
    local n = idx and arr and fetch_u32(arr + idx * 16)
    return n and n <= 1000 and n or nil
end
local function find_smoke(vehicle, gun)
    local ph, ah, gh = mgr_hdr((FEAT.smoke or NOSMOKE).pair, 0x40), mgr_hdr((FEAT.smoke or NOSMOKE).ammo, 0x50), mgr_hdr((FEAT.smoke or NOSMOKE).guns, 0x40)
    if not ph or not ah or not gh then return nil, 'weapon tables unreadable' end
    local gp, ga = map_get(ph, 0x20, gun), map_get(ah, 0x20, gun)
    if not gp or not ga then return nil, 'your gun is not in the weapon tables' end
    -- (the smoke launcher is registered right after the gun: one place later in both tables. The weapon one place
    -- before it belongs to something else - 1.2.2 Test 11 found one there - and is never used)
    local cands, tried, found = {vehicle + 3}, {}, nil
    local k = map_key(ph, 0x20, gp + 1)
    if k then cands[#cands + 1] = k end
    if TESTER then
        local kb = map_key(ph, 0x20, gp - 1)
        if kb then strace(string.format('  (not used) one place before your gun: %08x, ammo %s, rounds %s', kb, tostring(map_get(ah, 0x20, kb)),
            tostring(smoke_rounds(kb))), true) end
    end
    for _, c in ipairs(cands) do
        if c ~= gun and not tried[c] then
            tried[c] = true
            local cp, ca = map_get(ph, 0x20, c), map_get(ah, 0x20, c)
            if TESTER then strace(string.format('  candidate %08x: pair %s, ammo %s, main gun %s, rounds %s', c, tostring(cp), tostring(ca),
                tostring(map_get(gh, 0x28, c) ~= nil), tostring(smoke_rounds(c))), true) end
            -- (2.0 Test 3: the tables reorder during a mission - the launcher stayed tank + 3 but was no longer next
            -- to the gun in the ammo table - so tank + 3 counts on its own; any other weapon must sit right after the
            -- gun in both tables)
            -- (3.0.1: in a test match the launcher was tank id - 3, right after the gun in the gun-and-smoke
            -- table but two places later in the ammo table, so none was found; the ammo table's order no longer counts)
            -- (3.1.1 Test 3) in a game you join, the gun-and-smoke table holds every player's weapons (180 in a test log) and
            -- the one right after your gun was another tank's (another player its operator, 2-37 rounds); one tank's
            -- weapons get ids close together (gun 0x64c, smoke 0x64e), so a launcher far from both your gun's and your
            -- tank's id is not taken
            local near = c == vehicle + 3 or math.abs(c - gun) <= 8 or math.abs(c - vehicle) <= 8
            if TESTER and not near and cp == gp + 1 then strace(string.format('  %08x: right after your gun but far from it and your tank: not this tank\'s', c), true) end
            if cp and ca and near and not map_get(gh, 0x28, c) and (c == vehicle + 3 or cp == gp + 1) then
                if found and found ~= c then
                    if found ~= vehicle + 3 and c == vehicle + 3 then found = c end            -- (tank + 3 wins)
                else
                    found = c
                end
            end
        end
    end
    return found, found and (found == vehicle + 3 and 'tank id + 3' or 'right after your gun') or 'none found'
end
-- (tester) your trigger slot, its trigger bytes and state bits, the operator entry and the rounds, as one text
local function smoke_detail(entity, w, slot)
    local th = mgr_hdr((FEAT.smoke or NOSMOKE).trig, 0x70)
    local ti = th and map_get(th, 0x30, entity)
    local recs = th and str_ptr(th, 0x60)
    local sw = ti and recs and fetch_u32(recs + ti * 0x1D0 + slot * 0x50)
    local tb = ti and str_ptr(th, 0x58) and fetch_str(str_ptr(th, 0x58) + ti * 32, 8)
    local st = ti and str_ptr(th, 0x68) and fetch_u32(str_ptr(th, 0x68) + ti * 4)
    local op = operator_at(w)
    local ov = op and fetch_u32(op)
    return string.format('slot %d = %s, trigger bytes %s, state %s, operator %s, rounds %s', slot,
        sw and string.format('%08x', sw) or '?', tb and string.format('%02x%02x%02x%02x %02x%02x%02x%02x', tb:byte(1, 8)) or '?',
        st and string.format('%08x', st) or '?', ov and string.format('%08x', ov) or '?', tostring(smoke_rounds(w)))
end
-- (tester, 3.1.1 Test 2) every weapon in the gun-and-smoke table, in table order: id, its place in the gun-and-smoke and
-- ammo tables, rounds, operator (0 = nobody), and whether it is a main gun. In a game you join, the weapon right after
-- your gun was another tank's (rounds 4 then 2, its operator someone else), so this shows how the table is laid out there.
smoke.tables = function(gun, pick)
    if not TESTER then return end
    local ph, ah, gh = mgr_hdr((FEAT.smoke or NOSMOKE).pair, 0x40), mgr_hdr((FEAT.smoke or NOSMOKE).ammo, 0x50), mgr_hdr((FEAT.smoke or NOSMOKE).guns, 0x40)
    if not ph or not ah or not gh then strace('  tables: unreadable', true); return end
    local entries, cap, empty = str_ptr(ph, 0x20), le32(ph, 0x28), le32(ph, 0x2C)
    local es = entries and cap and cap >= 1 and cap <= 0x4000 and fetch_str(entries, cap * 8)
    if not es then strace('  tables: gun-and-smoke map unreadable', true); return end
    local list = {}
    for i = 0, cap - 1 do
        local k = le32(es, i * 8)
        if k ~= empty then list[#list + 1] = {k = k, p = le32(es, i * 8 + 4)} end
    end
    table.sort(list, function(a, b) return a.p < b.p end)
    local parts = {}
    for i, e in ipairs(list) do
        if i > 40 then strace('  table: ... ' .. (#list - 40) .. ' more', true); break end
        local op = operator_at(e.k)
        local ov = op and fetch_u32(op)
        parts[#parts + 1] = string.format('%s%08x p%d a%s r%s op%s%s', e.k == gun and '[gun] ' or (e.k == pick and '[pick] ' or ''), e.k, e.p,
            tostring(map_get(ah, 0x20, e.k)), tostring(smoke_rounds(e.k)), ov and string.format('%08x', ov) or '-',
            map_get(gh, 0x28, e.k) and ' main' or '')
        if #parts == 4 then strace('  table: ' .. table.concat(parts, ' | '), true); parts = {} end
    end
    if #parts > 0 then strace('  table: ' .. table.concat(parts, ' | '), true) end
end
-- (tester, 3.1.1 Test 2) in a Maelstrom's driver seat the game puts that tank's own smoke launcher in your trigger slot 0:
-- logged once per tank, a second after you sit down, with the tables, to compare with what the gunner-seat look-up picks
smoke.driver_seen = {}
smoke.driver_note = function(mine, me)
    if not TESTER or not FEAT.smoke or not me or not me.entity then return end
    local d = smoke.driver_seen[mine.vehicle]
    if d == true then return end
    if not d then smoke.driver_seen[mine.vehicle] = S.frames + 60; return end
    if S.frames < d then return end
    smoke.driver_seen[mine.vehicle] = true
    local rec = my_trigger(me.entity)
    local r = rec and fetch_str(rec, 0x1D0)
    local slots = {}
    for i = 0, 4 do slots[#slots + 1] = r and string.format('%08x', le32(r, i * 0x50)) or '?' end
    local w = r and le32(r, 0)
    strace(string.format('driver seat: vehicle %08x, you %08x, your slots %s; slot 0 (the smoke launcher): %s',
        mine.vehicle, me.entity, table.concat(slots, ' '), w and w ~= 0 and smoke_detail(me.entity, w, 0) or 'empty'), true)
    pcall(smoke.tables, nil, w)
    write_log(true)
end
-- The smoke key: Mouse 3, or the right stick click on a controller (3.0; 1.2.2-2.1.0 Test 18: the left stick click,
-- now the horn; Tests 19-20: the right bumper, the game's mark button). Controllers: see pads.
keys = {mouse = nil, dev = {}}
local function index_of(dev, k) return dev[k] end
field = function(dev, k) local ok, v = pcall(index_of, dev, k); return ok and v or nil end
button_of = function(dev, names)
    local d = keys.dev[dev]
    if d then return d end
    d = {button = field(dev, 'button'), active = field(dev, 'active')}
    local bi = field(dev, 'button_index')
    if d.button and bi then
        for _, n in ipairs(names) do
            local ok, i = pcall(bi, n)
            if ok and type(i) == 'number' then d.idx = i; break end
        end
    end
    keys.dev[dev] = d
    return d
end
pressed = function(d) if not d.idx then return false end local ok, v = pcall(d.button, d.idx); return ok and type(v) == 'number' and v > 0.5 end
local function smoke_key()
    if binds.down.smoke then return true end      -- (3.0.1) the key set in the Mod Bindings Menu
    local SR = rawget(_G, 'stingray')
    if type(SR) ~= 'table' then return false end
    if keys.mouse == nil then local m = field(SR, 'Mouse'); keys.mouse = m and button_of(m, {'middle'}) or false end
    if keys.mouse and pressed(keys.mouse) then return true end
    return pads.button('smoke')
end
local smk_press, smk_release
-- (smoke_restore: declared before the block)
-- Mouse 3 down: the smoke launcher `w` in a free trigger slot of yours, you as its operator, the slot pressed.
local function smoke_down(me, w)
    local rec = my_trigger(me.entity)
    -- (2.0.1 review) a launcher still held from before (another launcher, or your record moved) is put back first,
    -- so what is remembered as "before" is never this addon's own change
    local held = smoke.active
    if held and (held.w ~= w or held.rec ~= rec) then smoke_restore() end
    local r = rec and fetch_str(rec, 0x1D0)
    if not r then return 'your trigger record is unreadable' end
    local a = smoke.active
    local slot = a and a.w == w and a.rec == rec and a.slot
    if not slot then
        for s = 2, 4 do
            local cur = le32(r, s * 0x50)
            if cur == 0 or cur == invalid_entity() or cur == w then slot = s; break end
        end
    end
    if not slot then return 'no free trigger slot' end
    local at = rec + slot * 0x50
    local op = operator_at(w)
    if not op or not fetch(op, 4) then return 'the smoke launcher has no operator entry' end
    local cur_op = mem_u32(0)
    -- (2.0.1 review) everything is checked before anything is written: 2.0.0 filled your slot first and could leave
    -- the launcher in it when the operator entry then turned out not to be writable
    if not data_pages(at, 0x50) then return 'trigger slot not plain data' end
    if not data_pages(op, 4) then return 'operator entry not plain data' end
    -- (the operator entry is only taken while it is free: nobody, or you)
    if cur_op ~= 0 and cur_op ~= me.entity and cur_op ~= invalid_entity() then return 'someone else operates the smoke launcher' end
    if not a or a.w ~= w or a.rec ~= rec then
        a = {w = w, rec = rec, slot = slot, op = op, old = cur_op, me = me.entity, orig = r:sub(slot * 0x50 + 1, slot * 0x50 + 0x50)}
    end
    ffi.copy(at, r:sub(1, 0x50), 0x50)                               -- (your gun slot's aim values)
    local u = ffi.cast(U32P, at)
    u[0], u[1] = w, invalid_entity() or 0
    set_u32(op, me.entity)
    if not smk_press then
        smk_press = ffi.cast('void (*)(void *, uint32_t, uint32_t)', FEAT.smoke.press)
        smk_release = ffi.cast('void (*)(void *, uint32_t, uint32_t)', FEAT.smoke.release)
    end
    a.restore_at = nil
    smoke.active = a
    smk_press(nil, me.entity, slot)
    return nil
end
-- Lets go of the smoke launcher's trigger slot. (2.0.1 review) The game's release looks you up in its trigger table
-- without checking, like the engine switch: for someone not in it, it reads far outside the table and closes the game.
-- So you and the trigger manager are looked up fresh right before the call (2.0.0 passed the manager kept from the
-- press), and when you are gone - the tank destroyed or the mission ending while the key is held - the call is
-- skipped: the game drops the press itself when it takes you apart.
local function smoke_release(a)
    local rec, T = my_trigger(a.me)
    if not rec or not T or not smk_release then return false end
    pcall(smk_release, T, a.me, a.slot)
    return true
end
-- puts the smoke launcher's operator entry and your trigger slot back (releasing first if still held)
smoke_restore = function()
    local a = smoke.active
    if not a then return end
    smoke.active = nil
    if smoke.held then smoke.held = false; smoke_release(a) end
    if operator_at(a.w) == a.op and fetch(a.op, 4) and mem_u32(0) == a.me then set_u32(a.op, a.old) end
    if TESTER then strace(string.format('put back: operator %08x, slot %d cleared', a.old or 0, a.slot)) end
    local at = a.rec + a.slot * 0x50
    if my_trigger(a.me) == a.rec and fetch(at, 4) and mem_u32(0) == a.w and data_pages(at, 0x50) then ffi.copy(at, a.orig, 0x50) end
end
-- every frame you drive the Maelstrom from the gunner seat
smoke_frame = function(me, paused)
    if not FEAT.smoke then S.smoke = 'not available in this game version'; return end
    if smoke.vehicle ~= drive.vehicle then smoke_restore(); smoke.vehicle, smoke.id, smoke.next_find, smoke.rounds_at = drive.vehicle, nil, 0, 0 end
    if not smoke.id and S.frames >= smoke.next_find then
        smoke.next_find = S.frames + SMK.retry
        local rec = my_trigger(me.entity)
        local gun = rec and fetch_u32(rec)
        local why
        if gun and gun ~= 0 then smoke.id, why = find_smoke(drive.vehicle, gun) else why = 'your gun slot is empty' end
        if TESTER then
            local ph, ah = mgr_hdr((FEAT.smoke or NOSMOKE).pair, 0x40), mgr_hdr((FEAT.smoke or NOSMOKE).ammo, 0x50)
            local function ix(h, w) return h and w and map_get(h, 0x20, w) or '-' end
            local slots = {}
            local r = rec and fetch_str(rec, 0x1D0)
            for i = 0, 4 do slots[#slots + 1] = r and string.format('%08x', le32(r, i * 0x50)) or '?' end
            strace(string.format('look-up: vehicle %08x, you %08x, your slots %s; gun %s (pair %s, ammo %s); smoke %s (pair %s, ammo %s): %s',
                drive.vehicle, me.entity, table.concat(slots, ' '), gun and string.format('%08x', gun) or '-', tostring(ix(ph, gun)),
                tostring(ix(ah, gun)), smoke.id and string.format('%08x', smoke.id) or '-', tostring(ix(ph, smoke.id)),
                tostring(ix(ah, smoke.id)), tostring(why)), true)
            if smoke.id then strace('  before any press: ' .. smoke_detail(me.entity, smoke.id, 2), true) end
            pcall(smoke.tables, gun, smoke.id)
            write_log(true)
        end
        -- (3.0.1 review) the bound Smoke key named too, when one is registered
        local bound = ''
        for _, k in ipairs(binds.keys) do if k == 'smoke' then bound = ' + your Gunner Drive: Smoke binding' end end
        S.smoke = smoke.id and string.format('ready on Mouse 3 / right stick click%s (smoke launcher %s)', bound, why) or ('not found: ' .. tostring(why))
        if not smoke.id and smoke.last_why ~= why then hist('smoke launcher not found: ' .. tostring(why)) end
        smoke.last_why = why
    end
    local t = smoke.active
    if TESTER and t and smoke.trace_at and S.frames >= smoke.trace_at then
        strace(smoke.trace_what .. smoke_detail(me.entity, t.w, t.slot))
        smoke.trace_at = nil
        write_log(true)
    end
    local down = smoke.id and not paused and smoke_key() or false
    if down and not smoke.held then
        local err = smoke_down(me, smoke.id)
        if err then
            S.smoke = 'the smoke key did nothing: ' .. err; hist('smoke: ' .. err)
            smoke.id, smoke.next_find = nil, S.frames + SMK.retry     -- (looked up again)
        else
            smoke.held = true; S.smoke_shots = (S.smoke_shots or 0) + 1
            smoke.rounds_soon = min(smoke.rounds_soon or 1e9, S.frames + 10)
            if TESTER then
                local a = smoke.active
                strace(string.format('smoke key down: pressed slot %d (operator was %08x): %s', a.slot, a.old or 0, smoke_detail(me.entity, a.w, a.slot)))
                smoke.trace_at, smoke.trace_what = S.frames + 10, '  10 frames after the press: '
            end
        end
    elseif not down and smoke.held then
        smoke.held = false
        local a = smoke.active
        if a then smoke_release(a); a.restore_at = S.time + SMK.restore end
        smoke.rounds_soon = min(smoke.rounds_soon or 1e9, S.frames + 10)
        if TESTER and a then
            strace('smoke key up: released: ' .. smoke_detail(me.entity, a.w, a.slot))
            smoke.trace_at, smoke.trace_what = S.frames + 60, '  1 s after the release: '
        end
    end
    local a = smoke.active
    if a then
        if a.restore_at and S.time >= a.restore_at then smoke_restore()
        elseif smoke.held and S.frames >= smoke.check then             -- (held: the game may clear the entry, set again)
            smoke.check = S.frames + 10
            if fetch(a.op, 4) and (mem_u32(0) == 0 or mem_u32(0) == a.old) and mem_u32(0) ~= me.entity and operator_at(a.w) == a.op then
                set_u32(a.op, me.entity)
            end
        end
    end
end


end
-- ------------------------------------------------------------------------------------------ driving
local settle = nil     -- {vehicle, n} while a new seat settles
local tries = nil      -- {vehicle, n}: drives that failed on their first frame (see poll)
local shown_seat = {}  -- last seat written to the log fields (they are only reformatted when it changes)

-- The game marks your seat as moving while you get in or out, or move seats (in the tanks, the gunner can move to
-- the passenger seats on either side; nobody can move to or from the driver seat). While Gunner Drive had the engine
-- on, the engine is left alone until the move ends: someone driving that tank then keeps it running; otherwise it is switched off, as when a driver gets out. (1.2.1 Test 2
-- left it idling; 1.2.2: 1.2.1 left it idling when you got out while a teammate sat in any other tank.)
local pending_off = nil
-- (3.0.1) Getting out of a vehicle you drive from the gunner seat while it rolls: Gunner Drive brakes it to a stop.
-- Getting out of a moving tank could kill you and fling you away: the game puts the gunner out beside the turret, in
-- the path of a tank that kept rolling once the drive let go (worst with the turret turned round, MBT Turrets).
-- brake = {vehicle, t0, dir, v0} while braking (see brake_frame).
local brake = nil
local cancel_brake     -- (3.1.1 review; below brake_frame)
local BRAKE = {max_time = 6, stop_ratio = 0.1, stop_min = 0.5, done = 0, handbrake = 0x2D}
-- ------------------------------------------------------------------------------------------ horn (2.1)
-- The horn from the gunner seat: F (controller: the left stick click) while you drive (Tank and FRV Gunner Drive). The driver's F (the game's input
-- action 19) makes the game's driver code call game.dll+0x70E7B0 (_, vehicle, on), which only sets one byte: the
-- vehicle's horn flag in the vehicle buttons component ([game+0x33268C0]: map +0x30, 20-byte records at +0x50, horn
-- at +6). Gunner Drive sets and clears that same byte, only when it changes, and clears it whenever the drive stops or
-- pauses. The component is taken from that function's code (SITES.horn), so a game update that moves it doesn't break
-- the horn. Found in 2.1.0 Tests 11-12 (the input actions F changed, then the game's code that reads action 19).
-- (2.1 review) the horn, scoped
local horn, horn_frame, horn_release
do
horn = {on = false, vehicle = nil, memo = {}, key = nil, uses = 0}
S.horn = 'not used yet'
local function horn_at(vehicle)
    local comp = FEAT.horn and fetch_ptr(FEAT.horn)
    local hdr = comp and fetch_str(comp + 0x30, 0x28)
    if not hdr then return nil end
    local idx = map_get(hdr, 0, vehicle, horn.memo)
    local recs = str_ptr(hdr, 0x20)
    if not idx or not recs or idx > 0xFFFF then return nil end
    local p = recs + idx * 0x14 + 6
    return data_pages(p, 1) and p or nil
end
local function horn_set(vehicle, on)
    local p = horn_at(vehicle)
    if not p then return false end
    p[0] = on and 1 or 0
    return true
end
local function horn_key()
    if binds.down.horn then return true end      -- (3.0.1) the key set in the Mod Bindings Menu
    local SR = rawget(_G, 'stingray')
    if type(SR) ~= 'table' then return false end
    if horn.key == nil then local kb = field(SR, 'Keyboard'); horn.key = kb and button_of(kb, {'f'}) or false end
    if horn.key and pressed(horn.key) then return true end
    return pads.button('horn')             -- (2.1) the left stick click
end
-- every driving frame: F held = horn on (never while paused: a menu open, getting out)
horn_frame = function(vehicle, paused)
    if not FEAT.horn then S.horn = 'not available in this game version'; return end
    local want = (not paused) and horn_key() or false
    if want == horn.on and (not want or vehicle == horn.vehicle) then return end
    if horn.on and horn.vehicle and horn.vehicle ~= vehicle then horn_set(horn.vehicle, false) end
    if horn_set(vehicle, want) then
        horn.on, horn.vehicle = want, want and vehicle or nil
        if want then horn.uses = horn.uses + 1; S.horn = 'used ' .. horn.uses .. ' time(s)' end
    else
        horn.on, horn.vehicle = false, nil
        S.horn = 'this vehicle is not in the game\'s horn table'
    end
end
horn_release = function()
    if horn.on and horn.vehicle then pcall(horn_set, horn.vehicle, false) end
    horn.on, horn.vehicle = false, nil
end

end
local function stop_driving(why)
    clear_drive_pub()
    if not drive then return end
    if why == 'game closing' then
        -- the game is taking its objects apart: the tank is left alone (no record write, no engine call)
        hist('stopped: game closing'); drive, last.forward, last.reverse = nil, nil, nil
        horn.on, horn.vehicle = false, nil
        S.phase, S.status = 'watching', 'stopped: game closing'
        return
    end
    horn_release()           -- (2.1 review) first: nothing below can leave the horn on
    local record = driver_record(drive.vehicle)
    if record then clear_record(record) end
    pcall(smoke_restore)
    -- (2.0.1 review) the launcher is looked up again next time: the game reuses tank ids, so a new mission's tank can
    -- carry the old one's id with a different launcher
    smoke.vehicle, smoke.id, smoke.next_find = nil, nil, 0
    -- the engine goes off as when a driver gets out, unless a driver took over (their engine stays on)
    if drive.counted then hist('stopped: ' .. tostring(why)) end
    -- (1.2.1: not in the middle of a seat move - getting in or out - either: settle_engine decides once it ends)
    if drive.engine_on and why == 'moving_seat' then pending_off = {vehicle = drive.vehicle} end
    -- (3.0.1) getting out (or moving seats) while it rolls: braked to a stop first (brake_frame)
    if why == 'moving_seat' and drive.counted and FEAT.panel then
        if brake and brake.vehicle ~= drive.vehicle then cancel_brake('you drove another vehicle') end   -- (3.1.1 review)
        brake = {vehicle = drive.vehicle, t0 = S.time}
    end
    if drive.engine_on and why ~= 'has_driver' and why ~= 'moving_seat' and why ~= 'you took the driver seat' then
        local okc, ok, err = pcall(engine_switch, drive.vehicle, false)
        S.engine = S.engine .. ((okc and ok) and '; switched off when you stopped'
            or ('; not switched off (' .. tostring(okc and err or ok) .. ')'))
    end
    drive, last.forward, last.reverse = nil, nil, nil
    S.phase, S.status = 'watching', 'stopped: ' .. why
end

-- Settles a pending switch-off (see stop_driving). `mine` nil = you're in no vehicle; `others` = every other
-- occupied seat row (someone in that tank's driver seat keeps its engine running).
local function settle_engine(mine, verdict, others)
    if not pending_off or verdict == 'moving_seat' then return end
    if brake and brake.vehicle == pending_off.vehicle then return end     -- (3.0.1: after the braking)
    local v = pending_off.vehicle
    pending_off = nil
    if mine and mine.vehicle == v and (DRIVER_ROLES[mine.role] or verdict == 'has_driver' or verdict == 'drive') then return end
    for _, o in ipairs(others or {}) do
        if o.vehicle == v and DRIVER_ROLES[o.role] then return end    -- (someone drives it: left alone)
    end
    local okc, ok, why = pcall(engine_switch, v, false)
    if okc and ok then
        S.engine = S.engine .. '; switched off (you got out or moved seats and nobody drives)'
        hist('engine switched off: you got out or moved seats and nobody drives')
    else
        S.engine = S.engine .. '; not switched off (' .. tostring(okc and why or ok) .. ')'
    end
end

-- One frame of driving: copies your keys into the tank's driver-input record.
-- (3.0.1) One frame of braking: the opposite throttle to the way the vehicle rolls (reverse while it rolls forward;
-- forward when its gear says reverse), written into its driver-input record (looked up fresh, page-checked) with the
-- driver flag set - what a driver holding S does - and the handbrake held: record byte +0x2D, the one the Space key
-- sets (input action 6). The throttle direction is kept from the first frame to the stop (the tank's gearbox goes over
-- to the other direction almost at once, and letting go then barely braked). It ends, and the record is cleared, once
-- the vehicle is down to a crawl (the game's speed figure below 10% of what it was, or 0.5), after BRAKE.max_time
-- seconds, or as soon as someone takes the driver seat or you drive it again (see poll).
-- (3.1.1 review) braking ended early (the seat table unreadable, a driver took the seat, an error): the vehicle's
-- driver-input record is cleared too (looked up fresh, page-checked) - 3.1.0 just dropped the brake, which could leave
-- the throttle, handbrake and driver flag held on an empty vehicle (the game burns fuel while that flag is set)
cancel_brake = function(why)
    local b = brake
    brake = nil
    if not b then return end
    local okr, record = pcall(driver_record, b.vehicle)
    if okr and record then pcall(clear_record, record) end
    if why then hist('braking stopped: ' .. why) end
end
local function brake_frame()
    local b = brake
    local record, index, hdr = driver_record(b.vehicle)
    -- (3.1.1 review) a look-up that fails is tried again each frame until the braking time is up (3.1.0 dropped the brake
    -- at once, with the throttle, handbrake and driver flag left in the record)
    if not record then
        if S.time - b.t0 > BRAKE.max_time then brake = nil; hist('braking stopped: the vehicle can no longer be found') end
        return
    end
    local inst = b.inst or {}
    b.inst = inst
    if not read_instruments(index, hdr, inst) or not inst.speed then
        clear_record(record); brake = nil; hist('braking stopped: speed unreadable'); return
    end
    local t = S.time - b.t0
    if not b.dir then
        b.dir, b.v0 = (inst.gear == -1) and 1 or -1, inst.speed
        if TESTER then itrace(string.format('braking: speed %.2f, gear %s', inst.speed, tostring(inst.gear))) end
    end
    if TESTER and S.frames % 10 == 0 then itrace(string.format('braking: %.1f s, speed %.2f, gear %s', t, inst.speed, tostring(inst.gear))) end
    if inst.speed <= max(BRAKE.stop_min, b.v0 * BRAKE.stop_ratio) or t > BRAKE.max_time then
        clear_record(record); brake = nil
        if b.v0 > BRAKE.stop_min then
            BRAKE.done = BRAKE.done + 1
            S.brakes = string.format('%d time(s) (last: speed %.1f down to %.1f in %.1f s)', BRAKE.done, b.v0, inst.speed, t)
            hist(string.format('braked to a stop as you got out (%.1f s)', t))
        end
        return
    end
    local f = ffi.cast(F32P, record)
    for i = 0, 5 do f[i] = 0 end
    f[6], f[7], f[8] = b.dir > 0 and 1 or 0, b.dir < 0 and 1 or 0, 0
    record[0x2C] = 1
    for o = 0x2D, 0x2F do record[o] = 0 end
    record[BRAKE.handbrake] = 1
end

local function drive_frame()
    local record, index, hdr = driver_record(drive.vehicle)   -- (on failure `index` is the reason)
    if not record then
        stop_driving('vehicle record: ' .. tostring(index))
        return false
    end
    drive.record, drive.record_mgr = record, cached.vehicles.ptr          -- (for the error handler, see the end)
    local ok, fwhy = feed(drive.me, record)
    if not ok then S.errors = S.errors + 1; S.last_error = tostring(fwhy); stop_driving(fwhy); return false end
    S.phase, S.status = 'driving', 'driving from the gunner seat'
    -- published for the driver panel (shown only while you drive from the gunner seat)
    SEAT_PUB.driving = true
    if not drive.horn_off then                  -- (2.1 review) a horn that failed once is left off for this drive
        local okh, herr = pcall(horn_frame, drive.vehicle, last.paused)
        if not okh then S.errors = S.errors + 1; S.last_error = 'horn: ' .. tostring(herr); drive.horn_off = true; horn_release() end
    end
    if (drive.kind == SMK.kind and not drive.smoke_off) then
        local oks, serr = pcall(smoke_frame, drive.me, last.paused)
        if not oks then S.errors = S.errors + 1; S.last_error = 'smoke: ' .. tostring(serr); S.smoke = 'off after an error'; drive.smoke_off = true; pcall(smoke_restore) end
    end
    if not drive.gear_at or S.frames >= drive.gear_at then          -- instruments every 4 frames
        drive.gear_at = S.frames + 4
        local inst_time = drive.inst_time
        drive.inst_time = S.time
        if (drive.kind == SMK.kind and not drive.smoke_off) and smoke.id and (S.frames >= smoke.rounds_at or S.frames >= (smoke.rounds_soon or 1e9)) then
            smoke.rounds_at, smoke.rounds_soon = S.frames + 30, nil    -- (smoke rounds left, for the panel)
            local okr, n = pcall(smoke_rounds, smoke.id)
            SEAT_PUB.smoke = okr and n or nil
            if SEAT_PUB.smoke then smoke.full[drive.vehicle] = max(smoke.full[drive.vehicle] or 0, SEAT_PUB.smoke); smoke.full_any = true end
            SEAT_PUB.smoke_full = smoke.full[drive.vehicle]
        end
        -- (1.3) another player drove this tank last (or it doesn't answer your throttle): shown on the driver panel
        SEAT_PUB.remote = last_driver[drive.vehicle] == 'other' or (drive.silent == true and not drive.answered)
        if SEAT_PUB.remote and not drive.remote_noted then
            drive.remote_noted = true
            S.control = 'another player\'s game runs this tank (they drove it last): take the driver seat once to get it back'
        end
        if read_instruments(index, hdr, SEAT_PUB) then
            if not drive.sel_check or S.frames >= drive.sel_check then drive.sel_at, drive.sel_check = selector_at(drive.vehicle), S.frames + 60 end   -- (3.0 review: a miss waits too)
            SEAT_PUB.selector = (drive.sel_at and fetch(drive.sel_at, 4) and mem_u32(0) <= 4) and mem_u32(0) or nil
            binds.learn(SEAT_PUB.selector)
            -- does the tank answer? throttle held (not in neutral) for 3 s with no revs and no speed = no
            -- (1.3) the tank answers your throttle: it is yours (another player's earlier drive no longer matters)
            local pushing = last.forward and max(last.forward, last.reverse) > 0.5 and SEAT_PUB.selector ~= 1
            if pushing and ((SEAT_PUB.rpm or 0) > 1100 or (SEAT_PUB.speed or 0) > 3) and last_driver[drive.vehicle] == 'other' then
                last_driver[drive.vehicle] = 'me'; hist('the tank answers your throttle again')
                S.control = 'yours (it answers your throttle)'; drive.remote_noted = nil
            end
            if not drive.answered then
                -- (only judged with the engine running and fuel in the tank)
                local held = last.forward and max(last.forward, last.reverse) > 0.5 and SEAT_PUB.selector ~= 1
                    and SEAT_PUB.engine == true and (SEAT_PUB.fuel == nil or SEAT_PUB.fuel > 0)
                if (SEAT_PUB.rpm or 0) > 1100 or (SEAT_PUB.speed or 0) > 3 then
                    drive.answered = true; S.response = 'yes'
                    if drive.silent then hist('the tank answers the throttle now') end
                elseif held then
                    -- (3.0.1 review) seconds of game time (3.0.0: 180 frames, 1.25 s at 144 fps)
                    drive.pushed = (drive.pushed or 0) + min(0.25, S.time - (inst_time or S.time))
                    if drive.pushed >= 3 and not drive.silent then
                        drive.silent = true
                        S.response = string.format('no: throttle held 3 s, %.0f rpm, speed figure %.0f (the tank may be run by another player\'s game)',
                            SEAT_PUB.rpm or 0, SEAT_PUB.speed or 0)
                        hist('the tank does not answer the throttle (' .. S.overwritten .. ' frames of input replaced)')
                        write_log(true)
                    end
                end
            end
        end
    end
    -- the engine: started the game's own way when you start driving, and again if it stops. After a switch-on the
    -- next look waits 5 s: the game marks the engine as started only once its start-up has run (Test 8 switched it
    -- on 3 times at every start, checking every half second). Up to 3 switch-ons in a row that don't take, then it
    -- stops trying; once the engine runs, that count starts over. (3.0.1 review) The 5 s are game time (engine_hold;
    -- 3.0.0: 300 frames, 2.1 s at 144 fps, so a slow start-up could be switched on again).
    if (not drive.engine_check or S.frames >= drive.engine_check) and S.time >= (drive.engine_hold or 0) then
        drive.engine_check = S.frames + 30
        local started = engine_started(index, hdr)
        SEAT_PUB.engine = started
        if started then drive.engine_tries = 0 end
        if started == false and (drive.engine_tries or 0) < 3 then
            drive.engine_tries = (drive.engine_tries or 0) + 1
            local okc, ok, why = pcall(engine_switch, drive.vehicle, true)
            if okc and ok then
                drive.engine_on = true; S.engine_starts = S.engine_starts + 1
                drive.engine_hold = S.time + 5
                drive.switch_ons = (drive.switch_ons or 0) + 1
                S.engine = drive.switch_ons == 1 and 'started by Gunner Drive' or ('started again (' .. drive.switch_ons .. ' switch-ons this drive)')
                if drive.switch_ons > 1 then hist('engine had stopped: switched on again') end
            else
                S.engine = 'not started: ' .. tostring(okc and why or ok)
                if not okc then S.errors = S.errors + 1; S.last_error = 'engine switch: ' .. tostring(ok) end
                drive.engine_tries = 3
            end
        elseif started == nil and FEAT.engine and not drive.engine_blind then
            -- (1.2.1) the engine's state can't be read in this game version (the instruments place wasn't found): switch
            -- it on once when you set off (the switch does nothing to an engine that already runs). 1.2.0 never
            -- started it then.
            drive.engine_blind = true
            local okc, ok = pcall(engine_switch, drive.vehicle, true)
            if okc and ok then
                drive.engine_on = true; S.engine_starts = S.engine_starts + 1
                S.engine = 'switched on by Gunner Drive (its running state can\'t be read in this game version)'
            else
                S.engine = 'not started: ' .. tostring(ok)
                if not okc then S.errors = S.errors + 1; S.last_error = 'engine switch: ' .. tostring(ok) end
            end
        elseif started and not drive.engine_on and not drive.engine_seen then
            drive.engine_seen = true; S.engine = 'already running when Gunner Drive took over'
        end
    end
    return true
end

-- The seat you sit in, published for the Vehicle Indicator, Gunner Camera and driver panel (kind nil = not in a supported vehicle). Driving
-- itself only happens when the Gunner Drive option's small flag addon is installed.
local function publish(mine)
    SEAT_PUB.frame = S.frames
    -- (2.1) the FRVs too, in any seat, for the Vehicle Indicator and the driver panel (the Gunner camera and the
    -- driver panel check the kind themselves)
    if mine and (VEHICLES[mine.kind] or FRV_KINDS[mine.kind]) and mine.role ~= 0 then
        SEAT_PUB.kind, SEAT_PUB.role, SEAT_PUB.vehicle = mine.kind, mine.role, mine.vehicle
    else
        SEAT_PUB.kind, SEAT_PUB.role, SEAT_PUB.vehicle, SEAT_PUB.health = nil, 0, 0, nil
        local tt = SEAT_PUB.tires; if tt then tt[1], tt[2], tt[3], tt[4] = nil, nil, nil, nil end   -- (2.1 review)
        clear_drive_pub()
    end
end

-- ------------------------------------------------------------------------------------------ autoloader (2.1)
-- The Autoloader option: when your main gun's magazine runs dry in a tank's gunner seat, the reload starts by itself,
-- the game's own way (the function the reload key calls, see SITES.reload), so it takes the game's normal time and
-- your perks still count. Only an empty magazine is reloaded; a part-used one is left as it is.
-- Your main gun: slot 0 of your trigger record (trigger table: map +0x30, 0x1D0-byte records at +0x60, five 0x50-byte
-- slots, weapon at +0). Rounds: u32 at [ammo table +0x48] + index x 16 (map +0x20). The reload table (map +0x20) must
-- hold the gun and you must be its operator ([operators +0x38] + index x 4, map +0x18), all read fresh in the frame
-- of the call: the game's code doesn't check them itself and closes the game on a weapon it no longer has.
-- (3.0.1: a Maelstrom locked up in a test match with 3.0.0 - magazine empty, spare magazines on the HUD, and neither
-- the Autoloader's starts nor the R key reloaded it again.) The first start used to come in the very frame the
-- magazine ran dry, while the gun was still firing (and the game or the R key may start one in that frame too), with
-- two quick repeats 0.75 s apart. Now:
-- * the first start waits AUTO.settle seconds after the magazine runs dry (by then a reload you or the game began has
--   cleared the gun's can-reload flag, and the trigger is let go);
-- * a start is only asked while the gun's reload record says it can reload (byte +0x14 bit 0: the same flag the
--   game's own can-reload check reads, game.dll+0x775580), so it never lands on a reload that is running;
-- * after a start, the next one waits AUTO.retry seconds, longer than any tank reload takes (2.1.0 Test 1: Maelstrom
--   5.9 s, Bastion 4.8-5.0 s; perks only shorten them), for as long as the magazine stays empty (a start the game
--   turns down, e.g. no magazines left, costs nothing, and a resupply is then picked up by itself).
-- The Tester log writes the reload record's first 0x18 bytes at each step, to see what a lock-up looks like.
-- It checks every AUTO.every frames, on its own clock, and keeps your gun's id between checks (read again every
-- AUTO.gun_every frames or when the seat changes): the gun is checked fresh against the reload table and its
-- operator anyway before every reload start.
-- (2.1 review) the autoloader, scoped
local auto, autoloader_wanted, autoload
do
-- (3.0.1 review) retry, settle and flag_wait in seconds of game time (S.time; 3.0.0 counted frames, as if at 60 fps);
-- every and gun_every are poll cadences, in frames
local AUTO = {retry = 8, settle = 1, flag_wait = 0.5, every = 6, gun_every = 60}
auto = {gun = nil, seat = nil, gun_at = 0, next_check = 0, tries = 0, next_try = 0, empty_at = nil, memo = {}, rmemo = {}, omemo = {}, tmemo = {}}
S.autoloader, S.reloads = 'off (option not installed)', 0
autoloader_wanted = function() return rawget(_G, 'ArmoredOverhaulAutoloaderOn') == true and menu_opts.autoloader ~= false end
local table_hdr = mgr_hdr          -- (3.1.1 review: one helper; it was written twice)
local reload_start
autoload = function(mine, me)
    local F = FEAT.reload
    if not F then S.autoloader = 'not available in this game version'; return end
    if mine.role ~= GUNNER or not me then
        auto.gun = nil; S.autoloader = 'ready (not in the gunner seat)'; return
    end
    if S.frames < auto.next_check then return end
    auto.next_check = S.frames + AUTO.every
    local gun = auto.gun
    if not gun or auto.seat ~= mine.vehicle or S.frames >= auto.gun_at then
        local th = table_hdr(F.trigger, 0x70)
        local ti = th and map_get(th, 0x30, me.entity, auto.tmemo)
        local recs = th and str_ptr(th, 0x60)
        gun = ti and recs and fetch_u32(recs + ti * 0x1D0)
        if not gun or gun == 0 or gun == invalid_entity() then auto.gun = nil; S.autoloader = 'waiting (no gun in your hands yet)'; return end
        if gun ~= auto.gun or auto.seat ~= mine.vehicle then auto.gun, auto.tries, auto.next_try, auto.empty_at = gun, 0, 0, nil end
        auto.seat, auto.gun_at = mine.vehicle, S.frames + AUTO.gun_every
    end
    local ah = table_hdr(F.ammo, 0x50)
    local ai = ah and map_get(ah, 0x20, gun, auto.memo)
    local arr = ah and str_ptr(ah, 0x48)
    local rounds = ai and arr and fetch_u32(arr + ai * 16)
    if not rounds or rounds > 100000 then S.autoloader = 'waiting (the magazine is unreadable)'; return end
    if rounds > 0 then
        if auto.empty_at then
            if TESTER then atrace(string.format('magazine full again: %d rounds, %.1f s after it ran dry (%d start(s) asked)', rounds,
                S.time - auto.empty_at, auto.tries)) end
            auto.empty_at = nil
        end
        auto.tries, auto.next_try = 0, 0; S.autoloader = 'ready'; return
    end
    if not auto.empty_at then
        auto.empty_at, auto.can = S.time, nil
        if TESTER then atrace(string.format('magazine empty (gun %08x)', gun)) end
    end
    if S.time - auto.empty_at < AUTO.settle then S.autoloader = 'waiting (the magazine just ran dry)'; return end
    if S.time < auto.next_try then
        if auto.tries > 0 then S.autoloader = 'waiting (asked ' .. auto.tries .. ' time(s); the game turned it down or it is reloading)' end
        return
    end
    -- the gun in the reload table and you its operator, read now (see above)
    local rh, R = table_hdr(F.mgr, 0x40)
    -- (2.1 review) the game's reload start reads the gun's record through [table +0x38] + index x 8 without a check:
    -- it is checked here first
    local ri = rh and map_get(rh, 0x20, gun, auto.rmemo)
    local rarr = ri and str_ptr(rh, 0x38)
    local rp = ri and rarr and fetch_ptr(rarr + ri * 8)
    if not rp or not fetch(rp, 0x18) then S.autoloader = 'waiting (the gun is not in the reload table)'; return end   -- (3.0 review: the record too)
    local can = mem[0x14] % 2 == 1
    if TESTER and can ~= auto.can then
        auto.can = can
        local b = {}
        for i = 0, 0x17 do b[#b + 1] = string.format('%02x', mem[i]) end
        atrace(string.format('reload record %s (%s)', table.concat(b), can and 'can reload' or 'can not reload'))
    end
    if not can then
        auto.next_try = S.time + AUTO.flag_wait
        S.autoloader = 'waiting (the game says the gun can not reload right now)'
        return
    end
    local oh = table_hdr(F.oper, 0x40)
    local oi = oh and map_get(oh, 0x18, gun, auto.omemo)
    local oarr = oh and str_ptr(oh, 0x38)
    local op = oi and oarr and fetch_u32(oarr + oi * 4)
    if op ~= me.entity then S.autoloader = 'waiting (someone else operates the gun)'; return end
    if not reload_start then reload_start = ffi.cast('void (*)(void *, uint32_t, uint8_t)', F.fn) end
    auto.tries = auto.tries + 1
    auto.next_try = S.time + AUTO.retry
    reload_start(R, gun, 0)
    if auto.tries == 1 then S.reloads = S.reloads + 1 end
    S.autoloader = auto.tries == 1 and 'reload started' or ('reload asked again (' .. auto.tries .. ' times: the magazine stayed empty)')
    if TESTER then atrace(string.format('reload start asked (try %d, %.1f s after it ran dry)', auto.tries, S.time - auto.empty_at)) end
end

end
-- (1.3) The vehicle's health as a share of its maximum (0..1), for the Vehicle Indicator's outline color: read the
-- way the game's own driver HUD reads it (see SITES.health), every 15 frames while you sit in a supported vehicle.
-- (2.1) The FRV's tires come from the same read of its health record (2.1 review: they were a second look-up): one
-- health int per damageable part from +0xF8; the first four are the tires (front left, front right, rear left, rear
-- right, 350 each on the M-102 and M-103), and the byte at +0x20 has a bit per part (2k+1 for part k) the game sets when
-- the part is destroyed. Found in 2.1.0 Test 12 by shooting the tires out one at a time. Published as shares of full
-- health, -1 for a popped tire.
S.health, S.tires = 'not read yet', 'not read yet'
SEAT_PUB.tires = {nil, nil, nil, nil}
local health_at, health_for = 0, nil
local function clear_tires() local t = SEAT_PUB.tires; t[1], t[2], t[3], t[4] = nil, nil, nil, nil end
local read_tires, publish_health
do
    local health_memo = {}
    local TIRES = {at = 0xF8, flags = 0x20, full = 350, size = 0x108}
    local tire_top = {}
    local function signed(v) return v >= 0x80000000 and v - TWO32 or v end
    -- the vehicle's records in the health table: current (0x1B8 bytes) and maximum (0x1C), or nil and why
    local function records(vehicle)
        if not FEAT.health then return nil, 'not available in this game version' end
        local M = fetch_ptr(FEAT.health)
        local h = M and fetch_str(M + 0x1030, 0x38)
        if not h then return nil, 'health table unreadable' end
        local idx = map_get(h, 0, vehicle, health_memo)
        if not idx then return nil, 'vehicle not in the health table' end
        local cur_at, max_at = str_ptr(h, 0x28), str_ptr(h, 0x30)
        if not cur_at or not max_at then return nil, 'health unreadable' end
        return cur_at + idx * 0x1B8, max_at + idx * 0x1C
    end
    local function raw_parts()
        return string.format('%d %d %d %d, flags %02x', signed(mem_u32(TIRES.at)), signed(mem_u32(TIRES.at + 4)),
            signed(mem_u32(TIRES.at + 8)), signed(mem_u32(TIRES.at + 12)), mem[TIRES.flags])
    end
    -- the tires from the record now in `mem` (fetched with TIRES.size bytes)
    local function parse_tires(vehicle)
        local t, flags = SEAT_PUB.tires, mem[TIRES.flags]
        if tire_top.vehicle ~= vehicle then tire_top = {vehicle = vehicle} end
        for k = 0, 3 do
            local v = signed(mem_u32(TIRES.at + 4 * k))
            if v < 0 or v > 100000 then t[k + 1] = nil
            elseif v == 0 or floor(flags / 2 ^ (2 * k + 1)) % 2 == 1 then t[k + 1] = -1
            else
                tire_top[k] = max(tire_top[k] or TIRES.full, v)
                t[k + 1] = v / tire_top[k]
            end
        end
        if TESTER then S.tires = raw_parts() end
    end
    -- another vehicle's parts, raw, for the log (vehicles the mod doesn't support yet)
    read_tires = function(vehicle)
        local rec = records(vehicle)
        return rec and fetch(rec, TIRES.size) and raw_parts() or nil
    end
    local function read_health(vehicle, tires)
        local rec, top_at = records(vehicle)
        if not rec then return nil, top_at end
        if not fetch(rec, tires and TIRES.size or 0x18) then return nil, 'health unreadable' end
        local cur = signed(mem_u32(0x14))
        if tires then parse_tires(vehicle) end
        local top = fetch_u32(top_at + 0x14)
        if not top then return nil, 'health unreadable' end
        top = signed(top)
        if top <= 0 or top > 10000000 or cur < 0 or cur > top * 4 then return nil, string.format('odd health values (%d / %d)', cur, top) end
        return min(1, cur / top), cur, top
    end
    publish_health = function(mine)
        -- (2.0) read at once when you sit in another vehicle (Test 8 waited out the 15 frames: a grey outline meanwhile)
        if S.frames < health_at and mine.vehicle == health_for then return end
        health_at, health_for = S.frames + 15, mine.vehicle
        local frv = FRV_KINDS[mine.kind] ~= nil
        if not frv then clear_tires() end
        local ok, share, cur, top = pcall(read_health, mine.vehicle, frv)
        if ok and share then
            SEAT_PUB.health = share
            S.health = string.format('%d / %d (%.0f%%)', cur, top, share * 100)
        else
            SEAT_PUB.health = nil
            S.health = ok and tostring(cur) or ('failed: ' .. tostring(share))
            if frv then clear_tires() end
        end
    end
end
local kinds = {seen = {}, others = {}}     -- (2.1) the vehicle kinds logged (see poll)
S.kinds, S.kinds_others = 'none yet', 'none yet'

local next_poll = 0
local font_next
-- (1.3) Who sat in each tank's driver seat last. In multiplayer the driver's game runs the tank, and keeps running it
-- after the driver gets out (seen in testing: a host drove and got out; from then on the gunner seat's keys
-- reached the tank's controls but the tank sat at idle; taking the driver seat once, then the gunner seat again, made
-- Gunner Drive work). So when another player drove last, the driver panel says so, until you take the driver seat or
-- the tank answers your throttle.
-- (3.0 review: made once, not a new closure every poll)
local function note_driver(v, who)
    if v == 0 or last_driver[v] == who then return end
    if last_driver[v] == nil then
        last_driver_n = last_driver_n + 1
        if last_driver_n > 32 then last_driver, last_driver_n = {}, 1 end
    end
    last_driver[v] = who
    if who == 'other' and v == shown_seat.vehicle then
        hist(string.format('another player took the driver seat (vehicle 0x%08X)', v))
        S.control = 'another player drove your tank last'
    elseif who == 'me' and v == shown_seat.vehicle then S.control = 'yours (you drove it last)' end
end
local function note_drivers(seats)
    for _, o in ipairs(seats.others or {}) do if DRIVER_ROLES[o.role] then note_driver(o.vehicle, 'other') end end
    local m = seats.mine
    if m and DRIVER_ROLES[m.role] then note_driver(m.vehicle, 'me') end
end

local function poll()
    S.polls = S.polls + 1
    local flags = (tank_drive_on() and 1 or 0) + (frv_drive_on() and 2 or 0)      -- (2.1 review) text only on a change
    if flags ~= S.gd_flags then
        S.gd_flags = flags
        S.gunner_drive = (flags % 2 == 1 and 'tanks on' or 'tanks off') .. ', ' .. (flags >= 2 and 'FRV on' or 'FRV off')
            .. (flags > 0 and '' or ' (seat reader for the Vehicle Indicator only)')
    end
    -- (3.0.1 review) the Autoloader switched off in the Mod Options Menu is said so in the log (autoload isn't called
    -- then, and 3.0.0 kept showing its last state, 'ready' or 'reload started')
    local auto_off = menu_opts.autoloader == false
    if auto_off then S.autoloader = 'off (Mod Options Menu)'
    elseif S.autoloader == 'off (Mod Options Menu)' then S.autoloader = FEAT.reload and 'ready' or 'not available in this game version' end
    local seats, why = read_seats()
    -- (only with you found: without it, your own row would be among the others)
    if seats and seats.me then note_drivers(seats) end
    if not seats then
        -- (3.1.1 review) out of the mission only once the seat table has been gone for 0.25 s: a read that fails for a
        -- frame or two mid-mission changes nothing - the drive goes on (it checks its vehicle every frame itself), as do a
        -- brake under way, a pending engine switch-off and what is remembered per tank, and the seat stays published.
        -- 3.1.0 stopped the drive and switched the engine off, and dropped a brake with the controls left held.
        S.no_seats_at = S.no_seats_at or S.time
        local gone = S.time - S.no_seats_at >= 0.25
        if not gone then
            if SEAT_PUB.kind then SEAT_PUB.frame = S.frames end
            next_poll = S.frames + TUNING.idle_every
            return
        end
        publish(nil); health_for = nil
        stop_driving(why); settle = nil
        do
            cancel_brake(); pending_off = nil; tries = nil      -- (3.0 review: tank ids are reused next mission)
            -- (2.0.1 review) no seat table: out of the mission. Tank ids are reused by the next one, so what was
            -- remembered per tank (who drove it last, its full smoke count) goes.
            if last_driver_n > 0 then last_driver, last_driver_n = {}, 0 end
            if smoke.full_any then smoke.full, smoke.full_any = {}, false end
            -- (3.0.1 review) the Autoloader's gun and empty magazine too: the next mission's tank and gun can carry the same
            -- ids, and 3.0.0 then took its old empty-magazine time and start count (no wait, or none for up to 8 s)
            auto.gun, auto.seat, auto.empty_at, auto.tries, auto.next_try, auto.next_check = nil, nil, nil, 0, 0, 0
        end
        S.phase, S.verdict = 'waiting', why
        next_poll = S.frames + TUNING.menu_every
        return
    end
    S.no_seats_at = nil
    if not seats.anyone or not seats.mine then
        publish(nil); health_for = nil
        if brake and seats.others then        -- (3.0.1) someone took the driver seat of the tank being braked
            for _, o in ipairs(seats.others) do if o.vehicle == brake.vehicle and DRIVER_ROLES[o.role] then cancel_brake('a driver took the seat'); break end end
        end
        if auto.gun then auto.gun, auto.next_check = nil, 0; S.autoloader = (FEAT.reload and not auto_off) and 'ready (not in the gunner seat)' or S.autoloader end
        stop_driving('left the seat'); settle = nil
        settle_engine(nil, 'not_seated', seats.others)
        S.phase, S.verdict = 'watching', seats.anyone and 'not_seated' or 'nobody_in_vehicles'
        next_poll = S.frames + TUNING.idle_every
        return
    end
    local mine = seats.mine
    publish(mine)
    -- (2.1) the vehicle kinds you sat in, once each, with the parts of one the mod doesn't support yet (2.1 review: they
    -- were read every poll); test builds also read every vehicle's seats (see watched) and log other players' kinds
    if mine.role ~= 0 and not kinds.seen[mine.kind] then
        kinds.seen[mine.kind] = true
        local name, parts = DRIVEN[mine.kind] or FRV_KINDS[mine.kind], ''
        if not name then local okr, raw = pcall(read_tires, mine.vehicle); parts = ', parts ' .. (okr and tostring(raw) or 'unreadable') end
        S.kinds = (S.kinds == 'none yet' and '' or (S.kinds .. ', ')) .. string.format('0x%X (%s%s)', mine.kind, name or 'not supported yet', parts)
    end
    if TESTER then for _, o in ipairs(seats.others) do
        if o.role ~= 0 and o.kind and not kinds.seen[o.kind] and not kinds.others[o.kind] then
            kinds.others[o.kind] = true
            local okr, raw = pcall(read_tires, o.vehicle)
            S.kinds_others = (S.kinds_others == 'none yet' and '' or (S.kinds_others .. '; ')) .. string.format('0x%X (%s, parts %s)',
                o.kind, DRIVEN[o.kind] or FRV_KINDS[o.kind] or 'not supported yet', okr and tostring(raw) or 'unreadable')
        end
    end end
    if SEAT_PUB.kind and mine.role ~= 0 then publish_health(mine) else SEAT_PUB.health = nil; clear_tires() end   -- (2.1) the FRV too
    if autoloader_wanted() and VEHICLES[mine.kind] and (mine.role ~= GUNNER or S.frames >= auto.next_check) then
        local oka, aerr = pcall(autoload, mine, seats.me)
        if not oka then S.errors = S.errors + 1; S.last_error = 'autoloader: ' .. tostring(aerr); S.autoloader = 'error (see last error)' end
    end
    if not FONT_PUB.font and S.frames >= (font_next or 0) then font_next = S.frames + 120; read_font() end
    if shown_seat.index ~= mine.index or shown_seat.kind ~= mine.kind or shown_seat.role ~= mine.role
        or shown_seat.vehicle ~= mine.vehicle then
        shown_seat.index, shown_seat.kind, shown_seat.role, shown_seat.vehicle = mine.index, mine.kind, mine.role, mine.vehicle
        local role = mine.role == GUNNER and 'gunner seat' or (DRIVER_ROLES[mine.role] and 'driver seat' or ('seat role ' .. mine.role))
        S.seat = string.format('%s, %s (row %d)', DRIVEN[mine.kind] or FRV_KINDS[mine.kind] or string.format('vehicle kind 0x%X', mine.kind), role, mine.index)
        S.vehicle = string.format('0x%08X', mine.vehicle)
    end
    if TESTER and DRIVER_ROLES[mine.role] and mine.kind == SMK.kind then pcall(smoke.driver_note, mine, seats.me) end   -- (3.1.1 Test 2)
    if TESTER and DRIVER_ROLES[mine.role] and DRIVEN[mine.kind] then          -- (tester, 3.0) see input_note
        local okr, rec = pcall(driver_record, mine.vehicle)
        if okr and rec then pcall(input_note, 'driver seat (the game)', ffi.cast(F32P, rec)) end
    end
    if not drive_wanted(mine.kind) then                      -- seat reader only (Vehicle Indicator without Gunner Drive)
        stop_driving(mine.kind == FRV_KIND and 'FRV Gunner Drive option off' or 'Tank Gunner Drive option off'); settle = nil
        -- (3.0.1 review) a switch-off left pending by a seat move is settled here too (Gunner Drive turned Off in the Mod
        -- Options Menu during the move left the engine idling); with the option off nobody drives from the gunner seat
        if pending_off then
            local v = seat_verdict(mine, seats.others)
            settle_engine(mine, v == 'drive' and 'option_off' or v, seats.others)
        end
        S.phase, S.verdict = 'watching', 'seat reader only'
        next_poll = S.frames + TUNING.idle_every
        return
    end
    local verdict = seat_verdict(mine, seats.others)
    if brake then                               -- (3.0.1) a driver now, or you drive it again: braking ends
        if verdict == 'drive' and mine.vehicle == brake.vehicle then brake = nil      -- (you drive it again: your keys fill it)
        else for _, o in ipairs(seats.others) do if o.vehicle == brake.vehicle and DRIVER_ROLES[o.role] then cancel_brake('a driver took the seat'); break end end end
    end
    settle_engine(mine, verdict, seats.others)
    if verdict ~= S.verdict then
        if verdict == 'has_driver' then
            local who = '?'
            for _, o in ipairs(seats.others) do if o.vehicle == mine.vehicle and DRIVER_ROLES[o.role] then who = string.format('row %d, role %d', o.index, o.role) end end
            hist('someone took the driver seat (' .. who .. ')')
        elseif S.verdict == 'has_driver' then
            hist('driver seat free again (now: ' .. verdict .. ')')
        end
    end
    S.verdict = verdict
    if verdict ~= 'drive' then
        stop_driving((verdict == 'other_seat' and DRIVER_ROLES[mine.role]) and 'you took the driver seat' or verdict); settle = nil
        -- (3.0.1 review) a seat move is followed closely, but not every frame (3.0.0 read the seat table every frame
        -- of the get-in and get-out animations)
        if verdict == 'moving_seat' then next_poll = S.frames + TUNING.settle_every; return end
        next_poll = S.frames + TUNING.idle_every
        return
    end
    -- Only a different tank ends the drive; the game rebuilding its seat list (same tank, same seat) does not.
    -- (3.0.1 review) The drive and a settling seat are known by the vehicle, not by the row: the game keeps the seat
    -- rows packed, so a teammate leaving a vehicle moves your row, and 3.0.0 then stopped the drive ('seat changed'),
    -- switching the engine off and on again. The verdict already says you are its gunner (one gunner seat each).
    if drive and drive.vehicle ~= mine.vehicle then
        stop_driving('seat changed')
    end
    -- (3.1.1 review) a vehicle whose first driving frame failed 3 times is tried again every 5 s; in between the seat is
    -- still read and published every few frames (3.1.0 paused the whole seat reader for 300 frames: the Vehicle
    -- Indicator, Gunner Camera and driver panel let go of the seat after 45 and were off most of that time)
    if tries and tries.vehicle == mine.vehicle and tries.n >= 3 and S.time < (tries.retry_at or 0) and not (drive and drive.counted) then
        if drive then stop_driving('driving retried every 5 s') end
        settle = nil
        S.phase = 'watching'
        next_poll = S.frames + TUNING.idle_every
        return
    end
    if not drive then
        if not settle or settle.vehicle ~= mine.vehicle then
            settle = {vehicle = mine.vehicle, n = 0}
        end
        settle.n = settle.n + 1
        -- (3.0.1 review) the polls counted are settle_every frames apart (3.0.0: two frames in a row)
        if settle.n < TUNING.settle_polls then S.phase = 'settling'; next_poll = S.frames + TUNING.settle_every; return end
        drive = {vehicle = mine.vehicle, kind = mine.kind}
        settle = nil
    end
    drive.me = seats.me
    local fresh = not drive.counted
    if drive_frame() then
        -- (2.0.1 review) a drive is counted and logged once its first frame worked: 2.0.0 counted every try, so a tank
        -- whose controls couldn't be read started and stopped about twice a second, rewriting the log each time
        if fresh then
            drive.counted = true; tries = nil
            hist(string.format('started driving (%s, vehicle 0x%08X)', DRIVEN[mine.kind] or 'vehicle', mine.vehicle))
            S.sessions = S.sessions + 1
            write_log(true)
        end
        next_poll = S.frames + TUNING.drive_seat_every     -- keys every frame, seat table every few frames
    else
        -- vehicle going away: don't retry every frame; a tank that keeps failing is tried every 5 s
        if fresh then
            if not tries or tries.vehicle ~= mine.vehicle then tries = {vehicle = mine.vehicle, n = 0} end
            tries.n = tries.n + 1
            if tries.n >= 3 then tries.retry_at = S.time + 5 end
        end
        -- (3.1.1 review) never longer than the seat stays valid for the other options (they let go after 45 frames)
        next_poll = S.frames + ((tries and tries.n >= 3) and TUNING.idle_every or TUNING.menu_every)
    end
end

-- ------------------------------------------------------------------------------------------ start-up
local function start()
    local m = GetModuleHandleA('game.dll')
    if m == nil then return false end
    game = ffi.cast(BYTEP, m)
    local dos = fetch_str(game, 0x40)
    local pe = dos and le32(dos, 0x3C)
    local hdr = pe and fetch_str(game + pe, 0x60)
    if not hdr or hdr:sub(1, 4) ~= 'PE\0\0' then S.status = 'game.dll header unreadable'; return nil end
    local stamp
    stamp, image_size = le32(hdr, 8), le32(hdr, 0x50)
    local tag = string.format('%08X-%X', stamp, image_size)
    S.game = tag
    if stamp == KNOWN_BUILD.timestamp and KNOWN_BUILD.sizes[image_size] then
        local rvas = {}
        for _, n in ipairs(ALL_ORDER) do rvas[n] = SITES[n].rva end
        local found = resolve_globals(rvas)
        if found then bind(found); resolve_extras(rvas); S.locate = 'known build'; S.known_build = true; return true end
    end
    local saved = cache_load(tag)
    local found = saved and resolve_globals(saved)
    if found then bind(found); resolve_extras(saved); S.locate = 'saved from an earlier search'; return true end
    S.locate = 'searching the game code (new game version)'
    S.search_tag = tag
    return 'search'
end

local phase = 'start'
local function tick()
    S.frames = S.frames + 1
    -- (3.0.1 review) the game time: the frame time the game passes to update (S.dt), else the C runtime's clock (wall
    -- time on Windows), else 1/60 s a frame. The waits in frames assumed 60 fps: at 144 fps the Autoloader's 1 s wait
    -- was 0.42 s and its 8 s between starts 3.3 s, shorter than the Maelstrom's reload.
    local dt = S.dt
    if type(dt) ~= 'number' or dt <= 0 or dt >= 1 then
        local okc, c = false, nil
        if type(os) == 'table' and type(os.clock) == 'function' then okc, c = pcall(os.clock) end
        if not okc or type(c) ~= 'number' then c = nil end
        dt = c and S.clock_at and c - S.clock_at
        S.clock_at = c
        if not dt or dt <= 0 or dt >= 1 then dt = 1 / 60 end
    end
    S.time = S.time + dt
    menu_link(S.frames)
    binds.link(S.frames)
    if phase == 'start' then
        -- (3.0.1 review) game.dll not loaded yet: looked for once a second, and the log written once for it (3.0.0
        -- looked and rewrote the log every frame)
        if S.frames >= (S.start_at or 0) then
            S.start_at = S.frames + 60
            local r = start()
            if r == true then phase = 'run'; S.phase = 'watching'; S.status = 'ready'
            elseif r == 'search' then phase = 'search'
            elseif r == nil then phase = 'off'; S.phase = 'off'
            else S.status = 'waiting for game.dll' end
            if r ~= false then write_log(true) end
        end
    elseif phase == 'search' then
        if search_step() then
            local picked, counts = {}, {}
            for _, n in ipairs(ALL_ORDER) do
                counts[#counts + 1] = n .. '=' .. #search.hits[n]
                if #search.hits[n] == 1 then picked[n] = search.hits[n][1] end
            end
            local found, why = resolve_globals(picked)
            if found then
                bind(found)
                local ok = resolve_extras(picked)
                for _, n in ipairs(EXTRA_ORDER) do if not ok[n] then picked[n] = nil end end
                cache_save(S.search_tag, picked)
                phase = 'run'; S.phase = 'watching'; S.status = 'ready'; S.locate = 'found by search (' .. table.concat(counts, ' ') .. ')'
            else
                phase = 'off'; S.phase = 'off'; publish(nil)
                S.status = 'not active: could not find ' .. tostring(why) .. ' after the game update'
                S.locate = 'search failed (' .. table.concat(counts, ' ') .. ')'
            end
            write_log(true)
        end
    elseif phase == 'run' then
        if brake then
            local okb, berr = pcall(brake_frame)
            if not okb then S.errors = S.errors + 1; S.last_error = 'braking: ' .. tostring(berr); pcall(cancel_brake, 'an error') end
        end
        if S.frames >= next_poll then poll()
        elseif drive and (not drive_wanted(drive.kind) or not drive_frame()) then
            if drive then stop_driving(drive.kind == FRV_KIND and 'FRV Gunner Drive option off' or 'Tank Gunner Drive option off') end
            next_poll = S.frames + TUNING.menu_every
        end
    end
    write_log(S.frames % TUNING.report_every == 0)
end

local game_update, game_shutdown = update, shutdown
if type(game_update) ~= 'function' then return end
local broken = false
local function after_game(ok, ...)
    if not ok then error((...), 0) end
    if not broken then
        local fine, err = pcall(tick)
        if not fine then
            broken = true; S.errors = S.errors + 1; S.last_error = tostring(err)
            -- never leave keys held: if stopping failed too, the record is looked up again (never the one kept from
            -- an earlier frame, which may belong to a tank the game has taken apart)
            if not pcall(stop_driving, 'error') and drive then
                pcall(horn_release)
                pcall(smoke_restore)                -- (3.0 review) the smoke launcher's operator and your slot too
                local okr, rec = pcall(driver_record, drive.vehicle)
                if not okr then
                    -- (3.0.1 review) a look-up that threw gives its error text, never a record (3.0.0 cast that text
                    -- to a pointer and zeroed it)
                    rec = nil
                    -- (the look-up itself failed: the record kept from the last good frame is used only while the
                    -- game's vehicle table is still the one it came from, and (3.0.1 review) only when its page passes
                    -- a fresh check now: 3.0.0 wrote to it with no page check in this frame)
                    local okm, m = pcall(fetch_ptr, G.vehicles)
                    local old = drive.record
                    if old and okm and m ~= nil and m == drive.record_mgr then   -- (pointers compare by address)
                        local okp, plain = pcall(data_pages, old, VEH.stride, true)
                        if okp and plain == true then rec = old end
                    end
                end
                if rec then pcall(clear_record, rec) end
            end
            pcall(cancel_brake)                     -- (3.1.1 review: a vehicle being braked is let go of cleanly too)
            drive = nil; publish(nil)
            S.phase, S.status = 'off', 'stopped after an error: ' .. tostring(err)
            write_log(true)
        end
    end
    return ...
end
update = function(...) S.dt = ...; return after_game(pcall(game_update, ...)) end   -- (3.0.1 review) dt: see tick
shutdown = function(...)
    pcall(stop_driving, 'game closing'); publish(nil)
    S.phase = 'off'
    write_log(true)
    if game_shutdown then return game_shutdown(...) end
end
write_log(true)

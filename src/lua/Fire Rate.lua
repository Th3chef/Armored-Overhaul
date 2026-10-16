-- HD2-Addon: mods/chef/armored_overhaul_maelstrom_fire_rate
-- Armored Overhaul: the Maelstrom Fire Rate option (the hold-reload fire-rate choice). Tells the Maelstrom weapons addon (armored_overhaul_maelstrom_weapons) what to set.
do local p = rawget(_G, 'ArmoredOverhaulMaelstromPicks'); if type(p) ~= 'table' then p = {}; rawset(_G, 'ArmoredOverhaulMaelstromPicks', p) end; p.rpm = true end

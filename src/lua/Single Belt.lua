-- HD2-Addon: mods/chef/armored_overhaul_maelstrom_single_belt
-- Armored Overhaul: the Maelstrom Single Belt option. Tells the Maelstrom weapons addon (armored_overhaul_maelstrom_weapons) what to set.
do local p = rawget(_G, 'ArmoredOverhaulMaelstromPicks'); if type(p) ~= 'table' then p = {}; rawset(_G, 'ArmoredOverhaulMaelstromPicks', p) end; p.belt = true end

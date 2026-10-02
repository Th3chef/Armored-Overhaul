-- HD2-Addon: mods/chef/armored_overhaul_turret_elevation
-- Armored Overhaul: turret option flag (read by the turret core, mods/chef/armored_overhaul_mbt_turrets)
local o = rawget(_G, 'ArmoredOverhaulTurretOptions')
if type(o) ~= 'table' then o = {}; rawset(_G, 'ArmoredOverhaulTurretOptions', o) end
o.elevation = 1.25

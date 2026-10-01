# Changelog

## 2.0.1

Fixes: with MBT Turrets on, a Maelstrom wearing a camo no longer loses its hull (only the turret showed; most likely also the multiplayer report of another player's Maelstrom showing only its turret). Using Return to Ship from the pause menu while driving from the gunner seat no longer closes the game.

## 2.0.0

New options: Tank power (Strong, Stronger or Strongest), Turret traverse and Turret elevation (Quick, Fast or Very fast), Turret aim range (Wider or Widest) and FRV stability for the M-102 FRV, M-103 Supply FRV and M-104 incendiary FRV (Mild, Stable or Planted). Every choice has its own icon in the mod manager, and the options are grouped. Turret indicator: the Helldivers skull is the turret, the outline is drawn thick and colored by the tank's health, and it sits next to the driver panel. Gunner Drive: in the Maelstrom, Mouse 3 (left stick click on a controller) pops the smoke screen from the gunner seat, and the driver panel shows the smoke rounds left and says when another player controls the tank in multiplayer. The driver panel is part of Gunner Drive (it works with the Turret indicator off, with its own settings file) and its speed is measured from how fast the tank really moves. Getting out of the gunner seat always switches the engine off when nobody drives. Gunner camera: stays level on steep slopes, works when another mod changed the game's gunner camera settings, and every preset sits lower and further behind the tank.

## 1.2.1

Fixes: the driver panel now shows whenever you drive from the gunner seat, even if the Turret indicator can't find the turret (it could stay hidden without MBT Turrets). The Bastion's turret outline no longer risks following the Bastion's invisible second gun. Gunner Drive still starts the engine if a game update hides the engine's state. The Turret indicator no longer stops on setups where the game's input devices can't be read, and its controller check is lighter.

## 1.2.0

New option: Gunner camera (Close, Far, Farther or Farthest), which also keeps the camera behind the turret as it turns. Gunner Drive now starts the engine, and the Turret indicator shows a driver panel (gear selector, gear, rpm, speed and fuel, in the game's own HUD font) while you drive from the gunner seat (its keyboard gear keys are hidden on a controller). MBT Turrets: with a camo on, the Maelstrom's hull no longer disappears, and its turret now wears the camo too. Also includes the 1.1.1 fix. Clearer logs for bug reports.

## 1.1.1

Fix: on some setups Tank grip, Tank steering, MBT Turrets and Gunner Drive didn't load (the Bingus log said "missing declaration for symbol 'GetModuleHandleA'"). They now declare everything they use themselves instead of relying on another mod having done it.

## 1.1.0

New options: Tank steering (Responsive, Quick or Sharp) and Turret indicator. Tank grip is now picked in the mod manager (Moderate, Strong or Maximum) instead of a settings file. MBT Turrets: the Maelstrom's smoke launchers now turn with the turret, and the guns aim down to 6 degrees below level. Clearer logs for bug reports. The options are reordered in the mod manager.

## 1.0.0

First release.


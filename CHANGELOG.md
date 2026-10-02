# Changelog

## 3.1.0

Tank MBT Turrets rebuilt: the turrets are now the tanks' own armor, cut at the roof line and turned with the gun, so camos and battle damage show on the whole turret (the Maelstrom's turret armor and missile pods stayed plain before), the Maelstrom's own missile pods and smoke launcher turn with it, the deck and the turret's underside are closed at every angle, and the Bastion's second gun and the Maelstrom's laser designator point where the main gun does. New MBT Turrets choice: *180* (90 degrees each side, the gunner view stops with the gun); *360* stays the default. Tank Suspension fixed: 3.0.1's stiff springs made the tanks bounce, get pushed around by bodies and sometimes launch and flip, and they rode lower than the game; the springs are now close to the game's, the tanks really ride 0.1 m higher, the game's own roll handling is back, and a lower center of gravity makes them hard to tip (*Balanced* as low as the game's, *Planted* lower). Tank Turret Traverse is faster (*Quick* x1.5, *Fast* x2, *Very fast* x3 = 75 degrees a second); with MBT Turrets all the way round the turret really reaches those speeds, past the game's own limit of about 46 degrees a second, and a change in the Mod Options Menu applies at once; the gunner view turns as fast as the turret (traverse and elevation). Vehicle Indicator: in the driver's seat of any vehicle it sits where it does beside the driver panel. FRV Stability retuned: more tire grip on every preset and a new *Stable*, now the first (default) choice. The option texts say which settings apply to tanks called in after a change.

## 3.0.1

Tank Suspension reworked: *Balanced* and *Planted* replace *Firm* and *Heavy*. In the game the tanks rest on their bump stops; now each road wheel rests part-way down a longer travel and follows the ground, the hull no longer throws itself sideways or tips over when one track unloads, and the tanks ride a little higher. Gunner Drive: getting out while the vehicle rolls brakes it to a stop (getting out of a moving tank could kill you and throw you away), and with CowboyBingus's Mod Bindings Menu you can set your own keys for driving, the horn and the smoke. Tank Gunner Camera: pointing downhill, the camera follows the slope so you can see ahead (it stayed level and the hull hid the ground). Fixes: the autoloader could leave the main gun unable to reload (it now waits a moment after the magazine runs dry and only asks when the game says the gun can reload); the Maelstrom's smoke from the gunner seat wasn't found in some matches; in multiplayer, a teammate leaving a vehicle could stop and restart your Gunner Drive engine; timings now follow game time at any frame rate; options that gave up to another mod apply again when picked in the Mod Options Menu; and many smaller fixes for safety, logs and per-frame work.

## 3.0.0

New options: Tank Autoloader (the main gun reloads by itself when it runs dry, in the normal reload time) and Gunner Drive for the M-102 FRV (Gunner Drive is now one option where you pick Tanks and FRV, Tanks or FRV), with a driver panel modeled on the FRV's own. Gunner Drive: F sounds the horn; on a controller the left stick drives (forward, back, steering, turning on the spot), its click sounds the horn and the right stick click pops the Maelstrom's smoke (was the left stick click). The Turret indicator is now the Vehicle Indicator: it works in any seat of the Bastion, the Maelstrom, the M-102 FRV and the M-103 Supply FRV, and shows each FRV tire's health (clear when popped). Mod Options Menu support: the options you installed can be changed in game under MODS, ARMORED OVERHAUL. Tank Turret Aim Range gets a new Wide choice (-6 to +30); MBT Turrets no longer lowers the guns by itself. FRV Stability is retuned (more grip, weight, ground clearance and suspension travel). Options renamed with a "Tank" prefix and reordered. The Vehicle Indicator and driver panel no longer use settings files. Lighter on every frame, the controller is ignored while the game is in the background, and options step aside if another mod keeps changing the same values.

## 2.0.1

Fixes: with MBT Turrets on, a Maelstrom wearing a camo no longer loses its hull (only the turret showed; most likely also the multiplayer report of another player's Maelstrom showing only its turret). Using Return to Ship from the pause menu while driving from the gunner seat no longer closes the game. Gunner Drive, the smoke key and the driver panel are safer when a mission ends or a tank is destroyed, the driver panel does less work every frame, and game_font = 0 in its settings file now takes effect at once.

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


# Changelog

## 3.4.0

New:
- **Tank Top Speed (new option, first in the list).** More engine speed and pulling power for the Bastion and Maelstrom: a higher top speed and quicker acceleration, forward and in reverse. *Fast* x1.1, *Faster* x1.15 or *Fastest* x1.3 (the game's tanks top out at about 35 km/h on the flat). It changes the tank you are in at once, in any seat. In the Mod Options Menu (Off, Fast, Faster or Fastest) a change reaches every tank the mod has changed at once, and Off puts the tank's own engine back.
- **Tank Throttle Response (new option).** *Quick*, *Quicker* or *Instant*: the throttle and brake let go twice as fast, four times as fast or at once when you release the keys, and the pause when changing gear or between forward and reverse is half, a fifth or none. It changes the tanks at once and has a Mod Options Menu row.
- **Tank Stability (new option).** Downforce: the tank is pressed down harder the faster it goes, weighing 1.5 times (*Stable*), twice (*Steady*) or three times (*Planted*) as much at 45 km/h, so it stays on the ground over crests, ramps and bumps instead of floating. The extra grows with the speed squared: about half of it at 32 km/h, little at walking pace. It pushes through the tank's center, so it doesn't lean the hull. It changes the tank you are in at once and has a Mod Options Menu row.
- **Zoom in the FRV gunner seat and on the HMG and Anti-Tank Emplacements** (with Tank Gunner Camera). The mouse wheel (or the Zoom In / Zoom Out keys) moves the camera back when you're not aiming, and zooms on the crosshair up to x10 while aiming.

Changes:
- **Tank Power is now Tank Engine Torque**, and it changes the tank you are in at once (it used to change only tanks called in afterwards). *Strong* x1.2, *Stronger* x1.35, *Strongest* x1.5 (were x1.25, x1.5 and x2), so the tank doesn't turn into a racecar. With Tank Top Speed on too, their torque boosts multiply.
- **Tank Grip** changes the tank you are in at once (it used to change only tanks called in afterwards). *Moderate* x1.2, *Strong* x1.35, *Maximum* x1.5 (were x1.25, x1.5 and x2).
- Tank Top Speed and Tank Engine Torque never tip the hull back more than the game's own: the extra pull is balanced out.
- **Tank Steering:** its text now says it changes every tank at once (it always did).
- **Tank Suspension:** the tanks keep their full steering angle up to a slightly higher speed (the game narrows the steering above a set speed), for tighter turns when driving fast, and the hull's turning is damped so a lean builds more slowly (*Balanced* light, *Planted* firmer): fewer rollovers in fast turns. Used by tanks called in after a change.
- **Tank Turret Traverse, Elevation and Aim Range** now also change the tanks already out in the mission (not only tanks called in after), from the Mod Options Menu, at once. The gunner view's limits and look speed follow from the next time you sit in the gunner seat.
- **Tank Turret Aim Range:** the gunner view goes 20 degrees below the gun's lowest angle and 15 above its highest (never above 60), so on slopes the camera no longer stops the barrel short of its range (reported by a player: facing downhill you couldn't aim below level).
- **Maelstrom laser designator** (with MBT Turrets): aims down to 60 degrees below level and as high as the view, and is locked to its mount, so it always points where the turret faces.
- **Tank MBT Turrets models:** the turret's front arms lean inward (no inward cut-away), the double deck hatch where the old turret sat is fixed, the turret ring is cut to 2 m round the turret's axis so it doesn't clip into the taller side of the hull, and the turret shadows follow the moved and turned turret.
- **Tank Gunner Camera, smoother:** the camera circles the turret along your view instead of being turned with the turret a step at a time, so it stays smooth even at high traverse.
- **Tank Gunner Camera, farther presets,** labeled by where the camera really ends up: *Close* about 1.5 m back, *Far* about 3.5 m, *Farther* about 5 m and *Farthest* about 6.5 m. Every distance sits 1.4 m above the turret (it used to rise with the distance), and the mouse wheel goes farther out in the tank.
- **Steady zoomed view:** zoomed in on the crosshair, the view no longer shakes with the gun's recoil, and it keeps following the tank as it drives.

Fixes:
- Code review: more of the game's own values are put back when the game closes; safer after a game update (values out of range are left alone, searches are cached, less work per frame); a few rare edge cases fixed (another camera mod fighting the camera, turret settings handed to another mod, records from an earlier mission).

Known issues:
- Smoke from the gunner seat doesn't work in a tank another player called in yet.
- Tank Turret Position *Centered* moves the turret model and the gun; the tank's hit areas stay where the game has them.
- With a key set for Forward in the Mod Bindings Menu, holding W in the gunner seat may still nudge the tank a little. Please report it with your logs if you see it.
- Tank Suspension still needs the tank to be called in again after a change (it's in the tank's physics file); every other tank option changes mid-game.

## 3.3.0

New:
- **Vehicle Loadout (new option).** Pick more than one tank, exosuit or FRV in your stratagem loadout: a Bastion and a Maelstrom, or two exosuits, in the same mission. Each keeps its own cooldown and uses. Works when you host and when you join; turn it off in the Mod Options Menu to get the game's limit back at once.
- **Tank Turret Position** (Mod Options Menu, with Tank MBT Turrets). *Centered* moves the turret to the middle of the hull like a real main battle tank, so the gun reaches past the front deck and clips less when aimed low. The deck is plated where the turret used to sit. *Original*, the game's place, stays the default.
- **Your keys replace the built-in ones.** A Gunner Drive control you set a key for in the Mod Bindings Menu no longer answers its built-in key, so the two can't fight. The controller's left stick still drives.

Fixes:
- On a controller, the triggers in the gunner seat fire the guns and no longer move the tank.
- Bingus Shared Loader v19 support: the Mod Options Menu and Mod Bindings Menu are linked as soon as the game starts, and the logs go to the loader's own log folder.
- Small performance improvements.

Known issues:
- Smoke from the gunner seat doesn't work in a tank another player called in yet.
- Tank Turret Position *Centered* moves the turret model and the gun; the tank's hit areas stay where the game has them.
- With a key set for Forward in the Mod Bindings Menu, holding W in the gunner seat may still nudge the tank a little. Please report it with your logs if you see it.

## 3.2.0

New:
- **Scroll-wheel zoom for the gunner camera.** In the gunner seat, the mouse wheel moves the camera closer or further back. Your Gunner Camera choice is where it starts each time you sit down. From the closest point, keep scrolling to zoom in on the crosshair, up to 10x; a small "x2.4" next to the crosshair shows the zoom for a moment. Leaving the seat puts the view back to normal.
- **Driver Panel is now its own option.** Turn it on or off in the mod manager or the in-game Mod Options Menu. It shows only while you're the one driving from the gunner seat, and hides when another player is in control of the tank.
- **More key bindings** (Mod Bindings Menu): Gunner Drive's Shift Up, Shift Down and Handbrake, and the gunner camera's Zoom In and Zoom Out (on a controller too), along with Forward, Back, Steer Left, Steer Right, Horn and Smoke. Your normal keys still work.

Fixes:
- In someone else's tank, the smoke key no longer fires the wrong launcher or shows the wrong smoke count.

Known issue:
- Smoke from the gunner seat doesn't work in a tank another player called in yet: the smoke key does nothing there for now.

## 3.1.1

Bug fixes:
- Reinstalling or updating the mod while the game is running no longer doubles up your settings, such as turret speed or the gunner camera distance.
- MBT Turrets: the turret speed boost now works at high frame rates and no longer swings past where you're aiming.
- Gunner Drive is more reliable: it no longer cuts out randomly, the controls can't get stuck after you get out, and smoke keeps working after game updates.
- If a game update breaks Gunner Drive, only Gunner Drive turns off, not the whole mod.
- The driver panel and Vehicle Indicator handle odd game readings and controller hiccups better.
- Tank grip, power and steering are more reliable after game updates.
- Small performance improvements.

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


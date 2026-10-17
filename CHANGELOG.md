# Changelog

## 3.6.1

New:
- **Fire rate pop-up:** as the fire-rate menu closes, the rate you picked pops up next to the gun's ammo bar for a moment (for example "2400 RPM"), then fades. Part of Maelstrom Fire Rate.

Changed:
- **Maelstrom Fire Rate on right click:** pick the rate with right click now, like the FRV's gun. While the fire-rate menu is open neither the gun nor the missiles fire, so a click in the menu only picks a rate.
- **Gunner camera zoom:** the mouse wheel and the zoom keys no longer move the gunner camera while the pause menu or the map is open, in every seat it zooms (the tanks, the M-102 FRV's gunner seat and the HMG and Anti-Tank Emplacements).

Fixed:
- **MBT Turrets:** a small flat piece of the turret's floor stuck out past the side of the turret on both tanks; it's gone.

**Known issues:** Freelook in multiplayer: the game keeps one setting for both tanks' main guns, so while you hold Freelook as the host, another player's turret may stop turning too. Tell me if you see it. Maelstrom Fire Rate with a controller: the guns can still fire while the fire-rate menu is open, and the new rate pops up once you fire.

## 3.6.0

New:
- **Maelstrom Fire Rate** (new option): hold reload in the Maelstrom's gunner seat to switch its main gun between 1200, 1800 and 2400 rounds a minute, like other weapons with fire-rate settings. Pick with left click (right click stays the missiles); the menu is titled Maelstrom. The gun starts at 1800.
- **Maelstrom Single Belt** (new option): all 2,100 of the main gun's rounds on one belt, so it never reloads.
- **FRV Run-Flat Tires** (new option): the M-102 FRV's and M-103 Supply FRV's tires never pop or lose health. On/off in the Mod Options Menu, at once. Works when you host or play alone.
- **Supply FRV turret ammo:** in the M-103 Supply FRV the Vehicle Indicator shows a bar with its automated turret's ammo, so you know when it's out.

Changed:
- **Maelstrom missile pods:** with Tank Turret Position on Centered, the pods ride a little higher so they no longer sink into the hull.
- **Gunner camera:** aiming up, and with the tank leaning to the side, the camera rises over the turret, so it no longer sinks between (or into) the Maelstrom's missile pods.
- **Aiming up on slopes:** with MBT Turrets, the gun's and the view's top stops rise by how far the ground under the turret falls away, so aiming up over the low side of a leaning tank reaches as high as on flat ground.
- Maelstrom Fire Rate and Single Belt changes in the Mod Options Menu reach the next Maelstrom called in (a Maelstrom keeps what it was called in with).

**Known issue:** Freelook in multiplayer: the game keeps one setting for both tanks' main guns, so while you hold Freelook as the host, another player's turret may stop turning too. Tell me if you see it.

## 3.5.3

Changed:
- **Zoom keys replace the mouse wheel:** a key set for Gunner Camera: Zoom In or Zoom Out in the Mod Bindings Menu (controls, tab MODS) now turns that direction of the mouse wheel off, like every other Armored Overhaul key you rebind. Zoom In set: wheel up no longer zooms; Zoom Out set: wheel down no longer zooms. Clear the key and the wheel works again within a couple of seconds. In every gunner seat that zooms (tanks, FRV, emplacements).

**Known issue:** Freelook in multiplayer: the game keeps one setting for both tanks' main guns, so while you hold Freelook as the host, another player's turret may stop turning too. Tell me if you see it.

## 3.5.2

Changed:
- **Freelook gets its key first:** the Mod Bindings Menu has 29 key slots shared by every mod. "Tank Turret: Freelook" now asks for its slot before the other Armored Overhaul keys, so it is no longer the one left out when the slots run short.
- **Fewer key slots:** Gunner Drive's Steer Left, Steer Right, Shift Up and Shift Down are no longer in the Mod Bindings Menu. Steering and gears are always the game's own controls (A / D and Shift / CTRL, or the controller's). Armored Overhaul now takes 8 of the menu's slots (was 12). If you had set keys for them, A / D and Shift / CTRL work again. The menu frees the old slots for other mods after 30 game sessions.

**Known issue:** Freelook in multiplayer: the game keeps one setting for both tanks' main guns, so while you hold Freelook as the host, another player's turret may stop turning too. Tell me if you see it.

## 3.5.1

New:
- **Freelook for the tank gunner:** a new key in the controls (tab MODS, section ARMORED OVERHAUL), **"Tank Turret: Freelook"**, needs CowboyBingus's Mod Bindings Menu. Look around while the gun stays where it points, left/right and up/down; let go and the turret turns to where you look. The trigger you pick for the key in the controls decides how it works: *Hold* = Freelook while you hold it, *Press* / *Double tap* / *Long press* = on, and off the next time. Works with any of the turret options (MBT Turrets, Traverse, Elevation, Gun Depression, Gun Raise) and needs the Vehicle Indicator or the Tank Gunner Camera on (they measure where the gun points).

Changed:
- **Gunner camera zoom, faster:** each mouse wheel notch moves the camera 1 m (was 0.5 m), and the crosshair zoom goes up one whole step a notch: x2, x3 ... x10 (was 1.25x steps). Both glide into place quicker. Also in the M-102 FRV's gunner seat, on the HMG and Anti-Tank Emplacements, and for the Zoom In / Zoom Out keys.
- **Aiming down a slope:** pointing downhill, the gunner camera rises with the hill behind it, so the turret no longer blocks your view of the ground below the crosshair.
- **Aiming on slopes:** with MBT Turrets, the gun's up/down range follows the slope under the turret, so turned back up a steep hill the gun still aims down the slope (and up it when the nose points down). It only ever widens, never holds the gun up or down. The gunner view looks down to 80 degrees below the hull with MBT Turrets.
- **Tank Collision Damage Boost:** only runs while you drive a tank (the driver seat, or the gunner seat with Gunner Drive) and only for the tank you drive; nothing runs on foot. It now includes Tank Core (which tells it your seat). After a hit the higher demolition is kept 0.25 s (was 0.15). Much lighter: about 1 call into Windows a second (was 45).
- **Mod manager icon:** shows the 3.5 art.

Fixes & code review:
- **Corpse Cleanup and other mods:** Tank Collision Damage Boost and Vehicle Loadout could stop with an error when another mod (such as Corpse Cleanup) loaded first and described a Windows memory call its own way. Every option now works whatever loads first.
- Holding W with a key set for Forward in the Mod Bindings Menu no longer nudges the tank (the known issue from 3.5.0).
- Gunner Drive switches off the engine it started when you drive the same tank again and get out.
- The HMG and Anti-Tank Emplacement zoom works in the release build too (it worked only while someone was in a tank or FRV).
- The Vehicle Indicator and Driver Panel skip the game font or skull for the rest of a session after one made the game close, and never draw into a screen that went away during a mission load. The indicator no longer redraws every frame while the turret points straight back.
- The live handling options (Top Speed, Engine Torque, Grip, Stability, the gear changes) search the game after an update one at a time instead of all at once, and remember what they found for that game version. Turning one Off in the Mod Options Menu after an error now puts the game's own value back.
- Tank Collision Damage Boost only writes to the game settings it set before, and waits for the settings to load when a patched game has more than one candidate.
- Vehicle Loadout checks a vehicle's entry is still that vehicle's before putting it back.
- The gunner camera's crosshair zoom is undone at once if following the turret fails.

Upgrading:
- Install it over 3.5.0, then Purge & Deploy. Your options stay as they are.
- For Freelook: set a key for "Tank Turret: Freelook" in the controls, tab MODS.

Known issues:
- The tank's body (what you stand on and what the tank drives into) is still the game's own shape, whose top is the old turret's roof: with the turret centered or turned you can stand at roof height where the old turret was, in thin air.
- Smoke from the gunner seat doesn't work in a tank another player called in yet.
- Tank Suspension still needs the tank to be called in again after a change; every other tank option changes mid-game.
- Freelook in multiplayer: the game keeps one setting for both tanks' main guns, so while you hold Freelook as the host, another player's turret may stop turning too. Tell me if you see it.

## 3.5.0

New option:
- **Tank Collision Damage Boost** (right after Tank Stability; one checkbox, plus a Mod Options Menu switch, on by default). The faster the Bastion and Maelstrom drive into things, the harder they hit: walls, fences and small buildings break when you ram them at speed instead of stopping the tank dead. The demolition force follows how fast the tank is really going: 30 when crawling, 35 at half speed (about 17 km/h), 40 from three-quarter speed (about 26 km/h) up, never more than 40 (no cheesing objectives that need more). A nudge still won't break a wall. Changes every tank at once, the ones already out too; turning it off puts the game's own back. Both tanks of the same kind share the game's setting (with two Bastions out the faster one sets it); in multiplayer it most likely only applies when you host.

Changed:
- **Tank Turret Aim Range is split into Tank Gun Depression and Tank Gun Raise**, so each side is set on its own. Depression: *Low* 6, *Lower* 10, *Lowest* 15 degrees below level (the game: 3). Raise: *High* 30, *Higher* 45, *Highest* 60 degrees above level (the game: 25; higher than the old Widest's 45). The side you don't pick stays the game's own, for the gun and the gunner view. The gunner view goes 20 degrees below the gun's lowest angle and 15 above its highest, never above 60 (on *Highest* it stops at the gun's own top). Each has its own Mod Options Menu row that reaches the tanks already out at once.
- **Tank MBT Turrets, reworked turret model:** cut level just above the hull's roof line, with walls that come straight down, rounded in at the bottom, ending a small gap above the deck with a recessed turret ring in the gap. The old flared lip at the turret's base (which stuck out past the hull when the turret turned) is gone. The turret is closed all round (no holes or see-through spots), and the hull's own plating (with your camo) shows under it, also where the old turret sat. The front arms keep the game's own angle again.
- **Tank MBT Turrets, working hatches:** the turret's hatches open and close like the game's own (they were stuck shut) and go round with the turret. The gunner's door at the back of the turret swings up and out on its top edge and no longer clips into the hull or leaves a hole. The gunner gets in and out at the turret's door wherever the turret points; the passengers' places and the ways in go round with the turret too.
- **Tank MBT Turrets, hit areas follow the turret:** the turret's 14 hit areas (its five armor plates, its core, the side and rear boxes, radar and antenna) now turn and move with the turret, also with Tank Turret Position *Centered* and after a change in the Mod Options Menu. Before, a shot on a turned or centered turret could hit thin air or the hull underneath. MBT Turrets now includes the tanks' physics files for this; with Tank Suspension on too, its copy carries the same hit areas.
- **Option order:** Tank Suspension now comes right after Tank MBT Turrets (both change the tanks' physics files; this way they work together).

Fixes & code review:
- Hatches are tracked per tank (two tanks with different hatches open no longer confuse each other), put back on every tank when the game closes, and found again after a game update renumbers the model's parts.
- Less work a frame while the turret turns (the ways in are updated about once a degree); right after a tank is called in, its turret's hit areas line up at once.
- Gun Depression and Gun Raise menu rows are named by their angle.
- The physics builder checks every shape it changes against the rules the game's own files follow, and stops rather than write a broken file.

Upgrading:
- Tick the new Tank Collision Damage Boost option if you want it.
- Tank Turret Aim Range is gone: pick Tank Gun Depression and/or Tank Gun Raise instead. Its 3.4.0 Mod Options Menu value doesn't carry over.
- Tank Suspension moved below Tank MBT Turrets in the list (your pick stays).
- Purge & Deploy.

Known issues:
- The tank's body (what you stand on and what the tank drives into) is still the game's own shape, whose top is the old turret's roof: with the turret centered or turned you can stand at roof height where the old turret was, in thin air. (The hit areas follow the turret; this is separate.)
- Smoke from the gunner seat doesn't work in a tank another player called in yet.
- With a key set for Forward in the Mod Bindings Menu, holding W in the gunner seat may still nudge the tank a little. Please report it with your logs if you see it.
- Tank Suspension still needs the tank to be called in again after a change (it's in the tank's physics file); every other tank option changes mid-game.

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


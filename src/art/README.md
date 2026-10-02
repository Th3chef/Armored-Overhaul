# Armored Overhaul 3.1 art

The thumbnail, gallery photo, header, social picture and the "What's in 3.1" and option pictures in `media/`.

1. **Game models.** Build [Filediver](https://github.com/xypwn/filediver) (the commit in `filediver_commit.txt`) with
   `filediver_art.diff` applied: game data and materials that aren't in the extracted packages are skipped instead of
   stopping the export. Make a game folder `gd/data` holding the game's own tank and FRV packages
   (68ebdce3f7498179 Bastion, 65ee777b72347cb4 Maelstrom, 0bdf199f7ac14f43 FRV, 17ec2d364664c3e9, each with its
   `.gpu_resources` and `.stream`), the release zip's `Turret Models` patch copied in as `0000000000000001` (it sorts
   first, so its hulls and turrets are the ones used), and a copy of 17ec2d364664c3e9 named 9ba626afa44a3aa3 (Filediver
   looks for that archive). Export the units to glb into `ex/`:
   `filediver -P --gamedir gd -o ex -T unit -i <unit>` for `content/fac_helldivers/vehicles/tank/tank.unit`,
   `0x1fa1f596769225c2` (the MBT turret), `.../tank_storm/tank_storm.unit`,
   `.../tank_storm/armaments/tank_storm_maingun/tank_storm_maingun.unit`, `.../frv/frv.unit` and
   `.../frv/armaments/frv_mg/frv_mg.unit`.
2. **Renders** (Blender 4.2's `bpy` module, Cycles on the CPU): `render_all.sh` makes the square and 16:9 renders
   (each with a distance pass, plus a vehicles-only mask) in `final/`, `render_hd.sh` the header's own 3.5:1 view. The
   camera and vehicle places are in `sq.args`, `wd.args` and `hd.args`. The armor is one paint color; the game's own
   `base_data` map gives the panel normals, shading and worn edges.
3. **Pictures** (Python with Pillow, numpy and OpenCV; the Oswald font as `Oswald-VF.ttf` and the release's `options/`
   icons next to the scripts): `art3_compose.py square`, `wide`, `social` and `header` (one per run),
   `features3.py` and `options3_sheet.py`.

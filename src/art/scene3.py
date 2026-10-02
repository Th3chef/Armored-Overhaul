"""Armored Overhaul 3.0 art: Bastion (MBT turret) in front, Maelstrom and FRV behind, from the game's own models
(Filediver glb exports of the vanilla packages + the mod's Turret Models patch).
  python3 scene3.py -- key=value ...   (see opt.get calls)"""
import bpy, math, mathutils, sys, os, random
from mathutils import Vector as V3, noise as mnoise
args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
opt = dict(a.split('=', 1) for a in args)
EX = opt.get('ex', 'ex')
VEH = EX + '/content/fac_helldivers/vehicles/'
TRANSPARENT = opt.get('transparent', '0') == '1'
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene

def fv(key, default):
    return [float(v) for v in opt.get(key, default).split(',')]

# ---------------------------------------------------------------- materials
def armour(name, base_img, paint, edge, metal=0.25, rough=0.55):
    """The game's vehicle shader is LUT-driven; here: one paint colour, with the game's own base_data map giving
    the panel normals (RG), ambient occlusion (B) and edge curvature (A) for worn edges."""
    m = bpy.data.materials.new(name); m.use_nodes = True; nt = m.node_tree; n = nt.nodes; L = nt.links
    b = n['Principled BSDF']
    b.inputs['Metallic'].default_value = metal; b.inputs['Roughness'].default_value = rough
    if base_img is None:
        b.inputs['Base Color'].default_value = (*paint, 1); return m
    uv = n.new('ShaderNodeUVMap'); uv.uv_map = 'UVMap'
    tex = n.new('ShaderNodeTexImage'); tex.image = base_img; tex.extension = 'REPEAT'; tex.interpolation = 'Cubic'
    base_img.colorspace_settings.name = 'Non-Color'
    L.new(uv.outputs['UV'], tex.inputs['Vector'])
    sep = n.new('ShaderNodeSeparateColor'); L.new(tex.outputs['Color'], sep.inputs['Color'])
    comb = n.new('ShaderNodeCombineColor'); comb.inputs['Blue'].default_value = 1.0
    flip = n.new('ShaderNodeMath'); flip.operation = 'SUBTRACT'; flip.inputs[0].default_value = 1.0
    L.new(sep.outputs['Red'], comb.inputs['Red'])
    if opt.get('flipg', '1') == '1':
        L.new(sep.outputs['Green'], flip.inputs[1]); L.new(flip.outputs[0], comb.inputs['Green'])
    else:
        L.new(sep.outputs['Green'], comb.inputs['Green'])
    nm = n.new('ShaderNodeNormalMap'); nm.uv_map = 'UVMap'; nm.inputs['Strength'].default_value = float(opt.get('nstr', 1.0))
    L.new(comb.outputs['Color'], nm.inputs['Color']); L.new(nm.outputs['Normal'], b.inputs['Normal'])
    # curvature (alpha): 0.5 flat, >0.5 convex edges -> worn bright metal, <0.5 cavities -> darker
    edge_t = n.new('ShaderNodeMapRange'); edge_t.inputs['From Min'].default_value = 0.56; edge_t.inputs['From Max'].default_value = 0.8
    L.new(tex.outputs['Alpha'], edge_t.inputs['Value'])
    cav = n.new('ShaderNodeMapRange'); cav.inputs['From Min'].default_value = 0.2; cav.inputs['From Max'].default_value = 0.5
    cav.inputs['To Min'].default_value = 0.45
    L.new(tex.outputs['Alpha'], cav.inputs['Value'])
    ao = n.new('ShaderNodeMath'); ao.operation = 'MULTIPLY'; L.new(sep.outputs['Blue'], ao.inputs[0]); L.new(cav.outputs['Result'], ao.inputs[1])
    mix = n.new('ShaderNodeMix'); mix.data_type = 'RGBA'
    mix.inputs[6].default_value = (*paint, 1); mix.inputs[7].default_value = (*edge, 1)
    L.new(edge_t.outputs['Result'], mix.inputs['Factor'])
    mul = n.new('ShaderNodeMix'); mul.data_type = 'RGBA'; mul.blend_type = 'MULTIPLY'; mul.inputs['Factor'].default_value = 1.0
    L.new(mix.outputs[2], mul.inputs[6])
    aoc = n.new('ShaderNodeCombineColor'); [L.new(ao.outputs[0], aoc.inputs[k]) for k in ('Red', 'Green', 'Blue')]
    L.new(aoc.outputs['Color'], mul.inputs[7])
    L.new(mul.outputs[2], b.inputs['Base Color'])
    rmap = n.new('ShaderNodeMapRange'); rmap.inputs['To Min'].default_value = rough; rmap.inputs['To Max'].default_value = rough - 0.25
    L.new(edge_t.outputs['Result'], rmap.inputs['Value']); L.new(rmap.outputs['Result'], b.inputs['Roughness'])
    mmap = n.new('ShaderNodeMapRange'); mmap.inputs['To Min'].default_value = metal; mmap.inputs['To Max'].default_value = 0.9
    L.new(edge_t.outputs['Result'], mmap.inputs['Value']); L.new(mmap.outputs['Result'], b.inputs['Metallic'])
    return m

def flat(name, rgb, rough, metal=0.0, emit=None):
    m = bpy.data.materials.new(name); m.use_nodes = True; b = m.node_tree.nodes['Principled BSDF']
    b.inputs['Base Color'].default_value = (*rgb, 1); b.inputs['Roughness'].default_value = rough; b.inputs['Metallic'].default_value = metal
    if emit:
        b.inputs['Emission Color'].default_value = (*emit[0], 1); b.inputs['Emission Strength'].default_value = emit[1]
    return m

PAINT = tuple(fv('paint', '0.16,0.17,0.18')); EDGE = tuple(fv('edge', '0.55,0.55,0.55'))
FRV_PAINT = tuple(fv('frvpaint', '0.15,0.16,0.17'))
GLASS = flat('glass', (0.015, 0.016, 0.02), 0.12)
LIGHTS = flat('lights', (0.9, 0.8, 0.6), 0.3, emit=((1.0, 0.75, 0.45), float(opt.get('lamp', 6))))
DARK = flat('dark_metal', (0.045, 0.045, 0.048), 0.5, 0.6)
RUBBER = flat('rubber', (0.025, 0.024, 0.023), 0.85)
mat_cache = {}

def base_image(mat):
    if not mat or not mat.use_nodes: return None
    for nd in mat.node_tree.nodes:
        if nd.type == 'TEX_IMAGE' and nd.image: return nd.image
    return None

def remap(o, kind):
    for slot in o.material_slots:
        m = slot.material; nm = m.name if m else ''
        key = (kind, nm)
        if key not in mat_cache:
            if 'light' in nm or nm.startswith('0x9967528b'):
                new = LIGHTS if 'm_lights' in nm else GLASS
            elif 'tracks' in nm or 'e7fd8eac41b5da79' in nm:
                new = m    # the game's own tread textures, as Filediver exported them
                if m and m.use_nodes:
                    b = m.node_tree.nodes.get('Principled BSDF')
                    if b and not b.inputs['Base Color'].links: b.inputs['Base Color'].default_value = (0.05, 0.05, 0.05, 1)
            elif 'wheels' in nm:
                new = armour('frv_wheels', base_image(m), (0.04, 0.04, 0.04), (0.2, 0.2, 0.2), metal=0.0, rough=0.8)
            elif 'frv' in nm:
                new = armour('frv_' + nm[:20], base_image(m), FRV_PAINT, EDGE)
            elif '8080d4fe57ad7888' in nm or '3acd5f632a67d5c6' in nm or 'c92f49ead1c5d813' in nm:
                new = armour('gun_' + nm[-8:], base_image(m), tuple(c * 0.7 for c in PAINT), EDGE, metal=0.4)
            elif m is None:
                new = DARK
            else:
                new = armour('armour_' + nm[-8:], base_image(m), PAINT, EDGE)
            mat_cache[key] = new
        slot.material = mat_cache[key]
    for p in o.data.polygons: p.use_smooth = True

# ---------------------------------------------------------------- vehicles
DROP = ('damaged', 'destroyed', 'Icosphere')

def load(path, kind, keep=None, drop=DROP):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    out = []
    for o in new:
        if o.type == 'MESH':
            if any(d in o.name for d in drop) or (keep and not any(k in o.name for k in keep)):
                bpy.data.objects.remove(o); continue
            remap(o, kind); out.append(o)
    roots = [o for o in bpy.data.objects if o in new and o.name in bpy.data.objects and o.parent is None]
    return roots, [o for o in bpy.data.objects if o in new]

def place(roots, loc, yaw_deg, name):
    e = bpy.data.objects.new(name, None); sc.collection.objects.link(e)
    for r in roots: r.parent = e
    e.location = loc; e.rotation_euler = (0, 0, math.radians(yaw_deg))
    return e

def pose(objs, bone, axis, deg):
    for o in objs:
        if o.type == 'ARMATURE' and bone in o.pose.bones:
            pb = o.pose.bones[bone]; pb.rotation_mode = 'XYZ'
            r = [0, 0, 0]; r['XYZ'.index(axis)] = math.radians(deg); pb.rotation_euler = r

MOUNT = V3((0, -1.959, 2.525))
def tank(hull_path, gun_path, loc, yaw, turret, elev, name, gun_keep=None):
    hr, _ = load(hull_path, name)
    hull = place(hr, (0, 0, 0), 0, name + '_hull')
    gr, gobj = load(gun_path, name, keep=gun_keep)
    gun = place(gr, MOUNT, turret, name + '_gun')
    if elev: pose(gobj, 'elevation', opt.get('elev_axis', 'X'), elev)
    gun.parent = hull
    hull.location = loc; hull.rotation_euler = (0, 0, math.radians(yaw))
    return hull

def _rel(key):
    """'fwd,right' in metres from the camera (ground plane) -> world x,y."""
    c = V3(fv('cam', '9,9,1.4')); t = V3(fv('target', '0,-1,1.6')); d = (t - c); d.z = 0; d.normalize()
    r = V3((d.y, -d.x, 0)); f, rt = fv(key, '0,0')[:2]
    return c + d * f + r * rt
for _k in ('m', 'f'):
    if _k + '_rel' in opt:
        _p = _rel(_k + '_rel'); opt[_k + '_loc'] = '%.3f,%.3f,%s' % (_p.x, _p.y, '0.55' if _k == 'f' else '0')
VEHICLES = opt.get('vehicles', 'bastion,maelstrom,frv').split(',')
if 'bastion' in VEHICLES:
    tank(VEH + 'tank/tank.unit.glb', EX + '/0x1fa1f596769225c2.unit.glb', fv('b_loc', '0,0,0'), float(opt.get('b_yaw', 0)),
         float(opt.get('b_turret', 35)), float(opt.get('b_elev', 0)), 'bastion', gun_keep=('turret_',))
if 'maelstrom' in VEHICLES:
    tank(VEH + 'tank_storm/tank_storm.unit.glb', VEH + 'tank_storm/armaments/tank_storm_maingun/tank_storm_maingun.unit.glb',
         fv('m_loc', '-9,-11,0'), float(opt.get('m_yaw', 15)), float(opt.get('m_turret', -20)), float(opt.get('m_elev', 0)), 'maelstrom')
if 'frv' in VEHICLES:
    fr, _ = load(VEH + 'frv/frv.unit.glb', 'frv')
    frv = place(fr, (0, 0, 0), 0, 'frv_body')
    mr, mobj = load(VEH + 'frv/armaments/frv_mg/frv_mg.unit.glb', 'frv')
    mg = place(mr, (0, -1.199, 1.646), float(opt.get('f_turret', 0)), 'frv_mg'); mg.parent = frv
    frv.location = fv('f_loc', '8,-12,0.55'); frv.rotation_euler = (0, 0, math.radians(float(opt.get('f_yaw', -25))))
for o in list(bpy.data.objects):
    if o.type in ('LIGHT', 'CAMERA'): bpy.data.objects.remove(o)

# ---------------------------------------------------------------- ground and world (desert battlefield at dusk)
def terrain(name, size, res, height_fn):
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=res, y_subdivisions=res, size=size, location=(0, 0, 0))
    o = bpy.context.active_object; o.name = name
    for v in o.data.vertices: v.co.z = height_fn(v.co.x, v.co.y)
    for p in o.data.polygons: p.use_smooth = True
    return o
PADS = [tuple(fv(k, d)[:2]) + (r,) for k, d, r in (('b_loc', '0,0,0', 6.0), ('m_loc', '-9,-11,0', 6.0), ('f_loc', '8,-12,0', 3.6), ('cam', '9,9,1.4', 5.0))]
CRATERS = [(-14, 8, 3.0, 0.5), (14, 4, 2.2, 0.35), (-20, -24, 4.0, 0.6), (4, 22, 3.5, 0.5), (24, -30, 2.5, 0.4)]
def ground_h(x, y):
    flat_k = 1.0
    for px, py, pr in PADS:
        r = ((x - px) ** 2 + (y - py) ** 2) ** 0.5
        flat_k = min(flat_k, min(1.0, max(0.0, (r - pr) / 3.0)) ** 1.2)
    h = mnoise.fractal(V3((x * 0.045, y * 0.045, 0.3)), 0.6, 2.0, 5) * 1.6 + mnoise.noise(V3((x * 0.3, y * 0.3, 1.7))) * 0.08
    for cx, cy, cr, cd in CRATERS:
        d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5 / cr
        if d < 1.6: h += -cd * max(0.0, 1 - d * d) + cd * 0.45 * max(0.0, 1 - abs(d - 1.15) / 0.35)
    return 0.02 + h * flat_k
ground = terrain('ground', 200, int(opt.get('gres', 500)), ground_h)
def ridge_h(x, y):
    r = (x * x + y * y) ** 0.5
    if r < 170: return -2.0
    k = min(1.0, (r - 170) / 80)
    return -2 + k * (4 + 26 * max(0.0, mnoise.fractal(V3((x * 0.006, y * 0.006, 5.0)), 0.5, 2.0, 3) + 0.55))
ridges = terrain('ridges', 1000, 200, ridge_h)
rock_mat = flat('rock', (0.035, 0.03, 0.026), 0.95)
random.seed(int(opt.get('seed', 3)))
for i in range(int(opt.get('rocks', 90))):
    ang = random.uniform(0, 6.283); dist = random.uniform(7, 70)
    x, y = dist * math.cos(ang), dist * math.sin(ang)
    if any(((x - px) ** 2 + (y - py) ** 2) < (pr + 1.5) ** 2 for px, py, pr in PADS): continue
    sz = random.uniform(0.1, 0.6) * (1 + dist / 40)
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=3, radius=sz, location=(x, y, ground_h(x, y) + sz * 0.25))
    rk = bpy.context.active_object
    for v in rk.data.vertices: v.co *= 1 + 0.35 * mnoise.noise(v.co * 3.1 + V3((i, i * 2, 0)))
    rk.scale = (random.uniform(0.8, 1.6), random.uniform(0.8, 1.4), random.uniform(0.45, 0.8))
    rk.rotation_euler = (0, 0, random.uniform(0, 6.3)); rk.data.materials.append(rock_mat)
    for p in rk.data.polygons: p.use_smooth = True
    if TRANSPARENT: rk.hide_render = True
ridges.data.materials.append(flat('ridge', (0.05, 0.043, 0.038), 1.0))
g = bpy.data.materials.new('ground'); g.use_nodes = True; nt = g.node_tree; n = nt.nodes; b = n['Principled BSDF']
noise = n.new('ShaderNodeTexNoise'); noise.inputs['Scale'].default_value = 0.35; noise.inputs['Detail'].default_value = 12
ramp = n.new('ShaderNodeValToRGB'); ramp.color_ramp.elements[0].color = (0.03, 0.024, 0.018, 1); ramp.color_ramp.elements[1].color = (0.075, 0.058, 0.042, 1)
nt.links.new(noise.outputs['Fac'], ramp.inputs['Fac'])
bump = n.new('ShaderNodeBump'); bump.inputs['Strength'].default_value = 0.8; n2 = n.new('ShaderNodeTexNoise'); n2.inputs['Scale'].default_value = 14
nt.links.new(n2.outputs['Fac'], bump.inputs['Height']); nt.links.new(bump.outputs['Normal'], b.inputs['Normal'])
b.inputs['Roughness'].default_value = 0.95
sc_n = n.new('ShaderNodeTexNoise'); sc_n.inputs['Scale'].default_value = 0.08; sc_n.inputs['Detail'].default_value = 6
sc_r = n.new('ShaderNodeValToRGB'); sc_r.color_ramp.elements[0].position = 0.45; sc_r.color_ramp.elements[1].position = 0.62
sc_r.color_ramp.elements[0].color = (0.25, 0.22, 0.2, 1); sc_r.color_ramp.elements[1].color = (1, 1, 1, 1)
mix = n.new('ShaderNodeMix'); mix.data_type = 'RGBA'; mix.blend_type = 'MULTIPLY'; mix.inputs['Factor'].default_value = 1.0
nt.links.new(sc_n.outputs['Fac'], sc_r.inputs['Fac'])
nt.links.new(ramp.outputs['Color'], mix.inputs[6]); nt.links.new(sc_r.outputs['Color'], mix.inputs[7])
nt.links.new(mix.outputs[2], b.inputs['Base Color'])
ground.data.materials.append(g)
if TRANSPARENT: ground.hide_render = True; ridges.hide_render = True

world = bpy.data.worlds.new('w'); world.use_nodes = True; sc.world = world
bg = world.node_tree.nodes['Background']; sky = world.node_tree.nodes.new('ShaderNodeTexSky')
sky.sky_type = 'NISHITA'; sky.sun_elevation = math.radians(float(opt.get('sun_el', 5))); sky.sun_rotation = math.radians(float(opt.get('sun_rot', 200)))
sky.air_density = 2.5; sky.dust_density = 4.0; sky.sun_disc = False
world.node_tree.links.new(sky.outputs['Color'], bg.inputs['Color']); bg.inputs['Strength'].default_value = float(opt.get('sky', 0.07))
def sun(name, energy, rot, color, angle=2.0):
    Lt = bpy.data.lights.new(name, 'SUN'); Lt.energy = energy; Lt.color = color; Lt.angle = math.radians(angle)
    o = bpy.data.objects.new(name, Lt); o.rotation_euler = [math.radians(a) for a in rot]; sc.collection.objects.link(o)
sun('key', float(opt.get('key', 3.0)), fv('key_rot', '82,0,20'), tuple(fv('key_col', '1.0,0.62,0.32')), 1.0)   # low sun behind the vehicles
sun('fill', float(opt.get('fill', 0.7)), fv('fill_rot', '55,0,200'), tuple(fv('fill_col', '0.75,0.8,0.95')), 8.0)   # soft cool fill from the camera side

cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam')); sc.collection.objects.link(cam); sc.camera = cam
cam.data.lens = float(opt.get('lens', 28)); cam.data.shift_x = float(opt.get('shiftx', 0)); cam.data.shift_y = float(opt.get('shifty', 0))
cam.data.clip_end = 3000
cam.location = fv('cam', '9,9,1.4'); tgt = V3(fv('target', '0,-1,1.6'))
cam.rotation_euler = (tgt - cam.location).to_track_quat('-Z', 'Y').to_euler()

sc.render.engine = 'CYCLES'; sc.cycles.device = 'CPU'; sc.cycles.samples = int(opt.get('samples', 32))
sc.cycles.use_denoising = True
try: sc.cycles.denoiser = 'OPENIMAGEDENOISE'
except Exception: pass
sc.cycles.max_bounces = int(opt.get('bounces', 6))
sc.render.resolution_x, sc.render.resolution_y = [int(v) for v in opt.get('res', '640,640').split(',')]
sc.view_settings.view_transform = 'AgX'; sc.view_settings.look = 'None'
sc.render.film_transparent = TRANSPARENT
sc.render.filepath = opt.get('out', './test.png')
if opt.get('mist'):
    vl = sc.view_layers[0]; vl.use_pass_mist = True
    sc.world.mist_settings.start = 6; sc.world.mist_settings.depth = 400; sc.world.mist_settings.falloff = 'QUADRATIC'
    sc.use_nodes = True; tree = sc.node_tree
    rl = tree.nodes.get('Render Layers') or tree.nodes.new('CompositorNodeRLayers')
    fo = tree.nodes.new('CompositorNodeOutputFile'); fo.base_path = os.path.dirname(opt['mist'])
    fo.file_slots[0].path = os.path.basename(opt['mist']).replace('.png', '') + '_'
    fo.format.color_mode = 'BW'; fo.format.color_depth = '16'
    tree.links.new(rl.outputs['Mist'], fo.inputs[0])
    comp = tree.nodes.get('Composite') or tree.nodes.new('CompositorNodeComposite')
    tree.links.new(rl.outputs['Image'], comp.inputs['Image'])
if opt.get('blend'): bpy.ops.wm.save_as_mainfile(filepath=opt['blend'])
bpy.ops.render.render(write_still=True)
print('wrote', sc.render.filepath)

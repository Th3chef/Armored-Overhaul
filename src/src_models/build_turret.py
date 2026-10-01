"""Armored Overhaul - turret models. Makes the whole upper structure of a tank hull turn with its gun, like a main
battle tank turret. One script for both tanks:  TANK=maelstrom|bastion python3 build_turret.py
(headless Blender via the bpy module + HD2SDK; geometry only, textures are the game's own)."""
import sys, os, importlib, math, collections, bpy, bmesh, mathutils
sys.path.insert(0, '.')
sdk = importlib.import_module('hd2sdk')
sdk.register()
sdk.CreateGameMaterial = lambda StingrayMat, mat: None          # geometry only
from hd2sdk.utils import slim as _slim
DATA = 'blendwork/data/'
_slim.slim_init(DATA.rstrip('/'))
sdk.Global_gamepath = DATA
from hd2sdk import Global_TocManager, UnitID
V = mathutils.Vector

TANKS = {
    'maelstrom': {                                   # TD-110 Maelstrom (tank_storm)
        'archive': '65ee777b72347cb4', 'hull': 0xb0c9faf4af8903f9, 'gun': 0xd58ae6a04edb10de,
        'mount': V((0.0, -1.959, 2.525)),            # hull node 0xe30c5711 (MountComponent)
        'hide': [0x8aff7f0793a5bced, 0x3a061009aa31e9cb],   # missile pods, smoke launcher (fixed to the hull)
        # parts copied onto the turret at their hull nodes (the originals above are hidden): the two missile pods
        # (nodes 0x9dee49c0 / 0x27db9eb5) and, from 1.1, the smoke launcher rack (node 0x79cc4582)
        'pods': [{'unit': 0x8aff7f0793a5bced, 'nodes': [V((-1.422, -4.511, 2.966)), V((1.422, -4.511, 2.966))]},
                 {'unit': 0x3a061009aa31e9cb, 'nodes': [V((0.0, -2.816, 3.079))]}],
    },
    'bastion': {                                     # TD-220 Bastion (tank)
        'archive': '68ebdce3f7498179', 'hull': 0x16474112801385b6, 'gun': 0x1fa1f596769225c2,
        'mount': V((0.0, -1.959, 2.525)),            # hull node 0xe30c5711 (MountComponent)
        'hide': [], 'pods': [],
    },
}
TANK = os.environ.get('TANK', 'maelstrom')
CFG = TANKS[TANK]
HULL, GUN, MOUNT, HIDE = CFG['hull'], CFG['gun'], CFG['mount'], CFG['hide']
DECK_Z = 2.24                                        # hull roof line (same hull on both tanks): everything above turns
SHADOW_MATS = {str(0x75f87ad2ae08e9c2), str(0x5990e5efbca8ae21)}   # shadow-caster materials: mark the shadow levels

Global_TocManager.LoadArchive(DATA + CFG['archive'])
bpy.context.scene.Hd2ToolPanelSettings.ImportLods = True        # every level of detail, so distant views match
# Geometry only: materials from other packages get an empty placeholder with the right ID (export needs only the ID).
for mid in (0x75f87ad2ae08e9c2, 0xe7fd8eac41b5da79, 0x2d7ef36748bb42f4, 0x2bc2aecf229aeedb, 0x84b327056baf1c6d,
            0x5990e5efbca8ae21, 0x8080d4fe57ad7888, 0x3acd5f632a67d5c6):
    if str(mid) not in bpy.data.materials: bpy.data.materials.new(str(mid))
UNITS = [HULL, GUN] + HIDE
for fid in UNITS:
    Global_TocManager.GetEntry(fid, UnitID).Load(False, True)
for o in list(bpy.data.objects):
    if o.name == 'Cube': bpy.data.objects.remove(o)

def levels(fid):
    """{lod: object} for a unit, using the unit's own mesh table (object names differ between units)."""
    info = Global_TocManager.GetEntry(fid, UnitID).LoadedData.MeshInfoArray
    out = {}
    for o in bpy.data.objects:
        if o.type == 'MESH' and o.get('Z_ObjectID') == str(fid):
            lod = info[int(o['MeshInfoIndex'])].LodIndex
            if lod >= 0: out[lod] = o
    return out
def is_shadow(o): return any(m and m.name.split('.')[0] in SHADOW_MATS for m in o.data.materials)

# Damage zones. The hull material picks what to draw from the whole-number tile of UV0: tile 0 is always drawn, each
# armour zone has an intact tile (odd) and a crumpled damaged tile (even, same place), the roof boxes have one tile
# each (13-18) and row v=1 holds what is revealed when a box is shot off. The game only drives these for the hull
# unit, so on the turret the damaged shells would show through. The turret keeps the intact geometry, moved to
# tile 0 (texture lookups use the fractional part, so it looks the same).
DAMAGE_PAIRS = {1, 3, 5, 7, 9, 11, 19, 21, 23, 25}          # intact tiles; tile + 1 is the damaged version
BOXES = {13, 14, 15, 16, 17, 18}
def tile_of(face, layer):
    n = len(face.loops)
    return (math.floor(sum(l[layer].uv[0] for l in face.loops) / n), math.floor(sum(l[layer].uv[1] for l in face.loops) / n))

def keep_faces(obj, keep):
    bm = bmesh.new(); bm.from_mesh(obj.data); bm.faces.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if (f.index in keep) != True], context='FACES')
    bm.to_mesh(obj.data); bm.free()

def outline_xy(obj):
    pts = [(obj.matrix_world @ v.co) for v in obj.data.vertices if abs((obj.matrix_world @ v.co).z - DECK_Z) < 0.003]
    pts2 = sorted({(round(p.x, 4), round(p.y, 4)) for p in pts})
    def cross(o, a, b): return (a[0]-o[0])*(b[1]-o[1]) - (a[1]-o[1])*(b[0]-o[0])
    lower, upper = [], []
    for p in pts2:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0: lower.pop()
        lower.append(p)
    for p in reversed(pts2):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0: upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]

def plate_source(hull):
    """A big, flat, up-facing roof face (tile 0 preferred: never damage-switched): UVs, material, normal bits."""
    uv0 = hull.data.uv_layers[0].data
    nb = hull.data.attributes.get('hd2_normal_bits')
    best = None
    for p in hull.data.polygons:
        if p.normal.z <= 0.99 or p.area <= 0.05: continue
        tile0 = all(0 <= uv0[li].uv[0] < 1 and 0 <= uv0[li].uv[1] < 1 for li in p.loop_indices)
        score = (tile0, p.area)
        if best is None or score > best[0]: best = (score, p)
    p = best[1]
    uvs = []
    for i in range(len(hull.data.uv_layers)):
        u, v = hull.data.uv_layers[i].data[p.loop_indices[0]].uv
        if i == 0: u, v = u - math.floor(u), v - math.floor(v)
        uvs.append((u, v))
    return {'uv': uvs, 'mat': p.material_index, 'bits': nb.data[p.vertices[0]].value if nb else 0}

# Plate texture: a real flat deck panel of the hull (tile 0, always drawn) repeated like floor plates, so the deck
# under the turret and the turret's underside look like armour, not a blank patch.
def reference_panel(hull):
    import numpy as np
    W = hull.matrix_world
    bm = bmesh.new(); bm.from_mesh(hull.data); bm.faces.ensure_lookup_table()
    layers = bm.loops.layers.uv.values(); L0 = layers[0]
    col = bm.loops.layers.color.get('Col')
    nb = bm.verts.layers.int.get('hd2_normal_bits')
    def tile0(f): return all(0 <= l[L0].uv[0] < 1 and 0 <= l[L0].uv[1] < 1 for l in f.loops)
    flat = [f for f in bm.faces if (W.to_3x3() @ f.normal).z > 0.999 and tile0(f)]
    # biggest planar, rectangular island with an affine UV map
    groups = collections.defaultdict(list)
    for f in flat: groups[round((W @ f.calc_center_median()).z, 3)].append(f)
    best = None
    for z, fs in groups.items():
        seen = set()
        for f in fs:
            if f in seen: continue
            isl, stack = [], [f]; seen.add(f)
            while stack:
                g = stack.pop(); isl.append(g)
                for e in g.edges:
                    for h in e.link_faces:
                        if h in fs and h not in seen: seen.add(h); stack.append(h)
            pts = [W @ v.co for g in isl for v in g.verts]
            x0, x1 = min(p.x for p in pts), max(p.x for p in pts); y0, y1 = min(p.y for p in pts), max(p.y for p in pts)
            area = sum(g.calc_area() for g in isl)
            if (x1 - x0) * (y1 - y0) <= 0 or area / ((x1 - x0) * (y1 - y0)) < 0.97 or area < 0.5: continue
            maps = []
            ok = True
            for L in layers:
                A = np.array([[(W @ l.vert.co).x, (W @ l.vert.co).y, 1.0] for g in isl for l in g.loops])
                U = np.array([[l[L].uv[0], l[L].uv[1]] for g in isl for l in g.loops])
                sol = np.linalg.lstsq(A, U, rcond=None)[0]
                if np.abs(A @ sol - U).max() > 1e-3: ok = False
                maps.append(sol)
            if ok and (best is None or area > best['area']):
                l0 = isl[0].loops[0]
                best = {'area': area, 'rect': (x0, x1, y0, y1), 'maps': maps,
                        'color': tuple(l0[col]) if col else (1, 1, 1, 1), 'bits_up': l0.vert[nb] if nb else 0}
    down = [f for f in bm.faces if (W.to_3x3() @ f.normal).z < -0.999]
    best['bits_down'] = down[0].verts[0][nb] if (down and nb) else best['bits_up']
    bm.free()
    print('plate texture from deck panel', [round(v, 2) for v in best['rect']], 'area', round(best['area'], 2))
    return best

def add_plate(obj, ring, z, up, group, src, ref):
    """Flat plate over the convex outline `ring` (world xy) at height z, tiled with the reference deck panel."""
    x0, x1, y0, y1 = ref['rect']; w, h = x1 - x0, y1 - y0
    inv = obj.matrix_world.inverted(); rot = inv.to_3x3()
    bm = bmesh.new(); bm.from_mesh(obj.data)
    layers = bm.loops.layers.uv.values()
    col = bm.loops.layers.color.get('Col')
    nb = bm.verts.layers.int.get('hd2_normal_bits')
    dl = bm.verts.layers.deform.verify()
    gi = (obj.vertex_groups.get(group) or obj.vertex_groups[0]).index
    xs = [p[0] for p in ring]; ys = [p[1] for p in ring]
    new_faces = []
    i = 0
    cx = min(xs)
    while cx < max(xs):
        cy = min(ys)
        while cy < max(ys):
            corners = [(cx, cy), (cx + w, cy), (cx + w, cy + h), (cx, cy + h)]
            local = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]            # the same corners of the reference panel
            vs = [bm.verts.new(inv @ mathutils.Vector((x, y, z))) for x, y in corners]
            f = bm.faces.new(vs if up else list(reversed(vs)))
            f.material_index = src['mat']
            order = [0, 1, 2, 3] if up else [3, 2, 1, 0]
            for loop, k in zip(f.loops, order):
                lx, ly = local[k]
                for li, L in enumerate(layers):
                    m = ref['maps'][li] if li < len(ref['maps']) else None
                    if m is None: loop[L].uv = (0, 0); continue
                    u = m[0][0] * lx + m[1][0] * ly + m[2][0]; v = m[0][1] * lx + m[1][1] * ly + m[2][1]
                    loop[L].uv = (u, v)
                if col: loop[col] = ref['color']
            for v in vs:
                v[dl][gi] = 1.0
                if nb is not None: v[nb] = ref['bits_up'] if up else ref['bits_down']
            new_faces.append(f)
            cy += h
        cx += w
    # UV0 into tile 0 (per face, so every cell keeps its own continuous mapping)
    L0 = layers[0]
    for f in new_faces:
        tu = math.floor(sum(l[L0].uv[0] for l in f.loops) / 4); tv = math.floor(sum(l[L0].uv[1] for l in f.loops) / 4)
        for l in f.loops: l[L0].uv = (l[L0].uv[0] - tu, l[L0].uv[1] - tv)
    # crop the cells to the outline (convex, counter-clockwise): cut away everything outside each edge
    geom = set(new_faces)
    for k in range(len(ring)):
        ax, ay = ring[k]; bx, by = ring[(k + 1) % len(ring)]
        n_world = mathutils.Vector((by - ay, -(bx - ax), 0)).normalized()          # outward
        plane_co = inv @ mathutils.Vector((ax, ay, z)); plane_no = (rot @ n_world).normalized()
        elems = list({e for f in geom if f.is_valid for e in f.edges} | {v for f in geom if f.is_valid for v in f.verts} | {f for f in geom if f.is_valid})
        res = bmesh.ops.bisect_plane(bm, geom=elems, plane_co=plane_co, plane_no=plane_no, clear_outer=True)
        geom = {e for e in res['geom'] if isinstance(e, bmesh.types.BMFace)} | {f for f in geom if f.is_valid}
    bm.to_mesh(obj.data); bm.free()

def make_top(hull):
    """Cut the hull at the roof line; returns (top object in gun space, outline ring, counts). The hull keeps a deck."""
    W = hull.matrix_world.copy()
    zc = (W.inverted() @ mathutils.Vector((0, 0, DECK_Z))).z
    bm = bmesh.new(); bm.from_mesh(hull.data)
    bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], plane_co=(0, 0, zc), plane_no=(0, 0, 1))
    bm.to_mesh(hull.data); bm.free()
    top_faces = {p.index for p in hull.data.polygons if p.center.z > zc + 1e-4}
    src = plate_source(hull)
    top = hull.copy(); top.data = hull.data.copy(); bpy.context.scene.collection.objects.link(top)
    keep_faces(top, top_faces)
    keep_faces(hull, {p.index for p in hull.data.polygons} - top_faces)
    # intact geometry only, moved to tile 0
    bm = bmesh.new(); bm.from_mesh(top.data)
    L0 = bm.loops.layers.uv[0]
    drop, kept = [], collections.Counter()
    for f in bm.faces:
        tu, tv = tile_of(f, L0)
        if not (tv == 0 and (tu == 0 or tu in DAMAGE_PAIRS or tu in BOXES)): drop.append(f); continue
        kept[tu] += 1
        for l in f.loops: l[L0].uv = (l[L0].uv[0] - tu, l[L0].uv[1] - tv)
    bmesh.ops.delete(bm, geom=drop, context='FACES')
    bm.to_mesh(top.data); bm.free()
    ring = outline_xy(top)
    add_plate(hull, ring, DECK_Z - 0.004, True, 'boss', src, REF)          # deck where the top used to sit
    top.parent = None
    top.data.transform(W)
    top.data.transform(mathutils.Matrix.Translation(-MOUNT))               # hull space -> gun space
    top.matrix_world = mathutils.Matrix()
    top.vertex_groups.clear()
    top.vertex_groups.new(name='traverse').add(range(len(top.data.vertices)), 1.0, 'REPLACE')
    top.matrix_world = mathutils.Matrix.Translation(MOUNT)                  # so the floor lands at the roof line
    add_plate(top, ring, DECK_Z + 0.002, False, 'traverse', src, REF)      # turret floor
    top.matrix_world = mathutils.Matrix()
    return top, ring, len(top_faces), len(drop)

def join_into(gun, parts):
    with bpy.context.temp_override(active_object=gun, selected_editable_objects=[gun] + parts, selected_objects=[gun] + parts):
        bpy.ops.object.join()

def pod_copies(pod, nodes):
    out = []
    for node in nodes:
        c = pod.copy(); c.data = pod.data.copy(); bpy.context.scene.collection.objects.link(c)
        c.parent = None
        c.data.transform(mathutils.Matrix.Translation(node - MOUNT) @ pod.matrix_world)   # pod space -> gun space
        c.matrix_world = mathutils.Matrix()
        c.vertex_groups.clear()
        c.vertex_groups.new(name='traverse').add(range(len(c.data.vertices)), 1.0, 'REPLACE')
        out.append(c)
    return out

HULL_L, GUN_L = levels(HULL), levels(GUN)
REF = reference_panel(HULL_L[0])
# Pair levels: visual levels in order, shadow levels in order; a gun level without its own hull level reuses the
# smallest hull level of the same kind.
pairs = collections.defaultdict(list)
for shadow in (False, True):
    hl = [l for l in sorted(HULL_L) if is_shadow(HULL_L[l]) == shadow]
    gl = [l for l in sorted(GUN_L) if is_shadow(GUN_L[l]) == shadow]
    for i, g in enumerate(gl):
        if hl: pairs[hl[min(i, len(hl) - 1)]].append(g)
POD_BY_GUN = collections.defaultdict(list)          # gun level -> [(part level object, nodes)]
for part in CFG['pods']:
    POD_L = levels(part['unit'])
    for shadow in (False, True):
        pl = [l for l in sorted(POD_L) if is_shadow(POD_L[l]) == shadow]
        gl = [l for l in sorted(GUN_L) if is_shadow(GUN_L[l]) == shadow]
        for i, g in enumerate(gl):
            if pl: POD_BY_GUN[g].append((POD_L[pl[min(i, len(pl) - 1)]], part['nodes']))
for hl in sorted(pairs):
    top, ring, nfaces, ndrop = make_top(HULL_L[hl])
    for k, gl in enumerate(pairs[hl]):
        part = top if k == len(pairs[hl]) - 1 else top.copy()
        if part is not top: part.data = top.data.copy(); bpy.context.scene.collection.objects.link(part)
        parts = [part]
        for pod, nodes in POD_BY_GUN.get(gl, []): parts += pod_copies(pod, nodes)
        join_into(GUN_L[gl], parts)
        print(f'{TANK} hull lod{hl} -> gun lod{gl}: top faces {nfaces}, dropped {ndrop} damage/stump faces, outline {len(ring)} pts'
              + ''.join(f', + {pod.name}' for pod, _ in POD_BY_GUN.get(gl, [])))

# hide the roof-mounted parts that can't turn with the top (the turret carries its own copy where it has one)
for fid in HIDE:
    for o in bpy.data.objects:
        if o.type == 'MESH' and o.get('Z_ObjectID') == str(fid):
            for v in o.data.vertices: v.co = (0, 0, 0)
            print('hidden', o.name)
UNIT_OBJECTS = {fid: [o for o in bpy.data.objects if o.type == 'MESH' and o.get('Z_ObjectID') == str(fid)] for fid in UNITS}
bpy.ops.wm.save_as_mainfile(filepath=f'blendwork/{TANK}_turret.blend')
print('saved blend')

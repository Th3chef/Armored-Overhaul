"""Armored Overhaul 3.1 - MBT Turrets rework: the game's own tank hull, with everything above the roof line tied to
the hull's second gun mount (node b7e9b43d), which the MBT Turrets addon turns to the main gun's heading every frame.
The armour stays on the hull, so the game's own camo (hull slot a779745a) and damage looks (the hull's visibility
masks) apply to it; the guns, missile pods and smoke launchers stay the game's own units on their own mounts.

  build_mbt_hull.py TANK VANILLA_HULL_BASE OUT_BASE
    TANK: bastion | maelstrom; *_BASE: <path>.main / <path>.gpu
    VANILLA_HULL_BASE: the game's own hull unit, out of the game's own archives (Filediver): Bastion
    0x16474112801385b6, Maelstrom 0xb0c9faf4af8903f9 (unit type e0a48d0be9a7453f). Then pack_hulls.py writes the patch.
    (3.1.1) The 3.0.1 turret and gun inputs are gone: the deck and the turret floor have been made by the caps below
    since Test 10, and those files were loaded but never used.
    Byte for byte the release's hulls with shapely 2.1.2 / GEOS 3.13.1 and numpy 2.4.4 (see requirements.txt): the
    deck triangles come from GEOS's constrained Delaunay, which other versions may lay out differently.

Per skinned mesh (every visual and shadow LOD that has a skeleton map):
  - one skeleton-map slot whose bone carries only above-roof geometry (preferably a side case, l_box_0) is pointed at
    the second gun mount, with that node's inverse bind matrix (a translation in the mesh's space);
  - every vertex above the roof line is weighted 100% to that slot; triangles crossing the line are cut at it, the part
    above on the mount and the part below on the vertices' own bones (the original triangle is made degenerate);
  - the cut is closed by a deck (on the hull body bone) and a turret floor (on the mount); the mesh's bounds are grown
    for the turned turret.
The smallest shadow LOD has no such slot and is left as the game has it (a turret shadow that doesn't turn, far away).
(3.4.0) The deck copied over the old turret spot leaves out the copied strip's hatch. (3.4.0 leaned the front arms
inward; 3.4.1 keeps the game's angle, LEAN_ARMS.)
(3.4.1) The turret is cut level just over the roof line and its walls run straight down, rounded in, ending a small gap
over the deck with a recessed ring showing (Tests 8-15: LIP_CUT, BASE_GAP, ROUND_K); the hull plating is copied back
under it; its hatches keep working: each turret hatch rides a node MBT Turrets carries round with the turret
(HATCH_CARRY), the gunner's door split at the turret's base and swung open by the addon (Tests 16-18).
(3.6.1 Test 5) The old lip's ledge at the arms' root (a flat piece just over the gap level, reaching out past the side walls)
is dropped with the outer walls (OUT_CORNER): it showed as a small triangle sticking out under the turret's side.
Some switches below are kept off for the record of what was tried (LEAN_ARMS, BASE_BAND, DECK_PLAIN, DECK_LIFT): their
code doesn't run."""
import struct, sys, math, collections, os
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
from unitlib import Unit

TANKS = {
    # roof line in the hull meshes' own space; the second gun mount's world position; the hull body bone ('boss');
    # (3.4.0) arms: where the turret's two front arms start leaning (mesh y) and by how much (m of x per m of y)
    'bastion': {'roof': 2.24, 'mount': (0.0, -1.959, 2.525), 'boss_world': (0.0, 0.0, 1.162), 'arms': (-0.75, 0.40)},
    'maelstrom': {'roof': 0.5625, 'mount': (0.0, -1.959, 2.525), 'boss_world': (0.0, 0.0, 1.162), 'arms': (-1.0, 0.47)},
}
# (3.4.0) A user's idea: with MBT Turrets the gun no longer swings inside the turret, so the cut-aways on the inside of
# the turret's front arms (left by the game for the barrel's arc) aren't needed. Each arm's front is leaned inward, more
# the further forward: the inner edge comes out straight and the cut-away moves to the outer corner, so the turned
# turret sticks out less past the hull. A shear, not a mirror: the plates' art isn't flipped, nothing is turned inside
# out, and the arm stays joined to the turret behind the bend. Normals are sheared with it (inverse transpose).
ARM_MIN = 0.3              # m from the turret's middle: only the arms lean (nothing of the turret is closer there)
# (3.4.1, the tester: "return the turret model back to 3.4.0, change the front prong on the turret back to the vanilla angle
# they were at") The lean is off: the arms keep the game's own angle (and their inner cut-aways). Tests 3-7's lip
# removal is set aside too; Tests 8-17 below then reworked the turret's base, deck, hatches and gunner's door.
LEAN_ARMS = False
# (3.4.1 Test 8, the tester: "fix the lip on the turret so that its completely separated from the hull and looks like it
# was designed to be a 360 turret, rather than sliced off of the model") Behind the front arms, the turret's walls flare
# out in their lowest ~30 cm (the casemate's base, out to the hull's sides): the lip. The turret is cut level LIP_CUT
# over the roof line there, near and outside its body (its walls cut level at BODY_SECTIONS, LIP_INSET in), the part
# below dropped, and every near-upright wall cut there is run straight down to the turret floor as a skirt that keeps
# the wall's own look at the cut (its texture place, normal and tile). The turret floor and ring follow the body. The
# front arms (from LIP_FRONT behind where they start) already come straight down and are left as they are. The roof
# boxes (uv0 tiles 13-18) hang on the walls and are left whole.
LIP_CUT = 0.24
LIP_FRONT = 0.25
OUT_CORNER = True                   # (3.6.1 Test 5) low inside triangles with a corner past the walls go with the outer walls
# (3.4.1 Test 9, the tester: "the turret needs to not be a block into the hull, it needs to round off and have a small gap
# between it and the hull like an actual turret on a MBT") The turret now ends BASE_GAP over the deck everywhere, its
# outer walls rounded in (ROUND_K of the rounding's height) over the last stretch down; along the arms, whose fronts come
# down low, the cut eases to FRONT_CUT over FRONT_EASE. The turret ring shows in the gap, recessed.
BASE_GAP = 0.08
FRONT_CUT = 0.10
FRONT_EASE = 0.30
ROUND_K = 0.63
ROUND_STEPS = (35, 65, 90)
ROOM_FOR_ROUND = 14000               # (16-bit LODs: vertices left that the full round needs, with the deck and ring)
# (3.4.1 Test 10, the tester: "theres still some jaggedness where the lip used to be", "it should be completely smooth all
# around") Behind the arms the rounded base no longer follows the cut walls' own ins and outs: every skirt runs from its
# cut point down to one smooth curve, the body's outline at the cut with notches up to 2*BAND_BRIDGE bridged and its
# corners rounded SMOOTH_R, drawn in by the round's depth. A cut point farther than SMOOTH_REACH past that keeps its own
# way in. The base band is left out: it stood out of the recesses (black under the Maelstrom's side boxes), and with the
# skirts ending on one curve nothing is open without it (checked with holediff from above and just under the deck).
SMOOTH_R = 0.30
SMOOTH_REACH = 0.30
DECK_PLAIN = False                  # (Test 12 tried one plain plate under the turret; Test 13, the tester: "the hull texture is
                                    # missing that used to be underneath. its super noticable": the copied plating is back)
DECK_BEVEL = 0.06                   # (Test 13) flat-ish hull bevels down to this far under the roof line that reach the deck go too
DECK_LIFT = 0.0                     # (Test 13: 1.5 mm was tried for the wedges; dropping the flat bevels fixed them, and the
                                    # lift opened grazing slits at the deck's edge)
DECK_CLEAN = True                   # (Test 12) the hull's own bits that poked through the deck under the turret go: the low
                                    # ridges, the roof cut's leftover lip-foot slivers, and its cut points sink under the deck
DECK_RIDGE = 0.02                   # (Test 12) hull triangles inside the cut within these of the roof line go under the plate
DECK_RECESS = 0.015                 # (as before: lower bevels at the hull's edges show from the side)
BOX_BAY = 0.30                      # (the rear boxes stand on brackets 20-25 cm in front of their bay)
BASE_BAND = False
SKIRT_LOOK_UP = 0.08                # (Test 10) a skirt's look is the wall's this far over the cut (the game's art darkens
                                    # the walls' foot where the lip met them: the cut's own look showed as black slots)
LIP_LOW = 0.20
BAND_IN = 0.03
BAND_BRIDGE = 0.35                  # (the band bridges the roof boxes' notches in the body's outline, up to 70 cm wide)
LIP_INSET = 0.15
BODY_SECTIONS = (0.45, 0.6, 0.78)
SKIRT_NZ = 0.98
LIP_BRIDGE = 0.15


def body_footprint(U, mi, roof, sections=None):
    """(Test 8) the turret's body seen from above: its walls (not the roof boxes, the damage shells or the stumps)
    cut level at BODY_SECTIONS, each cut filled (gaps up to 30 cm bridged), joined, slits under 12 cm closed; the
    largest piece, holes filled"""
    import numpy as np
    from shapely.geometry import Polygon, LineString
    from shapely.ops import unary_union
    sections = sections or BODY_SECTIONS
    M = U.meshes[mi]; li = M.layout; segs = {z: [] for z in sections}
    for g, t in U.mesh_tris(mi, 0):
        ds = [U.decode(li, U.vertex(li, v)) for v in t]
        P = np.array([d['pos'] for d in ds])
        if (P[:, 2] <= roof + EPS).any(): continue
        tl = math.floor(ds[0]['uv0'][0]) + 32 * math.floor(1 - ds[0]['uv0'][1])
        if tl in range(2, 27, 2) or 13 <= tl <= 18 or tl >= 32: continue
        for zc in sections:
            dz = P[:, 2] - (roof + zc)
            if (dz > 0).all() or (dz < 0).all(): continue
            pts = [P[i, :2] + dz[i] / (dz[i] - dz[j]) * (P[j, :2] - P[i, :2]) for i, j in ((0, 1), (1, 2), (2, 0)) if (dz[i] > 0) != (dz[j] > 0)]
            if len(pts) == 2 and math.dist(pts[0], pts[1]) > 1e-6: segs[zc].append(LineString(pts))
    polys = []
    for zc, ss in segs.items():
        shape = unary_union(ss).buffer(LIP_BRIDGE)
        polys += [Polygon(g.exterior).buffer(-LIP_BRIDGE) for g in getattr(shape, 'geoms', [shape])]
    F = unary_union(polys).buffer(0.06).buffer(-0.06)
    return Polygon(max(getattr(F, 'geoms', [F]), key=lambda q: q.area).exterior)
# (3.4.0) The deck copy (Test 6-7) brought the hatch of the copied strip along: on the old turret spot it showed twice.
# Where the strip has it (x, and y from the strip's start), each copy takes the plain plating at the same place on the
# other side of the strip instead (the strip is the same left and right there).
HATCH = (-1.49, -0.47, 0.76, 1.76)
MOUNT_BONE, BOSS_BONE = 159, 46            # 0-based node indices in both hulls (b7e9b43d, 9b115563)
# (3.4.1 Test 16) Working hatches. The game slides its hatches open and shut by animating their bones (101 back_door, the
# gunner's door, slides 0.94 m up; 102 right_hatch and 103 left_hatch, the roof hatches, slide 0.91 m forward). Up to
# Test 15 the turret's hatches were tied to the turret mount like the rest of it, so they never moved. They now keep
# a bone of their own, so they still slide. Not the hatch bones themselves: the game's animation sets those every frame,
# so the turner can't carry them round with the turret. Each one's skeleton slot is turned over to a node the game
# doesn't animate (HATCH_CARRY: the seat effect nodes beside each hatch), and MBT Turrets puts that node every frame
# where the hatch would be on the turned turret: its own rest place carried round the turret's axis (and the Turret
# Position move) plus the hatch's slide read from the game's hatch bone. The slot's inverse bind is the carrier's own
# rest pose, so with the carrier at rest (the turner not running) the hatch is where the game has it. The whole gunner's
# door goes with the turret, its 31 cm under the roof line too (it slides up over the casemate's back wall; Test 15 cut
# it at the roof line and left its foot on the hull's back). The driver's hatch (104) is on the hull: left as it is.
KEEP_HATCHES = True
DOOR_SPLIT = True                   # (Test 17) the gunner's door split at the turret's base (see build)
HATCH_CARRY = {101: (200, (0.031258, -4.514132, 1.115169), 180),     # back_door -> fx_back_seat (turned 180 deg at rest)
               102: (199, (1.649954, -2.870157, 1.705128), 0),       # right_hatch -> fx_right_seat
               103: (198, (-1.590900, -2.870157, 1.705128), 0)}      # left_hatch -> fx_left_seat
HATCH_REST = {101: (-0.001715, -4.691677, 1.270034), 102: (1.616143, -2.799228, 2.072457), 103: (-1.616143, -2.799228, 2.072457)}
HATCH_SLIDE = {101: (0, 0, 0.942), 102: (0, 0.908, 0), 103: (0, 0.908, 0)}   # (the game's open pose less its shut one)
CARRIERS = {c[0] for c in HATCH_CARRY.values()}
PREFER = [99, 53, 98, 52, 96, 51]          # side cases l_box_0, r_box_0, l_box_1, r_box_1, l_box_2, r_box_2
EPS = 1e-5


def load(b): return Unit(open(b + '.main', 'rb').read(), open(b + '.gpu', 'rb').read())


def smap_table(d):
    """[(bones list, bones offset, matrices offset, [remap list per group])] by skeleton map index"""
    so = struct.unpack_from('<I', d, 88)[0]
    n = struct.unpack_from('<I', d, so)[0]
    out = []
    for o in struct.unpack_from('<%dI' % n, d, so + 4):
        b = so + o
        cnt, mo, io, ro = struct.unpack_from('<4I', d, b)
        rc = struct.unpack_from('<I', d, b + ro)[0]
        groups = []
        for j in range(rc):
            off, c = struct.unpack_from('<2I', d, b + ro + 4 + 8 * j)
            groups.append(list(struct.unpack_from('<%dI' % c, d, b + ro + off)))
        out.append((list(struct.unpack_from('<%dI' % cnt, d, b + io)), b + io, b + mo, groups))
    return out


def mesh_smap(U, M): return struct.unpack_from('<i', U.main, M.off + 8 + 24 + 4 * 6)[0]


def weight_one(bw):
    """the packed 10:10:10:2 weights with all of it on the first bone (the top 2 bits kept)"""
    w = struct.unpack('<I', bw)[0]
    return struct.pack('<I', (w & 0xC0000000) | 0x3FF)


def weights(bw):
    """the four bone weights (0..1023) of a packed 10:10:10:2 value: three stored, the fourth what is left"""
    w = struct.unpack('<I', bw)[0]
    w0, w1, w2 = w & 0x3FF, (w >> 10) & 0x3FF, (w >> 20) & 0x3FF
    return [w0, w1, w2, max(0, 1023 - w0 - w1 - w2)]


CAP_GAP = 0.003                            # the deck sits this far under the roof line, the turret floor this far over
# (3.4.0) The turret ring. The hull's deck in front of the game's turret lies 11-15 cm under the roof line, so with the
# turret moved forward (Turret Position) its front arms showed a gap over it (the tester: "the turret is still floating a
# bit"). Test 11 dropped the walls' cut edges straight down SKIRT m (texture stretched): "looks better, but it doesnt
# look natural, looks like its clipping into the hull". the tester picked a recessed ring (Test 15): the walls end at the roof
# line as in the game, and under them a plain band runs RING_IN m inside the walls, from the turret floor down SKIRT
# m, in the deck plating's own color (and camo mapping), so it reads as the ring the turret sits on. It follows the
# roof-line outline (the turret floor's) shrunk RING_IN and smoothed, so it is one clean band. At the game's place
# and angle it is behind the hull's walls and under the deck (hidden).
# (Test 19, the tester: "the ring under the turret of the tanks kind of clips into the taller side of the hull") The hull's
# deck in front of the old turret has raised parts near its sides (the Maelstrom's 5 cm under the roof line at 1.5-2 m
# out), and the band under the whole turret outline (5 m wide, the hull's front 4.4-4.9 m) poked out past the hull's
# sides as the turret turned. the tester picked the ring cut to a circle of RING_R round the turret's axis (2.0 m; 1.4 m, a
# real turret ring, left the arms floating again): it stays off the hull's sides at every angle, and only the outer
# edges and arm tips overhang it.
SKIRT, RING_IN, RING_R = 0.16, 0.05, 2.0


def oct_normal(raw):
    """the packed normal's direction (octahedral, 10+10 bits)"""
    v = struct.unpack('<I', raw)[0]
    x = (v & 0x3FF) / 1023 * 2 - 1; y = ((v >> 10) & 0x3FF) / 1023 * 2 - 1
    z = 1 - abs(x) - abs(y)
    if z < 0: x, y = (1 - abs(y)) * math.copysign(1, x), (1 - abs(x)) * math.copysign(1, y)
    n = math.sqrt(x * x + y * y + z * z) or 1
    return x / n, y / n, z / n


def oct_pack(n, raw):
    """n (a unit vector) packed as the game packs normals: 10+10 bits octahedral, the upper 12 bits kept from raw"""
    x, y, z = n
    s = abs(x) + abs(y) + abs(z)
    x, y, z = x / s, y / s, z / s
    if z < 0: x, y = (1 - abs(y)) * math.copysign(1, x), (1 - abs(x)) * math.copysign(1, y)
    qx = max(0, min(1023, round((x + 1) / 2 * 1023))); qy = max(0, min(1023, round((y + 1) / 2 * 1023)))
    v = struct.unpack('<I', raw)[0]
    return struct.pack('<I', (v & ~0xFFFFF) | qx | (qy << 10))


def lean_arm(d, x0, arms):
    """(3.4.0) a turret vertex (decoded) with the front arms leaned inward; None when it isn't on an arm's front"""
    yc, k = arms
    x, y, z = d['pos']
    if y <= yc or abs(x - x0) < ARM_MIN: return None
    s = 1 if x < x0 else -1                    # left arm moves right, right arm left
    nd = dict(d)
    nd['pos'] = (x + s * k * (y - yc), y, z)
    if 'normal' in d:
        nx, ny, nz = oct_normal(d['normal'])
        ny -= s * k * nx
        L = math.sqrt(nx * nx + ny * ny + nz * nz) or 1
        nd['normal'] = oct_pack((nx / L, ny / L, nz / L), d['normal'])
    return nd


def skin_shadow(U, mi, sm, boss_r):
    """(3.4.0) An unskinned shadow mesh (the Bastion's closest shadow, mesh 3) made skinned, so its turret part can turn
    and move with the turret like the other LODs: bone weights and indices are added to its own layout (the same items
    the skinned shadow layout has), every vertex 100% on the hull body (it never moved anything else before), and it
    uses skeleton map `sm` (the next shadow LOD's, whose turret slot is pointed at the mount). Before, its turret shadow
    stayed where the game's turret was and never turned (seen in game with the turret moved to the middle)."""
    M = U.meshes[mi]; li = M.layout
    assert [k for k, MM in enumerate(U.meshes) if MM.layout == li] == [mi], 'layout shared'
    L = U.layouts[li]
    n = struct.unpack_from('<I', U.main, L.off + 328)[0]
    assert n + 2 <= 16 and L.item(6) is None and L.item(7) is None
    struct.pack_into('<5I', U.main, L.off + 8 + 20 * n, 7, 29, 0, 0, 0)          # bone weights (10:10:10:2)
    struct.pack_into('<5I', U.main, L.off + 8 + 20 * (n + 1), 6, 28, 0, 0, 0)    # bone indices (4 x uint8)
    struct.pack_into('<I', U.main, L.off + 328, n + 2)
    old = L.stride
    L.items += [(7, 29, 0, old), (6, 28, 0, old + 4)]
    L.stride = old + 8
    one = struct.pack('<I', 0xC00003FF) + bytes([boss_r, 0, 0, 0])
    v = U.vbuf[li]
    U.vbuf[li] = b''.join(v[k:k + old] + one for k in range(0, len(v) // old * old, old))
    struct.pack_into('<i', U.main, M.off + 56, sm)


def find_panel(U, mi, roof):
    """A flat deck panel of the game's hull at the roof line (the 3.0.1 deck plates were tiled with it): its texture
    mapping (x, y) -> uv0, its rectangle, the winding that faces up, and packed normals facing up and down."""
    from shapely.geometry import Polygon
    from shapely.ops import unary_union
    M = U.meshes[mi]; li = M.layout; G = M.groups[0]
    idx = U.indices(li, G.io, G.ni)
    flat, up_raw, down_raw = [], None, None
    for t in range(0, len(idx) - 2, 3):
        ds = [U.decode(li, U.vertex(li, G.vo + k)) for k in idx[t:t + 3]]
        for d in ds:
            n = oct_normal(d['normal'])
            if n[2] > 0.999 and up_raw is None: up_raw = d['normal']
            if n[2] < -0.999 and down_raw is None: down_raw = d['normal']
        # flat, facing up, always drawn (tile 0), on the hull below the roof line (the deck plating)
        if max(d['pos'][2] for d in ds) - min(d['pos'][2] for d in ds) < 1e-3 and ds[0]['pos'][2] < roof \
                and all(math.floor(d['uv0'][0]) == 0 and math.floor(1 - d['uv0'][1]) == 0 for d in ds) \
                and all(oct_normal(d['normal'])[2] > 0.99 for d in ds):
            flat.append(ds)
    assert flat and up_raw and down_raw, 'no flat deck panel'
    # the mapping from the largest flat triangle; the panel = the connected flat area with that same mapping
    def area(ds): (ax, ay), (bx, by), (cx, cy) = [d['pos'][:2] for d in ds]; return (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
    ref = max(flat, key=lambda ds: abs(area(ds)) if abs(area(ds)) > 0 else 0)
    import numpy as np
    A = np.array([[d['pos'][0], d['pos'][1], 1] for d in ref]); B = np.array([d['uv0'] for d in ref])
    Mx = np.linalg.solve(A, B)                                   # 3x2: [x y 1] @ Mx = uv
    same = [ds for ds in flat if all(np.allclose(np.array([d['pos'][0], d['pos'][1], 1]) @ Mx, d['uv0'], atol=2e-3) for d in ds)]
    shape = unary_union([Polygon([d['pos'][:2] for d in ds]) for ds in same]).buffer(1e-4)
    geom = max(getattr(shape, 'geoms', [shape]), key=lambda g: g.area)
    rect = geom.bounds
    return {'map': Mx, 'rect': rect, 'z': ref[0]['pos'][2], 'area': geom.area, 'up_sign': 1 if area(ref) > 0 else -1, 'up_raw': up_raw, 'down_raw': down_raw,
            'ref_area': abs(area(ref))}


def deck_look(U, mi, roof):
    """(3.3.0 Test 5) How the game's own deck plating is textured, for the caps: uv1 (the camo pattern's mapping) is a
    flat projection of x/y on the up-facing deck, uv2 (where the material's wear/color table is read) and the vertex color
    are the same all over it. Fitted from the mesh's own up-facing vertices within 20 cm under the roof line. Before,
    the caps copied one turret-wall vertex's uv1/uv2/color everywhere: one flat camo color and a wall's shading, which
    showed once the turret was moved off it (it didn't look right with the turret centered)."""
    import numpy as np
    M = U.meshes[mi]; li = M.layout
    up = []
    for G in M.groups:
        for k in set(U.indices(li, G.io, G.ni)):
            d = U.decode(li, U.vertex(li, G.vo + k))
            if roof - 0.2 < d['pos'][2] <= roof + EPS and oct_normal(d['normal'])[2] > 0.99: up.append(d)
    if len(up) < 50: return None
    out = {'n': len(up), 'err': 0.0}                 # (lower LODs may lack some of these: only what the layout has)
    if 'uv1' in up[0]:
        A = np.array([[d['pos'][0], d['pos'][1], 1] for d in up])
        out['uv1'] = np.linalg.lstsq(A, np.array([d['uv1'] for d in up]), rcond=None)[0]
        out['err'] = float(np.percentile(np.abs(A @ out['uv1'] - np.array([d['uv1'] for d in up])), 90))
    if 'uv2' in up[0]: out['uv2'] = tuple(float(x) for x in np.median(np.array([d['uv2'] for d in up]), 0))
    if 'color' in up[0]: out['color'] = collections.Counter(d['color'] for d in up).most_common(1)[0][0]
    return out


def cap_outline(V, G0, idx_all, roof):
    """the hull's outline where it crosses the roof line, filled (gaps up to 30 cm in the walls bridged)"""
    from shapely.geometry import LineString, Polygon
    from shapely.ops import unary_union
    segs = []
    for t in range(0, len(idx_all) - 2, 3):
        ps = [V(G0.vo + k)['pos'] for k in idx_all[t:t + 3]]
        ab = [p[2] > roof + EPS for p in ps]
        if all(ab) or not any(ab): continue
        pts = []
        for i in range(3):
            a, b = ps[i], ps[(i + 1) % 3]
            if ab[i] != ab[(i + 1) % 3]:
                tt = (roof - a[2]) / (b[2] - a[2]); pts.append((a[0] + (b[0] - a[0]) * tt, a[1] + (b[1] - a[1]) * tt))
        if len(pts) == 2 and math.dist(*pts) > 1e-6: segs.append(LineString(pts))
    lines = unary_union(segs)
    x0, y0, x1, y1 = lines.bounds
    best = None
    for R in (0.15, 0.3, 0.5):                          # small LODs have wider gaps: bridge more until it closes
        shape = lines.buffer(R)
        filled = unary_union([Polygon(g.exterior) for g in getattr(shape, 'geoms', [shape])]).buffer(-R)
        best = max(getattr(filled, 'geoms', [filled]), key=lambda g: g.area)
        if best.area > 0.65 * (x1 - x0) * (y1 - y0): break
    return best


def add_cap(U, li, outline, z, up, slot_r, tpl, panel, new_v, new_t, base, look=None, plain=False):
    """Fill `outline` at height z, tiled with the deck panel's texture; up: facing up (else down). Appends to
    new_v / new_t (group-relative indices from base). Returns the triangle count."""
    import shapely
    from shapely.geometry import box
    import numpy as np
    x0, y0, x1, y1 = panel['rect']; w, h = x1 - x0, y1 - y0
    bx0, by0, bx1, by1 = outline.bounds
    if plain:          # (Test 6) one piece, the panel's middle color all over (few vertices: under the copied deck)
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        outline = outline.simplify(0.003, preserve_topology=True)       # (3 mm: hidden under the walls)
        x0, y0, w, h = bx0 - 1, by0 - 1, bx1 - bx0 + 2, by1 - by0 + 2
    want = panel['up_sign'] if up else -panel['up_sign']
    n = 0; cache = {}
    for i in range(math.floor((bx0 - x0) / w), math.ceil((bx1 - x0) / w) + 1):
        for j in range(math.floor((by0 - y0) / h), math.ceil((by1 - y0) / h) + 1):
            cell = box(x0 + i * w, y0 + j * h, x0 + (i + 1) * w, y0 + (j + 1) * h)
            piece = outline.intersection(cell)
            if piece.is_empty or piece.area < 1e-6: continue
            for poly in getattr(piece, 'geoms', [piece]):
                if poly.geom_type != 'Polygon' or poly.area < 1e-6: continue
                for tri in shapely.constrained_delaunay_triangles(poly).geoms:
                    if not poly.buffer(1e-6).contains(tri.centroid): continue
                    c = list(tri.exterior.coords)[:3]
                    s = (c[1][0] - c[0][0]) * (c[2][1] - c[0][1]) - (c[2][0] - c[0][0]) * (c[1][1] - c[0][1])
                    if abs(s) < 1e-9: continue
                    if (s > 0) != (want > 0): c = [c[0], c[2], c[1]]
                    ids = []
                    for (x, y) in c:
                        key = (round(x, 5), round(y, 5), i, j)
                        if key not in cache:
                            uv = np.array([cx, cy, 1]) @ panel['map'] if plain else np.array([x - i * w, y - j * h, 1]) @ panel['map']
                            nv = dict(tpl)
                            nv['pos'] = (x, y, z); nv['uv0'] = (float(uv[0]), float(uv[1]))
                            nv['normal'] = panel['up_raw'] if up else panel['down_raw']
                            if look:                     # (3.3.0 Test 5) the deck's own camo mapping and shading
                                if 'uv1' in look and 'uv1' in nv: nv['uv1'] = tuple(float(q) for q in np.array([x, y, 1]) @ look['uv1'])
                                for k in ('uv2', 'color'):
                                    if k in look and k in nv: nv[k] = look[k]
                            nv['bidx'] = bytes([slot_r, 0, 0, 0]); nv['bw'] = struct.pack('<I', 0xC00003FF)
                            cache[key] = base + len(new_v); new_v.append(U.encode(li, nv))
                        ids.append(cache[key])
                    new_t.append(tuple(ids)); n += 1
    return n


def add_ring(U, li, outline, roof, slot_r, tpl, panel, look, new_v, new_t, base, shadow, axis, top=None):
    """(Test 15) The turret ring: the roof-line outline (the turret floor's) shrunk RING_IN all round and smoothed, run
    as an upright band from the turret floor down SKIRT, facing out, in the deck plating's plain color (and the deck's
    camo mapping and shading). Returns the triangle count; -1 when a 16-bit LOD has no room for it."""
    import numpy as np
    from shapely.geometry.polygon import orient
    if shadow: return 0          # (a shadow LOD: the turret floor's shadow covers the ring's)
    from shapely.geometry import Point
    inner = outline.buffer(-RING_IN, join_style=2).intersection(Point(axis[0], axis[1]).buffer(RING_R, 48))
    inner = inner.simplify(0.01, preserve_topology=True)
    rings = []
    for poly in getattr(inner, 'geoms', [inner]):
        if poly.geom_type != 'Polygon' or poly.area < 0.05: continue
        pts = list(orient(poly, 1.0).exterior.coords)[:-1]          # counter-clockwise seen from above
        if len(pts) >= 3: rings.append(pts)
    need = sum(2 * len(r) for r in rings)
    if U.layouts[li].isz == 2 and base + len(new_v) + need > 65535: return -1
    cx, cy = (panel['rect'][0] + panel['rect'][2]) / 2, (panel['rect'][1] + panel['rect'][3]) / 2
    uv = np.array([cx, cy, 1]) @ panel['map']
    n = 0
    for pts in rings:
        m = len(pts)
        ids = []
        for i, (x, y) in enumerate(pts):
            (px, py), (qx, qy) = pts[i - 1], pts[(i + 1) % m]
            nx, ny = (qy - py), -(qx - px)                           # outward on a counter-clockwise ring
            h = math.hypot(nx, ny) or 1.0
            pair = []
            for z in (roof + CAP_GAP if top is None else top, roof - SKIRT):
                nv = dict(tpl)
                nv['pos'] = (x, y, z); nv['uv0'] = (float(uv[0]), float(uv[1]))
                if 'normal' in nv: nv['normal'] = oct_pack((nx / h, ny / h, 0.0), nv['normal'])
                if look:
                    if 'uv1' in look and 'uv1' in nv: nv['uv1'] = tuple(float(q) for q in np.array([x, y, 1]) @ look['uv1'])
                    for kk in ('uv2', 'color'):
                        if kk in look and kk in nv: nv[kk] = look[kk]
                nv['bidx'] = bytes([slot_r, 0, 0, 0]); nv['bw'] = struct.pack('<I', 0xC00003FF)
                pair.append(base + len(new_v)); new_v.append(U.encode(li, nv))
            ids.append(pair)
        # facing out: the winding whose normal points out when the deck's up-facing winding is counter-clockwise
        # (up_sign 1), the other way round otherwise
        for i in range(m):
            (t0, b0), (t1, b1) = ids[i], ids[(i + 1) % m]
            if panel['up_sign'] > 0: new_t += [(t0, b1, t1), (t0, b0, b1)]
            else: new_t += [(t0, t1, b1), (t0, b1, b0)]
            n += 2
    return n


DECK_STRIP = 2.4          # (Test 6) m of the hull's own front deck copied per band
DECK_UNDER = 0.004        # (Test 6) the tiled panel fill sits this much under the copied deck (shows only in its gaps)


def deck_source(U, mi, outline, roof):
    """(Test 6) The up-facing deck triangles (group 0) of mesh `mi` in the strip just in front of the cut."""
    M = U.meshes[mi]; li = M.layout; G0 = M.groups[0]
    idx_all = U.indices(li, G0.io, G0.ni)
    s0 = outline.bounds[3] + 0.35
    dec = {}
    def V(k):
        if k not in dec: dec[k] = U.decode(li, U.vertex(li, G0.vo + k))
        return dec[k]
    src = []
    for t in range(0, len(idx_all) - 2, 3):
        tri = idx_all[t:t + 3]
        if tri[0] == tri[1] or tri[1] == tri[2] or tri[0] == tri[2]: continue
        ds = [V(k) for k in tri]
        P = [d['pos'] for d in ds]
        if max(p[2] for p in P) > roof + EPS or min(p[2] for p in P) < roof - 0.25: continue
        if max(p[1] for p in P) < s0 or min(p[1] for p in P) > s0 + DECK_STRIP: continue
        (ax, ay, az), (bx, by, bz), (cx, cy, cz) = P
        nz = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
        ux, uy, uz, vx, vy, vz = bx - ax, by - ay, bz - az, cx - ax, cy - ay, cz - az
        n = ((uy * vz - uz * vy) ** 2 + (uz * vx - ux * vz) ** 2 + nz ** 2) ** 0.5
        if n < 1e-9 or nz / n < 0.9: continue           # up-facing only (plates, not the walls of their details)
        # (Test 7) the hull material shows geometry by uv0's whole-number tile: 0 always, odd tiles = intact panels, the
        # even tile above each = its damaged copy in the same place (hidden until that panel is hit), 13-18 the roof
        # boxes. Test 6 copied both shells of every panel on top of each other (they flickered) and,
        # highest first, could keep a hidden damaged shell over the intact one. Only always-drawn and intact pieces are
        # copied, moved to tile 0 (the textures use the fraction), so the copy is always drawn and never doubled.
        tiles = {(math.floor(d['uv0'][0]), math.floor(1 - d['uv0'][1])) for d in ds}
        if len(tiles) != 1: continue
        tu, tv = tiles.pop()
        if tv != 0 or not (tu == 0 or (tu % 2 == 1 and not 13 <= tu <= 18)): continue
        src.append((ds, tu, tv))
    # (3.4.0) the strip's hatch is left out of the copies: there the plain plating from the other side is copied instead
    from shapely.geometry import box
    hx0, hx1, hy0, hy1 = HATCH
    hatch = box(hx0, s0 + hy0, hx1, s0 + hy1)
    out = []
    for ds, tu, tv in src:
        P = [d['pos'] for d in ds]
        if not (max(p[0] for p in P) < hx0 or min(p[0] for p in P) > hx1 or max(p[1] for p in P) < s0 + hy0 or min(p[1] for p in P) > s0 + hy1):
            out.append((ds, tu, tv, ('out', hatch), 0.0))
        else: out.append((ds, tu, tv, None, 0.0))
        P = [d['pos'] for d in ds]                     # the other side's plating, moved over the hatch
        dx = hx0 + hx1
        if not (max(p[0] for p in P) + dx < hx0 or min(p[0] for p in P) + dx > hx1 or max(p[1] for p in P) < s0 + hy0 or min(p[1] for p in P) > s0 + hy1):
            out.append((ds, tu, tv, ('in', hatch), -dx))
    return out


def add_deck_copy(U, li, src, outline, z, up_sign, slot_r, tpl, look, new_v, new_t, base, roof):
    """(Test 6) Covers `outline` with the hull's own deck plating: the up-facing deck triangles of the strip just in front
    of the cut (DECK_STRIP long, within 25 cm under the roof line, group 0's material) are copied back over the cut in
    bands, flattened to z, clipped to the outline. Every attribute is interpolated from the source triangle (uv0 plate
    art, uv2, color, normal) except uv1, the camo pattern's flat projection, which is worked out at the new place so the
    pattern runs on. Test 5: the texture didn't match the hull (the tiled 2 m2 panel showed grilles and
    seams the hull's deck doesn't have). Returns (triangles, area covered)."""
    import shapely, shapely.affinity
    import numpy as np
    from shapely.geometry import Polygon, box
    from shapely.ops import unary_union
    bx0, by0, bx1, by1 = outline.bounds
    s0 = by1 + 0.35                                      # the source strip: [s0, s0 + DECK_STRIP]
    if not src: return 0, None
    # (Test 7) highest first, and each piece minus what is already covered: no two copied pieces overlap once flattened
    # (Test 6 copied stacked plates on top of each other: they fought for the same depth and flickered, seen in a screenshot)
    src = sorted(src, key=lambda e: -max(d['pos'][2] for d in e[0]))
    from shapely.strtree import STRtree
    n_tris = 0; covered = []; cache = {}
    keys = [k for k in ('uv0', 'uv2') if k in tpl]
    j = 0
    while by1 - j * DECK_STRIP > by0 - 1e-6:
        top = by1 - j * DECK_STRIP
        band = outline.intersection(box(bx0 - 1, top - DECK_STRIP, bx1 + 1, top))
        shift = s0 + DECK_STRIP - top                    # target y + shift = source y
        j += 1
        if band.is_empty: continue
        taken = []                                       # this band's accepted pieces (checked through a grid)
        grid = {}
        def cells(g):
            x0, y0, x1, y1 = g.bounds
            return [(i, k) for i in range(int(math.floor(x0 / 0.25)), int(math.floor(x1 / 0.25)) + 1)
                    for k in range(int(math.floor(y0 / 0.25)), int(math.floor(y1 / 0.25)) + 1)]
        for sid, (ds, tu, tv, clip, xs) in enumerate(src):
            P = [(d['pos'][0] - xs, d['pos'][1], d['pos'][2]) for d in ds]      # (3.4.0) xs: taken from the other side
            sp = Polygon([(p[0], p[1]) for p in P])
            if clip is not None:                          # (3.4.0) the hatch: left out, or only the stand-in over it
                sp = sp.difference(clip[1]) if clip[0] == 'out' else sp.intersection(clip[1])
                if sp.is_empty or sp.area < 1e-8: continue
            tp = shapely.affinity.translate(sp, 0, -shift)
            if not tp.is_valid or tp.area < 1e-8: continue
            piece = band.intersection(tp)
            if piece.is_empty or piece.area < 1e-8: continue
            near = {id(g): g for c in cells(piece) for g in grid.get(c, ())}
            for g in near.values():
                if piece.intersects(g): piece = piece.difference(g)
                if piece.is_empty: break
            if piece.is_empty or piece.area < 1e-6: continue
            piece = shapely.set_precision(piece, 1e-6)
            if piece.is_empty: continue
            for c in cells(piece): grid.setdefault(c, []).append(piece)
            (ax, ay, _), (bx, by, _), (cx, cy, _) = P
            det = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            def bary(x, y):
                y = y + shift
                l1 = ((by - cy) * (x - cx) + (cx - bx) * (y - cy)) / det
                l2 = ((cy - ay) * (x - cx) + (ax - cx) * (y - cy)) / det
                return l1, l2, 1 - l1 - l2
            for poly in getattr(piece, 'geoms', [piece]):
                if poly.geom_type != 'Polygon' or poly.area < 1e-8: continue
                covered.append(poly)
                for tri in shapely.constrained_delaunay_triangles(poly).geoms:
                    if not poly.buffer(1e-6).contains(tri.centroid): continue
                    c = list(tri.exterior.coords)[:3]
                    sgn = (c[1][0] - c[0][0]) * (c[2][1] - c[0][1]) - (c[2][0] - c[0][0]) * (c[1][1] - c[0][1])
                    if abs(sgn) < 1e-10: continue
                    if (sgn > 0) != (up_sign > 0): c = [c[0], c[2], c[1]]
                    ids = []
                    for (x, y) in c:
                        key = (sid, j, round(x, 5), round(y, 5))   # (shared by the triangles of one clipped piece)
                        if key in cache: ids.append(cache[key]); continue
                        w = bary(x, y)
                        nv = dict(tpl)
                        nv['pos'] = (x, y, z)
                        for k in keys:
                            if k not in ds[0]: continue          # (a source LOD without it: the template's)
                            nv[k] = tuple(sum(w[i] * ds[i][k][q] for i in range(3)) for q in range(len(ds[0][k])))
                            if k == 'uv0': nv[k] = (nv[k][0] - tu, nv[k][1] + tv)       # (Test 7) to tile 0
                        if 'color' in tpl and 'color' in ds[0]: nv['color'] = ds[max(range(3), key=lambda i: w[i])]['color']
                        nv['normal'] = ds[max(range(3), key=lambda i: w[i])]['normal']
                        if look and 'uv1' in look and 'uv1' in nv: nv['uv1'] = tuple(float(q) for q in np.array([x, y, 1]) @ look['uv1'])
                        nv['bidx'] = bytes([slot_r, 0, 0, 0]); nv['bw'] = struct.pack('<I', 0xC00003FF)
                        cache[key] = base + len(new_v); ids.append(cache[key]); new_v.append(U.encode(li, nv))
                    new_t.append(tuple(ids)); n_tris += 1
    return n_tris, unary_union(covered) if covered else None


def add_band(U, li, poly, keep, z0, z1, slot_r, tpl, panel, look, new_v, new_t, base, shadow, looks=None):
    """(Test 8) an upright plain band from z0 up to z1 along poly's outline (counter-clockwise, facing out), only where
    the outline lies inside `keep`, in the deck plating's plain color and camo mapping, on the mount (slot_r). It stands
    just inside the cut walls' skirts and closes the turret's base where nothing else does (under the roof boxes, which
    stand in for the wall there). Returns the triangle count; -1 when a 16-bit LOD has no room for it."""
    import numpy as np
    from shapely.geometry.polygon import orient
    from shapely.geometry import Point
    if shadow: return 0
    segs = []
    for pg in getattr(poly, 'geoms', [poly]):              # (every piece's outline)
        if pg.geom_type != 'Polygon' or pg.area < 0.05: continue
        pg = orient(pg.simplify(0.01, preserve_topology=True), 1.0)
        cut = pg.exterior.intersection(keep)               # the outline's pieces inside keep
        for piece in getattr(cut, 'geoms', [cut]):
            if piece.geom_type != 'LineString': continue
            c = list(piece.coords)
            segs += [(c[i], c[i + 1], pg.centroid) for i in range(len(c) - 1) if math.dist(c[i], c[i + 1]) > 1e-4]
    need = 2 * (len(getattr(lip_cut, 'steps', ROUND_STEPS)) + 1) * len(segs)
    if U.layouts[li].isz == 2 and base + len(new_v) + need > 65535: return -1
    cx, cy = (panel['rect'][0] + panel['rect'][2]) / 2, (panel['rect'][1] + panel['rect'][3]) / 2
    uv = np.array([cx, cy, 1]) @ panel['map']
    LP = np.array([d['pos'][:2] for d in looks]) if looks else None
    n = 0
    for (x0, y0), (x1, y1), ctr in segs:
        nx, ny = (y1 - y0), -(x1 - x0); h = math.hypot(nx, ny) or 1.0
        if nx * ((x0 + x1) / 2 - ctr.x) + ny * ((y0 + y1) / 2 - ctr.y) < 0:      # (facing out: flipped if a piece runs backwards)
            (x0, y0), (x1, y1) = (x1, y1), (x0, y0); nx, ny = -nx, -ny
        src = None
        if LP is not None:                                 # (the wall's own look, from the nearest cut point: one texture place)
            src = looks[int(np.argmin(np.hypot(LP[:, 0] - (x0 + x1) / 2, LP[:, 1] - (y0 + y1) / 2)))]
        ids = []
        H = z1 - z0; prof = [(0.0, 0.0, 0.0)] + profile(ROUND_K * H, H, getattr(lip_cut, 'steps', None))       # (Test 9: rounded in like the skirts)
        for (x, y) in ((x0, y0), (x1, y1)):
            pair = []
            tg = smooth_target(x, y, ROUND_K * H)               # (Test 10) down to the smooth curve, like the skirts
            for inset, drop, ang in prof:
                z = z1 - drop
                nv = dict(tpl) if src is None else dict(src)
                if tg is None: nv['pos'] = (x - nx / h * inset, y - ny / h * inset, z)
                else:
                    f = inset / (ROUND_K * H) if H > 1e-9 else 1.0
                    nv['pos'] = (x + (tg[0] - x) * f, y + (tg[1] - y) * f, z)
                if src is None: nv['uv0'] = (float(uv[0]), float(uv[1]))
                tilt = ang * 0.75
                if 'normal' in nv: nv['normal'] = oct_pack((nx / h * math.cos(tilt), ny / h * math.cos(tilt), -math.sin(tilt)), nv['normal'])
                if look and src is None:
                    if 'uv1' in look and 'uv1' in nv: nv['uv1'] = tuple(float(q) for q in np.array([x, y, 1]) @ look['uv1'])
                    for kk in ('uv2', 'color'):
                        if kk in look and kk in nv: nv[kk] = look[kk]
                nv['bidx'] = bytes([slot_r, 0, 0, 0]); nv['bw'] = struct.pack('<I', 0xC00003FF)
                pair.append(base + len(new_v)); new_v.append(U.encode(li, nv))
            ids.append(pair)
        A, Bc = ids
        for q in range(len(A) - 1):
            t0, b0, t1, b1 = A[q], A[q + 1], Bc[q], Bc[q + 1]
            if panel['up_sign'] > 0: new_t += [(t0, b1, t1), (t0, b0, b1)]
            else: new_t += [(t0, t1, b1), (t0, b1, b0)]
            n += 2
    return n


def profile(R, H, steps=None):
    """(Test 9) the rounded base's rows below a cut point: (inset, drop, normal tilt) for each step down a quarter round,
    R in and H down at the bottom"""
    return [(R * (1 - math.cos(a)), H * math.sin(a), a) for a in (math.radians(d) for d in (steps or ROUND_STEPS))]


def smooth_base(base_foot):
    """(Test 10) the smooth outline the rounded base ends on (before the round's inset): base_foot with notches bridged
    and corners rounded"""
    S = base_foot.buffer(BAND_BRIDGE).buffer(-BAND_BRIDGE)
    S = S.buffer(-SMOOTH_R).buffer(SMOOTH_R)
    return max(getattr(S, 'geoms', [S]), key=lambda q: q.area)


def smooth_target(x, y, R):
    """(Test 10) where a rounded column from (x, y) ends: the nearest point of the smooth outline drawn in by R (the
    round's depth), or None (no smooth outline, or the point is too far from it)"""
    from shapely.geometry import Point
    from shapely.ops import nearest_points
    S = getattr(lip_cut, 'smooth', None)
    if S is None: return None
    cache = lip_cut.__dict__.setdefault('_curves', {})
    q = round(R, 3)
    if q not in cache: cache[q] = (S.buffer(-q) if q > 0 else S).exterior
    b = nearest_points(cache[q], Point(x, y))[0]
    if math.hypot(b.x - x, b.y - y) > R + SMOOTH_REACH: return None
    return b.x, b.y


def box_footprint(U, mi, roof):
    """(Test 12) the roof boxes (uv tiles 13-18) seen from above, BOX_BAY wider: the bay each box sits in. Its walls were
    split by the body test (half the triangles of one wall cut at the lip, half kept to the gap: the wedges under the
    rear boxes), so all of a bay counts as outer"""
    from shapely.geometry import Polygon
    from shapely.ops import unary_union
    M = U.meshes[mi]; li = M.layout; polys = []
    for g, t in U.mesh_tris(mi, 0):
        ds = [U.decode(li, U.vertex(li, v)) for v in t]
        tl = math.floor(ds[0]['uv0'][0]) + 32 * math.floor(1 - ds[0]['uv0'][1])
        if not 13 <= tl <= 18 or min(d['pos'][2] for d in ds) <= roof + EPS: continue
        pg = Polygon([d['pos'][:2] for d in ds])
        if pg.area > 1e-6: polys.append(pg.buffer(0.002))
    return unary_union(polys).buffer(BOX_BAY) if polys else None


def lip_cut(U, li, M, G0, V, new_v, new_t, r, roof, foot, cfg, put_index, ib, idx_all):
    """(Test 8, 9) the turret's base. Every turret triangle near or outside the body's outer walls is cut level at the
    lip cut (LIP_CUT behind the arms, easing to FRONT_CUT along them); the part below is dropped and each cut edge runs
    down a rounded skirt (ROUND_K of its height in, see profile) to BASE_GAP over the roof line, keeping the cut's look.
    Every other turret triangle (inside: the gun well, the gun mount) is cut level at BASE_GAP. So the whole turret ends
    BASE_GAP over the hull's deck with a rounded bottom edge, like a turret on its ring. Works on group 0's turret
    triangles: the game's own (still in the index buffer) and the roof cut's (new_t, corners on the mount). Sets
    lip_cut.floor (the turret's underside outline) and lip_cut.looks (cut points, for the base band). Returns a report
    line, or None when nothing was cut."""
    from shapely.geometry import Point, LineString, Polygon
    from shapely.ops import unary_union
    L = U.layouts[li]; isz = L.isz
    ya = cfg['arms'][0]
    zg = roof + BASE_GAP
    lip_cut.out_corner = 0
    def zc_at(y):                                       # the outer cut: LIP_CUT behind the arms, easing to FRONT_CUT
        t = min(max((y - ya) / FRONT_EASE, 0.0), 1.0)
        return roof + LIP_CUT + (FRONT_CUT - LIP_CUT) * t
    inner = foot.convex_hull.buffer(-LIP_INSET)
    # (Test 11) the convex hull only stands in for the body around the gun well (the notch in the body's outline that
    # opens to the front; Test 8: its walls are inside). Elsewhere a wall counts as outer by the body itself: the rear
    # walls beside the Maelstrom's and Bastion's rear center block sat up to 15 cm inside the hull, so they were cut
    # straight at the gap like the gun well, the old lip's flare still on them (the wedges under the rear boxes)
    from shapely.ops import unary_union as _uu
    _notch = foot.convex_hull.difference(foot)
    well = _uu([g for g in getattr(_notch, 'geoms', [_notch]) if g.bounds[3] >= foot.bounds[3] - 0.3]).buffer(0.15)
    body_in = foot.buffer(-LIP_INSET)
    bays = getattr(lip_cut, 'boxes', None)
    def inside(x, y):
        P_ = Point(x, y)
        if bays is not None and bays.contains(P_): return False   # (Test 12) the bay under a roof box: all outer
        return inner.contains(P_) if well.contains(P_) else body_in.contains(P_)
    outer_body = foot.buffer(0.03)
    nd = {}
    def D(k):                                           # group-relative vertex, decoded
        if k < G0.nv: return V(G0.vo + k)
        if k not in nd: nd[k] = U.decode(li, new_v[k - G0.nv])
        return nd[k]
    hk = getattr(lip_cut, 'hatch', None) or ()       # (Test 16) the hatches' vertices: not the mount's, left whole
    def on_mount(k):
        d = D(k)
        return (d['pos'][2] > roof + EPS and k not in hk) if k < G0.nv else d['bidx'][0] == r
    def tile(d): return math.floor(d['uv0'][0]) + 32 * math.floor(1 - d['uv0'][1])
    def is_outer(tri):
        ds = [D(k) for k in tri]
        if any(13 <= tile(d) <= 18 for d in ds): return False      # the roof boxes hang on the walls: left whole
        cx = sum(d['pos'][0] for d in ds) / 3; cy = sum(d['pos'][1] for d in ds) / 3
        if not inside(cx, cy): return True
        # (3.6.1 Test 5, the tester: "theres a triangle sticking out of the turret") a low triangle whose middle is inside but
        # with a corner out past the body's walls: the old lip's ledge at the arms' root (Maelstrom: z +0.08, out to
        # x -2.39 / +2.41 where the walls stand at 2.21) sits just over the gap level, so it was kept whole: a flat wedge
        # sticking out under the turret's side once it turned. A triangle all within 1 cm over the gap with a corner
        # out past the rounded base's outline (the ledge and the 2 mm edge the gap cut left of its front) goes with the
        # outer walls, under their cut: dropped.
        if OUT_CORNER and max(d['pos'][2] for d in ds) < zg + 0.01 and any(not out_line.contains(Point(d['pos'][0], d['pos'][1])) for d in ds):
            lip_cut.out_corner = getattr(lip_cut, 'out_corner', 0) + 1
            if os.getenv('OUTDBG'): print('   out-corner', tuple(tri), [tuple(round(q, 3) for q in d['pos']) for d in ds], tile(ds[0]))
            return True
        # (Test 14) an inner wall within the round's reach (behind the arms): it would hang out under the rounded base
        # (the side cases' inner walls showed their backs there). Cut at the outer level, no skirt of its own
        if round_in is not None and cy < ya and not round_in.contains(Point(cx, cy)) and not well.contains(Point(cx, cy)):
            P_ = [d['pos'] for d in ds]                 # (only walls facing in, toward the body's middle: the backs)
            ux, uy, uz = (P_[1][q] - P_[0][q] for q in range(3)); vx, vy, vz = (P_[2][q] - P_[0][q] for q in range(3))
            nx_, ny_ = uy * vz - uz * vy, uz * vx - ux * vz
            if nx_ * (cx - body_c.x) + ny_ * (cy - body_c.y) < 0: return 'hid'
        return False
    body_c = foot.centroid
    _S = getattr(lip_cut, 'smooth', None)
    round_in = _S.buffer(-(ROUND_K * (LIP_CUT - BASE_GAP) + 0.02)) if _S is not None else None
    out_line = _S.buffer(0.01) if _S is not None else outer_body          # (3.6.1 Test 5)
    cache = {}; up_look = {}
    def cut(a, b, outer):
        key = (min(a, b), max(a, b), outer)
        if key in cache: return cache[key]
        da, db = D(a), D(b)
        lv = (lambda y: zc_at(y)) if outer else (lambda y: zg)
        ga, gb = da['pos'][2] - lv(da['pos'][1]), db['pos'][2] - lv(db['pos'][1])
        t = ga / (ga - gb)
        nv = {}
        for k in da:
            if k == 'pos' or k.startswith('uv'): nv[k] = tuple(da[k][i] + (db[k][i] - da[k][i]) * t for i in range(len(da[k])))
            else: nv[k] = da[k] if t < 0.5 else db[k]
        nv['pos'] = (nv['pos'][0], nv['pos'][1], lv(nv['pos'][1]))
        if 'normal' in da and 'normal' in db:
            na, nb = oct_normal(da['normal']), oct_normal(db['normal'])
            n = tuple(na[i] + (nb[i] - na[i]) * t for i in range(3)); h = math.sqrt(sum(q * q for q in n)) or 1
            nv['normal'] = oct_pack(tuple(q / h for q in n), da['normal'])
        nv['bidx'] = bytes([r, 0, 0, 0]); nv['bw'] = weight_one(da['bw'])
        idx = G0.nv + len(new_v); new_v.append(U.encode(li, nv)); nd[idx] = nv
        cache[key] = idx
        if outer:                                       # (Test 10) the look SKIRT_LOOK_UP over the cut, on the same edge
            dz = da['pos'][2] - db['pos'][2]
            tu = min(max(t - SKIRT_LOOK_UP / dz, 0.0), 1.0) if abs(dz) > 1e-6 else t
            up_look[idx] = {k: tuple(da[k][i] + (db[k][i] - da[k][i]) * tu for i in range(len(da[k]))) for k in da if k == 'uv0'}
        return idx
    def clip(tri, outer):
        """the part of tri over its cut level (polygon, winding kept) and its cut edge (in polygon order)"""
        ds = [D(k) for k in tri]
        # (Test 14) small parts are dropped whole as pieces (rails, lamps: their own shells, all low, outside the body).
        # Test 8's per-triangle rule also took small low triangles of the turret's own shell, the arms' nose bevels
        # among them, and left holes there (the tester: "make sure the turret is fully enclosed")
        if outer and loose.get(piece_of(tri[0])): return 'drop', None
        ab = [d['pos'][2] >= (zc_at(d['pos'][1]) if outer else zg) - 1e-6 for d in ds]
        if all(ab): return 'keep', None
        if not any(ab): return 'drop', None
        poly, cuts = [], []
        for i in range(3):
            a, b = tri[i], tri[(i + 1) % 3]
            if ab[i]: poly.append(a)
            if ab[i] != ab[(i + 1) % 3]:
                c = cut(a, b, outer); poly.append(c); cuts.append(c)
        return poly, cuts
    nv0 = len(new_v); segs = []; floor_segs = []; dropped = 0; cutn = 0
    # (a 16-bit LOD with little room left: one bevel step instead of the round, the deck plating and ring need the rest)
    steps = ROUND_STEPS if isz == 4 or 65535 - G0.nv - len(new_v) > ROOM_FOR_ROUND else (90,)
    lip_cut.steps = steps
    def geo_n(tri):
        P = [D(k)['pos'] for k in tri]
        ux, uy, uz = (P[1][q] - P[0][q] for q in range(3)); vx, vy, vz = (P[2][q] - P[0][q] for q in range(3))
        n = (uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx); h = math.sqrt(sum(q * q for q in n)) or 1
        return tuple(q / h for q in n)
    keep_new, add, kill = [], [], []; src_tri = {}
    def one(tri):
        """the cut of one turret triangle: (result, outer) where result is 'keep', 'drop' or the kept polygon"""
        nonlocal dropped, cutn
        outer = is_outer(tri)
        res, cuts = clip(tri, outer)
        if res in ('keep', 'drop'):
            if res == 'drop': dropped += 1
            return res
        cutn += 1
        for i in range(1, len(res) - 1): add.append((res[0], res[i], res[i + 1]))
        for c in cuts: src_tri.setdefault(c, tri)          # (Test 11) the wall each cut point lies on
        if len(cuts) == 2:
            n = geo_n(tri)
            cx_ = sum(D(k)['pos'][0] for k in tri) / 3; cy_ = sum(D(k)['pos'][1] for k in tri) / 3
            facing_in = n[0] * (cx_ - body_c.x) + n[1] * (cy_ - body_c.y) < 0
            # (Test 14) a wall facing in (a side case's or box bay's inner wall, cut with the outer walls) gets no skirt:
            # its skirt faced in and showed its back from outside under the rounded base
            if outer is True and abs(n[2]) < SKIRT_NZ and not (facing_in and cy_ < ya): segs.append((cuts[0], cuts[1], n))
            elif not outer: floor_segs.append((cuts[0], cuts[1]))
        return 'cut'
    cur = [struct.unpack_from('<H' if isz == 2 else '<I', ib, (G0.io + t) * isz)[0] for t in range(len(idx_all))]
    # (Test 14) the turret's pieces: triangles joined by shared corners (by position, 0.5 mm), the game's and the roof cut's
    par = {}
    def find(a):
        while par.setdefault(a, a) != a: par[a] = par[par[a]]; a = par[a]
        return a
    def pkey(k): p_ = D(k)['pos']; return (round(p_[0] / 0.0005), round(p_[1] / 0.0005), round(p_[2] / 0.0005))
    vkey = {}
    def piece_of(k):
        if k not in vkey: vkey[k] = pkey(k)
        return find(vkey[k])
    mt = [cur[t:t + 3] for t in range(0, len(cur) - 2, 3)] + [list(q) for q in new_t]
    mt = [q for q in mt if q[0] != q[1] and q[1] != q[2] and q[0] != q[2] and all(on_mount(k) for k in q)]
    for q in mt:
        a = piece_of(q[0])
        for k in q[1:]:
            b = piece_of(k)
            if a != b: par[b] = a
    info = {}
    for q in mt:
        r_ = piece_of(q[0]); e = info.setdefault(r_, [-1e9, 0.0, 0.0, 0])
        for k in q:
            p_ = D(k)['pos']; e[0] = max(e[0], p_[2]); e[1] += p_[0]; e[2] += p_[1]; e[3] += 1
    loose = {r_: (e[0] < zc_at(e[2] / e[3]) + LIP_LOW and not outer_body.contains(Point(e[1] / e[3], e[2] / e[3])))
             for r_, e in info.items()}
    for t in range(0, len(cur) - 2, 3):                 # the game's own turret triangles (in the index buffer)
        tri = cur[t:t + 3]
        if tri[0] == tri[1] or tri[1] == tri[2] or tri[0] == tri[2]: continue
        if not all(on_mount(k) for k in tri): continue
        if one(tri) != 'keep': kill.append((t, tri[0]))
    for tri in new_t:                                   # the roof cut's
        if not all(on_mount(k) for k in tri): keep_new.append(tri); continue
        if one(tri) == 'keep': keep_new.append(tri)
    if not dropped and not cutn: return None
    # the rounded skirts. Each cut point's way in is the mean of the walls' it closes (so neighbouring skirts share
    # their points and corners stay closed); its rows follow profile() down to the gap
    way = {}
    for a, b, n in segs:
        h = math.hypot(n[0], n[1]) or 1
        for k in (a, b):
            w = way.setdefault(k, [0.0, 0.0]); w[0] += n[0] / h; w[1] += n[1] / h
    rows = {}
    def uv_map(k, key):
        """(Test 11) the mapping `key` (uv0: the surface art, uv1: the camo) of the wall cut point k lies on, as a
        function of position: J (2x3) with uv(p) = uv(k) + J (p - pos(k)), the least-norm map that fits the wall
        triangle (None if it is degenerate)"""
        tri = src_tri.get(k)
        if tri is None or key not in D(k): return None
        P = [D(q)['pos'] for q in tri]; T = [D(q)[key] for q in tri]
        E = [[P[1][i] - P[0][i], P[2][i] - P[0][i]] for i in range(3)]                    # 3x2
        G = [[sum(E[i][a] * E[i][b] for i in range(3)) for b in range(2)] for a in range(2)]
        det = G[0][0] * G[1][1] - G[0][1] * G[1][0]
        if abs(det) < 1e-10: return None
        Gi = [[G[1][1] / det, -G[0][1] / det], [-G[1][0] / det, G[0][0] / det]]
        Dm = [[T[1][j] - T[0][j], T[2][j] - T[0][j]] for j in range(2)]                    # 2x2
        DG = [[sum(Dm[j][a] * Gi[a][b] for a in range(2)) for b in range(2)] for j in range(2)]
        return [[sum(DG[j][b] * E[i][b] for b in range(2)) for i in range(3)] for j in range(2)]
    # (Test 12) the decals (uv2 on the decal sheet) end at the cut: the skirts take the sheet's blank spot (the one most
    # turret vertices use), and a skirt under a decal starts from its own copy of the cut point with the blank spot, so
    # no decal texel is stretched down the round (the skull emblem's stem, the wedges under the rear boxes)
    blank = None
    if 'uv2' in D(0):
        cnt = collections.Counter(tuple(V(G0.vo + q_)['uv2']) for q_ in range(0, G0.nv, max(1, G0.nv // 4000)))
        blank = cnt.most_common(1)[0][0]                 # (exact: the sheet's edge texel; a rounded 1.0 wraps to the top row)
    def column(k):
        if k in rows: return rows[k]
        d0 = D(k); x, y, z = d0['pos']
        J = uv_map(k, 'uv1'); J0 = uv_map(k, 'uv0')
        wx, wy = way[k]; h = math.hypot(wx, wy) or 1; wx, wy = wx / h, wy / h
        H = z - zg; R = ROUND_K * H
        tg = smooth_target(x, y, R) if y < ya else None       # (Test 10) behind the arms: down to the smooth curve
        col = [k]
        if blank is not None and max(abs(d0['uv2'][i] - blank[i]) for i in range(2)) > 0.02:
            d = dict(d0); d['uv2'] = blank
            idx = G0.nv + len(new_v); new_v.append(U.encode(li, d)); nd[idx] = d; col = [idx]
        for inset, drop, a in profile(R, H, steps):
            d = dict(d0)
            if blank is not None: d['uv2'] = blank
            if J0 is not None:                           # (Test 11) the wall's art mirrored up from the cut: rows `drop`
                d['uv0'] = tuple(d0['uv0'][j] + J0[j][2] * drop for j in range(2))   # under it show the wall `drop` over it
            else: d.update(up_look.get(k, {}))
            if tg is None: d['pos'] = (x - wx * inset, y - wy * inset, z - drop)
            else:
                f = inset / R if R > 1e-9 else 1.0
                d['pos'] = (x + (tg[0] - x) * f, y + (tg[1] - y) * f, z - drop)
            if J is not None:                            # (Test 11) the camo runs on down the skirt, not smeared (it was
                                                         # the same camo point all the way down: streaks and wedges)
                dp = [d['pos'][i] - d0['pos'][i] for i in range(3)]
                d['uv1'] = tuple(d0['uv1'][j] + sum(J[j][i] * dp[i] for i in range(3)) for j in range(2))
            if 'normal' in d:
                tilt = a * 0.75                          # (a softer turn than the shape: the bottom row stays lit)
                d['normal'] = oct_pack((wx * math.cos(tilt), wy * math.cos(tilt), -math.sin(tilt)), d0['normal'])
            idx = G0.nv + len(new_v); new_v.append(U.encode(li, d)); nd[idx] = d; col.append(idx)
        rows[k] = col
        return col
    skirt = 0
    for a, b, n in segs:
        ca, cb = column(a), column(b)
        for q in range(len(ca) - 1):
            a1, b1, a2, b2 = ca[q], cb[q], ca[q + 1], cb[q + 1]
            quad = [(a1, b1, b2), (a1, b2, a2)]
            # (Test 14) each triangle faces out on its own. Out is worked out from the column's step down in the wall's
            # cross-section (r out along the wall's normal, z up): going down and in, out is out-and-down; going down
            # and out (a column reaching out to the smooth curve under a recessed wall), out is out-and-UP. Test 13
            # faced both out-and-down: the reaching ones showed their backs from above, under the rear boxes' bays
            hn = math.hypot(n[0], n[1]) or 1.0; ux_, uy_ = n[0] / hn, n[1] / hn
            dpx = (D(a2)['pos'][0] - D(a1)['pos'][0] + D(b2)['pos'][0] - D(b1)['pos'][0]) / 2
            dpy = (D(a2)['pos'][1] - D(a1)['pos'][1] + D(b2)['pos'][1] - D(b1)['pos'][1]) / 2
            dpz = (D(a2)['pos'][2] - D(a1)['pos'][2] + D(b2)['pos'][2] - D(b1)['pos'][2]) / 2
            dr = dpx * ux_ + dpy * uy_
            want = (ux_ * -dpz, uy_ * -dpz, dr)
            for i_, tq in enumerate(quad):
                if len(set(tq)) < 3: continue
                g = geo_n(tq)
                if g[0] * want[0] + g[1] * want[1] + g[2] * want[2] < 0: quad[i_] = (tq[0], tq[2], tq[1])
            add += quad; skirt += 2
        floor_segs.append((ca[-1], cb[-1]))
    if L.isz == 2 and G0.nv + len(new_v) > 65535:
        n_need = len(new_v) - nv0
        del new_v[nv0:]
        return f'no room for the cut ({n_need} vertices, 16-bit indices): the lip left as the game has it'
    for t, k0 in kill:
        for k in range(3): put_index(G0.io + t + k, k0)
    new_t[:] = keep_new + add
    # (Test 10) the base band's looks: the walls' own a little way up (0.35-0.6 m over the roof line, outer, plain
    # tiles). The cut's looks fell on the art's dark foot of the wall (where the lip met it): the band under a box showed black
    lip_cut.looks = []
    for k in (range(G0.nv) if BASE_BAND else ()):
        d = V(G0.vo + k); z = d['pos'][2]
        if not roof + 0.35 <= z <= roof + 0.6: continue
        tl = tile(d)
        if tl != 0 and not (tl % 2 == 1 and tl < 32) or 13 <= tl <= 18: continue
        if inside(d['pos'][0], d['pos'][1]): continue
        lip_cut.looks.append(d)
    # the turret's underside: the gap-level edges (the skirts' bottoms, the inner parts' cuts), filled
    # (Test 16) the gunner's door (left whole, see HATCH_CARRY) closes the underside where it crosses the gap level, as
    # its cut used to: without it the outline was open at the back and its fill lost the rear 2 m2
    door = []
    for t in range(0, len(cur) - 2, 3):
        tri = cur[t:t + 3]
        if not hk or len(set(tri)) < 3 or not all(k in hk for k in tri): continue
        ps = [D(k)['pos'] for k in tri]; ab = [p_[2] >= zg for p_ in ps]
        if all(ab) or not any(ab): continue
        pts = [(ps[i][0] + (ps[(i + 1) % 3][0] - ps[i][0]) * (zg - ps[i][2]) / (ps[(i + 1) % 3][2] - ps[i][2]),
                ps[i][1] + (ps[(i + 1) % 3][1] - ps[i][1]) * (zg - ps[i][2]) / (ps[(i + 1) % 3][2] - ps[i][2]))
               for i in range(3) if ab[i] != ab[(i + 1) % 3]]
        if len(pts) == 2 and math.dist(*pts) > 1e-6: door.append(LineString(pts))
    lines = unary_union([LineString([D(a)['pos'][:2], D(b)['pos'][:2]]) for a, b in floor_segs
                         if math.dist(D(a)['pos'][:2], D(b)['pos'][:2]) > 1e-6] + door)
    best = None
    for Rb in (0.15, 0.3, 0.5):
        shape = lines.buffer(Rb)
        filled = unary_union([Polygon(g.exterior) for g in getattr(shape, 'geoms', [shape])]).buffer(-Rb)
        best = max(getattr(filled, 'geoms', [filled]), key=lambda g: g.area)
        if best.area > 0.8 * foot.area: break
    lip_cut.floor = best
    return f'cut at +{LIP_CUT} m (+{FRONT_CUT} m along the arms), rounded down to +{BASE_GAP} m: {dropped} triangles under it dropped, {cutn} cut, {skirt} skirt triangles, {len(new_v) - nv0} new vertices, underside {best.area:.2f} m2' + (f', {lip_cut.out_corner} low triangle(s) with a corner past the walls taken as outer' if lip_cut.out_corner else '')


def build(tank, van_b, out_b):
    cfg = TANKS[tank]; roof = cfg['roof']
    U = load(van_b)
    st = smap_table(U.main)
    report = []
    lod0 = max((k for k, MM in enumerate(U.meshes) if MM.layout >= 0 and MM.mesh_type not in (0, 256, 258)),
               key=lambda k: sum(g.ni for g in U.meshes[k].groups))
    panel = find_panel(U, lod0, roof)
    foot = body_footprint(U, lod0, roof)    # (Test 8)
    base_foot = body_footprint(U, lod0, roof, (LIP_CUT,)) if foot is not None else None   # (Test 8) the body at the cut, for the base band
    lip_cut.smooth = smooth_base(base_foot) if base_foot is not None else None             # (Test 10)
    lip_cut._curves = {}
    lip_cut.boxes = box_footprint(U, lod0, roof) if base_foot is not None else None          # (Test 12)
    if foot is not None: report.append(f'turret body (LOD0, cut at {BODY_SECTIONS}): {foot.area:.2f} m2, bounds {[round(q, 2) for q in foot.bounds]}')
    look0 = deck_look(U, lod0, roof)
    report.append(f'deck look (LOD0): uv1 fitted on {look0["n"]} deck vertices (90% within {look0["err"]:.4f}), uv2 {tuple(round(x, 4) for x in look0["uv2"])}, color {look0["color"].hex()}')
    report.append(f'deck panel: rect {[round(x, 3) for x in panel["rect"]]} at z {panel["z"]:.3f} ({panel["area"]:.2f} m2), up winding {panel["up_sign"]}')
    # (3.4.0) an unskinned shadow mesh gets bone data and the largest skinned shadow LOD's skeleton map
    shadows = [k for k, MM in enumerate(U.meshes) if MM.layout >= 0 and MM.mesh_type == 10]
    skinned = [k for k in shadows if mesh_smap(U, U.meshes[k]) >= 0]
    for k in shadows:
        if mesh_smap(U, U.meshes[k]) >= 0 or not skinned: continue
        src = max(skinned, key=lambda q: sum(g.ni for g in U.meshes[q].groups))
        ssm = mesh_smap(U, U.meshes[src]); sb = st[ssm]
        skin_shadow(U, k, ssm, sb[3][0].index(next(s for s in sb[3][0] if sb[0][s] == BOSS_BONE)))
        report.append(f'mesh {k}: unskinned shadow given bone data and skeleton map {ssm} (mesh {src}\'s)')
    for mi, M in sorted(enumerate(U.meshes), key=lambda e: (e[1].mesh_type == 10 and mesh_smap(U, e[1]) in
                        [mesh_smap(U, U.meshes[q]) for q in skinned if q != e[0]], e[0])):
        if M.layout < 0 or M.mesh_type in (0, 256, 258): continue
        st = smap_table(U.main)                     # (3.4.0) re-read: a shared skeleton map may already be changed
        sm = mesh_smap(U, M)
        if sm < 0: report.append(f'mesh {mi}: no skeleton map, left as is'); continue
        bones, bones_at, mats_at, remap = st[sm]
        li = M.layout
        G0 = M.groups[0]
        dec = {}
        def V(vi):
            if vi not in dec: dec[vi] = U.decode(li, U.vertex(li, vi))
            return dec[vi]
        tris0 = [t for g, t in U.mesh_tris(mi, 0)]
        # other groups: no geometry above the roof, and no vertex shared with group 0's above-roof part
        other = set()
        for gi in range(1, len(M.groups)):
            for _, t in U.mesh_tris(mi, gi):
                for v in t:
                    other.add(v)
                    assert V(v)['pos'][2] <= roof + EPS, (mi, gi, 'geometry above the roof outside group 0')
        rl = remap[0]
        # (Test 16) the hatches' slots (see HATCH_CARRY; a skeleton map shared with a mesh done before has them turned over
        # to the carriers already) and their vertices: all weight on one of them
        hatch_slot = {s for s in rl if KEEP_HATCHES and (bones[s] in HATCH_CARRY or bones[s] in CARRIERS)}
        hatch_r = {c for c, s in enumerate(rl) if s in hatch_slot}
        def on_hatch(v):
            d = V(v); w = weights(d['bw'])
            return any(q > 0 for q in w) and all(d['bidx'][c] in hatch_r for c, q in enumerate(w) if q > 0)
        hatch_verts = {v for t in tris0 for v in t if on_hatch(v)} if hatch_r else set()
        hk = {v - G0.vo for v in hatch_verts}
        # bone -> above/below use in group 0
        use = collections.defaultdict(lambda: [0, 0])
        for t in tris0:
            for v in t:
                d = V(v)
                ab = d['pos'][2] > roof + EPS
                for c, w in enumerate(weights(d['bw'])):
                    if w > 0 and d['bidx'][c] < len(rl):
                        use[rl[d['bidx'][c]]][0 if ab else 1] += 1
        cands = [s for s in rl if use[s][0] > 0 and use[s][1] == 0 and s not in hatch_slot]
        order = sorted(cands, key=lambda s: (PREFER.index(bones[s]) if bones[s] in PREFER else 99, s))
        above_verts = {v for t in tris0 for v in t if V(v)['pos'][2] > roof + EPS} - hatch_verts
        if not order:
            # (3.4.0) a skeleton map already turned for another mesh (the skinned shadow above): its mount slot
            mount_slots = [s for s in rl if bones[s] == MOUNT_BONE]
            if mount_slots: order = mount_slots
        if not order and M.mesh_type == 10:
            # (3.4.0) the smallest shadow LOD: every bone is shared with the hull below. The track/wheel bone with the
            # fewest vertices gives them to the hull body (a far shadow: its few points no longer bounce) and carries
            # the turret instead. Before, this LOD's turret shadow never turned or moved.
            boss_s = next((s for s in rl if bones[s] == BOSS_BONE), None)
            spare = [s for s in rl if s != boss_s and use[s][0] == 0 and not 101 <= bones[s] <= 104] or \
                    [s for s in rl if s != boss_s and use[s][0] == 0]          # (Test 16: a hatch's last)
            if boss_s is not None and spare:
                victim = min(spare, key=lambda s: (use[s][1], s))
                br = rl.index(boss_s); vr = rl.index(victim)
                L0 = U.layouts[li]; raw0 = bytearray(U.vbuf[li]); bi0 = L0.item(6); bw0 = L0.item(7); moved = 0
                for v in {v for t in tris0 for v in t}:
                    d = V(v)
                    if any(d['bidx'][c] == vr and w > 0 for c, w in enumerate(weights(d['bw']))):
                        o = v * L0.stride
                        raw0[o + bi0[3]:o + bi0[3] + 4] = bytes([br, 0, 0, 0])
                        raw0[o + bw0[3]:o + bw0[3] + 4] = weight_one(d['bw'])
                        dec.pop(v, None); moved += 1
                U.vbuf[li] = bytes(raw0)
                report.append(f'mesh {mi}: shadow slot {victim} (bone {bones[victim]}, {moved} vertices) given to the hull body for the turret')
                order = [victim]
        if not order:
            report.append(f'mesh {mi}: no slot carries only above-roof geometry; left as is ({len(above_verts)} vertices above)'); continue
        S = order[0]; r = rl.index(S)
        assert r < 256
        # the boss slot for deck plates
        boss_slot = next((s for s in rl if bones[s] == BOSS_BONE), None)
        # mesh origin from the boss bone's inverse bind (identity rotation)
        bslot = bones.index(BOSS_BONE)
        bm = struct.unpack_from('<16f', U.main, mats_at + 64 * bslot)
        assert abs(bm[0] - 1) < 1e-4 and abs(bm[5] - 1) < 1e-4 and abs(bm[10] - 1) < 1e-4
        origin = tuple(cfg['boss_world'][k] + bm[12 + k] for k in range(3))
        mount_mesh = tuple(cfg['mount'][k] - origin[k] for k in range(3))
        old_bone = bones[S]
        struct.pack_into('<I', U.main, bones_at + 4 * S, MOUNT_BONE)
        struct.pack_into('<16f', U.main, mats_at + 64 * S, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0,
                         -mount_mesh[0], -mount_mesh[1], -mount_mesh[2], 1)
        # (Test 16) the hatches' slots turned over to their carriers: the carrier's node, the inverse of its rest pose
        hatched = []
        for s in sorted(hatch_slot):
            hb = bones[s]
            if hb not in HATCH_CARRY: continue
            ck, cpos, cyaw = HATCH_CARRY[hb]
            m0 = struct.unpack_from('<16f', U.main, mats_at + 64 * s)
            hm = tuple(HATCH_REST[hb][k] - bm[12 + k] for k in range(3))
            assert abs(m0[0] - 1) < 1e-4 and abs(m0[5] - 1) < 1e-4 and all(abs(m0[12 + k] + hm[k]) < 2e-3 for k in range(3)), \
                (mi, hb, 'hatch bone not where expected', m0[12:15], hm)
            cm = tuple(cpos[k] - bm[12 + k] for k in range(3))
            struct.pack_into('<I', U.main, bones_at + 4 * s, ck)
            if cyaw == 180: struct.pack_into('<16f', U.main, mats_at + 64 * s, -1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, cm[0], cm[1], -cm[2], 1)
            else: struct.pack_into('<16f', U.main, mats_at + 64 * s, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -cm[0], -cm[1], -cm[2], 1)
            hatched.append(f'{hb}->{ck}')
        if hatch_verts:
            report.append(f'mesh {mi}: hatches kept on their own slots ({", ".join(hatched) or "already turned over"}): {len(hatch_verts)} vertices')
        # vertices above the roof: on the mount, 100%
        assert not (above_verts & other), (mi, 'an above-roof vertex is shared with another group')
        L = U.layouts[li]
        raw = bytearray(U.vbuf[li])
        bi_item = L.item(6); bw_item = L.item(7)
        for v in above_verts:
            d = V(v)
            o = v * L.stride
            raw[o + bi_item[3]:o + bi_item[3] + 4] = bytes([r, 0, 0, 0])
            raw[o + bw_item[3]:o + bw_item[3] + 4] = weight_one(d['bw'])
        U.vbuf[li] = bytes(raw)
        on_mount = {'bidx': bytes([r, 0, 0, 0])}
        # triangles crossing the roof line: cut
        new_v, new_t, cut_cache = [], [], {}
        ib = bytearray(U.ibuf[li]); isz = L.isz
        def put_index(k, val): struct.pack_into('<H' if isz == 2 else '<I', ib, k * isz, val)
        def cut_vertex(a, b, side):
            key = (min(a, b), max(a, b), side)
            if key in cut_cache: return cut_cache[key]
            da, db = V(a), V(b)
            za, zb = da['pos'][2], db['pos'][2]
            t = (roof - za) / (zb - za)
            nv = {}
            for k in da:
                if k == 'pos' or k.startswith('uv'):
                    nv[k] = tuple(da[k][i] + (db[k][i] - da[k][i]) * t for i in range(len(da[k])))
                else:
                    nv[k] = da[k] if t < 0.5 else db[k]
            nv['pos'] = (nv['pos'][0], nv['pos'][1], roof)
            below = a if za <= roof + EPS else b
            if side == 'above':
                nv['bidx'] = on_mount['bidx']; nv['bw'] = weight_one(V(below)['bw'])
            else:
                nv['bidx'] = V(below)['bidx']; nv['bw'] = V(below)['bw']
            idx = G0.nv + len(new_v)          # group-relative
            new_v.append(U.encode(li, nv))
            cut_cache[key] = idx
            return idx
        crossing = 0; ring_edges = []
        idx_all = U.indices(li, G0.io, G0.ni)
        for t in range(0, len(idx_all) - 2, 3):
            tri = idx_all[t:t + 3]
            if hk and all(k in hk for k in tri): continue          # (Test 16) a hatch goes whole (the gunner's door)
            ab = [V(G0.vo + k)['pos'][2] > roof + EPS for k in tri]
            if all(ab) or not any(ab): continue
            crossing += 1
            above_poly, below_poly = [], []
            for i in range(3):
                a, b = tri[i], tri[(i + 1) % 3]
                if ab[i]: above_poly.append(a)
                else: below_poly.append(a)
                if ab[i] != ab[(i + 1) % 3]:
                    above_poly.append(cut_vertex(G0.vo + a, G0.vo + b, 'above'))
                    below_poly.append(cut_vertex(G0.vo + a, G0.vo + b, 'below'))
            for poly in (above_poly, below_poly):
                for i in range(1, len(poly) - 1):
                    new_t.append((poly[0], poly[i], poly[i + 1]))
            # (Test 15) the wall's cut edge on the turret side, for the ring: its two cut points, the wall's outward
            # (shading) normal and its winding's normal
            cuts = [k for k in above_poly if k >= G0.nv]
            if len(cuts) == 2:
                P3 = [V(G0.vo + k)['pos'] for k in tri]
                g = (lambda a, b, c: ((b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1]),
                                      (b[2] - a[2]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[2] - a[2]),
                                      (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])))(*P3)
                ds = [V(G0.vo + k) for k in tri]
                if all('normal' in d for d in ds):
                    ns = [oct_normal(d['normal']) for d in ds]
                    nout = tuple(sum(n[q] for n in ns) for q in range(3))
                    ring_edges.append((cuts[0], cuts[1], nout, g))
            for k in range(3): put_index(G0.io + t + k, tri[0])        # the original: degenerate
        U.ibuf[li] = bytes(ib)
        # (Test 8) the lip: see LIP_CUT
        lip_cut.hatch = hk
        lip = lip_cut(U, li, M, G0, V, new_v, new_t, r, roof, foot, cfg, put_index, ib, idx_all) if foot is not None else None
        if lip: U.ibuf[li] = bytes(ib); report.append(f'mesh {mi}: lip: ' + lip)
        # caps: the hull's cut opened at the roof line, so the hull gets a deck over the opening (facing up, on the hull
        # body bone) and the turret a floor under itself (facing down, on the mount), both the roof-line outline filled
        tpl = V(next(iter(above_verts)))
        boss_r = rl.index(boss_slot)
        outline = cap_outline(V, G0, idx_all, roof)        # (Test 16: the gunner's door counts, as before: the deck runs under it)
        look = deck_look(U, mi, roof) or look0          # (3.3.0 Test 5) this LOD's own deck look (else LOD0's)
        # (Test 7) the game's own flat surfaces just under the roof line inside the cut (where the casemate stood on the
        # hull) would lie a few mm under the new deck and flicker against it: they are hidden by it anyway, so dropped
        from shapely.geometry import Point
        inner = outline.buffer(-0.01); ib = bytearray(U.ibuf[li]); dropped = 0
        from shapely.geometry import Polygon as _Pg
        drop_polys = []
        def under_deck(P, tl=0):
            """a hull triangle (corners P) the deck over the cut hides or must hide (its centroid is checked apart)"""
            zmax, zmin = max(p[2] for p in P), min(p[2] for p in P)
            # (Test 15) the casemate's own walls going on down into the hull (turret uv tiles 1-18 on the hull's side of the
            # roof-line cut), within DECK_BEVEL under the roof line: their tops showed as a yellow wedge on each side when the
            # turret is turned. Upright or not, inside the cut they belong under the deck
            if DECK_CLEAN and 1 <= tl <= 18 and zmax <= roof + DECK_RIDGE and zmin >= roof - DECK_BEVEL: return True
            if zmax > roof + (DECK_RIDGE if DECK_CLEAN else EPS): return False
            if zmin >= roof - (DECK_RECESS if DECK_CLEAN else 0.015): return True
            if not DECK_CLEAN or zmin < roof - DECK_BEVEL or zmax < roof - CAP_GAP - DECK_UNDER - 0.001: return False
            # (Test 13) the rear deck's recess bevels, mostly flat, whose top reaches the deck's height: they showed through
            # the deck as dark wedges behind the turret. (Upright faces stay: at the hull's edges they close its side.)
            ux, uy, uz = (P[1][q] - P[0][q] for q in range(3)); vx, vy, vz = (P[2][q] - P[0][q] for q in range(3))
            nx_, ny_, nz_ = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
            return abs(nz_) > 0.8 * (math.sqrt(nx_ * nx_ + ny_ * ny_ + nz_ * nz_) or 1)     # (a 45-degree edge bevel stays)
        for t in range(0, len(idx_all) - 2, 3):
            tri = idx_all[t:t + 3]
            if tri[0] == tri[1] or tri[1] == tri[2] or tri[0] == tri[2]: continue
            if hk and all(k in hk for k in tri): continue          # (Test 16) the hatches stay
            P = [V(G0.vo + k)['pos'] for k in tri]
            _d0 = V(G0.vo + tri[0]); tl_ = math.floor(_d0['uv0'][0]) + 32 * math.floor(1 - _d0['uv0'][1])
            # (Test 12) and the deck's low ridges just over the roof line (the rear deck's bevels rise up to 9 mm over
            # it: they poked through the deck plate as light chevrons and wedges right behind the turret)
            if not under_deck(P, tl_): continue
            if not inner.contains(Point(sum(p[0] for p in P) / 3, sum(p[1] for p in P) / 3)): continue
            for k in range(3): put_index(G0.io + t + k, tri[0])
            dropped += 1
            pg_ = _Pg([p[:2] for p in P])
            if DECK_CLEAN and pg_.area > 1e-7 and not outline.contains(pg_): drop_polys.append(pg_.buffer(0.002))
        U.ibuf[li] = bytes(ib)
        if DECK_CLEAN:
            # (Test 12) and what the roof-line cut left of the casemate's foot on the hull side: 3 mm slivers between the
            # deck and the roof line, the old lip's footprint, that poked through the plate as light frames behind the turret
            def Dn(k): return V(G0.vo + k) if k < G0.nv else U.decode(li, new_v[k - G0.nv])
            kept_t = []
            for tri in new_t:
                ds = [Dn(k) for k in tri]
                if any(d['bidx'][0] == r for d in ds) or not under_deck([d['pos'] for d in ds], math.floor(ds[0]['uv0'][0]) + 32 * math.floor(1 - ds[0]['uv0'][1])) or \
                        not inner.contains(Point(sum(d['pos'][0] for d in ds) / 3, sum(d['pos'][1] for d in ds) / 3)):
                    kept_t.append(tri); continue
                dropped += 1
                pg_ = _Pg([d['pos'][:2] for d in ds])
                if pg_.area > 1e-7 and not outline.contains(pg_): drop_polys.append(pg_.buffer(0.002))
            new_t[:] = kept_t
            # (Test 12) the hull side of the roof-line cut (the casemate's walls going on down into the hull) ends at the roof
            # line, 3 mm over the plate: its top edge showed as thin light lines (the old lip's footprint). It now ends just
            # under the plate
            sunk = 0; inner_s = inner.buffer(-0.02)
            for j in range(len(new_v)):
                d = U.decode(li, new_v[j])
                if d['bidx'][0] == r or abs(d['pos'][2] - roof) > 1e-4: continue
                if not inner_s.contains(Point(d['pos'][0], d['pos'][1])): continue     # (the hull's own edge stays)
                d['pos'] = (d['pos'][0], d['pos'][1], roof - CAP_GAP - 0.0015); new_v[j] = U.encode(li, d); sunk += 1
            report.append(f'mesh {mi}: {sunk} hull-side cut points sunk under the deck plate')
        report.append(f'mesh {mi}: {dropped} flat hull triangles under the new deck dropped')
        # (Test 17) the gunner's door, split at the turret's base. Test 16 took it whole onto the turret: its 31 cm under the
        # roof line hung below the turret's base, swept through the hull when the turret turned, and left the doorway's
        # foot in the hull's back open (the tester: "the hatch will clip into the hull when you turn the turret, you can
        # then see into the model when the hatch is moved"). Now the turret's part ends at its base (BASE_GAP over the
        # roof line, closed underneath on the door's own node, so it slides up closed), and the part under the roof line
        # stays on the hull as a fixed panel (on the hull body, its top tucked under the deck), so the doorway's foot is
        # always closed and nothing reaches into the hull. With the turret straight and shut it reads as the game's door.
        door_r = {c for c in hatch_r if bones[rl[c]] in (101, 200)}
        door_tris = {tuple(idx_all[t:t + 3]) for t in range(0, len(idx_all) - 2, 3) if hk and len(set(idx_all[t:t + 3])) == 3
                     and all(k in hk and V(G0.vo + k)['bidx'][0] in door_r for k in idx_all[t:t + 3])} if door_r else set()
        if door_tris and DOOR_SPLIT:
            zg_ = roof + BASE_GAP; z_tuck = roof - CAP_GAP - 0.0015
            dcache = {}
            def door_cut(a, b, z, side):
                key = (min(a, b), max(a, b), side)
                if key in dcache: return dcache[key]
                da, db = V(G0.vo + a), V(G0.vo + b)
                t_ = (z - da['pos'][2]) / (db['pos'][2] - da['pos'][2])
                nv = {}
                for k in da:
                    if k == 'pos' or k.startswith('uv'): nv[k] = tuple(da[k][i] + (db[k][i] - da[k][i]) * t_ for i in range(len(da[k])))
                    else: nv[k] = da[k] if t_ < 0.5 else db[k]
                if side == 'turret': nv['pos'] = (nv['pos'][0], nv['pos'][1], z); nv['bidx'] = da['bidx']; nv['bw'] = weight_one(da['bw'])
                else: nv['pos'] = (nv['pos'][0], nv['pos'][1], z_tuck); nv['bidx'] = bytes([boss_r, 0, 0, 0]); nv['bw'] = weight_one(da['bw'])
                idx = G0.nv + len(new_v); new_v.append(U.encode(li, nv)); dcache[key] = idx
                return idx
            def clip(tri, z, keep_above, side):
                ab = [(V(G0.vo + k)['pos'][2] >= z) == keep_above for k in tri]
                if not any(ab): return []
                if all(ab): return [tuple(tri)]
                poly = []
                for i in range(3):
                    a, b = tri[i], tri[(i + 1) % 3]
                    if ab[i]: poly.append(a)
                    if ab[i] != ab[(i + 1) % 3]: poly.append(door_cut(a, b, z, side))
                return [(poly[0], poly[i], poly[i + 1]) for i in range(1, len(poly) - 1)]
            ib = bytearray(U.ibuf[li]); n_up = n_down = 0; bottom = []
            low = set()
            for t in range(0, len(idx_all) - 2, 3):
                tri = idx_all[t:t + 3]
                if tuple(tri) not in door_tris: continue
                zs = [V(G0.vo + k)['pos'][2] for k in tri]
                if min(zs) >= zg_ - EPS: continue                  # all on the turret: as it is
                up = clip(tri, zg_, True, 'turret'); down = clip(tri, roof, False, 'hull')
                new_t.extend(up); new_t.extend(down); n_up += len(up); n_down += len(down)
                for k in tri:
                    if V(G0.vo + k)['pos'][2] < roof - EPS: low.add(k)
                ps = [V(G0.vo + k)['pos'] for k in tri]; ab_ = [p_[2] >= zg_ for p_ in ps]
                if any(ab_) and not all(ab_):                      # the turret part's bottom edge, for its cap
                    pts = [(ps[i][0] + (ps[(i + 1) % 3][0] - ps[i][0]) * (zg_ - ps[i][2]) / (ps[(i + 1) % 3][2] - ps[i][2]),
                            ps[i][1] + (ps[(i + 1) % 3][1] - ps[i][1]) * (zg_ - ps[i][2]) / (ps[(i + 1) % 3][2] - ps[i][2]))
                           for i in range(3) if ab_[i] != ab_[(i + 1) % 3]]
                    if len(pts) == 2 and math.dist(*pts) > 1e-6: bottom.append(pts)
                for k in range(3): put_index(G0.io + t + k, tri[0])
            U.ibuf[li] = bytes(ib)
            # the door's own vertices under the roof line: the hull's fixed panel (on the hull body), the top ones tucked
            raw = bytearray(U.vbuf[li]); bi_item = L.item(6); bw_item = L.item(7)
            for k in low:
                d = V(G0.vo + k); o = (G0.vo + k) * L.stride
                raw[o + bi_item[3]:o + bi_item[3] + 4] = bytes([boss_r, 0, 0, 0])
                raw[o + bw_item[3]:o + bw_item[3] + 4] = weight_one(d['bw'])
            U.vbuf[li] = bytes(raw)
            # the turret part's underside: its outline at the base filled, facing down, on the door's node
            caps = 0
            if bottom:
                from shapely.geometry import LineString as _LS, Polygon as _PG
                from shapely.ops import unary_union as _UU
                lines_ = _UU([_LS(q) for q in bottom]); best_ = None
                for R_ in (0.01, 0.02, 0.04):
                    sh_ = lines_.buffer(R_)
                    f_ = _UU([_PG(g.exterior) for g in getattr(sh_, 'geoms', [sh_])]).buffer(-R_)
                    if not f_.is_empty: best_ = f_.buffer(-0.002)     # (2 mm inside the door's walls: no edge shows)
                    if best_ is not None and best_.area > 0.03: break
                if best_ is not None and not best_.is_empty:
                    dtpl = dict(V(G0.vo + next(iter(door_tris))[0]))
                    for g_ in getattr(best_, 'geoms', [best_]):
                        caps += add_cap(U, li, g_, zg_, False, dtpl['bidx'][0], dtpl, panel, new_v, new_t, G0.nv, look, plain=True)
            report.append(f'mesh {mi}: gunner\'s door split at the turret\'s base: {n_up} triangles on the turret (underside {caps}), '
                          f'{n_down} under the roof line on the hull ({len(low)} of its vertices)')
        report.append(f'mesh {mi}: deck look from {"its own " + str(look["n"]) + " deck vertices" if look is not look0 else "LOD0"}: {sorted(k for k in look if k in ("uv1", "uv2", "color"))}')
        toutline = outline; zfloor = roof + CAP_GAP
        cut_ok = foot is not None and lip and not lip.startswith('no room')
        if cut_ok:                                     # (Test 9) the turret's underside: the cut's, BASE_GAP over the deck
            from shapely.ops import unary_union as _uu
            bandpoly = base_foot.buffer(BAND_BRIDGE).buffer(-BAND_BRIDGE - BAND_IN)
            H_ = LIP_CUT - BASE_GAP
            g_ = _uu([lip_cut.floor, (lip_cut.smooth or bandpoly).buffer(-ROUND_K * H_)]).buffer(0.004)   # (Test 10: the smooth curve)
            toutline = max(getattr(g_, 'geoms', [g_]), key=lambda q: q.area); zfloor = roof + BASE_GAP
        floor_tris = add_cap(U, li, toutline, zfloor, False, r, tpl, panel, new_v, new_t, G0.nv, look, plain=True)
        # (Test 8) the base band: closes the turret's base behind the arms wherever the cut left it open
        if cut_ok and BASE_BAND:                       # (Test 10: left out, see BASE_BAND)
            from shapely.geometry import box as _box
            band = add_band(U, li, bandpoly, _box(-99, -99, 99, cfg['arms'][0] + 0.05), roof + BASE_GAP,
                            roof + LIP_CUT, r, tpl, panel, look, new_v, new_t, G0.nv, M.mesh_type == 10, getattr(lip_cut, 'looks', None))
            report.append(f'mesh {mi}: base band ' + ('left out (no room: 16-bit indices)' if band < 0 else f'{band} triangles'))
        # (Test 15) the turret ring. (3.4.1 Test 8: the band and the ring now come before the deck copy, which falls back to
        # a coarser LOD's plating when a 16-bit LOD has no room left; the ring's fallback pushed the arms' walls under the roof line)
        ring_tris = add_ring(U, li, toutline, roof, r, tpl, panel, look, new_v, new_t, G0.nv, M.mesh_type == 10, mount_mesh, zfloor)
        if ring_tris < 0:
            # no room for the ring's vertices on this 16-bit LOD: Test 11's skirt instead (the walls' cut points moved
            # down SKIRT and 5 mm in: no new vertices)
            for k in {k for a, b, _, _ in ring_edges for k in (a, b)}:
                d = U.decode(li, new_v[k - G0.nv]); x, y, z = d['pos']
                if 'normal' in d:
                    nx, ny, _ = oct_normal(d['normal']); h = math.hypot(nx, ny)
                    if h > 0.2: x, y = x - nx / h * 0.005, y - ny / h * 0.005
                d['pos'] = (x, y, z - SKIRT); new_v[k - G0.nv] = U.encode(li, d)
        report.append(f'mesh {mi}: turret ring ' + ('left out (no room for its vertices: 16-bit indices); the walls reach down instead' if ring_tris < 0 else f'{ring_tris} triangles'))
        # (Test 6) the hull's own deck plating copied over the cut, first; then (Test 7) a plain fill only where the copy
        # left gaps (2 mm over the copy's edges, 4 mm under it), so nothing else lies under the copy to flicker against.
        # A LOD with 16-bit indices that has no room for its own deck as the source uses the next coarser LOD's
        # (same mesh space and texture layout: only its plate art and uv2 are taken).
        deck_z = roof - CAP_GAP + (DECK_LIFT if DECK_CLEAN else 0.0)
        dk = outline
        if drop_polys:                                 # (Test 12) the deck also covers what the dropped ridges left past the cut
            from shapely.ops import unary_union as _uu2
            dk = _uu2([outline] + drop_polys)
        nv0, nt0 = len(new_v), len(new_t)
        cands = [mi] + sorted((k for k, MM in enumerate(U.meshes) if MM.layout >= 0 and MM.mesh_type == M.mesh_type
                               and sum(g.nv for g in MM.groups) < sum(g.nv for g in M.groups)),
                              key=lambda k: -sum(g.nv for g in U.meshes[k].groups))
        done = None
        if DECK_PLAIN: cands = []                      # (Test 12: no copy, the plain plate everywhere, see DECK_PLAIN)
        for src_mi in cands:
            copy_tris, copy_geom = add_deck_copy(U, li, deck_source(U, src_mi, outline, roof), dk, deck_z,
                                                 panel['up_sign'], boss_r, tpl, look, new_v, new_t, G0.nv, roof)
            gaps = dk if copy_geom is None else dk.difference(copy_geom.buffer(-0.002))
            deck_tris = add_cap(U, li, gaps, deck_z - DECK_UNDER, True, boss_r, tpl, panel, new_v, new_t, G0.nv, look, plain=True) if not gaps.is_empty else 0
            if L.isz == 2 and G0.nv + len(new_v) > 65535:
                report.append(f'mesh {mi}: hull deck copy from mesh {src_mi} needs {len(new_v) - nv0} vertices, {65535 - G0.nv - nv0} left (16-bit indices)')
                del new_v[nv0:]; del new_t[nt0:]
                continue
            done = src_mi; copy_area = copy_geom.area if copy_geom is not None else 0.0; break
        if done is None:
            deck_tris = add_cap(U, li, dk, deck_z, True, boss_r, tpl, panel, new_v, new_t, G0.nv, look, plain=DECK_PLAIN)
            if L.isz == 2 and G0.nv + len(new_v) > 65535:      # (Test 14) no room for the tiled fill either: one plain piece
                del new_v[nv0:]; del new_t[nt0:]
                deck_tris = add_cap(U, li, dk, deck_z, True, boss_r, tpl, panel, new_v, new_t, G0.nv, look, plain=True)
                report.append(f'mesh {mi}: tiled fill has no room (16-bit indices): plain deck piece')
        if done is None: report.append(f'mesh {mi}: ' + ('plain deck plate over the cut (DECK_PLAIN)' if DECK_PLAIN else 'no deck copy fits: tiled fill kept'))
        else: report.append(f'mesh {mi}: hull deck copied over the cut (from mesh {done}): {copy_tris} triangles, {len(new_v) - nv0} vertices, {copy_area:.2f} of {outline.area:.2f} m2')
        plates, tplates = deck_tris, floor_tris
        # (3.4.0) the turret's front arms leaned inward: every turret vertex there (the game's, the cut's, the floor's)
        leaned = 0
        raw = bytearray(U.vbuf[li])
        for v in (above_verts if LEAN_ARMS else ()):
            o = v * L.stride
            nd = lean_arm(U.decode(li, bytes(raw[o:o + L.stride])), mount_mesh[0], cfg['arms'])
            if nd: raw[o:o + L.stride] = U.encode(li, nd); leaned += 1
        U.vbuf[li] = bytes(raw)
        for i, b in enumerate(new_v if LEAN_ARMS else ()):
            d = U.decode(li, b)
            if d['bidx'][0] != r: continue
            nd = lean_arm(d, mount_mesh[0], cfg['arms'])
            if nd: new_v[i] = U.encode(li, nd); leaned += 1
        report.append(f'mesh {mi}: {leaned} turret vertices on the front arms leaned inward')
        if L.isz == 2 and G0.nv + len(new_v) > 65535:
            print('\n'.join(report[-12:])); print(f'mesh {mi}: {G0.nv} + {len(new_v)} vertices over 16-bit', flush=True)
        U.add_to_group(mi, 0, new_v, new_t, group_relative=True)
        # bounds: the turret turning round its axis
        R = max(math.hypot(V(v)['pos'][0] - mount_mesh[0], V(v)['pos'][1] - mount_mesh[1]) for v in above_verts | hatch_verts) if above_verts else 0
        a = list(M.aabb)
        if hatch_verts:                                # (Test 16) the gunner's door slid open over the casemate
            a[5] = max(a[5], max(V(v)['pos'][2] for v in hatch_verts) + max(q[2] for q in HATCH_SLIDE.values()))
        a[0] = min(a[0], mount_mesh[0] - R); a[1] = min(a[1], mount_mesh[1] - R)
        a[3] = max(a[3], mount_mesh[0] + R); a[4] = max(a[4], mount_mesh[1] + R)
        struct.pack_into('<6f', U.main, M.off + 8, *a)
        report.append(f'mesh {mi} (type {M.mesh_type}): slot {S} (bone {old_bone}) -> mount; {len(above_verts)} vertices on the mount, '
                      f'{crossing} triangles cut, deck {plates} and turret floor {tplates} triangles ({outline.area:.2f} m2), {len(new_v)} new vertices, turret radius {R:.2f}')
    m, g = U.write()
    open(out_b + '.main', 'wb').write(m); open(out_b + '.gpu', 'wb').write(g)
    print('\n'.join(report)); print('wrote', out_b, len(m), len(g))


if __name__ == '__main__':
    if len(sys.argv) != 4 or sys.argv[1] not in TANKS:
        sys.exit('usage: build_mbt_hull.py bastion|maelstrom VANILLA_HULL_BASE OUT_BASE')
    import shapely, numpy
    print('shapely %s (GEOS %s), numpy %s' % (shapely.__version__, '.'.join(map(str, shapely.geos_version)), numpy.__version__))
    build(*sys.argv[1:4])

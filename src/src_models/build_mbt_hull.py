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
The smallest shadow LOD has no such slot and is left as the game has it (a turret shadow that doesn't turn, far away)."""
import struct, sys, math, collections
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
from unitlib import Unit

TANKS = {
    # roof line in the hull meshes' own space; the second gun mount's world position; the hull body bone ('boss')
    'bastion': {'roof': 2.24, 'mount': (0.0, -1.959, 2.525), 'boss_world': (0.0, 0.0, 1.162)},
    'maelstrom': {'roof': 0.5625, 'mount': (0.0, -1.959, 2.525), 'boss_world': (0.0, 0.0, 1.162)},
}
MOUNT_BONE, BOSS_BONE = 159, 46            # 0-based node indices in both hulls (b7e9b43d, 9b115563)
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


def oct_normal(raw):
    """the packed normal's direction (octahedral, 10+10 bits)"""
    v = struct.unpack('<I', raw)[0]
    x = (v & 0x3FF) / 1023 * 2 - 1; y = ((v >> 10) & 0x3FF) / 1023 * 2 - 1
    z = 1 - abs(x) - abs(y)
    if z < 0: x, y = (1 - abs(y)) * math.copysign(1, x), (1 - abs(x)) * math.copysign(1, y)
    n = math.sqrt(x * x + y * y + z * z) or 1
    return x / n, y / n, z / n


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


def add_cap(U, li, outline, z, up, slot_r, tpl, panel, new_v, new_t, base):
    """Fill `outline` at height z, tiled with the deck panel's texture; up: facing up (else down). Appends to
    new_v / new_t (group-relative indices from base). Returns the triangle count."""
    import shapely
    from shapely.geometry import box
    import numpy as np
    x0, y0, x1, y1 = panel['rect']; w, h = x1 - x0, y1 - y0
    bx0, by0, bx1, by1 = outline.bounds
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
                            uv = np.array([x - i * w, y - j * h, 1]) @ panel['map']
                            nv = dict(tpl)
                            nv['pos'] = (x, y, z); nv['uv0'] = (float(uv[0]), float(uv[1]))
                            nv['normal'] = panel['up_raw'] if up else panel['down_raw']
                            nv['bidx'] = bytes([slot_r, 0, 0, 0]); nv['bw'] = struct.pack('<I', 0xC00003FF)
                            cache[key] = base + len(new_v); new_v.append(U.encode(li, nv))
                        ids.append(cache[key])
                    new_t.append(tuple(ids)); n += 1
    return n


def build(tank, van_b, out_b):
    cfg = TANKS[tank]; roof = cfg['roof']
    U = load(van_b)
    st = smap_table(U.main)
    report = []
    lod0 = max((k for k, MM in enumerate(U.meshes) if MM.layout >= 0 and MM.mesh_type not in (0, 256, 258)),
               key=lambda k: sum(g.ni for g in U.meshes[k].groups))
    panel = find_panel(U, lod0, roof)
    report.append(f'deck panel: rect {[round(x, 3) for x in panel["rect"]]} at z {panel["z"]:.3f} ({panel["area"]:.2f} m2), up winding {panel["up_sign"]}')
    for mi, M in enumerate(U.meshes):
        if M.layout < 0 or M.mesh_type in (0, 256, 258): continue
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
        # bone -> above/below use in group 0
        use = collections.defaultdict(lambda: [0, 0])
        for t in tris0:
            for v in t:
                d = V(v)
                ab = d['pos'][2] > roof + EPS
                for c, w in enumerate(weights(d['bw'])):
                    if w > 0 and d['bidx'][c] < len(rl):
                        use[rl[d['bidx'][c]]][0 if ab else 1] += 1
        cands = [s for s in rl if use[s][0] > 0 and use[s][1] == 0]
        order = sorted(cands, key=lambda s: (PREFER.index(bones[s]) if bones[s] in PREFER else 99, s))
        above_verts = {v for t in tris0 for v in t if V(v)['pos'][2] > roof + EPS}
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
        crossing = 0
        idx_all = U.indices(li, G0.io, G0.ni)
        for t in range(0, len(idx_all) - 2, 3):
            tri = idx_all[t:t + 3]
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
            for k in range(3): put_index(G0.io + t + k, tri[0])        # the original: degenerate
        U.ibuf[li] = bytes(ib)
        # caps: the hull's cut opened at the roof line, so the hull gets a deck over the opening (facing up, on the hull
        # body bone) and the turret a floor under itself (facing down, on the mount), both the roof-line outline filled
        tpl = V(next(iter(above_verts)))
        boss_r = rl.index(boss_slot)
        outline = cap_outline(V, G0, idx_all, roof)
        deck_tris = add_cap(U, li, outline, roof - CAP_GAP, True, boss_r, tpl, panel, new_v, new_t, G0.nv)
        floor_tris = add_cap(U, li, outline, roof + CAP_GAP, False, r, tpl, panel, new_v, new_t, G0.nv)
        plates, tplates = deck_tris, floor_tris
        U.add_to_group(mi, 0, new_v, new_t, group_relative=True)
        # bounds: the turret turning round its axis
        R = max(math.hypot(V(v)['pos'][0] - mount_mesh[0], V(v)['pos'][1] - mount_mesh[1]) for v in above_verts) if above_verts else 0
        a = list(M.aabb)
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

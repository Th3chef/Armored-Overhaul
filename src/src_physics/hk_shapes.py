"""Armored Overhaul - the hull physics' Havok shapes (3.4.1 Test 26). Reads and writes the small Havok 2019 tagfiles
('TAG0') that hold each actor's shape in the tank hull .physics resources, enough to:
  * recompute a single-child compound shape's bounds, radius, middle vector and tree after its child is moved
    (refresh_compound), and check them (compound_problems); its mass properties are left as they were (the tank's
    keyframed hit actors don't use them);
  * wrap an actor's plain convex shape in a single-child compound shape (wrap_convex), modelled on one of the game's own
    compounds, so an armour block can follow another node like the game's box actors do.

Tagfile layout as read from the game's files (our names): sections are [u32 big-endian size incl. this 8-byte header,
top 2 bits flags][4-char tag]; TAG0 holds SDKV, DATA, TYPE (sub-sections) and INDX (ITEM, PTCH). DATA is the objects'
bytes; ITEM is a 12-byte row per item (type index | flags << 24, offset in DATA, count), item 0 empty; PTCH lists, per
type, the DATA offsets of every reference, each an 8-byte field holding an item index.

A single-child compound (hknpCompoundShape, from the game's files; offsets in DATA): its bounds at 0x70 (min xyzw,
max xyzw) and bounding radius at 0x90; its child instance at 0x120 (4x4 transform, rotation rows and translation row,
flags in the w's; scale at 0x160; child shape reference at 0x170); the bounding tree's three nodes at 0x190, 0x80
each (node 1 = root, node 2 = leaf; each node's lane 0 holds min x, max x, min y, max y, min z, max z, 16 bytes apart);
a vector at 0x310 = bounds min + max (w 0.5). In every compound of both hulls: the instance's row-0 w has flag 0x04
set exactly when the child is turned; bounds = the child's vertices placed by
the instance, grown by the child's convex radius (convex object +0x20); radius = the furthest vertex from the bounds'
middle + the convex radius; both tree nodes' lane 0 = the bounds; the vector = min + max."""
import struct, math, hashlib

B_AABB, B_RAD, B_INST, B_VEC, B_TREE = 0x70, 0x90, 0x120, 0x310, 0x190
CHILD = 0x360                  # the child convex object in DATA (the game's compounds)
CONVEX_RADIUS = 0x20
RCP_SIZE, MASS_SIZE = 0x28, 0x38   # hkRefCountedProperties, hknpShapeMassProperties (as laid out in the game's compounds)


def sections(t, o, end):
    out = []
    while o < end:
        raw, = struct.unpack_from('>I', t, o)
        size = raw & 0x3FFFFFFF
        assert size >= 8 and o + size <= end, 'bad section'
        out.append([t[o + 4:o + 8].decode('latin1'), raw >> 30, t[o + 8:o + size]])
        o += size
    return out


def pack_sections(secs):
    return b''.join(struct.pack('>I', (f << 30) | (8 + len(b))) + tag.encode() + b for tag, f, b in secs)


def packed_int(t, o):
    b = t[o]
    if b < 0x80: return b, o + 1
    if b < 0xC0: return ((b & 0x3F) << 8) | t[o + 1], o + 2
    if b < 0xE0: return ((b & 0x1F) << 16) | (t[o + 1] << 8) | t[o + 2], o + 3
    return ((b & 0x07) << 24) | (t[o + 1] << 16) | (t[o + 2] << 8) | t[o + 3], o + 4


class Tag:
    """a parsed tagfile: .data (bytearray), .items [(type, flags, offset, count)], .ptch [(type, [offsets])], .names"""
    def __init__(self, t):
        top = sections(t, 0, len(t))
        assert len(top) == 1 and top[0][0] == 'TAG0'
        self.flags = top[0][1]
        self.secs = sections(top[0][2], 0, len(top[0][2]))
        tags = [s[0] for s in self.secs]
        assert tags == ['SDKV', 'DATA', 'TYPE', 'INDX'], tags
        self.data = bytearray(self.secs[1][2])
        ty = {s[0]: s[2] for s in sections(self.secs[2][2], 0, len(self.secs[2][2]))}
        strs = (ty.get('TSTR') or ty['TST1']).split(b'\0')
        tn = ty.get('TNAM') or ty['TNA1']
        n, o = packed_int(tn, 0)
        self.names = [None]
        for _ in range(1, n):
            si, o = packed_int(tn, o); np_, o = packed_int(tn, o)
            for _ in range(np_): _, o = packed_int(tn, o); _, o = packed_int(tn, o)
            self.names.append(strs[si].decode())
        idx = sections(self.secs[3][2], 0, len(self.secs[3][2]))
        assert [s[0] for s in idx] == ['ITEM', 'PTCH']
        self.idx_flags = [s[1] for s in idx]
        it = idx[0][2]
        self.items = []
        for o in range(0, len(it), 12):
            f, off, cnt = struct.unpack_from('<III', it, o)
            self.items.append((f & 0xFFFFFF, f >> 24, off, cnt))
        p = idx[1][2]; o = 0; self.ptch = []
        while o < len(p):
            ty_, n = struct.unpack_from('<II', p, o)
            self.ptch.append((ty_, list(struct.unpack_from('<%dI' % n, p, o + 8))))
            o += 8 + 4 * n

    def name(self, i): return self.names[self.items[i][0]]

    def extent(self, i):
        """item i's bytes in DATA, up to the next item (its padding included)"""
        off = self.items[i][2]
        nxt = min([x[2] for x in self.items[1:] if x[2] > off] + [len(self.data)])
        return off, nxt

    def build(self):
        it = b''.join(struct.pack('<III', ty | (f << 24), off, cnt) for ty, f, off, cnt in self.items)
        p = b''.join(struct.pack('<II', ty, len(offs)) + struct.pack('<%dI' % len(offs), *offs) for ty, offs in self.ptch)
        idx = pack_sections([['ITEM', self.idx_flags[0], it], ['PTCH', self.idx_flags[1], p]])
        secs = [self.secs[0], ['DATA', self.secs[1][1], bytes(self.data)], self.secs[2], ['INDX', self.secs[3][1], idx]]
        return pack_sections([['TAG0', self.flags, pack_sections(secs)]])


def chunk_tag(blk, sh):
    """(header bytes, Tag) of the shape chunk at blk[sh:]"""
    assert blk[sh + 8:sh + 12] == b'SH  ' and struct.unpack_from('<I', blk, sh + 0x10)[0] == 0x20
    tsz, = struct.unpack_from('<I', blk, sh + 0x14)
    assert struct.unpack_from('<I', blk, sh)[0] == 0x20 + tsz and blk[sh + 0x2C:sh + 0x30] == b'TAG0'
    return bytes(blk[sh:sh + 0x28]), Tag(bytes(blk[sh + 0x28:sh + 0x28 + tsz]))


def make_chunk(head, tag, shape_type):
    """a shape chunk around a tagfile; the two hash words get a new value from the content (the game gives identical
    shapes the same pair: a changed shape must not pass for the game's)"""
    t = tag.build()
    h = hashlib.sha256(t).digest()[:8]
    out = bytearray(head)
    struct.pack_into('<I', out, 0, 0x20 + len(t)); struct.pack_into('<I', out, 0x14, len(t))
    out[0x18:0x20] = h
    struct.pack_into('<I', out, 0x20, shape_type)
    return bytes(out) + t


def child_vertices(tag):
    ci = [i for i in range(1, len(tag.items)) if tag.name(i) == 'hknpConvexShape']
    assert len(ci) == 1
    fv = [i for i in range(ci[0] + 1, len(tag.items)) if tag.name(i) == 'hkFloat3']
    _, _, off, cnt = tag.items[fv[0]]
    V = [struct.unpack_from('<3f', tag.data, off + 12 * k) for k in range(cnt)]
    crad, = struct.unpack_from('<f', tag.data, tag.items[ci[0]][2] + CONVEX_RADIUS)
    return V, crad


ROTATED = 0x04                 # the instance's row-0 w flag bit the game sets exactly when the child is turned


def place(D, translation):
    """the child instance: no rotation (the 'turned' flag cleared, the rest of each row's flags kept), the translation"""
    for r in range(3):
        for c in range(3): struct.pack_into('<f', D, B_INST + 16 * r + 4 * c, 1.0 if r == c else 0.0)
    w, = struct.unpack_from('<I', D, B_INST + 12)
    struct.pack_into('<I', D, B_INST + 12, w & ~ROTATED)
    struct.pack_into('<3f', D, B_INST + 48, *translation)


def derived(tag):
    """a single-child compound's bounds (lo, hi), radius, from its child and instance"""
    D = tag.data
    V, crad = child_vertices(tag)
    m = struct.unpack_from('<16f', D, B_INST)
    W = [tuple(sum(v[r] * m[r * 4 + c] for r in range(3)) + m[12 + c] for c in range(3)) for v in V]
    lo = [min(w[k] for w in W) - crad for k in range(3)]
    hi = [max(w[k] for w in W) + crad for k in range(3)]
    mid = [(lo[k] + hi[k]) / 2 for k in range(3)]
    rad = max(math.dist(w, mid) for w in W) + crad
    return lo, hi, rad


def is_compound(tag):
    return tag.name(1) == 'hknpCompoundShape'


def refresh_compound(tag):
    """rewrites the compound's derived data from its child and instance (see the header)"""
    assert is_compound(tag)
    lo, hi, rad = derived(tag)
    D = tag.data
    struct.pack_into('<4f', D, B_AABB, *lo, 0.0); struct.pack_into('<4f', D, B_AABB + 16, *hi, 0.0)
    struct.pack_into('<f', D, B_RAD, rad)
    w = struct.unpack_from('<f', D, B_VEC + 12)[0]
    struct.pack_into('<4f', D, B_VEC, *[lo[k] + hi[k] for k in range(3)], w)
    for node in (1, 2):
        for k in range(3):
            struct.pack_into('<f', D, B_TREE + 0x80 * node + 32 * k, lo[k])
            struct.pack_into('<f', D, B_TREE + 0x80 * node + 32 * k + 16, hi[k])


def compound_problems(tag, tol=2e-4):
    """what of the compound's derived data doesn't match its child and instance ([] = all of it does)"""
    lo, hi, rad = derived(tag)
    D = tag.data; bad = []
    f = lambda o: struct.unpack_from('<f', D, o)[0]
    if any(abs(f(B_AABB + 4 * k) - lo[k]) > tol or abs(f(B_AABB + 16 + 4 * k) - hi[k]) > tol for k in range(3)): bad.append('bounds')
    if abs(f(B_RAD) - rad) > tol: bad.append('radius')
    if any(abs(f(B_VEC + 4 * k) - (lo[k] + hi[k])) > 2 * tol for k in range(3)) or f(B_VEC + 12) != 0.5: bad.append('middle vector')
    m = struct.unpack_from('<16f', D, B_INST)
    turned = any(abs(m[r * 4 + c] - (1.0 if r == c else 0.0)) > 1e-6 for r in range(3) for c in range(3))
    if bool(struct.unpack_from('<I', D, B_INST + 12)[0] & ROTATED) != turned: bad.append('turned flag')
    for node in (1, 2):
        if any(abs(f(B_TREE + 0x80 * node + 32 * k) - lo[k]) > tol or abs(f(B_TREE + 0x80 * node + 32 * k + 16) - hi[k]) > tol
               for k in range(3)):
            bad.append('tree node %d' % node)
    return bad


def wrap_convex(tpl, conv, translation):
    """a new single-child compound tagfile: the game's compound tpl (a Tag) with its child replaced by the convex
    shape conv (a Tag holding just a hknpConvexShape and its arrays), placed at translation, no rotation"""
    assert is_compound(tpl) and conv.name(1) == 'hknpConvexShape'
    # the template's child items, in the order they follow the child object (the game's compounds: 6 the convex, 9 its
    # properties, 10-15 its arrays, 16 the properties entry, 17 its mass), against the convex file's own (1-10)
    t_child = [6] + list(range(9, len(tpl.items)))      # (7 and 8 are the compound's own properties entry and mass)
    t_names = [tpl.name(i) for i in t_child]
    c_names = [conv.name(i) for i in range(1, len(conv.items))]
    assert t_names == ['hknpConvexShape', 'hkRefCountedProperties', 'hkFloat3', 'hkVector4', 'hknpConvexHull::Face',
                       'hkUint8', 'hknpConvexHull::Edge', 'hknpConvexHull::Edge', 'hkRefCountedProperties::Entry',
                       'hknpShapeMassProperties'] and t_names == c_names, (t_names, c_names)
    remap = dict(zip(range(1, len(conv.items)), t_child))
    assert tpl.items[6][2] == CHILD and all(tpl.items[i][2] < CHILD for i in (1, 2, 3, 4, 5, 7))
    # the convex file's DATA: the object and its arrays first (0 .. its properties), then properties, entry, mass
    order = [1, 3, 4, 5, 6, 7, 8]
    assert [conv.items[i][2] for i in order] == sorted(conv.items[i][2] for i in order) and conv.items[1][2] == 0
    props_at = conv.items[2][2]
    assert all(conv.items[i][2] < props_at for i in order) and conv.items[2][2] < conv.items[9][2] < conv.items[10][2]
    data = bytearray(tpl.data[:CHILD])
    new_off = {i: tpl.items[i][2] for i in (1, 2, 3, 4, 5, 7)}
    data += conv.data[:props_at]
    for i in order: new_off[remap[i]] = CHILD + conv.items[i][2]

    def put(src, i_src, align, size=None):
        nonlocal data
        while len(data) % align: data.append(0)
        a, b = src.extent(i_src)
        assert not size or (b - a >= size and not any(src.data[a + size:b])), 'item shorter than its type, or not padding after it'
        at = len(data); data += src.data[a:a + size if size else b]
        return at
    # the compound's mass, where the game's compounds have it (after the arrays): the convex's own (unplaced; the game's
    # keyframed hit actors don't use it)
    new_off[8] = put(conv, 10, 16, MASS_SIZE)
    new_off[remap[2]] = put(conv, 2, 8, RCP_SIZE)
    new_off[remap[9]] = put(conv, 9, 16)
    new_off[remap[10]] = put(conv, 10, 16, MASS_SIZE)
    while len(data) % 16: data.append(0)
    # where each of the convex file's references lands, and the item it now names
    def home(src, off, offs_map, idx_of):
        for i in range(1, len(src.items)):
            a, b = src.extent(i)
            if a <= off < b: return offs_map[idx_of(i)] + off - a
        raise AssertionError('reference outside every item')
    moved_refs = []
    for ty, offs in conv.ptch:
        for p in offs:
            q = home(conv, p, new_off, lambda i: remap[i])
            old, = struct.unpack_from('<I', conv.data, p)
            assert old in remap and struct.unpack_from('<I', conv.data, p + 4)[0] == 0
            struct.pack_into('<I', data, q, remap[old])
            moved_refs.append(q)
    # the template's references: its own part unchanged; those in its child items go where that item now is
    t_ptch = []
    for ty, offs in tpl.ptch:
        nl = []
        for p in offs:
            if p < CHILD: nl.append(p); continue
            nl.append(home(tpl, p, new_off, lambda i: i))
        t_ptch.append((ty, nl))
    child_refs = sorted(q for _, offs in t_ptch for q in offs if q >= CHILD)
    assert child_refs == sorted(moved_refs), 'the convex and the template child differ in their references'
    new = Tag.__new__(Tag)
    new.__dict__.update({k: v for k, v in tpl.__dict__.items()})
    new.data = data
    new.items = [tpl.items[0]] + [None] * (len(tpl.items) - 1)
    for i in range(1, len(tpl.items)):
        ty, f, _, cnt = tpl.items[i]
        if i in (1, 2, 3, 4, 5, 7, 8):
            new.items[i] = (ty, f, new_off[i], cnt)
        else:
            src = [k for k, v in remap.items() if v == i][0]
            new.items[i] = (ty, f, new_off[i], conv.items[src][3])
    new.ptch = t_ptch
    # placement: no rotation (each row's flags kept), the translation; then the derived data
    D = new.data
    place(D, translation)
    assert struct.unpack_from('<4f', D, B_INST + 0x40) == (1.0, 1.0, 1.0, 1.0)
    assert struct.unpack_from('<I', D, B_INST + 0x50)[0] == 6
    refresh_compound(new)
    return new

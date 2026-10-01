"""Merges the material slots HD2SDK writes per mesh into one slot per material, as the game's own units have.
  python merge_material_slots.py PATCH_IN PATCH_OUT
HD2SDK's export gives every mesh its own entries in a unit's material list (the Maelstrom hull had 51 entries
for 5 materials; the game's own has 5). With a vehicle skin (camo) applied, the Maelstrom hull then disappeared in
game (1.2 Test 9; fine with the default skin). Every slot that points at the same material is renamed to one
slot (in the mesh material lists and the unit's material list), duplicates are dropped, and the list is written
back in place (the unit keeps its size; the freed bytes are zeroed). Slots the game's own unit has keep their
names, so vehicle skins still find them (e.g. the hull's a779745a, the Bastion cannon's ba24ab63).
2.0.1: the list is written sorted by slot name, as in every one of the game's own units. The game looks slots up
in it by binary search; 1.2-2.0.0 kept the order the slots were first seen, so a lookup could miss a slot that is
there (e.g. the Maelstrom gun's f59bb44b and the pods' 169a6fc9, the slots a camo's mounted overrides name; the
Bastion's lists happened to resolve). Suspected cause of the Maelstrom hull vanishing with a camo on."""
import struct, sys

UNIT = 0xe0a48d0be9a7453f
# the game's own slot names per unit (from the vanilla units): kept as the canonical slot for their material
VANILLA = {
    0x16474112801385b6: {0x63f5aacd: 0x75f87ad2ae08e9c2, 0x9bd9bf07: 0xe7fd8eac41b5da79, 0xa779745a: 0x2d7ef36748bb42f4,
                         0xe6e63b71: 0x2bc2aecf229aeedb, 0xe9871763: 0x84b327056baf1c6d},
    0xb0c9faf4af8903f9: {0x63f5aacd: 0x75f87ad2ae08e9c2, 0x9bd9bf07: 0xe7fd8eac41b5da79, 0xa779745a: 0x2d7ef36748bb42f4,
                         0xe6e63b71: 0x2bc2aecf229aeedb, 0xe9871763: 0x84b327056baf1c6d},
    0x1fa1f596769225c2: {0x63f5aacd: 0x75f87ad2ae08e9c2, 0xba24ab63: 0x2d7ef36748bb42f4, 0xe9871763: 0x84b327056baf1c6d},
    0xd58ae6a04edb10de: {0x63f5aacd: 0x5990e5efbca8ae21, 0xe9871763: 0x84b327056baf1c6d, 0xf59bb44b: 0x8080d4fe57ad7888},
    0x8aff7f0793a5bced: {0x169a6fc9: 0x3acd5f632a67d5c6, 0x63f5aacd: 0x5990e5efbca8ae21, 0xe9871763: 0x84b327056baf1c6d},
    0x3a061009aa31e9cb: {0x63f5aacd: 0x5990e5efbca8ae21, 0xf59bb44b: 0x8080d4fe57ad7888},
}

# extra canonical names: the Maelstrom turret carries the hull's roof and armour (hull material) - named like the
# hull's own slot, so the hull's skin reaches it if the game applies hull skins to mounted units by slot name
PREFER = {0xd58ae6a04edb10de: {0x2d7ef36748bb42f4: 0xa779745a}}

def header_offsets(d):
    o = 48
    lod, joint, light, _ = struct.unpack_from('<4I', d, o); o += 16 + 12
    o += 8 + 4
    skel, layouts, meshdata, meshinfo, terrain = struct.unpack_from('<5I', d, o); o += 20 + 4
    matlist = struct.unpack_from('<I', d, o)[0]
    return meshinfo, matlist

def mesh_material_positions(d, meshinfo):
    """File positions of every mesh's material slot ids (MeshInfo list: count, offsets, then headers)."""
    n = struct.unpack_from('<I', d, meshinfo)[0]
    # layout of the mesh info list (as read by filediver): u32 count, count x u32 offsets, count x u32 group bones
    offs = struct.unpack_from('<%dI' % n, d, meshinfo + 4)
    pos = []
    for off in offs:
        base = meshinfo + off
        # MeshHeader: Unk00 8, AABB 24, UnkFloat00 4, MeshType 4, MeshName 4, AABBTransformIndex 4, TransformIdx 4,
        # UnkInt03 4, SkeletonMapIdx 4, LayoutIdx 4, Unk01 40, NumMaterials 4, MaterialOffset 4
        nm, mo = struct.unpack_from('<2I', d, base + 8 + 24 + 4 * 8 + 40)
        pos += [base + mo + 4 * i for i in range(nm)]
    return pos

def fix_unit(uid, d):
    d = bytearray(d)
    meshinfo, ml = header_offsets(d)
    c = struct.unpack_from('<I', d, ml)[0]
    keys = list(struct.unpack_from('<%dI' % c, d, ml + 4))
    vals = list(struct.unpack_from('<%dQ' % c, d, ml + 4 + 4 * c))
    slot_mat = {}
    for k, v in zip(keys, vals):
        assert slot_mat.get(k, v) == v, 'slot %08x maps to two materials' % k
        slot_mat[k] = v
    canon = {}                                  # material -> slot
    for k, v in VANILLA.get(uid, {}).items(): canon[v] = k
    for v, k in PREFER.get(uid, {}).items():
        assert k not in slot_mat or slot_mat[k] == v, 'preferred slot %08x already used' % k
        canon[v] = k
    for k in keys:
        canon.setdefault(slot_mat[k], k)
    rename = {k: canon[slot_mat[k]] for k in slot_mat}
    assert len(set(canon.values())) == len(canon), 'two materials on one slot name'
    positions = mesh_material_positions(d, meshinfo)
    changed = 0
    for p in positions:
        s = struct.unpack_from('<I', d, p)[0]
        assert s in rename, 'mesh uses slot %08x that is not in the list' % s
        if rename[s] != s: struct.pack_into('<I', d, p, rename[s]); changed += 1
    new = []                                    # unique (slot, material)
    for k in keys:
        pair = (rename[k], slot_mat[k])
        if pair not in new: new.append(pair)
    new.sort()                                  # sorted by slot name, as the game's own units (binary search)
    end = ml + 4 + 12 * c
    d[ml:end] = b'\0' * (end - ml)
    struct.pack_into('<I', d, ml, len(new))
    for i, (k, v) in enumerate(new):
        struct.pack_into('<I', d, ml + 4 + 4 * i, k)
        struct.pack_into('<Q', d, ml + 4 + 4 * len(new) + 8 * i, v)
    return bytes(d), c, len(new), changed

if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    p = bytearray(open(src, 'rb').read())
    tc, ec = struct.unpack_from('<II', p, 4)
    base = 72 + 32 * tc
    for i in range(ec):
        e = struct.unpack_from('<7Q6I', p, base + 80 * i)
        uid, typ, off, size = e[0], e[1], e[2], e[7]
        if typ != UNIT: continue
        fixed, before, after, changed = fix_unit(uid, p[off:off + size])
        assert len(fixed) == size
        p[off:off + size] = fixed
        print('%016x: material list %d -> %d entries, %d mesh slots renamed' % (uid, before, after, changed))
    open(dst, 'wb').write(p)

"""Armored Overhaul - Tank MBT Turrets: the turret's hit areas (3.4.1 Test 21; Test 26). Changes the two tank hull physics
resources so the casemate's hit areas (the keyframed actors that shots and damage land on) are attached to the turret's
mount node (b7e9b43d, node 159, which MBT Turrets turns and moves forward), so they go round with the turret.

Why in the physics file: the hit areas follow nodes the game animates every frame (their own c_* nodes, the side and rear
boxes' nodes, the radar and the antenna); Test 20 moved those nodes from Lua and the game put them back every time (816
of 816 checks). Node 159 isn't animated, so the actors follow it.

The physics resource, as read from the game's own files (both hulls alike; field names ours):
  header: +0x10 file size; 'PR  ' at 0x48: +4 offset of the actor section (0x60), +8 / +0xC absolute offsets of the
  'MR  ' and 'VR  ' sections. Actor section at 0x60: 'AR  ', count, then each actor's offset relative to 0x60.
  actor: +0 its node's name hash, +4 template ('keyframed' 937a5a10), +8 the node it follows, +0xC flags (1: its own
  node, 0x11: another one). +0x38 entry count, +0x3C entry offsets (relative to the actor). Each entry 0x88 bytes: type,
  two hashes, the actor's name hash, a 4x4 matrix (row-major, translation in the last row): for type 0x1004 the actor's
  pose in the followed node's frame; type 4 (own node) identity; a second entry of type 6 (identity) when it follows
  another node. Then the shape chunk ('SH  ' after an 8-byte size header), whose +0x20 names the last entry's type.
So an actor on its own node (one entry, shape at +0xC8) becomes one following node 159 like the game's own box actors:
two entries (0x1004 with its pose, 6), shape at +0x168: 0xA0 bytes more; every later actor and section moves by that.
Actors already following another node only get the new node and pose.

(Test 26) What every attached actor's shape needs (hk_shapes.py): the game's attached actors carry a single-child
compound shape whose child instance holds the pose, and whose bounds, bounding radius, 'middle' vector and BOTH bounding
tree nodes are worked out from where the child sits. Test 25 moved the child and the bounds and the root node but left
the tree's leaf node and the middle vector at the old place (near the mount's middle): a shot is tested against the
leaf, so the moved boxes still couldn't be hit where they now are. Now all of it is recomputed from the moved child,
and checked against the same rule the game's own compounds all follow. The five armour blocks (plain convex shapes on
their own nodes) get a compound made like the game's: a box actor's compound with the block's own convex as the child.
Test 26 also moves the casemate's core (985fc05e: the big block filling the casemate, 3 m wide, already a compound on
the hull body) that the earlier tests missed. Every changed shape gets a new content hash (the game gives identical
shapes the same pair), so none can pass for the game's.

Without MBT Turrets node 159 stays at rest, where every pose below puts each actor exactly where the game has it.
Used by make_suspension.py for the MBT Turrets option's 'Turret Hit Areas' folder and for each Suspension preset (the
presets replace the same files; Tank Suspension comes after Tank MBT Turrets in the option list so its copy wins)."""
import struct
import hk_shapes as K

MOUNT = 0xb7e9b43d                     # attach_tank_gun_mg, node 159
MOUNT_WORLD = (0.0, -1.958914, 2.524669)
KEYFRAMED = 0x937a5a10
# the turret's hit areas: actor (its node's name hash) -> its node's rest place (unit frame; every one unturned)
TURRET = {
    0xbce8db39: (0.0, -3.991178, 2.518748),          # c_back_door_block
    0x1bba0852: (-1.576604, -2.130685, 2.635641),    # c_left_top_block
    0x89d22707: (1.577076, -2.130685, 2.635641),     # c_right_top_block
    0x54221db6: (-1.408000, -0.833735, 2.583963),    # c_left_front_block
    0x8709f332: (1.407592, -0.833735, 2.583963),     # c_right_front_block
    0x50e5b5c3: (2.330809, -1.809590, 2.702248),     # c_right_box_0 (on r_box_0)
    0xd7ea969c: (2.330809, -2.450647, 2.702249),     # c_right_box_1
    0x8712e6f6: (-2.330809, -1.809590, 2.702248),    # c_left_box_0
    0x69ddc2c7: (-2.330809, -2.450647, 2.702249),    # c_left_box_1
    0xc1a9fc52: (1.579778, -4.501788, 2.702249),     # c_right_box_2
    0x6a1d9969: (-1.579778, -4.501788, 2.702249),    # c_left_box_2
    0xad390c7d: (1.571121, -3.822489, 3.198488),     # c_radar (on radar)
    0x0902a4f2: (-1.597311, -4.125620, 3.390064),    # c_antenna (on antenna_1)
    0x985fc05e: (0.0, -2.948598, 2.021473),          # (Test 26) the casemate's core (on the hull body, boss)
}
OWN, OTHER = 1, 0x11
# Following another node, the game's actors carry a compound shape (shape chunk +0x20 = 6: hknpCompoundShape; entries:
# the convex child with its pose, 0x1004, and the compound, 6); the armour blocks on their own nodes a plain convex one
# (+0x20 = 4). (Test 21 only relabelled the blocks' convex shapes as compounds: the game crashed at start. From Test 26
# each block gets a real compound, hk_shapes.wrap_convex.)
ENTRY = 0x88
TEMPLATE = 0x50e5b5c3    # the game's compound the blocks' compounds are made like (c_right_box_0)
TURNS = ((1, 0, 0, 0, 1, 0, 0, 0, 1), (1, 0, 0, 0, -1, 0, 0, 0, -1))      # the child turns the game's turret actors have


def moved():
    """the turret hit areas this build moves (every one)"""
    return dict(TURRET)


def actors(d):
    assert d[0x48:0x4C] == b'PR  ' and struct.unpack_from('<I', d, 0x4C)[0] == 0x60 and d[0x60:0x64] == b'AR  '
    n = struct.unpack_from('<I', d, 0x64)[0]
    return [0x60 + x for x in struct.unpack_from('<%dI' % n, d, 0x68)]


def layout(d, o):
    """an actor's entries and shape: (count, [entry offsets], shape chunk offset), all relative to the actor"""
    cnt = struct.unpack_from('<I', d, o + 0x38)[0]
    lst = list(struct.unpack_from('<%dI' % cnt, d, o + 0x3C))
    sh = lst[-1] + ENTRY
    assert d[o + sh + 8:o + sh + 12] == b'SH  ', (hex(o), 'no shape where expected')
    return cnt, lst, sh


def pose(name):
    t = tuple(TURRET[name][k] - MOUNT_WORLD[k] for k in range(3))
    return struct.pack('<16f', 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, t[0], t[1], t[2], 1)


def move_compound(blk, sh, old, name):
    """(Test 25, Test 26) an attached actor's compound: its child placed at the actor's node (seen from the mount, no
    rotation: every turret actor's child ends up unturned in the hull's frame), everything worked out from it redone"""
    head, tag = K.chunk_tag(blk, sh)
    assert K.is_compound(tag) and not K.compound_problems(tag), 'not the game\'s compound'
    D = tag.data
    inst = struct.unpack_from('<16f', D, K.B_INST)
    assert all(abs(inst[r * 4 + c] - old[r * 4 + c]) < 1e-4 for r in range(4) for c in range(3)), 'the shape\'s child pose is not the entry\'s'
    # the game's turret actors' children are unturned or turned half round x, and their nodes turned the same way: in
    # the hull's frame every child is unturned (3.4.1 review: anything else stops the build)
    R = tuple(round(old[r * 4 + c], 4) for r in range(3) for c in range(3))
    assert R in TURNS, 'an unexpected child turn %s' % (R,)
    K.place(D, [TURRET[name][k] - MOUNT_WORLD[k] for k in range(3)])
    K.refresh_compound(tag)
    return K.make_chunk(head, tag, 6)


def retarget(data):
    """the turret's hit areas attached to node 159 (see the header); returns the new file. Asserts the game's layout."""
    d = bytes(data)
    offs = actors(d)
    tpl = None
    for o in offs:
        if struct.unpack_from('<I', d, o)[0] == TEMPLATE:
            tpl = K.chunk_tag(d[o:], layout(d, o)[2])[1]
    assert tpl is not None and K.is_compound(tpl)
    found = {}
    out = bytearray(d[:offs[0]])
    new_offs = []
    for i, o in enumerate(offs):
        end = offs[i + 1] if i + 1 < len(offs) else struct.unpack_from('<I', d, 0x50)[0]
        blk = bytearray(d[o:end])
        name, tpl_, att, flag = struct.unpack_from('<4I', blk, 0)
        new_offs.append(len(out))
        if name in TURRET:
            assert tpl_ == KEYFRAMED, hex(name)
            cnt, lst, sh = layout(blk, 0)
            tsz = struct.unpack_from('<I', blk, sh)[0] + 8
            tail = bytes(blk[sh + tsz:])
            assert tail == bytes(12), 'the 12 bytes after the shape'
            if flag == OTHER:
                assert cnt == 2 and lst == [0x50, 0xE0] and struct.unpack_from('<I', blk, 0x50)[0] == 0x1004
                assert struct.unpack_from('<I', blk, 0x5C)[0] == name
                old = struct.unpack_from('<16f', blk, 0x60)
                struct.pack_into('<I', blk, 8, MOUNT)
                blk[0x60:0xA0] = pose(name)
                blk = blk[:sh] + move_compound(blk, sh, old, name) + tail
            elif flag == OWN:
                assert att == name and cnt == 1 and lst == [0x40] and sh == 0xC8
                assert struct.unpack_from('<I', blk, 0x40)[0] == 4 and struct.unpack_from('<I', blk, 0x4C)[0] == name
                assert struct.unpack_from('<I', blk, sh + 0x20)[0] == 4, 'the shape names its entry type'
                assert blk[0x50:0x90] == struct.pack('<16f', 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1) or \
                    all(abs(a - b) < 1e-6 for a, b in zip(struct.unpack_from('<16f', blk, 0x50), (1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)))
                head_, conv = K.chunk_tag(blk, sh)
                comp = K.wrap_convex(tpl, conv, tuple(TURRET[name][k] - MOUNT_WORLD[k] for k in range(3)))
                head = bytearray(blk[:0x38])
                struct.pack_into('<II', head, 8, MOUNT, OTHER)
                e1 = bytearray(blk[0x40:0x40 + ENTRY])
                struct.pack_into('<I', e1, 0, 0x1004); e1[0x10:0x50] = pose(name)
                e2 = bytearray(ENTRY)
                struct.pack_into('<I', e2, 0, 6); e2[0x10:0x50] = struct.pack('<16f', 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
                blk = head + struct.pack('<III', 2, 0x50, 0xE0) + bytes(0x50 - 0x44) + e1 + bytes(0xE0 - 0x50 - ENTRY) + e2 + \
                    K.make_chunk(head_, comp, 6) + tail
            else:
                raise AssertionError('unexpected flags %x on %08x' % (flag, name))
            found[name] = flag
        out += blk
    assert set(found) == set(moved()), 'missing: ' + ', '.join('%08x' % k for k in set(moved()) - set(found))
    mr, vr = struct.unpack_from('<II', d, 0x50)
    grow = len(out) - mr                                   # bytes added before 'MR'
    out += d[mr:]
    struct.pack_into('<II', out, 0x50, mr + grow, vr + grow)
    struct.pack_into('<%dI' % len(new_offs), out, 0x68, *[x - 0x60 for x in new_offs])
    assert struct.unpack_from('<I', d, 0x10)[0] == len(d)
    struct.pack_into('<I', out, 0x10, len(out))
    check(bytes(out), d)
    return bytes(out)


def check(new, old):
    """re-reads the new file: every actor and shape where the layout says; the turret's actors on node 159 with their
    pose, a compound shape whose child sits at the actor's node and whose bounds, radius, middle vector, both tree
    nodes and turned flag follow from it (the rule every compound of the game's follows), the rest of the shape what it
    was made from (see below); everything else and the 'MR'/'VR' sections byte for byte the game's"""
    o_old, o_new = actors(old), actors(new)
    assert len(o_old) == len(o_new)
    assert new[struct.unpack_from('<I', new, 0x50)[0]:][:4] == b'MR  ' and new[struct.unpack_from('<I', new, 0x54)[0]:][:4] == b'VR  '
    mr_o, mr_n = struct.unpack_from('<I', old, 0x50)[0], struct.unpack_from('<I', new, 0x50)[0]
    assert old[mr_o:] == new[mr_n:]
    for i, (a, b) in enumerate(zip(o_old, o_new)):
        ea = o_old[i + 1] if i + 1 < len(o_old) else mr_o
        eb = o_new[i + 1] if i + 1 < len(o_new) else mr_n
        name = struct.unpack_from('<I', new, b)[0]
        cnt, lst, sh = layout(new, b)
        if name in moved():
            assert struct.unpack_from('<II', new, b + 8) == (MOUNT, OTHER) and cnt == 2 and lst == [0x50, 0xE0]
            assert struct.unpack_from('<I', new, b + 0x50)[0] == 0x1004 and new[b + 0xE0:b + 0xE0 + ENTRY] == struct.pack('<I', 6) + bytes(12) + \
                struct.pack('<16f', 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1) + bytes(ENTRY - 0x50)      # as the game's
            assert new[b + 0x60:b + 0xA0] == pose(name)
            assert new[b:b + 0x38] == old[a:a + 8] + struct.pack('<II', MOUNT, OTHER) + old[a + 0x10:a + 0x38]
            assert struct.unpack_from('<I', new, b + sh + 0x20)[0] == 6
            _, tag = K.chunk_tag(new[b:eb], sh)
            assert K.is_compound(tag), '%08x not a compound' % name
            p = K.compound_problems(tag)
            assert not p, '%08x: %s' % (name, p)
            ni = struct.unpack_from('<16f', tag.data, K.B_INST)
            assert all(abs(ni[12 + k] - (TURRET[name][k] - MOUNT_WORLD[k])) < 1e-6 for k in range(3)), 'shape pose'
            assert all(ni[r * 4 + c] == (1.0 if r == c else 0.0) for r in range(3) for c in range(3)), 'shape turn'
            # (3.4.1 review) everything else in the shape, against what it was made from: the compound part (the old
            # compound, or for an armour block the template's) byte for byte but the placement and what follows from it;
            # the child (the old compound's, or the block's own convex) and the compound's mass byte for byte, each item
            # its full length, every reference naming the matching item; the same reference list; a new content hash
            oh, otag = K.chunk_tag(old[a:ea], layout(old, a)[2])
            own = not K.is_compound(otag)
            if own:
                ta = [x for x in o_old if struct.unpack_from('<I', old, x)[0] == TEMPLATE][0]
                ref = K.chunk_tag(old[ta:], layout(old, ta)[2])[1]
                oi = list(range(1, len(otag.items)))                  # the convex file's items, in child order
                mass_src = 10
            else:
                ref = otag
                oi = [6] + list(range(9, len(otag.items)))
                mass_src = 8
            ci = [6] + list(range(9, len(tag.items)))
            assert len(ci) == len(oi) and len(tag.items) == len(ref.items)
            to_new = dict(zip(oi, ci))
            for x in range(1, len(tag.items)):                          # types and flags as the game's compound's
                assert tag.items[x][:2] == ref.items[x][:2], '%08x: item %d type' % (name, x)
            na, ra = bytearray(tag.data[:K.CHILD]), bytearray(ref.data[:K.CHILD])
            for lo_, n_ in [(K.B_AABB, 12), (K.B_AABB + 16, 12), (K.B_RAD, 4), (K.B_VEC, 12)] + \
                    [(K.B_INST + 16 * r, 12) for r in range(4)] + [(K.B_TREE + 0x80 * nd + 16 * k, 4) for nd in (1, 2) for k in range(6)]:
                na[lo_:lo_ + n_] = ra[lo_:lo_ + n_]
            w_new, w_ref = struct.unpack_from('<I', na, K.B_INST + 12)[0], struct.unpack_from('<I', ra, K.B_INST + 12)[0]
            assert w_new | K.ROTATED == w_ref | K.ROTATED, '%08x: instance flags' % name
            struct.pack_into('<I', na, K.B_INST + 12, w_ref)
            assert na == ra, '%08x: the compound part changed beyond its placement' % name
            refs_new = sorted(q for _, offs in tag.ptch for q in offs)
            refs_old = otag.ptch if own else [(ty, [q for q in offs if q >= K.CHILD]) for ty, offs in otag.ptch]
            want_refs = sorted([q for _, offs in ref.ptch for q in offs if q < K.CHILD] +
                               [tag.extent(to_new[y])[0] + q - otag.extent(y)[0] for _, offs in refs_old for q in offs
                                for y in oi if otag.extent(y)[0] <= q < otag.extent(y)[1]])
            assert refs_new == want_refs, '%08x: reference list' % name
            for x, y in zip(ci, oi):
                assert tag.items[x][3] == otag.items[y][3], '%08x: item %d count' % (name, x)
                xa, xb = tag.extent(x); ya, yb = otag.extent(y)
                size = K.RCP_SIZE if tag.name(x) == 'hkRefCountedProperties' else (K.MASS_SIZE if tag.name(x) == 'hknpShapeMassProperties' else None)
                bx, by = bytearray(tag.data[xa:xa + size if size else xb]), bytearray(otag.data[ya:ya + size if size else yb])
                n_ = min(len(bx), len(by))                              # (each item's own length; past it only padding)
                assert not any(bx[n_:]) and not any(by[n_:]), '%08x: item %s length' % (name, tag.name(x))
                bx, by = bx[:n_], by[:n_]
                for q in refs_new:
                    if xa <= q < xa + len(bx):
                        oq = ya + q - xa
                        assert to_new[struct.unpack_from('<I', otag.data, oq)[0]] == struct.unpack_from('<I', tag.data, q)[0], '%08x: reference' % name
                        bx[q - xa:q - xa + 4] = by[q - xa:q - xa + 4]
                assert bx == by, '%08x: child item %s differs' % (name, tag.name(x))
            ma = tag.extent(8)[0]; mb = otag.extent(mass_src)[0]
            assert tag.data[ma:ma + K.MASS_SIZE] == otag.data[mb:mb + K.MASS_SIZE], '%08x: compound mass' % name
            nh = new[b + sh:b + sh + 0x28]
            assert nh[0x18:0x20] != oh[0x18:0x20], '%08x: the content hash is the game\'s' % name
            assert nh[4:0x14] == oh[4:0x14] and nh[0x24:0x28] == oh[0x24:0x28], '%08x: shape chunk header' % name
            e_old = 0x40 if own else 0x50
            assert new[b + 0x54:b + 0x60] == old[a + e_old + 4:a + e_old + 0x10] and not any(new[b + 0xA0:b + 0xD8]), '%08x: entry' % name
            assert new[eb - 12:eb] == bytes(12)
        else:
            assert new[b:eb] == old[a:ea], '%08x changed' % name


if __name__ == '__main__':
    import sys
    for p in sys.argv[1:]:
        d = open(p, 'rb').read()
        n = retarget(d)
        print(p, len(d), '->', len(n), 'ok')

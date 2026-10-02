"""Minimal reader/writer for Helldivers 2 unit geometry (main + gpu_resources), enough to add triangles to existing
meshes. Layout of the structures follows Filediver's stingray/unit reader (field offsets noted below)."""
import struct, math

FMT_SIZE = {0: 4, 1: 8, 2: 12, 3: 16, 4: 4, 21: 4, 22: 8, 23: 12, 24: 16, 25: 1, 26: 2, 27: 3, 28: 4, 29: 4, 30: 4,
            32: 2, 33: 4, 34: 6, 35: 8}
POS, NORMAL, TANGENT, UV, COLOR, BONEIDX, BONEW = 0, 1, 2, 4, 5, 6, 7
LAYOUT_SIZE = 448
HDR_OFFS = {'meshlayouts': 92, 'meshdata': 96, 'meshinfos': 100, 'materials': 112}


class Layout:
    def __init__(self, d, off):
        self.off = off
        self.items = []
        n = struct.unpack_from('<I', d, off + 328)[0]
        pos = 0
        for i in range(n):
            t, f, layer = struct.unpack_from('<III', d, off + 8 + 20 * i)
            self.items.append((t, f, layer, pos))
            pos += FMT_SIZE[f]
        (self.nverts, self.stride) = struct.unpack_from('<II', d, off + 352)
        self.nidx = struct.unpack_from('<I', d, off + 392)[0]
        self.voff, self.vsize, self.ioff, self.isize = struct.unpack_from('<IIII', d, off + 416)
        assert pos == self.stride, (pos, self.stride)
        self.isz = self.isize // self.nidx if self.nidx else 2

    def item(self, t, layer=0):
        for it in self.items:
            if it[0] == t and it[2] == layer: return it
        return None


class Group:
    def __init__(self, d, off):
        self.off = off
        self.mat, self.vo, self.nv, self.io, self.ni, self.gi = struct.unpack_from('<6I', d, off)


class MeshInfo:
    def __init__(self, d, off):
        self.off = off
        self.aabb = struct.unpack_from('<6f', d, off + 8)
        self.mesh_type, self.name = struct.unpack_from('<II', d, off + 36)
        self.layout = struct.unpack_from('<i', d, off + 60)[0]
        nmat, matoff = struct.unpack_from('<II', d, off + 104)
        ngrp, grpoff = struct.unpack_from('<II', d, off + 120)
        self.mats = list(struct.unpack_from('<%dI' % nmat, d, off + matoff))
        self.groups = [Group(d, off + grpoff + 24 * j) for j in range(ngrp)]


class Unit:
    def __init__(self, main, gpu):
        self.main = bytearray(main)
        self.gpu = gpu
        d = self.main
        lo = struct.unpack_from('<I', d, HDR_OFFS['meshlayouts'])[0]
        n = struct.unpack_from('<I', d, lo)[0]
        offs = struct.unpack_from('<%dI' % n, d, lo + 4)
        self.layouts = [Layout(d, lo + o) for o in offs]
        mo = struct.unpack_from('<I', d, HDR_OFFS['meshinfos'])[0]
        n = struct.unpack_from('<I', d, mo)[0]
        offs = struct.unpack_from('<%dI' % n, d, mo + 4)
        self.meshes = [MeshInfo(d, mo + o) for o in offs]
        ml = struct.unpack_from('<I', d, HDR_OFFS['materials'])[0]
        n = struct.unpack_from('<I', d, ml)[0]
        keys = struct.unpack_from('<%dI' % n, d, ml + 4)
        vals = struct.unpack_from('<%dQ' % n, d, ml + 4 + 4 * n)
        self.material_map = dict(zip(keys, vals))
        # raw buffers per layout
        self.vbuf = [bytes(gpu[L.voff:L.voff + L.vsize]) for L in self.layouts]
        self.ibuf = [bytes(gpu[L.ioff:L.ioff + L.isize]) for L in self.layouts]

    # ---- reading
    def vertex(self, li, vi):
        L = self.layouts[li]
        return self.vbuf[li][vi * L.stride:(vi + 1) * L.stride]

    def indices(self, li, io, ni):
        L = self.layouts[li]
        fmt = '<%d%s' % (ni, 'H' if L.isz == 2 else 'I')
        return struct.unpack_from(fmt, self.ibuf[li], io * L.isz)

    def decode(self, li, raw):
        """dict of the vertex's attributes (position, uv layers as floats; others raw bytes)"""
        L = self.layouts[li]
        out = {}
        for t, f, layer, p in L.items:
            b = raw[p:p + FMT_SIZE[f]]
            if t == POS:
                out['pos'] = struct.unpack('<3f', b) if f == 2 else tuple(struct.unpack('<3e', b))
            elif t == UV:
                out['uv%d' % layer] = struct.unpack('<2f', b) if f == 1 else struct.unpack('<2e', b)
            elif t == NORMAL:
                out['normal'] = b
            elif t == COLOR:
                out['color'] = b
            elif t == BONEIDX:
                out['bidx'] = b
            elif t == BONEW:
                out['bw'] = b
            else:
                out['raw%d_%d' % (t, layer)] = b
        return out

    def encode(self, li, v):
        """bytes in layout li's format from an attribute dict (missing items: zero)"""
        L = self.layouts[li]
        out = bytearray(L.stride)
        for t, f, layer, p in L.items:
            n = FMT_SIZE[f]
            if t == POS:
                b = struct.pack('<3f', *v['pos']) if f == 2 else struct.pack('<3e', *v['pos'])
            elif t == UV:
                uv = v.get('uv%d' % layer, (0.0, 0.0))
                b = struct.pack('<2f', *uv) if f == 1 else struct.pack('<2e', *uv)
            elif t == NORMAL:
                b = v['normal']
            elif t == COLOR:
                b = v.get('color', b'\xff\xff\xff\xff')
            elif t == BONEIDX:
                b = v['bidx']
            elif t == BONEW:
                b = v['bw']
            else:
                b = bytes(n)
            assert len(b) == n, (t, f, len(b), n)
            out[p:p + n] = b
        return bytes(out)

    def set_uv0(self, li, vi, uv):
        L = self.layouts[li]
        it = L.item(UV, 0)
        t, f, layer, p = it
        raw = bytearray(self.vbuf[li])
        o = vi * L.stride + p
        raw[o:o + FMT_SIZE[f]] = struct.pack('<2f', *uv) if f == 1 else struct.pack('<2e', *uv)
        self.vbuf[li] = bytes(raw)

    # ---- writing: add vertices/indices to a mesh group, rebuilding its layout's buffers
    def add_to_group(self, mesh_index, group_index, new_verts, new_tris, group_relative=False):
        """new_verts: list of encoded vertex bytes for this mesh's layout; new_tris: index triples relative to the
        new vertices (0-based). Appended at the end of the group's vertex and index ranges; every other group of
        every mesh on the same layout is shifted."""
        M = self.meshes[mesh_index]
        li = M.layout
        L = self.layouts[li]
        G = M.groups[group_index]
        nv_add, ni_add = len(new_verts), 3 * len(new_tris)
        # all groups on this layout, by vertex range
        groups = [(m, g) for m in self.meshes if m.layout == li for g in m.groups]
        # vertex ranges can be shared by several groups of one mesh (same vo/nv): shift by vo
        vranges = sorted({(g.vo, g.nv) for _, g in groups})
        # build new vertex buffer: copy ranges in order, inserting after G's range
        old_v = self.vbuf[li]
        st = L.stride
        new_v = bytearray()
        vmap = {}
        pos = 0
        covered = 0
        for vo, nv in vranges:
            assert vo >= covered, ('overlapping vertex ranges', vo, covered)
            if vo > covered:                          # vertices not in any group: keep
                new_v += old_v[covered * st:vo * st]
            vmap[(vo, nv)] = len(new_v) // st
            new_v += old_v[vo * st:(vo + nv) * st]
            if (vo, nv) == (G.vo, G.nv):
                for b in new_verts: new_v += b
            covered = vo + nv
        new_v += old_v[covered * st:]
        # index ranges: per group, sorted by io
        iranges = sorted({(g.io, g.ni) for _, g in groups})
        old_i = self.ibuf[li]
        isz = L.isz
        if isz == 2 and G.nv + nv_add > 65535: raise ValueError('16-bit indices overflow')
        if isz == 2 and new_tris and max(k for t in new_tris for k in t) + (0 if group_relative else G.nv) > 65535:
            raise ValueError('16-bit indices overflow')
        new_i = bytearray()
        imap = {}
        coveri = 0
        for io, ni in iranges:
            if io < coveri:
                assert ni == 0 or io >= coveri, ('overlapping index ranges', io, coveri)
            if io > coveri:
                new_i += old_i[coveri * isz:io * isz]
            imap[(io, ni)] = len(new_i) // isz
            new_i += old_i[io * isz:(io + ni) * isz]
            if (io, ni) == (G.io, G.ni):
                base = 0 if group_relative else G.nv     # group_relative: indices already count from the group's vo
                fmt = '<%d%s' % (ni_add, 'H' if isz == 2 else 'I')
                new_i += struct.pack(fmt, *[base + k for tri in new_tris for k in tri])
            coveri = max(coveri, io + ni)
        new_i += old_i[coveri * isz:]
        # update groups (vertex counts for every group sharing G's vertex range)
        gkey = (G.vo, G.nv)
        for m, g in groups:
            vo2 = vmap[(g.vo, g.nv)]
            io2 = imap[(g.io, g.ni)]
            grew_v = (g.vo, g.nv) == gkey
            grew_i = g is G
            g.vo, g.io = vo2, io2
            if grew_v: g.nv = g.nv + nv_add
            if grew_i: g.ni = g.ni + ni_add
        self.vbuf[li] = bytes(new_v)
        self.ibuf[li] = bytes(new_i)
        L.nverts = len(new_v) // st
        L.nidx = len(new_i) // isz

    def write(self):
        """returns (main, gpu): buffers packed in layout order, offsets and counts written back into main"""
        d = self.main
        gpu = bytearray()
        for li, L in enumerate(self.layouts):
            L.voff = len(gpu); gpu += self.vbuf[li]; L.vsize = len(self.vbuf[li])
            L.ioff = len(gpu); gpu += self.ibuf[li]; L.isize = len(self.ibuf[li])
            struct.pack_into('<II', d, L.off + 352, L.nverts, L.stride)
            struct.pack_into('<I', d, L.off + 392, L.nidx)
            struct.pack_into('<IIII', d, L.off + 416, L.voff, L.vsize, L.ioff, L.isize)
        for M in self.meshes:
            for g in M.groups:
                struct.pack_into('<6I', d, g.off, g.mat, g.vo, g.nv, g.io, g.ni, g.gi)
        return bytes(d), bytes(gpu)

    # ---- helpers
    def mesh_tris(self, mi, gi=None):
        """[(group, (a,b,c) absolute vertex indices in the layout)]"""
        M = self.meshes[mi]
        out = []
        for k, g in enumerate(M.groups):
            if gi is not None and k != gi: continue
            idx = self.indices(M.layout, g.io, g.ni)
            for t in range(0, len(idx) - 2, 3):
                out.append((k, (g.vo + idx[t], g.vo + idx[t + 1], g.vo + idx[t + 2])))
        return out


def tile_of_uv(u, v):
    """the shader's tile: uint(u) + 32 * uint(1 - v)"""
    return int(math.floor(u)) + 32 * int(math.floor(1 - v))

import sys, os, importlib, bpy, bmesh, math, collections, mathutils
from mathutils.bvhtree import BVHTree
sys.path.insert(0, '.')
sdk = importlib.import_module('hd2sdk'); sdk.register()
sdk.CreateGameMaterial = lambda a, b: None
sdk.Global_gamepath = 'blendwork/data/'
from hd2sdk.utils import slim as _slim; _slim.slim_init('blendwork/data')
from hd2sdk import Global_TocManager, UnitID
bpy.context.scene.Hd2ToolPanelSettings.ImportLods = True
for mid in (0x75f87ad2ae08e9c2, 0xe7fd8eac41b5da79, 0x2d7ef36748bb42f4, 0x2bc2aecf229aeedb, 0x84b327056baf1c6d, 0x5990e5efbca8ae21, 0x8080d4fe57ad7888, 0x3acd5f632a67d5c6):
    bpy.data.materials.new(str(mid))
TANK = os.environ.get('TANK', 'bastion')
HULL, GUN = {'maelstrom': (0xb0c9faf4af8903f9, 0xd58ae6a04edb10de), 'bastion': (0x16474112801385b6, 0x1fa1f596769225c2)}[TANK]
Global_TocManager.LoadArchive('blendwork/final/9ba626afa44a3aa3.patch_0')
for fid in (HULL, GUN): Global_TocManager.GetEntry(fid, UnitID).Load(False, True)
def levels(fid):
    info = Global_TocManager.GetEntry(fid, UnitID).LoadedData.MeshInfoArray
    return {info[int(o['MeshInfoIndex'])].LodIndex: o for o in bpy.data.objects if o.type == 'MESH' and o.get('Z_ObjectID') == str(fid) and info[int(o['MeshInfoIndex'])].LodIndex >= 0}
HL, GL = levels(HULL), levels(GUN)
for lod in sorted(GL):
    g = GL[lod]; me = g.data; uv0 = me.uv_layers[0].data
    tiles = collections.Counter()
    for p in me.polygons:
        n = p.loop_total
        tiles[(math.floor(sum(uv0[i].uv[0] for i in p.loop_indices)/n), math.floor(sum(uv0[i].uv[1] for i in p.loop_indices)/n))] += 1
    h = HL.get(lod); above = sum(1 for p in h.data.polygons if (h.matrix_world @ p.center).z > 2.25) if h else -1
    bm = bmesh.new(); bm.from_mesh(me); bm.faces.ensure_lookup_table()
    hullmat = [i for i, m in enumerate(me.materials) if m and m.name.startswith('3278325203699712756')]
    tree = BVHTree.FromBMesh(bm); dbl = tot = 0
    for f in bm.faces:
        if f.material_index not in hullmat: continue
        tot += 1
        c = f.calc_center_median()
        loc, nor, idx, d = tree.ray_cast(c + f.normal * 1e-4, f.normal, 0.03)
        if loc is not None and idx != f.index and bm.faces[idx].normal.dot(f.normal) > 0.9: dbl += 1
    nb = me.attributes.get('hd2_normal_bits'); nz = sum(1 for d in nb.data if d.value) if nb else -1
    even = sum(c for (u, v), c in tiles.items() if u in {2,4,6,8,10,12,20,22,24,26} or v != 0)
    print(f'{TANK} lod{lod}: gun faces {len(me.polygons)}, damaged/stump tiles {even}, hull faces above deck {above}, hull-material faces {tot}, doubled {100*dbl/max(1,tot):.1f}%, normal bits set {nz}/{len(me.vertices)}')
bpy.ops.wm.save_as_mainfile(filepath=f'blendwork/verify_{TANK}.blend')

import sys, os, importlib, bpy
sys.path.insert(0, '.')
sdk = importlib.import_module('hd2sdk')
sdk.register()
sdk.CreateGameMaterial = lambda StingrayMat, mat: None   # geometry work only: skip textures
sdk.Global_gamepath = 'blendwork/data/'
from hd2sdk.utils import slim as _slim
_slim.slim_init('blendwork/data')
from hd2sdk import Global_TocManager, UnitID
ARCH = sys.argv[-2]; IDS = [int(x, 16) for x in sys.argv[-1].split(',')]
Global_TocManager.LoadArchive(f'blendwork/data/{ARCH}')
for fid in IDS:
    e = Global_TocManager.GetEntry(fid, UnitID)
    print('entry', hex(fid), e is not None)
    e.Load(False, True)
print('--- objects')
for o in bpy.data.objects:
    if o.type == 'MESH':
        me = o.data
        vg = [g.name for g in o.vertex_groups][:6]
        print(o.name, 'verts', len(me.vertices), 'loc', tuple(round(v,3) for v in o.location), 'parent', o.parent.name if o.parent else None,
              'groups', len(o.vertex_groups), vg, 'bbox', [tuple(round(c,2) for c in o.bound_box[0]), tuple(round(c,2) for c in o.bound_box[6])])
    elif o.type == 'ARMATURE':
        print(o.name, 'ARMATURE bones', len(o.data.bones), [b.name for b in o.data.bones][:40])
bpy.ops.wm.save_as_mainfile(filepath=f'blendwork/{ARCH}.blend')

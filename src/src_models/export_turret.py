exec(open('blendwork/build_turret.py').read())
import shutil
Global_TocManager.CreatePatchFromActive('Armored Overhaul turret models')
bpy.context.scene.Hd2ToolPanelSettings.AutoLods = False     # every level is built by hand; don't copy lod0 over them
for fid, objs in UNIT_OBJECTS.items():
    for x in bpy.data.objects: x.select_set(False)
    for o in objs: o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    r = bpy.ops.helldiver2.archive_unit_save(object_id=objs[0]['Z_ObjectID'])
    print('saved', hex(fid), [o.name for o in objs], r)
out = f'blendwork/patch_out_{TANK}'; os.makedirs(out, exist_ok=True)
Global_TocManager.ActivePatch.ToFile(out + '/9ba626afa44a3aa3.patch_0')
print('patch written', [ (f, os.path.getsize(os.path.join(out, f))) for f in os.listdir(out)])

import bpy, sys, math, mathutils
blend, out = sys.argv[-2], sys.argv[-1]
bpy.ops.wm.open_mainfile(filepath=blend)
sc = bpy.context.scene
grig = bpy.data.objects['15387364653056856286_rig']; grig.location = (0, -1.959, 2.525)
mat = bpy.data.materials.new('grey'); mat.use_nodes = True
mat.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.55, 0.57, 0.5, 1)
tm = bpy.data.materials.new('tur'); tm.use_nodes = True
tm.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.35, 0.5, 0.7, 1)
for o in bpy.data.objects:
    if o.type == 'MESH':
        m = tm if o.name.startswith('15387364653056856286') else mat
        o.data.materials.clear(); o.data.materials.append(m)
        for p in o.data.polygons: p.material_index = 0
sc.render.engine = 'CYCLES'; sc.cycles.samples = 12; sc.cycles.device = 'CPU'
sc.render.resolution_x, sc.render.resolution_y = 640, 400
world = bpy.data.worlds.new('w'); world.use_nodes = True
world.node_tree.nodes['Background'].inputs['Strength'].default_value = 0.6; sc.world = world
sun = bpy.data.objects.new('sun', bpy.data.lights.new('sun', 'SUN')); sun.data.energy = 4
sun.rotation_euler = (math.radians(50), 0, math.radians(30)); sc.collection.objects.link(sun)
cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam')); sc.collection.objects.link(cam); sc.camera = cam
target = mathutils.Vector((0, -0.8, 1.8))
pb = grig.pose.bones['traverse']; pb.rotation_mode = 'XYZ'
for yaw in (0, 90):
    pb.rotation_euler = (0, 0, 0)
    # traverse bone's local axes may differ from world: rotate about the world up axis through the bone
    bone = grig.data.bones['traverse']
    up_local = (bone.matrix_local.to_3x3().inverted() @ mathutils.Vector((0, 0, 1))).normalized()
    pb.rotation_mode = 'QUATERNION'; pb.rotation_quaternion = mathutils.Quaternion(up_local, math.radians(yaw))
    bpy.context.view_layer.update()
    for name, pos in (('front34', (8, 9, 6)), ('top', (0.01, -1.5, 14))):
        cam.location = pos; cam.rotation_euler = (target - cam.location).to_track_quat('-Z', 'Y').to_euler()
        sc.render.filepath = f'{out}_{yaw}_{name}.png'; bpy.ops.render.render(write_still=True); print('wrote', sc.render.filepath)

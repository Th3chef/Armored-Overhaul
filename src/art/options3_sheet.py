"""Page image with the Arsenal option icons and their names, in the Arsenal order (options_icons.png), two rows (3.2: 14 options)."""
from PIL import Image, ImageDraw, ImageFont
f = ImageFont.truetype('Oswald-VF.ttf', 30); f.set_variation_by_axes([600])
names = [('tank_power', 'TANK POWER'), ('tank_grip', 'TANK GRIP'), ('tank_steering', 'TANK STEERING'),
         ('tank_suspension', 'TANK SUSPENSION'), ('mbt_turrets', 'TANK MBT TURRETS'), ('turret_traverse', 'TURRET TRAVERSE'),
         ('turret_elevation', 'TURRET ELEVATION'), ('turret_aim_range', 'TURRET AIM RANGE'), ('autoloader', 'TANK AUTOLOADER'),
         ('gunner_drive', 'GUNNER DRIVE'), ('driver_panel', 'DRIVER PANEL'), ('gunner_camera', 'TANK GUNNER CAMERA'), ('frv_stability', 'FRV STABILITY'),
         ('turret_indicator', 'VEHICLE INDICATOR')]
cols = 7; rows = (len(names) + cols - 1) // cols
cw, ch = 296, 256 + 100
im = Image.new('RGB', (cols * cw + 40, rows * ch + 40), (18, 18, 20)); d = ImageDraw.Draw(im)
for i, (n, t) in enumerate(names):
    r, c = divmod(i, cols)
    off = (cols - (len(names) - r * cols)) * cw // 2 if r == rows - 1 else 0     # centre the shorter last row
    x, y = 40 + c * cw + off, 40 + r * ch
    im.paste(Image.open('options/%s.png' % n).convert('RGB').resize((256, 256), Image.LANCZOS), (x, y))
    size = 30
    while d.textlength(t, font=f) > cw - 20 and size > 20:
        size -= 1; f = ImageFont.truetype('Oswald-VF.ttf', size); f.set_variation_by_axes([600])
    d.text((x + 128, y + 256 + 18), t, font=f, fill=(255, 255, 255), anchor='mt')
    f = ImageFont.truetype('Oswald-VF.ttf', 30); f.set_variation_by_axes([600])
im.save('options_icons.png'); print(im.size)

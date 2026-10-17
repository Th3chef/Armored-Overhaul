"""'What's in 3.5' page photo (features_1920x1080.png): the twenty Arsenal options with their icons and one line each, over the darkened 16:9 art. python3 features3.py (needs clean_wide.png and options/)."""
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageEnhance

ART = '.'
OPT = 'options'
YELLOW = (255, 196, 0)
W, H = 1920, 1080


def font(size, weight):
    f = ImageFont.truetype(ART + '/Oswald-VF.ttf', size)
    f.set_variation_by_axes([weight])
    return f


# Arsenal order (3.6); tag = group, badge = what changed since 3.5
CARDS = [
    ('tank_speed', 'TANK TOP SPEED', 'HANDLING', 'Faster forward and in reverse, up to x1.3.', None),
    ('tank_power', 'ENGINE TORQUE', 'HANDLING', 'More pull off the line and up slopes, live.', None),
    ('tank_grip', 'TANK GRIP', 'HANDLING', 'Tracks hold their line, changed live.', None),
    ('tank_steering', 'TANK STEERING', 'HANDLING', 'Quicker to start and stop turning.', None),
    ('tank_throttle', 'THROTTLE RESPONSE', 'HANDLING', 'Snappier throttle, brake and gear changes.', None),
    ('tank_stability', 'TANK STABILITY', 'HANDLING', 'Downforce keeps the tank on the ground.', None),
    ('tank_collision_damage', 'COLLISION DAMAGE', 'HANDLING', 'Ram through walls and small buildings at speed.', None),
    ('maelstrom_fire_rate', 'FIRE RATE', 'MAELSTROM', 'Hold reload: 1200, 1800 or 2400 rpm.', 'NEW'),
    ('maelstrom_belt', 'SINGLE BELT', 'MAELSTROM', 'All 2,100 rounds on one belt, no reload.', 'NEW'),
    ('mbt_turrets', 'TANK MBT TURRETS', 'TURRET', 'New turret, working hatches, hit areas follow it.', 'UPDATED'),
    ('tank_suspension', 'TANK SUSPENSION', 'HANDLING', 'A calm ride, tighter turns at speed.', None),
    ('turret_traverse', 'TURRET TRAVERSE', 'TURRET', 'Up to three times as fast, tanks out too.', None),
    ('turret_elevation', 'TURRET ELEVATION', 'TURRET', 'Up and down up to twice as fast.', None),
    ('gun_depression', 'GUN DEPRESSION', 'TURRET', 'Aim down to 15° below level.', None),
    ('gun_raise', 'GUN RAISE', 'TURRET', 'Aim up to 60° above level, on slopes too.', 'UPDATED'),
    ('autoloader', 'TANK AUTOLOADER', 'TURRET', 'The main gun reloads by itself.', None),
    ('gunner_drive', 'GUNNER DRIVE', 'GUNNER SEAT', 'Drive tanks and the FRV from the gunner seat.', None),
    ('driver_panel', 'DRIVER PANEL', 'GUNNER SEAT', 'Gear, rpm, speed and fuel while you drive.', None),
    ('gunner_camera', 'GUNNER CAMERA', 'GUNNER SEAT', 'Farther, steadier, zoom up to x10.', None),
    ('frv_stability', 'FRV STABILITY', 'FRV', 'The FRVs stay on their wheels.', None),
    ('frv_run_flat', 'FRV RUN-FLAT TIRES', 'FRV', 'The FRVs\' tires never pop.', 'NEW'),
    ('turret_indicator', 'VEHICLE INDICATOR', 'HUD', 'Your vehicle, gun and Supply FRV turret ammo.', 'UPDATED'),
    ('vehicle_loadout', 'VEHICLE LOADOUT', 'LOADOUT', 'More than one vehicle per mission.', None),
]


def wrap(d, text, f, width):
    words, lines, cur = text.split(), [], ''
    for w in words:
        t = (cur + ' ' + w).strip()
        if d.textlength(t, font=f) <= width: cur = t
        else: lines.append(cur); cur = w
    lines.append(cur)
    return lines


def menu_icon(size):
    """A simple sliders glyph for the Mod Options Menu card, in the option icons' colours."""
    ss = 4; S = size * ss
    im = Image.new('RGBA', (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    d.rectangle([0, 0, S - 1, S - 1], fill=(22, 22, 26, 255)); w = int(S * 0.075)
    d.rectangle([w // 2, w // 2, S - 1 - w // 2, S - 1 - w // 2], outline=YELLOW + (255,), width=w)
    for i, k in enumerate((0.3, 0.68, 0.45)):
        y = int(S * (0.3 + 0.2 * i))
        d.rounded_rectangle([int(S * 0.18), y - int(S * 0.025), int(S * 0.82), y + int(S * 0.025)], int(S * 0.02), fill=(200, 200, 200, 255))
        cx = int(S * (0.18 + 0.64 * k)); r = int(S * 0.075)
        d.ellipse([cx - r, y - r, cx + r, y + r], fill=YELLOW + (255,))
    return im.resize((size, size), Image.LANCZOS)


def main():
    bg = Image.open(ART + '/clean_wide.png').convert('RGB').resize((W, H), Image.LANCZOS)
    bg = bg.filter(ImageFilter.GaussianBlur(10))
    bg = ImageEnhance.Brightness(bg).enhance(0.38)
    im = bg.convert('RGBA')
    d = ImageDraw.Draw(im)
    d.rectangle([60, 56, 290, 166], fill=YELLOW)
    d.text((175, 111), '3.6', font=font(104, 700), fill=(14, 14, 16), anchor='mm')
    d.text((326, 106), 'ARMORED ', font=font(84, 700), fill=(255, 255, 255), anchor='ls', stroke_width=2, stroke_fill=(10, 10, 12))
    x = 326 + d.textlength('ARMORED ', font=font(84, 700))
    d.text((x, 106), 'OVERHAUL', font=font(84, 700), fill=YELLOW, anchor='ls', stroke_width=2, stroke_fill=(10, 10, 12))
    d.text((330, 160), 'TWENTY-THREE OPTIONS  •  NEW: MAELSTROM WEAPONS, FRV RUN-FLAT TIRES', font=font(27, 500), fill=(215, 215, 215), anchor='ls')
    d.text((1860, 106), "WHAT'S IN 3.6", font=font(64, 700), fill=YELLOW, anchor='rs', stroke_width=2, stroke_fill=(10, 10, 12))
    d.text((1860, 158), 'TD-220 BASTION  •  TD-110 MAELSTROM  •  FRVS', font=font(30, 600), fill=(255, 255, 255), anchor='rs')
    cols, x0, y0, gx, gy = 6, 60, 204, 14, 14
    cw = (1800 - gx * (cols - 1)) // cols
    ch = (1050 - y0 - gy * 3) // 4
    icon = 80
    fd, ft, fb = font(21, 500), font(17, 600), font(18, 700)
    for i, (key, name, tag, desc, badge) in enumerate(CARDS):
        r, c = divmod(i, cols)
        x, y = x0 + c * (cw + gx), y0 + r * (ch + gy)
        w = cw
        card = Image.new('RGBA', (w, ch), (0, 0, 0, 0))
        ImageDraw.Draw(card).rounded_rectangle([0, 0, w - 1, ch - 1], 14, fill=(14, 14, 16, 205), outline=(70, 70, 74, 255), width=2)
        im.alpha_composite(card, (x, y))
        d.rectangle([x, y + 14, x + 6, y + ch - 14], fill=YELLOW)
        ic = menu_icon(icon) if key is None else Image.open('%s/%s.png' % (OPT, key)).convert('RGBA').resize((icon, icon), Image.LANCZOS)
        im.alpha_composite(ic, (x + 22, y + 18))
        tx = x + 22 + icon + 16
        d.text((tx, y + 40), tag, font=ft, fill=(170, 170, 170), anchor='ls')
        size = 30
        while d.textlength(name, font=font(size, 700)) > w - tx + x - 16 and size > 18: size -= 1
        d.text((tx, y + 82), name, font=font(size, 700), fill=(255, 255, 255), anchor='ls')
        if badge:
            bw = d.textlength(badge, font=fb) + 20
            bx = x + w - 16 - bw
            d.rounded_rectangle([bx, y + 20, bx + bw, y + 48], 5, fill=YELLOW if badge == 'NEW' else (255, 255, 255))
            d.text((bx + 10, y + 34), badge, font=fb, fill=(14, 14, 16), anchor='lm')
        lines = wrap(d, desc, fd, w - 44)
        for k, line in enumerate(lines[:2]):
            d.text((x + 22, y + 132 + k * 29), line, font=fd, fill=(225, 225, 225), anchor='ls')
        if len(lines) > 2: print('WARNING: description cut:', name)
    im.convert('RGB').save(ART + '/features_1920x1080.png')
    print('features written')


if __name__ == '__main__':
    main()

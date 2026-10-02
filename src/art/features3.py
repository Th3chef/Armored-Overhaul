"""'What's in 3.0' page photo (features_1920x1080.png): the thirteen Arsenal options with their icons and one line each,
plus the Mod Options Menu, over the darkened 16:9 art. python3 features3.py (needs clean_wide.png and options/)."""
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageEnhance

ART = '.'
OPT = 'options'
YELLOW = (255, 196, 0)
W, H = 1920, 1080


def font(size, weight):
    f = ImageFont.truetype(ART + '/Oswald-VF.ttf', size)
    f.set_variation_by_axes([weight])
    return f


# Arsenal order (3.0); tag = group, badge = what changed since 2.0.1
CARDS = [
    ('tank_power', 'TANK POWER', 'HANDLING', 'More pulling power: quicker off the line and up slopes.', None),
    ('tank_grip', 'TANK GRIP', 'HANDLING', 'Tracks hold their line on slopes and in turns.', None),
    ('tank_steering', 'TANK STEERING', 'HANDLING', 'Quicker to start and stop turning.', None),
    ('tank_suspension', 'TANK SUSPENSION', 'HANDLING', 'Stiffer and better damped: less bounce and roll.', None),
    ('mbt_turrets', 'TANK MBT TURRETS', 'TURRET', 'The whole top of the tank turns all the way round.', None),
    ('turret_traverse', 'TURRET TRAVERSE', 'TURRET', 'Turns side to side up to twice as fast.', None),
    ('turret_elevation', 'TURRET ELEVATION', 'TURRET', 'Moves up and down up to twice as fast.', None),
    ('turret_aim_range', 'TURRET AIM RANGE', 'TURRET', 'Aims lower and higher: new Wide choice, up to -15° / +45°.', 'UPDATED'),
    ('autoloader', 'TANK AUTOLOADER', 'TURRET', 'The main gun reloads by itself when it runs dry.', 'NEW'),
    ('gunner_drive', 'GUNNER DRIVE', 'GUNNER SEAT', 'Drive tanks and the FRV from the gunner seat. Horn and controller.', 'UPDATED'),
    ('gunner_camera', 'TANK GUNNER CAMERA', 'GUNNER SEAT', 'Lower and further behind the turret: four distances.', None),
    ('frv_stability', 'FRV STABILITY', 'FRV', 'Retuned: FRVs stay on their wheels. Mild, Stable or Planted.', 'UPDATED'),
    ('turret_indicator', 'VEHICLE INDICATOR', 'ANY SEAT', 'Was the Turret indicator: now in tanks and FRVs, tire by tire.', 'UPDATED'),
    (None, 'MOD OPTIONS MENU', 'IN GAME', "Change the options you installed in game, under MODS, ARMORED OVERHAUL (CowboyBingus's Mod Options Menu, optional).", 'NEW'),
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
    d.text((175, 111), '3.0', font=font(104, 700), fill=(14, 14, 16), anchor='mm')
    d.text((326, 106), 'ARMORED ', font=font(84, 700), fill=(255, 255, 255), anchor='ls', stroke_width=2, stroke_fill=(10, 10, 12))
    x = 326 + d.textlength('ARMORED ', font=font(84, 700))
    d.text((x, 106), 'OVERHAUL', font=font(84, 700), fill=YELLOW, anchor='ls', stroke_width=2, stroke_fill=(10, 10, 12))
    d.text((330, 160), 'THIRTEEN OPTIONS  •  NOW ALSO IN GAME', font=font(32, 500), fill=(215, 215, 215), anchor='ls')
    d.text((1860, 106), "WHAT'S IN 3.0", font=font(64, 700), fill=YELLOW, anchor='rs', stroke_width=2, stroke_fill=(10, 10, 12))
    d.text((1860, 158), 'TD-220 BASTION  •  TD-110 MAELSTROM  •  FRVS', font=font(30, 600), fill=(255, 255, 255), anchor='rs')
    cols, x0, y0, gx, gy = 5, 60, 214, 18, 22
    cw = (1800 - gx * (cols - 1)) // cols
    ch = (1050 - y0 - gy * 2) // 3
    icon = 104
    fd, ft, fb = font(23, 500), font(18, 600), font(19, 700)
    for i, (key, name, tag, desc, badge) in enumerate(CARDS):
        r, c = divmod(i, cols)
        span = 2 if key is None else 1
        x, y = x0 + c * (cw + gx), y0 + r * (ch + gy)
        w = cw * span + gx * (span - 1)
        card = Image.new('RGBA', (w, ch), (0, 0, 0, 0))
        ImageDraw.Draw(card).rounded_rectangle([0, 0, w - 1, ch - 1], 14, fill=(14, 14, 16, 205), outline=(70, 70, 74, 255), width=2)
        im.alpha_composite(card, (x, y))
        d.rectangle([x, y + 14, x + 6, y + ch - 14], fill=YELLOW)
        ic = menu_icon(icon) if key is None else Image.open('%s/%s.png' % (OPT, key)).convert('RGBA').resize((icon, icon), Image.LANCZOS)
        im.alpha_composite(ic, (x + 24, y + 22))
        tx = x + 24 + icon + 18
        d.text((tx, y + 46), tag, font=ft, fill=(170, 170, 170), anchor='ls')
        if badge:
            bw = d.textlength(badge, font=fb) + 20
            d.rounded_rectangle([tx, y + 62, tx + bw, y + 92], 5, fill=YELLOW if badge == 'NEW' else (255, 255, 255))
            d.text((tx + 10, y + 78), badge, font=fb, fill=(14, 14, 16), anchor='lm')
        size = 32
        while d.textlength(name, font=font(size, 700)) > w - 48 and size > 20: size -= 1
        d.text((x + 24, y + 166), name, font=font(size, 700), fill=(255, 255, 255), anchor='ls')
        lines = wrap(d, desc, fd, w - 48)
        for k, line in enumerate(lines[:2]):
            d.text((x + 24, y + 202 + k * 31), line, font=fd, fill=(225, 225, 225), anchor='ls')
        if len(lines) > 2: print('WARNING: description cut:', name)
    im.convert('RGB').save(ART + '/features_1920x1080.png')
    print('features written')


if __name__ == '__main__':
    main()

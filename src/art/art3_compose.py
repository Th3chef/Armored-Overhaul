"""Armored Overhaul 3.1 art: grades the Bastion / Maelstrom / FRV renders (scene3.py) into the square thumbnail, the 16:9
gallery photo, the Nexus header and the 2:1 GitHub social picture.
  python3 art3_compose.py [square] [wide] [header] [social]   (needs R/sq.png, R/mask_sq.png, R/mist_sq_0001.png, the same for wd and hd)
Outputs: thumbnail_1254.png, thumbnail_512.png (Arsenal), gallery_1920x1080.png, clean_square.png (no text, for icons)."""
import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ART = '.'
R = '../final'
FONT = ART + '/Oswald-VF.ttf'
YELLOW = (255, 196, 0)
VERSION = '3.1'
TAG1, TAG2 = 'DRIVE  \u2022  FIGHT  \u2022  RELOAD', 'COMMAND YOUR ARMOR'
VEHICLES = 'TD-220 BASTION  \u2022  TD-110 MAELSTROM  \u2022  M-102 FRV'
FEATURES_SQUARE = ['TANK POWER  •  GRIP  •  STEERING  •  SUSPENSION',
                   '360° MBT TURRETS  •  TRAVERSE  •  ELEVATION  •  AIM RANGE',
                   'AUTOLOADER  •  GUNNER DRIVE  •  GUNNER CAMERA',
                   'FRV STABILITY  •  VEHICLE INDICATOR  •  MOD OPTIONS MENU']   # (3.0) Arsenal option order, then the menu
FEATURES = ['TANK POWER  •  GRIP  •  STEERING  •  SUSPENSION  •  360° MBT TURRETS  •  TRAVERSE  •  ELEVATION  •  AIM RANGE',
            'AUTOLOADER  •  GUNNER DRIVE  •  GUNNER CAMERA  •  FRV STABILITY  •  VEHICLE INDICATOR  •  MOD OPTIONS MENU']


def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_axes([weight])
    return f


def blur(a, r):
    """Gaussian blur of a float HxW or HxWxC array (via PIL, per channel)."""
    return cv2.GaussianBlur(np.ascontiguousarray(a, np.float32), (0, 0), r)


def fractal(h, w, seed, octaves=6, base=4):
    rng = np.random.default_rng(seed)
    out = np.zeros((h, w), np.float32); amp, tot = 1.0, 0.0
    for o in range(octaves):
        n = base * 2 ** o
        small = rng.random((n, max(2, int(n * w / h)))).astype(np.float32)
        out += amp * np.asarray(Image.fromarray(small, 'F').resize((w, h), Image.BICUBIC), np.float32)
        tot += amp; amp *= 0.55
    out /= tot
    return (out - out.min()) / (out.max() - out.min() + 1e-6)


def horizon_row(img):
    """The render's horizon: the biggest brightness drop down the left edge (sky above, ground below)."""
    col = img[:, 8:40].mean(1).mean(-1)
    d = col[1:] - col[:-1]
    lo, hi = int(len(col) * 0.3), int(len(col) * 0.8)
    return lo + int(np.argmin(d[lo:hi]))


def grade(render, mask, seed=7, mist=None):
    img = np.asarray(render.convert('RGB'), np.float32) / 255.0
    H, W = img.shape[:2]
    tank = np.asarray(mask.getchannel('A'), np.float32) / 255.0
    tank = np.clip(blur(tank, 1.2) * 1.15, 0, 1)
    # (3.0) the vehicles are backlit by the low sun: lift them a little so the paint and panels read
    lift = float(__import__('os').environ.get('LIFT', '0.8'))
    img = img * (1 + lift * tank)[..., None]
    yy = np.arange(H, dtype=np.float32)[:, None] / H
    if mist is not None:
        # distance pass: sky = nothing hit; the horizon row = where the sky ends on average
        dist = np.asarray(mist.convert('I;16').resize((W, H), Image.BILINEAR) if mist.mode.startswith('I') else
                          mist.convert('L').resize((W, H), Image.BILINEAR), np.float32)
        dist = dist / dist.max()
        sky = (dist > 0.995).astype(np.float32)
        rows = sky.mean(1)
        hz = int(np.argmax(rows < 0.5)) if (rows < 0.5).any() else H // 2
        sky = blur(sky, 1.5) * (1 - tank)
    else:
        dist = None
        hz = horizon_row(img)
        sky = (np.arange(H)[:, None] < hz).astype(np.float32) * np.ones((1, W), np.float32)
        sky = blur(sky, 3) * (1 - tank)
    ground = np.clip(1 - sky - tank, 0, 1)

    # sky: darker toward the top, drifting battle smoke, warm glow low down
    top = np.clip(yy / (hz / H), 0, 1)
    img *= (1 - sky * (0.55 * (1 - top) ** 1.4))[..., None]
    smoke = fractal(H, W, seed, 7, 3)
    smoke = np.clip((smoke - 0.42) * 2.2, 0, 1) * np.clip(1.2 - top, 0, 1)
    img = img * (1 - (sky * smoke * 0.55)[..., None]) + (sky * smoke * 0.55)[..., None] * np.array([0.06, 0.05, 0.045])

    # ground: warm dusty dirt instead of the flat grey plane, darker toward the viewer, with grit
    grit = fractal(H, W, seed + 1, 7, 8)
    tint = np.array([0.95, 0.72, 0.52]) * (0.85 + 0.3 * grit)[..., None]
    img = img * (1 - ground[..., None]) + (img * tint * (1 - 0.45 * np.clip((yy - hz / H) / (1 - hz / H), 0, 1))[..., None]) * ground[..., None]

    # horizon haze: soft warm band that hides the hard edge of the ground plane (with a distance pass: haze by distance,
    # so the far ridges fade into the dusk)
    band = np.exp(-((np.arange(H, dtype=np.float32) - hz) / (H * 0.045)) ** 2)[:, None] * np.ones((1, W), np.float32)
    if dist is not None:
        far = np.clip(dist, 0, 1) ** 0.8 * (1 - sky) * (1 - tank)
        band = np.maximum(band * 0.6, far * 0.95)
    haze = band * (1 - 0.75 * tank)
    img = 1 - (1 - img) * (1 - (haze * 0.55)[..., None] * np.array([1.0, 0.62, 0.28]))

    if dist is not None:
        img = battlefield(img, sky, dist, tank, hz, seed)

    # bloom on the bright rim light
    bright = np.clip((img.max(-1) - 0.62) / 0.38, 0, 1)
    glow = blur(img * bright[..., None], W * 0.012)
    img = 1 - (1 - img) * (1 - 0.55 * glow)

    # grade: S-curve, cool shadows, warm highlights
    lum = img.mean(-1, keepdims=True)
    img = img + (img - 0.5) * 0.18 * (1 - np.abs(img - 0.5) * 2)
    img = img + (1 - lum) ** 3 * np.array([-0.012, 0.0, 0.03]) + lum ** 2 * np.array([0.03, 0.012, -0.02])
    # vignette
    xx = np.linspace(-1, 1, W)[None, :]; y2 = np.linspace(-1, 1, H)[:, None]
    vig = 1 - 0.38 * np.clip(np.sqrt(xx ** 2 * 0.8 + y2 ** 2 * 0.9) - 0.35, 0, 1) ** 1.4
    img *= vig[..., None]
    return np.clip(img, 0, 1), hz


def battlefield(img, sky, dist, tank, hz, seed):
    """Far battle: smoke columns rising from the horizon with fire glow at their base, and a few drifting embers.
    Only behind the tank (weighted by the sky / far-distance mask)."""
    H, W = img.shape[:2]
    rng = np.random.default_rng(seed + 20)
    behind = np.clip(np.maximum(sky, np.clip((dist - 0.25) / 0.5, 0, 1)), 0, 1) * (1 - tank)
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    turb = fractal(H, W, seed + 30, 7, 4) - 0.5
    # far fires: burning wreckage on the horizon, each with a small warm glow and a thin wisp of smoke above it
    for fx, sz in ((0.06, 1.0), (0.83, 0.7), (0.95, 1.2)):
        x0 = fx * W; base = hz + H * 0.004
        glow = np.exp(-(((xx - x0) / (W * 0.035 * sz)) ** 2 + ((yy - base) / (H * 0.018 * sz)) ** 2)) * (1 - tank)
        hot = np.exp(-(((xx - x0) / (W * 0.006 * sz)) ** 2 + ((yy - base) / (H * 0.004 * sz)) ** 2)) * behind
        img = 1 - (1 - img) * (1 - glow[..., None] * np.array([1.0, 0.42, 0.08]) * 0.75)
        img = 1 - (1 - img) * (1 - hot[..., None] * np.array([1.0, 0.8, 0.45]))
        up = np.clip((base - yy) / (H * 0.3 * sz), 0, 1)
        drift = x0 + up ** 1.5 * W * 0.05 + turb * W * 0.03 * up
        wisp = np.exp(-((xx - drift) / (W * 0.008 * sz * (1 + 5 * up))) ** 2) * (yy < base) * np.clip(up / 0.05, 0, 1)
        a = wisp * (1 - up) ** 1.5 * np.clip(0.5 + turb * 1.5, 0, 1) * 0.6 * behind
        img = img * (1 - a[..., None]) + a[..., None] * np.array([0.08, 0.065, 0.055])
    return img


def bottom_fade(img, start, strength=0.92):
    H = img.shape[0]
    yy = np.arange(H, dtype=np.float32)[:, None] / H
    f = np.clip((yy - start) / (1 - start), 0, 1) ** 1.3 * strength
    return img * (1 - f)[..., None] + f[..., None] * np.array([0.03, 0.028, 0.03])


def text(d, xy, s, f, fill, stroke=0, anchor='la'):
    d.text(xy, s, font=f, fill=fill, anchor=anchor, stroke_width=stroke, stroke_fill=(10, 10, 12))


def cap(f):
    return -f.getbbox('H', anchor='ls')[1]


def title_block(d, x, baseline, sz, gaps, bar_w, features=None):
    """Stacks the title bottom-up from the feature line's baseline. sz = (armored, overhaul, dogs, features).
    features: one line, or a list of lines (top first) when one line would not fit."""
    fa, fo, fd, ff = font(sz[0], 700), font(sz[1], 700), font(sz[2], 600), font(sz[3], 500)
    lines = features or FEATURES
    if isinstance(lines, str): lines = [lines]
    step = int(cap(ff) * 1.75)
    b_feat = baseline
    b_first = b_feat - step * (len(lines) - 1)
    b_dog = b_first - cap(ff) - gaps[0]
    b_over = b_dog - cap(fd) - gaps[1]
    b_arm = b_over - cap(fo) - gaps[2]
    xi = x + bar_w * 4
    d.rectangle([x + bar_w // 2, b_dog - cap(fd), x + bar_w // 2 + bar_w, b_feat], fill=YELLOW)
    for i, line in enumerate(lines):
        text(d, (xi, b_first + step * i), line, ff, (215, 215, 215), anchor='ls')
    text(d, (xi, b_dog), VEHICLES, fd, (255, 255, 255), anchor='ls')
    stroke = max(2, sz[0] // 60)
    text(d, (x - sz[1] // 60, b_over), 'OVERHAUL', fo, YELLOW, stroke, 'ls')
    text(d, (x, b_arm), 'ARMORED', fa, (255, 255, 255), stroke, 'ls')
    return b_arm - cap(fa)


def square():
    render = Image.open(R + '/sq.png'); mask = Image.open(R + '/mask_sq.png')
    img, hz = grade(render, mask, mist=Image.open(R + '/mist_sq_0001.png'))
    Image.fromarray((img * 255).astype(np.uint8)).save(ART + '/clean_square.png')
    img = bottom_fade(img, 0.66, 0.9)
    im = Image.fromarray((img * 255).astype(np.uint8)); d = ImageDraw.Draw(im)
    S = im.width / 1600
    def s(v): return int(round(v * S))
    # badge
    d.rectangle([s(72), s(72), s(330), s(206)], fill=YELLOW)
    text(d, (s(201), s(139)), VERSION, font(s(118), 700), (14, 14, 16), anchor='mm')
    # tagline, top right
    text(d, (s(1540), s(72)), TAG1, font(s(62), 600), (255, 255, 255), s(4), 'ra')
    text(d, (s(1540), s(146)), TAG2, font(s(76), 700), YELLOW, s(4), 'ra')
    # title block
    top = title_block(d, s(70), s(1540), (s(195), s(260), s(58), s(34)), (s(24), s(40), s(32)), s(10), FEATURES_SQUARE)
    print('square title top', top, 'of', im.height)
    im.resize((1254, 1254), Image.LANCZOS).save(ART + '/thumbnail_1254.png')
    im.resize((512, 512), Image.LANCZOS).save(ART + '/thumbnail_512.png')


def wide():
    render = Image.open(R + '/wd.png'); mask = Image.open(R + '/mask_wd.png')
    img, hz = grade(render, mask, seed=11, mist=Image.open(R + '/mist_wd_0001.png'))
    # left side darker for the title
    W = img.shape[1]
    xx = np.arange(W, dtype=np.float32)[None, :] / W
    side = np.clip((0.55 - xx) / 0.55, 0, 1) ** 1.5 * 0.55
    img = img * (1 - side)[..., None]
    img = bottom_fade(img, 0.62, 0.9)
    im = Image.fromarray((img * 255).astype(np.uint8)).resize((1920, 1080), Image.LANCZOS)
    Image.fromarray((np.asarray(im))).save(ART + '/clean_wide.png')
    d = ImageDraw.Draw(im)
    d.rectangle([60, 56, 290, 166], fill=YELLOW)
    text(d, (175, 111), VERSION, font(104, 700), (14, 14, 16), anchor='mm')
    text(d, (1860, 64), TAG1, font(46, 600), (255, 255, 255), 3, 'ra')
    text(d, (1860, 120), TAG2, font(58, 700), YELLOW, 3, 'ra')
    top = title_block(d, 64, 1036, (112, 150, 42, 26), (18, 26, 20), 8)
    print('wide title top', top)
    im.save(ART + '/gallery_1920x1080.png')


def header():
    """Nexus page header, 1300x372, from its own 3.5:1 render (hd.png: the vehicles on the right, room for the title)."""
    render = Image.open(R + '/hd.png'); mask = Image.open(R + '/mask_hd.png')
    img, hz = grade(render, mask, seed=13, mist=Image.open(R + '/mist_hd_0001.png'))
    H, W = img.shape[:2]
    xx = np.arange(W, dtype=np.float32)[None, :] / W
    side = np.clip((0.6 - xx) / 0.6, 0, 1) ** 1.3 * 0.6
    img = img * (1 - side)[..., None]
    im = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).resize((1300, 372), Image.LANCZOS)
    d = ImageDraw.Draw(im)
    fa, fs = font(70, 700), font(27, 600)
    base = 196
    text(d, (46, base), 'ARMORED', fa, (255, 255, 255), 3, 'ls')
    x = 46 + fa.getlength('ARMORED ') + 4
    text(d, (x, base), 'OVERHAUL', fa, YELLOW, 3, 'ls')
    d.rectangle([48, base + 26, 54, base + 26 + cap(fs) + 88], fill=YELLOW)
    text(d, (68, base + 26 + cap(fs)), VEHICLES, fs, (255, 255, 255), anchor='ls')
    ff = font(19, 500)
    for i, line in enumerate(['POWER  \u2022  GRIP  \u2022  STEERING  \u2022  SUSPENSION  \u2022  360\u00b0 MBT TURRETS',
                              'TRAVERSE  \u2022  ELEVATION  \u2022  AIM RANGE  \u2022  AUTOLOADER  \u2022  GUNNER DRIVE',
                              'GUNNER CAMERA  \u2022  FRV STABILITY  \u2022  VEHICLE INDICATOR  \u2022  MOD OPTIONS MENU']):
        text(d, (68, base + 26 + cap(fs) + 32 + i * 28), line, ff, (215, 215, 215), anchor='ls')
    d.rectangle([46, 40, 150, 92], fill=YELLOW)
    text(d, (98, 66), VERSION, font(46, 700), (14, 14, 16), anchor='mm')
    im.save(ART + '/header_1300x372.png')


def social():
    """GitHub social preview, 1280x640: the clean 16:9 art cropped to 2:1, with the badge, tagline and title block."""
    im = Image.open(ART + '/clean_wide.png').convert('RGB').resize((1280, 720), Image.LANCZOS).crop((0, 40, 1280, 680))
    d = ImageDraw.Draw(im)
    d.rectangle([40, 36, 194, 110], fill=YELLOW)
    text(d, (117, 73), VERSION, font(70, 700), (14, 14, 16), anchor='mm')
    text(d, (1240, 44), TAG1, font(31, 600), (255, 255, 255), 2, 'ra')
    text(d, (1240, 82), TAG2, font(39, 700), YELLOW, 2, 'ra')
    top = title_block(d, 44, 610, (76, 102, 28, 18), (12, 18, 14), 6)
    print('social title top', top)
    im.save(ART + '/GitHub-Social-1280x640.png')

if __name__ == '__main__':
    import sys
    if 'wide' not in sys.argv[1:] and 'header' not in sys.argv[1:] and 'social' not in sys.argv[1:]: square()
    if 'square' not in sys.argv[1:] and 'header' not in sys.argv[1:] and 'social' not in sys.argv[1:]: wide()
    if 'social' in sys.argv[1:]: social()
    if 'header' in sys.argv[1:]: header()
    print('done')

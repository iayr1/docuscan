"""Generates the DocuScan logo and all launcher icons.

Usage (from the project root):  python tool/make_icons.py
"""
import json
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SS = 4  # supersampling factor for smooth edges

TOP = (46, 150, 112)      # gradient start (top-left)
BOTTOM = (16, 78, 56)     # gradient end (bottom-right)
MINT = (124, 232, 184)
WHITE = (255, 255, 255)


def gradient(size):
    """Diagonal two-colour gradient."""
    g = Image.new('RGB', (size, size))
    px = g.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM))
    return g


def gradient_fast(size):
    small = gradient(64)
    return small.resize((size, size), Image.BICUBIC)


def draw_mark(size, scale=1.0):
    """Transparent layer with the document + scanner brackets, centred.

    `scale` shrinks the artwork (used for adaptive-icon safe zones).
    """
    S = size * SS
    layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    c = S / 2
    u = S * scale / 100.0  # 1 unit = 1% of the (scaled) artwork

    # --- document page with folded corner -------------------------------
    w, h = 40 * u, 52 * u
    left, top = c - w / 2, c - h / 2
    right, bottom = left + w, top + h
    fold = 13 * u
    r = 4 * u

    # soft shadow
    shadow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([left, top + 2.5 * u, right, bottom + 2.5 * u], radius=r, fill=(0, 0, 0, 70))
    shadow = shadow.filter(ImageFilter.GaussianBlur(3 * u))
    layer.alpha_composite(shadow)

    page = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    pd = ImageDraw.Draw(page)
    pd.rounded_rectangle([left, top, right, bottom], radius=r, fill=WHITE)
    # cut the folded corner
    pd.polygon([(right - fold, top - 1), (right + 1, top - 1), (right + 1, top + fold)], fill=(0, 0, 0, 0))
    layer.alpha_composite(page)
    # fold flap
    d.polygon([(right - fold, top), (right - fold, top + fold), (right, top + fold)], fill=(190, 230, 212))

    # text lines
    lx = left + 7 * u
    line_h = 3.2 * u
    for i, frac in enumerate([0.52, 0.78, 0.66, 0.78, 0.45]):
        y = top + 17 * u + i * 7 * u
        d.rounded_rectangle([lx, y, lx + (w - 14 * u) * frac / 0.78, y + line_h], radius=line_h / 2, fill=(28, 112, 84, 255 if i else 255))
    # title line slightly bolder & mint accent dot
    d.ellipse([lx, top + 8 * u, lx + 5 * u, top + 13 * u], fill=(46, 150, 112))

    # --- scanner corner brackets ----------------------------------------
    pad = 9 * u
    bl, bt, br, bb = left - pad, top - pad, right + pad, bottom + pad
    arm = 11 * u
    th = 4.2 * u
    for (x, y, dx, dy) in [(bl, bt, 1, 1), (br, bt, -1, 1), (bl, bb, 1, -1), (br, bb, -1, -1)]:
        d.rounded_rectangle(sorted_box(x, y, x + dx * arm, y + dy * th), radius=th / 2, fill=WHITE)
        d.rounded_rectangle(sorted_box(x, y, x + dx * th, y + dy * arm), radius=th / 2, fill=WHITE)

    # --- scan beam with glow --------------------------------------------
    by = c + 6 * u
    glow = Image.new('RGBA', (S, S), MINT + (0,))
    gd = ImageDraw.Draw(glow)
    gd.rounded_rectangle([bl + 3 * u, by - 3 * u, br - 3 * u, by + 3 * u], radius=3 * u, fill=MINT + (110,))
    glow = glow.filter(ImageFilter.GaussianBlur(2.5 * u))
    layer.alpha_composite(glow)
    d.rounded_rectangle([bl + 2 * u, by - 1.3 * u, br - 2 * u, by + 1.3 * u], radius=1.3 * u, fill=MINT + (255,))

    return layer.resize((size, size), Image.LANCZOS)


def sorted_box(x0, y0, x1, y1):
    return [min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)]


def full_icon(size, rounded=True, radius_frac=0.225):
    """Gradient tile + mark. Rounded corners are transparent."""
    S = size * SS
    bg = gradient_fast(S).convert('RGBA')
    bg = bg.resize((size, size), Image.LANCZOS)
    bg.alpha_composite(draw_mark(size))
    if rounded:
        mask = Image.new('L', (S, S), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=S * radius_frac, fill=255)
        mask = mask.resize((size, size), Image.LANCZOS)
        bg.putalpha(mask)
    return bg


def save(img, *parts):
    path = os.path.join(ROOT, *parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=True)
    return path


def main():
    # Master artwork used inside the app and for stores.
    save(full_icon(1024), 'assets', 'branding', 'logo.png')
    save(full_icon(1024, rounded=False).convert('RGB'), 'assets', 'branding', 'logo_square.png')
    save(full_icon(512, rounded=False).convert('RGB'), 'assets', 'branding', 'play_store_512.png')

    # Android legacy icons (pre-Android 8).
    res = os.path.join('android', 'app', 'src', 'main', 'res')
    for folder, px in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
        save(full_icon(px), res, f'mipmap-{folder}', 'ic_launcher.png')
        # Round variant
        r = full_icon(px, radius_frac=0.5)
        save(r, res, f'mipmap-{folder}', 'ic_launcher_round.png')

    # Android adaptive icon foreground (108dp canvas, art inside the 66dp safe zone).
    for folder, px in {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}.items():
        save(draw_mark(px, scale=0.8), res, f'mipmap-{folder}', 'ic_launcher_foreground.png')
        save(gradient_fast(px).convert('RGB'), res, f'mipmap-{folder}', 'ic_launcher_background.png')
        # Monochrome layer for Android 13+ themed icons.
        mono = draw_mark(px, scale=0.8)
        alpha = mono.split()[3]
        white = Image.new('RGBA', mono.size, (255, 255, 255, 0))
        white.putalpha(alpha)
        save(white, res, f'mipmap-{folder}', 'ic_launcher_monochrome.png')

    adaptive = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
'''
    d = os.path.join(ROOT, res, 'mipmap-anydpi-v26')
    os.makedirs(d, exist_ok=True)
    for name in ('ic_launcher.xml', 'ic_launcher_round.xml'):
        with open(os.path.join(d, name), 'w', encoding='utf-8') as f:
            f.write(adaptive)

    # iOS: overwrite every image referenced by the AppIcon set (opaque, square).
    icon_set = os.path.join(ROOT, 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
    contents = os.path.join(icon_set, 'Contents.json')
    if os.path.exists(contents):
        master = full_icon(1024, rounded=False).convert('RGB')
        for img in json.load(open(contents, encoding='utf-8'))['images']:
            fn = img.get('filename')
            if not fn:
                continue
            pts = float(img['size'].split('x')[0])
            scale = int(img.get('scale', '1x').rstrip('x'))
            px = round(pts * scale)
            master.resize((px, px), Image.LANCZOS).save(os.path.join(icon_set, fn), optimize=True)

    print('icons generated')


if __name__ == '__main__':
    main()

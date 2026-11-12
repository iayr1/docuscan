"""Builds Google Play listing graphics from raw device screenshots.

Usage:  python tool/make_store_assets.py <raw-screenshot-dir>
Writes to store_assets/ (phone screenshots, feature graphic, 512px icon).
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'store_assets')
FONTS = 'C:/Windows/Fonts/'
BOLD = FONTS + 'segoeuib.ttf'
SEMI = FONTS + 'seguisb.ttf'
REG = FONTS + 'segoeui.ttf'

G1 = (42, 140, 105)
G2 = (14, 70, 50)
MINT = (124, 232, 184)


def font(path, size):
    return ImageFont.truetype(path, size)


def gradient(w, h, c1=G1, c2=G2):
    small = Image.new('RGB', (64, 64))
    px = small.load()
    for y in range(64):
        for x in range(64):
            t = (x * 0.35 + y) / (63 * 1.35)
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(c1, c2))
    return small.resize((w, h), Image.BICUBIC)


def decorate(bg):
    """Soft circles for depth."""
    w, h = bg.size
    layer = Image.new('RGBA', (w, h), (255, 255, 255, 0))
    d = ImageDraw.Draw(layer)
    d.ellipse([w * 0.55, -h * 0.12, w * 1.35, h * 0.33], fill=(255, 255, 255, 18))
    d.ellipse([-w * 0.45, h * 0.62, w * 0.45, h * 1.2], fill=(255, 255, 255, 12))
    out = bg.convert('RGBA')
    out.alpha_composite(layer.filter(ImageFilter.GaussianBlur(2)))
    return out


def clean_status_bar(shot, dark=False):
    """Replaces the real status bar with a neutral one (9:41, full battery)."""
    shot = shot.convert('RGB')
    w = shot.width
    bar_h = round(w * 0.112)
    bg = shot.getpixel((w // 2, bar_h - 4))
    d = ImageDraw.Draw(shot)
    d.rectangle([0, 0, w, bar_h], fill=bg)
    fg = (255, 255, 255) if sum(bg) < 300 else (25, 30, 28)
    s = w / 720
    d.text((44 * s, 22 * s), '9:41', font=font(SEMI, round(27 * s)), fill=fg)
    # signal bars
    x0 = w - 150 * s
    for i in range(4):
        hgt = (8 + i * 5) * s
        d.rounded_rectangle([x0 + i * 9 * s, 50 * s - hgt, x0 + i * 9 * s + 6 * s, 50 * s], radius=1.5 * s, fill=fg)
    # battery
    bx = w - 90 * s
    d.rounded_rectangle([bx, 28 * s, bx + 44 * s, 52 * s], radius=6 * s, outline=fg, width=round(2.5 * s))
    d.rounded_rectangle([bx + 5 * s, 33 * s, bx + 39 * s, 47 * s], radius=3 * s, fill=fg)
    d.rounded_rectangle([bx + 46 * s, 35 * s, bx + 50 * s, 45 * s], radius=1.5 * s, fill=fg)
    return shot


def phone(shot, width):
    """Screenshot inside a slim dark device frame with rounded corners."""
    ratio = shot.height / shot.width
    screen_w = width - 2 * round(width * 0.035)
    screen_h = round(screen_w * ratio)
    bezel = round(width * 0.035)
    fw, fh = screen_w + 2 * bezel, screen_h + 2 * bezel
    r_out, r_in = round(fw * 0.13), round(fw * 0.105)

    frame = Image.new('RGBA', (fw, fh), (0, 0, 0, 0))
    fd = ImageDraw.Draw(frame)
    fd.rounded_rectangle([0, 0, fw - 1, fh - 1], radius=r_out, fill=(18, 22, 20, 255))
    fd.rounded_rectangle([2, 2, fw - 3, fh - 3], radius=r_out - 2, outline=(70, 78, 74, 255), width=2)

    scr = shot.resize((screen_w, screen_h), Image.LANCZOS).convert('RGBA')
    mask = Image.new('L', (screen_w, screen_h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, screen_w - 1, screen_h - 1], radius=r_in, fill=255)
    frame.paste(scr, (bezel, bezel), mask)
    # camera punch-hole
    cx, cy, cr = fw // 2, bezel + round(screen_w * 0.045), round(screen_w * 0.016)
    fd.ellipse([cx - cr, cy - cr, cx + cr, cy + cr], fill=(10, 12, 11, 255))
    return frame


def shadow_for(img, blur=40, offset=(0, 30), alpha=110):
    sh = Image.new('RGBA', (img.width + blur * 4, img.height + blur * 4), (0, 0, 0, 0))
    a = img.split()[3].point(lambda v: alpha if v > 0 else 0)
    sh.paste((0, 0, 0, 255), (blur * 2 + offset[0], blur * 2 + offset[1]), a)
    return sh.filter(ImageFilter.GaussianBlur(blur))


def wrap_center(draw, text, fnt, y, width, fill, line_gap=1.12):
    for line in text.split('\n'):
        tw = draw.textlength(line, font=fnt)
        draw.text(((width - tw) / 2, y), line, font=fnt, fill=fill)
        y += fnt.size * line_gap
    return y


def screenshot_card(shot_path, headline, sub, dark_shot=False, size=(1080, 1920)):
    W, H = size
    canvas = decorate(gradient(W, H))
    d = ImageDraw.Draw(canvas)

    # pill
    pill_f = font(BOLD, 28)
    label = '100% OFFLINE  ·  PRIVATE'
    tw = d.textlength(label, font=pill_f)
    px, py = (W - tw) / 2 - 26, 110
    overlay = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(overlay).rounded_rectangle([px, py, px + tw + 52, py + 54], radius=27, fill=(255, 255, 255, 46))
    canvas.alpha_composite(overlay)
    d = ImageDraw.Draw(canvas)
    d.text((px + 26, py + 7), label, font=pill_f, fill=(232, 252, 242))

    y = wrap_center(d, headline, font(BOLD, 84), 200, W, (255, 255, 255))
    wrap_center(d, sub, font(REG, 40), y + 34, W, (210, 238, 226), line_gap=1.3)

    shot = clean_status_bar(Image.open(shot_path), dark=dark_shot)
    dev = phone(shot, 760)
    top = 620
    sh = shadow_for(dev)
    canvas.alpha_composite(sh, ((W - sh.width) // 2, top - 80 + 30))
    canvas.alpha_composite(dev, ((W - dev.width) // 2, top))
    return canvas.convert('RGB')


def feature_graphic(home_shot, logo_path):
    W, H = 1024, 500
    canvas = decorate(gradient(W, H))
    d = ImageDraw.Draw(canvas)

    logo = Image.open(logo_path).convert('RGBA').resize((132, 132), Image.LANCZOS)
    canvas.alpha_composite(shadow_for(logo, blur=14, offset=(0, 8), alpha=90), (60 - 28, 92 - 28))
    canvas.alpha_composite(logo, (60, 92))

    d.text((60, 240), 'Docu', font=font(BOLD, 80), fill=(255, 255, 255))
    dw = d.textlength('Docu', font=font(BOLD, 80))
    d.text((60 + dw, 240), 'Scan', font=font(BOLD, 80), fill=MINT)
    d.text((62, 345), 'Scan  ·  Organise  ·  Sign', font=font(SEMI, 32), fill=(225, 248, 236))
    d.text((62, 392), 'PDF tools & OCR — 100% offline', font=font(REG, 26), fill=(190, 228, 212))

    shot = clean_status_bar(Image.open(home_shot))
    dev = phone(shot, 300)
    # tilt slightly and let it bleed off the bottom edge
    dev = dev.rotate(-8, resample=Image.BICUBIC, expand=True)
    sh = shadow_for(dev, blur=24, offset=(10, 20), alpha=120)
    x, y = 640, 46
    canvas.alpha_composite(sh, (x - 96 + 10, y - 96 + 20))
    canvas.alpha_composite(dev, (x, y))
    return canvas.convert('RGB')


def main():
    raw = sys.argv[1]
    os.makedirs(os.path.join(OUT, 'phone_screenshots'), exist_ok=True)
    shots = [
        ('home.png', 'Scan, organise\nand sign', 'Your documents, beautifully\norganised on your phone', False),
        ('search.png', 'Find anything\ninstantly', 'Search the words inside\nevery scan and receipt', False),
        ('viewer.png', 'Crisp, clear\nscans', 'Auto crop, enhance and\nzoom into every page', True),
        ('ocr.png', 'Extract text\nin seconds', 'On-device OCR in English, Hindi\nand more — no internet', False),
        ('tools.png', 'A complete\nPDF toolkit', 'Merge, split, compress, protect\nand convert Word & Excel', False),
        ('invoice_detail.png', 'Edit every\npage', 'Rotate, crop, sign, annotate\nand share as PDF', False),
        ('vault.png', 'Private by\ndesign', 'Lock documents in an\nAES-256 encrypted vault', False),
        ('home_dark.png', 'Gorgeous in\nthe dark', 'A polished dark theme\nthat is easy on the eyes', True),
    ]
    for i, (fn, head, sub, dark) in enumerate(shots, 1):
        img = screenshot_card(os.path.join(raw, fn), head, sub, dark)
        img.save(os.path.join(OUT, 'phone_screenshots', f'{i:02d}_{os.path.splitext(fn)[0]}.png'), optimize=True)

    feature_graphic(os.path.join(raw, 'home.png'), os.path.join(ROOT, 'assets', 'branding', 'logo.png')) \
        .save(os.path.join(OUT, 'feature_graphic_1024x500.png'), optimize=True)

    Image.open(os.path.join(ROOT, 'assets', 'branding', 'play_store_512.png')).convert('RGB') \
        .resize((512, 512)).save(os.path.join(OUT, 'app_icon_512.png'), optimize=True)
    print('store assets written to', OUT)


if __name__ == '__main__':
    main()

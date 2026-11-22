"""Composite real app screens into the generated scenes' green areas.

Usage: python -E -P compose.py <lp_dir> <out_dir>
Writes webp figures into <out_dir> (to be copied into lp/images/figs/).
"""
import sys, os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

LP, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)
IMG = os.path.join(LP, "images")


def load(rel):
    return Image.open(os.path.join(IMG, rel)).convert("RGBA")


# ---------- large widgets, made in the real widget's style ----------
def large_widget(photo_rel, mode, label=None, pos=(0.5, 0.4), zoom=1.0):
    W, H = 1092, 1146
    ph = load(photo_rel)
    sc = max(W / ph.width, H / ph.height) * zoom
    pr = ph.resize((int(ph.width * sc), int(ph.height * sc)), Image.LANCZOS)
    ox = int((pr.width - W) * pos[0]); oy = int((pr.height - H) * pos[1])
    img = pr.crop((ox, oy, ox + W, oy + H)).convert("RGBA")
    real = {"cloudy": "screens/widget-cloudy.webp", "year": "screens/widget-year-ago.webp", "family": "screens/widget-family.webp"}
    if mode == "cloudy":
        img = img.filter(ImageFilter.GaussianBlur(60)).convert("RGBA")
        fog = Image.new("RGBA", (W, H), (235, 235, 238, 150)); img = Image.alpha_composite(img, fog)
        pill = load(real["cloudy"]).crop((293, 360, 800, 456))
        img.alpha_composite(pill, ((W - pill.width) // 2, H - 150))
    else:
        g = np.zeros((H, W, 4), np.uint8); t = np.clip((np.arange(H) - H * 0.62) / (H * 0.38), 0, 1)[:, None]
        g[..., 3] = (t * 120).astype(np.uint8)
        img = Image.alpha_composite(img, Image.fromarray(g))
        d = ImageDraw.Draw(img)
        f = ImageFont.truetype(r"C:\Windows\Fonts\YuGothM.ttc", 40)
        if label:
            tw = d.textlength(label, font=f)
            d.text(((W - tw) / 2, H - 112), label, fill=(255, 255, 255), font=f)
        if mode == "family":
            heart = load(real["family"]).crop((52, 358, 152, 458))
            img.alpha_composite(heart, (52, H - 152))
    m = Image.new("L", (W, H), 0); ImageDraw.Draw(m).rounded_rectangle([0, 0, W - 1, H - 1], radius=66, fill=255)
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0)); out.paste(img, (0, 0), m)
    return out


# ---------- home screens built from the real widgets ----------
def home_screen(widget, w=1179, h=2556):
    s = 3.0
    base = Image.new("RGBA", (w, h))
    # soft warm wallpaper
    grad = np.zeros((h, w, 3), np.float32)
    top = np.array([253, 240, 224], np.float32); bot = np.array([238, 226, 240], np.float32)
    t = np.linspace(0, 1, h)[:, None]
    grad[:] = (top * (1 - t) + bot * t)[:, None, :][:, 0, :][:, None, :]
    base = Image.fromarray(grad.astype(np.uint8)).convert("RGBA")
    d = ImageDraw.Draw(base)
    try:
        f = ImageFont.truetype(r"C:\Windows\Fonts\segoeuib.ttf", int(17 * s))
    except OSError:
        f = ImageFont.load_default()
    d.text((int(44 * s), int(17 * s)), "9:41", fill=(20, 20, 20), font=f)
    # signal / wifi / battery, simple
    bx = w - int(36 * s) - int(27 * s)
    d.rounded_rectangle([bx, int(20 * s), bx + int(25 * s), int(32 * s)], radius=int(3.5 * s), outline=(60, 60, 60), width=int(1.2 * s))
    d.rounded_rectangle([bx + int(2 * s), int(22 * s), bx + int(19 * s), int(30 * s)], radius=int(2 * s), fill=(20, 20, 20))
    for i, hh in enumerate([4, 6.5, 9, 11.5]):
        x = bx - int(48 * s) + int(i * 4.6 * s)
        d.rounded_rectangle([x, int(32 * s - hh * s), x + int(3 * s), int(32 * s)], radius=int(0.8 * s), fill=(20, 20, 20))
    # the widget (medium, 364x170pt drawn at 3x)
    wid = widget if isinstance(widget, Image.Image) else load(widget)
    ww = int(361 * s); wh = int(wid.height * ww / wid.width)
    wid = wid.resize((ww, wh), Image.LANCZOS)
    wx = (w - ww) // 2; wy = int(70 * s)
    shadow = Image.new("RGBA", base.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([wx, wy + int(8 * s), wx + ww, wy + wh + int(8 * s)], radius=int(22 * s), fill=(60, 40, 20, 70))
    base = Image.alpha_composite(base, shadow.filter(ImageFilter.GaussianBlur(int(10 * s))))
    base.alpha_composite(wid, (wx, wy))
    d = ImageDraw.Draw(base)
    try:
        f2 = ImageFont.truetype(r"C:\Windows\Fonts\YuGothM.ttc", int(11 * s))
    except OSError:
        f2 = ImageFont.load_default()
    label = "ねこのまど"
    tw = d.textlength(label, font=f2)
    d.text(((w - tw) / 2, wy + wh + int(6 * s)), label, fill=(120, 105, 92), font=f2)
    # app icons: 4 columns x 4 rows, plus a dock
    cols = [((255, 255, 255), (238, 238, 238)), ((246, 180, 76), (167, 122, 226)), ((207, 211, 217), (154, 161, 171)), ((92, 179, 246), (47, 116, 216)),
            ((30, 30, 32), (30, 30, 32)), ((159, 220, 143), (127, 192, 239)), ((255, 255, 255), (247, 215, 91)), ((182, 188, 198), (124, 131, 142))]
    size = int(62 * s); gap = (w - 4 * size) // 5
    y0 = wy + wh + int(40 * s)
    k = 0
    for row in range(2):
        for col in range(4):
            a, b = cols[k % len(cols)]; k += 1
            x = gap + col * (size + gap); y = y0 + row * (size + int(34 * s))
            ic = Image.new("RGBA", (size, size))
            arr = np.zeros((size, size, 4), np.uint8)
            tt = np.linspace(0, 1, size)[:, None]
            arr[..., :3] = (np.array(a) * (1 - tt) + np.array(b) * tt)[:, None, :][:, 0, :][:, None, :].astype(np.uint8)
            arr[..., 3] = 255
            ic = Image.fromarray(arr)
            m = Image.new("L", (size, size), 0); ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=int(14 * s), fill=255)
            base.paste(ic, (x, y), m)
    # dock
    dy = h - int(110 * s)
    dock = Image.new("RGBA", base.size, (0, 0, 0, 0))
    ImageDraw.Draw(dock).rounded_rectangle([int(12 * s), dy, w - int(12 * s), dy + int(88 * s)], radius=int(32 * s), fill=(255, 255, 255, 110))
    base = Image.alpha_composite(base, dock)
    dcols = [((111, 224, 122), (51, 196, 74)), ((111, 182, 255), (47, 124, 246)), ((255, 255, 255), (233, 233, 238)), ((255, 138, 122), (242, 85, 74))]
    for col in range(4):
        a, b = dcols[col]
        x = gap + col * (size + gap); y = dy + int(13 * s)
        arr = np.zeros((size, size, 4), np.uint8)
        tt = np.linspace(0, 1, size)[:, None]
        arr[..., :3] = (np.array(a) * (1 - tt) + np.array(b) * tt)[:, None, :][:, 0, :][:, None, :].astype(np.uint8)
        arr[..., 3] = 255
        m = Image.new("L", (size, size), 0); ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=int(14 * s), fill=255)
        base.paste(Image.fromarray(arr), (x, y), m)
    return base


# ---------- green screen detection and perspective fit ----------
def green_mask(img):
    a = np.asarray(img.convert("RGB")).astype(np.int16)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    # soft key: how green a pixel is
    k = np.clip((g - np.maximum(r, b) - 40) / 120.0, 0, 1)
    return k


def quads(mask, n):
    """Corners of the n largest green regions (left to right)."""
    from collections import deque
    hard = mask > 0.5
    h, w = hard.shape
    seen = np.zeros_like(hard)
    regions = []
    step = 4
    for y in range(0, h, step):
        for x in range(0, w, step):
            if hard[y, x] and not seen[y, x]:
                # flood fill on a coarse grid
                q = deque([(y, x)]); seen[y, x] = True; pts = []
                while q:
                    cy, cx = q.popleft(); pts.append((cy, cx))
                    for dy, dx in ((step, 0), (-step, 0), (0, step), (0, -step)):
                        ny, nx = cy + dy, cx + dx
                        if 0 <= ny < h and 0 <= nx < w and hard[ny, nx] and not seen[ny, nx]:
                            seen[ny, nx] = True; q.append((ny, nx))
                regions.append(np.array(pts))
    regions.sort(key=len, reverse=True)
    out = []
    for pts in regions[:n]:
        ys, xs = pts[:, 0].astype(float), pts[:, 1].astype(float)
        tl = pts[np.argmin(xs + ys)]; br = pts[np.argmax(xs + ys)]
        tr = pts[np.argmax(xs - ys)]; bl = pts[np.argmax(ys - xs)]
        out.append([(tl[1], tl[0]), (tr[1], tr[0]), (br[1], br[0]), (bl[1], bl[0])])
    out.sort(key=lambda q: q[0][0])
    return out


def coeffs(dst, src):
    """PIL perspective coefficients mapping output (dst quad) -> input (src quad)."""
    A = []; B = []
    for (x, y), (u, v) in zip(dst, src):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); B.append(u)
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y]); B.append(v)
    return np.linalg.solve(np.array(A, float), np.array(B, float)).tolist()


def expand(quad, px):
    cx = sum(p[0] for p in quad) / 4; cy = sum(p[1] for p in quad) / 4
    res = []
    for x, y in quad:
        dx, dy = x - cx, y - cy; L = (dx * dx + dy * dy) ** .5
        res.append((x + dx / L * px, y + dy / L * px))
    return res


def place(scene, screens, inset_corners=True):
    sc = scene.convert("RGBA")
    mask = green_mask(sc)
    qs = quads(mask, len(screens))
    out = sc.copy()
    for quad, scr in zip(qs, screens):
        quad = expand(quad, 6)  # the corners are rounded: push out so the screen fills them
        w, h = scr.size
        src = [(0, 0), (w, 0), (w, h), (0, h)]
        warped = scr.transform(sc.size, Image.PERSPECTIVE, coeffs(quad, src), Image.BICUBIC)
        out = Image.alpha_composite(out, warped.copy().__class__.new("RGBA", sc.size, (0, 0, 0, 0))) if False else out
        alpha = Image.fromarray((np.clip(mask * 1.15, 0, 1) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.2))
        wa = np.asarray(warped).copy()
        wa[..., 3] = np.minimum(wa[..., 3], np.asarray(alpha))
        out = Image.alpha_composite(out, Image.fromarray(wa))
    # despill: any remaining green fringe
    a = np.asarray(out).astype(np.int16)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    spill = g > np.maximum(r, b) + 30
    a[..., 1] = np.where(spill, np.maximum(r, b) + 10, g)
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))


def save(img, name, width):
    h = int(img.height * width / img.width)
    img.convert("RGB").resize((width, h), Image.LANCZOS).save(os.path.join(OUT, name), "WEBP", quality=82, method=6)
    print(name, os.path.getsize(os.path.join(OUT, name)))


# hero: the cat through the arched window
win = load("scenes/scene-window.webp")
cat = load("photo-grey-yawn.webp")
m = green_mask(win)
ys, xs = np.nonzero(m > .5)
x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
bw, bh = x1 - x0 + 12, y1 - y0 + 12
cw, ch = cat.size; scale = max(bw / cw, bh / ch)
catr = cat.resize((int(cw * scale), int(ch * scale)), Image.LANCZOS)
ox = int((catr.width - bw) * .5); oy = int((catr.height - bh) * .32)
catc = catr.crop((ox, oy, ox + bw, oy + bh))
layer = Image.new("RGBA", win.size, (0, 0, 0, 0)); layer.paste(catc, (x0 - 6, y0 - 6))
alpha = Image.fromarray((np.clip(m * 1.15, 0, 1) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.2))
la = np.asarray(layer).copy(); la[..., 3] = np.minimum(la[..., 3], np.asarray(alpha))
hero = Image.alpha_composite(win.convert("RGBA"), Image.fromarray(la))
a = np.asarray(hero).astype(np.int16); r, g, b = a[..., 0], a[..., 1], a[..., 2]
a[..., 1] = np.where(g > np.maximum(r, b) + 30, np.maximum(r, b) + 10, g)
save(Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)), "fig-hero.webp", 1100)

# きょうは、どの子だろう：two phones on the desk, cloudy and clear
save(place(load("scenes/scene-two-phones.webp"), [home_screen(large_widget("photo-grey-ball.webp", "cloudy")), home_screen(large_widget("photo-grey-ball.webp", "clear", pos=(0.5, 0.45)))]), "fig-today.webp", 1400)
# 忘れていた1枚が、帰ってくる：a hand at home, 1年前のきょう
save(place(load("scenes/scene-hand-home.webp"), [home_screen(large_widget("photo-grey-chair.webp", "year", "1年前のきょう", pos=(0.42, 0.62), zoom=1.9))]), "fig-back.webp", 1000)
# 家族：the parent's hand, the photo that came
save(place(load("scenes/scene-hand-family.webp"), [home_screen(large_widget("photo-grey-bed.webp", "family", "ゆうから・いま届いた1枚", pos=(0.45, 0.35)))]), "fig-family.webp", 1000)
# 月の作品：the real monthly work on the desk
save(place(load("scenes/scene-desk-phone.webp"), [load("screens/screen-monthly.webp")]), "fig-monthly.webp", 1000)

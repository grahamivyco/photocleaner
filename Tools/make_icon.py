"""Draws the Shoebox app icon and writes every size the asset catalog needs.

Run from the repo root: python3 Tools/make_icon.py  (needs Pillow)
"""
import json
import os

from PIL import Image, ImageDraw, ImageFilter

S = 4096  # draw big, scale down for smooth edges
OUT = "Shoebox/Assets.xcassets/AppIcon.appiconset"


def sc(v):
    return int(v * S / 1024)


def rounded(draw, box, r, fill):
    draw.rounded_rectangle([sc(x) for x in box], radius=sc(r), fill=fill)


def card(angle, offset, photo_fill):
    """A white-bordered print, rotated, on its own layer."""
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    w, h = 300, 360
    x0, y0 = 512 - w / 2 + offset[0], 300 + offset[1]
    rounded(d, (x0, y0, x0 + w, y0 + h), 14, (246, 238, 222, 255))
    inner = (x0 + 22, y0 + 22, x0 + w - 22, y0 + h - 80)
    rounded(d, inner, 6, photo_fill)
    # simple landscape: sun + hill
    cx, cy = inner[0] + 70, inner[1] + 70
    d.ellipse([sc(cx - 28), sc(cy - 28), sc(cx + 28), sc(cy + 28)], fill=(248, 206, 120, 255))
    d.polygon([(sc(inner[0]), sc(inner[3])), (sc(inner[0] + 110), sc(inner[1] + 150)),
               (sc(inner[0] + 180), sc(inner[1] + 200)), (sc(inner[2] - 60), sc(inner[1] + 120)),
               (sc(inner[2]), sc(inner[1] + 170)), (sc(inner[2]), sc(inner[3]))],
              fill=(70, 96, 78, 255))
    return layer.rotate(angle, resample=Image.BICUBIC, center=(sc(512), sc(760)))


def main():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # macOS icon body: 824pt square with ~185pt corners, centred on a 1024 canvas.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([sc(100), sc(116), sc(924), sc(940)], radius=sc(185), fill=(0, 0, 0, 120))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(sc(18))))

    body = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(body)
    # vertical warm gradient
    top, bottom = (58, 44, 32), (24, 19, 15)
    for y in range(sc(100), sc(924)):
        t = (y - sc(100)) / (sc(824))
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        bd.line([(sc(100), y), (sc(924), y)], fill=c)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([sc(100), sc(100), sc(924), sc(924)], radius=sc(185), fill=255)
    img.paste(body, (0, 0), mask)

    # prints fanning out of the box
    img.alpha_composite(card(14, (-40, 10), (120, 150, 170, 255)))
    img.alpha_composite(card(-9, (30, -20), (196, 120, 92, 255)))

    # the box itself
    d = ImageDraw.Draw(img)
    rounded(d, (232, 590, 792, 820), 26, (232, 163, 61, 255))      # front
    rounded(d, (232, 590, 792, 640), 14, (247, 190, 98, 255))      # rim highlight
    rounded(d, (440, 680, 584, 712), 10, (186, 120, 38, 255))      # label slot

    # keep everything inside the rounded body (plus its shadow)
    outside = Image.new("L", (S, S), 0)
    ImageDraw.Draw(outside).rounded_rectangle([sc(100), sc(100), sc(924), sc(924)], radius=sc(185), fill=255)
    clipped = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    clipped.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(sc(18))))
    clipped.paste(img, (0, 0), outside)

    master = clipped.resize((1024, 1024), Image.LANCZOS)
    os.makedirs(OUT, exist_ok=True)

    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            master.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name))
            images.append({"idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}", "filename": name})

    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()

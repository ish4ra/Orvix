from pathlib import Path
from PIL import Image

SOURCE = Path("assets/branding/orvix_icon.png")


def make_mark(source: Path = SOURCE) -> Image.Image:
    image = Image.open(source).convert("RGBA")
    w, h = image.size

    # The historical Orvix app-icon artwork contains a dark square/rounded
    # plate around the actual lime P/play mark. UI chrome and OS launchers
    # already provide their own background/mask, so keep only the centre mark.
    left = int(w * 0.23)
    top = int(h * 0.18)
    right = int(w * 0.77)
    bottom = int(h * 0.82)
    mark = image.crop((left, top, right, bottom))

    pixels = mark.load()
    for y in range(mark.height):
        for x in range(mark.width):
            r, g, b, a = pixels[x, y]
            # Preserve lime/green artwork and its glow while removing the
            # black plate and neutral pixels.
            green_signal = g - max(r, b)
            brightness = max(r, g, b)
            if a == 0 or brightness < 28 or (green_signal < 8 and g < 105):
                pixels[x, y] = (r, g, b, 0)
            else:
                # Fade very dark edge glow rather than leaving a hard box.
                new_alpha = min(a, max(0, int((brightness - 20) * 2.2)))
                pixels[x, y] = (r, g, b, new_alpha)

    bbox = mark.getbbox()
    if bbox is None:
        raise SystemExit("Could not isolate the Orvix logo mark")
    mark = mark.crop(bbox)

    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    mark.thumbnail((820, 820), Image.Resampling.LANCZOS)
    canvas.alpha_composite(
        mark,
        ((canvas.width - mark.width) // 2, (canvas.height - mark.height) // 2),
    )
    return canvas


if __name__ == "__main__":
    output = make_mark()
    output.save(SOURCE, format="PNG", optimize=True)
    print(f"Generated transparent Orvix mark: {SOURCE} ({output.size})")

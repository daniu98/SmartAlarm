"""Renders the SmartAlarm app icon.

The mark is the app's idea in one shape: a clock dial carrying two markers — when you wake
and when you have to leave — with the get-ready window drawn as an arc between them. The dial
sits on a dawn gradient, because this is a thing you look at before sunrise.

Drawn at 4x and downsampled, because PIL's arc/ellipse strokes are aliased.
"""
from PIL import Image, ImageDraw
import math
import os

S = 1024          # final size
SS = 4            # supersample factor
W = S * SS

# Dial geometry, in final-size points.
RING_R = 300
RING_W = 62
ARC_W = 96
DOT_R = 46
CENTER = (S / 2, S / 2)

# The window runs clockwise from the wake marker to the leave marker.
# Angles are compass-style: 0 = 12 o'clock, growing clockwise.
WAKE_ANGLE = -118
LEAVE_ANGLE = -34

AMBER = (255, 176, 74)
AMBER_DIM = (214, 142, 58)


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(stops):
    """Vertical gradient from a list of (position, rgb) stops."""
    img = Image.new("RGB", (1, W))
    px = img.load()
    for y in range(W):
        t = y / (W - 1)
        lo = stops[0]
        hi = stops[-1]
        for i in range(len(stops) - 1):
            if stops[i][0] <= t <= stops[i + 1][0]:
                lo, hi = stops[i], stops[i + 1]
                break
        span = hi[0] - lo[0]
        local = 0 if span == 0 else (t - lo[0]) / span
        px[0, y] = lerp(lo[1], hi[1], local)
    return img.resize((W, W))


def compass_to_pil(angle):
    """Compass degrees (0 = up, clockwise) to PIL degrees (0 = right, clockwise)."""
    return angle - 90


def draw_mark(img, ring_color, arc_color, dot_color, hand_color):
    d = ImageDraw.Draw(img)
    cx, cy = CENTER[0] * SS, CENTER[1] * SS
    r = RING_R * SS

    box = [cx - r, cy - r, cx + r, cy + r]

    # Full dial.
    d.ellipse(box, outline=ring_color, width=RING_W * SS)

    # The get-ready window, sitting proud of the dial.
    d.arc(
        box,
        start=compass_to_pil(WAKE_ANGLE),
        end=compass_to_pil(LEAVE_ANGLE),
        fill=arc_color,
        width=ARC_W * SS,
    )

    # Markers at each end of the window.
    for angle in (WAKE_ANGLE, LEAVE_ANGLE):
        rad = math.radians(angle - 90)
        mx = cx + r * math.cos(rad)
        my = cy + r * math.sin(rad)
        rr = DOT_R * SS
        d.ellipse([mx - rr, my - rr, mx + rr, my + rr], fill=dot_color)

    # A hand pointing at the wake marker — the moment the app actually decides.
    rad = math.radians(WAKE_ANGLE - 90)
    hx = cx + (r - RING_W * SS * 1.15) * math.cos(rad)
    hy = cy + (r - RING_W * SS * 1.15) * math.sin(rad)
    d.line([cx, cy, hx, hy], fill=hand_color, width=int(38 * SS))

    hub = 52 * SS
    d.ellipse([cx - hub, cy - hub, cx + hub, cy + hub], fill=hand_color)


def render_light():
    img = gradient([
        (0.00, (26, 30, 74)),     # night still holding at the top
        (0.45, (86, 58, 122)),
        (0.78, (214, 106, 92)),
        (1.00, (255, 168, 92)),   # sunrise
    ])
    draw_mark(img, (255, 255, 255), AMBER, (255, 255, 255), (255, 255, 255))
    return img.resize((S, S), Image.LANCZOS)


def render_dark():
    img = gradient([
        (0.00, (10, 12, 32)),
        (0.50, (34, 24, 58)),
        (1.00, (96, 46, 40)),
    ])
    draw_mark(img, (236, 238, 245), AMBER_DIM, (236, 238, 245), (236, 238, 245))
    return img.resize((S, S), Image.LANCZOS)


def render_tinted():
    """Grayscale on transparency — iOS supplies the tint and the backdrop."""
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    draw_mark(
        img,
        (255, 255, 255, 255),
        (255, 255, 255, 140),
        (255, 255, 255, 255),
        (255, 255, 255, 255),
    )
    return img.resize((S, S), Image.LANCZOS)


out = os.path.join(os.path.dirname(__file__), "..", "SmartAlarm", "Assets.xcassets", "AppIcon.appiconset")
os.makedirs(out, exist_ok=True)
render_light().save(os.path.join(out, "icon-light.png"))
render_dark().save(os.path.join(out, "icon-dark.png"))
render_tinted().save(os.path.join(out, "icon-tinted.png"))
print("rendered", os.listdir(out))

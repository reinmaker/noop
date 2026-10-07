"""Writes yoop.svg (the app icon) and yoop-glyph.svg (the mark alone, for the Coach button).

The Ultraviolet mark: a full ring sweeping from deep indigo to electric purple and back, with a soft
glow, around a white Y, on a near-black violet ground. The ring is drawn as short arc segments so the
colour sweeps around it (SVG has no conic gradient).
"""
import math

RING = [(0.0, "#3A1A8F"), (0.5, "#8A4DFF"), (1.0, "#3A1A8F")]
Y_STOPS = [(0, "#FFFFFF"), (1, "#CFC4F2")]
BG = ("#0D0818", "#020104")
GLOW = "#4B1FA8"
Y_PATH = "M 418 382 L 512 500 L 606 382 M 512 500 L 512 648"


def lerp(c1, c2, t):
    a = [int(c1[i:i + 2], 16) for i in (1, 3, 5)]
    b = [int(c2[i:i + 2], 16) for i in (1, 3, 5)]
    return "#%02X%02X%02X" % tuple(round(a[k] + (b[k] - a[k]) * t) for k in range(3))


def ramp(t):
    for (p0, c0), (p1, c1) in zip(RING, RING[1:]):
        if t <= p1:
            return lerp(c0, c1, (t - p0) / (p1 - p0))
    return RING[-1][1]


def ring(width=66, segments=180, radius=318):
    out = []
    for i in range(segments):
        a0 = math.radians(-90 + 360 * i / segments)
        a1 = math.radians(-90 + 360 * (i + 1) / segments + 0.6)
        x0, y0 = 512 + radius * math.cos(a0), 512 + radius * math.sin(a0)
        x1, y1 = 512 + radius * math.cos(a1), 512 + radius * math.sin(a1)
        out.append(f'<path d="M {x0:.2f} {y0:.2f} A {radius} {radius} 0 0 1 {x1:.2f} {y1:.2f}" '
                   f'fill="none" stroke="{ramp(i / segments)}" stroke-width="{width}"/>')
    return "\n".join(out)


def y_mark():
    return (f'<path d="{Y_PATH}" fill="none" stroke="url(#y)" stroke-width="74" '
            f'stroke-linecap="round" stroke-linejoin="round"/>')


def defs(with_bg):
    y = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in Y_STOPS)
    out = f'<linearGradient id="y" x1="0" y1="0" x2="1" y2="1">{y}</linearGradient>'
    if with_bg:
        out += (f'<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{BG[0]}"/>'
                f'<stop offset="1" stop-color="{BG[1]}"/></linearGradient>'
                f'<radialGradient id="glow" cx="0.5" cy="0.5" r="0.5"><stop offset="0.45" stop-color="{GLOW}" stop-opacity="0"/>'
                f'<stop offset="0.62" stop-color="{GLOW}" stop-opacity="0.45"/><stop offset="0.8" stop-color="{GLOW}" stop-opacity="0"/></radialGradient>'
                '<filter id="soft" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="18"/></filter>')
    return f"<defs>{out}</defs>"


icon = (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{defs(True)}'
        '<rect width="1024" height="1024" fill="url(#bg)"/><rect width="1024" height="1024" fill="url(#glow)"/>'
        f'<g filter="url(#soft)" opacity="0.55">{ring(70, 90)}</g>{ring()}{y_mark()}</svg>')
glyph = (f'<svg xmlns="http://www.w3.org/2000/svg" width="710" height="710" viewBox="157 157 710 710">{defs(False)}'
         f'{ring()}{y_mark()}</svg>')
open("yoop.svg", "w").write(icon)
open("yoop-glyph.svg", "w").write(glyph)

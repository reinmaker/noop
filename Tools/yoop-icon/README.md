# Yoop app icon

The Ultraviolet mark: a full ring sweeping from deep indigo to electric purple, with a soft glow, around a
white Y, on a near-black violet ground. `make_icon.py` writes the two sources:

- `yoop.svg`, the app icon (1024 x 1024)
- `yoop-glyph.svg`, the mark alone on a transparent ground, cropped to the ring

Rebuild the PNGs with:

```
python3 make_icon.py
rsvg-convert -w 1024 -h 1024 yoop.svg -o /tmp/rgba.png
magick /tmp/rgba.png -background '#020104' -alpha remove -alpha off icon_1024.png
for s in 1 2 3; do rsvg-convert -w $((28*s)) -h $((28*s)) yoop-glyph.svg -o yoop-coach@${s}x.png; done
```

- iOS: `StrandiOS/Resources/Assets.xcassets/YoopIconV2.appiconset/icon_1024.png` (iOS rounds the corners).
  The set name carries a version: iOS caches notification icons by name, so new artwork gets a new name
  (and `ASSETCATALOG_COMPILER_APPICON_NAME` in project.yml and the AltStore `iconURL` follow it).
- The alternate set `AppIcon-Navy` and `AltIcons/NavyTitanium@2x/@3x` carry the same artwork.
- Watch: `NOOPWatch/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png`, the same 1024 image.
- macOS: the 1024 image at 824 px inside a transparent 1024 canvas with a 185 px corner radius
  (an SVG `clipPath` rendered with rsvg-convert), at every size in `Strand/Resources/Assets.xcassets/AppIcon.appiconset`.
- Coach button: `yoop-coach@1x/2x/3x.png` in `StrandiOS/Resources/Assets.xcassets/YoopCoach.imageset` (28 pt).
- In-app logo: `BrandMark` in StrandDesign draws the same mark in SwiftUI.

# Yoop app icon

`yoop.svg` is the source. Rebuild the PNGs with:

```
rsvg-convert -w 1024 -h 1024 yoop.svg -o /tmp/rgba.png
magick /tmp/rgba.png -background '#0B0E11' -alpha remove -alpha off icon_1024.png
```

The iOS icon set is `YoopIcon.appiconset` (renamed from AppIcon so iOS drops its cached NOOP icon).
The iOS and watch icons use `icon_1024.png` as is (iOS rounds the corners). The macOS sizes are the same
image at 824 px inside a 1024 canvas with a 185 px corner radius, then resized.

`yoop-glyph.svg` is the same mark without the background, cropped to the ring. It is the Coach button in
the tab bar (`StrandiOS/Resources/Assets.xcassets/YoopCoach.imageset`, 28 pt):

```
for s in 1 2 3; do rsvg-convert -w $((28*s)) -h $((28*s)) yoop-glyph.svg -o yoop-coach@${s}x.png; done
```

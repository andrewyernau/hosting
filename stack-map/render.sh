#!/bin/sh
# Regenerate both HTML files and their PNGs (2x, trimmed to content).
set -eu
cd "$(dirname "$0")"
python3 gen.py
SHELL_BIN=$(find "$HOME/.cache/ms-playwright" -name chrome-headless-shell -type f | sort | tail -1)
for f in stack-map stack-map-public; do
  "$SHELL_BIN" --no-sandbox --hide-scrollbars --force-device-scale-factor=2 --window-size=776,1400 \
    --screenshot="/tmp/$f.full.png" "file://$PWD/$f.html" >/dev/null 2>&1
done
docker run --rm -e OWNER="$(id -u):$(id -g)" -v /tmp:/in -v "$PWD":/out python:3.12-alpine sh -c 'pip -q install pillow >/dev/null 2>&1; python -c "
from PIL import Image, ImageChops
for f in (\"stack-map\", \"stack-map-public\"):
    im = Image.open(f\"/in/{f}.full.png\").convert(\"RGB\")
    box = ImageChops.difference(im, Image.new(\"RGB\", im.size, im.getpixel((0, 0)))).getbbox()
    im.crop((0, 0, im.width, box[3] + 48)).save(f\"/out/{f}.png\")
"; chown $OWNER /out/*.png'

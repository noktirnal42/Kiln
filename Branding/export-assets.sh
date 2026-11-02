#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v rsvg-convert >/dev/null || { echo 'Install librsvg to export the branding assets.' >&2; exit 1; }
swift Branding/render-painted-icon.swift
for size in 16 32 64 128 256 512; do
  sips -z "$size" "$size" Branding/export/kiln-icon-1024.png --out "Branding/export/kiln-icon-$size.png" >/dev/null
done
rsvg-convert -w 1024 -h 1024 Branding/source/kiln-mark.svg -o Branding/export/kiln-mark-1024.png
rsvg-convert Branding/source/kiln-banner.svg -o Branding/export/kiln-banner-1600x640.png
for size in 16 32 128 256 512; do
  cp "Branding/export/kiln-icon-$size.png" "Resources/Assets.xcassets/AppIcon.appiconset/icon_${size}x${size}.png"
  double=$((size * 2))
  cp "Branding/export/kiln-icon-$double.png" "Resources/Assets.xcassets/AppIcon.appiconset/icon_${size}x${size}@2x.png"
done
for scale in 1 2 3; do
  size=$((128 * scale))
  rsvg-convert -w "$size" -h "$size" Branding/source/kiln-mark.svg -o "Resources/Assets.xcassets/KilnMark.imageset/kiln-mark@${scale}x.png"
done

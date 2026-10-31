# Kuk

<img src="Icon/AppIcon.png" width="128" align="right">

A fast fullscreen image viewer for macOS. Native Swift/AppKit, no dependencies.

Open an image from Finder and it fills the screen instantly; arrow keys walk the whole folder and wrap around at the ends. There is no open dialog — Kuk only shows what Finder hands it.

## Controls

Press **H** in the app to show this list.

| Key | Action |
|---|---|
| → ↓ / ← ↑, Space / ⇧Space | Next / previous image (wraps around) |
| Z | Toggle zoom mode ↔ 100 % |
| F | Cycle zoom modes |
| 1 | 100 % (actual size, 1 image pixel = 1 display pixel) |
| 2 | Fit all |
| 3 | Fit smaller only (enlarge small images, keep large ones at 100 %) |
| 4 | Fit larger only (shrink large images, keep small ones at 100 %) |
| + / − (also with ⌘) | Zoom |
| 0 (also with ⌘) | Reset zoom to the mode |
| Scroll wheel, ⌘+scroll, pinch | Zoom at cursor |
| Drag, two-finger scroll | Pan a zoomed image |
| Two-finger swipe sideways | Next / previous when there is nothing to pan |
| Double-click | Toggle zoom mode ↔ 100 % |
| Home / End | First / last image |
| Return | Close Kuk and select the file in Finder |
| ⇧Return | Open in Photoshop |
| ⌘Return | Annotate in CleanShot X exactly as on screen: the visible part at the current zoom (100 % = crop, 35 % = image at 35 %); saved as PNG in ~/Documents/Kuk |
| ⇧⌘Return | Annotate the original file in CleanShot X |
| ⌫ | Move the file to the Trash (asks first; Finder's Put Back works) |
| ⇧⌫ | Move the file to the Trash without asking |
| ⌘C | Copy the image (the file's own data; HEIC, RAW, PSD… also as TIFF) |
| ⇧⌘C | Copy the file's absolute path |
| I | Info bar (name, position, dimensions, color profile, file size, zoom, mode) |
| D | Move to the next display (main ↔ second), stays fullscreen |
| H | Help |
| Esc / Q / ⌘W | Close (Kuk stays resident for instant reopening) |
| ⌘Q | Quit |

The chosen zoom mode is remembered as the default.

## Why it's fast

- JPEGs are decoded by Core Animation with the hardware decoder when they first reach the screen, and the GPU scales them. EXIF rotation is a layer transform, so rotated photos take the same fast path.
- Images over the GPU texture limit (16384 px) are decoded at half size on a background thread — a gigapixel photo opens in ~0.7 s.
- Neighbours (+1, −1, +2) are prepared ahead in the background.
- After Esc the process stays alive with its caches released, so the next open from Finder skips app launch entirely.
- Embedded color profiles (sRGB, Display P3, Adobe RGB, ProPhoto…) are color-matched to the display by Core Animation.

## Build

```bash
./build.sh            # builds build/Kuk.app
./build.sh --install  # and installs it to ~/Applications
Icon/make_icon.sh     # regenerates Resources/AppIcon.icns
```

To make Kuk the default viewer: in Finder select an image, ⌘I → Open with → Kuk → Change All. Repeat for each file type (JPG, PNG, HEIC…).

## Testing hooks

`KUK_SNAPSHOT=/tmp/out.png` renders the window's layers to a PNG after the first image appears and logs launch timings to stderr; `KUK_KEYS="f,z,h,right,cmd+c"` presses keys before the snapshot. No screen-recording permission needed:

```bash
open -n --env KUK_SNAPSHOT=/tmp/kuk.png --env KUK_KEYS=h -a build/Kuk.app photo.jpg
```

## License

MIT, see [LICENSE](LICENSE). Provided as is, without warranty.

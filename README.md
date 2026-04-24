# HEIC HDR Converter

A local macOS tool for two-way conversion between standard images and HEIC with HDR gain map (Apple Adaptive HDR). Output HEIC files appear as HDR in Apple Photos and adapt brightness on XDR/HDR displays.

- **JPEG / PNG / TIFF → HEIC HDR** with embedded gain map (ISO 21496-1)
- **HEIC → JPEG** with wide-gamut Display P3 color preservation

Runs entirely on-device — no cloud, no API keys, no pip installs.

## Requirements

- macOS 14+ (Apple Silicon recommended)
- Xcode Command Line Tools (`xcode-select --install`)
- Python 3 (included with macOS)

## Quick start

```bash
git clone https://github.com/Jcali86/heic-hdr-converter.git
cd heic-hdr-converter
chmod +x build.sh
./build.sh
```

This compiles the Swift CLI, builds the `.app` bundle, and starts the web UI at **http://localhost:3939**.

After the first build, you can launch the app from the Dock or with:

```bash
open "HEIC HDR Converter.app"
```

## How to use

Drop one or more images into the window. Files are auto-detected:

| Drop in | Get out |
|---------|---------|
| JPEG, PNG, TIFF | HEIC with HDR gain map |
| HEIC, HEIF | JPEG (Display P3) |

The file row shows `→ HEIC` or `→ JPEG` so you know what's coming before you click Convert. Each result card shows conversion time, output size, and a Download button.

### Quality and Headroom

- **Quality** — output compression (0.5–1.0). Affects both HEIC and JPEG output.
- **Headroom** — maximum HDR brightness multiplier (1.0–8.0) for HEIC encoding. A value of 4.0 means highlights can appear up to 4× brighter than SDR on HDR/XDR displays. Has no effect on JPEG decoding.

## CLI usage

The Swift binary works standalone:

```bash
# Encode JPEG/PNG/TIFF → HEIC HDR
./heic-convert input.png output.heic --quality 0.85 --headroom 4.0

# Decode HEIC → JPEG
./heic-convert input.heic output.jpg --quality 0.9
```

The operation is auto-detected from the input extension. Outputs JSON to stdout:

```json
{"success":true,"output":"/path/to/output.heic","size_bytes":123456,"width":4000,"height":3000,"elapsed_ms":1423}
```

On failure, the JSON includes a `hint` field with actionable guidance.

## How it works

### Encode (anything → HEIC HDR)

1. Source image is rendered in extended linear Display P3 color space
2. An SDR base layer is created by clamping highlights to standard range
3. A gain map is computed from the HDR-to-SDR luminance ratio (or a synthetic boost for SDR inputs)
4. `CIContext.heifRepresentation` generates correctly-formatted gain map auxiliary data
5. The primary image is re-encoded with `CGImageDestination` for user-controlled quality, with the gain map attached

### Decode (HEIC → JPEG)

1. The HEIC's primary image is loaded (already the SDR base)
2. EXIF orientation is baked into pixels
3. `CIContext.writeJPEGRepresentation` writes a Display P3 JPEG with embedded ICC profile

## Project layout

```
heic-hdr-converter/
├── swift/
│   ├── heic-convert.swift   # CLI: encode + decode
│   └── launcher.swift       # Native Cocoa app with WKWebView
├── server/
│   ├── app.py               # Python stdlib HTTP server
│   └── public/index.html    # Web UI (glass theme)
├── build.sh                 # Compiles everything, builds .app, starts server
└── HEIC HDR Converter.app/  # Generated bundle (gitignored)
```

## License

MIT

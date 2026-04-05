# HEIC HDR Converter

Local tool for converting images to HEIC with HDR gain map (Apple Adaptive HDR). Output files show as HDR in Apple Photos and adapt brightness on XDR/HDR displays.

## Requirements

- macOS 14+ (Apple Silicon recommended)
- Xcode Command Line Tools (`xcode-select --install`)
- Python 3 (included with macOS)

## Quick start

```bash
chmod +x build.sh
./build.sh
```

This compiles the Swift CLI and starts the web UI at **http://localhost:3939**. No pip installs needed — the server uses only Python stdlib.

## CLI usage

```bash
./heic-convert input.tiff output.heic --quality 0.85 --headroom 4.0
```

- `--quality` — HEIC compression (0.0–1.0, default 0.85)
- `--headroom` — HDR brightness boost factor (1.0–16.0, default 4.0)

Outputs JSON to stdout:
```json
{"success":true,"output":"/path/to/output.heic","size_bytes":123456,"width":4000,"height":3000}
```

## Supported inputs

- **TIFF** (16-bit recommended for real HDR data)
- **PNG**
- **JPEG**

## How it works

The converter produces HEIC files with an embedded HDR gain map per ISO 21496-1:

1. Source image is loaded in extended linear Display P3 color space
2. An SDR base layer is created by clamping to standard range
3. A gain map is computed from the HDR-to-SDR luminance ratio
4. Both layers plus metadata are written into a single HEIC file

For SDR inputs (8-bit JPEG/PNG), a synthetic HDR boost is applied to highlights.

**Headroom** controls the maximum brightness multiplier on HDR displays. A headroom of 4.0 means highlights can be up to 4x brighter than SDR on capable screens.

#!/usr/bin/env python3
"""Lightweight HTTP server for HEIC HDR conversion. Uses only stdlib — no pip installs."""

import http.server
import json
import os
import shutil
import subprocess
import threading
import uuid
import cgi
from pathlib import Path
from urllib.parse import urlparse

PORT = int(os.environ.get("HEIC_PORT", "3939"))
BASE = Path(__file__).resolve().parent.parent
BINARY = Path(os.environ.get("HEIC_BINARY", str(BASE / "heic-convert")))
TMP = Path(os.environ.get("HEIC_TMP_DIR", str(BASE / "tmp")))
PUBLIC = Path(__file__).resolve().parent / "public"

TMP.mkdir(exist_ok=True)

# Track files for cleanup
_cleanup_lock = threading.Lock()
_cleanup_timers: dict[str, threading.Timer] = {}


def schedule_cleanup(path: Path, delay: int = 600):
    """Delete file after delay seconds."""
    def _rm():
        try:
            path.unlink(missing_ok=True)
        except Exception:
            pass
        with _cleanup_lock:
            _cleanup_timers.pop(str(path), None)

    t = threading.Timer(delay, _rm)
    t.daemon = True
    with _cleanup_lock:
        _cleanup_timers[str(path)] = t
    t.start()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Quieter logging
        pass

    def _send_json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_static(self, rel_path: str):
        if rel_path == "" or rel_path == "/":
            rel_path = "index.html"
        fp = PUBLIC / rel_path.lstrip("/")
        fp = fp.resolve()

        # Security: ensure within public dir
        if not str(fp).startswith(str(PUBLIC)):
            self.send_error(403)
            return

        if not fp.is_file():
            self.send_error(404)
            return

        ext = fp.suffix.lower()
        ct = {
            ".html": "text/html",
            ".css": "text/css",
            ".js": "application/javascript",
            ".json": "application/json",
            ".png": "image/png",
            ".svg": "image/svg+xml",
        }.get(ext, "application/octet-stream")

        data = fp.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        # Download endpoint
        if path.startswith("/api/download/"):
            filename = os.path.basename(path.split("/")[-1])
            mime_by_ext = {".heic": "image/heic", ".jpg": "image/jpeg"}
            file_ext = os.path.splitext(filename)[1].lower()
            if file_ext not in mime_by_ext:
                self.send_error(400, "Invalid file type")
                return
            fp = TMP / filename
            try:
                data = fp.read_bytes()
            except FileNotFoundError:
                self.send_error(404, "File not found or expired")
                return
            self.send_response(200)
            self.send_header("Content-Type", mime_by_ext[file_ext])
            self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        # Static files
        self._serve_static(path)

    def do_POST(self):
        if self.path != "/api/convert":
            self.send_error(404)
            return

        content_type = self.headers.get("Content-Type", "")
        if "multipart/form-data" not in content_type:
            self._send_json({"success": False, "error": "Expected multipart/form-data"}, 400)
            return

        # Parse multipart
        form = cgi.FieldStorage(
            fp=self.rfile,
            headers=self.headers,
            environ={
                "REQUEST_METHOD": "POST",
                "CONTENT_TYPE": content_type,
            },
        )

        if "image" not in form:
            self._send_json({"success": False, "error": "No image file uploaded"}, 400)
            return
        image_field = form["image"]
        if not getattr(image_field, "filename", None):
            self._send_json({"success": False, "error": "No image file uploaded"}, 400)
            return

        original_name = os.path.basename(image_field.filename)
        ext = os.path.splitext(original_name)[1].lower()
        encode_exts = {".tiff", ".tif", ".png", ".jpg", ".jpeg"}
        decode_exts = {".heic", ".heif"}
        if ext not in encode_exts and ext not in decode_exts:
            self._send_json({"success": False, "error": f"Unsupported format: {ext}", "hint": "Use JPEG, PNG, TIFF (to encode) or HEIC (to decode)."}, 400)
            return
        out_ext = ".jpg" if ext in decode_exts else ".heic"
        operation = "decode" if ext in decode_exts else "encode"

        quality = "0.85"
        headroom = "4.0"
        if "quality" in form:
            quality = form.getvalue("quality", "0.85")
        if "headroom" in form:
            headroom = form.getvalue("headroom", "4.0")

        # Save uploaded file
        uid = str(uuid.uuid4())
        input_path = TMP / f"{uid}{ext}"
        with open(input_path, "wb") as f:
            shutil.copyfileobj(image_field.file, f)

        original_size = input_path.stat().st_size
        output_path = TMP / f"{uid}{out_ext}"

        # Run converter
        try:
            result = subprocess.run(
                [str(BINARY), str(input_path), str(output_path),
                 "--quality", quality, "--headroom", headroom],
                capture_output=True, text=True, timeout=300,
            )
        except subprocess.TimeoutExpired:
            output_path.unlink(missing_ok=True)
            self._send_json({"success": False, "error": "Conversion timed out", "hint": "The image may be too large. Try a smaller image."}, 500)
            return
        except Exception as e:
            output_path.unlink(missing_ok=True)
            self._send_json({"success": False, "error": str(e), "hint": "An unexpected error occurred. Try again or use a different image."}, 500)
            return
        finally:
            input_path.unlink(missing_ok=True)

        # Parse CLI output
        try:
            cli_result = json.loads(result.stdout.strip())
        except json.JSONDecodeError:
            output_path.unlink(missing_ok=True)
            self._send_json({
                "success": False,
                "error": "Converter crashed unexpectedly",
                "hint": "The image may be corrupted or in an unsupported format. Try a different image.",
            })
            return

        if not cli_result.get("success"):
            output_path.unlink(missing_ok=True)
            self._send_json({
                "success": False,
                "error": cli_result.get("error", "Conversion failed"),
                "hint": cli_result.get("hint"),
            })
            return

        # Schedule cleanup
        schedule_cleanup(output_path)

        self._send_json({
            "success": True,
            "downloadUrl": f"/api/download/{uid}{out_ext}",
            "originalName": original_name,
            "originalSize": original_size,
            "outputSize": cli_result.get("size_bytes"),
            "outputExt": out_ext,
            "operation": operation,
            "width": cli_result.get("width"),
            "height": cli_result.get("height"),
            "elapsed_ms": cli_result.get("elapsed_ms"),
        })


def main():
    if not BINARY.exists():
        print(f"Error: heic-convert not found at {BINARY}")
        print("Run build.sh first to compile the Swift CLI.")
        raise SystemExit(1)

    server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    print()
    print("  HEIC HDR Converter")
    print(f"  http://localhost:{PORT}")
    print()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


if __name__ == "__main__":
    main()

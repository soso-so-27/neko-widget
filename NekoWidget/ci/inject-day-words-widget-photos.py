"""Review-only: put two sample cat photos into the day-words Widget fixture.

Edits only the disposable CI checkout of a capture run, never a commit. The
photos are the repository's own fixtures (ci/fixtures/cats): the gray cat on a
light carpet (bright) and the black-and-white cat on a gray sofa (dark),
reduced to 1100 pixels with macOS sips.
"""
import base64
import subprocess
import sys
import tempfile
from pathlib import Path

CATS = Path(__file__).resolve().parent / "fixtures" / "cats"
PHOTOS = {"BRIGHT": "cat-gray-portrait.png", "DARK": "cat-tuxedo-landscape.png"}

view = Path(sys.argv[1])
source = view.read_text(encoding="utf-8")
with tempfile.TemporaryDirectory() as work:
    for name, filename in PHOTOS.items():
        marker = f"__DAY_WORDS_{name}_JPEG_BASE64__"
        if source.count(marker) != 1:
            raise SystemExit(f"Missing or duplicate day-words photo marker: {name}")
        output = Path(work, f"{name}.jpg")
        subprocess.run(
            ["sips", "-Z", "1100", "-s", "format", "jpeg", "-s", "formatOptions", "85",
             str(CATS / filename), "--out", str(output)],
            check=True, stdout=subprocess.DEVNULL,
        )
        data = output.read_bytes()
        if not data.startswith(b"\xff\xd8") or len(data) > 1024 * 1024:
            raise SystemExit("The day-words photo must be a bounded JPEG")
        source = source.replace(marker, base64.b64encode(data).decode("ascii"))
        print(f"{name}: {filename} -> {len(data)} bytes")
view.write_text(source, encoding="utf-8")

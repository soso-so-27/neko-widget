"""Fetch only the pinned public model; never include private images in this target."""
import hashlib
from pathlib import Path
import urllib.request

REVISION = "9dd4c915be29a81b116b3e30eb996c59d0e7ede0"
SHA256 = "6a5e2373ab348bed588cef4072f3914ca9c8bacde3e8d0651019e8dad86b24ba"
SIZE = 89_227_604
URL = f"https://huggingface.co/open-noodle/pet-recognition-small/resolve/{REVISION}/recognition/model.onnx"


def verify(path):
    if path.stat().st_size != SIZE:
        raise ValueError("Unexpected model size")
    with path.open("rb") as data:
        if hashlib.file_digest(data, "sha256").hexdigest() != SHA256:
            raise ValueError("Model SHA-256 mismatch")


def main():
    resources = Path(__file__).resolve().parent / "Resources"
    resources.mkdir(exist_ok=True)
    destination = resources / "model.onnx"
    if destination.exists():
        verify(destination)
        print("Existing pinned model verified")
        return
    temporary = resources / "model.onnx.download"
    # Exclusive creation prevents overwriting any existing or partial download.
    with temporary.open("xb") as output, urllib.request.urlopen(URL, timeout=60) as response:
        received = 0
        while chunk := response.read(1_048_576):
            received += len(chunk)
            if received > SIZE:
                raise ValueError("Download larger than pinned model")
            output.write(chunk)
    verify(temporary)
    temporary.rename(destination)
    print(f"Pinned public model verified: {SIZE} bytes, {SHA256}")


if __name__ == "__main__":
    main()

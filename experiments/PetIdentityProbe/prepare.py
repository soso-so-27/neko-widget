"""Fetch only the two pinned public models; never include private images."""
import hashlib
from pathlib import Path
import urllib.request

REVISION = "9dd4c915be29a81b116b3e30eb996c59d0e7ede0"
SHA256 = "6a5e2373ab348bed588cef4072f3914ca9c8bacde3e8d0651019e8dad86b24ba"
SIZE = 89_227_604
URL = f"https://huggingface.co/open-noodle/pet-recognition-small/resolve/{REVISION}/recognition/model.onnx"
DETECTOR_SHA256 = "c789161ed43c8269fcd4e67c67eeeb4e80c622da2eb296a20bc6007bd18a0b7d"
DETECTOR_SIZE = 3_659_407
DETECTOR_URL = "https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_nano.onnx"


def verify(path, size=SIZE, sha256=SHA256):
    if path.is_symlink() or path.stat().st_size != size:
        raise ValueError("Unexpected model size")
    with path.open("rb") as data:
        if hashlib.file_digest(data, "sha256").hexdigest() != sha256:
            raise ValueError("Model SHA-256 mismatch")


def fetch(resources, name, url, size, sha256):
    destination = resources / name
    if destination.exists():
        verify(destination, size, sha256)
        print("Existing pinned model verified")
        return
    temporary = resources / f"{name}.download"
    # Exclusive creation prevents overwriting any existing or partial download.
    with temporary.open("xb") as output, urllib.request.urlopen(url, timeout=60) as response:
        received = 0
        while chunk := response.read(1_048_576):
            received += len(chunk)
            if received > size:
                raise ValueError("Download larger than pinned model")
            output.write(chunk)
    verify(temporary, size, sha256)
    temporary.rename(destination)
    print(f"Pinned public model verified: {size} bytes, {sha256}")


def main():
    resources = Path(__file__).resolve().parent / "Resources"
    resources.mkdir(exist_ok=True)
    fetch(resources, "model.onnx", URL, SIZE, SHA256)
    fetch(resources, "yolox-nano.onnx", DETECTOR_URL, DETECTOR_SIZE, DETECTOR_SHA256)


if __name__ == "__main__":
    main()

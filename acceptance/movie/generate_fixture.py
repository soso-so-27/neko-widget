"""Generate only synthetic inputs; never claim to run the app exporter."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import wave
from PIL import Image, ImageDraw


def generate(destination):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    sizes = [(720, 1280), (1280, 720), (900, 900), (360, 1440), (1440, 360), (720, 1280)]
    colors = ["#203060", "#602030", "#306020", "#403060", "#206060", "#604020"]
    files = []
    for index, (size, color) in enumerate(zip(sizes, colors), 1):
        image = Image.new("RGB", size, color)
        draw = ImageDraw.Draw(image)
        w, h = size
        draw.rectangle((4, 4, w-5, h-5), outline="white", width=8)
        for x, y, name in [(20, 20, "TL"), (w-100, 20, "TR"), (20, h-45, "BL"), (w-100, h-45, "BR")]:
            draw.text((x, y), f"{index} {name}", fill="white")
        draw.ellipse((w*.3, h*.3, w*.7, h*.7), fill="#f0c060")
        draw.text((w*.3, h*.5), f"SYNTHETIC {index}", fill="black")
        name = f"still-{index}.png"
        image.save(destination/name)
        files.append(name)
    frames = destination/"motion"
    frames.mkdir()
    for index in range(72):
        image = Image.new("RGB", (1280, 720), "#103040")
        draw = ImageDraw.Draw(image)
        x = 50 + index*13
        draw.rectangle((x, 240, x+180, 420), fill="#f0c060")
        draw.rectangle((4, 4, 1275, 715), outline="white", width=8)
        draw.text((20, 20), f"SYNTHETIC MOTION FRAME {index:02d}", fill="white")
        image.save(frames/f"frame-{index:03d}.png")
    # Deliberately identifiable source-video audio, never an output soundtrack.
    with wave.open(str(destination/"source-audio-997hz.wav"), "wb") as output:
        output.setparams((1, 2, 48000, 0, "NONE", "not compressed"))
        output.writeframes(b"".join(struct.pack("<h", round(16000*math.sin(2*math.pi*997*i/48000))) for i in range(144000)))
    scenes = [
        {"file": "still-1.png", "date": "2025-01-02T12:00:00Z", "kind": "stillPhoto", "duration": 1.8},
        {"file": "still-2.png", "date": "2025-01-07T12:00:00Z", "kind": "stillPhoto", "duration": 1.45},
        {"file": "source-video.mp4", "date": "2025-01-19T12:00:00Z", "kind": "video", "duration": 2.0},
        {"file": "still-3.png", "date": "2025-02-03T12:00:00Z", "kind": "stillPhoto", "duration": 1.45},
        {"file": "still-4.png", "date": "2025-02-12T12:00:00Z", "kind": "stillPhoto", "duration": 1.45},
        {"file": "source-video.mp4", "date": "2025-02-22T12:00:00Z", "kind": "video", "duration": 2.0},
        {"file": "still-5.png", "date": "2025-03-04T12:00:00Z", "kind": "stillPhoto", "duration": 1.45},
        {"file": "still-6.png", "date": "2025-03-19T12:00:00Z", "kind": "stillPhoto", "duration": 2.0},
    ]
    frame_count = sum(math.floor(scene["duration"]*24+.5) for scene in scenes)+math.floor(1.8*24+.5)
    manifest = {"schemaVersion": 1, "syntheticOnly": True, "productionExportExecuted": False,
                "scenes": scenes, "expectedFrameCount": frame_count, "expectedDuration": frame_count/24,
                "sourceMetadataSentinel": "SYNTHETIC_SOURCE_DO_NOT_EXPORT",
                "sha256": {name: hashlib.sha256((destination/name).read_bytes()).hexdigest() for name in files+["source-audio-997hz.wav"]}}
    (destination/"fixture.json").write_text(json.dumps(manifest, indent=2)+"\n", encoding="utf-8")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    print(json.dumps(generate(args.destination), indent=2))

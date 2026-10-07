"""Verify a synthetic input MP4; never validate a production movie export."""
import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys


def tone_fraction(samples, frequency=997, sample_rate=48000):
    energy = sum(value*value for value in samples)
    if not samples or energy == 0:
        return 0.0
    sine = sum(value*math.sin(2*math.pi*frequency*i/sample_rate) for i, value in enumerate(samples))
    cosine = sum(value*math.cos(2*math.pi*frequency*i/sample_rate) for i, value in enumerate(samples))
    return 2*(sine*sine+cosine*cosine)/(len(samples)*energy)


def verify(ffmpeg, source):
    result = subprocess.run([str(ffmpeg), "-hide_banner", "-nostdin", "-i", str(source),
        "-map", "0:v:0", "-progress", "pipe:1", "-f", "null", "-"], capture_output=True, check=True)
    log = result.stderr.decode("utf-8", errors="replace")
    progress = result.stdout.decode("utf-8")
    assert "Duration: 00:00:03.00" in log, "source duration differs from 3 seconds"
    assert re.search(r"Video: h264 .*1280x720.*24 fps", log), "unexpected source video format"
    assert re.search(r"Audio: aac .*48000 Hz, mono", log), "source tone audio missing"
    for tag in ["title", "comment"]:
        assert re.search(tag+r"\s*: SYNTHETIC_SOURCE_DO_NOT_EXPORT", log), "source sentinel missing"
    counts = re.findall(r"^frame=(\d+)$", progress, re.M)
    assert counts and int(counts[-1]) == 72, "source must decode 72 frames"
    audio = subprocess.run([str(ffmpeg), "-v", "error", "-nostdin", "-i", str(source),
        "-map", "0:a:0", "-t", "3.1", "-ac", "1", "-ar", "48000", "-f", "s16le", "-"],
        capture_output=True, check=True).stdout
    pcm = array("h"); pcm.frombytes(audio)
    if sys.byteorder != "little":
        pcm.byteswap()
    assert abs(len(pcm)/48000-3) < .03, "unexpected source audio duration"
    fraction = tone_fraction(pcm[48000:96000])
    assert fraction > .98, "decoded source audio is not the intended 997 Hz tone"
    return {"schemaVersion": 1, "syntheticInputOnly": True, "productionExportExecuted": False,
        "sourceFile": "source-video.mp4", "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "bytes": source.stat().st_size, "videoCodec": "h264", "width": 1280, "height": 720,
        "fps": 24, "duration": 3, "decodedVideoFrames": int(counts[-1]),
        "audioCodec": "aac", "audioSampleRate": 48000, "audioChannels": 1,
        "decodedAudioSamples": len(pcm), "source997HzEnergyFraction": fraction,
        "sourceMetadataSentinelVerified": True,
        "ffmpegSHA256": hashlib.sha256(ffmpeg.read_bytes()).hexdigest()}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--ffmpeg", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    report = verify(args.ffmpeg, args.source)
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    assert manifest["syntheticOnly"] and manifest["productionExportExecuted"] is False
    previous = manifest["sha256"].get("source-video.mp4")
    assert previous is None or previous == report["sha256"], "existing source hash differs"
    with args.report.open("x", encoding="utf-8") as destination:
        destination.write(json.dumps(report, indent=2)+"\n")
    manifest["sha256"]["source-video.mp4"] = report["sha256"]
    manifest["sourceVideoVerification"] = report
    args.manifest.write_text(json.dumps(manifest, indent=2)+"\n", encoding="utf-8")
    print(json.dumps(report, indent=2))

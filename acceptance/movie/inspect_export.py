"""Read an actual MP4 and retain probe/decode evidence in a NEW directory.

This never runs the shipping exporter, imports Photos, shares, or cleans exports.
A technical pass leaves visual inspection and listening pending.
"""
import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import wave

from validate_probe import validate
from verify_source_video import tone_fraction
from diagnostic_fixture import regular_bytes, unique_json_fields
from export_timestamps import export_interval, validate_timestamps

RATE = 48000
BUNDLED_BGM_SHA256 = "f9acf7a8dd0ed3ba2f45a110bc6702c39e70233d19edaeb8323659057fa8f134"


def digest(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def pcm_samples(raw):
    samples = array("h")
    samples.frombytes(raw)
    if sys.byteorder != "little":
        samples.byteswap()
    return samples


def audio_metrics(actual, reference, duration):
    """Compare decoded stereo PCM against bundled WAV, including volume/fades.

    This numerical comparison is intentionally separate from listening. AAC
    padding of <=50ms is allowed; clipping, silence and source tone are rejected.
    """
    if not reference or len(reference) % 2 or len(actual) % 2:
        raise ValueError("stereo PCM required")
    count = round(duration * RATE)
    if abs(len(actual) / 2 - count) > RATE * .05:
        raise ValueError("unexpected decoded audio duration")
    count = min(count, len(actual) // 2)
    energy = residual = reference_energy = 0.0
    segments = {"fadeIn": [0.0, 0.0, 0.0], "middle": [0.0, 0.0, 0.0], "fadeOut": [0.0, 0.0, 0.0]}
    clipped = 0
    for frame in range(count):
        time = frame / RATE
        gain = .55 * min(1, time / .25, max(0, duration - time))
        for channel in range(2):
            value = actual[frame * 2 + channel]
            expected = reference[(frame * 2 + channel) % len(reference)] * gain
            energy += value * value
            reference_energy += expected * expected
            residual += (value - expected) ** 2
            segment = "fadeIn" if time < .25 else ("fadeOut" if time >= duration-1 else "middle")
            segments[segment][0] += value * value
            segments[segment][1] += expected * expected
            segments[segment][2] += (value - expected) ** 2
            clipped += abs(value) >= 32767
    error = math.sqrt(residual / reference_energy) if reference_energy else None
    # Central 1s windows include both synthetic source-video intervals.
    tones = []
    for second in range(1, max(1, math.floor(duration) - 1)):
        start = second * RATE
        mono = [(actual[i*2] + actual[i*2+1])/2 for i in range(start, min(start+RATE, count))]
        tones.append({"startSeconds": second, "source997HzEnergyFraction": tone_fraction(mono)})
    maximum_tone = max((item["source997HzEnergyFraction"] for item in tones), default=0)
    errors = []
    local_errors = {}
    for label, (actual_energy, expected_energy, difference) in segments.items():
        local_error = (math.sqrt(difference / expected_energy) if expected_energy
                       else (0.0 if actual_energy == 0 else None))
        local_errors[label] = local_error
        if local_error is None or local_error > .25:
            errors.append(label + " waveform differs from specified BGM envelope")
    if energy == 0:
        errors.append("decoded audio is silent")
    if error is None or error > .15:
        errors.append("decoded audio differs from bundled BGM at 55% with specified fades")
    if maximum_tone > .01:
        errors.append("997Hz source tone detected")
    if clipped:
        errors.append("clipped decoded samples")
    return {"decodedStereoFrames": len(actual)//2, "referenceNormalizedRMSError": error,
            "segmentNormalizedRMSError": local_errors,
            "clippedSamples": clipped, "sourceToneWindows": tones, "errors": errors}


def inspect(source, destination, ffmpeg, ffprobe, duration, sound, reference=None,
            receipt=None, source_sha=None, receipt_sha=None):
    source = Path(source).resolve(strict=True)
    if not source.is_file():
        raise ValueError("MP4 input must be a regular file")
    if not math.isfinite(duration) or duration <= 1.25 or duration > 60:
        raise ValueError("expected duration must be within (1.25, 60] seconds")
    if sound and reference is None:
        raise ValueError("sound ON requires the bundled BGM WAV reference")
    before = digest(source)
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    report = {"schemaVersion": 1, "inputSHA256": before, "inputBytes": source.stat().st_size,
              "inspectionToolSHA256": digest(__file__),
              "soundEnabled": sound, "productionExportExecutedByThisTool": False,
              "visualInspection": "not performed", "listening": "not performed", "errors": []}
    def run(tool, arguments):
        return subprocess.run([str(tool), *arguments], check=True, capture_output=True, timeout=120).stdout
    try:
        report["toolVersions"] = {"ffmpeg": run(ffmpeg, ["-version"]).decode("utf-8", errors="replace").splitlines()[0],
                                  "ffprobe": run(ffprobe, ["-version"]).decode("utf-8", errors="replace").splitlines()[0]}
        raw = run(ffprobe, ["-v", "error", "-show_format", "-show_streams", "-of", "json", str(source)])
        (destination / "probe.json").write_bytes(raw)
        probe = json.loads(raw, object_pairs_hook=unique_json_fields)
        timestamp_verified = False
        # All technical acceptance requires provenance, even when ffprobe omits
        # a creation_time tag. Hidden nonzero modification dates cannot bypass it.
        if receipt is None or source_sha is None or receipt_sha is None:
            report["errors"].append("Measured export receipt unavailable or invalid")
        else:
            try:
                if receipt is None or source_sha is None or receipt_sha is None:
                    raise ValueError("Receipt and independently pinned source/receipt hashes are required")
                receipt_bytes = regular_bytes(Path(receipt), 64 * 1024)
                interval = export_interval(Path(receipt), receipt_sha, source_sha, source.name, before, sound, duration)
                timestamp_errors = validate_timestamps(regular_bytes(source, 100 * 1024 * 1024), probe, interval)
                if regular_bytes(Path(receipt), 64 * 1024) != receipt_bytes:
                    raise ValueError("Export receipt changed during inspection")
                report["errors"].extend(timestamp_errors)
                timestamp_verified = not timestamp_errors
                report["timestampEvidence"] = {"receiptSHA256": hashlib.sha256(receipt_bytes).hexdigest(),
                    "buildSourceSHA": source_sha, "headerAndProbeCheck": "passed" if timestamp_verified else "failed"}
            except (OSError, ValueError, TypeError, KeyError):
                report["errors"].append("Measured export receipt unavailable or invalid")
        report["errors"].extend(validate(probe, duration, sound, export_timestamps_verified=timestamp_verified))
        # Decode ALL video frames. Hash evidence is from pixels, not nb_frames.
        frames = run(ffmpeg, ["-v", "error", "-nostdin", "-xerror", "-i", str(source),
                             "-map", "0:v:0", "-an", "-fps_mode", "passthrough", "-f", "framemd5", "-"])
        (destination / "decoded-frames.framemd5").write_bytes(frames)
        rows = [line for line in frames.decode("utf-8").splitlines() if line.strip() and not line.startswith("#")]
        report["decodedVideoFrames"] = len(rows)
        if len(rows) != math.floor(duration*24+.5):
            report["errors"].append("unexpected actual decoded video frame count")
        for label, time in [("opening", .25), ("middle", duration/2), ("ending", duration-.1)]:
            image = run(ffmpeg, ["-v", "error", "-nostdin", "-xerror", "-i", str(source), "-ss", str(time),
                                "-map", "0:v:0", "-frames:v", "1", "-f", "image2pipe", "-vcodec", "png", "-"])
            if not image.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError("representative frame did not decode")
            (destination / (label+".png")).write_bytes(image)
        if sound:
            reference_digest = digest(reference)
            if reference_digest != BUNDLED_BGM_SHA256:
                raise ValueError("reference hash differs from the shipping bundled BGM")
            with wave.open(str(reference), "rb") as wav:
                if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth(), wav.getcomptype()) != (RATE, 2, 2, "NONE"):
                    raise ValueError("bundled reference must be stereo 48kHz PCM16")
                samples = pcm_samples(wav.readframes(wav.getnframes()))
            report["referenceSHA256"] = digest(reference)
            if report["referenceSHA256"] != reference_digest:
                raise ValueError("BGM reference changed during inspection")
            raw_audio = run(ffmpeg, ["-v", "error", "-nostdin", "-xerror", "-i", str(source),
                                    "-map", "0:a:0", "-t", str(duration+.05), "-ac", "2", "-ar", str(RATE), "-f", "s16le", "-"])
            report["audioComparison"] = audio_metrics(pcm_samples(raw_audio), samples, duration)
            report["errors"].extend(report["audioComparison"]["errors"])
    except (subprocess.SubprocessError, OSError, ValueError, TypeError, wave.Error) as error:
        report["errors"].append(type(error).__name__ + ": " + str(error))
    finally:
        try:
            report["inputUnchanged"] = digest(source) == before
        except OSError as error:
            report["inputUnchanged"] = False
            report["errors"].append("input unavailable after inspection: " + type(error).__name__)
        if not report["inputUnchanged"]:
            report["errors"].append("input changed during inspection")
        report["technicalCheck"] = "failed" if report["errors"] else "passed"
        (destination / "inspection.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--ffprobe", default="ffprobe")
    parser.add_argument("--expected-duration", type=float, required=True)
    parser.add_argument("--sound", choices=["on", "off"], required=True)
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--receipt", type=Path, help="Unmodified native schema-2 synthetic export receipt")
    parser.add_argument("--source-sha", help="Expected immutable build SHA, supplied independently of the receipt")
    parser.add_argument("--receipt-sha256", help="Expected receipt hash from the independently verified artifact")
    args = parser.parse_args()
    result = inspect(args.source, args.destination, args.ffmpeg, args.ffprobe,
                     args.expected_duration, args.sound == "on", args.reference, args.receipt, args.source_sha,
                     args.receipt_sha256)
    print(json.dumps(result, indent=2))
    raise SystemExit(bool(result["errors"]))

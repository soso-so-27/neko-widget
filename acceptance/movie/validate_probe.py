"""Structural acceptance only. Input is ffprobe JSON, not a success receipt."""
import argparse
import json
import math
from fractions import Fraction
from pathlib import Path


def validate(probe, expected_duration, sound_enabled):
    errors = []
    def check(condition, message):
        if not condition:
            errors.append(message)
    if not isinstance(probe, dict):
        return ["probe must be an object"]
    if not isinstance(expected_duration, (float, int)) or isinstance(expected_duration, bool) or not math.isfinite(expected_duration) or expected_duration <= 0:
        return ["expected duration must be positive and finite"]
    container = probe.get("format", {})
    if not isinstance(container, dict):
        return ["format must be an object"]
    name = container.get("format_name", "")
    check(isinstance(name, str) and "mp4" in name.split(","), "container must be MP4")
    streams = probe.get("streams", [])
    if not isinstance(streams, list) or any(not isinstance(s, dict) for s in streams):
        return errors + ["streams must be a list of objects"]
    video = [s for s in streams if s.get("codec_type") == "video"]
    audio = [s for s in streams if s.get("codec_type") == "audio"]
    check(len(video) == 1, "exactly one video stream required")
    check(len(audio) == int(sound_enabled), "sound ON needs one audio stream; OFF needs none")
    check(len(streams) == len(video)+len(audio), "unexpected extra stream")
    if video:
        stream = video[0]
        check(stream.get("codec_name") == "h264", "video must be H.264")
        check((stream.get("width"), stream.get("height")) == (720, 1280), "output must be 720x1280")
        try:
            check(Fraction(stream.get("avg_frame_rate", "0/1")) == 24, "output must be 24 fps")
            check(Fraction(stream.get("r_frame_rate", "0/1")) == 24, "declared frame rate must be 24 fps")
        except (ValueError, ZeroDivisionError, TypeError):
            errors.append("invalid frame rate")
    if video:
        try:
            count = video[0].get("nb_frames", "")
            check((type(count) is int or (isinstance(count, str) and count.isascii() and count.isdigit()))
                  and int(count) == math.floor(expected_duration*24+.5), "unexpected encoded frame count")
        except (ValueError, TypeError, OverflowError):
            errors.append("missing or invalid encoded frame count")
    if audio:
        stream = audio[0]
        check(stream.get("codec_name") == "aac", "audio must be AAC")
        check(str(stream.get("sample_rate")) == "48000", "audio must be 48 kHz")
        check(stream.get("channels") == 2, "audio must be stereo")
    try:
        duration = float(probe["format"]["duration"])
        check(math.isfinite(duration) and abs(duration-expected_duration) <= .1, "unexpected total duration")
    except (KeyError, TypeError, ValueError):
        errors.append("missing or invalid duration")
    # Muxer technical tags are allowed. Source names/location/timestamps are not.
    allowed = {"major_brand", "minor_version", "compatible_brands", "encoder", "language", "handler_name", "vendor_id"}
    for item in [container]+streams:
        tags = item.get("tags", {})
        if not isinstance(tags, dict) or any(not isinstance(tag, str) or not isinstance(value, str) for tag, value in tags.items()):
            errors.append("invalid metadata tags")
            continue
        for tag in tags:
            check(tag.lower() in allowed, "unexpected metadata tag: "+tag)
        sides = item.get("side_data_list", [])
        if not isinstance(sides, list) or any(not isinstance(side, dict) for side in sides):
            errors.append("invalid side data")
            continue
        for side in sides:
            if side.get("side_data_type") == "Display Matrix":
                check(side.get("rotation", 0) == 0, "unexpected output rotation")
    check("SYNTHETIC_SOURCE_DO_NOT_EXPORT" not in json.dumps(probe), "source metadata sentinel leaked")
    return errors


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("probe", type=Path)
    parser.add_argument("--expected-duration", type=float, required=True)
    parser.add_argument("--sound", choices=["on", "off"], required=True)
    args = parser.parse_args()
    errors = validate(json.loads(args.probe.read_text(encoding="utf-8")), args.expected_duration, args.sound == "on")
    print(json.dumps({"structuralCheck": "failed" if errors else "passed", "errors": errors,
                      "visualAudioAcceptance": "not performed"}, indent=2))
    raise SystemExit(bool(errors))

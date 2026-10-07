"""Accept muxer dates only with independently measured, hash-bound export evidence.

Never derives an export interval from the MP4, file timestamps or CI log times.
Old receipts remain readable by the collector but cannot authorize creation_time.
"""
from datetime import datetime
import hashlib
import re

from diagnostic_fixture import regular_bytes, validated_receipt, validate_export_timing

MP4_EPOCH = 2082844800
SOURCE_DATES = {"2025-01-02T12:00:00Z", "2025-01-07T12:00:00Z", "2025-01-19T12:00:00Z",
                "2025-02-03T12:00:00Z", "2025-02-12T12:00:00Z", "2025-02-22T12:00:00Z",
                "2025-03-04T12:00:00Z", "2025-03-19T12:00:00Z"}
SOURCE_SECONDS = {int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()) for s in SOURCE_DATES}


def export_interval(receipt_path, receipt_sha, source_sha, file_name, input_sha, sound, duration):
    if not isinstance(source_sha, str) or re.fullmatch(r"[0-9a-f]{40}", source_sha) is None:
        raise ValueError("Expected immutable build source SHA")
    data = regular_bytes(receipt_path, 64 * 1024)
    if (not isinstance(receipt_sha, str) or re.fullmatch(r"[0-9a-f]{64}", receipt_sha) is None
            or hashlib.sha256(data).hexdigest() != receipt_sha):
        raise ValueError("Native receipt differs from independently pinned artifact hash")
    receipt = validated_receipt(data)
    if (receipt.get("schemaVersion") != 2 or receipt["buildSourceSHA"] != source_sha
            or receipt["result"] != "exported; external inspection pending"
            or receipt["exportAttempts"] != 2 or receipt["shippingExporterInvoked"] is not True
            or any(receipt[k] is not True for k in ["photoBaselineRestored", "managedCleanupSucceeded",
                                                   "returnedManagedExportsCleaned"])
            or receipt["remainingNewManagedDirectories"] != []
            or {e["file"] for e in receipt["exports"]} != {"exported-on.mp4", "exported-off.mp4"}):
        raise ValueError("Measured export receipt or cleanup evidence is incomplete")
    entries = {e["file"]: e for e in receipt["exports"]}
    _, on_end = validate_export_timing(entries["exported-on.mp4"])
    off_start, _ = validate_export_timing(entries["exported-off.mp4"])
    if on_end > off_start:
        raise ValueError("Sequential export timing overlaps")
    entry = entries.get(file_name)
    if (entry is None or entry["sha256"] != input_sha or entry["soundEnabled"] is not sound
            or abs(entry["duration"]-duration) > .001):
        raise ValueError("Export measurement is not bound to this MP4")
    return validate_export_timing(entry)


def boxes(data, start, end):
    count = 0
    while start < end:
        count += 1
        if count > 4096 or end-start < 8:
            raise ValueError("Malformed MP4 box boundary")
        size = int.from_bytes(data[start:start+4], "big")
        kind = data[start+4:start+8]
        head = 8
        if size == 1:
            if end-start < 16:
                raise ValueError("Truncated extended MP4 box")
            size = int.from_bytes(data[start+8:start+16], "big")
            head = 16
        elif size == 0:
            size = end-start
        if size < head or start+size > end:
            raise ValueError("Malformed MP4 box size")
        yield kind, start+head, start+size
        start += size


def one(children, kind):
    found = [(start, end) for name, start, end in children if name == kind]
    if len(found) != 1:
        raise ValueError("Missing or ambiguous MP4 timing header")
    return found[0]


def header_times(data, bounds):
    start, end = bounds
    if end-start < 4 or data[start] not in {0, 1}:
        raise ValueError("Unsupported MP4 timing header")
    width = 4 if data[start] == 0 else 8
    if end-start < 4+2*width+4:
        raise ValueError("Truncated MP4 timing header")
    offset = start+4
    created = int.from_bytes(data[offset:offset+width], "big")-MP4_EPOCH
    modified = int.from_bytes(data[offset+width:offset+2*width], "big")-MP4_EPOCH
    return (created, modified), offset+2*width


def validate_timestamps(data, probe, interval):
    """Read mvhd/tkhd/mdhd directly, matching track IDs and UTC probe tags."""
    try:
        if (not isinstance(probe, dict) or not isinstance(probe.get("format"), dict)
                or not isinstance(probe.get("streams"), list)
                or any(not isinstance(s, dict) for s in probe["streams"])
                or not isinstance(interval, tuple) or len(interval) != 2
                or any(type(n) is not int for n in interval)):
            raise ValueError("Invalid timestamp evidence structure")
        lo, hi = (n//1000 for n in interval)  # MP4 integer-second precision only.
        if lo > hi:
            raise ValueError("Export interval cannot establish MP4 timestamp provenance")
        root = list(boxes(data, 0, len(data)))
        moov = list(boxes(data, *one(root, b"moov")))
        movie_times, _ = header_times(data, one(moov, b"mvhd"))
        created, modified = movie_times
        if not lo <= created <= modified <= hi or created in SOURCE_SECONDS or modified in SOURCE_SECONDS:
            raise ValueError("MP4 header date is outside measured export or retains source date")
        tracks = {}
        for name, start, end in moov:
            if name != b"trak":
                continue
            trak = list(boxes(data, start, end))
            track_times, offset = header_times(data, one(trak, b"tkhd"))
            track_id = int.from_bytes(data[offset:offset+4], "big")
            mdia = list(boxes(data, *one(trak, b"mdia")))
            media_times, _ = header_times(data, one(mdia, b"mdhd"))
            handler_start, handler_end = one(mdia, b"hdlr")
            if handler_end-handler_start < 12:
                raise ValueError("Truncated MP4 media handler")
            handler = data[handler_start+8:handler_start+12]
            if (not track_id or track_id in tracks or handler not in {b"vide", b"soun"}
                    or track_times != movie_times or media_times != movie_times):
                raise ValueError("MP4 timing headers or track identities disagree")
            tracks[track_id] = handler
        streams = probe["streams"]
        if len(tracks) != len(streams):
            raise ValueError("MP4 timing track count disagrees with probe")
        seen = set()
        for item in [probe["format"]]+streams:
            tags = item.get("tags")
            if not isinstance(tags, dict):
                raise ValueError("Timestamp metadata is not an object")
            value = tags.get("creation_time")
            if (not isinstance(value, str) or re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.0{1,6})?Z", value) is None
                    or int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()) != created):
                raise ValueError("Probe creation date is missing or disagrees with MP4 header")
        for stream in streams:
            identifier = stream.get("id")
            if not isinstance(identifier, str) or re.fullmatch(r"0x[0-9a-fA-F]+", identifier) is None:
                raise ValueError("Probe track identity is missing")
            track_id = int(identifier, 16)
            expected = {"video": b"vide", "audio": b"soun"}.get(stream.get("codec_type"))
            if track_id in seen or tracks.get(track_id) != expected:
                raise ValueError("Probe track identity disagrees with MP4 header")
            seen.add(track_id)
        return []
    except (ValueError, TypeError, KeyError, OverflowError):
        # Do not put arbitrary metadata values, original filenames or paths in reports.
        return ["MP4 export timestamp provenance is missing, invalid or inconsistent"]

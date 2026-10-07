"""Synthetic protocol/header tests. Never rewrite or bless previous app artifacts."""
import copy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from diagnostic_fixture import validated_receipt, collect, MANIFEST_SHA256
from export_timestamps import export_interval, validate_timestamps, SOURCE_DATES, SOURCE_SECONDS, MP4_EPOCH
from test_diagnostic_fixture import output_fixture, SHA
from test_preparation import probe
from validate_probe import validate

CREATED = 1767225602
MODIFIED = CREATED+10


def box(kind, payload):
    return (len(payload)+8).to_bytes(4, "big")+kind+payload


def headers(created=CREATED, modified=MODIFIED, sound=True, version=0, damage=None):
    width = 8 if version == 1 else 4
    def timing(kind, extra=b"", modification=modified):
        return box(kind, bytes([version, 0, 0, 0])+(created+MP4_EPOCH).to_bytes(width, "big")
                   +(modification+MP4_EPOCH).to_bytes(width, "big")+extra+b"\0"*24)
    tracks = []
    for index, kind in enumerate([b"vide", b"soun"] if sound else [b"vide"], 1):
        track = timing(b"tkhd", index.to_bytes(4, "big"), modified+1 if damage == "tkhd" else modified)
        media = timing(b"mdhd", modification=modified+1 if damage == "mdhd" else modified)
        if damage == "duplicate":
            media += timing(b"mdhd")
        media += box(b"hdlr", b"\0"*8+kind+b"\0"*12)
        tracks.append(box(b"trak", track+box(b"mdia", media)))
    return box(b"moov", timing(b"mvhd")+b"".join(tracks))


def timed_probe(created=CREATED, sound=True):
    p = probe()
    if not sound:
        p["streams"].pop()
    timestamp = datetime.fromtimestamp(created, timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
    p["format"]["tags"]["creation_time"] = timestamp
    for i, stream in enumerate(p["streams"], 1):
        stream["id"] = hex(i)
        stream["tags"] = {"creation_time": timestamp, "handler_name": "Core Media Video" if i == 1 else "Core Media Audio"}
    return p


def measured_receipt(documents):
    directory, receipt = output_fixture(documents)
    receipt["schemaVersion"] = 2
    for i, entry in enumerate(receipt["exports"]):
        start = (CREATED-1+i*20)*1000+500
        end = start+11500
        entry.update(exportStartedUnixMilliseconds=start, exportCompletedUnixMilliseconds=end,
                     exportElapsedMilliseconds=end-start)
    path = directory/"receipt.json"
    path.write_text(json.dumps(receipt), encoding="utf-8")
    return directory, receipt


class TimestampTests(unittest.TestCase):
    def test_consistent_headers_with_integer_second_quantization(self):
        for sound in [True, False]:
            for version in [0, 1]:
                with self.subTest(sound=sound, version=version):
                    p = timed_probe(sound=sound)
                    interval = ((CREATED-1)*1000+999, MODIFIED*1000+1)
                    self.assertEqual(validate_timestamps(headers(sound=sound, version=version), p, interval), [])
                    self.assertEqual(validate(p, 370/24, sound, export_timestamps_verified=True), [])
                    self.assertTrue(validate(p, 370/24, sound))  # No receipt/header proof => reject.

    def test_old_source_date_rejected_even_inside_forged_interval(self):
        for source in SOURCE_SECONDS:
            self.assertTrue(validate_timestamps(headers(source, source+1), timed_probe(source),
                                                (source*1000, (source+2)*1000)))

    def test_bounds_header_ambiguity_and_truncation_rejected(self):
        for data, interval in [(headers(), ((CREATED+1)*1000, (MODIFIED+1)*1000)),
                               (headers(), ((CREATED-1)*1000, (MODIFIED-1)*1000)),
                               (headers(modified=CREATED-1), ((CREATED-2)*1000, MODIFIED*1000)),
                               (headers(damage="tkhd"), (CREATED*1000, (MODIFIED+2)*1000)),
                               (headers(damage="mdhd"), (CREATED*1000, (MODIFIED+2)*1000)),
                               (headers(damage="duplicate"), (CREATED*1000, MODIFIED*1000)),
                               (headers()+headers(), (CREATED*1000, MODIFIED*1000)),
                               (headers()[:-1], (CREATED*1000, MODIFIED*1000)),
                               (headers(version=2), (CREATED*1000, MODIFIED*1000))]:
            self.assertTrue(validate_timestamps(data, timed_probe(), interval))

    def test_probe_dates_and_track_identity_must_match(self):
        for damage in ["missing", "different", "id", "duplicate-id", "track-count", "fraction"]:
            with self.subTest(damage=damage):
                p = timed_probe()
                if damage == "missing": del p["streams"][0]["tags"]["creation_time"]
                elif damage == "different": p["format"]["tags"]["creation_time"] = "2026-01-01T00:00:00Z"
                elif damage == "fraction": p["format"]["tags"]["creation_time"] = "2026-01-01T00:00:02.100000Z"
                elif damage == "id": p["streams"][0]["id"] = "0xff"
                elif damage == "duplicate-id": p["streams"][1]["id"] = "0x1"
                else: p["streams"].pop()
                self.assertTrue(validate_timestamps(headers(), p, (CREATED*1000, MODIFIED*1000)))

    def test_malformed_probe_and_measurement_fail_without_exception(self):
        for p in [None, [], {"format":None,"streams":[]}, {"format":{},"streams":[None]},
                  {"format":{"tags":None},"streams":[]}]:
            self.assertTrue(validate_timestamps(headers(),p,(CREATED*1000,MODIFIED*1000)))
        for interval in [None, (), (True,False), ("private-sentinel",0), (CREATED*1000,)]:
            errors=validate_timestamps(headers(),timed_probe(),interval)
            self.assertTrue(errors)
            self.assertNotIn("private-sentinel",json.dumps(errors))

    def test_location_original_name_and_date_never_become_technical_tags(self):
        for key, value in [("location", "+12.345+067.890/"), ("filename", "source-video.mp4"),
                           ("handler_name", "still-1.png"), ("encoder", "2025-01-02T12:00:00Z"),
                           ("encoder", "12.345"), ("title", "SYNTHETIC_SOURCE_DO_NOT_EXPORT")]:
            p = timed_probe();p["format"]["tags"][key] = value
            self.assertTrue(validate(p, 370/24, True, export_timestamps_verified=True))

    def test_schema2_measurements_remain_bound_to_hashes_source_and_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary);documents=root/"Documents";documents.mkdir()
            directory, receipt = measured_receipt(documents)
            path = directory/"receipt.json";expected = hashlib.sha256(path.read_bytes()).hexdigest()
            entry = receipt["exports"][0]
            self.assertEqual(export_interval(path, expected, SHA, entry["file"], entry["sha256"], True, 370/24),
                             (entry["exportStartedUnixMilliseconds"], entry["exportCompletedUnixMilliseconds"]))
            self.assertEqual(collect(documents, root/"evidence", SHA)["collectionCheck"], "passed")
            for args in [(None, SHA, entry["file"], entry["sha256"]), (expected, "b"*40, entry["file"], entry["sha256"]),
                         (expected, SHA, "foreign.mp4", entry["sha256"]), (expected, SHA, entry["file"], "b"*64)]:
                with self.assertRaises(ValueError): export_interval(path, *args, True, 370/24)
            # A plausible timing alteration must fail the independently pinned receipt hash.
            receipt["exports"][0]["exportStartedUnixMilliseconds"] -= 1
            path.write_text(json.dumps(receipt), encoding="utf-8")
            with self.assertRaises(ValueError):
                export_interval(path, expected, SHA, entry["file"], entry["sha256"], True, 370/24)

    def test_invalid_measurement_schema_cleanup_and_overlap_fail(self):
        damages = ["legacy", "unknown", "missing", "boolean", "clock-jump", "too-long", "overlap", "cleanup", "manifest", "duplicate", "extra", "oversize"]
        for damage in damages:
            with self.subTest(damage=damage), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary);documents=root/"Documents";documents.mkdir()
                directory, receipt = measured_receipt(documents);entry=receipt["exports"][0]
                if damage == "legacy":
                    del receipt["schemaVersion"]
                    for e in receipt["exports"]:
                        for k in list(e):
                            if k.startswith("export"):del e[k]
                elif damage == "unknown":receipt["schemaVersion"] = 3
                elif damage == "missing":del entry["exportElapsedMilliseconds"]
                elif damage == "boolean":entry["exportElapsedMilliseconds"] = True
                elif damage == "clock-jump":entry["exportCompletedUnixMilliseconds"] += 1000
                elif damage == "too-long":entry["exportElapsedMilliseconds"] = 180001
                elif damage == "overlap":receipt["exports"][1].update({k:v for k,v in entry.items() if k.startswith("export")})
                elif damage == "cleanup":receipt["photoBaselineRestored"] = False
                elif damage == "manifest":receipt["fixtureManifestSHA256"] = "b"*64
                elif damage == "extra":entry["personalPath"] = "private-sentinel"
                raw=json.dumps(receipt).encode()
                if damage == "duplicate":raw=b'{"schemaVersion":"private-sentinel",'+raw[1:]
                if damage == "oversize":raw += b" "*65536
                path=directory/"receipt.json";path.write_bytes(raw)
                with self.assertRaises(ValueError):
                    export_interval(path, hashlib.sha256(raw).hexdigest(), SHA, entry["file"], entry["sha256"], True, 370/24)

    def test_native_measurements_surround_the_shipping_call_and_preserve_guards(self):
        root = Path(__file__).resolve().parents[2]
        source = (root/"NekoWidget/NekoWidget/App/MainlineMovieAcceptance.swift").read_text(encoding="utf-8")
        block = source.split("for enabled in [true, false]",1)[1].split("catch { failure = error }",1)[0]
        self.assertLess(block.index("let exportStartedUnixMilliseconds"), block.index("shared.export"))
        self.assertLess(block.index("shared.export"), block.index("let exportCompletedUnixMilliseconds"))
        self.assertLess(block.index("let exportCompletedUnixMilliseconds"), block.index("copyItem"))
        self.assertIn("ProcessInfo.processInfo.systemUptime", block)
        self.assertIn('request?.creationDate = dates[index]', source)
        self.assertIn('request?.location = CLLocation(latitude: 12.345, longitude: 67.89)', source)
        self.assertIn('let date = asset.creationDate, let location = asset.location', source)
        self.assertIn('abs(date.timeIntervalSince(dates[index])) < 0.001', source)
        self.assertIn('abs(location.coordinate.latitude - 12.345) < 0.000001', source)
        manifest=json.loads((root/'acceptance/movie/fixed-inputs/fixture.json').read_text())
        self.assertEqual({scene['date'] for scene in manifest['scenes']},SOURCE_DATES)
        self.assertTrue(source.startswith("#if DEBUG && targetEnvironment(simulator)"))


if __name__ == "__main__":
    unittest.main()

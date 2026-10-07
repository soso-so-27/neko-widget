import copy
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
import wave

from inspect_export import audio_metrics, inspect, digest
from test_preparation import probe
from validate_probe import validate
from diagnostic_fixture import MANIFEST_SHA256


class InspectionTests(unittest.TestCase):
    def test_missing_receipt_cannot_pass_when_probe_omits_header_dates(self):
        # Adversarial probe protocol only; no claim of decoding a real export.
        from test_export_timestamps import headers
        p=probe();p["streams"].pop();p["format"]["duration"]="2";p["streams"][0]["nb_frames"]="48"
        def tool(command, **kwargs):
            if "-version" in command:raw=b"synthetic tool protocol\n"
            elif "-show_format" in command:raw=json.dumps(p).encode()
            elif "framemd5" in command:raw=b"synthetic-frame\n"*48
            else:raw=b"\x89PNG\r\n\x1a\nsynthetic-image-protocol"
            return subprocess.CompletedProcess(command,0,stdout=raw)
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);source=root/"exported-off.mp4";source.write_bytes(headers(sound=False))
            with patch("inspect_export.subprocess.run",side_effect=tool):
                report=inspect(source,root/"evidence","synthetic-ffmpeg","synthetic-ffprobe",2,False)
            self.assertEqual(report["technicalCheck"],"failed")
            self.assertEqual(report["errors"],["Measured export receipt unavailable or invalid"])
            self.assertTrue(report["inputUnchanged"])

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "existing ffmpeg/ffprobe required")
    def test_real_toolchain_retains_positive_and_negative_evidence_without_overwrite(self):
        # TOOL self-test with synthetic inputs, not a native export acceptance.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundled = Path(__file__).resolve().parents[2]/"NekoWidget/NekoWidget/Assets.xcassets/SeasonalMovieAmbient.dataset/seasonal-movie-ambient.wav"
            entries = []
            for sound in [True, False]:
                path = root/("exported-on.mp4" if sound else "exported-off.mp4")
                start = time.time_ns()//1000000; monotonic = time.monotonic_ns()
                timestamp = datetime.fromtimestamp(start/1000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                command = ["ffmpeg", "-v", "error", "-nostdin", "-n", "-f", "lavfi", "-i", "color=c=blue:s=720x1280:r=24:d=2"]
                if sound:
                    command += ["-i", str(bundled), "-c:a", "aac", "-af", "volume=0.55,afade=t=in:d=0.25,afade=t=out:st=1:d=1"]
                command += ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-metadata", "creation_time="+timestamp, "-t", "2", str(path)]
                subprocess.run(command, check=True, capture_output=True, timeout=60)
                elapsed = (time.monotonic_ns()-monotonic)//1000000; end = time.time_ns()//1000000
                entries.append({"file":path.name,"soundEnabled":sound,"duration":2,"sha256":digest(path),
                    "exportStartedUnixMilliseconds":start,"exportCompletedUnixMilliseconds":end,"exportElapsedMilliseconds":elapsed})
            receipt = {"schemaVersion":2,"syntheticOnly":True,"shippingExporterInvoked":True,"exportAttempts":2,
                "fixtureManifestSHA256":MANIFEST_SHA256,"buildSourceSHA":"a"*40,"exports":entries,
                "photoBaselineRestored":True,"managedCleanupSucceeded":True,"returnedManagedExportsCleaned":True,
                "remainingNewManagedDirectories":[],"result":"exported; external inspection pending",
                "visualInspection":"not performed","listening":"not performed"}
            native = root/"receipt.json";native.write_text(json.dumps(receipt),encoding="utf-8")
            receipt_hash = digest(native);source = root/"exported-off.mp4";before = digest(source)
            good = inspect(source, root/"good", "ffmpeg", "ffprobe", 2, False,
                           receipt=native,source_sha="a"*40,receipt_sha=receipt_hash)
            self.assertEqual(good["errors"], [], good)
            self.assertEqual(good["timestampEvidence"]["headerAndProbeCheck"], "passed")
            self.assertEqual(good["decodedVideoFrames"],48)
            on = root/"exported-on.mp4"
            audible = inspect(on, root/"audible", "ffmpeg", "ffprobe", 2, True, bundled,
                              receipt=native,source_sha="a"*40,receipt_sha=receipt_hash)
            self.assertEqual(audible["errors"], [], audible)
            self.assertEqual(audible["decodedVideoFrames"],48)
            self.assertEqual(audible["listening"],"not performed")
            bad = inspect(source, root/"bad", "ffmpeg", "ffprobe", 2, False,
                          receipt=native,source_sha="a"*40,receipt_sha="b"*64)
            self.assertEqual(bad["technicalCheck"],"failed")
            self.assertIn("Measured export receipt unavailable or invalid",bad["errors"])
            missing = inspect(source, root/"missing", "ffmpeg", "ffprobe", 2, False)
            self.assertEqual(missing["technicalCheck"],"failed")
            self.assertIn("Measured export receipt unavailable or invalid",missing["errors"])
            wrong_sound = inspect(on, root/"wrong-sound", "ffmpeg", "ffprobe", 2, False,
                                  receipt=native,source_sha="a"*40,receipt_sha=receipt_hash)
            self.assertEqual(wrong_sound["technicalCheck"],"failed")
            self.assertTrue((root/"wrong-sound/inspection.json").is_file())
            report_before=(root/"good/inspection.json").read_bytes()
            with self.assertRaises(FileExistsError):
                inspect(source,root/"good","ffmpeg","ffprobe",2,False,receipt=native,
                        source_sha="a"*40,receipt_sha=receipt_hash)
            self.assertEqual((root/"good/inspection.json").read_bytes(),report_before)
            self.assertEqual(digest(source),before)
            self.assertEqual(digest(native),receipt_hash)

    def test_malformed_probe_rejected_without_exception(self):
        for value in [None, [], {"format": None}, {"streams": [None]}, {"streams": None}]:
            with self.subTest(value=value):
                self.assertTrue(validate(value, 370/24, True))
        for expected in [float("nan"), float("inf"), -1, True, None]:
            self.assertTrue(validate(probe(), expected, True))
        for value in [370.9, True, "370.0", None]:
            invalid = copy.deepcopy(probe()); invalid["streams"][0]["nb_frames"] = value
            self.assertTrue(validate(invalid, 370/24, True))
        for field in ["tags", "side_data_list"]:
            invalid = copy.deepcopy(probe()); invalid["streams"][0][field] = None
            self.assertTrue(validate(invalid, 370/24, True))

    def test_pcm_detects_wrong_bgm_silence_tone_and_fades(self):
        reference = [round(8000*math.sin(2*math.pi*650*i/48000)) for i in range(48000)]
        reference = [sample for sample in reference for _ in range(2)]
        expected = []
        for i in range(4*48000):
            gain = .55*min(1, i/48000/.25, 4-i/48000)
            expected.extend([round(reference[(i*2) % len(reference)]*gain)]*2)
        self.assertEqual(audio_metrics(expected, reference, 4)["errors"], [])
        self.assertTrue(audio_metrics([0]*len(expected), reference, 4)["errors"])
        unfaded = [round(reference[i % len(reference)]*.55) for i in range(len(expected))]
        self.assertTrue(audio_metrics(unfaded, reference, 4)["errors"])
        tone = [round(8000*math.sin(2*math.pi*997*i/48000)) for i in range(4*48000)]
        actual = [sample for sample in tone for _ in range(2)]
        self.assertIn("997Hz source tone detected", audio_metrics(actual, reference, 4)["errors"])

    def test_long_movie_cannot_hide_missing_opening_fade_in_global_average(self):
        duration = 370/24
        reference = [sample for i in range(48000) for sample in
                     [round(8000*math.sin(2*math.pi*650*i/48000))]*2]
        actual = []
        for i in range(round(duration*48000)):
            gain = .55*min(1, duration-i/48000)  # Deliberately no fade-in.
            actual.extend([round(reference[(i*2) % len(reference)]*gain)]*2)
        metrics = audio_metrics(actual, reference, duration)
        self.assertLess(metrics["referenceNormalizedRMSError"], .15)
        self.assertIn("fadeIn waveform differs from specified BGM envelope", metrics["errors"])



if __name__ == "__main__":
    unittest.main()

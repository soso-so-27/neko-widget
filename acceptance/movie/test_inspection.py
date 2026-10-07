import copy
import math
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import wave

from inspect_export import audio_metrics, inspect, digest
from test_preparation import probe
from validate_probe import validate


class InspectionTests(unittest.TestCase):
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

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "existing ffmpeg/ffprobe required")
    def test_real_toolchain_retains_positive_and_negative_evidence_without_overwrite(self):
        # Synthetic TOOL self-test only. These MP4s never represent app output.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            reference = root/"reference.wav"
            bundled = Path(__file__).resolve().parents[2]/"NekoWidget/NekoWidget/Assets.xcassets/SeasonalMovieAmbient.dataset/seasonal-movie-ambient.wav"
            shutil.copyfile(bundled, reference)
            source = root/"tool-test.mp4"
            subprocess.run(["ffmpeg", "-v", "error", "-nostdin", "-n", "-f", "lavfi", "-i",
                            "color=c=blue:s=720x1280:r=24:d=2", "-i", str(reference),
                            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac",
                            "-af", "volume=0.55,afade=t=in:d=0.25,afade=t=out:st=1:d=1", "-t", "2", str(source)],
                           check=True, capture_output=True, timeout=60)
            before = digest(source)
            good = inspect(source, root/"good", "ffmpeg", "ffprobe", 2, True, reference)
            self.assertEqual(good["errors"], [], good)
            self.assertEqual(good["decodedVideoFrames"], 48)
            self.assertEqual(good["listening"], "not performed")
            bad = inspect(source, root/"bad", "ffmpeg", "ffprobe", 2, False)
            self.assertEqual(bad["technicalCheck"], "failed")
            self.assertTrue((root/"bad/inspection.json").is_file())
            report_before = (root/"good/inspection.json").read_bytes()
            with self.assertRaises(FileExistsError):
                inspect(source, root/"good", "ffmpeg", "ffprobe", 2, True, reference)
            self.assertEqual((root/"good/inspection.json").read_bytes(), report_before)
            self.assertEqual(digest(source), before)


if __name__ == "__main__":
    unittest.main()

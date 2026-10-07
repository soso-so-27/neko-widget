import copy
import math
from pathlib import Path
import tempfile
import unittest
import wave
from generate_fixture import generate
from validate_probe import validate
from verify_source_video import tone_fraction


def probe():
    return {"format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2", "duration": "15.416667", "tags": {"major_brand": "isom"}}, "streams": [
        {"codec_type": "video", "codec_name": "h264", "width": 720, "height": 1280, "avg_frame_rate": "24/1", "r_frame_rate": "24/1", "nb_frames": "370"},
        {"codec_type": "audio", "codec_name": "aac", "sample_rate": "48000", "channels": 2}]}


class PreparationTests(unittest.TestCase):
    def test_native_entry_pins_synthetic_inputs_and_cleanup_ownership(self):
        root = Path(__file__).resolve().parents[2]
        source = (root/"NekoWidget/NekoWidget/App/MainlineMovieAcceptance.swift").read_text(encoding="utf-8")
        for boundary in ['#if DEBUG && targetEnvironment(simulator)',
                         'PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized',
                         'NEKO_MOVIE_SYNTHETIC_FIXTURE_DIR',
                         'manifestHash == "643f16febdb4088c28a1aea1d6d25032be324296dd3f2955d0f94ce93f100e82"',
                         'for enabled in [true, false]', 'SeasonalMovieExportService.shared.export(presentation, soundEnabled: enabled)',
                         'Set(created.values).subtracting(baseline)', 'identifiers() == baseline',
                         'exports.allSatisfy', 'exportAttempts > 0']:
            self.assertIn(boundary, source)
        self.assertNotIn('requestAuthorization', source)
        cleanup = (root/"NekoWidget/NekoWidget/Services/SeasonalMovieExportService.swift").read_text(encoding="utf-8")
        self.assertIn('isOwnedExportDirectory(directory, root: root)', cleanup)
        self.assertIn('isOwnedExportDirectory(candidate, root: root)', cleanup)
        self.assertIn('values.isSymbolicLink == false', cleanup)

    def test_synthetic_inputs_are_reproducible_and_refuse_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            first = generate(Path(temporary)/"first")
            second = generate(Path(temporary)/"second")
            self.assertEqual(first, second)
            self.assertEqual(first["expectedFrameCount"], 370)
            self.assertFalse(first["productionExportExecuted"])
            self.assertEqual(len(list((Path(temporary)/"first/motion").glob("*.png"))), 72)
            with wave.open(str(Path(temporary)/"first/source-audio-997hz.wav")) as audio:
                self.assertEqual((audio.getframerate(), audio.getnchannels(), audio.getnframes()), (48000, 1, 144000))
            with self.assertRaises(FileExistsError):
                generate(Path(temporary)/"first")

    def test_source_tone_measurement_rejects_silence_and_another_tone(self):
        samples = [16000*math.sin(2*math.pi*997*i/48000) for i in range(48000)]
        self.assertGreater(tone_fraction(samples), .999)
        self.assertEqual(tone_fraction([0]*48000), 0)
        other = [16000*math.sin(2*math.pi*650*i/48000) for i in range(48000)]
        self.assertLess(tone_fraction(other), .001)

    def test_on_and_off_are_distinct(self):
        self.assertEqual(validate(probe(), 370/24, True), [])
        self.assertTrue(validate(probe(), 370/24, False))
        muted = probe(); muted["streams"].pop()
        self.assertEqual(validate(muted, 370/24, False), [])
        self.assertTrue(validate(muted, 370/24, True))

    def test_invalid_outputs_rejected(self):
        mutations = [
            lambda p: p["format"].update(format_name="matroska"),
            lambda p: p["streams"][0].update(nb_frames="369"),
            lambda p: p["streams"][0].update(r_frame_rate="30/1"),
            lambda p: p["streams"][0].update(width=1280),
            lambda p: p["streams"][0].update(codec_name="hevc"),
            lambda p: p["streams"][0].update(avg_frame_rate="30/1"),
            lambda p: p["streams"][0].update(avg_frame_rate="0/0"),
            lambda p: p["streams"][1].update(sample_rate="44100"),
            lambda p: p["streams"][1].update(channels=1),
            lambda p: p["streams"].append({"codec_type": "data"}),
            lambda p: p["format"].update(duration="nan"),
            lambda p: p["format"].update(duration="14"),
            lambda p: p["format"].update(tags={"location": "+35+139/"}),
            lambda p: p["format"].update(tags={"creation_time": "2025-01-02"}),
            lambda p: p["format"].update(tags={"encoder": "SYNTHETIC_SOURCE_DO_NOT_EXPORT"}),
            lambda p: p["streams"][0].update(side_data_list=[{"side_data_type": "Display Matrix", "rotation": 90}]),
        ]
        for mutation in mutations:
            value = copy.deepcopy(probe()); mutation(value)
            with self.subTest(mutation=mutations.index(mutation)):
                self.assertTrue(validate(value, 370/24, True))


if __name__ == "__main__":
    unittest.main()

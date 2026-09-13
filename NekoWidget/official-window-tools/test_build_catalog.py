from datetime import datetime, timedelta, timezone
import hashlib
from io import StringIO
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from unittest.mock import patch

from PIL import Image, ImageCms
from PIL.PngImagePlugin import PngInfo

import build_catalog as catalog


NOW = datetime(2026, 9, 10, 12, 0, 0, tzinfo=timezone.utc)


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="official-window-test-")
        self.root = Path(self.temporary.name)
        self.images = self.root / "images"
        self.images.mkdir()
        self.output = self.root / "output"
        Image.new("RGB", (24, 12), (210, 30, 70)).save(self.images / "sample.png")

    def tearDown(self):
        self.temporary.cleanup()

    def photo(self, identifier="photo-one", **changes):
        value = {
            "id": identifier, "catID": "test-cat", "catName": "ねこ",
            "credit": "提供者の公開名", "caption": "一行目\n二行目\n三行目",
            "photographedOn": "2026-09-01",
            "publishedAt": catalog.utc_string(NOW - timedelta(hours=1)),
            "expiresAt": catalog.utc_string(NOW + timedelta(days=7)),
            "sourceFilename": "sample.png", "publicationApproved": True,
            "internal": {"operator": "PRIVATE-OPERATOR", "permissionRecord": "PRIVATE-RECORD"},
        }
        value.update(changes)
        return value

    def build(self, photos=None, **options):
        return catalog.build_catalog(
            self.output, document={"photos": photos if photos is not None else [self.photo()]},
            images_dir=self.images, now=NOW, **options,
        )

    def assert_rejected(self, photos, message=None):
        with self.assertRaises(catalog.CatalogError) as caught:
            self.build(photos)
        if message:
            self.assertIn(message, str(caught.exception))
        self.assertFalse(self.output.exists(), "invalid input created output")

    def test_public_schema_hash_and_no_internal_fields(self):
        result = self.build()
        self.assertEqual(set(result), {
            "schemaVersion", "channelID", "enabled", "generatedAt", "validUntil", "photos",
        })
        self.assertEqual(result["schemaVersion"], 1)
        self.assertEqual(result["channelID"], "official-cats")
        self.assertIs(result["enabled"], True)
        self.assertEqual(result["generatedAt"], "2026-09-10T12:00:00Z")
        self.assertEqual(result["validUntil"], "2026-09-12T12:00:00Z")
        photo = result["photos"][0]
        self.assertEqual(set(photo), {
            "id", "catID", "catName", "credit", "caption", "photographedOn",
            "publishedAt", "expiresAt", "imageFilename", "sha256", "width", "height",
        })
        data = (self.output / photo["imageFilename"]).read_bytes()
        self.assertEqual(photo["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(photo["imageFilename"], photo["sha256"] + ".jpg")
        payload = (self.output / "catalog.json").read_text(encoding="utf-8")
        self.assertEqual(json.loads(payload), result)
        for secret in ("publicationApproved", "sourceFilename", "sample.png", "PRIVATE-", "internal"):
            self.assertNotIn(secret, payload)
        self.assertEqual(sorted(path.name for path in self.output.iterdir()),
                         sorted(["catalog.json", photo["imageFilename"]]))

    def test_channel_changes_only_catalog_identity_and_keeps_photo_bytes(self):
        legacy = self.build()
        other_output = self.root / "other"
        other = catalog.build_catalog(
            other_output, document={"photos": [self.photo()]}, images_dir=self.images,
            now=NOW, channel_id="test-window-a",
        )
        self.assertEqual(other, {**legacy, "channelID": "test-window-a"})
        filename = legacy["photos"][0]["imageFilename"]
        self.assertEqual((self.output / filename).read_bytes(), (other_output / filename).read_bytes())
        self.assertNotIn("PRIVATE-", (other_output / "catalog.json").read_text(encoding="utf-8"))

    def test_invalid_channel_is_rejected_before_output_for_active_and_paused(self):
        for channel in ("", "a" * 65, "UPPER", "../cats", "a/b", "a\\b", "a%2fb", "a\n", None, 1):
            for paused in (False, True):
                with self.subTest(channel=channel, paused=paused), self.assertRaises(catalog.CatalogError):
                    if paused:
                        catalog.build_catalog(self.output, paused=True, channel_id=channel, now=NOW)
                    else:
                        self.build(channel_id=channel)
                self.assertFalse(self.output.exists())

    def test_additional_channel_still_requires_approval(self):
        with self.assertRaisesRegex(catalog.CatalogError, "publicationApproved"):
            self.build([self.photo(publicationApproved=False)], channel_id="test-window-a")
        self.assertFalse(self.output.exists())

    def test_exif_orientation_resize_and_source_metadata_removed(self):
        source = Image.new("RGB", (3000, 1000), "red")
        source.paste("blue", (1500, 0, 3000, 1000))
        exif = Image.Exif()
        exif[274] = 6  # rotate clockwise: red top, blue bottom
        exif[270] = "PRIVATE-EXIF-DESCRIPTION"
        exif[315] = "PRIVATE-PHOTOGRAPHER"
        exif[34853] = {1: "N", 2: (35.0, 0.0, 0.0), 3: "E", 4: (139.0, 0.0, 0.0)}
        source.save(
            self.images / "oriented.jpg", exif=exif,
            icc_profile=ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes(),
            comment=b"PRIVATE-JPEG-COMMENT",
        )
        original_bytes = (self.images / "oriented.jpg").read_bytes()
        photo = self.build([self.photo(sourceFilename="oriented.jpg")])["photos"][0]
        image_path = self.output / photo["imageFilename"]
        with Image.open(image_path) as image:
            self.assertEqual(image.format, "JPEG")
            self.assertEqual(image.size, (683, 2048))
            self.assertEqual(image.size, (photo["width"], photo["height"]))
            self.assertEqual(dict(image.getexif()), {})
            self.assertNotIn("icc_profile", image.info)
            self.assertNotIn("comment", image.info)
            top = image.getpixel((image.width // 2, image.height // 4))
            bottom = image.getpixel((image.width // 2, 3 * image.height // 4))
            self.assertGreater(top[0] - top[2], 150)
            self.assertGreater(bottom[2] - bottom[0], 150)
        data = image_path.read_bytes()
        for marker in (b"PRIVATE-", b"Exif\x00\x00", b"ICC_PROFILE", b"http://ns.adobe.com"):
            self.assertNotIn(marker, data)
        self.assertEqual((self.images / "oriented.jpg").read_bytes(), original_bytes)

    def test_png_text_transparency_and_no_upscaling(self):
        source = Image.new("RGBA", (20, 10), (0, 0, 0, 0))
        metadata = PngInfo()
        metadata.add_text("Description", "PRIVATE-PNG-TEXT")
        metadata.add_text("XML:com.adobe.xmp", "PRIVATE-XMP")
        source.save(self.images / "transparent.png", pnginfo=metadata)
        photo = self.build([self.photo(sourceFilename="transparent.png")])["photos"][0]
        data = (self.output / photo["imageFilename"]).read_bytes()
        self.assertNotIn(b"PRIVATE-", data)
        with Image.open(self.output / photo["imageFilename"]) as image:
            self.assertEqual(image.size, (20, 10))
            self.assertEqual(image.mode, "RGB")
            self.assertTrue(all(channel >= 250 for channel in image.getpixel((10, 5))))

    def test_approval_must_be_explicit_boolean_for_all_rows(self):
        for value in (False, None, 1, "true"):
            for timing in ({}, {"publishedAt": catalog.utc_string(NOW + timedelta(days=1))}):
                with self.subTest(value=value, timing=timing):
                    self.assert_rejected([self.photo(publicationApproved=value, **timing)], "publicationApproved")
        missing = self.photo()
        del missing["publicationApproved"]
        self.assert_rejected([missing])

    def test_duplicate_ids_rejected_even_when_future(self):
        self.assert_rejected([
            self.photo(), self.photo(publishedAt=catalog.utc_string(NOW + timedelta(days=1))),
        ], "duplicate")

    def test_photo_lifetime_boundaries(self):
        for lifetime in (timedelta(0), timedelta(seconds=-1), timedelta(days=14, seconds=1)):
            with self.subTest(lifetime=lifetime):
                self.assert_rejected([self.photo(
                    publishedAt=catalog.utc_string(NOW), expiresAt=catalog.utc_string(NOW + lifetime),
                )], "lifetime")
        result = self.build([self.photo(
            publishedAt=catalog.utc_string(NOW), expiresAt=catalog.utc_string(NOW + timedelta(days=14)),
        )])
        self.assertEqual(len(result["photos"]), 1)

    def test_future_expired_filter_and_newest_first(self):
        rows = [
            self.photo("old", publishedAt=catalog.utc_string(NOW - timedelta(days=2))),
            self.photo("future", publishedAt=catalog.utc_string(NOW + timedelta(seconds=1))),
            self.photo("expired", expiresAt=catalog.utc_string(NOW)),
            self.photo("new", publishedAt=catalog.utc_string(NOW)),
        ]
        result = self.build(rows)
        self.assertEqual([row["id"] for row in result["photos"]], ["new", "old"])
        # Identical pixels deduplicate the physical JPEG without aliasing IDs.
        self.assertEqual(len(list(self.output.glob("*.jpg"))), 1)

    def test_empty_enabled_catalog_does_not_copy_excluded_images(self):
        result = self.build([self.photo(publishedAt=catalog.utc_string(NOW + timedelta(days=1)))])
        self.assertIs(result["enabled"], True)
        self.assertEqual(result["photos"], [])
        self.assertEqual([path.name for path in self.output.iterdir()], ["catalog.json"])

    def test_empty_input_is_allowed(self):
        self.assertEqual(self.build([])["photos"], [])

    def test_catalog_validity_bounds(self):
        for hours in (0, 49, True, 1.5):
            with self.subTest(hours=hours):
                with self.assertRaises(catalog.CatalogError):
                    self.build(valid_for_hours=hours)
                self.assertFalse(self.output.exists())
        result = self.build(valid_for_hours=1)
        self.assertEqual(result["validUntil"], "2026-09-10T13:00:00Z")

    def test_invalid_timestamps_and_calendar_date(self):
        for value in ("2026-09-10T12:00:00+00:00", "2026-09-10T12:00:00.0Z",
                      "2026-02-30T12:00:00Z", "2026-09-10T12:00:60Z", None):
            with self.subTest(value=value):
                self.assert_rejected([self.photo(publishedAt=value)])
        for value in ("2026-02-30", "2026-9-01", "2026-09-01T00:00:00Z", None):
            with self.subTest(date=value):
                self.assert_rejected([self.photo(photographedOn=value)])

    def test_text_slug_and_field_boundaries(self):
        for change in (
            {"id": "Bad"}, {"catID": "../cat"}, {"id": "a" * 65},
            {"catName": ""}, {"catName": "あ" * 31}, {"credit": "x" * 81},
            {"caption": "x" * 101}, {"caption": "a\nb\nc\nd"},
            {"credit": "a\nb"}, {"caption": "x\x00"}, {"credit": "   "},
            {"sourceFileName": "typo.png"},
        ):
            with self.subTest(change=change):
                self.assert_rejected([self.photo(**change)])
        result = self.build([self.photo(
            identifier="a" * 64, catName="あ" * 30, credit="x" * 80, caption="x" * 100,
        )])
        self.assertEqual(len(result["photos"][0]["caption"]), 100)

    def test_optional_fields_are_not_synthesized(self):
        row = self.photo()
        del row["caption"], row["photographedOn"]
        output = self.build([row])["photos"][0]
        self.assertNotIn("caption", output)
        self.assertNotIn("photographedOn", output)

    def test_blank_captions_are_omitted_and_nonblank_captions_are_trimmed(self):
        rows = [self.photo(f"blank-{number}", caption=value)
                for number, value in enumerate(("", " ", "\n \t\r\n", "\u3000"))]
        rows.append(self.photo("trimmed", caption=" \n一行目\n二行目 \n"))
        result = self.build(rows)
        for row in result["photos"]:
            if row["id"] == "trimmed":
                self.assertEqual(row["caption"], "一行目\n二行目")
            else:
                self.assertNotIn("caption", row)

    def test_encoded_jpeg_byte_limit_is_checked_before_output(self):
        data, _, _ = catalog.jpeg_bytes(self.images / "sample.png")
        self.assertLessEqual(len(data), 4 * 1024 * 1024)
        # Exercise both sides with real encoded bytes, without allocating a
        # huge fixture or relying on quality settings to imply a byte bound.
        with patch.object(catalog, "MAX_JPEG_BYTES", len(data) - 1):
            self.assert_rejected([self.photo()], "client download limit")
        with patch.object(catalog, "MAX_JPEG_BYTES", len(data)):
            result = self.build()
        self.assertEqual((self.output / result["photos"][0]["imageFilename"]).read_bytes(), data)

    def test_item_limit(self):
        rows = [self.photo(f"photo-{number}") for number in range(61)]
        self.assert_rejected(rows, "60")
        self.assertEqual(len(self.build(rows[:60])["photos"]), 60)

    def test_path_traversal_absolute_network_and_ads_rejected(self):
        for value in ("../outside.png", "/sample.png", "C:/sample.png", "a/../sample.png",
                      "a//sample.png", "https://example.com/a.jpg", "sample.png:secret",
                      "\\\\server\\sample.png", "./sample.png", "missing.png", "."):
            with self.subTest(value=value):
                self.assert_rejected([self.photo(sourceFilename=value)])

    def test_symlink_outside_image_root_is_rejected(self):
        outside = self.root / "outside.png"
        Image.new("RGB", (4, 4), "blue").save(outside)
        try:
            (self.images / "escape.png").symlink_to(outside)
        except OSError:
            self.skipTest("this Windows account cannot create symlinks")
        self.assert_rejected([self.photo(sourceFilename="escape.png")], "escapes")

    def test_nested_image_inside_root_is_supported(self):
        nested = self.images / "approved"
        nested.mkdir()
        (nested / "cat.png").write_bytes((self.images / "sample.png").read_bytes())
        self.assertEqual(len(self.build([self.photo(sourceFilename="approved/cat.png")])["photos"]), 1)

    def test_invalid_image_does_not_leave_partial_output(self):
        (self.images / "broken.jpg").write_bytes(b"PRIVATE-NOT-AN-IMAGE")
        self.assert_rejected([self.photo(), self.photo("broken", sourceFilename="broken.jpg")])

    def test_animated_input_is_rejected(self):
        first = Image.new("RGB", (8, 8), "red")
        second = Image.new("RGB", (8, 8), "blue")
        first.save(self.images / "animated.gif", save_all=True, append_images=[second])
        self.assert_rejected([self.photo(sourceFilename="animated.gif")], "animated")

    def test_existing_output_file_and_directory_are_not_overwritten(self):
        self.output.write_text("DO-NOT-CHANGE", encoding="utf-8")
        with self.assertRaises(catalog.CatalogError):
            self.build()
        self.assertEqual(self.output.read_text(encoding="utf-8"), "DO-NOT-CHANGE")
        self.output.unlink()
        self.output.mkdir()
        with self.assertRaises(catalog.CatalogError):
            self.build()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_paused_is_independent_and_does_not_delete_old_jpegs(self):
        active = self.build()
        active_data = {path.name: path.read_bytes() for path in self.output.iterdir()}
        stopped = self.root / "paused"
        result = catalog.build_catalog(stopped, paused=True, now=NOW)
        self.assertIs(result["enabled"], False)
        self.assertEqual(result["photos"], [])
        self.assertEqual([path.name for path in stopped.iterdir()], ["catalog.json"])
        self.assertEqual({path.name: path.read_bytes() for path in self.output.iterdir()}, active_data)
        self.assertEqual(len(active["photos"]), 1)

    def test_paused_rejects_photo_inputs(self):
        with self.assertRaises(catalog.CatalogError):
            self.build(paused=True)
        self.assertFalse(self.output.exists())

    def test_json_duplicate_keys_and_parse_failure(self):
        source = self.root / "source.json"
        for payload in ('{"photos":[],"photos":[]}', '{"photos":'):
            source.write_text(payload, encoding="utf-8")
            with self.subTest(payload=payload), self.assertRaises(catalog.CatalogError):
                catalog.read_source(source)

    def test_cli_paused_catalog(self):
        completed = subprocess.run(
            [sys.executable, str(Path(catalog.__file__)), "--paused", "--output", str(self.output)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads((self.output / "catalog.json").read_text(encoding="utf-8"))
        self.assertIs(result["enabled"], False)
        generated = catalog.parse_utc(result["generatedAt"], "generatedAt")
        self.assertEqual(catalog.parse_utc(result["validUntil"], "validUntil") - generated,
                         timedelta(hours=48))

    def test_cli_channel_stop_does_not_change_another_channel(self):
        active = self.build(channel_id="test-window-b")
        original = {path.name: path.read_bytes() for path in self.output.iterdir()}
        stopped = self.root / "paused-a"
        completed = subprocess.run(
            [sys.executable, str(Path(catalog.__file__)), "--paused", "--channel-id", "test-window-a",
             "--output", str(stopped)], capture_output=True, text=True, check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads((stopped / "catalog.json").read_text(encoding="utf-8"))
        self.assertEqual(result["channelID"], "test-window-a")
        self.assertIs(result["enabled"], False)
        self.assertEqual(result["photos"], [])
        self.assertEqual({path.name: path.read_bytes() for path in self.output.iterdir()}, original)
        self.assertEqual(len(active["photos"]), 1)

    def test_cli_errors_do_not_expose_internal_input(self):
        source = self.root / "source.json"
        source.write_text(json.dumps({"photos": [self.photo(publicationApproved=False)]}), encoding="utf-8")
        stderr = StringIO()
        with redirect_stderr(stderr):
            code = catalog.main(["--input", str(source), "--images-dir", str(self.images),
                                 "--output", str(self.output)])
        self.assertEqual(code, 1)
        self.assertNotIn("PRIVATE", stderr.getvalue())
        self.assertNotIn(str(source), stderr.getvalue())
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()

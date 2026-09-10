#!/usr/bin/env python3
"""Build an approved, metadata-free official-cats catalog locally; never publish it."""

from __future__ import annotations

import argparse
from datetime import date, datetime, timedelta, timezone
import hashlib
from io import BytesIO
import json
from pathlib import Path, PurePosixPath
import re
import sys
import warnings

from PIL import Image, ImageCms, ImageOps


MAX_PHOTOS = 60
MAX_DIMENSION = 2048
MAX_JPEG_BYTES = 4 * 1024 * 1024
UTC_SECONDS = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
SLUG = re.compile(r"[a-z0-9-]{1,64}")
REQUIRED = {
    "id", "catID", "catName", "credit", "publishedAt", "expiresAt",
    "sourceFilename", "publicationApproved",
}
OPTIONAL = {"caption", "photographedOn", "internal"}


class CatalogError(ValueError):
    """An invalid source or unsafe local operation; no publication is attempted."""


def utc_string(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_utc(value: object, label: str) -> datetime:
    if not isinstance(value, str) or UTC_SECONDS.fullmatch(value) is None:
        raise CatalogError(f"{label} must be UTC seconds in YYYY-MM-DDTHH:MM:SSZ format")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise CatalogError(f"{label} is not a valid date/time") from error


def checked_text(value: object, label: str, maximum: int, *, caption: bool = False) -> str:
    minimum = 0 if caption else 1
    if not isinstance(value, str) or not minimum <= len(value) <= maximum:
        raise CatalogError(f"{label} must contain {minimum}..{maximum} characters")
    if not caption and (value != value.strip() or not value.strip()):
        raise CatalogError(f"{label} must not be blank or have surrounding whitespace")
    if any((ord(char) < 32 and not (caption and char == "\n"))
           or 127 <= ord(char) <= 159 or 0xD800 <= ord(char) <= 0xDFFF
           or char in "\u2028\u2029" for char in value):
        raise CatalogError(f"{label} contains unsupported control characters")
    if caption and value.count("\n") > 2:
        raise CatalogError("caption must contain at most two newline characters")
    return value


def local_path(path: Path) -> Path:
    # No URL fetches, UNC shares, or Windows mapped network drives.
    if str(path).startswith(("\\\\", "//")):
        raise CatalogError("network paths are not supported")
    resolved = path.resolve(strict=True)
    if str(resolved).startswith(("\\\\", "//")):
        raise CatalogError("network paths are not supported")
    if sys.platform == "win32":
        import ctypes
        if ctypes.windll.kernel32.GetDriveTypeW(str(resolved.anchor)) == 4:
            raise CatalogError("network drives are not supported")
    return resolved


def source_image(root: Path, value: object) -> Path:
    if not isinstance(value, str) or not value or "\\" in value or ":" in value:
        raise CatalogError("sourceFilename must be a local relative path using / separators")
    parts = value.split("/")
    if PurePosixPath(value).is_absolute() or any(part in {"", ".", ".."} for part in parts):
        raise CatalogError("sourceFilename must stay inside the image directory")
    try:
        candidate = local_path(root.joinpath(*parts))
        candidate.relative_to(root)
    except (OSError, ValueError) as error:
        raise CatalogError("sourceFilename is missing or escapes the image directory") from error
    if not candidate.is_file():
        raise CatalogError("sourceFilename must refer to a regular file")
    return candidate


def read_source(path: Path) -> dict:
    def unique_object(pairs: list[tuple[str, object]]) -> dict:
        result = {}
        for key, value in pairs:
            if key in result:
                raise CatalogError("input JSON contains a duplicate object key")
            result[key] = value
        return result

    try:
        with local_path(path).open("r", encoding="utf-8") as handle:
            return json.load(handle, object_pairs_hook=unique_object)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CatalogError("could not read the local UTF-8 input JSON") from error


def validated_photos(document: object, root: Path) -> list[tuple[dict, Path, datetime, datetime]]:
    if not isinstance(document, dict) or set(document) != {"photos"}:
        raise CatalogError("input JSON must contain only a photos array")
    photos = document["photos"]
    if not isinstance(photos, list) or len(photos) > MAX_PHOTOS:
        raise CatalogError("input photos must be an array of at most 60 items")
    seen = set()
    checked = []
    for item in photos:
        if not isinstance(item, dict) or not REQUIRED <= set(item) or set(item) - REQUIRED - OPTIONAL:
            raise CatalogError("a photo has missing or unknown fields")
        # Deliberately validate even future/expired rows before filtering.
        if item["publicationApproved"] is not True:
            raise CatalogError("every input photo requires publicationApproved: true")
        for key in ("id", "catID"):
            if not isinstance(item[key], str) or SLUG.fullmatch(item[key]) is None:
                raise CatalogError(f"{key} must be a 1..64 character lowercase slug")
        if item["id"] in seen:
            raise CatalogError("duplicate photo id")
        seen.add(item["id"])
        published = parse_utc(item["publishedAt"], "publishedAt")
        expires = parse_utc(item["expiresAt"], "expiresAt")
        if not timedelta(0) < expires - published <= timedelta(days=14):
            raise CatalogError("photo lifetime must be positive and at most 14 days")
        public = {
            "id": item["id"],
            "catID": item["catID"],
            "catName": checked_text(item["catName"], "catName", 30),
            "credit": checked_text(item["credit"], "credit", 80),
            "publishedAt": item["publishedAt"],
            "expiresAt": item["expiresAt"],
        }
        if "caption" in item:
            caption = item["caption"]
            if not isinstance(caption, str):
                raise CatalogError("caption must be a string when present")
            caption = caption.strip()
            if caption:
                public["caption"] = checked_text(caption, "caption", 100, caption=True)
        if "photographedOn" in item:
            value = item["photographedOn"]
            try:
                if not isinstance(value, str) or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value) is None:
                    raise ValueError
                date.fromisoformat(value)
            except ValueError as error:
                raise CatalogError("photographedOn must be a valid YYYY-MM-DD date") from error
            public["photographedOn"] = value
        checked.append((public, source_image(root, item["sourceFilename"]), published, expires))
    return checked


def jpeg_bytes(path: Path) -> tuple[bytes, int, int]:
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(path) as original:
                if getattr(original, "n_frames", 1) != 1:
                    raise CatalogError("animated/multipage sources are not supported")
                original.load()
                oriented = ImageOps.exif_transpose(original)
                icc = oriented.info.get("icc_profile")
                alpha = oriented.convert("RGBA").getchannel("A") if (
                    "A" in oriented.getbands() or "transparency" in oriented.info
                ) else None
                colors = oriented if oriented.mode in {"RGB", "CMYK"} else oriented.convert("RGB")
                if icc:
                    colors = ImageCms.profileToProfile(
                        colors, ImageCms.ImageCmsProfile(BytesIO(icc)),
                        ImageCms.createProfile("sRGB"), outputMode="RGB",
                    )
                else:
                    colors = colors.convert("RGB")
                if alpha is not None:
                    background = Image.new("RGB", colors.size, "white")
                    background.paste(colors, mask=alpha)
                    colors = background
                colors.thumbnail((MAX_DIMENSION, MAX_DIMENSION), Image.Resampling.LANCZOS)
                # A fresh pixel canvas severs EXIF, GPS, comments, ICC, XMP and
                # format-specific source metadata. Color conversion above uses
                # the embedded profile before discarding it.
                clean = Image.new("RGB", colors.size)
                clean.paste(colors)
                encoded = BytesIO()
                clean.save(encoded, format="JPEG", quality=88, optimize=True)
                data = encoded.getvalue()
                if len(data) > MAX_JPEG_BYTES:
                    raise CatalogError("encoded JPEG exceeds the 4 MiB client download limit")
                return data, clean.width, clean.height
    except CatalogError:
        raise
    except (OSError, ValueError, SyntaxError, Image.DecompressionBombError,
            Image.DecompressionBombWarning, ImageCms.PyCMSError) as error:
        raise CatalogError("source image could not be safely decoded/re-encoded") from error


def build_catalog(
    output: Path, *, document: object = None, images_dir: Path | None = None,
    paused: bool = False, valid_for_hours: int = 48, now: datetime | None = None,
) -> dict:
    if type(valid_for_hours) is not int or not 1 <= valid_for_hours <= 48:
        raise CatalogError("valid_for_hours must be an integer from 1 to 48")
    clock = now if now is not None else datetime.now(timezone.utc)
    if clock.tzinfo is None or clock.utcoffset() is None:
        raise CatalogError("generation time must include a timezone")
    clock = clock.astimezone(timezone.utc).replace(microsecond=0)
    if output.exists() or output.is_symlink():
        raise CatalogError("output already exists; choose a new directory")
    # Only the explicitly requested final directory is created. Its parent
    # must already exist; resolve it before appending the new directory name.
    parent = local_path(output.parent)
    if not parent.is_dir() or output.name in {"", ".", ".."}:
        raise CatalogError("output requires an existing local parent directory")
    destination = parent / output.name
    binaries = {}
    public_photos = []
    if paused:
        if document is not None or images_dir is not None:
            raise CatalogError("paused catalogs do not accept photo inputs")
    else:
        if images_dir is None:
            raise CatalogError("images_dir is required for an enabled catalog")
        root = local_path(images_dir)
        if not root.is_dir():
            raise CatalogError("images_dir must be a local directory")
        entries = validated_photos(document, root)
        entries.sort(key=lambda entry: entry[0]["id"])
        entries.sort(key=lambda entry: entry[2], reverse=True)
        for public, path, published, expires in entries:
            if not published <= clock < expires:
                continue
            data, width, height = jpeg_bytes(path)
            digest = hashlib.sha256(data).hexdigest()
            filename = f"{digest}.jpg"
            binaries[filename] = data
            public_photos.append({
                **public, "imageFilename": filename, "sha256": digest,
                "width": width, "height": height,
            })
    catalog = {
        "schemaVersion": 1, "channelID": "official-cats", "enabled": not paused,
        "generatedAt": utc_string(clock),
        "validUntil": utc_string(clock + timedelta(hours=valid_for_hours)),
        "photos": public_photos,
    }
    payload = (json.dumps(catalog, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    # All validation/encoding has succeeded before touching the destination.
    # mkdir and exclusive file creation also reject concurrent existing output.
    destination.mkdir(exist_ok=False)
    for filename, data in binaries.items():
        with (destination / filename).open("xb") as handle:
            handle.write(data)
    # Write the catalog last. Disk/I/O failures can leave a new incomplete
    # directory, which must never be published or reused as a successful build.
    with (destination / "catalog.json").open("xb") as handle:
        handle.write(payload)
    return catalog


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, help="local UTF-8 source JSON")
    parser.add_argument("--images-dir", type=Path, help="approved local image root")
    parser.add_argument("--output", type=Path, required=True, help="new local directory")
    parser.add_argument("--paused", action="store_true", help="build a disabled empty catalog")
    parser.add_argument("--valid-for-hours", type=int, default=48, help="catalog validity: 1..48 hours")
    args = parser.parse_args(argv)
    if args.paused and (args.input is not None or args.images_dir is not None):
        parser.error("--paused cannot be combined with --input or --images-dir")
    if not args.paused and (args.input is None or args.images_dir is None):
        parser.error("enabled catalogs require --input and --images-dir")
    try:
        catalog = build_catalog(
            args.output, document=read_source(args.input) if args.input else None,
            images_dir=args.images_dir, paused=args.paused,
            valid_for_hours=args.valid_for_hours,
        )
    except (CatalogError, OSError) as error:
        # Do not echo source paths, internal approval notes, or image metadata.
        message = str(error) if isinstance(error, CatalogError) else "local filesystem operation failed"
        print(f"Catalog generation failed: {message}", file=sys.stderr)
        return 1
    print(f"Created local catalog: enabled={catalog['enabled']}, photos={len(catalog['photos'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

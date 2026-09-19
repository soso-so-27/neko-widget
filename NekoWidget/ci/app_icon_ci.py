"""Narrow, binary-aware selection for the two existing app icon images."""

import struct
import re
import zlib

ICON_SCOPE = "app-icon-v1"
ICON_PATHS = frozenset({
    "NekoWidget/NekoWidget/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
    "NekoWidget/NekoWidget/Assets.xcassets/OnboardingAppIcon.imageset/OnboardingAppIcon.png",
})
ICON_DOC_PATHS = frozenset({
    "NekoWidget/docs/design/AppIcon-window-cat-master.png",
    "NekoWidget/docs/design/AppIcon-window-cat.md",
})

# Only these exact additive workflow steps are selection-only. Existing build,
# privacy, signing and runtime commands must remain byte-for-byte equivalent.
ICON_WORKFLOW_STEPS = """      - name: Verify packaged icons and capture first launch
        if: needs.plan.outputs.runtime_scope == 'app-icon-v1' || needs.plan.outputs.runtime_scope == 'ci-selection-v1'
        run: python3 NekoWidget/ci/verify-app-icon.py --app "$RUNNER_TEMP/DerivedData/Build/Products/Release-iphonesimulator/NekoWidget.app" --artifacts "$RUNNER_TEMP/app-icon-check"

      - name: Upload icon display evidence
        if: always() && (needs.plan.outputs.runtime_scope == 'app-icon-v1' || needs.plan.outputs.runtime_scope == 'ci-selection-v1')
        uses: actions/upload-artifact@b7c566a772e6b6bfb58ed0dc250532a479d7789f # v6.0.0
        with:
          name: app-icon-check-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}
          path: ${{ runner.temp }}/app-icon-check
          if-no-files-found: error
          retention-days: 7

"""


def icon_workflow_wired(source):
    jobs = dict(re.findall(r"^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)",
                          source.split("\njobs:\n", 1)[-1], re.M | re.S))
    body = jobs.get("build-without-signing", "")
    anchored = "            build\n\n" + ICON_WORKFLOW_STEPS + "      - name: Upload build result bundle\n"
    return source.count(ICON_WORKFLOW_STEPS) == 1 and anchored in body


def icon_paths_only(paths):
    return bool(paths and set(paths) & ICON_PATHS and set(paths) <= ICON_PATHS | ICON_DOC_PATHS)


def validate_png(data, size=1024):
    """Bounded validation: real opaque RGB PNG, complete pixels and valid CRCs."""
    if not isinstance(data, bytes) or not 32 <= len(data) <= 8 * 1024 * 1024:
        raise ValueError("Icon PNG must be at most 8 MiB")
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Not a PNG")
    offset, header, compressed, ended = 8, None, bytearray(), False
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError("Truncated PNG chunk")
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        tag = data[offset + 4:offset + 8]
        end = offset + 12 + length
        if end > len(data):
            raise ValueError("Truncated PNG payload")
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack(">I", data[end - 4:end])[0]
        if zlib.crc32(tag + payload) & 0xffffffff != crc:
            raise ValueError("PNG CRC mismatch")
        if offset == 8 and tag != b"IHDR":
            raise ValueError("Missing initial PNG header")
        if tag == b"IHDR":
            if header is not None or len(payload) != 13:
                raise ValueError("Invalid PNG header")
            header = struct.unpack(">IIBBBBB", payload)
            if header != (size, size, 8, 2, 0, 0, 0):
                raise ValueError(f"Expected {size}x{size} non-interlaced opaque RGB PNG")
        elif tag == b"IDAT":
            compressed.extend(payload)
        elif tag == b"IEND":
            if payload or end != len(data):
                raise ValueError("Invalid PNG ending")
            ended = True
        elif tag in (b"tRNS", b"acTL", b"fcTL", b"fdAT") or (tag[0] & 32 == 0):
            raise ValueError("Unsupported transparency, animation or critical chunk")
        offset = end
    if header is None or not compressed or not ended:
        raise ValueError("Incomplete PNG")
    expected = size * (size * 3 + 1)
    decoder = zlib.decompressobj()
    try:
        pixels = decoder.decompress(bytes(compressed), expected + 1)
    except zlib.error as error:
        raise ValueError("Invalid compressed PNG pixels") from error
    if len(pixels) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError("PNG pixel data is incomplete or oversized")
    if any(pixels[row * (size * 3 + 1)] > 4 for row in range(size)):
        raise ValueError("Invalid PNG row filter")

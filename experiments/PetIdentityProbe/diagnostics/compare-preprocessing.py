"""Synthetic comparison; executes exact probe methods, no model or user photos.

Windows --self-check validates fixture/reference/extraction only. Full mode runs
UIKit/CoreGraphics in iOS Simulator, not a substituted non-Apple renderer.
References independently implement the published transforms, not upstream code.
Different interpolation kernels are measurements, not identity-accuracy failures.
"""

import argparse
import hashlib
import json
import platform
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, __version__ as pillow_version

PROBE = Path(__file__).resolve().parents[1]
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)


def probe_methods():
    source = (PROBE / "Sources/IdentityPhotoService.swift").read_text(encoding="utf-8")
    extracted = []
    for name, following in (("upright", "cropRect"), ("cropRect", "singleCatCrop"), ("rgbTensor", "fingerprint")):
        begin = source.index(f"    static func {name}(")
        end = source.index(f"    static func {following}(", begin)
        method = source[begin:end].rstrip()
        assert method.endswith("}")
        extracted.append(method)
    return "\n\n".join(extracted)


def patterns():
    result = {}
    for name, width, height, kind in (
        ("rgb_sentinel", 224, 224, "corners"),
        ("constant", 224, 224, "constant"),
        ("portrait", 96, 384, "gradient"),
        ("landscape", 384, 96, "gradient"),
        ("gradient", 800, 600, "gradient"),
        ("fine_bands", 800, 600, "bands"),
        ("hard_edge", 800, 600, "edge"),
    ):
        y, x = np.indices((height, width))
        if kind == "gradient":
            rgb = np.stack((x * 255 // (width - 1), y * 255 // (height - 1),
                            (x + y) * 255 // (width + height - 2)), axis=2)
        elif kind == "corners":
            rgb = np.stack((np.where(x < width // 2, 255, 0),
                            np.where(y >= height // 2, 255, 0),
                            np.where(x >= width // 2, 255, 0)), axis=2)
        elif kind == "constant":
            rgb = np.broadcast_to([31, 127, 223], (height, width, 3))
        elif kind == "bands":
            rgb = np.stack((((x // 4) % 2) * 255, ((y // 4) % 2) * 255,
                            (((x + y) // 4) % 2) * 255), axis=2)
        else:
            rgb = np.repeat(np.where(x[..., None] < width // 2 - 1, 0, 255), 3, axis=2)
        result[name] = rgb.astype(np.uint8)
    return result


def normalize(rgb):
    return ((rgb.astype(np.float32) / np.float32(255) - MEAN) / STD).transpose(2, 0, 1)


def pil_reference(rgb):
    return normalize(np.asarray(Image.fromarray(rgb).resize((224, 224), Image.Resampling.BILINEAR)))


def cv_reference(rgb):
    import cv2
    # Published author choice is based on area, including mixed-axis resizes.
    method = cv2.INTER_AREA if rgb.shape[0] * rgb.shape[1] > 224 * 224 else cv2.INTER_LINEAR
    # Input is already RGB (author converts BGR after resize); no double swap.
    return normalize(cv2.resize(rgb, (224, 224), interpolation=method))


def difference(a, b):
    assert a.shape == b.shape == (3, 224, 224)
    assert np.isfinite(a).all() and np.isfinite(b).all()
    delta = np.abs(a.astype(np.float64) - b.astype(np.float64))
    pixels = delta * STD.astype(np.float64)[:, None, None] * 255
    return {"mean_abs_normalized": round(float(delta.mean()), 8),
            "max_abs_normalized": round(float(delta.max()), 8),
            "mean_abs_RGB_0_255": round(float(pixels.mean()), 6),
            "max_abs_RGB_0_255": round(float(pixels.max()), 6)}


HARNESS = r'''
struct Fixture: Decodable { let name: String; let width: Int; let height: Int }
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: folder.appendingPathComponent("fixtures.json")))
func load(_ f: Fixture) throws -> CGImage {
    let data = try Data(contentsOf: folder.appendingPathComponent(f.name + ".rgba"))
    precondition(data.count == f.width * f.height * 4)
    let provider = CGDataProvider(data: data as CFData)!
    return CGImage(width: f.width, height: f.height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: f.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}
func save(_ image: CGImage, _ name: String) throws {
    guard let tensor = IdentityImagePipeline.rgbTensor(image) else { fatalError("tensor conversion failed") }
    precondition(tensor.length == 3 * 224 * 224 * 4)
    try (tensor as Data).write(to: folder.appendingPathComponent(name + ".f32"))
}
for fixture in fixtures where fixture.name != "scene" {
    let input = try load(fixture)
    try save(input, fixture.name)
    if fixture.name == "rgb_sentinel" {
        for (name, orientation) in [("up", UIImage.Orientation.up), ("down", .down), ("left", .left), ("right", .right), ("upMirrored", .upMirrored), ("downMirrored", .downMirrored), ("leftMirrored", .leftMirrored), ("rightMirrored", .rightMirrored)] {
            guard let normalized = IdentityImagePipeline.upright(UIImage(cgImage: input, scale: 1, orientation: orientation)) else { fatalError("upright failed") }
            try save(normalized, "orientation_" + name)
        }
        let rect = IdentityImagePipeline.cropRect(CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), width: 224, height: 224)!
        precondition(rect == CGRect(x: 0, y: 0, width: 112, height: 112))
        try save(input.cropping(to: rect)!, "top_left_crop")
    }
}
precondition(IdentityImagePipeline.cropRect(CGRect(x: 0, y: 0, width: 28.0/1024, height: 28.0/768), width: 1024, height: 768) == nil)
precondition(IdentityImagePipeline.cropRect(CGRect(x: 0, y: 0, width: 32.0/1024, height: 32.0/768), width: 1024, height: 768) != nil)
let scene = try load(fixtures.first { $0.name == "scene" }!)
let original = CGRect(x: 512, y: 512, width: 256, height: 256)
try save(scene.cropping(to: original)!, "order_direct")
let upright = IdentityImagePipeline.upright(UIImage(cgImage: scene))!
precondition(upright.width == 1024 && upright.height == 768)
let normalizedBox = CGRect(x: 512.0/2048, y: 1 - 768.0/1536, width: 256.0/2048, height: 256.0/1536)
let smaller = IdentityImagePipeline.cropRect(normalizedBox, width: upright.width, height: upright.height)!
precondition(smaller == CGRect(x: 256, y: 256, width: 128, height: 128))
try save(upright.cropping(to: smaller)!, "order_staged")
let metadata: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
    "device": UIDevice.current.model, "runtime": "iOS Simulator", "geometryAssertions": 4,
    "syntheticOnly": true, "usesPhotoKit": false, "usesVision": false, "usesONNX": false]
try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
    .write(to: folder.appendingPathComponent("native.json"))
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-check", action="store_true")
    parser.add_argument("--work", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    methods = probe_methods()
    fixtures = patterns()
    assert methods.count("static func ") == 3
    assert "context.interpolationQuality = .high" in methods
    assert "import Photos" not in methods and "ORT" not in methods
    for rgb in fixtures.values():
        assert pil_reference(rgb).shape == (3, 224, 224)
    assert np.array_equal(pil_reference(fixtures["rgb_sentinel"]), normalize(fixtures["rgb_sentinel"]))
    if args.self_check:
        print(json.dumps({"fixtureCount": len(fixtures), "extractedMethods": 3,
                          "nativeExecuted": False, "localChecks": "passed"}))
        return
    if platform.system() != "Darwin" or not args.work or not args.report:
        parser.error("Full comparison requires macOS, --work and --report; there is no simulated Apple fallback.")
    import cv2
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=False)
    y, x = np.indices((256, 256))
    patch = np.stack((((x//4)%2)*255, ((y//4)%2)*255, (((x+y)//4)%2)*255), axis=2).astype(np.uint8)
    scene = np.full((1536, 2048, 3), 127, dtype=np.uint8)
    scene[512:768, 512:768] = patch
    manifest = []
    for name, rgb in {**fixtures, "scene": scene}.items():
        rgba = np.concatenate((rgb, np.full((*rgb.shape[:2], 1), 255, dtype=np.uint8)), axis=2)
        rgba.tofile(work / (name + ".rgba"))
        manifest.append({"name": name, "width": rgb.shape[1], "height": rgb.shape[0]})
    (work / "fixtures.json").write_text(json.dumps(manifest), encoding="utf-8")
    source = "import Foundation\nimport UIKit\nimport CoreGraphics\nenum IdentityImagePipeline {\n" + methods + "\n}\n" + HARNESS
    swift = work / "main.swift"
    swift.write_text(source, encoding="utf-8")

    def command(*argv, timeout=240):
        return subprocess.run(argv, check=True, capture_output=True, text=True, timeout=timeout).stdout.strip()

    sdk = command("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
    target = f"{platform.machine()}-apple-ios18.6-simulator"
    executable = work / "preprocessing"
    command("xcrun", "swiftc", "-sdk", sdk, "-target", target, str(swift), "-o", str(executable))
    runtime = "com.apple.CoreSimulator.SimRuntime.iOS-18-6"
    simulator = command("xcrun", "simctl", "create", "PetPreprocessingOnly", "com.apple.CoreSimulator.SimDeviceType.iPhone-16", runtime)
    try:
        command("xcrun", "simctl", "boot", simulator)
        command("xcrun", "simctl", "bootstatus", simulator, "-b")
        command("xcrun", "simctl", "spawn", simulator, str(executable), str(work), timeout=90)
    finally:
        # Only the simulator created above, never an existing user device.
        command("xcrun", "simctl", "shutdown", simulator, timeout=30)

    def native(name):
        return np.fromfile(work / (name + ".f32"), dtype="<f4").reshape(3, 224, 224)

    measurements = []
    for name, rgb in fixtures.items():
        current = native(name)
        pil = pil_reference(rgb)
        cv = cv_reference(rgb)
        measurements.append({"name": name, "size": [rgb.shape[1], rgb.shape[0]],
                             "native_vs_PIL": difference(current, pil),
                             "native_vs_OpenCV": difference(current, cv),
                             "PIL_vs_OpenCV": difference(pil, cv)})
    for name in ("rgb_sentinel", "constant"):
        np.testing.assert_allclose(native(name), normalize(fixtures[name]), atol=1e-6, rtol=0)
    top_left = np.broadcast_to([255, 0, 0], (224, 224, 3)).astype(np.uint8)
    np.testing.assert_allclose(native("top_left_crop"), normalize(top_left), atol=1e-6, rtol=0)
    orientation_ops = {"up": None, "down": Image.Transpose.ROTATE_180,
                       "left": Image.Transpose.ROTATE_90, "right": Image.Transpose.ROTATE_270,
                       "upMirrored": Image.Transpose.FLIP_LEFT_RIGHT, "downMirrored": Image.Transpose.FLIP_TOP_BOTTOM,
                       "leftMirrored": Image.Transpose.TRANSPOSE, "rightMirrored": Image.Transpose.TRANSVERSE}
    for name, op in orientation_ops.items():
        original = Image.fromarray(fixtures["rgb_sentinel"])
        expected = np.asarray(original if op is None else original.transpose(op))
        np.testing.assert_allclose(native("orientation_" + name), normalize(expected), atol=1e-6, rtol=0)
    result = {"scope": "synthetic native transform comparison only; not model accuracy or actual unknown diagnosis",
              "sourceCommit": command("git", "rev-parse", "HEAD"),
              "extractedMethodsSHA256": hashlib.sha256(methods.encode()).hexdigest(),
              "native": json.loads((work / "native.json").read_text()),
              "versions": {"numpy": np.__version__, "Pillow": pillow_version, "OpenCV": cv2.__version__},
              "fixtureContract": {"colorSpace": "sRGB", "bitsPerComponent": 8,
                                  "alpha": "opaque-noneSkipLast", "shouldInterpolate": True,
                                  "tensorByteOrder": "little-endian Float32 CHW"},
              "swiftTarget": target, "measurements": measurements,
              "native_crop_order_difference": difference(native("order_direct"), native("order_staged")),
              "invariants": {"unscaledRGB": "passed", "cropCoordinatesAndPixels": "passed", "orientation8": "passed"},
              "limits": ["No PhotoKit fetching, Vision detection, model or user photos",
                         "sRGB opaque fixtures only; no HDR, ICC or natural cat accuracy validation",
                         "Reference library versions are pinned here, not proven identical to author's original environment",
                         "Simulator iOS 18.6 is not the user's iOS 26.6 physical device"],
              "productValidated": False}
    args.report.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"native": result["native"], "invariants": result["invariants"],
                      "report": args.report.name, "productValidated": False}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        # Only compiler/simulator output; no signing secrets or user inputs exist.
        print((error.stderr or error.stdout or "")[-6000:])
        raise

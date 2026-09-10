"""Assemble exact upstream notices for internal distribution; never repin silently."""
import hashlib
from pathlib import Path
import urllib.request

SOURCES = [
    ("ONNX Runtime 1.24.2 (MIT)", "https://raw.githubusercontent.com/microsoft/onnxruntime/v1.24.2/LICENSE", "2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c"),
    ("ONNX Runtime SwiftPM and bindings (MIT)", "https://raw.githubusercontent.com/microsoft/onnxruntime-swift-package-manager/b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2/LICENSE", "c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383"),
    ("ONNX Runtime upstream third-party notices", "https://raw.githubusercontent.com/microsoft/onnxruntime/v1.24.2/ThirdPartyNotices.txt", "0e07b95f3a8d6230037707c5c4a2b554d12c4cb67369669ac255635528ffcee2"),
    ("Apache License 2.0 (pet recognition model)", "https://www.apache.org/licenses/LICENSE-2.0.txt", "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"),
    ("DINOv2 upstream license (Apache 2.0)", "https://raw.githubusercontent.com/facebookresearch/dinov2/7764ea0f912e53c92e82eb78a2a1631e92725fc8/LICENSE", "600cc67cc4cb2f5ea317dcfc687ad1c74dc4bec8782bbe9db0afd83513b935b7"),
    ("YOLOX-Nano model and inference processing (Apache 2.0)", "https://raw.githubusercontent.com/Megvii-BaseDetection/YOLOX/e1052df71842031413f6030723c3607b839c80ce/LICENSE", "577c03d505ec80f667ebf96ebd0cc4f6825c817ca1088ee348c48aaabd51bd92"),
]

ORIGIN = """猫識別・動作確認 — Internal engineering evaluation only

This app measures runtime performance using synthetic inputs and offers
explicit, local-only diagnosis of user-selected photos. It never automatically
transmits photos or results and does not modify production photo assignments.

Three generated cat controls are bundled for detector diagnosis (CC0 1.0):
cat-orange-square.png, cat-tuxedo-landscape.png, cat-gray-portrait.png.
Generated for this repository on 2026-08-15 without personal or reference photos.
Fixture provenance and license:
https://github.com/soso-so-27/neko-widget/tree/main/NekoWidget/ci/fixtures/cats
https://creativecommons.org/publicdomain/zero/1.0/legalcode

Model: open-noodle/pet-recognition-small
Model card and license designation (Apache-2.0):
https://huggingface.co/open-noodle/pet-recognition-small/blob/9dd4c915be29a81b116b3e30eb996c59d0e7ede0/README.md
Original SHA256: 6a5e2373ab348bed588cef4072f3914ca9c8bacde3e8d0651019e8dad86b24ba
Modified model-fixed.onnx SHA256: 32adffda4e65f790ae624d828b79db7a18f7fdb1facdce1cc91bb9951d948c0b
Modification: input batch dimension fixed to 1 using the official ONNX Runtime
make_dynamic_shape_fixed helper. Other model parameters were not retrained.
No Gallery application source (AGPL) is included.

Additional object detector: YOLOX-Nano, official ONNX release 0.1.1rc0.
Copyright (c) Megvii, Inc. and its affiliates. Apache License 2.0 below.
https://github.com/Megvii-BaseDetection/YOLOX/releases/tag/0.1.1rc0
Model SHA256: c789161ed43c8269fcd4e67c67eeeb4e80c622da2eb296a20bc6007bd18a0b7d
The distributed model is unmodified. Official preprocessing, stride decoding
and class-agnostic NMS were adapted to Swift for a bounded local comparison.
https://github.com/Megvii-BaseDetection/YOLOX/tree/e1052df71842031413f6030723c3607b839c80ce
This is general cat-region detection, not individual cat identification.
It does not assign photos, train from human decisions or replace the identity model.
Training-data provenance and commercial product adoption remain separate reviews.

The model author describes a DINOv2-small backbone. The DINOv2 license below
was checked at commit 7764ea0f912e53c92e82eb78a2a1631e92725fc8; this does not
establish the base revision originally used to train the pet model.
Training-data provenance, real-photo accuracy and commercial product use
remain separate, unresolved evaluations.

Source availability for upstream open-source components:
ONNX Runtime: https://github.com/microsoft/onnxruntime/tree/v1.24.2
Bindings: https://github.com/microsoft/onnxruntime-swift-package-manager/tree/b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2
Eigen (MPL-2.0), as pinned by ONNX Runtime v1.24.2 cmake/deps.txt:
https://github.com/eigen-mirror/eigen/tree/1d8b82b0740839c0de7f1242a3585e3390ff5f33
Your rights under the component licenses below are not restricted by
additional application terms. Original notices are retained in full.
"""


def main():
    parts = [ORIGIN]
    for title, url, expected in SOURCES:
        with urllib.request.urlopen(url, timeout=30) as response:
            data = response.read(1_000_001)
        if len(data) > 1_000_000 or hashlib.sha256(data).hexdigest() != expected:
            raise ValueError(f"Upstream notice changed: {title}")
        parts.append(f"\n\n=== {title} ===\nSource: {url}\n\n{data.decode('utf-8')}")
    target = Path(__file__).resolve().parent / "Generated" / "ThirdPartyNotices.txt"
    target.parent.mkdir(exist_ok=True)
    target.write_text("".join(parts), encoding="utf-8", newline="\n")
    print("Six pinned upstream license/notice files assembled")


if __name__ == "__main__":
    main()

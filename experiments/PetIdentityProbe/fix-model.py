"""Fix batch to 1 using the official ORT helper and check synthetic equivalence."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

import numpy as np
import onnxruntime as ort

SOURCE_SHA = "6a5e2373ab348bed588cef4072f3914ca9c8bacde3e8d0651019e8dad86b24ba"
FIXED_SHA = "32adffda4e65f790ae624d828b79db7a18f7fdb1facdce1cc91bb9951d948c0b"


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main():
    original, fixed = map(Path, sys.argv[1:3])
    if digest(original) != SOURCE_SHA:
        raise ValueError("Unexpected original model")
    if not fixed.exists():
        subprocess.run([
            sys.executable, "-m", "onnxruntime.tools.make_dynamic_shape_fixed",
            "--input_name", "input", "--input_shape", "1,3,224,224",
            str(original), str(fixed),
        ], check=True)
    if digest(fixed) != FIXED_SHA:
        raise ValueError("Unexpected fixed model; stop instead of silently repinning")
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    baseline = ort.InferenceSession(str(original), sess_options=options, providers=["CPUExecutionProvider"])
    candidate = ort.InferenceSession(str(fixed), sess_options=options, providers=["CPUExecutionProvider"])
    if candidate.get_inputs()[0].shape != [1, 3, 224, 224]:
        raise ValueError("Input is not static")
    maximum_delta = 0.0
    for index in range(3):
        pixels = np.random.default_rng(index).random((1, 3, 224, 224), dtype=np.float32)
        if index == 0:
            pixels.fill(0.5)
        elif index == 1:
            pixels[:] = np.linspace(0, 1, 224, dtype=np.float32)[None, None, None, :]
        mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)[None, :, None, None]
        std = np.array([0.229, 0.224, 0.225], dtype=np.float32)[None, :, None, None]
        inputs = {"input": np.ascontiguousarray((pixels - mean) / std)}
        lhs, rhs = baseline.run(None, inputs)[0], candidate.run(None, inputs)[0]
        if lhs.shape != (1, 512) or rhs.shape != lhs.shape:
            raise ValueError("Unexpected output shape")
        if not np.isfinite(lhs).all() or not np.isfinite(rhs).all():
            raise ValueError("Nonfinite model output")
        maximum_delta = max(maximum_delta, float(np.max(np.abs(lhs - rhs))))
        if not np.allclose(lhs, rhs, atol=1e-5, rtol=1e-5):
            raise ValueError("Fixed model changed the synthetic output")
    print(json.dumps({
        "scope": "synthetic_static_shape_equivalence",
        "source_sha256": SOURCE_SHA, "fixed_sha256": FIXED_SHA,
        "samples": 3, "maximum_absolute_difference": maximum_delta,
        "cat_accuracy_measured": False,
    }))


if __name__ == "__main__":
    main()

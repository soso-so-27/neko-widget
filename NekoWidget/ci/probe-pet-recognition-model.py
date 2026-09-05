"""Offline I/O smoke probe, NOT a cat-identity accuracy or iPhone benchmark.

Uses synthetic inputs only. Does not download anything, read user photos, save
embeddings, or change application data. Dependencies: numpy, onnxruntime==1.22.1.
Model: open-noodle/pet-recognition-small, revision
9dd4c915be29a81b116b3e30eb996c59d0e7ede0/recognition/model.onnx.
Written from the published I/O contract; no Gallery implementation is included.
"""

import argparse
import hashlib
import json
import platform
import statistics
import time
from pathlib import Path

import numpy as np
import onnxruntime as ort


MODEL_SHA256 = "6a5e2373ab348bed588cef4072f3914ca9c8bacde3e8d0651019e8dad86b24ba"
MODEL_BYTES = 89_227_604


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", type=Path, help="Locally downloaded, pinned ONNX file")
    args = parser.parse_args()
    if args.model.stat().st_size != MODEL_BYTES:
        raise ValueError("Unexpected model size; refusing to load a different model")
    with args.model.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    if digest != MODEL_SHA256:
        raise ValueError("Model SHA-256 mismatch; refusing to load")

    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    options.log_severity_level = 3
    started = time.perf_counter()
    session = ort.InferenceSession(
        str(args.model), sess_options=options, providers=["CPUExecutionProvider"]
    )
    load_ms = (time.perf_counter() - started) * 1000
    inputs, outputs = session.get_inputs(), session.get_outputs()
    if len(inputs) != 1 or len(outputs) != 1:
        raise ValueError("Unexpected input/output count")
    if (inputs[0].name, inputs[0].type, inputs[0].shape[1:]) != (
        "input", "tensor(float)", [3, 224, 224]
    ) or (outputs[0].name, outputs[0].type, outputs[0].shape[1:]) != (
        "embedding", "tensor(float)", [512]
    ):
        raise ValueError("Model does not match the published I/O contract")

    # Generated RGB values, not camera-roll assets or sample animal photos.
    pixels = np.random.default_rng(129).random((3, 3, 224, 224), dtype=np.float32)
    pixels[0].fill(0.5)
    pixels[1] = np.linspace(0, 1, 224, dtype=np.float32)[None, None, :]
    mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)[None, :, None, None]
    std = np.array([0.229, 0.224, 0.225], dtype=np.float32)[None, :, None, None]
    batch = np.ascontiguousarray((pixels - mean) / std)

    def infer(value):
        result = session.run(["embedding"], {"input": value})[0]
        if result.shape != (len(value), 512) or not np.isfinite(result).all():
            raise ValueError("Invalid or nonfinite embedding output")
        if not np.allclose(np.linalg.norm(result, axis=1), 1.0, atol=1e-4):
            raise ValueError("Embedding is not L2-normalized")
        return result

    infer(batch[:1])  # One warm-up; timing below is not startup latency.
    elapsed = []
    for sample in batch:
        started = time.perf_counter()
        infer(sample[None, :])
        elapsed.append((time.perf_counter() - started) * 1000)
    together = infer(batch)
    individually = np.concatenate([infer(sample[None, :]) for sample in batch])
    batch_delta = float(np.max(np.abs(together - individually)))
    if not np.allclose(together, individually, atol=1e-4, rtol=1e-4):
        raise ValueError("Dynamic-batch and single-input outputs differ")
    print(json.dumps({
        "result": "synthetic_io_pass",
        "model_sha256": digest,
        "model_bytes": MODEL_BYTES,
        "runtime": ort.__version__,
        "platform": platform.system(),
        "provider": "CPUExecutionProvider",
        "intra_op_threads": 2,
        "synthetic_samples": 3,
        "session_load_ms": round(load_ms, 2),
        "warm_single_input_median_ms": round(statistics.median(elapsed), 2),
        "batch_max_absolute_difference": batch_delta,
        "cat_accuracy_evaluated": False,
        "iphone_performance_evaluated": False,
        "user_photos_read": False,
        "embeddings_saved": False,
    }, indent=2))


if __name__ == "__main__":
    main()

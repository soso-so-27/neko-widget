"""Local generated-fixture experiment only: no PhotoKit, IDs or app integration.

YOLOX processing follows Megvii's Apache-2.0 demo (copyright Megvii Inc.):
Upstream license is retained in YOLOX-LICENSE.txt. Adaptation: this bounded
generated-fixture runner replaces CLI photo input/visualization with fixed controls.
https://github.com/Megvii-BaseDetection/YOLOX/blob/main/demo/ONNXRuntime/onnx_inference.py
https://github.com/Megvii-BaseDetection/YOLOX/blob/main/yolox/utils/demo_utils.py
Fixed before execution: Nano416 baseline or official S640 comparison, score >= .3, class-agnostic NMS .45,
15 single-cat controls and 6 pair layouts. No threshold/grid/model search.
Pillow fixture rendering is not pixel-identical to UIKit: not a paired accuracy claim.
"""
import argparse
import hashlib
import json
import time
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort
from PIL import Image, ImageDraw, ImageFont


def fixtures(root):
    names = ["cat-orange-square", "cat-tuxedo-landscape", "cat-gray-portrait"]
    originals = [(name, Image.open(root / f"{name}.png").convert("RGB")) for name in names]
    for name, image in originals:
        yield name, 1, image
    for name, image in originals:
        ratio = 768 / max(image.size)
        size = tuple(int(n * ratio) for n in image.size)
        fitted = image.resize(size, Image.Resampling.BILINEAR)
        for corner, x, y in [("top-left", 0, 0), ("top-right", 1024-size[0], 0),
                              ("bottom-left", 0, 1024-size[1]), ("bottom-right", 1024-size[0], 1024-size[1])]:
            canvas = Image.new("RGB", (1024, 1024), (128, 128, 128))
            canvas.paste(fitted, (x, y))
            yield f"{name}-single75-{corner}", 1, canvas
    for i, (name_a, image_a) in enumerate(originals):
        for name_b, image_b in originals[i+1:]:
            for vertical in [False, True]:
                canvas = Image.new("RGB", (1024, 1024), (128, 128, 128))
                width, height = (1024, 512) if vertical else (512, 1024)
                for j, image in enumerate([image_a, image_b]):
                    ratio = min(width / image.width, height / image.height)
                    size = tuple(int(n * ratio) for n in image.size)
                    x = (width-size[0])//2 + (0 if vertical else j*width)
                    y = (height-size[1])//2 + (j*height if vertical else 0)
                    canvas.paste(image.resize(size, Image.Resampling.BILINEAR), (x, y))
                yield f"{name_a}+{name_b}-{'vertical' if vertical else 'horizontal'}", 2, canvas


def decode(output, side):
    row_count = sum((side // stride)**2 for stride in [8, 16, 32])
    if output.shape != (1, row_count, 85) or not np.isfinite(output).all():
        raise ValueError("Unexpected fixed model output")
    grids, strides = [], []
    for stride in [8, 16, 32]:
        n = side // stride
        x, y = np.meshgrid(np.arange(n), np.arange(n))
        grids.append(np.stack((x, y), 2).reshape(1, -1, 2))
        strides.append(np.full((1, n*n, 1), stride))
    prediction = output.copy()
    prediction[..., :2] = (prediction[..., :2] + np.concatenate(grids, 1)) * np.concatenate(strides, 1)
    prediction[..., 2:4] = np.exp(prediction[..., 2:4]) * np.concatenate(strides, 1)
    if not np.isfinite(prediction).all():
        raise ValueError("Nonfinite decoded output")
    return prediction[0]


def nms(boxes, scores, threshold=.45):
    order = np.argsort(scores)[::-1]
    area = (boxes[:, 2]-boxes[:, 0]+1) * (boxes[:, 3]-boxes[:, 1]+1)
    keep = []
    while order.size:
        index = order[0]
        keep.append(int(index))
        others = order[1:]
        left = np.maximum(boxes[index, :2], boxes[others, :2])
        right = np.minimum(boxes[index, 2:], boxes[others, 2:])
        extent = np.maximum(0, right-left+1)
        intersection = extent[:, 0] * extent[:, 1]
        overlap = intersection / (area[index]+area[others]-intersection)
        order = others[overlap <= threshold]
    return keep


def detect(session, image, side):
    # Official demo uses cv2 BGR, 0..255 float32, top-left letterbox114, no normalization.
    bgr = np.asarray(image)[..., ::-1]
    ratio = min(side/image.height, side/image.width)
    size = (int(image.width*ratio), int(image.height*ratio))
    resized = cv2.resize(bgr, size, interpolation=cv2.INTER_LINEAR)
    padded = np.full((side, side, 3), 114, dtype=np.uint8)
    padded[:size[1], :size[0]] = resized
    tensor = np.ascontiguousarray(padded.transpose(2, 0, 1)[None], dtype=np.float32)
    prediction = decode(session.run(None, {session.get_inputs()[0].name: tensor})[0], side)
    scores = prediction[:, 4:5] * prediction[:, 5:]
    classes = scores.argmax(1)
    best = scores[np.arange(len(scores)), classes]
    # Official demo first removes <=.1, NMS .45, then displays score >=.3.
    valid = best > .1
    boxes = np.column_stack((prediction[:, :2]-prediction[:, 2:4]/2,
                             prediction[:, :2]+prediction[:, 2:4]/2))[valid] / ratio
    best, classes = best[valid], classes[valid]
    picked = nms(boxes, best)
    cats = [i for i in picked if classes[i] == 15 and best[i] >= .3]
    return {"catDetections": len(cats), "catScores": [round(float(best[i]), 6) for i in cats],
            "generatedFixtureBoxesXYXY": [boxes[i].tolist() for i in cats]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--variant", choices=["nano416", "s640"], default="nano416")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--preview", type=Path)
    args = parser.parse_args()
    side = 416 if args.variant == "nano416" else 640
    # Refuse arbitrary pictures: only these three repository-generated fixtures are read.
    root = Path(__file__).resolve().parents[3] / "NekoWidget/ci/fixtures/cats"
    if hashlib.sha256(args.model.read_bytes()).hexdigest() != args.sha256.lower():
        raise ValueError("Model hash mismatch")
    assert nms(np.array([[0., 0, 20, 20], [0, 0, 20, 20], [30, 30, 50, 50]]), np.array([.9, .8, .7])) == [0, 2]
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    session = ort.InferenceSession(str(args.model), sess_options=options, providers=["CPUExecutionProvider"])
    if session.get_inputs()[0].shape != [1, 3, side, side]:
        raise ValueError("Unexpected model input")
    rows, preview_tiles = [], []
    start = time.perf_counter()
    for name, expected, image in fixtures(root):
        detection = detect(session, image, side)
        rows.append({"fixture": name, "expectedCats": expected, **detection})
        if args.preview and expected == 2:
            # Analysis overlay on fixed generated fixtures only. Never an app/PhotoKit photo.
            preview = image.resize((512, 512), Image.Resampling.BILINEAR)
            draw = ImageDraw.Draw(preview)
            for index, box in enumerate(detection["generatedFixtureBoxesXYXY"]):
                draw.rectangle([value/2 for value in box], outline=(0, 255, 80), width=3)
                draw.text((max(0, box[0]/2)+4, max(0, box[1]/2)+4), str(index+1),
                          fill=(0, 255, 80), font=ImageFont.load_default(size=22))
            tile = Image.new("RGB", (512, 555), (20, 20, 20))
            tile.paste(preview, (0, 43))
            ImageDraw.Draw(tile).text((8, 10), name.replace("cat-", ""),
                                     fill="white", font=ImageFont.load_default(size=14))
            preview_tiles.append(tile)
    assert len(rows) == 21 and len({row["fixture"] for row in rows}) == 21
    result = {"scope": "generated-only-desktop-mechanism-exploration;not-pixel-identical-to-UIKit;not-device-or-product-validation",
              "model": "YOLOX-" + ("Nano" if side == 416 else "S") + "-0.1.1rc0",
              "inputSide": side, "modelSHA256": args.sha256.lower(),
              "runtimeVersion": ort.__version__, "scoreThreshold": .3, "nmsThreshold": .45,
              "elapsedSeconds": round(time.perf_counter()-start, 3), "photosIncluded": False,
              "geometryScope": "fixed-generated-fixtures-only;not-user-photo-geometry",
              "identifiersIncluded": False, "productionDataChanged": False, "productValidated": False,
              "rows": rows}
    with args.output.open("x", encoding="utf-8") as output:
        json.dump(result, output, ensure_ascii=False, indent=2)
    if args.preview:
        assert len(preview_tiles) == 6
        contact = Image.new("RGB", (1024, 1665))
        for index, tile in enumerate(preview_tiles):
            contact.paste(tile, ((index % 2)*512, (index // 2)*555))
        with args.preview.open("xb") as output:
            contact.save(output, format="PNG")
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()

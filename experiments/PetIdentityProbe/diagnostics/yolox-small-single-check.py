"""One additional safety counterfactual, not threshold or model search.

S640 made face+body boxes on the lower gray cat in a two-cat fixture. Remove
the other cat, keeping the gray cat's exact scale and position. If this one
cat still produces multiple usable regions, simple region-count gating is
not acceptable. Fixed generated asset only; no user photos or app writes.
"""
import importlib.util
import json
from pathlib import Path


def main():
    path = Path(__file__).with_name("yolox-fixed-fixtures.py")
    spec = importlib.util.spec_from_file_location("fixture_runner", path)
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    root = Path(__file__).resolve().parents[3]
    model = root / "artifacts/detector-alternative-20260910/yolox_s.onnx"
    assert runner.hashlib.sha256(model.read_bytes()).hexdigest() == "c5c2d13e59ae883e6af3b45daea64af4833a4951c92d116ec270d9ddbe998063"
    image = runner.Image.open(root / "NekoWidget/ci/fixtures/cats/cat-gray-portrait.png").convert("RGB")
    ratio = min(1024/image.width, 512/image.height)
    size = tuple(int(n*ratio) for n in image.size)
    canvas = runner.Image.new("RGB", (1024, 1024), (128, 128, 128))
    canvas.paste(image.resize(size, runner.Image.Resampling.BILINEAR), ((1024-size[0])//2, (512-size[1])//2+512))
    options = runner.ort.SessionOptions(); options.intra_op_num_threads = 2
    session = runner.ort.InferenceSession(str(model), sess_options=options, providers=["CPUExecutionProvider"])
    result = {"scope": "one-fixed-generated-counterfactual;not-independent-accuracy", "expectedCats": 1,
              "fixture": "gray-bottom50-without-other-cat", **runner.detect(session, canvas, 640)}
    target = root / "artifacts/detector-alternative-20260910/s640-single-counterfactual.json"
    with target.open("x", encoding="utf-8") as output:
        json.dump(result, output, indent=2)
    print(json.dumps(result))


if __name__ == "__main__":
    main()

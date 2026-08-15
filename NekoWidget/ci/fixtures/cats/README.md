# Simulator cat fixtures

These three images are deterministic test fixtures for the GitHub Actions iOS
Simulator smoke test:

- `cat-orange-square.png`
- `cat-tuxedo-landscape.png`
- `cat-gray-portrait.png`

They were generated specifically for this repository with OpenAI image
generation on 2026-08-15. No personal photos, third-party source images, or
reference images were used. Each image contains a single prominent cat and no
people, text, logos, or watermarks so that the fixtures exercise PhotoKit and
Vision without introducing personal data.

These three source images and the temporary derivatives described below are
released under [CC0 1.0 Universal](LICENSE.md). The rest of the repository is
not covered by this fixture-specific license.

## Scale-test derivatives

`ci/generate-scale-fixtures.swift` creates 1,000–3,000 temporary JPEG
derivatives from only these three hash-pinned sources. It downloads no external
media. Every output has a unique filename and a small index pattern drawn into
its pixels, and the generator refuses to finish unless every encoded SHA-256 is
unique.

The requested total includes three 8000×6000 large fixtures and four
regular-size warm-up fixtures. The remaining images have the `bulk` role. Their
capture dates are separated so a newest-first scan processes `warmup`, then
`large`, then `bulk`; this keeps Vision model initialization out of the large
image memory-measurement window. The scale runner should import the directories
in the corresponding bulk → large → warm-up order.

Compile and run the generator on the macOS runner as follows:

```bash
xcrun swiftc ci/generate-scale-fixtures.swift \
  -o "$RUNNER_TEMP/generate-scale-fixtures"
"$RUNNER_TEMP/generate-scale-fixtures" \
  --source-dir ci/fixtures/cats \
  --output-dir "$RUNNER_TEMP/neko-scale-fixtures" \
  --count 1000
```

Generated JPEGs are deliberately kept under `RUNNER_TEMP`, not in Git. A
compact `scale-fixture-manifest.json` records each role, source, dimensions,
byte count, capture date, pixel-variant ID, and SHA-256, together with the CC0
lineage. The temporary derivatives are also released under
[CC0 1.0 Universal](LICENSE.md).

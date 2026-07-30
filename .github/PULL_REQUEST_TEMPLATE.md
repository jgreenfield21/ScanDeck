## What this changes

<!-- One or two sentences. What behaviour is different after this merges? -->

## Why

<!-- The problem, not the patch. If it fixes an issue, link it. -->

## How it was verified

- [ ] `swift test` passes
- [ ] `swift test -c release` passes (required if this touches `ScanDeckImagePipeline` —
      the cropper takes ~47 s per master in debug and ~0.25 s in release)
- [ ] Ran the app (`bash Scripts/bundle-app.sh --run` or `--synthetic`)

**Hardware:** <!-- "fi-8170, real cards", or "no scanner — tests and --synthetic only".
Both are fine. Please don't claim a hardware behaviour you did not observe. -->

## Checklist

- [ ] No card scans, sample images, or personal data are committed
- [ ] New safety rules live in the `BatchSession` reducer, not the presentation model
- [ ] `ImageCaptureCore` types stayed inside `ScanDeckScanner`
- [ ] Tests inject temp directories and in-memory stores rather than touching
      real counters, bookmarks, settings, or batch history
- [ ] Operator-facing copy reads as if it ships, because it does

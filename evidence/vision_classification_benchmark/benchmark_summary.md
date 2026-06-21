# Vision Classification Benchmark Summary

## Scope

This evidence is for the DEBUG-only P0/P0.5 benchmark on `spike/vision-classification-benchmark`.

The benchmark does not save image bodies, thumbnails, face images, face templates, feature vectors, or raw asset identifiers. Asset identifiers in JSON/CSV are SHA-256 hashes.

## K Phone P0.5

- photoAuthorizationStatus: authorized
- totalAvailableImageCount: 26992
- supportedIdentifiers total: 1303

| Bucket | Report | Count | Avg ms | Failed | Screenshots | Non-screenshots | Document segmentation | Document label | Final document | OCR priority | Receipt |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Recent 20 | `20260621_200258_vision_probe_recent_20.json` | 20 | 449.4 | 0 | 15 | 5 | 20 | 16 | 1 | 15 | 0 |
| Recent 100 | `20260621_200332_vision_probe_recent_100.json` | 100 | 67.5 | 0 | 87 | 13 | 100 | 87 | 1 | 87 | 1 |
| Screenshot 20 | `20260621_200431_vision_probe_screenshot_20.json` | 20 | 533.3 | 0 | 20 | 0 | 20 | 20 | 0 | 20 | 0 |
| Non-screenshot 20 | `20260621_200504_vision_probe_non_screenshot_20.json` | 20 | 40.2 | 0 | 0 | 20 | 20 | 4 | 1 | 0 | 1 |

## P0.5 Notes

- `documentScore` was split into document segmentation, label score, visual score, final document score, and OCR priority.
- `VNDetectDocumentSegmentationRequest` still over-detects: every P0.5 bucket returned document segmentation for all sampled assets.
- Screenshots are now treated as OCR-priority candidates, not final document candidates. The screenshot bucket produced `finalDocumentCandidate: 0` while keeping `ocrPriorityCandidate: 20`.
- Recent samples remain screenshot-heavy, so building, construction, sign, whiteboard, receipt, and business card categories still need curated sample sets.
- Product classification storage, OCR coupling, and PhotoGrid integration were not implemented in this spike.

## K Phone P0.6

P0.6 adds `fullProbe` / `gatedProbe`, per-stage timing, screenshot fast path, ground-truth labeling UI, and precision/recall output for manually labeled assets.

| Bucket | Mode | Report | Count | Avg ms | Image | Classify | Face | Human | Doc seg | Final document | OCR priority |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Screenshot 20 | fullProbe | `20260621_205359_vision_probe_screenshot_full_20.json` | 20 | 527.8 | 241.5 | 30.2 | 9.0 | 3.6 | 3.7 | 0 | 20 |
| Screenshot 20 | gatedProbe | `20260621_205422_vision_probe_screenshot_gated_20.json` | 20 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0 | 20 |
| Recent 100 | fullProbe | `20260621_205436_vision_probe_recent_full_100.json` | 100 | 55.1 | 12.3 | 26.7 | 4.6 | 3.8 | 3.0 | 1 | 87 |
| Recent 100 | gatedProbe | `20260621_205503_vision_probe_recent_gated_100.json` | 100 | 7.8 | 2.2 | 2.0 | 1.0 | 0.5 | 0.6 | 1 | 87 |
| Non-screenshot 20 | fullProbe | `20260621_205517_vision_probe_non_screenshot_full_20.json` | 20 | 52.8 | 18.6 | 11.9 | 6.1 | 4.0 | 4.0 | 1 | 0 |
| Non-screenshot 20 | gatedProbe | `20260621_205531_vision_probe_non_screenshot_gated_20.json` | 20 | 49.3 | 16.0 | 11.3 | 6.0 | 4.0 | 3.9 | 1 | 0 |

Additional smoke check after adding ground-truth export:

- `20260621_210245_vision_probe_screenshot_gated_20.json`
- `p06_ground_truth_20260621_210245_vision_probe_screenshot_gated_20.json`
- Purpose: confirm K Phone build/install/launch and the P0.6 ground-truth export format. The exported ground-truth file contains no image bodies, thumbnails, or raw asset identifiers.

## P0.6 Notes

- `gatedProbe` is the production candidate for screenshots: it skips image loading and heavy Vision requests, keeps OCR priority, and prevents screenshots from becoming final document candidates.
- `documentSegmentationScore` is capped at 0.08 and `documentScoreWithoutSegmentation` is exported for comparison. Document segmentation should not be a primary signal.
- Manual label UI is implemented in DEBUG settings. CLI validation could not add labels, so these P0.6 reports contain `labeledAssetCount: 0`.
- Building, construction, sign, whiteboard, drawing, receipt, and business-card precision still require manually labeled samples.

## P0 Baseline

Earlier baseline reports are kept for comparison:

- `20260621_192957_vision_probe_20.json`
- `20260621_193046_vision_probe_100.json`

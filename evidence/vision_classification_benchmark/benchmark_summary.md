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

## P0 Baseline

Earlier baseline reports are kept for comparison:

- `20260621_192957_vision_probe_20.json`
- `20260621_193046_vision_probe_100.json`

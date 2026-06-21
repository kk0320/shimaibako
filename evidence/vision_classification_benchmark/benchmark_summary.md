# Vision Classification Benchmark Summary

## Scope

This evidence is for the DEBUG-only P0 benchmark on `spike/vision-classification-benchmark`.

The benchmark does not save image bodies, thumbnails, face images, face templates, feature vectors, or raw asset identifiers. Asset identifiers in JSON/CSV are SHA-256 hashes.

## K Phone

- photoAuthorizationStatus: authorized
- totalAvailableImageCount: 26992
- supportedIdentifiers total: 1303

### 20 Assets

- report: `20260621_192957_vision_probe_20.json`
- actualCount: 20
- averageMsPerAsset: 349.6
- maxMsPerAsset: 1473.7
- failedCount: 0
- screenshotCandidateCount: 15
- faceDetectedCount: 1
- humanDetectedCount: 2
- likelyDocumentCount: 20
- likelyBuildingCount: 5
- likelySignCount: 0
- likelyFoodCount: 0
- likelyConstructionSiteCount: 0

### 100 Assets

- report: `20260621_193046_vision_probe_100.json`
- actualCount: 100
- averageMsPerAsset: 265.0
- maxMsPerAsset: 1424.4
- failedCount: 0
- screenshotCandidateCount: 87
- faceDetectedCount: 1
- humanDetectedCount: 2
- likelyDocumentCount: 100
- likelyBuildingCount: 15
- likelySignCount: 0
- likelyFoodCount: 0
- likelyConstructionSiteCount: 0

## Notes

- The recent K Phone sample was screenshot-heavy.
- The provisional document score over-detected likely documents. This should be tightened before product use.
- Simulator launch and file output were verified, but CLI photo authorization stayed `notDetermined`, so Simulator image analysis returned 0 assets.
- Product classification storage, OCR coupling, and PhotoGrid integration were not implemented in this spike.

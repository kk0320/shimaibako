# Vision Classification Benchmark

## Run
- runID: 20260621_205359_vision_probe_screenshot_full_20
- bucketName: screenshot
- bucketTitle: スクショ
- probeMode: fullProbe
- device: iPhone
- photo authorization: authorized
- available image count: 26992
- requested count: 20
- actual count: 20
- average ms/asset: 527.8
- max ms/asset: 1079.8
- failed: 0

## Timing Breakdown
- imageRequestMs avg: 241.5
- classifyImageMs avg: 30.2
- faceDetectionMs avg: 9.0
- humanDetectionMs avg: 3.6
- documentSegmentationMs avg: 3.7
- visualFeatureMs avg: 0.2
- scoringMs avg: 0.0

## Signals
- screenshots: 20
- nonScreenshots: 0
- face detected: 0
- human detected: 0
- documentSegmentationDetected: 20
- documentLabelCandidate: 20
- finalDocumentCandidate: 0
- screenshotCandidate: 20
- ocrPriorityCandidate: 20
- likely building: 0
- likely construction site: 0
- likely sign: 0
- likely food: 0
- likely whiteboard: 0
- likely receipt: 0
- likely business card: 0
- likely vehicle/heavy equipment: 0
- likely material/equipment: 0

## Ground Truth Evaluation
- labeled assets: 0
- screenshot: TP 0, FP 0, FN 0, precision 0.00, recall 0.00
- document: TP 0, FP 0, FN 0, precision 0.00, recall 0.00
- drawing: TP 0, FP 0, FN 0, precision 0.00, recall 0.00
- businessCard: TP 0, FP 0, FN 0, precision 0.00, recall 0.00
- receipt: TP 0, FP 0, FN 0, precision 0.00, recall 0.00
- sign: TP 0, FP 0, FN 0, precision 0.00, recall 0.00
- whiteboard: TP 0, FP 0, FN 0, precision 0.00, recall 0.00
- building: TP 0, FP 0, FN 0, precision 0.00, recall 0.00
- constructionSite: TP 0, FP 0, FN 0, precision 0.00, recall 0.00
- person: TP 0, FP 0, FN 0, precision 0.00, recall 0.00
- vehicleHeavyEquipment: TP 0, FP 0, FN 0, precision 0.00, recall 0.00
- materialEquipment: TP 0, FP 0, FN 0, precision 0.00, recall 0.00
- food: TP 0, FP 0, FN 0, precision 0.00, recall 0.00
- landscape: TP 0, FP 0, FN 0, precision 0.00, recall 0.00
- ocrNeeded: TP 0, FP 0, FN 0, precision 0.00, recall 0.00

## Top Label Examples
- e14caba05d68: document 0.69, screenshot 0.69, printed_page 0.07, chart 0.04, diagram 0.04
- 2f3a806b7650: document 0.61, screenshot 0.61, structure 0.04, conveyance 0.04, portal 0.04
- 727864643548: document 0.50, screenshot 0.50, consumer_electronics 0.27, machine 0.27, computer 0.27
- add127c426fd: document 0.66, screenshot 0.66, printed_page 0.30, chart 0.06, diagram 0.06
- ca3de16df96f: document 0.62, screenshot 0.62, printed_page 0.11, chart 0.04, diagram 0.04
- 1f470e928b09: document 0.81, screenshot 0.81, printed_page 0.08, chart 0.05, diagram 0.05
- 5208c211645d: document 0.64, screenshot 0.64, machine 0.03, consumer_electronics 0.03, computer 0.03
- fba95c9a7d3d: document 0.58, screenshot 0.58, printed_page 0.06, chart 0.04, diagram 0.04
- ffce1d977582: document 0.52, screenshot 0.52, machine 0.05, consumer_electronics 0.05, computer 0.05
- 692d98eecc15: document 0.79, screenshot 0.79, printed_page 0.14, machine 0.04, consumer_electronics 0.04

## Safety
- image bodies are not saved
- thumbnails are not saved
- face images and face templates are not saved
- Photos library assets are read only
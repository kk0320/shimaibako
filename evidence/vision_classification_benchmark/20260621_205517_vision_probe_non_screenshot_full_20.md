# Vision Classification Benchmark

## Run
- runID: 20260621_205517_vision_probe_non_screenshot_full_20
- bucketName: nonScreenshot
- bucketTitle: スクショ以外
- probeMode: fullProbe
- device: iPhone
- photo authorization: authorized
- available image count: 26992
- requested count: 20
- actual count: 20
- average ms/asset: 52.8
- max ms/asset: 300.6
- failed: 0

## Timing Breakdown
- imageRequestMs avg: 18.6
- classifyImageMs avg: 11.9
- faceDetectionMs avg: 6.1
- humanDetectionMs avg: 4.0
- documentSegmentationMs avg: 4.0
- visualFeatureMs avg: 0.2
- scoringMs avg: 0.0

## Signals
- screenshots: 0
- nonScreenshots: 20
- face detected: 2
- human detected: 2
- documentSegmentationDetected: 20
- documentLabelCandidate: 4
- finalDocumentCandidate: 1
- screenshotCandidate: 0
- ocrPriorityCandidate: 0
- likely building: 0
- likely construction site: 0
- likely sign: 0
- likely food: 0
- likely whiteboard: 0
- likely receipt: 1
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
- 61731ecd6016: machine 0.23, consumer_electronics 0.23, computer 0.20, computer_monitor 0.20, television 0.18
- 1a3632a6a8e6: document 0.72, screenshot 0.72, structure 0.33, conveyance 0.33, portal 0.33
- dcec4bc4d5f1: structure 0.79, wood_processed 0.79, art 0.73, decoration 0.73, balloon 0.73
- 3af2c917b6e7: structure 0.81, wood_processed 0.81, art 0.81, decoration 0.81, balloon 0.81
- 9afe140afa20: structure 0.78, wood_processed 0.78, art 0.46, decoration 0.46, balloon 0.46
- 0d127c01a426: structure 0.72, wood_processed 0.71, furniture 0.30, table 0.30, machine 0.24
- 162612bc1d2f: document 0.43, screenshot 0.41, printed_page 0.27, art 0.02, illustrations 0.02
- 50b901b9adab: document 0.44, screenshot 0.43, printed_page 0.27, art 0.06, illustrations 0.06
- ad6953c46a81: document 0.44, printed_page 0.42, screenshot 0.30, art 0.02, illustrations 0.02
- cc1f2b9c40e1: document 0.47, screenshot 0.47, printed_page 0.13, chart 0.10, diagram 0.10

## Safety
- image bodies are not saved
- thumbnails are not saved
- face images and face templates are not saved
- Photos library assets are read only
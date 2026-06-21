# Vision Classification Benchmark

## Run
- runID: 20260621_205503_vision_probe_recent_gated_100
- bucketName: allRecent
- bucketTitle: 直近
- probeMode: gatedProbe
- device: iPhone
- photo authorization: authorized
- available image count: 26992
- requested count: 100
- actual count: 100
- average ms/asset: 7.8
- max ms/asset: 317.8
- failed: 0

## Timing Breakdown
- imageRequestMs avg: 2.2
- classifyImageMs avg: 2.0
- faceDetectionMs avg: 1.0
- humanDetectionMs avg: 0.5
- documentSegmentationMs avg: 0.6
- visualFeatureMs avg: 0.0
- scoringMs avg: 0.0

## Signals
- screenshots: 87
- nonScreenshots: 13
- face detected: 1
- human detected: 2
- documentSegmentationDetected: 13
- documentLabelCandidate: 4
- finalDocumentCandidate: 1
- screenshotCandidate: 87
- ocrPriorityCandidate: 87
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
- e14caba05d68: ラベルなし
- 2f3a806b7650: ラベルなし
- 727864643548: ラベルなし
- add127c426fd: ラベルなし
- ca3de16df96f: ラベルなし

## Safety
- image bodies are not saved
- thumbnails are not saved
- face images and face templates are not saved
- Photos library assets are read only
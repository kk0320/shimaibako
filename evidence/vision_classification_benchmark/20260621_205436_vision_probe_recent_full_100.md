# Vision Classification Benchmark

## Run
- runID: 20260621_205436_vision_probe_recent_full_100
- bucketName: allRecent
- bucketTitle: 直近
- probeMode: fullProbe
- device: iPhone
- photo authorization: authorized
- available image count: 26992
- requested count: 100
- actual count: 100
- average ms/asset: 55.1
- max ms/asset: 360.1
- failed: 0

## Timing Breakdown
- imageRequestMs avg: 12.3
- classifyImageMs avg: 26.7
- faceDetectionMs avg: 4.6
- humanDetectionMs avg: 3.8
- documentSegmentationMs avg: 3.0
- visualFeatureMs avg: 0.2
- scoringMs avg: 0.0

## Signals
- screenshots: 87
- nonScreenshots: 13
- face detected: 1
- human detected: 2
- documentSegmentationDetected: 100
- documentLabelCandidate: 87
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
- e14caba05d68: document 0.69, screenshot 0.69, printed_page 0.07, chart 0.04, diagram 0.04
- 2f3a806b7650: document 0.61, screenshot 0.61, structure 0.04, conveyance 0.04, portal 0.04
- 727864643548: document 0.50, screenshot 0.50, consumer_electronics 0.27, machine 0.27, computer 0.27
- add127c426fd: document 0.66, screenshot 0.66, printed_page 0.30, chart 0.06, diagram 0.06
- ca3de16df96f: document 0.62, screenshot 0.62, printed_page 0.11, chart 0.04, diagram 0.04

## Safety
- image bodies are not saved
- thumbnails are not saved
- face images and face templates are not saved
- Photos library assets are read only
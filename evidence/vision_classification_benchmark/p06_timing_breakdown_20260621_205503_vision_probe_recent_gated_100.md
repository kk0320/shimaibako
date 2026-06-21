# P0.6 Timing Breakdown

- runID: 20260621_205503_vision_probe_recent_gated_100
- bucket: 直近
- probeMode: gatedProbe
- actualCount: 100
- averageTotalMs: 7.8
- averageImageRequestMs: 2.2
- averageClassifyImageMs: 2.0
- averageFaceDetectionMs: 1.0
- averageHumanDetectionMs: 0.5
- averageDocumentSegmentationMs: 0.6
- averageVisualFeatureMs: 0.0
- averageScoringMs: 0.0

## Notes
- gatedProbe skips image loading and heavy Vision requests for screenshots.
- fullProbe runs image classification, face rectangles, human rectangles, document segmentation, visual metrics, and scoring.
- Images and thumbnails are not written to evidence.
# P0.6 Timing Breakdown

- runID: 20260621_205436_vision_probe_recent_full_100
- bucket: 直近
- probeMode: fullProbe
- actualCount: 100
- averageTotalMs: 55.1
- averageImageRequestMs: 12.3
- averageClassifyImageMs: 26.7
- averageFaceDetectionMs: 4.6
- averageHumanDetectionMs: 3.8
- averageDocumentSegmentationMs: 3.0
- averageVisualFeatureMs: 0.2
- averageScoringMs: 0.0

## Notes
- gatedProbe skips image loading and heavy Vision requests for screenshots.
- fullProbe runs image classification, face rectangles, human rectangles, document segmentation, visual metrics, and scoring.
- Images and thumbnails are not written to evidence.
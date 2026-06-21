# P0.6 Timing Breakdown

- runID: 20260621_210245_vision_probe_screenshot_gated_20
- bucket: スクショ
- probeMode: gatedProbe
- actualCount: 20
- averageTotalMs: 0.0
- averageImageRequestMs: 0.0
- averageClassifyImageMs: 0.0
- averageFaceDetectionMs: 0.0
- averageHumanDetectionMs: 0.0
- averageDocumentSegmentationMs: 0.0
- averageVisualFeatureMs: 0.0
- averageScoringMs: 0.0

## Notes
- gatedProbe skips image loading and heavy Vision requests for screenshots.
- fullProbe runs image classification, face rectangles, human rectangles, document segmentation, visual metrics, and scoring.
- Images and thumbnails are not written to evidence.
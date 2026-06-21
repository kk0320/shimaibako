# P0.6 Timing Breakdown

- runID: 20260621_205531_vision_probe_non_screenshot_gated_20
- bucket: スクショ以外
- probeMode: gatedProbe
- actualCount: 20
- averageTotalMs: 49.3
- averageImageRequestMs: 16.0
- averageClassifyImageMs: 11.3
- averageFaceDetectionMs: 6.0
- averageHumanDetectionMs: 4.0
- averageDocumentSegmentationMs: 3.9
- averageVisualFeatureMs: 0.2
- averageScoringMs: 0.0

## Notes
- gatedProbe skips image loading and heavy Vision requests for screenshots.
- fullProbe runs image classification, face rectangles, human rectangles, document segmentation, visual metrics, and scoring.
- Images and thumbnails are not written to evidence.
# P0.6 Timing Breakdown

- runID: 20260621_205517_vision_probe_non_screenshot_full_20
- bucket: スクショ以外
- probeMode: fullProbe
- actualCount: 20
- averageTotalMs: 52.8
- averageImageRequestMs: 18.6
- averageClassifyImageMs: 11.9
- averageFaceDetectionMs: 6.1
- averageHumanDetectionMs: 4.0
- averageDocumentSegmentationMs: 4.0
- averageVisualFeatureMs: 0.2
- averageScoringMs: 0.0

## Notes
- gatedProbe skips image loading and heavy Vision requests for screenshots.
- fullProbe runs image classification, face rectangles, human rectangles, document segmentation, visual metrics, and scoring.
- Images and thumbnails are not written to evidence.
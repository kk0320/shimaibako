# P0.6 Timing Breakdown

- runID: 20260621_205359_vision_probe_screenshot_full_20
- bucket: スクショ
- probeMode: fullProbe
- actualCount: 20
- averageTotalMs: 527.8
- averageImageRequestMs: 241.5
- averageClassifyImageMs: 30.2
- averageFaceDetectionMs: 9.0
- averageHumanDetectionMs: 3.6
- averageDocumentSegmentationMs: 3.7
- averageVisualFeatureMs: 0.2
- averageScoringMs: 0.0

## Notes
- gatedProbe skips image loading and heavy Vision requests for screenshots.
- fullProbe runs image classification, face rectangles, human rectangles, document segmentation, visual metrics, and scoring.
- Images and thumbnails are not written to evidence.
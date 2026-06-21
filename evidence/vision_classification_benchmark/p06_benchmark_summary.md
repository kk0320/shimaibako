# P0.6 Vision Classification Benchmark Summary

- generatedAt: 2026-06-21T11:56:41.731Z
- device: K Phone
- evidence source: Application Support/ShimaiBako/vision_classification_benchmark
- image bodies: not exported
- thumbnails: not exported
- face images/templates: not exported

## Timing
| bucket | mode | count | avg ms | image | classify | face | human | doc seg | visual | scoring |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| スクショ | fullProbe | 20 | 527.8 | 241.5 | 30.2 | 9.0 | 3.6 | 3.7 | 0.2 | 0.0 |
| スクショ | gatedProbe | 20 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| 直近 | fullProbe | 100 | 55.1 | 12.3 | 26.7 | 4.6 | 3.8 | 3.0 | 0.2 | 0.0 |
| 直近 | gatedProbe | 100 | 7.8 | 2.2 | 2.0 | 1.0 | 0.5 | 0.6 | 0.0 | 0.0 |
| スクショ以外 | fullProbe | 20 | 52.8 | 18.6 | 11.9 | 6.1 | 4.0 | 4.0 | 0.2 | 0.0 |
| スクショ以外 | gatedProbe | 20 | 49.3 | 16.0 | 11.3 | 6.0 | 4.0 | 3.9 | 0.2 | 0.0 |

## Signals
| bucket | mode | screenshots | finalDocument | ocrPriority | building | sign | whiteboard | receipt | businessCard | construction | labeled |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| スクショ | fullProbe | 20 | 0 | 20 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| スクショ | gatedProbe | 20 | 0 | 20 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 直近 | fullProbe | 87 | 1 | 87 | 0 | 0 | 0 | 1 | 0 | 0 | 0 |
| 直近 | gatedProbe | 87 | 1 | 87 | 0 | 0 | 0 | 1 | 0 | 0 | 0 |
| スクショ以外 | fullProbe | 0 | 1 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 0 |
| スクショ以外 | gatedProbe | 0 | 1 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 0 |

## Initial Interpretation
- gatedProbe is fastest on screenshots because it skips image loading and heavy Vision requests.
- documentSegmentation remains over-sensitive and should not drive final document classification.
- screenshot assets should be treated as OCR-priority records, not document records.
- non-screenshot full/gated are intentionally similar because P0.6 gating only short-circuits screenshots.
- manual labels were not added from CLI; the DEBUG review UI is available for 20+ labels on device.

## Ground Truth Export Smoke Check
- K Phone run: `20260621_210245_vision_probe_screenshot_gated_20`
- Exported: `p06_ground_truth_20260621_210245_vision_probe_screenshot_gated_20.json`
- labeled assets: 0
- purpose: verify that P0.6 can export the hand-label store shape without exporting image bodies, thumbnails, face images/templates, or raw asset identifiers.

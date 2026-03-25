import 'package:flutter_test/flutter_test.dart';

import 'package:note_scanner/scan_models.dart';

void main() {
  test('serializes note scan results with confidence labels', () {
    final result = NoteScanResult(
      verdict: 'Likely Real',
      summary: 'Strong OCR and image-quality matches were found.',
      confidence: 0.92,
      capturedImagePath: 'capture.jpg',
      processedImagePath: 'crop.jpg',
      extractedText: 'STATE BANK 500',
      detectedFeatures: [
        ScanFeature(
          title: 'Authority text',
          detail: 'Issuer wording was detected.',
          passed: true,
        ),
      ],
      warnings: ['Preliminary mobile scan only.'],
      scannedAt: DateTime(2026, 3, 25),
      quality: ScanQualityMetrics(
        lighting: 0.8,
        contrast: 0.7,
        sharpness: 0.9,
        uvResponse: 0.22,
      ),
      ocrAvailable: true,
      detectionMode: 'OCR + image processing',
      inspectionMode: ScanInspectionMode.standard,
    );

    expect(result.confidenceLabel, '92% confidence');

    final restored = NoteScanResult.fromJson(result.toJson());
    expect(restored.verdict, 'Likely Real');
    expect(restored.detectedFeatures.single.passed, isTrue);
    expect(restored.quality.sharpness, 0.9);
    expect(restored.inspectionMode, ScanInspectionMode.standard);
  });
}

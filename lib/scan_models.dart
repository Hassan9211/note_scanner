enum ScanInspectionMode {
  standard,
  uv,
}

ScanInspectionMode scanInspectionModeFromJson(String? value) {
  switch (value) {
    case 'uv':
      return ScanInspectionMode.uv;
    case 'standard':
    default:
      return ScanInspectionMode.standard;
  }
}

extension ScanInspectionModePresentation on ScanInspectionMode {
  String get label {
    switch (this) {
      case ScanInspectionMode.standard:
        return 'Standard';
      case ScanInspectionMode.uv:
        return 'UV Assist';
    }
  }

  String get helperText {
    switch (this) {
      case ScanInspectionMode.standard:
        return 'Place the note inside the frame, then tap Scan Note.';
      case ScanInspectionMode.uv:
        return 'Use an external UV light, keep room light low, and keep the note flat inside the frame.';
    }
  }
}

class ScanFrameSpec {
  static const double widthFactor = 0.92;
  static const double heightFactor = 0.42;
  static const double cropPaddingFactor = 0.03;
  static const double cornerRadius = 28;
}

class ScanProgress {
  const ScanProgress({
    required this.title,
    required this.detail,
    required this.progress,
  });

  final String title;
  final String detail;
  final double progress;
}

class ScanFeature {
  const ScanFeature({
    required this.title,
    required this.detail,
    required this.passed,
  });

  final String title;
  final String detail;
  final bool passed;

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'detail': detail,
      'passed': passed,
    };
  }

  factory ScanFeature.fromJson(Map<String, dynamic> json) {
    return ScanFeature(
      title: json['title'] as String? ?? 'Unknown feature',
      detail: json['detail'] as String? ?? '',
      passed: json['passed'] as bool? ?? false,
    );
  }
}

class ScanQualityMetrics {
  const ScanQualityMetrics({
    required this.lighting,
    required this.contrast,
    required this.sharpness,
    this.uvResponse = 0,
  });

  final double lighting;
  final double contrast;
  final double sharpness;
  final double uvResponse;

  ScanQualityMetrics copyWith({
    double? lighting,
    double? contrast,
    double? sharpness,
    double? uvResponse,
  }) {
    return ScanQualityMetrics(
      lighting: lighting ?? this.lighting,
      contrast: contrast ?? this.contrast,
      sharpness: sharpness ?? this.sharpness,
      uvResponse: uvResponse ?? this.uvResponse,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'lighting': lighting,
      'contrast': contrast,
      'sharpness': sharpness,
      'uvResponse': uvResponse,
    };
  }

  factory ScanQualityMetrics.fromJson(Map<String, dynamic> json) {
    return ScanQualityMetrics(
      lighting: (json['lighting'] as num?)?.toDouble() ?? 0,
      contrast: (json['contrast'] as num?)?.toDouble() ?? 0,
      sharpness: (json['sharpness'] as num?)?.toDouble() ?? 0,
      uvResponse: (json['uvResponse'] as num?)?.toDouble() ?? 0,
    );
  }
}

class NoteScanResult {
  const NoteScanResult({
    required this.verdict,
    required this.summary,
    required this.confidence,
    required this.capturedImagePath,
    required this.processedImagePath,
    required this.extractedText,
    required this.detectedFeatures,
    required this.warnings,
    required this.scannedAt,
    required this.quality,
    required this.ocrAvailable,
    required this.detectionMode,
    required this.inspectionMode,
  });

  final String verdict;
  final String summary;
  final double confidence;
  final String capturedImagePath;
  final String processedImagePath;
  final String extractedText;
  final List<ScanFeature> detectedFeatures;
  final List<String> warnings;
  final DateTime scannedAt;
  final ScanQualityMetrics quality;
  final bool ocrAvailable;
  final String detectionMode;
  final ScanInspectionMode inspectionMode;

  String get confidenceLabel => '${(confidence * 100).round()}% confidence';

  Map<String, dynamic> toJson() {
    return {
      'verdict': verdict,
      'summary': summary,
      'confidence': confidence,
      'capturedImagePath': capturedImagePath,
      'processedImagePath': processedImagePath,
      'extractedText': extractedText,
      'detectedFeatures': detectedFeatures.map((item) => item.toJson()).toList(),
      'warnings': warnings,
      'scannedAt': scannedAt.toIso8601String(),
      'quality': quality.toJson(),
      'ocrAvailable': ocrAvailable,
      'detectionMode': detectionMode,
      'inspectionMode': inspectionMode.name,
    };
  }

  factory NoteScanResult.fromJson(Map<String, dynamic> json) {
    final rawFeatures = json['detectedFeatures'] as List<dynamic>? ?? const [];
    final rawWarnings = json['warnings'] as List<dynamic>? ?? const [];

    return NoteScanResult(
      verdict: json['verdict'] as String? ?? 'Needs Review',
      summary: json['summary'] as String? ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      capturedImagePath: json['capturedImagePath'] as String? ?? '',
      processedImagePath: json['processedImagePath'] as String? ?? '',
      extractedText: json['extractedText'] as String? ?? '',
      detectedFeatures: rawFeatures
          .map(
            (item) => ScanFeature.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
      warnings: rawWarnings.map((item) => item.toString()).toList(),
      scannedAt: DateTime.tryParse(json['scannedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      quality: ScanQualityMetrics.fromJson(
        Map<String, dynamic>.from((json['quality'] as Map?) ?? const {}),
      ),
      ocrAvailable: json['ocrAvailable'] as bool? ?? false,
      detectionMode: json['detectionMode'] as String? ?? 'Image processing only',
      inspectionMode: scanInspectionModeFromJson(
        json['inspectionMode'] as String?,
      ),
    );
  }
}

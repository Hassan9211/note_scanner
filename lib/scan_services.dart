import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'scan_models.dart';

typedef ScanProgressCallback = void Function(ScanProgress progress);

class ScanHistoryStore {
  ScanHistoryStore._({required this.preferences, required this.rootDirectory});

  static const _historyKey = 'note_scan_history_v2';

  final SharedPreferences preferences;
  final Directory rootDirectory;

  static Future<ScanHistoryStore> create() async {
    final preferences = await SharedPreferences.getInstance();
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final rootDirectory = Directory(
      p.join(documentsDirectory.path, 'note_scan_history'),
    );
    await rootDirectory.create(recursive: true);

    return ScanHistoryStore._(
      preferences: preferences,
      rootDirectory: rootDirectory,
    );
  }

  Future<String> persistCapture(String sourcePath) async {
    final extension = p.extension(sourcePath).isEmpty
        ? '.jpg'
        : p.extension(sourcePath);
    final targetPath = p.join(
      rootDirectory.path,
      'capture_${DateTime.now().microsecondsSinceEpoch}$extension',
    );

    await File(sourcePath).copy(targetPath);
    return targetPath;
  }

  Future<List<NoteScanResult>> loadHistory() async {
    final raw = preferences.getString(_historyKey);
    if (raw == null || raw.isEmpty) {
      return const [];
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map(
            (item) =>
                NoteScanResult.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<NoteScanResult>> save(NoteScanResult result) async {
    final existing = await loadHistory();
    final next = <NoteScanResult>[
      result,
      ...existing.where(
        (item) => item.capturedImagePath != result.capturedImagePath,
      ),
    ];
    final trimmed = next.take(12).toList();
    final removed = next.skip(12).toList();

    await preferences.setString(
      _historyKey,
      jsonEncode(trimmed.map((item) => item.toJson()).toList()),
    );

    await _cleanupFiles(removed);
    return trimmed;
  }

  Future<void> _cleanupFiles(List<NoteScanResult> removed) async {
    for (final item in removed) {
      await _deleteIfManaged(item.capturedImagePath);
      await _deleteIfManaged(item.processedImagePath);
    }
  }

  Future<void> _deleteIfManaged(String filePath) async {
    if (filePath.isEmpty) {
      return;
    }

    final normalizedRoot = p.normalize(rootDirectory.path);
    final normalizedFile = p.normalize(filePath);
    if (!p.isWithin(normalizedRoot, normalizedFile)) {
      return;
    }

    final file = File(filePath);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

class NoteScanAnalyzer {
  NoteScanAnalyzer()
    : _textRecognizer = Platform.isAndroid || Platform.isIOS
          ? TextRecognizer(script: TextRecognitionScript.latin)
          : null;

  final TextRecognizer? _textRecognizer;

  Future<NoteScanResult> analyze({
    required String imagePath,
    required ScanInspectionMode mode,
    ScanProgressCallback? onProgress,
  }) async {
    onProgress?.call(
      ScanProgress(
        title: mode == ScanInspectionMode.uv
            ? 'Preparing UV frame...'
            : 'Preparing image...',
        detail: mode == ScanInspectionMode.uv
            ? 'Cropping the note frame for focused UV fluorescence analysis.'
            : 'Cropping the note frame for focused processing.',
        progress: 0.3,
      ),
    );

    final bytes = await File(imagePath).readAsBytes();
    final decoded = img.decodeImage(bytes);

    if (decoded == null) {
      return NoteScanResult(
        verdict: 'Poor Capture',
        summary:
            'The image could not be decoded, so the scan stopped before OCR.',
        confidence: 0.12,
        capturedImagePath: imagePath,
        processedImagePath: imagePath,
        extractedText: '',
        detectedFeatures: const [
          ScanFeature(
            title: 'Image decode',
            detail: 'The captured file could not be opened for analysis.',
            passed: false,
          ),
        ],
        warnings: const [
          'Try another capture and keep the note steady inside the frame.',
        ],
        scannedAt: DateTime.now(),
        quality: const ScanQualityMetrics(
          lighting: 0,
          contrast: 0,
          sharpness: 0,
        ),
        ocrAvailable: false,
        detectionMode: mode == ScanInspectionMode.uv
            ? 'UV assist image processing'
            : 'Image processing only',
        inspectionMode: mode,
      );
    }

    final crop = _buildCropBox(decoded);
    final processed = img.copyCrop(
      decoded,
      x: crop.left,
      y: crop.top,
      width: crop.width,
      height: crop.height,
      radius: ScanFrameSpec.cornerRadius,
    );

    final processedImagePath = p.join(
      File(imagePath).parent.path,
      'crop_${p.basenameWithoutExtension(imagePath)}.jpg',
    );
    await File(
      processedImagePath,
    ).writeAsBytes(img.encodeJpg(processed, quality: 90));

    onProgress?.call(
      ScanProgress(
        title: mode == ScanInspectionMode.uv
            ? 'Checking UV capture quality...'
            : 'Checking image quality...',
        detail: mode == ScanInspectionMode.uv
            ? 'Scoring sharpness, contrast, and dark-field separation in the note zone.'
            : 'Scoring lighting, contrast, and sharpness in the note zone.',
        progress: 0.5,
      ),
    );

    var quality = _measureQuality(processed);
    _UvSignalMetrics? uvSignals;

    if (mode == ScanInspectionMode.uv) {
      onProgress?.call(
        const ScanProgress(
          title: 'Analyzing UV response...',
          detail:
              'Looking for localized fluorescence-style glow inside the note frame.',
          progress: 0.64,
        ),
      );
      uvSignals = _measureUvSignals(processed);
      quality = quality.copyWith(uvResponse: uvSignals.response);
    }

    onProgress?.call(
      ScanProgress(
        title: mode == ScanInspectionMode.uv
            ? 'Cross-checking visible print...'
            : 'Running OCR...',
        detail: mode == ScanInspectionMode.uv
            ? 'Reading any visible print to support the UV pass.'
            : 'Reading printed note details with ML Kit when available.',
        progress: mode == ScanInspectionMode.uv ? 0.76 : 0.68,
      ),
    );

    final ocrData = await _readText(processedImagePath);

    onProgress?.call(
      ScanProgress(
        title: 'Scoring features...',
        detail: mode == ScanInspectionMode.uv
            ? 'Combining UV response, visible print, and capture quality.'
            : 'Combining OCR evidence with image-quality signals.',
        progress: 0.88,
      ),
    );

    final normalizedText = ocrData.text.toLowerCase().replaceAll('\n', ' ');
    final hasAuthorityKeyword = _containsAny(normalizedText, const [
      'bank',
      'reserve bank',
      'state bank',
      'central bank',
      'federal reserve',
    ]);
    final hasCurrencyKeyword = _containsAny(normalizedText, const [
      'rupees',
      'rupee',
      'dollars',
      'dollar',
      'pkr',
      'usd',
      'inr',
      'eur',
      'pounds',
      'currency',
      'note',
    ]);
    final hasDenomination = RegExp(
      r'\b(5|10|20|50|100|200|500|1000|2000|5000)\b',
    ).hasMatch(normalizedText);
    final hasSerialPattern = RegExp(
      r'\b[a-z]{0,2}\d{5,}\b',
      caseSensitive: false,
    ).hasMatch(normalizedText);

    final hasCurrencyCue = hasCurrencyKeyword || hasDenomination;
    final hasReadableText = ocrData.available && normalizedText.length >= 12;
    final readableTextScore = ocrData.available
        ? (normalizedText.length / 44).clamp(0.0, 1.0)
        : 0.0;

    if (mode == ScanInspectionMode.uv) {
      final uvMetrics = uvSignals ?? const _UvSignalMetrics.fallback();
      final visibleCuePassed =
          hasReadableText ||
          hasAuthorityKeyword ||
          hasCurrencyCue ||
          hasSerialPattern;
      final captureQuality =
          (quality.contrast * 0.36) +
          (quality.sharpness * 0.36) +
          (uvMetrics.darkField * 0.28);
      final passedSignalCount = <bool>[
        quality.contrast >= 0.4,
        quality.sharpness >= 0.44,
        uvMetrics.response >= 0.62,
        uvMetrics.darkField >= 0.52,
        uvMetrics.patternBalance >= 0.52,
        !uvMetrics.overglow,
        visibleCuePassed,
      ].where((value) => value).length;
      final uvSecurityGatePassed =
          uvMetrics.response >= 0.68 &&
          uvMetrics.darkField >= 0.56 &&
          uvMetrics.patternBalance >= 0.56 &&
          !uvMetrics.overglow &&
          quality.sharpness >= 0.44 &&
          quality.contrast >= 0.38 &&
          visibleCuePassed;

      double confidence = 0.08;
      confidence += quality.contrast * 0.12;
      confidence += quality.sharpness * 0.12;
      confidence += uvMetrics.response * 0.26;
      confidence += uvMetrics.darkField * 0.1;
      confidence += uvMetrics.patternBalance * 0.14;
      confidence += visibleCuePassed ? 0.08 : -0.06;
      confidence += hasReadableText ? 0.05 : 0;
      confidence += hasAuthorityKeyword ? 0.04 : -0.02;
      confidence += hasCurrencyCue ? 0.04 : -0.02;
      confidence += hasSerialPattern ? 0.06 : -0.04;

      if (uvMetrics.overglow) {
        confidence -= 0.24;
      }
      if (quality.sharpness < 0.38) {
        confidence -= 0.08;
      }
      if (quality.contrast < 0.34) {
        confidence -= 0.08;
      }
      if (!ocrData.available) {
        confidence -= 0.04;
      }

      var clampedConfidence = confidence.clamp(0.02, 0.95);
      if (uvMetrics.overglow) {
        clampedConfidence = math.min(clampedConfidence, 0.34);
      }
      if (!visibleCuePassed) {
        clampedConfidence = math.min(clampedConfidence, 0.64);
      }
      if (uvMetrics.response < 0.62) {
        clampedConfidence = math.min(clampedConfidence, 0.56);
      }
      if (uvMetrics.darkField < 0.52) {
        clampedConfidence = math.min(clampedConfidence, 0.54);
      }
      if (uvMetrics.patternBalance < 0.52) {
        clampedConfidence = math.min(clampedConfidence, 0.58);
      }
      if (!uvSecurityGatePassed) {
        clampedConfidence = math.min(clampedConfidence, 0.76);
      }

      final verdict = _buildUvVerdict(
        confidence: clampedConfidence,
        captureQuality: captureQuality,
        passedSignalCount: passedSignalCount,
        visibleCuePassed: visibleCuePassed,
        quality: quality,
        uvMetrics: uvMetrics,
        uvSecurityGatePassed: uvSecurityGatePassed,
      );

      final features = _buildUvFeatures(
        quality: quality,
        ocrAvailable: ocrData.available,
        hasReadableText: hasReadableText,
        visibleCuePassed: visibleCuePassed,
        uvMetrics: uvMetrics,
        uvSecurityGatePassed: uvSecurityGatePassed,
      );

      final warnings = _buildUvWarnings(
        quality: quality,
        verdict: verdict,
        ocrWarning: ocrData.warning,
        ocrAvailable: ocrData.available,
        visibleCuePassed: visibleCuePassed,
        uvMetrics: uvMetrics,
      );

      return NoteScanResult(
        verdict: verdict,
        summary: _buildUvSummary(verdict),
        confidence: clampedConfidence,
        capturedImagePath: imagePath,
        processedImagePath: processedImagePath,
        extractedText: _condenseText(ocrData.text),
        detectedFeatures: features,
        warnings: warnings,
        scannedAt: DateTime.now(),
        quality: quality,
        ocrAvailable: ocrData.available,
        detectionMode: ocrData.available
            ? 'UV assist + OCR + image processing'
            : 'UV assist image processing',
        inspectionMode: mode,
      );
    }

    final averageQuality =
        (quality.lighting + quality.contrast + quality.sharpness) / 3;
    final passedSignalCount = <bool>[
      quality.lighting >= 0.55,
      quality.contrast >= 0.52,
      quality.sharpness >= 0.48,
      hasReadableText,
      hasAuthorityKeyword,
      hasCurrencyCue,
      hasSerialPattern,
    ].where((value) => value).length;
    final highSecurityGatePassed =
        hasReadableText &&
        hasAuthorityKeyword &&
        hasCurrencyCue &&
        hasSerialPattern &&
        averageQuality >= 0.62;

    double confidence = 0.05;
    confidence += quality.lighting * 0.14;
    confidence += quality.contrast * 0.14;
    confidence += quality.sharpness * 0.14;
    confidence += readableTextScore * 0.16;
    confidence += hasReadableText ? 0.12 : -0.08;
    confidence += hasAuthorityKeyword ? 0.12 : -0.08;
    confidence += hasCurrencyCue ? 0.1 : -0.1;
    confidence += hasSerialPattern ? 0.12 : -0.12;

    if (!ocrData.available) {
      confidence -= 0.18;
    }
    if (averageQuality < 0.5) {
      confidence -= 0.08;
    }
    if (normalizedText.length < 8) {
      confidence -= 0.1;
    }

    var clampedConfidence = confidence.clamp(0.02, 0.97);
    if (!hasReadableText || !ocrData.available) {
      clampedConfidence = math.min(clampedConfidence, 0.48);
    }
    if (!hasAuthorityKeyword) {
      clampedConfidence = math.min(clampedConfidence, 0.56);
    }
    if (!hasCurrencyCue) {
      clampedConfidence = math.min(clampedConfidence, 0.52);
    }
    if (!hasSerialPattern) {
      clampedConfidence = math.min(clampedConfidence, 0.58);
    }
    if (!highSecurityGatePassed) {
      clampedConfidence = math.min(clampedConfidence, 0.74);
    }

    final verdict = _buildStandardVerdict(
      confidence: clampedConfidence,
      averageQuality: averageQuality,
      ocrAvailable: ocrData.available,
      hasReadableText: hasReadableText,
      hasAuthorityKeyword: hasAuthorityKeyword,
      hasCurrencyCue: hasCurrencyCue,
      hasSerialPattern: hasSerialPattern,
      passedSignalCount: passedSignalCount,
      highSecurityGatePassed: highSecurityGatePassed,
    );

    final features = _buildStandardFeatures(
      quality: quality,
      ocrAvailable: ocrData.available,
      hasReadableText: hasReadableText,
      hasAuthorityKeyword: hasAuthorityKeyword,
      hasCurrencyCue: hasCurrencyCue,
      hasSerialPattern: hasSerialPattern,
      highSecurityGatePassed: highSecurityGatePassed,
    );

    final warnings = _buildStandardWarnings(
      quality: quality,
      verdict: verdict,
      ocrWarning: ocrData.warning,
      ocrAvailable: ocrData.available,
      hasReadableText: hasReadableText,
      hasAuthorityKeyword: hasAuthorityKeyword,
      hasCurrencyCue: hasCurrencyCue,
      hasSerialPattern: hasSerialPattern,
    );

    return NoteScanResult(
      verdict: verdict,
      summary: _buildStandardSummary(verdict),
      confidence: clampedConfidence,
      capturedImagePath: imagePath,
      processedImagePath: processedImagePath,
      extractedText: _condenseText(ocrData.text),
      detectedFeatures: features,
      warnings: warnings,
      scannedAt: DateTime.now(),
      quality: quality,
      ocrAvailable: ocrData.available,
      detectionMode: ocrData.available
          ? 'High-security OCR + image processing'
          : 'High-security image processing only',
      inspectionMode: mode,
    );
  }

  void dispose() {
    _textRecognizer?.close();
  }

  String _buildStandardVerdict({
    required double confidence,
    required double averageQuality,
    required bool ocrAvailable,
    required bool hasReadableText,
    required bool hasAuthorityKeyword,
    required bool hasCurrencyCue,
    required bool hasSerialPattern,
    required int passedSignalCount,
    required bool highSecurityGatePassed,
  }) {
    if (averageQuality < 0.38) {
      return 'Poor Capture';
    }
    if (highSecurityGatePassed &&
        ocrAvailable &&
        confidence >= 0.88 &&
        passedSignalCount >= 6) {
      return 'Likely Real';
    }
    if (!hasReadableText ||
        !hasAuthorityKeyword ||
        !hasCurrencyCue ||
        !hasSerialPattern) {
      if (confidence <= 0.4 || passedSignalCount <= 2) {
        return 'Likely Fake';
      }
      return 'Needs Review';
    }
    if (confidence >= 0.6 && passedSignalCount >= 4) {
      return 'Needs Review';
    }
    return confidence <= 0.4 ? 'Likely Fake' : 'Needs Review';
  }

  List<ScanFeature> _buildStandardFeatures({
    required ScanQualityMetrics quality,
    required bool ocrAvailable,
    required bool hasReadableText,
    required bool hasAuthorityKeyword,
    required bool hasCurrencyCue,
    required bool hasSerialPattern,
    required bool highSecurityGatePassed,
  }) {
    return [
      ScanFeature(
        title: 'Lighting balance',
        detail: quality.lighting >= 0.55
            ? 'Exposure looks stable inside the frame.'
            : 'The note area is too dark or too bright for a strong read.',
        passed: quality.lighting >= 0.55,
      ),
      ScanFeature(
        title: 'Contrast check',
        detail: quality.contrast >= 0.52
            ? 'Printed details stand out well from the background.'
            : 'Printed details blend together, which weakens confidence.',
        passed: quality.contrast >= 0.52,
      ),
      ScanFeature(
        title: 'Sharpness check',
        detail: quality.sharpness >= 0.48
            ? 'Edges look sharp enough for OCR and feature scoring.'
            : 'Blur reduced the quality of the scan frame.',
        passed: quality.sharpness >= 0.48,
      ),
      ScanFeature(
        title: 'Readable note text',
        detail: ocrAvailable
            ? (hasReadableText
                  ? 'OCR found enough printed characters to trust the read more.'
                  : 'OCR ran, but it could not read enough text.')
            : 'OCR is unavailable on this platform, so only image checks ran.',
        passed: hasReadableText,
      ),
      ScanFeature(
        title: 'Authority or issuer text',
        detail: hasAuthorityKeyword
            ? 'The scan found bank-style issuer wording.'
            : 'No strong issuer wording was confirmed.',
        passed: hasAuthorityKeyword,
      ),
      ScanFeature(
        title: 'Currency or denomination cues',
        detail: hasCurrencyCue
            ? 'Currency wording or denomination numbers were detected.'
            : 'Currency wording and denomination cues were weak.',
        passed: hasCurrencyCue,
      ),
      ScanFeature(
        title: 'Serial-style pattern',
        detail: hasSerialPattern
            ? 'A serial-number style pattern was detected.'
            : 'No clear serial-style pattern was detected in OCR.',
        passed: hasSerialPattern,
      ),
      ScanFeature(
        title: 'High-security gate',
        detail: highSecurityGatePassed
            ? 'Essential note cues all passed the stricter security gate.'
            : 'One or more essential note cues failed, so the scan stayed conservative.',
        passed: highSecurityGatePassed,
      ),
    ];
  }

  List<String> _buildStandardWarnings({
    required ScanQualityMetrics quality,
    required String verdict,
    required String? ocrWarning,
    required bool ocrAvailable,
    required bool hasReadableText,
    required bool hasAuthorityKeyword,
    required bool hasCurrencyCue,
    required bool hasSerialPattern,
  }) {
    final warnings = <String>[];

    if (!ocrAvailable && ocrWarning != null) {
      warnings.add(ocrWarning);
    }
    if (!hasReadableText) {
      warnings.add(
        'High-security mode did not get enough reliable text from the note.',
      );
    }
    if (!hasAuthorityKeyword) {
      warnings.add(
        'Issuer or bank wording was not confirmed, so the result was downgraded.',
      );
    }
    if (!hasCurrencyCue) {
      warnings.add(
        'Denomination or currency wording was too weak for a secure pass.',
      );
    }
    if (!hasSerialPattern) {
      warnings.add(
        'A serial-style pattern was not detected, which is a strong negative signal.',
      );
    }
    if (quality.lighting < 0.45) {
      warnings.add('Try brighter, more even light or switch the flash on.');
    }
    if (quality.sharpness < 0.42) {
      warnings.add(
        'Hold the phone steady and keep the note flat inside the frame.',
      );
    }
    if (verdict == 'Likely Fake') {
      warnings.add(
        'This pass found too few matching note cues. Use manual verification before trusting the result.',
      );
    }

    return warnings;
  }

  String _buildStandardSummary(String verdict) {
    switch (verdict) {
      case 'Likely Real':
        return 'High-security checks found strong OCR, serial-style, issuer, and quality matches. This is stricter than before, but still not forensic verification.';
      case 'Likely Fake':
        return 'High-security mode found missing essential note cues, so the scan treated this note as suspicious. Re-scan once, then verify manually.';
      case 'Poor Capture':
        return 'The framed note area was too weak for a confident decision. Re-scan with steadier hands, better light, or flash enabled.';
      default:
        return 'High-security mode blocked a real verdict because one or more essential note cues were weak. A second scan or manual verification is recommended.';
    }
  }

  String _buildUvVerdict({
    required double confidence,
    required double captureQuality,
    required int passedSignalCount,
    required bool visibleCuePassed,
    required ScanQualityMetrics quality,
    required _UvSignalMetrics uvMetrics,
    required bool uvSecurityGatePassed,
  }) {
    if (captureQuality < 0.32 || quality.sharpness < 0.26) {
      return 'Poor Capture';
    }
    if (uvSecurityGatePassed && confidence >= 0.86 && passedSignalCount >= 6) {
      return 'Likely Real';
    }
    if (uvMetrics.overglow ||
        uvMetrics.response < 0.42 ||
        passedSignalCount <= 2) {
      return 'Likely Fake';
    }
    if (!visibleCuePassed ||
        uvMetrics.response < 0.62 ||
        uvMetrics.darkField < 0.52 ||
        uvMetrics.patternBalance < 0.52) {
      return confidence <= 0.44 ? 'Likely Fake' : 'Needs Review';
    }
    return confidence >= 0.6 ? 'Needs Review' : 'Likely Fake';
  }

  List<ScanFeature> _buildUvFeatures({
    required ScanQualityMetrics quality,
    required bool ocrAvailable,
    required bool hasReadableText,
    required bool visibleCuePassed,
    required _UvSignalMetrics uvMetrics,
    required bool uvSecurityGatePassed,
  }) {
    final coveragePercent = (uvMetrics.hotspotCoverage * 100).round();
    return [
      ScanFeature(
        title: 'UV fluorescence response',
        detail: uvMetrics.response >= 0.62
            ? 'Localized glow reacted strongly under UV assist.'
            : 'Fluorescence response was weak for a secure UV pass.',
        passed: uvMetrics.response >= 0.62,
      ),
      ScanFeature(
        title: 'Dark-field separation',
        detail: uvMetrics.darkField >= 0.52
            ? 'The frame stayed dark enough for UV marks to stand out.'
            : 'Ambient light was too strong, so UV marks may be washed out.',
        passed: uvMetrics.darkField >= 0.52,
      ),
      ScanFeature(
        title: 'Localized glow pattern',
        detail: uvMetrics.patternBalance >= 0.52
            ? 'Bright response stayed localized at about $coveragePercent% of the frame.'
            : 'UV glow was too sparse or too spread out at about $coveragePercent% coverage.',
        passed: uvMetrics.patternBalance >= 0.52,
      ),
      ScanFeature(
        title: 'Overglow check',
        detail: uvMetrics.overglow
            ? 'Too much of the frame glowed evenly, which is suspicious.'
            : 'Glow stayed controlled instead of flooding the whole note.',
        passed: !uvMetrics.overglow,
      ),
      ScanFeature(
        title: 'Visible print cross-check',
        detail: ocrAvailable
            ? (visibleCuePassed
                  ? 'Visible print or serial cues supported the UV pass.'
                  : 'UV glow appeared without enough visible print support.')
            : 'OCR support is unavailable here, so UV confidence stays more conservative.',
        passed: visibleCuePassed,
      ),
      ScanFeature(
        title: 'Readable text under UV',
        detail: hasReadableText
            ? 'The camera still resolved enough printed characters in UV mode.'
            : 'Readable text was limited in UV mode, so the pass stayed stricter.',
        passed: hasReadableText,
      ),
      ScanFeature(
        title: 'Sharpness under UV',
        detail: quality.sharpness >= 0.44
            ? 'Edges stayed sharp enough to read UV response cleanly.'
            : 'Blur softened bright security marks and reduced confidence.',
        passed: quality.sharpness >= 0.44,
      ),
      ScanFeature(
        title: 'UV security gate',
        detail: uvSecurityGatePassed
            ? 'UV response, dark field, and visible cues all passed together.'
            : 'One or more UV gate checks failed, so the result stayed conservative.',
        passed: uvSecurityGatePassed,
      ),
    ];
  }

  List<String> _buildUvWarnings({
    required ScanQualityMetrics quality,
    required String verdict,
    required String? ocrWarning,
    required bool ocrAvailable,
    required bool visibleCuePassed,
    required _UvSignalMetrics uvMetrics,
  }) {
    final warnings = <String>[];

    if (!ocrAvailable && ocrWarning != null) {
      warnings.add(ocrWarning);
    }
    if (uvMetrics.darkField < 0.52) {
      warnings.add(
        'Dim the room lights and use only the external UV lamp for a cleaner fluorescence read.',
      );
    }
    if (uvMetrics.patternBalance < 0.52) {
      warnings.add(
        'UV fluorescence was either too weak or too evenly spread across the note.',
      );
    }
    if (uvMetrics.overglow) {
      warnings.add(
        'Too much of the note glowed uniformly. That can mean ambient-light contamination or suspicious paper.',
      );
    }
    if (!visibleCuePassed) {
      warnings.add(
        'UV mode still needs some visible print or serial cue so fluorescence alone is not over-trusted.',
      );
    }
    if (quality.sharpness < 0.42) {
      warnings.add(
        'Hold the phone steady even in UV mode so bright security marks stay crisp.',
      );
    }
    if (verdict == 'Likely Fake') {
      warnings.add(
        'This UV pass found suspicious fluorescence behavior. Re-scan once, then verify with manual UV checks.',
      );
    }

    return warnings;
  }

  String _buildUvSummary(String verdict) {
    switch (verdict) {
      case 'Likely Real':
        return 'UV assist found controlled fluorescence, dark-field separation, and supporting visible note cues. This still requires an external UV lamp and is not forensic verification.';
      case 'Likely Fake':
        return 'UV assist saw suspicious fluorescence behavior or an even full-note glow, so the note stayed flagged as suspicious. Re-scan once, then verify manually.';
      case 'Poor Capture':
        return 'UV assist could not get a clean dark-field image. Lower room light, use an external UV lamp, and keep the phone steady.';
      default:
        return 'UV assist found some response, but not enough controlled note cues for a secure pass. Try a darker setup or manual UV verification.';
    }
  }

  _CropBox _buildCropBox(img.Image image) {
    final width = math.max(
      1,
      (image.width *
              (ScanFrameSpec.widthFactor + ScanFrameSpec.cropPaddingFactor))
          .round(),
    );
    final height = math.max(
      1,
      (image.height *
              (ScanFrameSpec.heightFactor + ScanFrameSpec.cropPaddingFactor))
          .round(),
    );
    final left = ((image.width - width) / 2).round().clamp(0, image.width - 1);
    final top = ((image.height - height) / 2).round().clamp(
      0,
      image.height - 1,
    );

    return _CropBox(
      left: left,
      top: top,
      width: math.min(width, image.width - left),
      height: math.min(height, image.height - top),
    );
  }

  ScanQualityMetrics _measureQuality(img.Image image) {
    final step = math.max(1, math.min(image.width, image.height) ~/ 120);
    double total = 0;
    double totalSquared = 0;
    double edge = 0;
    var samples = 0;

    for (var y = 0; y < image.height; y += step) {
      double? previousInRow;
      for (var x = 0; x < image.width; x += step) {
        final pixel = image.getPixel(x, y);
        final double luminance = pixel.luminanceNormalized * 255.0;

        total += luminance;
        totalSquared += luminance * luminance;
        samples++;

        if (previousInRow != null) {
          edge += (luminance - previousInRow).abs();
        }

        if (y >= step) {
          final double upperLuminance =
              image.getPixel(x, y - step).luminanceNormalized * 255.0;
          edge += (luminance - upperLuminance).abs();
        }

        previousInRow = luminance;
      }
    }

    final mean = total / math.max(1, samples);
    final variance = math.max(
      0,
      (totalSquared / math.max(1, samples)) - (mean * mean),
    );
    final deviation = math.sqrt(variance);
    final lighting = (1 - ((mean - 145).abs() / 145)).clamp(0.0, 1.0);
    final contrast = (deviation / 64).clamp(0.0, 1.0);
    final sharpness = ((edge / math.max(1, samples)) / 46).clamp(0.0, 1.0);

    return ScanQualityMetrics(
      lighting: lighting,
      contrast: contrast,
      sharpness: sharpness,
    );
  }

  _UvSignalMetrics _measureUvSignals(img.Image image) {
    final step = math.max(1, math.min(image.width, image.height) ~/ 140);
    double hotspotLuminanceTotal = 0;
    double backgroundLuminanceTotal = 0;
    var hotspotCount = 0;
    var backgroundCount = 0;
    var tintedHotspotCount = 0;
    var darkCount = 0;
    var samples = 0;

    for (var y = 0; y < image.height; y += step) {
      for (var x = 0; x < image.width; x += step) {
        final pixel = image.getPixel(x, y);
        final luminance = pixel.luminanceNormalized;
        final red = pixel.rNormalized;
        final green = pixel.gNormalized;
        final blue = pixel.bNormalized;
        final maxChannel = math.max(red, math.max(green, blue));
        final minChannel = math.min(red, math.min(green, blue));
        final saturation = maxChannel == 0
            ? 0.0
            : (maxChannel - minChannel) / maxChannel;
        final tinted = (blue - red) >= 0.08 || (green - red) >= 0.08;
        final hotspot = luminance >= 0.72 && saturation >= 0.18;

        if (luminance <= 0.42) {
          darkCount++;
        }
        if (hotspot) {
          hotspotCount++;
          hotspotLuminanceTotal += luminance;
          if (tinted) {
            tintedHotspotCount++;
          }
        } else {
          backgroundCount++;
          backgroundLuminanceTotal += luminance;
        }
        samples++;
      }
    }

    final hotspotCoverage = hotspotCount / math.max(1, samples);
    final darkField = (darkCount / math.max(1, samples)).clamp(0.0, 1.0);
    final tintStrength = (tintedHotspotCount / math.max(1, hotspotCount)).clamp(
      0.0,
      1.0,
    );
    final hotspotMean = hotspotCount == 0
        ? 0.0
        : hotspotLuminanceTotal / hotspotCount;
    final backgroundMean = backgroundCount == 0
        ? 0.0
        : backgroundLuminanceTotal / backgroundCount;
    final contrastGap = ((hotspotMean - backgroundMean) / 0.55).clamp(0.0, 1.0);
    final coverageScore = (1 - ((hotspotCoverage - 0.08).abs() / 0.08)).clamp(
      0.0,
      1.0,
    );
    final darkFieldScore = (darkField / 0.6).clamp(0.0, 1.0);
    final patternBalance =
        ((coverageScore * 0.55) + (contrastGap * 0.25) + (tintStrength * 0.2))
            .clamp(0.0, 1.0);
    final overglow =
        hotspotCoverage > 0.24 ||
        (hotspotCoverage > 0.16 && darkField < 0.3) ||
        backgroundMean > 0.58;
    final response =
        ((contrastGap * 0.4) +
                (coverageScore * 0.25) +
                (tintStrength * 0.2) +
                (darkFieldScore * 0.15))
            .clamp(0.0, 1.0);

    return _UvSignalMetrics(
      response: response,
      darkField: darkFieldScore,
      patternBalance: patternBalance,
      hotspotCoverage: hotspotCoverage,
      overglow: overglow,
    );
  }

  Future<_OcrData> _readText(String processedImagePath) async {
    final recognizer = _textRecognizer;
    if (recognizer == null) {
      return const _OcrData(
        text: '',
        available: false,
        warning:
            'ML Kit OCR runs on Android and iOS only, so confidence is capped here.',
      );
    }

    try {
      final inputImage = InputImage.fromFilePath(processedImagePath);
      final recognized = await recognizer.processImage(inputImage);
      return _OcrData(text: recognized.text.trim(), available: true);
    } on MissingPluginException {
      return const _OcrData(
        text: '',
        available: false,
        warning:
            'OCR plugin is unavailable on this platform, so only image checks were used.',
      );
    } catch (_) {
      return const _OcrData(
        text: '',
        available: false,
        warning:
            'OCR could not finish for this scan. The result used image processing only.',
      );
    }
  }

  bool _containsAny(String source, List<String> candidates) {
    for (final candidate in candidates) {
      if (source.contains(candidate)) {
        return true;
      }
    }
    return false;
  }

  String _condenseText(String source) {
    final compact = source.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= 140) {
      return compact;
    }

    return '${compact.substring(0, 140)}...';
  }
}

class _CropBox {
  const _CropBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final int left;
  final int top;
  final int width;
  final int height;
}

class _OcrData {
  const _OcrData({required this.text, required this.available, this.warning});

  final String text;
  final bool available;
  final String? warning;
}

class _UvSignalMetrics {
  const _UvSignalMetrics({
    required this.response,
    required this.darkField,
    required this.patternBalance,
    required this.hotspotCoverage,
    required this.overglow,
  });

  const _UvSignalMetrics.fallback()
    : response = 0,
      darkField = 0,
      patternBalance = 0,
      hotspotCoverage = 0,
      overglow = false;

  final double response;
  final double darkField;
  final double patternBalance;
  final double hotspotCoverage;
  final bool overglow;
}

import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';

import 'scan_models.dart';
import 'scan_services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NoteScannerApp());
}

class NoteScannerApp extends StatelessWidget {
  const NoteScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0A8F62);
    return MaterialApp(
      title: 'Currency Note Checker',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
      ),
      home: const NoteScannerHome(),
    );
  }
}

class NoteScannerHome extends StatefulWidget {
  const NoteScannerHome({super.key});

  @override
  State<NoteScannerHome> createState() => _NoteScannerHomeState();
}

class _NoteScannerHomeState extends State<NoteScannerHome>
    with SingleTickerProviderStateMixin {
  CameraController? _controller;
  ScanHistoryStore? _historyStore;
  late final AudioPlayer _scanSoundPlayer;
  late final AnimationController _scanLineController;
  late final NoteScanAnalyzer _noteScanAnalyzer;

  List<NoteScanResult> _history = const [];
  NoteScanResult? _latestResult;
  PermissionStatus? _permissionStatus;

  String _status = 'Booting secure scan workspace...';
  String _helperText =
      'Preparing OCR and image-quality checks for the framed note area.';
  String? _lastCapturePath;

  bool _isInitializing = true;
  bool _isBusy = false;
  bool _isCameraReady = false;
  bool _isFlashOn = false;
  ScanInspectionMode _inspectionMode = ScanInspectionMode.standard;
  double _analysisProgress = 0;

  @override
  void initState() {
    super.initState();
    _scanSoundPlayer = AudioPlayer();
    _scanLineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _noteScanAnalyzer = NoteScanAnalyzer();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final store = await ScanHistoryStore.create();
      final history = await store.loadHistory();
      if (!mounted) {
        return;
      }
      setState(() {
        _historyStore = store;
        _history = history;
        _latestResult = history.isNotEmpty ? history.first : null;
        _lastCapturePath = history.isNotEmpty
            ? history.first.capturedImagePath
            : null;
        _inspectionMode = history.isNotEmpty
            ? history.first.inspectionMode
            : ScanInspectionMode.standard;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Storage setup failed';
        _helperText = 'History will stay disabled until local storage works.';
      });
    }

    await _ensurePermissionAndStartCamera();
  }

  Future<void> _ensurePermissionAndStartCamera() async {
    setState(() {
      _isInitializing = true;
      _status = 'Checking camera permission...';
      _helperText =
          'Camera access is required for capture, flash, and cropped analysis.';
    });

    var status = await Permission.camera.status;
    if (!status.isGranted) {
      status = await Permission.camera.request();
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _permissionStatus = status;
    });

    if (status.isGranted) {
      await _prepareCamera();
      return;
    }

    setState(() {
      _isInitializing = false;
      _isCameraReady = false;
      _status = status.isPermanentlyDenied
          ? 'Camera permission blocked'
          : 'Camera permission required';
      _helperText = status.isPermanentlyDenied
          ? 'Open app settings to enable camera access and flash.'
          : 'Grant camera access so the scanner can capture a note.';
    });
  }

  Future<void> _prepareCamera() async {
    await _disposeCameraController();
    setState(() {
      _status = 'Starting camera...';
      _helperText =
          'Hold the note horizontally and keep all four corners inside the guide.';
      _analysisProgress = 0;
    });

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw StateError('No camera found on this device.');
      }

      final selected = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        selected,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      await controller.setFlashMode(FlashMode.off);

      if (!mounted) {
        await controller.dispose();
        return;
      }

      _controller = controller;
      _scanLineController.repeat();
      setState(() {
        _isInitializing = false;
        _isCameraReady = true;
        _isFlashOn = false;
        _status = 'Ready to scan';
        _helperText = _inspectionMode == ScanInspectionMode.uv
            ? ScanInspectionMode.uv.helperText
            : 'Place the note inside the wider frame, then tap Scan Note.';
      });
    } on CameraException catch (error) {
      setState(() {
        _isInitializing = false;
        _isCameraReady = false;
        _status = 'Camera error';
        _helperText = error.description ?? 'Unable to start the camera.';
      });
    } catch (error) {
      setState(() {
        _isInitializing = false;
        _isCameraReady = false;
        _status = 'Camera unavailable';
        _helperText = error.toString();
      });
    }
  }

  Future<void> _disposeCameraController() async {
    final controller = _controller;
    _controller = null;
    _isCameraReady = false;
    if (controller != null) {
      await controller.dispose();
    }
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (!_isCameraReady || controller == null) {
      return;
    }

    final nextFlashOn = !_isFlashOn;
    try {
      await controller.setFlashMode(
        nextFlashOn ? FlashMode.torch : FlashMode.off,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _isFlashOn = nextFlashOn;
        _helperText = nextFlashOn
            ? 'Flash enabled for low-light scanning.'
            : 'Flash disabled.';
      });
    } on CameraException {
      if (!mounted) {
        return;
      }
      setState(() {
        _helperText = 'Flash is not available on this camera.';
      });
    }
  }

  Future<void> _setInspectionMode(ScanInspectionMode mode) async {
    if (_inspectionMode == mode) {
      return;
    }

    if (mode == ScanInspectionMode.uv && _isFlashOn && _controller != null) {
      try {
        await _controller!.setFlashMode(FlashMode.off);
        _isFlashOn = false;
      } on CameraException {
        if (mounted) {
          setState(() {
            _helperText =
                'Phone flash could not be turned off automatically, so keep it off during UV scans.';
          });
        }
      }
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _inspectionMode = mode;
      _status = mode == ScanInspectionMode.uv
          ? 'UV assist ready'
          : 'Ready to scan';
      _helperText = mode.helperText;
    });
  }

  Future<void> _captureAndAnalyze() async {
    final controller = _controller;
    final historyStore = _historyStore;
    if (!_isCameraReady ||
        _isBusy ||
        controller == null ||
        historyStore == null) {
      return;
    }

    setState(() {
      _isBusy = true;
      _analysisProgress = 0.08;
      _status = 'Capturing note...';
      _helperText = 'Hold steady while we save the image preview.';
    });

    try {
      final capture = await controller.takePicture();
      final savedImagePath = await historyStore.persistCapture(capture.path);
      if (!mounted) {
        return;
      }

      setState(() {
        _lastCapturePath = savedImagePath;
        _analysisProgress = 0.18;
        _status = 'Preview saved';
        _helperText = _inspectionMode == ScanInspectionMode.uv
            ? 'Running UV fluorescence and visible-print checks inside the framed note area.'
            : 'Running OCR and image-quality checks inside the framed note area.';
      });

      final result = await _noteScanAnalyzer.analyze(
        imagePath: savedImagePath,
        mode: _inspectionMode,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          setState(() {
            _analysisProgress = progress.progress;
            _status = progress.title;
            _helperText = progress.detail;
          });
        },
      );

      final history = await historyStore.save(result);
      await _playScanFeedback(result);
      if (!mounted) {
        return;
      }

      setState(() {
        _latestResult = result;
        _history = history;
        _analysisProgress = 1;
        _status = 'Scan complete';
        _helperText = result.summary;
      });
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Capture failed';
        _helperText =
            error.description ?? 'The camera could not take a picture.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Analysis failed';
        _helperText = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _playScanFeedback(NoteScanResult result) async {
    await HapticFeedback.mediumImpact();

    try {
      await _scanSoundPlayer.stop();
      await _scanSoundPlayer.setVolume(result.confidence >= 0.7 ? 1.0 : 0.82);
      await _scanSoundPlayer.play(AssetSource('audio/scan_beep.wav'));
    } catch (_) {
      await SystemSound.play(
        result.confidence >= 0.7
            ? SystemSoundType.click
            : SystemSoundType.alert,
      );
    }

    try {
      if (await Vibration.hasVibrator()) {
        await Vibration.vibrate(
          pattern: result.confidence >= 0.7
              ? const [0, 70, 45, 110]
              : const [0, 160, 60, 140],
        );
      }
    } catch (_) {}
  }

  Future<void> _showHistorySheet() async {
    if (_history.isEmpty) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _history.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final item = _history[index];
                return ListTile(
                  onTap: () {
                    Navigator.of(context).pop();
                    setState(() {
                      _latestResult = item;
                      _lastCapturePath = item.capturedImagePath;
                      _inspectionMode = item.inspectionMode;
                      _status = 'Loaded from history';
                      _helperText =
                          'Showing the saved analysis from ${_formatTimestamp(item.scannedAt)}.';
                    });
                  },
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22),
                  ),
                  tileColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                  leading: _HistoryThumb(
                    path: item.capturedImagePath,
                    size: 56,
                  ),
                  title: Text(item.verdict),
                  subtitle: Text(
                    '${item.confidenceLabel} - ${_formatTimestamp(item.scannedAt)}',
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _scanSoundPlayer.dispose();
    _scanLineController.dispose();
    _noteScanAnalyzer.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final permissionBlocked = _permissionStatus?.isPermanentlyDenied ?? false;
    final permissionGranted = _permissionStatus?.isGranted ?? false;
    final result = _latestResult;
    final progressValue = _isBusy ? _analysisProgress : result?.confidence;

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF031A16), Color(0xFF0A372E), Color(0xFF12614E)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                flex: 6,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(34),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_isCameraReady && _controller != null)
                          CameraPreview(_controller!)
                        else
                          DecoratedBox(
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Color(0xFF12332B), Color(0xFF081412)],
                              ),
                            ),
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 28,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      permissionGranted
                                          ? Icons.document_scanner
                                          : Icons.no_photography,
                                      size: 52,
                                      color: Colors.white.withValues(
                                        alpha: 0.82,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      _status,
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.titleLarge
                                          ?.copyWith(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      _helperText,
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: Colors.white.withValues(
                                              alpha: 0.82,
                                            ),
                                          ),
                                    ),
                                    const SizedBox(height: 18),
                                    if (_isInitializing)
                                      const SizedBox(
                                        width: 32,
                                        height: 32,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 3,
                                        ),
                                      )
                                    else if (permissionBlocked)
                                      FilledButton.icon(
                                        onPressed: openAppSettings,
                                        icon: const Icon(
                                          Icons.settings_outlined,
                                        ),
                                        label: const Text('Open Settings'),
                                      )
                                    else
                                      FilledButton.icon(
                                        onPressed:
                                            _ensurePermissionAndStartCamera,
                                        icon: const Icon(
                                          Icons.camera_alt_outlined,
                                        ),
                                        label: Text(
                                          permissionGranted
                                              ? 'Retry Camera'
                                              : 'Grant Camera Access',
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _FramePainter(isBusy: _isBusy),
                            ),
                          ),
                        ),
                        if (_isCameraReady)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: AnimatedBuilder(
                                animation: _scanLineController,
                                builder: (context, child) {
                                  return CustomPaint(
                                    painter: _ScanLinePainter(
                                      progress: _scanLineController.value,
                                      isActive: _isBusy,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        Positioned(
                          top: 16,
                          left: 16,
                          right: 16,
                          child: Row(
                            children: [
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.42),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    _status,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelLarge?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              IconButton.filledTonal(
                                onPressed: _history.isEmpty
                                    ? null
                                    : _showHistorySheet,
                                icon: const Icon(Icons.history_rounded),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filledTonal(
                                onPressed: _isCameraReady ? _toggleFlash : null,
                                icon: Icon(
                                  _isFlashOn
                                      ? Icons.flash_on_rounded
                                      : Icons.flash_off_rounded,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Positioned(
                          left: 26,
                          right: 26,
                          bottom: 22,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.48),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              _helperText,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                flex: 5,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(32),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'AI Scan Console',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Preview, confidence score, detected features, and saved history all stay in one place.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.68,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: ScanInspectionMode.values
                                .map(
                                  (mode) => ChoiceChip(
                                    selected: _inspectionMode == mode,
                                    onSelected: _isBusy
                                        ? null
                                        : (selected) {
                                            if (selected) {
                                              _setInspectionMode(mode);
                                            }
                                          },
                                    avatar: Icon(
                                      mode == ScanInspectionMode.standard
                                          ? Icons.document_scanner_outlined
                                          : Icons.wb_sunny_outlined,
                                      size: 18,
                                    ),
                                    label: Text(mode.label),
                                  ),
                                )
                                .toList(),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _inspectionMode == ScanInspectionMode.uv
                                ? 'UV Assist expects an external UV lamp. Phone flash is switched off so fluorescence patterns stay visible.'
                                : 'Standard mode prioritizes OCR, visible print, and stricter image-quality checks.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.68,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(24),
                              gradient: LinearGradient(
                                colors: [
                                  theme.colorScheme.primary.withValues(
                                    alpha: 0.14,
                                  ),
                                  theme.colorScheme.secondary.withValues(
                                    alpha: 0.12,
                                  ),
                                ],
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _isBusy
                                      ? 'Scan in progress'
                                      : result?.confidenceLabel ??
                                            'Waiting for first scan',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: LinearProgressIndicator(
                                    minHeight: 11,
                                    value: progressValue?.clamp(0.0, 1.0),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_lastCapturePath != null) ...[
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                _HistoryThumb(
                                  path: _lastCapturePath!,
                                  size: 88,
                                ),
                                if (result != null) ...[
                                  const SizedBox(width: 12),
                                  _HistoryThumb(
                                    path: result.processedImagePath,
                                    size: 72,
                                  ),
                                ],
                              ],
                            ),
                          ],
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.all(18),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(26),
                              gradient: LinearGradient(
                                colors: [
                                  _toneForResult(
                                    result?.verdict,
                                  ).withValues(alpha: 0.16),
                                  theme.colorScheme.surface,
                                ],
                              ),
                            ),
                            child: result == null
                                ? const Text(
                                    'No result yet. Capture a note to get preview, confidence %, OCR text, and history.',
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Result: ${result.verdict}',
                                        style: theme.textTheme.headlineSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                      const SizedBox(height: 10),
                                      Text(result.summary),
                                      const SizedBox(height: 12),
                                      Wrap(
                                        spacing: 10,
                                        runSpacing: 10,
                                        children: [
                                          Chip(
                                            label: Text(result.confidenceLabel),
                                          ),
                                          Chip(
                                            label: Text(
                                              result.inspectionMode.label,
                                            ),
                                          ),
                                          Chip(
                                            label: Text(result.detectionMode),
                                          ),
                                          Chip(
                                            label: Text(
                                              'Light ${(result.quality.lighting * 100).round()}%',
                                            ),
                                          ),
                                          if (result.inspectionMode ==
                                              ScanInspectionMode.uv)
                                            Chip(
                                              label: Text(
                                                'UV ${(result.quality.uvResponse * 100).round()}%',
                                              ),
                                            ),
                                        ],
                                      ),
                                      if (result.extractedText.isNotEmpty) ...[
                                        const SizedBox(height: 12),
                                        Text(
                                          result.extractedText,
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ],
                                    ],
                                  ),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: permissionGranted
                                      ? (_isCameraReady && !_isBusy
                                            ? _captureAndAnalyze
                                            : null)
                                      : _ensurePermissionAndStartCamera,
                                  icon: Icon(
                                    permissionGranted
                                        ? Icons.document_scanner_outlined
                                        : Icons.lock_open_rounded,
                                  ),
                                  label: Text(
                                    permissionGranted
                                        ? (_isBusy
                                              ? 'Scanning...'
                                              : 'Scan Note')
                                        : 'Grant Camera',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _history.isEmpty
                                      ? null
                                      : _showHistorySheet,
                                  icon: const Icon(Icons.history_rounded),
                                  label: const Text('View History'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          Text(
                            'Detected Features',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 10),
                          if (result == null)
                            const Text(
                              'After your first scan, OCR hits and image-quality checks will appear here.',
                            )
                          else
                            Column(
                              children: result.detectedFeatures
                                  .map(
                                    (feature) => Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 10,
                                      ),
                                      child: _FeatureTile(feature: feature),
                                    ),
                                  )
                                  .toList(),
                            ),
                          const SizedBox(height: 18),
                          Text(
                            'Recent History',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 10),
                          if (_history.isEmpty)
                            const Text(
                              'No scans saved yet. Each successful scan stores the image, result, and time locally.',
                            )
                          else
                            SizedBox(
                              height: 96,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: _history.take(5).length,
                                separatorBuilder: (context, index) =>
                                    const SizedBox(width: 12),
                                itemBuilder: (context, index) {
                                  final item = _history[index];
                                  return InkWell(
                                    borderRadius: BorderRadius.circular(22),
                                    onTap: () {
                                      setState(() {
                                        _latestResult = item;
                                        _lastCapturePath =
                                            item.capturedImagePath;
                                        _inspectionMode = item.inspectionMode;
                                        _status = 'Loaded from history';
                                        _helperText =
                                            'Showing the saved analysis from ${_formatTimestamp(item.scannedAt)}.';
                                      });
                                    },
                                    child: Container(
                                      width: 182,
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: theme
                                            .colorScheme
                                            .surfaceContainerHighest
                                            .withValues(alpha: 0.28),
                                        borderRadius: BorderRadius.circular(22),
                                      ),
                                      child: Row(
                                        children: [
                                          _HistoryThumb(
                                            path: item.capturedImagePath,
                                            size: 56,
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  item.verdict,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  item.confidenceLabel,
                                                  style:
                                                      theme.textTheme.bodySmall,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _toneForResult(String? verdict) {
    switch (verdict) {
      case 'Likely Real':
        return const Color(0xFF118B57);
      case 'Likely Fake':
        return const Color(0xFFBD3A3A);
      case 'Poor Capture':
        return const Color(0xFFD48A24);
      default:
        return const Color(0xFF3D79E1);
    }
  }

  String _formatTimestamp(DateTime timestamp) {
    final hour = timestamp.hour % 12 == 0 ? 12 : timestamp.hour % 12;
    final minute = timestamp.minute.toString().padLeft(2, '0');
    final suffix = timestamp.hour >= 12 ? 'PM' : 'AM';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[timestamp.month - 1]} ${timestamp.day}, ${timestamp.year} - $hour:$minute $suffix';
  }
}

class _FeatureTile extends StatelessWidget {
  const _FeatureTile({required this.feature});

  final ScanFeature feature;

  @override
  Widget build(BuildContext context) {
    final tone = feature.passed
        ? const Color(0xFF118B57)
        : const Color(0xFFC56F1F);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            feature.passed ? Icons.check_circle : Icons.info_outline,
            color: tone,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  feature.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(feature.detail),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryThumb extends StatelessWidget {
  const _HistoryThumb({required this.path, required this.size});

  final String path;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: size,
        height: size,
        child: Image.file(
          File(path),
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => const ColoredBox(
            color: Colors.black12,
            child: Icon(Icons.image_not_supported_outlined),
          ),
        ),
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  _FramePainter({required this.isBusy});

  final bool isBusy;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width * ScanFrameSpec.widthFactor,
      height: size.height * ScanFrameSpec.heightFactor,
    );
    final frame = RRect.fromRectAndRadius(
      rect,
      const Radius.circular(ScanFrameSpec.cornerRadius),
    );
    final overlay = Path()..addRect(Offset.zero & size);
    final cutout = Path()..addRRect(frame);
    canvas.drawPath(
      Path.combine(PathOperation.difference, overlay, cutout),
      Paint()..color = Colors.black.withValues(alpha: 0.46),
    );
    canvas.drawRRect(
      frame,
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 0.5),
            isBusy ? const Color(0xFF7DFFC0) : const Color(0xFF45D690),
            Colors.white.withValues(alpha: 0.5),
          ],
        ).createShader(rect)
        ..strokeWidth = isBusy ? 3.4 : 2.4
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _FramePainter oldDelegate) {
    return oldDelegate.isBusy != isBusy;
  }
}

class _ScanLinePainter extends CustomPainter {
  _ScanLinePainter({required this.progress, required this.isActive});

  final double progress;
  final bool isActive;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width * ScanFrameSpec.widthFactor,
      height: size.height * ScanFrameSpec.heightFactor,
    );
    final frame = RRect.fromRectAndRadius(
      rect,
      const Radius.circular(ScanFrameSpec.cornerRadius),
    );
    canvas.save();
    canvas.clipRRect(frame);
    final lineY = rect.top + rect.height * progress;
    final glowRect = Rect.fromLTWH(rect.left, lineY - 26, rect.width, 52);
    canvas.drawRect(
      glowRect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.transparent,
            (isActive ? const Color(0xFF91FFC1) : const Color(0xFF5DE6A4))
                .withValues(alpha: 0.85),
            Colors.transparent,
          ],
        ).createShader(glowRect),
    );
    canvas.drawLine(
      Offset(rect.left, lineY),
      Offset(rect.right, lineY),
      Paint()
        ..color = isActive ? const Color(0xFFB0FFD2) : const Color(0xFF7BF0AF)
        ..strokeWidth = isActive ? 3 : 2,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ScanLinePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.isActive != isActive;
  }
}

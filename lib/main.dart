import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  List<CameraDescription> cameras = [];
  String? startupError;

  try {
    cameras = await availableCameras();
  } on CameraException {
    startupError = 'Unable to access the camera.';
  } catch (_) {
    startupError = 'Camera setup failed.';
  }

  runApp(NoteScannerApp(cameras: cameras, startupError: startupError));
}

class NoteScannerApp extends StatelessWidget {
  const NoteScannerApp({
    super.key,
    required this.cameras,
    this.startupError,
  });

  final List<CameraDescription> cameras;
  final String? startupError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Currency Note Checker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: NoteScannerHome(
        cameras: cameras,
        startupError: startupError,
      ),
    );
  }
}

class NoteScannerHome extends StatefulWidget {
  const NoteScannerHome({
    super.key,
    required this.cameras,
    this.startupError,
  });

  final List<CameraDescription> cameras;
  final String? startupError;

  @override
  State<NoteScannerHome> createState() => _NoteScannerHomeState();
}

class _NoteScannerHomeState extends State<NoteScannerHome>
    with SingleTickerProviderStateMixin {
  CameraController? _controller;
  Future<void>? _initializeFuture;
  String _status = 'Ready to scan';
  String? _lastCapturePath;
  String _resultText = 'No result yet';
  String _resultDetail = 'Scan a note to see the result.';
  bool _isBusy = false;
  bool _isCameraReady = false;
  int _scanCount = 0;
  late final AnimationController _scanLineController;

  @override
  void initState() {
    super.initState();
    _scanLineController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    if (widget.startupError != null) {
      _status = widget.startupError!;
      _resultText = 'Camera unavailable';
      _resultDetail = 'Check camera permissions or device support.';
    }

    _setupCamera();
  }

  Future<void> _setupCamera() async {
    if (widget.cameras.isEmpty) {
      setState(() {
        _status = widget.startupError ?? 'No camera found on this device.';
      });
      return;
    }

    final controller = CameraController(
      widget.cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    setState(() {
      _controller = controller;
      _initializeFuture = controller.initialize();
      _status = 'Starting camera...';
    });

    try {
      await _initializeFuture;
      if (!mounted) {
        return;
      }

      _scanLineController.repeat();
      setState(() {
        _isCameraReady = true;
        _status = 'Ready to scan';
      });
    } catch (_) {
      await controller.dispose();
      if (!mounted) {
        return;
      }

      setState(() {
        _controller = null;
        _initializeFuture = null;
        _status = 'Failed to start camera.';
        _resultText = 'Camera unavailable';
        _resultDetail = 'Camera initialization failed.';
      });
    }
  }

  @override
  void dispose() {
    _scanLineController.dispose();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _captureAndCheck() async {
    final controller = _controller;
    final initFuture = _initializeFuture;
    if (!_isCameraReady || controller == null || initFuture == null) {
      return;
    }

    setState(() {
      _isBusy = true;
      _status = 'Capturing image...';
    });

    try {
      await initFuture;
      final file = await controller.takePicture();
      setState(() {
        _lastCapturePath = file.path;
        _status = 'Analyzing note...';
        _resultText = 'Analyzing...';
        _resultDetail = 'Please wait while we check the note.';
      });

      // Demo-only: simulate analysis delay and a placeholder result.
      await Future<void>.delayed(const Duration(seconds: 3));
      final isLikelyReal = _scanCount % 2 == 0;
      setState(() {
        _scanCount++;
        _resultText = isLikelyReal ? 'Likely Real' : 'Likely Fake';
        _resultDetail = isLikelyReal
            ? 'No obvious red flags detected in this demo.'
            : 'Possible mismatch in demo checks.';
        _status = 'Analysis complete.';
      });
    } catch (error) {
      setState(() {
        _status = 'Capture failed. Please try again.';
        _resultText = 'No result';
        _resultDetail = 'Capture failed before analysis.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final canScan = _isCameraReady && !_isBusy;

    return Scaffold(
      appBar: AppBar(title: const Text('Currency Note Checker')),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: Colors.black,
              child: controller == null
                  ? const Center(
                      child: Text(
                        'Camera not available',
                        style: TextStyle(color: Colors.white),
                      ),
                    )
                  : FutureBuilder<void>(
                      future: _initializeFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.done) {
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              CameraPreview(controller),
                              AnimatedBuilder(
                                animation: _scanLineController,
                                builder: (context, child) {
                                  final linePosition =
                                      _scanLineController.value;
                                  return FractionallySizedBox(
                                    heightFactor: 1,
                                    widthFactor: 1,
                                    alignment: Alignment.topCenter,
                                    child: CustomPaint(
                                      painter: _ScanLinePainter(
                                        progress: linePosition,
                                        isActive: _isBusy,
                                      ),
                                    ),
                                  );
                                },
                              ),
                              Align(
                                alignment: Alignment.topCenter,
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 16),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black54,
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Text(
                                      _isBusy
                                          ? 'Scanning note...'
                                          : 'Align note within the frame',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        }
                        if (snapshot.hasError) {
                          return const Center(
                            child: Text(
                              'Failed to start camera',
                              style: TextStyle(color: Colors.white),
                            ),
                          );
                        }
                        return const Center(child: CircularProgressIndicator());
                      },
                    ),
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _status,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _lastCapturePath == null
                      ? 'No capture yet'
                      : 'Last capture: $_lastCapturePath',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 12),
                Text(
                  _resultText,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: _resultText == 'Likely Real'
                        ? Colors.green.shade700
                        : _resultText == 'Likely Fake'
                        ? Colors.red.shade700
                        : Colors.black87,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _resultDetail,
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: canScan ? _captureAndCheck : null,
                        icon: const Icon(Icons.camera_alt),
                        label: const Text('Scan Note'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanLinePainter extends CustomPainter {
  _ScanLinePainter({
    required this.progress,
    required this.isActive,
  });

  final double progress;
  final bool isActive;

  @override
  void paint(Canvas canvas, Size size) {
    final lineY = size.height * progress;
    final glowPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.transparent,
          isActive ? Colors.greenAccent : Colors.green,
          Colors.transparent,
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromLTWH(0, lineY - 24, size.width, 48))
      ..strokeWidth = isActive ? 3 : 2
      ..style = PaintingStyle.stroke;

    final linePaint = Paint()
      ..color = isActive ? Colors.greenAccent : Colors.green
      ..strokeWidth = isActive ? 2 : 1.5;

    canvas.drawLine(Offset(0, lineY), Offset(size.width, lineY), linePaint);
    canvas.drawLine(Offset(0, lineY - 12), Offset(size.width, lineY - 12), glowPaint);
    canvas.drawLine(Offset(0, lineY + 12), Offset(size.width, lineY + 12), glowPaint);
  }

  @override
  bool shouldRepaint(covariant _ScanLinePainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.isActive != isActive;
  }
}

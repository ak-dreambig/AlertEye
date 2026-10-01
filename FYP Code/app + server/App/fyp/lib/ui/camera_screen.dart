import 'sensor_inference.dart'; // Import the sensor_inference.dart file
import 'local_processor.dart'; // Import your local processor
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'dart:async';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _cameraController;
  List<CameraDescription>? cameras;
  String? currentVideoPath;
  Timer? frameTimer;
  bool isRecording = false;
  late Future<void> _initializeControllerFuture;

  // Sensor data
  StreamSubscription<GyroscopeEvent>? _gyroscopeStream;
  StreamSubscription<AccelerometerEvent>? _accelerometerStream;

  List<Map<String, double>> gyroData = [];
  List<Map<String, double>> accData = [];

  double _gyroX = 0.0, _gyroY = 0.0, _gyroZ = 0.0;
  double _accX = 0.0, _accY = 0.0, _accZ = 0.0;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    await Permission.camera.request();
    await Permission.microphone.request();

    if (await Permission.camera.isGranted && await Permission.microphone.isGranted) {
      try {
        cameras = await availableCameras();
        if (cameras!.isEmpty) {
          print('No cameras found');
          return;
        }
        _cameraController = CameraController(
          cameras!.firstWhere((camera) => camera.lensDirection == CameraLensDirection.front),
          ResolutionPreset.high,
          imageFormatGroup: ImageFormatGroup.yuv420,
        );
        _initializeControllerFuture = _cameraController!.initialize();
        await _initializeControllerFuture;
        if (mounted) {
          setState(() {});
        }
      } catch (e) {
        print('Error initializing camera: $e');
      }
    } else {
      print('Camera or microphone permission denied');
    }
  }

  List<CameraImage> capturedFrames = [];
  Timer? batchUploadTimer;

  void _startSensorListeners() {
    _gyroscopeStream = gyroscopeEvents.listen(
          (GyroscopeEvent event) {
        if (mounted && isRecording) {
          setState(() {
            _gyroX = event.x;
            _gyroY = event.y;
            _gyroZ = event.z;
          });
          gyroData.add({'x': _gyroX, 'y': _gyroY, 'z': _gyroZ});
        }
      },
      onError: (e) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (context) {
              return const AlertDialog(
                title: Text("Sensor Not Found"),
                content: Text("Your device doesn't support Gyroscope Sensor."),
              );
            },
          );
        }
      },
    );

    _accelerometerStream = accelerometerEvents.listen(
          (AccelerometerEvent event) {
        if (mounted && isRecording) {
          setState(() {
            _accX = event.x;
            _accY = event.y;
            _accZ = event.z;
          });
          accData.add({'x': _accX, 'y': _accY, 'z': _accZ});
        }
      },
      onError: (e) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (context) {
              return const AlertDialog(
                title: Text("Sensor Not Found"),
                content: Text("Your device doesn't support Accelerometer Sensor."),
              );
            },
          );
        }
      },
    );
  }

  Future<void> _collectAndSendSensorData() async {
    // Collect data for 10 seconds and send it to the server
    await Future.delayed(const Duration(seconds: 2)); // Collect data for 2 seconds
    if (gyroData.isNotEmpty && accData.isNotEmpty) {
      await SensorInference.sendDataToServer(List.from(gyroData), List.from(accData));
      gyroData.clear();
      accData.clear();
    }
  }

  void _stopSensorListeners() {
    _gyroscopeStream?.cancel();
    _accelerometerStream?.cancel();
    _gyroscopeStream = null;
    _accelerometerStream = null;
  }

  Future<void> _startRecording() async {
    if (_cameraController != null && !isRecording) {
      try {
        setState(() {
          isRecording = true;
          capturedFrames.clear();
        });

        _startSensorListeners();

        // Start the sensor data collection and periodic sending of sensor data
        _startPeriodicSensorDataCollection();

        _cameraController!.startImageStream((CameraImage image) {
          if (capturedFrames.length < 10) {
            capturedFrames.add(image);
          }
        });

        batchUploadTimer = Timer.periodic(const Duration(seconds: 20), (timer) {
          if (capturedFrames.isNotEmpty) {
            _sendBatchToProcessor(List<CameraImage>.from(capturedFrames));
            capturedFrames.clear();
          }
        });

        print("Frame recording started.");
      } catch (e) {
        print('Error starting frame recording: $e');
      }
    }
  }

  Future<void> _stopRecording() async {
    if (_cameraController != null && isRecording) {
      try {
        await _cameraController!.stopImageStream();
        batchUploadTimer?.cancel();
        setState(() {
          isRecording = false;
        });

        _stopSensorListeners();

        if (capturedFrames.isNotEmpty) {
          await _sendBatchToProcessor(List<CameraImage>.from(capturedFrames));
          capturedFrames.clear();
        }

        print("Frame recording stopped.");
      } catch (e) {
        print('Error stopping frame recording: $e');
      }
    }
  }

  Future<void> _sendBatchToProcessor(List<CameraImage> batch) async {
    try {
      await LocalProcessor.processBatch(batch, context);
      print("Batch processed successfully.");
    } catch (e) {
      print("Error sending batch to processor: $e");
    }
  }

  void _startPeriodicSensorDataCollection() {
    // Collect and send data every 10 seconds
    Timer.periodic(const Duration(seconds: 10), (timer) async {
      await _collectAndSendSensorData();
    });
  }

  @override
  void dispose() {
    _stopSensorListeners();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return Stack(
              children: [
                CameraPreview(_cameraController!),
                Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    color: Colors.black.withOpacity(0.5),
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Gyroscope: x: ${_gyroX.toStringAsFixed(2)}, y: ${_gyroY.toStringAsFixed(2)}, z: ${_gyroZ.toStringAsFixed(2)}',
                          style: const TextStyle(color: Colors.white),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Accelerometer: x: ${_accX.toStringAsFixed(2)}, y: ${_accY.toStringAsFixed(2)}, z: ${_accZ.toStringAsFixed(2)}',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: GestureDetector(
                      onTap: isRecording ? _stopRecording : _startRecording,
                      child: Container(
                        height: 120,
                        width: 120,
                        decoration: BoxDecoration(
                          color: isRecording ? Colors.red : const Color(0xff001C3D),
                          borderRadius: BorderRadius.circular(100),
                        ),
                        child: Center(
                          child: Text(
                            isRecording ? 'Stop' : 'Start',
                            style: const TextStyle(
                              color: Color(0xff0076FF),
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          } else if (snapshot.hasError) {
            return Center(child: Text('Error initializing camera: ${snapshot.error}'));
          } else {
            return const Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }
}

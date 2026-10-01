import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:google_ml_kit/google_ml_kit.dart';
import 'package:http/http.dart' as http;
import 'dart:typed_data';
import "package:just_audio/just_audio.dart";

final FaceDetector faceDetector = GoogleMlKit.vision.faceDetector(
  FaceDetectorOptions(
    enableContours: true,
    enableLandmarks: true,
  ),
);

class LocalProcessor {
  static final player = AudioPlayer();





  static Future<void> processBatch(List<CameraImage> batch, BuildContext context) async {
    try {
      List<String> eyeStatuses = []; // List to hold the status of both eyes for each frame

      for (var i = 0; i < batch.length; i++) {
        print("Processing frame ${i + 1} of ${batch.length}");

        // Adjust rotation dynamically based on your camera setup
        InputImageRotation rotation = InputImageRotation.rotation0deg; // Update this based on actual rotation logic

        // Convert CameraImage to InputImage for ML Kit
        final InputImage inputImage = _convertCameraImageToInputImage(batch[i], rotation);

        // Detect faces in the frame
        final List<Face> faces = await faceDetector.processImage(inputImage);

        if (faces.isEmpty) {
          print("No faces detected in frame ${i + 1}");
          continue;
        }

        // Extract eye regions and send to server
        final Map<String, Uint8List> eyeImages = _extractEyeRegions(batch[i], faces);

        if (eyeImages.containsKey("leftEye") && eyeImages.containsKey("rightEye")) {
          Uint8List leftEyeBytes = eyeImages["leftEye"]!;
          Uint8List rightEyeBytes = eyeImages["rightEye"]!;

          // Send the eye images to the server
          final response = await _sendToServer(leftEyeBytes, rightEyeBytes);
          print("Server response: $response");

          // Get the eye status and save it
          String eyeStatus = _checkEyeStatus(response);
          eyeStatuses.add(eyeStatus);
          print("Eye status: $eyeStatus");
        }
      }

      if (eyeStatuses.isNotEmpty) {
        int closedCount = eyeStatuses.where((status) => status == 'eye closed').length;

        // If "eye closed" status appears more than half of the times
        if (closedCount > eyeStatuses.length / 2) {
          print("Alert: Majority of frames have eyes closed!");

          // Show alert dialog
          _showAlert(context);

          // Play the alarm sound (Placeholder)
          _playAlarm();
        } else {
          print("Eyes are open in the majority of frames.");
        }
      }

      print("Batch processing complete. Frames processed: ${batch.length}");
    } catch (e) {
      print("Error in local processing: $e");
    }
  }

  static InputImage _convertCameraImageToInputImage(CameraImage image, InputImageRotation rotation) {
    // Convert CameraImage to bytes
    final bytes = Uint8List(
        image.planes.fold<int>(0, (sum, plane) => sum + plane.bytes.length));

    int offset = 0;
    for (final plane in image.planes) {
      bytes.setRange(offset, offset + plane.bytes.length, plane.bytes);
      offset += plane.bytes.length;
    }

    // Create InputImageMetadata with dynamic rotation
    final InputImageMetadata metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation, // Pass dynamic rotation
      format: InputImageFormat.nv21,
      bytesPerRow: image.planes[0].bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  static Map<String, Uint8List> _extractEyeRegions(CameraImage frame, List<Face> faces) {
    final int width = frame.width;
    final int height = frame.height;

    final img.Image imgBuffer = img.Image(width, height);

    final Plane yPlane = frame.planes[0];
    final Plane uPlane = frame.planes[1];
    final Plane vPlane = frame.planes[2];

    final int uvRowStride = uPlane.bytesPerRow;
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int yIndex = y * yPlane.bytesPerRow + x;
        final int uvIndex = (y ~/ 2) * uvRowStride + (x ~/ 2) * uvPixelStride;

        final int yPixel = yPlane.bytes[yIndex];
        final int uPixel = uPlane.bytes[uvIndex] - 128;
        final int vPixel = vPlane.bytes[uvIndex] - 128;

        final int r = (yPixel + 1.402 * vPixel).clamp(0, 255).toInt();
        final int g = (yPixel - 0.344136 * uPixel - 0.714136 * vPixel).clamp(
            0, 255).toInt();
        final int b = (yPixel + 1.772 * uPixel).clamp(0, 255).toInt();

        imgBuffer.setPixel(x, y, img.getColor(r, g, b));
      }
    }

    img.Image? leftEyeImage;
    img.Image? rightEyeImage;

    for (Face face in faces) {
      final FaceLandmark? leftEye = face.landmarks[FaceLandmarkType.leftEye];
      final FaceLandmark? rightEye = face.landmarks[FaceLandmarkType.rightEye];

      if (leftEye != null && rightEye != null) {
        const int eyeBoxSize = 40;

        final int leftX = (leftEye.position.x - eyeBoxSize / 2)
            .clamp(0, width)
            .toInt();
        final int leftY = (leftEye.position.y - eyeBoxSize / 2)
            .clamp(0, height)
            .toInt();
        leftEyeImage =
            img.copyCrop(imgBuffer, leftX, leftY, eyeBoxSize, eyeBoxSize);

        final int rightX = (rightEye.position.x - eyeBoxSize / 2).clamp(
            0, width).toInt();
        final int rightY = (rightEye.position.y - eyeBoxSize / 2).clamp(
            0, height).toInt();
        rightEyeImage =
            img.copyCrop(imgBuffer, rightX, rightY, eyeBoxSize, eyeBoxSize);
      }
    }

    final Map<String, Uint8List> eyeImages = {};

    if (leftEyeImage != null) {
      eyeImages["leftEye"] = Uint8List.fromList(img.encodeJpg(leftEyeImage));
    }
    if (rightEyeImage != null) {
      eyeImages["rightEye"] = Uint8List.fromList(img.encodeJpg(rightEyeImage));
    }

    return eyeImages;
  }

  static Future<String> _sendToServer(Uint8List leftEyeBytes, Uint8List rightEyeBytes) async {
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse(
            'http://192.168.18.217:8080/upload_eye_images'), // Replace with your server's URL and endpoint
      );

      // Add files
      request.files.add(http.MultipartFile.fromBytes(
          'leftEye', leftEyeBytes, filename: 'left_eye.jpg'));
      request.files.add(http.MultipartFile.fromBytes(
          'rightEye', rightEyeBytes, filename: 'right_eye.jpg'));

      // Send the request
      final response = await request.send();

      if (response.statusCode == 200) {
        final responseData = await response.stream.bytesToString();
        return responseData; // The server's response, which includes eye states and file paths
      } else {
        print('Failed to get response from server. Status code: ${response.statusCode}');
        return 'Error: ${response.statusCode}';
      }
    } catch (e) {
      print('Error sending to server: $e');
      return 'Error';
    }
  }

  static String _checkEyeStatus(String response) {
    if (response.isEmpty) return 'Error: No response from server';

    final Map<String, dynamic> responseData = jsonDecode(response);

    // Check the status of each eye and return a string
    final String leftEyeStatus = responseData['leftEyeStatus'];
    final String rightEyeStatus = responseData['rightEyeStatus'];

    // Return the status based on the conditions
    if (leftEyeStatus == 'eye closed' && rightEyeStatus == 'eye closed') {
      return 'eye closed'; // Both eyes are closed
    } else if (leftEyeStatus == 'eye open' && rightEyeStatus == 'eye open') {
      return 'eye open'; // Both eyes are open
    } else {
      return 'mixed'; // One eye is open and one is closed
    }
  }

  // Show an alert dialog to the user
  static void _showAlert(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,  // Prevent dismissal by tapping outside
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Alert'),
          content: Text('Eyes are closed! Please take action.'),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close the dialog
                _stopAlarm(); // Placeholder for stopping the alarm
              },
              child: Text('OK'),
            ),
          ],
        );
      },
    );
  }

  static void _playAlarm() async {
    try {
      print("Playing alarm...");
      await player.setAsset('assets/alarm_sound.mp3'); // Replace with your audio URL
      player.setLoopMode(LoopMode.one); // Loop the alarm sound
      player.play(); // Start playback
    } catch (e) {
      print("Error playing alarm: $e");
    }
  }

  static void _stopAlarm() async {
    try {
      print("Stopping alarm...");
      await player.stop(); // Stop the playback
    } catch (e) {
      print("Error stopping alarm: $e");
    }
  }

}

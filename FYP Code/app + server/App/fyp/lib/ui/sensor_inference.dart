import 'dart:async';
import 'package:http/http.dart' as http;
import 'dart:convert';

class SensorInference {
  // URL of the Flask server
  static const String serverUrl = 'http://192.168.18.217:5000/upload-sensor-data';

  // Method to receive and send sensor data to the server
  static Future<void> sendDataToServer(
      List<Map<String, double>> gyroData, List<Map<String, double>> accData) async {
    // Get the current time (without date) and format it
    final DateTime now = DateTime.now();
    final String time = '${now.hour}:${now.minute}:${now.second}.${now.millisecond}';

    // Combine the gyroscope and accelerometer data into a JSON payload
    final List<Map<String, dynamic>> gyroWithTimestamp = gyroData
        .map((gyro) => {...gyro, 'timestamp': time})
        .toList();

    final List<Map<String, dynamic>> accWithTimestamp = accData
        .map((acc) => {...acc, 'timestamp': time})
        .toList();

    final Map<String, dynamic> data = {
      'gyro': gyroWithTimestamp,
      'acc': accWithTimestamp,
    };

    try {
      // Send the data to the server using HTTP POST
      final response = await http.post(
        Uri.parse(serverUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(data),
      );

      if (response.statusCode == 200) {
        print('Data sent successfully to the server');
      } else {
        print('Failed to send data to server. Status: ${response.statusCode}');
      }
    } catch (e) {
      print('Error sending data to server: $e');
    }
  }
}

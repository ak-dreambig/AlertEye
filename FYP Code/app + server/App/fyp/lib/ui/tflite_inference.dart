import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class TFLitePreprocessor {
  final int inputWidth;
  final int inputHeight;
  late Interpreter interpreter;
  int closedEyeCount = 0;

  TFLitePreprocessor({required this.inputWidth, required this.inputHeight}) {
    _initializeInterpreter();
  }

  Future<void> _initializeInterpreter() async {
    try {
      interpreter = await Interpreter.fromAsset('assets/mobileNet_eye_model.tflite');
      print("Interpreter initialized successfully!");
      print("Model Input Shape: ${interpreter.getInputTensor(0).shape}");
      print("Model Output Shape: ${interpreter.getOutputTensor(0).shape}");
    } catch (e) {
      print("Error initializing TFLite interpreter: $e");
      rethrow;
    }
  }

  Float32List preprocess(Uint8List imageBytes) {
    try {
      // Decode the image
      img.Image? rawImage = img.decodeImage(imageBytes);

      if (rawImage == null) throw Exception("Failed to decode image.");

      // Get the model's input shape
      var inputShape = interpreter.getInputTensor(0).shape;
      int batchSize = inputShape[0];
      int expectedWidth = inputShape[1];
      int expectedHeight = inputShape[2];
      int channels = inputShape[3];
      if (rawImage.width <= 0 || rawImage.height <= 0) {
        print("Decoded image has invalid dimensions: ${rawImage.width}x${rawImage.height}");
        throw Exception("Decoded image dimensions are invalid.");
      }

      // Resize the image
      img.Image resizedImage = img.copyResize(
        rawImage,
        width: expectedWidth,
        height: expectedHeight,
      );
      if (resizedImage.width != expectedWidth || resizedImage.height != expectedHeight) {
        print("Resized image dimensions are invalid: ${resizedImage.width}x${resizedImage.height}");
        throw Exception("Resized image dimensions do not match the expected input size.");
      }


      // Print the actual shape being passed to the interpreter
      print("Actual Input Image Shape: [$batchSize, ${resizedImage.width}, ${resizedImage.height}, $channels]");

      // Validate the resized image dimensions
      if (resizedImage.width != expectedWidth || resizedImage.height != expectedHeight) {
        throw Exception("Resized image dimensions do not match the expected input size.");
      }

      // Normalize the pixel values to [0, 1] and prepare for tensor
      List<double> normalizedPixels = [];
      for (int y = 0; y < resizedImage.height; y++) {
        for (int x = 0; x < resizedImage.width; x++) {
          int pixel = resizedImage.getPixel(x, y);

          normalizedPixels.add(img.getBlue(pixel) / 255.0);
          normalizedPixels.add(img.getGreen(pixel) / 255.0);
          normalizedPixels.add(img.getRed(pixel) / 255.0);

        }
      }

      // Ensure the tensor size matches the model's expected input
      int expectedSize = expectedWidth * expectedHeight * channels;
      if (normalizedPixels.length != expectedSize) {
        throw Exception("Flattened tensor size mismatch. Expected: $expectedSize, Got: ${normalizedPixels.length}");
      }

      return Float32List.fromList(normalizedPixels);
    } catch (e) {
      print("Error during preprocessing: $e");
      rethrow;
    }
  }

  String performInference(Float32List tensor) {
    try {
      var inputShape = interpreter.getInputTensor(0).shape;
      var outputShape = interpreter.getOutputTensor(0).shape;

      // Prepare output buffer
      var output = List<List<double>>.filled(
          outputShape[0], List<double>.filled(outputShape[1], 0.0));

      // Run inference
      interpreter.run(tensor.buffer.asFloat32List(), output);

      double prediction = output[0][0];
      return prediction > 0.5 ? "eye open" : "eye closed";
    } catch (e) {
      print("Error during inference: $e");
      rethrow;
    }
  }

  Future<void> handleImages(Uint8List leftEyeBytes, Uint8List rightEyeBytes) async {
    try {
      String leftEyeState = _processAndInfer(leftEyeBytes);
      String rightEyeState = _processAndInfer(rightEyeBytes);

      if (leftEyeState == "eye closed" && rightEyeState == "eye closed") {
        closedEyeCount++;
      } else {
        closedEyeCount = 0;
      }

      if (closedEyeCount >= 5) {
        print("Driver is drowsy.");
      }
    } catch (e) {
      print("Error handling images: $e");
    }
  }

  String _processAndInfer(Uint8List imageBytes) {
    Float32List tensor = preprocess(imageBytes);
    if (tensor.isEmpty) {
      print("Tensor is empty. Cannot perform inference.");
      throw Exception("Input tensor is empty.");
    }

    // Wrap the tensor in a batch (TensorFlow Lite expects batched input)
    List<List<List<List<double>>>> batchedInput = [
      List.generate(
        inputHeight,
            (i) => List.generate(
          inputWidth,
              (j) => List.generate(
            3,
                (k) => tensor[(i * inputWidth + j) * 3 + k],
          ),
        ),
      )
    ];

    // Convert to a flattened Float32List to pass into TensorFlow Lite interpreter
    Float32List batchedTensor = Float32List.fromList(
      batchedInput.expand((batch) => batch.expand((row) => row.expand((pixel) => pixel))).toList(),
    );

    return performInference(batchedTensor);
  }
}

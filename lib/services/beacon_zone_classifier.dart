import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart' as tfl;
import 'dart:math' show exp, pow;

/// Runs TFLite inference for zone classification from smoothed RSSI vectors.
/// Uses tflite_flutter 0.12.1 for actual model execution on Android/iOS.
class BeaconZoneClassifier {
  static const String _modelAssetPath = 'assets/booth_classifier.tflite';

  final tfl.Interpreter? _interpreter;
  final int numBeacons;
  final int numZones;

  BeaconZoneClassifier({
    required this.numBeacons,
    required this.numZones,
    required tfl.Interpreter? interpreter,
  }) : _interpreter = interpreter;

  /// Load the TFLite model from assets using tflite_flutter.
  static Future<BeaconZoneClassifier?> loadModel({
    required int numBeacons,
    required int numZones,
  }) async {
    try {
      final data = await rootBundle.load(_modelAssetPath);
      final interpreter = await tfl.Interpreter.fromBuffer(data.buffer.asUint8List());
      
      debugPrint('[ML] TFLite model loaded successfully');
      debugPrint('[ML] Model input tensors: ${interpreter.getInputTensors().length}');
      debugPrint('[ML] Model output tensors: ${interpreter.getOutputTensors().length}');
      
      return BeaconZoneClassifier(
        numBeacons: numBeacons,
        numZones: numZones,
        interpreter: interpreter,
      );
    } catch (e) {
      debugPrint('[ML] Failed to load TFLite model: $e');
      return null;
    }
  }

  /// Normalize raw RSSI values to [0, 1] range using fixed bounds.
  /// This matches the exact normalization used during training in Python.
  /// 
  /// Formula: (clip(rssi, -100, -40) - (-100)) / 60.0
  /// CRITICAL: Uses fixed RSSI bounds (physics-based), not data-dependent.
  /// Works identically in Python training and Dart inference.
  /// 
  /// Args:
  ///   rawRssi: Raw RSSI values (typically -30 to -100 dBm)
  /// Returns:
  ///   Normalized values in range [0.0, 1.0]
  static List<double> normalizeRssi(List<double> rawRssi) {
    const double rssiMin = -100.0;
    const double rssiMax = -40.0;
    const double rssiRange = rssiMax - rssiMin; // 60.0
    
    return rawRssi
        .map((rssi) {
          // Clip RSSI to valid range
          final clipped = rssi.clamp(rssiMin, rssiMax);
          // Normalize to [0, 1]
          return (clipped - rssiMin) / rssiRange;
        })
        .toList();
  }

  /// Predict zone probabilities from a normalized RSSI feature vector.
  /// Runs TFLite model inference on the input vector.
  Future<List<double>> predictZoneProbabilities(List<double> normalizedRssiVector) async {
    if (normalizedRssiVector.length != numBeacons) {
      throw ArgumentError(
        'Expected $numBeacons features, got ${normalizedRssiVector.length}',
      );
    }

    // If interpreter not loaded, return uniform probabilities
    if (_interpreter == null) {
      debugPrint('[ML] Interpreter not loaded, returning uniform probabilities');
      return List.filled(numZones, 1.0 / numZones);
    }

    try {
      // Prepare input: [1, numBeacons] (batch size 1)
      final input = <Object>[normalizedRssiVector];
      
      // Prepare output: [1, numZones]
      final output = List<List<double>>.filled(
        1,
        List<double>.filled(numZones, 0.0),
      );

      // Run inference
      _interpreter!.run(input, output);

      // Extract raw logits from output[0]
      final rawLogits = output[0];
      
      debugPrint('[ML] Raw model output: $rawLogits');
      
      // Apply softmax to convert logits to probabilities
      // Formula: softmax(x_i) = exp(x_i) / sum(exp(x_j))
      final expLogits = rawLogits.map((logit) => _exp(logit)).toList();
      final sumExp = expLogits.fold<double>(0.0, (a, b) => a + b);
      final probabilities = expLogits.map((e) => e / sumExp).toList();
      
      debugPrint('[ML] After softmax: $probabilities');
      
      return probabilities;
    } catch (e) {
      debugPrint('[ML] Inference error: $e');
      return List.filled(numZones, 1.0 / numZones);
    }
  }

  /// Stable exponential function for softmax computation
  static double _exp(double x) {
    // Clamp to avoid overflow
    if (x > 20) return 1e9;
    if (x < -20) return 0.0;
    return exp(x);  // Uses dart:math exp
  }

  /// Predict the most likely zone index.
  Future<int> predictZone(List<double> normalizedRssiVector) async {
    final probs = await predictZoneProbabilities(normalizedRssiVector);
    double maxProb = -1;
    int bestZone = 0;

    for (int i = 0; i < probs.length; i++) {
      if (probs[i] > maxProb) {
        maxProb = probs[i];
        bestZone = i;
      }
    }

    return bestZone;
  }

  /// Get confidence (0.0-1.0) of the prediction.
  /// High confidence: top prediction significantly higher than others.
  Future<double> getPredictionConfidence(List<double> normalizedRssiVector) async {
    final probs = await predictZoneProbabilities(normalizedRssiVector);
    if (probs.isEmpty) return 0.0;

    probs.sort((a, b) => b.compareTo(a));
    if (probs.length == 1) return probs[0];

    // Margin between top and second: normalized to [0, 1]
    final margin = (probs[0] - probs[1]) / probs[0];
    return margin.clamp(0.0, 1.0);
  }

  void dispose() {
    try {
      _interpreter?.close();
      debugPrint('[ML] TFLite interpreter closed');
    } catch (e) {
      debugPrint('[ML] Error closing interpreter: $e');
    }
  }
}

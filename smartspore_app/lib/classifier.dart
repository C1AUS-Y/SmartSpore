import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:executorch_flutter/executorch_flutter.dart';
import 'package:flutter/services.dart' show rootBundle;

class ClassificationResult {
  final String label;
  final double confidence;

  ClassificationResult(this.label, this.confidence);

  @override
  String toString() => '$label ${(confidence * 100).toStringAsFixed(2)}%';
}

class MultiClassificationResult {
  final List<List<ClassificationResult>> perImage;
  final List<ClassificationResult> overall;

  MultiClassificationResult({required this.perImage, required this.overall});

  String? get overallLabel => overall.isEmpty ? null : overall.first.label;

  double get overallConfidence => overall.isEmpty ? 0.0 : overall.first.confidence;

  double get agreement {
    final target = overallLabel;
    if (target == null || perImage.isEmpty) return 0.0;

    final matches = perImage.where((r) => r.isNotEmpty && r.first.label == target).length;
    return matches / perImage.length;
  }

  List<double> get perImageConfidenceForWinner {
    final target = overallLabel;
    if (target == null) return const [];

    return perImage.map((results) {
      for (final r in results) {
        if (r.label == target) return r.confidence;
      }
      return 0.0;
    }).toList();
  }
}

abstract class MushroomClassifier {
  bool get isReady;

  Future<void> load();
  Future<void> dispose();

  Future<List<ClassificationResult>> classify(File imageFile, {int topK = 5});
  Future<List<ClassificationResult>> classifyMultiple(List<File> imageFiles, {int topK = 5});
  Future<MultiClassificationResult> classifyMultipleDetailed(List<File> imageFiles, {int topK = 5});
}

class Classifier implements MushroomClassifier {
  static const String modelPath = 'lib/assets/model/MNv4_FP32_ver2.pte';
  static const String labelsPath = 'lib/assets/labels.txt';

  static const int inputSize = 384;
  static const int numClasses = 6;

  ExecuTorchModel? _model;
  List<String> labels = [];
  List<double> lastScores = [];
  List<List<double>> lastPerImageScores = [];

  @override
  bool get isReady => _model != null;

  @override
  Future<void> load() async {
    final labelData = await rootBundle.loadString(labelsPath);

    labels = labelData.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    _model = await loadModelFromAsset(modelPath);
  }

  @override
  Future<void> dispose() async {
    await _model?.dispose();
    _model = null;
  }

  Future<List<double>> _predictSingle(File imageFile) async {
    final model = _model;
    if (model == null) {
      throw StateError('Model is not loaded yet.');
    }

    final bytes = await imageFile.readAsBytes();

    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final codec = await descriptor.instantiateCodec(targetWidth: inputSize, targetHeight: inputSize);
    final frame = await codec.getNextFrame();
    final nativeImage = frame.image;

    final rgbaByteData = await nativeImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgbaByteData == null) {
      throw StateError('Could not extract raw pixel data from native image.');
    }
    final rgbaBytes = rgbaByteData.buffer.asUint8List();

    nativeImage.dispose();

    final inputTensor = _rgbaBytesToNCHWTensor(rgbaBytes);
    final outputs = await model.forward([inputTensor]);

    if (outputs.isEmpty) {
      throw StateError('Inference returned no output tensors.');
    }

    final rawScores = _floatsFromBytes(outputs.first.data, numClasses);
    return _softmax(rawScores);
  }

  @override
  Future<List<ClassificationResult>> classify(File imageFile, {int topK = 5}) async {
    final scores = await _predictSingle(imageFile);
    lastScores = scores;
    return _scoresToResults(scores, topK);
  }

  @override
  Future<MultiClassificationResult> classifyMultipleDetailed(List<File> imageFiles, {int topK = 5}) async {
    if (imageFiles.isEmpty) {
      throw ArgumentError('Need at least one image to classify.');
    }

    final perImage = <List<ClassificationResult>>[];
    final perImageScores = <List<double>>[];
    final summedScores = List<double>.filled(numClasses, 0.0);

    for (final file in imageFiles) {
      final scores = await _predictSingle(file);

      perImageScores.add(scores);
      perImage.add(_scoresToResults(scores, topK));

      for (var i = 0; i < numClasses; i++) {
        if (i < scores.length) {
          summedScores[i] += scores[i];
        }
      }
    }

    final avgScores = List<double>.generate(numClasses, (i) => summedScores[i] / imageFiles.length);

    lastScores = avgScores;
    lastPerImageScores = perImageScores;

    return MultiClassificationResult(perImage: perImage, overall: _scoresToResults(avgScores, topK));
  }

  @override
  Future<List<ClassificationResult>> classifyMultiple(List<File> imageFiles, {int topK = 5}) async {
    final detailed = await classifyMultipleDetailed(imageFiles, topK: topK);
    return detailed.overall;
  }

  TensorData _rgbaBytesToNCHWTensor(Uint8List rgbaBytes) {
    const channelSize = inputSize * inputSize;
    final floats = Float32List(3 * channelSize);

    var pixelIndex = 0;
    for (var i = 0; i < channelSize; i++) {
      floats[i] = rgbaBytes[pixelIndex].toDouble();
      floats[channelSize + i] = rgbaBytes[pixelIndex + 1].toDouble();
      floats[2 * channelSize + i] = rgbaBytes[pixelIndex + 2].toDouble();
      pixelIndex += 4;
    }

    return TensorData(
      shape: const [1, 3, inputSize, inputSize],
      dataType: TensorType.float32,
      data: floats.buffer.asUint8List(),
    );
  }

  List<double> _softmax(List<double> logits) {
    if (logits.isEmpty) return const [];

    var maxLogit = logits[0];
    for (var i = 1; i < logits.length; i++) {
      if (logits[i] > maxLogit) maxLogit = logits[i];
    }

    final exps = List<double>.filled(logits.length, 0.0);
    var sum = 0.0;

    for (var i = 0; i < logits.length; i++) {
      final e = math.exp(logits[i] - maxLogit);
      exps[i] = e;
      sum += e;
    }

    for (var i = 0; i < exps.length; i++) {
      exps[i] /= sum;
    }

    return exps;
  }

  List<ClassificationResult> _scoresToResults(List<double> scores, int topK) {
    final indices = List.generate(scores.length, (i) => i)
      ..sort((a, b) => scores[b].compareTo(scores[a]));

    final resultCount = math.min(topK, indices.length);

    return List<ClassificationResult>.generate(resultCount, (position) {
      final i = indices[position];
      final label = i < labels.length ? labels[i] : 'class_$i';
      return ClassificationResult(label, scores[i]);
    });
  }

  List<double> _floatsFromBytes(Uint8List bytes, int count) {
    final byteData = ByteData.sublistView(bytes);

    if (bytes.length == count * 4) {
      return List<double>.generate(count, (i) => byteData.getFloat32(i * 4, Endian.little));
    }

    if (bytes.length == count * 2) {
      return List<double>.generate(
        count,
        (i) => _float16BitsToDouble(byteData.getUint16(i * 2, Endian.little)),
      );
    }

    throw StateError('Unexpected output tensor size: got ${bytes.length} bytes for $count classes.');
  }

  double _float16BitsToDouble(int value) {
    final sign = (value & 0x8000) >> 15;
    final exponent = (value & 0x7C00) >> 10;
    final fraction = value & 0x03FF;
    final signMultiplier = sign == 1 ? -1.0 : 1.0;

    if (exponent == 0) {
      return signMultiplier * math.pow(2, -14) * (fraction / 1024.0);
    }

    if (exponent == 0x1F) {
      if (fraction != 0) return double.nan;
      return sign == 1 ? double.negativeInfinity : double.infinity;
    }

    return signMultiplier * math.pow(2, exponent - 15) * (1.0 + fraction / 1024.0);
  }
}
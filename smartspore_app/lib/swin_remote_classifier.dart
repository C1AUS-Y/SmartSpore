import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'classifier.dart';

class SwinRemoteClassifier implements MushroomClassifier {
  static const String baseUrl =
      'https://mushroom-swin-285732427447.asia-southeast1.run.app';

  static const String? apiKey = null;

  static const int numClasses = 6;
  static const Duration requestTimeout = Duration(seconds: 30);

  static const int _uploadSize = 384;
  static const int _jpegQuality = 82;

  bool _ready = false;

  @override
  bool get isReady => _ready;

  @override
  Future<void> load() async {
    final uri = Uri.parse(baseUrl);
    const maxWait = Duration(seconds: 45);
    const pollIntervals = [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 3),
      Duration(seconds: 5),
    ];
    final deadline = DateTime.now().add(maxWait);
    var attempt = 0;

    while (DateTime.now().isBefore(deadline)) {
      try {
        final response = await http.get(uri).timeout(
              const Duration(seconds: 10),
            );

        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body) as Map<String, dynamic>;
          if (decoded['model_ready'] == true) {
            _ready = true;
            return;
          }
        }
      } on SocketException {
        throw StateError('No internet connection.');
      } on TimeoutException {}

      final wait = pollIntervals[attempt.clamp(0, pollIntervals.length - 1)];
      attempt++;
      await Future.delayed(wait);
    }

    throw StateError(
      'The online model is taking longer than usual to start. '
      'Please try again shortly.',
    );
  }

  @override
  Future<void> dispose() async {
    _ready = false;
  }

  Future<http.MultipartFile> _compressedMultipartFile(File imageFile) async {
    final bytes = await imageFile.readAsBytes();
    final decoded = img.decodeImage(bytes);

    if (decoded == null) {
      return http.MultipartFile.fromPath('file', imageFile.path);
    }

    final resized = img.copyResize(
      decoded,
      width: decoded.width >= decoded.height ? _uploadSize : null,
      height: decoded.height > decoded.width ? _uploadSize : null,
    );

    final jpegBytes = img.encodeJpg(resized, quality: _jpegQuality);

    return http.MultipartFile.fromBytes(
      'file',
      jpegBytes,
      filename: 'upload.jpg',
    );
  }

  Future<List<Map<String, dynamic>>> _predictRaw(File imageFile) async {
    final uri = Uri.parse('$baseUrl/predict');
    final request = http.MultipartRequest('POST', uri);

    if (apiKey != null && apiKey!.isNotEmpty) {
      request.headers['x-api-key'] = apiKey!;
    }

    request.files.add(await _compressedMultipartFile(imageFile));

    http.Response response;
    try {
      final streamed = await request.send().timeout(requestTimeout);
      response = await http.Response.fromStream(streamed);
    } on SocketException {
      throw StateError('No internet connection.');
    } on TimeoutException {
      throw StateError(
        'The request took too long. Check your connection and try again.',
      );
    }

    if (response.statusCode == 503) {
      throw StateError(
        'Swin model is still warming up on the server. '
        'Try again in a few seconds.',
      );
    }

    if (response.statusCode != 200) {
      throw StateError(
        'Swin server returned an error (${response.statusCode}): '
        '${response.body}',
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return (decoded['predictions'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
  }

  List<ClassificationResult> _toResults(
    List<Map<String, dynamic>> predictions,
    int topK,
  ) {
    return predictions
        .take(topK)
        .map(
          (p) => ClassificationResult(
            p['label'] as String,
            (p['confidence'] as num).toDouble(),
          ),
        )
        .toList();
  }

  @override
  Future<List<ClassificationResult>> classify(
    File imageFile, {
    int topK = 5,
  }) async {
    final predictions = await _predictRaw(imageFile);
    return _toResults(predictions, topK);
  }

  @override
  Future<MultiClassificationResult> classifyMultipleDetailed(
    List<File> imageFiles, {
    int topK = 5,
  }) async {
    if (imageFiles.isEmpty) {
      throw ArgumentError('Need at least one image to classify.');
    }

    final allPredictions = await Future.wait(
      imageFiles.map(_predictRaw),
    );

    final perImage =
        allPredictions.map((p) => _toResults(p, topK)).toList();

    final summed = <String, double>{};
    for (final predictions in allPredictions) {
      for (final p in predictions) {
        final label = p['label'] as String;
        final confidence = (p['confidence'] as num).toDouble();
        summed[label] = (summed[label] ?? 0.0) + confidence;
      }
    }

    final averaged = summed.entries
        .map((e) => ClassificationResult(e.key, e.value / imageFiles.length))
        .toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));

    return MultiClassificationResult(
      perImage: perImage,
      overall: averaged.take(topK).toList(),
    );
  }

  @override
  Future<List<ClassificationResult>> classifyMultiple(
    List<File> imageFiles, {
    int topK = 5,
  }) async {
    final detailed = await classifyMultipleDetailed(imageFiles, topK: topK);
    return detailed.overall;
  }
}
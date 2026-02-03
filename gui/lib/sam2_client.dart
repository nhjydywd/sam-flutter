import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class Sam2Client {
  Sam2Client({required this.baseUrl});

  final String baseUrl;

  Uri _uri(String path) {
    // Accept both "http://host:port" and "http://host:port/".
    final b = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return Uri.parse('$b$path');
  }

  Future<Map<String, dynamic>> health() async {
    final uri = _uri('/health');
    final res = await _requestJson('GET', uri);
    return res;
  }

  Future<Map<String, dynamic>> listModels() async {
    final uri = _uri('/models');
    return await _requestJson('GET', uri);
  }

  Future<Map<String, dynamic>> selectModel(String modelKey) async {
    final uri = _uri('/model/select');
    return await _requestJson('POST', uri, body: {'model_key': modelKey});
  }

  Future<Map<String, dynamic>> createSession({String? modelKey}) async {
    final uri = _uri('/sessions');
    final body = (modelKey == null) ? null : {'model_key': modelKey};
    return await _requestJson('POST', uri, body: body);
  }

  Future<Map<String, dynamic>> deleteSession(String sessionId) async {
    final uri = _uri('/sessions/$sessionId');
    return await _requestJson('DELETE', uri);
  }

  Future<Map<String, dynamic>> setImage({
    required String sessionId,
    required Uint8List imageBytes,
    required String filename,
    String contentType = 'application/octet-stream',
  }) async {
    final uri = _uri('/sessions/$sessionId/image');
    final httpClient = HttpClient();
    try {
      final req = await httpClient.postUrl(uri);
      final boundary = '----samflutter_${DateTime.now().microsecondsSinceEpoch}';
      req.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$boundary');

      final header = StringBuffer()
        ..write('--$boundary\r\n')
        ..write('Content-Disposition: form-data; name="file"; filename="$filename"\r\n')
        ..write('Content-Type: $contentType\r\n')
        ..write('\r\n');
      final footer = '\r\n--$boundary--\r\n';

      req.add(utf8.encode(header.toString()));
      req.add(imageBytes);
      req.add(utf8.encode(footer));

      final resp = await req.close();
      final respBody = await utf8.decoder.bind(resp).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('HTTP ${resp.statusCode}: $respBody', uri: uri);
      }
      return jsonDecode(respBody) as Map<String, dynamic>;
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<Map<String, dynamic>> predict({
    required String sessionId,
    required List<List<double>> points,
    required List<int> labels,
    bool multimask = false,
  }) async {
    final uri = _uri('/sessions/$sessionId/predict');
    final body = <String, dynamic>{
      'points': points,
      'labels': labels,
      'multimask': multimask,
    };
    return await _requestJson('POST', uri, body: body);
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    Uri uri, {
    Map<String, dynamic>? body,
  }) async {
    final httpClient = HttpClient();
    try {
      final req = await httpClient.openUrl(method, uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.add(utf8.encode(jsonEncode(body)));
      }
      final resp = await req.close();
      final respBody = await utf8.decoder.bind(resp).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('HTTP ${resp.statusCode}: $respBody', uri: uri);
      }
      return jsonDecode(respBody) as Map<String, dynamic>;
    } finally {
      httpClient.close(force: true);
    }
  }
}


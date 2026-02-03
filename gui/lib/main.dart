import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:dropdown_button2/dropdown_button2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

import 'app_settings.dart';
import 'widgets/drag_divider.dart';
import 'widgets/segmentation_preview.dart';

void main() {
  runApp(const SamFlutterApp());
}

class SamFlutterApp extends StatelessWidget {
  const SamFlutterApp({super.key, this.locale});

  final Locale? locale;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      locale: locale,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const _HomePage(),
    );
  }
}

class _HomePage extends StatefulWidget {
  const _HomePage();

  @override
  State<_HomePage> createState() => _HomePageState();
}

enum _ConnState { disconnected, connecting, connected }

enum _EmbeddingState { idle, computing, ready, error }

class _HomePageState extends State<_HomePage> {
  late final AppSettings _settings;
  final TextEditingController _serverCtrl = TextEditingController();
  final FocusNode _modelFocusNode = FocusNode(debugLabel: 'model-dropdown');
  bool _rightCollapsed = false;
  _ConnState _connState = _ConnState.disconnected;
  String? _lastError;
  Map<String, dynamic>? _health;
  Uri? _baseUri;
  List<Map<String, dynamic>> _models = const <Map<String, dynamic>>[];
  bool _modelsLoading = false;
  String? _selectedModelKey;
  bool _settingModel = false;
  String? _modelError;
  String? _pickedFilePath;
  String? _pickedFolderPath;
  int? _pickedFolderImageCount;
  int? _pickedImagesCount;
  bool _dragging = false;
  String? _pickError;
  String? _lastPickDir;
  final List<String> _imagePaths = <String>[];
  int _selectedImageIndex = -1;
  String? _activeImagePath;
  ui.Image? _activeUiImage;
  ui.Image? _activeMaskAlpha;
  final List<PromptPoint> _promptPoints = <PromptPoint>[];
  String? _sessionId;
  bool _creatingSession = false;
  _EmbeddingState _embeddingState = _EmbeddingState.idle;
  String? _embeddingError;
  double? _embeddingElapsedMs;
  int? _serverImageWidth;
  int? _serverImageHeight;
  bool _predicting = false;
  String? _predictError;
  double? _predictScore;
  int? _predictMaskArea;
  double? _predictElapsedMs;
  int _embedRequestToken = 0;
  double _leftListWidth = 260.0;
  static const double _rightExpandedWidth = 320.0;
  static const double _rightCollapsedWidth = 24.0;
  bool _appliedSettings = false;
  String _preferredModelKey = '';
  static const List<String> _imageExtensions = <String>[
    'png',
    'jpg',
    'jpeg',
    'webp',
    'bmp',
    'tif',
    'tiff',
  ];

  bool _isImagePath(String path) {
    final parts = path.split('.');
    if (parts.length < 2) return false;
    final ext = parts.last.toLowerCase();
    return _imageExtensions.contains(ext);
  }

  String _basename(String path) {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? path : parts.last;
  }

  Future<List<String>> _collectImagesFromPaths(List<String> paths) async {
    final out = <String>[];
    final seen = <String>{};

    for (final p in paths) {
      try {
        final type = FileSystemEntity.typeSync(p);
        if (type == FileSystemEntityType.directory) {
          final dir = Directory(p);
          if (!dir.existsSync()) continue;
          await for (final ent
              in dir.list(recursive: true, followLinks: false)) {
            if (ent is! File) continue;
            final fp = ent.path;
            if (!_isImagePath(fp)) continue;
            if (seen.add(fp)) out.add(fp);
          }
        } else if (type == FileSystemEntityType.file) {
          if (!_isImagePath(p)) continue;
          if (seen.add(p)) out.add(p);
        }
      } catch (_) {
        // Ignore broken paths.
      }
    }

    return out;
  }

  Future<void> _handleInputPaths(List<String> paths) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _pickError = null;
    });

    final images = await _collectImagesFromPaths(paths);
    if (images.isEmpty) {
      setState(() {
        _pickedFilePath = null;
        _pickedFolderPath = null;
        _pickedFolderImageCount = null;
        _pickedImagesCount = 0;
        _pickError = l10n.noImagesFound;
      });
      return;
    }

    // If user dropped exactly one file, keep the "Selected file" UX.
    if (paths.length == 1) {
      final p = paths.first;
      final t = FileSystemEntity.typeSync(p);
      if (t == FileSystemEntityType.file && _isImagePath(p)) {
        setState(() {
          _pickedFilePath = p;
          _pickedFolderPath = null;
          _pickedFolderImageCount = null;
          _pickedImagesCount = 1;
        });
        _lastPickDir = File(p).parent.path;
        _addImages(images);
        return;
      }
      if (t == FileSystemEntityType.directory) {
        setState(() {
          _pickedFolderPath = p;
          _pickedFolderImageCount = images.length;
          _pickedFilePath = null;
          _pickedImagesCount = images.length;
        });
        _lastPickDir = p;
        _addImages(images);
        return;
      }
    }

    // Otherwise show summary count (could be multiple files and/or folders).
    setState(() {
      _pickedFilePath = null;
      _pickedFolderPath = null;
      _pickedFolderImageCount = null;
      _pickedImagesCount = images.length;
    });

    _addImages(images);
    try {
      _lastPickDir = File(images.first).parent.path;
    } catch (_) {}
  }

  void _addImages(List<String> images) {
    if (images.isEmpty) return;
    final existing = _imagePaths.toSet();
    final toAdd = images.where(existing.add).toList(growable: false);
    if (toAdd.isEmpty) return;
    final shouldAutoSelect = _selectedImageIndex < 0;
    setState(() {
      _imagePaths.addAll(toAdd);
      if (_selectedImageIndex < 0 && _imagePaths.isNotEmpty) {
        _selectedImageIndex = 0;
      }
    });
    if (shouldAutoSelect && _imagePaths.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _selectImageIndex(0);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _settings = AppSettings();
    _settings.addListener(_onSettingsChanged);
    _serverCtrl.addListener(() {
      _settings.serverUrl = _serverCtrl.text;
    });
  }

  void _onSettingsChanged() {
    if (_settings.loaded) {
      // Keep this in sync so a later reconnect can apply the latest preference.
      _preferredModelKey = _settings.modelKey;
    }
    if (!_appliedSettings && _settings.loaded) {
      _appliedSettings = true;
      _serverCtrl.text = _settings.serverUrl;
      setState(() {
        _rightCollapsed = _settings.rightPanelCollapsed;
      });
      return;
    }
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    _serverCtrl.dispose();
    _modelFocusNode.dispose();
    _activeUiImage?.dispose();
    _activeMaskAlpha?.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _connState = _ConnState.connecting;
      _lastError = null;
      _health = null;
      _baseUri = null;
      _models = const <Map<String, dynamic>>[];
      _modelsLoading = false;
      _selectedModelKey = null;
      _settingModel = false;
      _modelError = null;
      _sessionId = null;
      _embeddingState = _EmbeddingState.idle;
      _embeddingError = null;
      _embeddingElapsedMs = null;
      _serverImageWidth = null;
      _serverImageHeight = null;
      _predictError = null;
      _predictScore = null;
      _predictMaskArea = null;
      _predictElapsedMs = null;
      _activeMaskAlpha = null;
      _promptPoints.clear();
    });

    final base = _serverCtrl.text.trim();
    Uri baseUri;
    try {
      baseUri = Uri.parse(base);
      if (!baseUri.hasScheme) {
        baseUri = Uri.parse('http://$base');
      }
      // Ensure we keep only scheme/host/port.
      baseUri = baseUri.replace(path: '', query: '', fragment: '');
    } catch (e) {
      setState(() {
        _connState = _ConnState.disconnected;
        _lastError = e.toString();
      });
      return;
    }

    try {
      final parsed = await _httpGetJson(baseUri.replace(path: '/health'));
      final ok =
          (parsed is Map<String, dynamic>) ? (parsed['ok'] == true) : false;
      if (!ok) {
        throw StateError('health check failed');
      }
      setState(() {
        _connState = _ConnState.connected;
        _lastError = null;
        _health = Map<String, dynamic>.from(parsed as Map);
        _baseUri = baseUri;
      });

      await _refreshModels();
    } catch (e) {
      setState(() {
        _connState = _ConnState.disconnected;
        _lastError = e.toString();
        _health = null;
        _baseUri = null;
      });
    }
  }

  Future<Object?> _httpGetJson(Uri uri) async {
    final httpClient = HttpClient();
    try {
      final req = await httpClient.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final resp = await req.close();
      final body = await utf8.decoder.bind(resp).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('HTTP ${resp.statusCode}: $body', uri: uri);
      }
      return jsonDecode(body);
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<Object?> _httpPostJson(Uri uri, Map<String, Object?> payload) async {
    final httpClient = HttpClient();
    try {
      final req = await httpClient.postUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(
          HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
      req.add(utf8.encode(jsonEncode(payload)));
      final resp = await req.close();
      final body = await utf8.decoder.bind(resp).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('HTTP ${resp.statusCode}: $body', uri: uri);
      }
      return jsonDecode(body);
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<void> _refreshModels() async {
    final base = _baseUri;
    if (base == null || _connState != _ConnState.connected) return;

    setState(() {
      _modelsLoading = true;
      _modelError = null;
    });

    try {
      final parsed = await _httpGetJson(base.replace(path: '/models'));
      if (parsed is! Map) throw StateError('invalid /models response');
      final m = Map<String, dynamic>.from(parsed);
      final avail = (m['available'] is List)
          ? List.from(m['available'] as List)
          : const <Object?>[];
      final models = <Map<String, dynamic>>[];
      for (final item in avail) {
        if (item is Map) {
          models.add(Map<String, dynamic>.from(item));
        }
      }

      final currentKey =
          _deepGet(m, <String>['current', 'model_key'])?.toString();
      final downloadedKeys = models
          .where((it) => it['downloaded'] == true)
          .map((it) => it['model_key']?.toString() ?? '')
          .where((k) => k.isNotEmpty)
          .toSet();

      String? selected;
      final preferred = _preferredModelKey.trim();
      if (preferred.isNotEmpty && downloadedKeys.contains(preferred)) {
        selected = preferred;
      } else if (currentKey != null && downloadedKeys.contains(currentKey)) {
        selected = currentKey;
      } else if (downloadedKeys.isNotEmpty) {
        selected = downloadedKeys.first;
      }

      setState(() {
        _models = models;
        _selectedModelKey = selected;
      });

      // If we have a preferred model and it's different from the server's current model,
      // apply it automatically after connect.
      if (selected != null && currentKey != null && selected != currentKey) {
        await _selectModel(selected, userInitiated: false);
      } else if (selected != null && _settings.modelKey != selected) {
        _settings.modelKey = selected;
      }
    } catch (e) {
      setState(() {
        _modelError = e.toString();
      });
    } finally {
      setState(() {
        _modelsLoading = false;
      });
    }
  }

  Future<void> _selectModel(String modelKey,
      {required bool userInitiated}) async {
    final base = _baseUri;
    if (base == null || _connState != _ConnState.connected) return;
    final cur = _deepGet(_health, <String>['model', 'model_key'])?.toString();
    if (cur == modelKey) {
      if (_settings.modelKey != modelKey) _settings.modelKey = modelKey;
      return;
    }
    if (_settingModel) return;

    setState(() {
      _settingModel = true;
      _modelError = null;
    });

    try {
      final parsed = await _httpPostJson(
        base.replace(path: '/model/select'),
        <String, Object?>{'model_key': modelKey},
      );
      if (parsed is! Map) throw StateError('invalid /model/select response');

      // Refresh health so sessions/device reflect the new model.
      final health = await _httpGetJson(base.replace(path: '/health'));
      if (health is Map) {
        setState(() {
          _health = Map<String, dynamic>.from(health);
          _selectedModelKey = modelKey;
          _sessionId = null; // server clears sessions on model switch
          _embeddingState = _EmbeddingState.idle;
          _embeddingError = null;
          _embeddingElapsedMs = null;
          _serverImageWidth = null;
          _serverImageHeight = null;
          _predictError = null;
          _predictScore = null;
          _predictMaskArea = null;
          _predictElapsedMs = null;
          _activeMaskAlpha = null;
          _promptPoints.clear();
        });
      } else {
        setState(() {
          _selectedModelKey = modelKey;
          _sessionId = null; // server clears sessions on model switch
          _embeddingState = _EmbeddingState.idle;
          _embeddingError = null;
          _embeddingElapsedMs = null;
          _serverImageWidth = null;
          _serverImageHeight = null;
          _predictError = null;
          _predictScore = null;
          _predictMaskArea = null;
          _predictElapsedMs = null;
          _activeMaskAlpha = null;
          _promptPoints.clear();
        });
      }
      _settings.modelKey = modelKey;
    } catch (e) {
      setState(() {
        _modelError = e.toString();
        if (userInitiated) {
          // Keep selection in sync with the server if the user action fails.
          _selectedModelKey =
              _deepGet(_health, <String>['model', 'model_key'])?.toString();
        }
      });
    } finally {
      setState(() {
        _settingModel = false;
      });
    }
  }

  Object? _deepGet(Map<String, dynamic>? m, List<String> path) {
    Object? cur = m;
    for (final key in path) {
      if (cur is Map<String, dynamic>) {
        cur = cur[key];
      } else if (cur is Map) {
        cur = cur[key];
      } else {
        return null;
      }
    }
    return cur;
  }

  Future<ui.Image> _decodeUiImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  Future<String> _ensureSession() async {
    final base = _baseUri;
    if (base == null || _connState != _ConnState.connected) {
      throw StateError('not connected');
    }
    final sid = _sessionId;
    if (sid != null && sid.isNotEmpty) return sid;
    if (_creatingSession) throw StateError('creating session');
    setState(() {
      _creatingSession = true;
    });
    try {
      final created = await _httpPostJson(
          base.replace(path: '/sessions'), <String, Object?>{});
      if (created is! Map) throw StateError('invalid /sessions response');
      final m = Map<String, dynamic>.from(created);
      final newSid = m['session_id']?.toString() ?? '';
      if (newSid.isEmpty) throw StateError('missing session_id');
      setState(() {
        _sessionId = newSid;
      });
      return newSid;
    } finally {
      setState(() {
        _creatingSession = false;
      });
    }
  }

  Future<Object?> _httpPostMultipartBytes(
    Uri uri, {
    required Uint8List bytes,
    required String filename,
    String fieldName = 'file',
  }) async {
    final httpClient = HttpClient();
    final boundary = '----samflutter-${DateTime.now().microsecondsSinceEpoch}';
    try {
      final req = await httpClient.postUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );

      void writeString(String s) => req.add(utf8.encode(s));

      writeString('--$boundary\r\n');
      writeString(
        'Content-Disposition: form-data; name="$fieldName"; filename="$filename"\r\n',
      );
      writeString('Content-Type: application/octet-stream\r\n\r\n');
      req.add(bytes);
      writeString('\r\n--$boundary--\r\n');

      final resp = await req.close();
      final body = await utf8.decoder.bind(resp).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('HTTP ${resp.statusCode}: $body', uri: uri);
      }
      return jsonDecode(body);
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<void> _computeEmbeddingForSelection({
    required String imagePath,
    required Uint8List imageBytes,
    required int requestToken,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    if (_connState != _ConnState.connected || _baseUri == null) {
      setState(() {
        _embeddingState = _EmbeddingState.error;
        _embeddingError = l10n.embeddingNotConnected;
      });
      return;
    }

    setState(() {
      _embeddingState = _EmbeddingState.computing;
      _embeddingError = null;
      _embeddingElapsedMs = null;
      _serverImageWidth = null;
      _serverImageHeight = null;
      _predictError = null;
      _predictScore = null;
      _predictMaskArea = null;
      _predictElapsedMs = null;
      _activeMaskAlpha = null;
      _promptPoints.clear();
    });

    final base = _baseUri!;
    String sid = await _ensureSession();

    Future<Map<String, dynamic>> doUpload(String sid) async {
      final parsed = await _httpPostMultipartBytes(
        base.replace(path: '/sessions/$sid/image'),
        bytes: imageBytes,
        filename: _basename(imagePath),
      );
      if (parsed is! Map)
        throw StateError('invalid /sessions/{id}/image response');
      return Map<String, dynamic>.from(parsed);
    }

    try {
      Map<String, dynamic> imgResp;
      try {
        imgResp = await doUpload(sid);
      } on HttpException catch (e) {
        // Model switches clear sessions; retry once with a fresh session.
        if (e.message.contains('HTTP 404')) {
          setState(() {
            _sessionId = null;
          });
          sid = await _ensureSession();
          imgResp = await doUpload(sid);
        } else {
          rethrow;
        }
      }

      if (requestToken != _embedRequestToken) return;

      setState(() {
        _embeddingState = _EmbeddingState.ready;
        _embeddingElapsedMs = (imgResp['elapsed_ms'] is num)
            ? (imgResp['elapsed_ms'] as num).toDouble()
            : null;
        _serverImageWidth = (imgResp['width'] is num)
            ? (imgResp['width'] as num).toInt()
            : null;
        _serverImageHeight = (imgResp['height'] is num)
            ? (imgResp['height'] as num).toInt()
            : null;
      });
    } catch (e) {
      if (requestToken != _embedRequestToken) return;
      setState(() {
        _embeddingState = _EmbeddingState.error;
        _embeddingError = e.toString();
      });
    }
  }

  Future<void> _runPredict() async {
    if (_predicting) return;
    if (_embeddingState != _EmbeddingState.ready) return;
    final base = _baseUri;
    if (base == null || _connState != _ConnState.connected) return;
    final sid = _sessionId;
    if (sid == null || sid.isEmpty) return;
    if (_promptPoints.isEmpty) return;
    final token = _embedRequestToken;
    final path = _activeImagePath;

    setState(() {
      _predicting = true;
      _predictError = null;
    });
    try {
      final pts = _promptPoints.map((p) => <double>[p.x, p.y]).toList();
      final lbs = _promptPoints.map((p) => p.label).toList();
      final parsed = await _httpPostJson(
        base.replace(path: '/sessions/$sid/predict'),
        <String, Object?>{
          'points': pts,
          'labels': lbs,
          'multimask': false,
          'return_format': 'png_base64',
        },
      );
      if (parsed is! Map) throw StateError('invalid /predict response');
      final m = Map<String, dynamic>.from(parsed);
      final b64 = m['mask_png_base64']?.toString() ?? '';
      if (b64.isEmpty) throw StateError('missing mask_png_base64');
      final bytes = base64Decode(b64);
      final maskImg = await _decodeUiImage(Uint8List.fromList(bytes));

      if (token != _embedRequestToken || path != _activeImagePath) {
        maskImg.dispose();
        return;
      }

      setState(() {
        final old = _activeMaskAlpha;
        _activeMaskAlpha = maskImg;
        _predictScore =
            (m['score'] is num) ? (m['score'] as num).toDouble() : null;
        _predictMaskArea =
            (m['mask_area'] is num) ? (m['mask_area'] as num).toInt() : null;
        _predictElapsedMs = (m['elapsed_ms'] is num)
            ? (m['elapsed_ms'] as num).toDouble()
            : null;
        old?.dispose();
      });
    } catch (e) {
      setState(() {
        _predictError = e.toString();
      });
    } finally {
      setState(() {
        _predicting = false;
      });
    }
  }

  Future<void> _selectImageIndex(int index) async {
    if (index < 0 || index >= _imagePaths.length) return;
    final path = _imagePaths[index];
    final token = ++_embedRequestToken;
    final oldImg = _activeUiImage;
    final oldMask = _activeMaskAlpha;
    setState(() {
      _selectedImageIndex = index;
      _activeImagePath = path;
      _activeUiImage = null;
      _activeMaskAlpha = null;
      _promptPoints.clear();
      _embeddingState = _EmbeddingState.idle;
      _embeddingError = null;
      _embeddingElapsedMs = null;
      _serverImageWidth = null;
      _serverImageHeight = null;
      _predictError = null;
      _predictScore = null;
      _predictMaskArea = null;
      _predictElapsedMs = null;
    });
    oldImg?.dispose();
    oldMask?.dispose();

    Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (e) {
      if (token != _embedRequestToken) return;
      setState(() {
        _embeddingState = _EmbeddingState.error;
        _embeddingError = e.toString();
      });
      return;
    }

    try {
      final img = await _decodeUiImage(bytes);
      if (token != _embedRequestToken) return;
      setState(() {
        _activeUiImage = img;
      });
    } catch (e) {
      if (token != _embedRequestToken) return;
      setState(() {
        _embeddingState = _EmbeddingState.error;
        _embeddingError = e.toString();
      });
      return;
    }

    await _computeEmbeddingForSelection(
      imagePath: path,
      imageBytes: bytes,
      requestToken: token,
    );
  }

  Future<void> _chooseFile() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _pickError = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: _imageExtensions,
        dialogTitle: l10n.chooseFile,
        initialDirectory: _lastPickDir,
      );
      if (result == null || result.files.isEmpty) return;
      final paths = result.files
          .map((f) => f.path)
          .whereType<String>()
          .where((p) => p.isNotEmpty)
          .toList();
      if (paths.isEmpty) return;
      final images = paths.where(_isImagePath).toList(growable: false);
      if (images.isEmpty) {
        setState(() {
          _pickError = l10n.noImagesFound;
        });
        return;
      }

      setState(() {
        _pickedFilePath = images.length == 1 ? images.first : null;
        _pickedFolderPath = null;
        _pickedFolderImageCount = null;
        _pickedImagesCount = images.length;
      });
      _lastPickDir = File(images.first).parent.path;
      _addImages(images);
    } catch (e) {
      setState(() {
        _pickError = e.toString();
      });
    }
  }

  Future<void> _chooseFolder() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _pickError = null;
    });
    try {
      final dirPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: l10n.chooseFolder,
        initialDirectory: _lastPickDir,
      );
      if (dirPath == null || dirPath.isEmpty) return;

      int count = 0;
      final images = <String>[];
      final seen = <String>{};
      final dir = Directory(dirPath);
      if (dir.existsSync()) {
        // Recursive scan (images only). Note: this can take time for large folders.
        await for (final ent in dir.list(recursive: true, followLinks: false)) {
          if (ent is! File) continue;
          if (!_isImagePath(ent.path)) continue;
          final p = ent.path;
          if (seen.add(p)) images.add(p);
          count += 1;
        }
      }

      if (count <= 0) {
        setState(() {
          _pickedFolderPath = dirPath;
          _pickedFolderImageCount = 0;
          _pickedFilePath = null;
          _pickedImagesCount = 0;
          _pickError = l10n.noImagesFound;
        });
        _lastPickDir = dirPath;
        return;
      }

      setState(() {
        _pickedFolderPath = dirPath;
        _pickedFolderImageCount = count;
        _pickedFilePath = null;
        _pickedImagesCount = count;
      });
      _lastPickDir = dirPath;
      _addImages(images);
    } catch (e) {
      setState(() {
        _pickError = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final panelWidth =
        _rightCollapsed ? _rightCollapsedWidth : _rightExpandedWidth;

    return DropTarget(
      // Important: this needs to wrap the whole page (like subocr) because the
      // macOS plugin reports positions relative to the root Flutter view.
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) async {
        setState(() => _dragging = false);
        final paths =
            detail.files.map((e) => e.path).where((p) => p.isNotEmpty).toList();
        if (paths.isEmpty) return;
        await _handleInputPaths(paths);
      },
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Scaffold(
            body: LayoutBuilder(
              builder: (context, constraints) {
                final dividerX = constraints.maxWidth - panelWidth;
                const btnSize = 28.0;
                final btnLeft = dividerX - (btnSize / 2);
                final btnTop = (constraints.maxHeight / 2) - (btnSize / 2);
                const minMainWidth = 280.0;
                const minLeftWidth = 160.0;
                const resizeHandleWidth = 10.0;
                final maxLeftWidthRaw =
                    constraints.maxWidth - panelWidth - minMainWidth;
                final maxLeftWidth = maxLeftWidthRaw < minLeftWidth
                    ? minLeftWidth
                    : maxLeftWidthRaw;
                final leftWidth =
                    _leftListWidth.clamp(minLeftWidth, maxLeftWidth);
                final selectedImagePath = (_selectedImageIndex >= 0 &&
                        _selectedImageIndex < _imagePaths.length)
                    ? _imagePaths[_selectedImageIndex]
                    : (_imagePaths.isNotEmpty ? _imagePaths.first : null);

                return Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        SizedBox(
                          width: leftWidth,
                          child: Stack(
                            fit: StackFit.expand,
                            children: <Widget>[
                              Material(
                                color: Theme.of(context).colorScheme.surface,
                                child: _imagePaths.isEmpty
                                    ? Center(
                                        child: Text(
                                          l10n.imagesListEmpty,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        ),
                                      )
                                    : ListView.builder(
                                        itemCount: _imagePaths.length,
                                        itemBuilder: (context, index) {
                                          final p = _imagePaths[index];
                                          final selected =
                                              index == _selectedImageIndex;
                                          return Material(
                                            color: selected
                                                ? Theme.of(context)
                                                    .colorScheme
                                                    .primaryContainer
                                                : Colors.transparent,
                                            child: InkWell(
                                              onTap: () {
                                                _selectImageIndex(index);
                                              },
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 10,
                                                        vertical: 8),
                                                child: Row(
                                                  children: <Widget>[
                                                    Text('${index + 1}.'),
                                                    const SizedBox(width: 8),
                                                    Expanded(
                                                      child: Text(
                                                        _basename(p),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                              ),
                              Positioned(
                                right: 0,
                                top: 0,
                                bottom: 0,
                                child: DragDivider(
                                  hitWidth: resizeHandleWidth,
                                  getInitialPosition: () => _leftListWidth,
                                  onPositionChanged: (pos) {
                                    setState(() {
                                      _leftListWidth =
                                          pos.clamp(minLeftWidth, maxLeftWidth);
                                    });
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: selectedImagePath != null
                              ? Container(
                                  color: Theme.of(context).colorScheme.surface,
                                  alignment: Alignment.center,
                                  child: Column(
                                    children: <Widget>[
                                      Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.all(16),
                                          child: Builder(
                                            builder: (context) {
                                              final activeOk =
                                                  _activeImagePath ==
                                                      selectedImagePath;
                                              final img = activeOk
                                                  ? _activeUiImage
                                                  : null;
                                              final mask = activeOk
                                                  ? _activeMaskAlpha
                                                  : null;
                                              if (img == null) {
                                                return const Center(
                                                  child:
                                                      CircularProgressIndicator(),
                                                );
                                              }
                                              return SegmentationPreview(
                                                image: img,
                                                maskAlpha: mask,
                                                points: _promptPoints,
                                                onAddPoint: (pt) {
                                                  if (_embeddingState !=
                                                      _EmbeddingState.ready) {
                                                    return;
                                                  }
                                                  setState(() {
                                                    _promptPoints.add(pt);
                                                  });
                                                  _runPredict();
                                                },
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                            16, 0, 16, 12),
                                        child: _ImageStatusBar(
                                          embeddingState: _embeddingState,
                                          embeddingError: _embeddingError,
                                          embeddingElapsedMs:
                                              _embeddingElapsedMs,
                                          promptPoints: _promptPoints,
                                          predicting: _predicting,
                                          predictError: _predictError,
                                          predictScore: _predictScore,
                                          predictMaskArea: _predictMaskArea,
                                          predictElapsedMs: _predictElapsedMs,
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              : Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      ElevatedButton.icon(
                                        onPressed: _chooseFile,
                                        icon: const Icon(
                                            Icons.insert_drive_file_outlined),
                                        label: Text(l10n.chooseFile),
                                      ),
                                      const SizedBox(height: 12),
                                      ElevatedButton.icon(
                                        onPressed: _chooseFolder,
                                        icon: const Icon(
                                            Icons.folder_open_outlined),
                                        label: Text(l10n.chooseFolder),
                                      ),
                                      if (_pickedFilePath != null) ...<Widget>[
                                        const SizedBox(height: 12),
                                        SizedBox(
                                          width: 520,
                                          child: Text(
                                            l10n.selectedFileLabel(
                                                _pickedFilePath!),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                      ],
                                      if (_pickedFolderPath !=
                                          null) ...<Widget>[
                                        const SizedBox(height: 12),
                                        SizedBox(
                                          width: 520,
                                          child: Text(
                                            l10n.selectedFolderLabel(
                                              _pickedFolderPath!,
                                              _pickedFolderImageCount ?? 0,
                                            ),
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                      ],
                                      if (_pickedImagesCount != null &&
                                          _pickedFilePath == null &&
                                          _pickedFolderPath ==
                                              null) ...<Widget>[
                                        const SizedBox(height: 12),
                                        SizedBox(
                                          width: 520,
                                          child: Text(
                                            l10n.selectedImagesCountLabel(
                                                _pickedImagesCount!),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                      ],
                                      if (_pickError != null &&
                                          _pickError!.isNotEmpty) ...<Widget>[
                                        const SizedBox(height: 12),
                                        SizedBox(
                                          width: 520,
                                          child: Text(
                                            l10n.statusErrorPrefix(_pickError!),
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .error,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                        ),
                        _ServerStatusPanel(
                          width: panelWidth,
                          collapsed: _rightCollapsed,
                          serverController: _serverCtrl,
                          modelFocusNode: _modelFocusNode,
                          connState: _connState,
                          lastError: _lastError,
                          health: _health,
                          models: _models,
                          modelsLoading: _modelsLoading,
                          selectedModelKey: _selectedModelKey,
                          settingModel: _settingModel,
                          modelError: _modelError,
                          onConnect: _connect,
                          onSelectModel: (key) =>
                              _selectModel(key, userInitiated: true),
                        ),
                      ],
                    ),
                    Positioned(
                      left: btnLeft.clamp(0.0, constraints.maxWidth - btnSize),
                      top: btnTop.clamp(0.0, constraints.maxHeight - btnSize),
                      child: _DividerToggleButton(
                        collapsed: _rightCollapsed,
                        onPressed: () {
                          setState(() => _rightCollapsed = !_rightCollapsed);
                          _settings.rightPanelCollapsed = _rightCollapsed;
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.16),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ImageStatusBar extends StatelessWidget {
  const _ImageStatusBar({
    required this.embeddingState,
    required this.embeddingError,
    required this.embeddingElapsedMs,
    required this.promptPoints,
    required this.predicting,
    required this.predictError,
    required this.predictScore,
    required this.predictMaskArea,
    required this.predictElapsedMs,
  });

  final _EmbeddingState embeddingState;
  final String? embeddingError;
  final double? embeddingElapsedMs;
  final List<PromptPoint> promptPoints;
  final bool predicting;
  final String? predictError;
  final double? predictScore;
  final int? predictMaskArea;
  final double? predictElapsedMs;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    final pos = promptPoints.where((p) => p.label == 1).length;
    final neg = promptPoints.where((p) => p.label == 0).length;

    String embedText;
    TextStyle? embedStyle;
    switch (embeddingState) {
      case _EmbeddingState.idle:
        embedText = l10n.embeddingStatusIdle;
        break;
      case _EmbeddingState.computing:
        embedText = l10n.embeddingStatusComputing;
        break;
      case _EmbeddingState.ready:
        embedText = l10n.embeddingStatusReady(
          (embeddingElapsedMs ?? 0).round(),
        );
        break;
      case _EmbeddingState.error:
        embedText = l10n.embeddingStatusError(
            embeddingError?.trim().isNotEmpty == true
                ? embeddingError!
                : l10n.unknownError);
        embedStyle = TextStyle(color: theme.colorScheme.error);
        break;
    }

    final promptText = l10n.promptsSummary(pos, neg);

    String? predictText;
    TextStyle? predictStyle;
    if (predicting) {
      predictText = l10n.predicting;
    } else if (predictError != null && predictError!.trim().isNotEmpty) {
      predictText = l10n.statusErrorPrefix(predictError!);
      predictStyle = TextStyle(color: theme.colorScheme.error);
    } else if (predictMaskArea != null || predictScore != null) {
      predictText = l10n.maskSummary(
        predictMaskArea ?? 0,
        (predictScore ?? 0).toStringAsFixed(4),
        (predictElapsedMs ?? 0).round(),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          embedText,
          style: embedStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 6,
          children: <Widget>[
            Text(promptText, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (predictText != null)
              Text(
                predictText,
                style: predictStyle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ],
    );
  }
}

class _ServerStatusPanel extends StatelessWidget {
  const _ServerStatusPanel({
    required this.width,
    required this.collapsed,
    required this.serverController,
    required this.modelFocusNode,
    required this.connState,
    required this.lastError,
    required this.health,
    required this.models,
    required this.modelsLoading,
    required this.selectedModelKey,
    required this.settingModel,
    required this.modelError,
    required this.onConnect,
    required this.onSelectModel,
  });

  final double width;
  final bool collapsed;
  final TextEditingController serverController;
  final FocusNode modelFocusNode;
  final _ConnState connState;
  final String? lastError;
  final Map<String, dynamic>? health;
  final List<Map<String, dynamic>> models;
  final bool modelsLoading;
  final String? selectedModelKey;
  final bool settingModel;
  final String? modelError;
  final VoidCallback onConnect;
  final ValueChanged<String> onSelectModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    final Color dotColor;
    final String statusText;
    switch (connState) {
      case _ConnState.connecting:
        dotColor = Colors.orange;
        statusText = l10n.statusConnecting;
        break;
      case _ConnState.connected:
        dotColor = Colors.green;
        statusText = l10n.statusConnected;
        break;
      case _ConnState.disconnected:
        dotColor = Colors.red;
        statusText = l10n.statusDisconnected;
        break;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      width: width,
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: collapsed
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  TextField(
                    controller: serverController,
                    decoration: InputDecoration(
                      labelText: l10n.serverAddressLabel,
                      hintText: l10n.serverAddressHint,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => onConnect(),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed:
                        connState == _ConnState.connecting ? null : onConnect,
                    child: Text(l10n.connect),
                  ),
                  const SizedBox(height: 12),
                  _modelPicker(context),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                            color: dotColor, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(statusText)),
                    ],
                  ),
                  if (lastError != null && lastError!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      l10n.statusErrorPrefix(lastError!),
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (modelError != null && modelError!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      l10n.statusErrorPrefix(modelError!),
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const Divider(height: 24),
                  Text(
                    l10n.statusDetailsTitle,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  _kv(context, l10n.statusServerOkLabel,
                      health?['ok'] == true ? 'true' : '-'),
                  _kv(
                      context,
                      l10n.statusModelKeyLabel,
                      _deepGet(health, ['model', 'model_key'])?.toString() ??
                          '-'),
                  _kv(context, l10n.statusDeviceLabel,
                      _deepGet(health, ['model', 'device'])?.toString() ?? '-'),
                  _kv(context, l10n.statusSessionsLabel,
                      health?['sessions']?.toString() ?? '-'),
                ],
              ),
            ),
    );
  }

  Widget _modelPicker(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    final downloaded =
        models.where((m) => m['downloaded'] == true).toList(growable: false);
    final keys = downloaded
        .map((m) => m['model_key']?.toString() ?? '')
        .where((k) => k.isNotEmpty)
        .toList(growable: false);

    final enabled = connState == _ConnState.connected &&
        !modelsLoading &&
        !settingModel &&
        keys.isNotEmpty;

    Widget pickerChild;
    if (keys.isEmpty) {
      pickerChild = Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          modelsLoading ? l10n.modelSelectLoading : l10n.modelSelectNone,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    } else {
      pickerChild = Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(4),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton2<String>(
            focusNode: modelFocusNode,
            // Ensure focus highlight doesn't stick around on desktop after a selection.
            onMenuStateChange: (isOpen) {
              if (!isOpen) modelFocusNode.unfocus();
            },
            buttonStyleData: const ButtonStyleData(
              overlayColor: WidgetStatePropertyAll<Color?>(Colors.transparent),
            ),
            isExpanded: true,
            value: (selectedModelKey != null && keys.contains(selectedModelKey))
                ? selectedModelKey
                : (keys.isNotEmpty ? keys.first : null),
            hint: Text(
              modelsLoading ? l10n.modelSelectLoading : l10n.modelSelectNone,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            items: keys
                .map(
                  (k) => DropdownMenuItem<String>(
                    value: k,
                    child: Text(
                      k,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(growable: false),
            onChanged: enabled
                ? (v) {
                    if (v == null) return;
                    modelFocusNode.unfocus();
                    if (v != selectedModelKey) onSelectModel(v);
                  }
                : null,
            dropdownStyleData: const DropdownStyleData(
              maxHeight: 320,
            ),
            menuItemStyleData: const MenuItemStyleData(
              height: 36,
            ),
          ),
        ),
      );
    }

    return Row(
      children: <Widget>[
        SizedBox(
          width: 54,
          child: Text(
            l10n.modelSelectLabel,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: pickerChild),
      ],
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(width: 90, child: Text(k)),
          Expanded(
            child: Text(
              v,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Object? _deepGet(Map<String, dynamic>? m, List<String> path) {
    Object? cur = m;
    for (final key in path) {
      if (cur is Map<String, dynamic>) {
        cur = cur[key];
      } else if (cur is Map) {
        cur = cur[key];
      } else {
        return null;
      }
    }
    return cur;
  }
}

class _DividerToggleButton extends StatelessWidget {
  const _DividerToggleButton(
      {required this.collapsed, required this.onPressed});

  final bool collapsed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final icon = collapsed ? Icons.chevron_left : Icons.chevron_right;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Center(child: Icon(icon, size: 20)),
        ),
      ),
    );
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'sam2_client.dart';

void main() {
  runApp(const SamFlutterApp());
}

class SamFlutterApp extends StatelessWidget {
  const SamFlutterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sam-flutter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _serverCtrl = TextEditingController(text: 'http://127.0.0.1:8000');
  final _dirCtrl = TextEditingController();

  Sam2Client? _client;
  Map<String, dynamic>? _health;

  String? _sessionId;
  bool _busy = false;

  List<File> _images = <File>[];
  File? _selectedImage;
  Uint8List? _imageBytes;
  Uint8List? _maskBytes;
  int _imgW = 0;
  int _imgH = 0;

  bool _fg = true;
  bool _multimask = false;

  double? _lastScore;
  int? _lastMaskArea;
  double? _lastElapsedMs;
  Offset? _lastClickPx;

  @override
  void dispose() {
    _serverCtrl.dispose();
    _dirCtrl.dispose();
    super.dispose();
  }

  Future<void> _runBusy(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await fn();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() async {
    await _runBusy(() async {
      final c = Sam2Client(baseUrl: _serverCtrl.text.trim());
      final h = await c.health();
      setState(() {
        _client = c;
        _health = h;
      });
    });
  }

  Future<void> _newSession() async {
    await _runBusy(() async {
      final c = _requireClient();
      final resp = await c.createSession();
      setState(() {
        _sessionId = resp['session_id'] as String?;
        _maskBytes = null;
        _lastScore = null;
        _lastMaskArea = null;
        _lastElapsedMs = null;
        _lastClickPx = null;
      });
    });
  }

  Future<void> _closeSession() async {
    final sid = _sessionId;
    if (sid == null) return;
    await _runBusy(() async {
      final c = _requireClient();
      await c.deleteSession(sid);
      setState(() {
        _sessionId = null;
        _maskBytes = null;
        _lastScore = null;
        _lastMaskArea = null;
        _lastElapsedMs = null;
        _lastClickPx = null;
      });
    });
  }

  Sam2Client _requireClient() {
    final c = _client;
    if (c == null) {
      throw StateError('Not connected. Click Connect first.');
    }
    return c;
  }

  String _requireSessionId() {
    final sid = _sessionId;
    if (sid == null || sid.isEmpty) {
      throw StateError('No session. Click New Session first.');
    }
    return sid;
  }

  Future<void> _loadDirectory() async {
    final dirPath = _dirCtrl.text.trim();
    if (dirPath.isEmpty) return;
    await _runBusy(() async {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) {
        throw ArgumentError('Directory not found: $dirPath');
      }
      final exts = <String>{'.png', '.jpg', '.jpeg', '.bmp', '.webp'};
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => exts.contains(_lowerExt(f.path)))
          .toList()
        ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      setState(() {
        _images = files;
      });
    });
  }

  String _lowerExt(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return '';
    return path.substring(dot).toLowerCase();
  }

  Future<void> _selectImage(File f) async {
    await _runBusy(() async {
      final c = _requireClient();
      final sid = _requireSessionId();

      final bytes = await f.readAsBytes();
      final resp = await c.setImage(
        sessionId: sid,
        imageBytes: bytes,
        filename: f.uri.pathSegments.isNotEmpty ? f.uri.pathSegments.last : 'image',
      );
      setState(() {
        _selectedImage = f;
        _imageBytes = bytes;
        _imgW = (resp['width'] as num).toInt();
        _imgH = (resp['height'] as num).toInt();
        _maskBytes = null;
        _lastScore = null;
        _lastMaskArea = null;
        _lastElapsedMs = null;
        _lastClickPx = null;
      });
    });
  }

  Future<void> _predictAt(Offset localPos, Size containerSize) async {
    if (_imageBytes == null || _imgW <= 0 || _imgH <= 0) return;

    final coords = _mapTapToImagePx(
      localPos: localPos,
      containerSize: containerSize,
      imageW: _imgW.toDouble(),
      imageH: _imgH.toDouble(),
    );
    if (coords == null) return;

    await _runBusy(() async {
      final c = _requireClient();
      final sid = _requireSessionId();

      final resp = await c.predict(
        sessionId: sid,
        points: <List<double>>[
          <double>[coords.dx, coords.dy],
        ],
        labels: <int>[_fg ? 1 : 0],
        multimask: _multimask,
      );

      final b64 = resp['mask_png_base64'] as String;
      final maskBytes = base64Decode(b64);
      setState(() {
        _maskBytes = Uint8List.fromList(maskBytes);
        _lastScore = (resp['score'] as num).toDouble();
        _lastMaskArea = (resp['mask_area'] as num).toInt();
        _lastElapsedMs = (resp['elapsed_ms'] as num).toDouble();
        _lastClickPx = coords;
      });
    });
  }

  // Returns null if tap is outside the displayed image region.
  Offset? _mapTapToImagePx({
    required Offset localPos,
    required Size containerSize,
    required double imageW,
    required double imageH,
  }) {
    final scale = (containerSize.width / imageW).isFinite && (containerSize.height / imageH).isFinite
        ? (containerSize.width / imageW).clamp(0.0, double.infinity)
        : 1.0;
    final scale2 = (containerSize.height / imageH).isFinite
        ? (containerSize.height / imageH).clamp(0.0, double.infinity)
        : 1.0;
    final s = scale < scale2 ? scale : scale2;

    final dispW = imageW * s;
    final dispH = imageH * s;
    final offX = (containerSize.width - dispW) / 2.0;
    final offY = (containerSize.height - dispH) / 2.0;

    final x = localPos.dx - offX;
    final y = localPos.dy - offY;
    if (x < 0 || y < 0 || x > dispW || y > dispH) return null;

    final px = (x / s).clamp(0.0, imageW - 1.0);
    final py = (y / s).clamp(0.0, imageH - 1.0);
    return Offset(px, py);
  }

  Future<void> _saveMaskNextToImage() async {
    final img = _selectedImage;
    final mask = _maskBytes;
    if (img == null || mask == null) return;
    await _runBusy(() async {
      final outPath = _withSuffix(img.path, '_mask.png');
      final outFile = File(outPath);
      await outFile.writeAsBytes(mask, flush: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved: $outPath')),
        );
      }
    });
  }

  String _withSuffix(String path, String suffix) {
    final dot = path.lastIndexOf('.');
    if (dot <= 0) return '$path$suffix';
    return '${path.substring(0, dot)}$suffix';
  }

  @override
  Widget build(BuildContext context) {
    final left = SizedBox(width: 280, child: _buildLeftPanel());
    final right = SizedBox(width: 340, child: _buildRightPanel());
    final center = Expanded(child: _buildCenterPanel());

    return Scaffold(
      appBar: AppBar(
        title: const Text('sam-flutter (SAM2)'),
        actions: <Widget>[
          IconButton(
            onPressed: _busy ? null : _connect,
            tooltip: 'Connect to server',
            icon: const Icon(Icons.link),
          ),
          IconButton(
            onPressed: (_busy || _client == null) ? null : _newSession,
            tooltip: 'New session',
            icon: const Icon(Icons.add_box_outlined),
          ),
          IconButton(
            onPressed: (_busy || _sessionId == null) ? null : _closeSession,
            tooltip: 'Close session',
            icon: const Icon(Icons.close),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: <Widget>[
          left,
          const VerticalDivider(width: 1),
          center,
          const VerticalDivider(width: 1),
          right,
        ],
      ),
    );
  }

  Widget _buildLeftPanel() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: _serverCtrl,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'http://127.0.0.1:8000',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _connect(),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: ElevatedButton(
                  onPressed: _busy ? null : _connect,
                  child: const Text('Connect'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: (_busy || _client == null) ? null : _newSession,
                  child: const Text('New Session'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _dirCtrl,
            decoration: const InputDecoration(
              labelText: 'Image folder (path)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _loadDirectory(),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _busy ? null : _loadDirectory,
            child: const Text('Load Folder'),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _images.isEmpty
                ? const Center(child: Text('No images loaded'))
                : ListView.builder(
                    itemCount: _images.length,
                    itemBuilder: (context, i) {
                      final f = _images[i];
                      final name = f.uri.pathSegments.isNotEmpty ? f.uri.pathSegments.last : f.path;
                      final selected = _selectedImage?.path == f.path;
                      return ListTile(
                        dense: true,
                        selected: selected,
                        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: _busy ? null : () => _selectImage(f),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCenterPanel() {
    final bytes = _imageBytes;
    if (bytes == null) {
      return const Center(child: Text('Select an image (after connecting + creating a session).'));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _busy
              ? null
              : (d) {
                  _predictAt(d.localPosition, size);
                },
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
              if (_maskBytes != null)
                Positioned.fill(
                  child: Opacity(
                    opacity: 0.5,
                    child: Image.memory(_maskBytes!, fit: BoxFit.contain),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRightPanel() {
    final modelKey = (_health?['model'] as Map?)?['model_key'];
    final device = (_health?['model'] as Map?)?['device'];

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Status',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          _kv('Connected', _client != null ? 'yes' : 'no'),
          _kv('Session', _sessionId ?? '(none)'),
          _kv('Model', modelKey?.toString() ?? '(unknown)'),
          _kv('Device', device?.toString() ?? '(unknown)'),
          const SizedBox(height: 12),
          Text(
            'Prompt',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: const <ButtonSegment<bool>>[
              ButtonSegment<bool>(value: true, label: Text('FG')),
              ButtonSegment<bool>(value: false, label: Text('BG')),
            ],
            selected: <bool>{_fg},
            onSelectionChanged: _busy
                ? null
                : (v) {
                    setState(() => _fg = v.first);
                  },
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Multimask'),
            value: _multimask,
            onChanged: _busy ? null : (v) => setState(() => _multimask = v),
          ),
          const Divider(),
          Text(
            'Last prediction',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          _kv('Score', _lastScore?.toStringAsFixed(4) ?? '-'),
          _kv('Mask area', _lastMaskArea?.toString() ?? '-'),
          _kv('Elapsed', _lastElapsedMs == null ? '-' : '${_lastElapsedMs!.toStringAsFixed(1)} ms'),
          _kv(
            'Click (px)',
            _lastClickPx == null ? '-' : '${_lastClickPx!.dx.toStringAsFixed(1)}, ${_lastClickPx!.dy.toStringAsFixed(1)}',
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: (_busy || _maskBytes == null || _selectedImage == null) ? null : _saveMaskNextToImage,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save mask next to image'),
          ),
          const SizedBox(height: 8),
          Text(
            'Tip: run the server with ./server/launch.sh',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(width: 90, child: Text(k)),
          Expanded(child: Text(v)),
        ],
      ),
    );
  }
}


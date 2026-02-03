import 'dart:convert';
import 'dart:io';

import 'package:dropdown_button2/dropdown_button2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

import 'app_settings.dart';

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
  static const double _rightExpandedWidth = 320.0;
  static const double _rightCollapsedWidth = 24.0;
  bool _appliedSettings = false;
  String _preferredModelKey = '';

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
      final ok = (parsed is Map<String, dynamic>) ? (parsed['ok'] == true) : false;
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
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
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
      final avail = (m['available'] is List) ? List.from(m['available'] as List) : const <Object?>[];
      final models = <Map<String, dynamic>>[];
      for (final item in avail) {
        if (item is Map) {
          models.add(Map<String, dynamic>.from(item));
        }
      }

      final currentKey = _deepGet(m, <String>['current', 'model_key'])?.toString();
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

  Future<void> _selectModel(String modelKey, {required bool userInitiated}) async {
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
        });
      } else {
        setState(() {
          _selectedModelKey = modelKey;
        });
      }
      _settings.modelKey = modelKey;
    } catch (e) {
      setState(() {
        _modelError = e.toString();
        if (userInitiated) {
          // Keep selection in sync with the server if the user action fails.
          _selectedModelKey = _deepGet(_health, <String>['model', 'model_key'])?.toString();
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final panelWidth = _rightCollapsed ? _rightCollapsedWidth : _rightExpandedWidth;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle)),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final dividerX = constraints.maxWidth - panelWidth;
          const btnSize = 28.0;
          final btnLeft = dividerX - (btnSize / 2);
          final btnTop = (constraints.maxHeight / 2) - (btnSize / 2);

          return Stack(
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Center(
                      child: Text(l10n.helloWorld),
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
                    onSelectModel: (key) => _selectModel(key, userInitiated: true),
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
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          l10n.serverPanelTitle,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
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
                    onPressed: connState == _ConnState.connecting ? null : onConnect,
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
                        decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(statusText)),
                    ],
                  ),
                  if (lastError != null && lastError!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      l10n.statusErrorPrefix(lastError!),
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (modelError != null && modelError!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      l10n.statusErrorPrefix(modelError!),
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
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
                  _kv(context, l10n.statusServerOkLabel, health?['ok'] == true ? 'true' : '-'),
                  _kv(context, l10n.statusModelKeyLabel, _deepGet(health, ['model', 'model_key'])?.toString() ?? '-'),
                  _kv(context, l10n.statusDeviceLabel, _deepGet(health, ['model', 'device'])?.toString() ?? '-'),
                  _kv(context, l10n.statusSessionsLabel, health?['sessions']?.toString() ?? '-'),
                ],
              ),
            ),
    );
  }

  Widget _modelPicker(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    final downloaded = models.where((m) => m['downloaded'] == true).toList(growable: false);
    final keys = downloaded
        .map((m) => m['model_key']?.toString() ?? '')
        .where((k) => k.isNotEmpty)
        .toList(growable: false);

    final enabled = connState == _ConnState.connected && !modelsLoading && !settingModel && keys.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(l10n.modelSelectLabel, style: theme.textTheme.labelMedium),
        const SizedBox(height: 6),
        Container(
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
              value: (selectedModelKey != null && keys.contains(selectedModelKey)) ? selectedModelKey : (keys.isNotEmpty ? keys.first : null),
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
        ),
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
  const _DividerToggleButton({required this.collapsed, required this.onPressed});

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

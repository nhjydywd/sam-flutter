import 'dart:convert';
import 'dart:io';

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
  bool _rightCollapsed = false;
  _ConnState _connState = _ConnState.disconnected;
  String? _lastError;
  static const double _rightExpandedWidth = 320.0;
  static const double _rightCollapsedWidth = 24.0;
  bool _appliedSettings = false;

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
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _connState = _ConnState.connecting;
      _lastError = null;
    });

    final base = _serverCtrl.text.trim();
    Uri uri;
    try {
      uri = Uri.parse(base);
      if (!uri.hasScheme) {
        uri = Uri.parse('http://$base');
      }
      uri = uri.replace(path: '/health');
    } catch (e) {
      setState(() {
        _connState = _ConnState.disconnected;
        _lastError = e.toString();
      });
      return;
    }

    final httpClient = HttpClient();
    try {
      final req = await httpClient.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final resp = await req.close();
      final body = await utf8.decoder.bind(resp).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('HTTP ${resp.statusCode}: $body', uri: uri);
      }
      final parsed = jsonDecode(body);
      final ok = (parsed is Map<String, dynamic>) ? (parsed['ok'] == true) : false;
      if (!ok) {
        throw StateError('health check failed');
      }
      setState(() {
        _connState = _ConnState.connected;
        _lastError = null;
      });
    } catch (e) {
      setState(() {
        _connState = _ConnState.disconnected;
        _lastError = e.toString();
      });
    } finally {
      httpClient.close(force: true);
    }
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
            connState: _connState,
            lastError: _lastError,
            onConnect: _connect,
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
    required this.connState,
    required this.lastError,
    required this.onConnect,
  });

  final double width;
  final bool collapsed;
  final TextEditingController serverController;
  final _ConnState connState;
  final String? lastError;
  final VoidCallback onConnect;

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
                  const SizedBox(height: 8),
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
                ],
              ),
            ),
    );
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

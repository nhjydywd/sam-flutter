import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:path_provider/path_provider.dart';

part 'app_settings.g.dart';

@JsonSerializable()
class _AppSettingsData {
  @JsonKey(defaultValue: 'http://127.0.0.1:8000')
  String serverUrl = 'http://127.0.0.1:8000';

  // Preferred SAM2 model key, e.g. "sam2.1_hiera_tiny".
  // Empty means "use server default/current".
  @JsonKey(defaultValue: '')
  String modelKey = '';

  @JsonKey(defaultValue: false)
  bool rightPanelCollapsed = false;

  _AppSettingsData();

  factory _AppSettingsData.fromJson(Map<String, dynamic> json) => _$AppSettingsDataFromJson(json);
  Map<String, dynamic> toJson() => _$AppSettingsDataToJson(this);
}

class AppSettings extends ChangeNotifier {
  AppSettings() {
    _load();
  }

  bool _loaded = false;
  bool get loaded => _loaded;

  _AppSettingsData _data = _AppSettingsData();

  String get serverUrl => _data.serverUrl;
  set serverUrl(String value) {
    if (_data.serverUrl != value) {
      _data.serverUrl = value;
      notifyListeners();
      _scheduleSave();
    }
  }

  String get modelKey => _data.modelKey;
  set modelKey(String value) {
    if (_data.modelKey != value) {
      _data.modelKey = value;
      notifyListeners();
      _scheduleSave();
    }
  }

  bool get rightPanelCollapsed => _data.rightPanelCollapsed;
  set rightPanelCollapsed(bool value) {
    if (_data.rightPanelCollapsed != value) {
      _data.rightPanelCollapsed = value;
      notifyListeners();
      _scheduleSave();
    }
  }

  bool _saveScheduled = false;
  void _scheduleSave() {
    if (_saveScheduled) return;
    _saveScheduled = true;
    Future.microtask(() async {
      _saveScheduled = false;
      await _save();
    });
  }

  Future<Directory> _getAppDir() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}sam_flutter');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } catch (_) {
      // In widget tests, platform plugins may be unavailable. Fall back to a temp dir.
      final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}sam_flutter');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
  }

  Future<File> _settingsFile() async {
    final dir = await _getAppDir();
    return File('${dir.path}${Platform.pathSeparator}settings.json');
  }

  Future<void> _load() async {
    try {
      final f = await _settingsFile();
      if (await f.exists()) {
        final content = await f.readAsString();
        final json = jsonDecode(content);
        if (json is Map<String, dynamic>) {
          _data = _AppSettingsData.fromJson(json);
        } else if (json is Map) {
          _data = _AppSettingsData.fromJson(Map<String, dynamic>.from(json));
        }
      }
    } catch (_) {
      // Keep defaults on any parse/io error.
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  Future<void> _save() async {
    try {
      final f = await _settingsFile();
      await f.writeAsString(jsonEncode(_data.toJson()));
    } catch (_) {
      // Ignore persistence errors (e.g. tests / permissions).
    }
  }
}

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_AppSettingsData _$AppSettingsDataFromJson(Map<String, dynamic> json) =>
    _AppSettingsData()
      ..serverUrl = json['serverUrl'] as String? ?? 'http://127.0.0.1:8000'
      ..rightPanelCollapsed = json['rightPanelCollapsed'] as bool? ?? false;

Map<String, dynamic> _$AppSettingsDataToJson(_AppSettingsData instance) =>
    <String, dynamic>{
      'serverUrl': instance.serverUrl,
      'rightPanelCollapsed': instance.rightPanelCollapsed,
    };

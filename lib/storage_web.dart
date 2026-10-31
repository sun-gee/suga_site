import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

// Everything lives in the browser's localStorage (a few MB per site). Sounds are stored as base64 WAV.
const _settingsKey = 'suga.settings';
const _soundPrefix = 'suga.sound.';

web.Storage get _store => web.window.localStorage;

Future<String?> readSettings() async => _store.getItem(_settingsKey);

Future<void> writeSettings(String json) async => _store.setItem(_settingsKey, json);

/// Every saved custom sound: name -> WAV bytes.
Future<Map<String, Uint8List>> loadSounds() async => {
  for (var i = 0; i < _store.length; i++)
    if (_store.key(i) case final key? when key.startsWith(_soundPrefix))
      key.substring(_soundPrefix.length): base64Decode(_store.getItem(key)!),
};

/// Saves [bytes] as custom sound [name], replacing any sound with that name. Throws if storage is full.
Future<void> saveSound(String name, Uint8List bytes) async => _store.setItem('$_soundPrefix$name', base64Encode(bytes));

Future<void> deleteSound(String name) async => _store.removeItem('$_soundPrefix$name');

/// The web recorder ignores the path and returns a blob URL instead.
Future<String> recordingPath() async => '';

/// The bytes of a finished recording, from the blob URL the recorder returned.
Future<Uint8List> readRecording(String url) async {
  final response = await web.window.fetch(url.toJS).toDart;
  return (await response.arrayBuffer().toDart).toDart.asUint8List();
}

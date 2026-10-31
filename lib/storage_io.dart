import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<String> _supportPath(String name) async =>
    '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}$name';

Future<File> _settingsFile() async => File(await _supportPath('settings.json'));
Future<Directory> _soundsDir() async => Directory(await _supportPath('custom_sounds'));

/// A file's name without its folder or extension.
String _stem(String path) => path.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.[^.]+$'), '');

Future<String?> readSettings() async {
  final file = await _settingsFile();
  return await file.exists() ? file.readAsString() : null;
}

Future<void> writeSettings(String json) async => (await _settingsFile()).writeAsString(json);

/// Every saved custom sound: name -> WAV bytes.
Future<Map<String, Uint8List>> loadSounds() async {
  final dir = await _soundsDir();
  if (!await dir.exists()) return {};
  final files = await dir.list().where((e) => e is File).cast<File>().toList();
  return {for (final file in files) _stem(file.path): await file.readAsBytes()};
}

/// Saves [bytes] as custom sound [name], replacing any sound with that name.
Future<void> saveSound(String name, Uint8List bytes) async {
  final dir = await _soundsDir();
  await dir.create(recursive: true);
  await deleteSound(name);
  await File('${dir.path}${Platform.pathSeparator}$name.wav').writeAsBytes(bytes);
}

Future<void> deleteSound(String name) async {
  final dir = await _soundsDir();
  if (!await dir.exists()) return;
  await for (final file in dir.list()) {
    if (file is File && _stem(file.path) == name) await file.delete();
  }
}

/// Where the recorder should write a new recording.
Future<String> recordingPath() async =>
    '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}recording_${DateTime.now().millisecondsSinceEpoch}.wav';

/// The bytes of a finished recording, from the path the recorder returned.
Future<Uint8List> readRecording(String path) => File(path).readAsBytes();

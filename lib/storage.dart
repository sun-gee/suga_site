/// Saved settings, custom sounds and recordings: files on Android, iOS and desktop, browser storage on the web.
library;

export 'storage_io.dart' if (dart.library.js_interop) 'storage_web.dart';

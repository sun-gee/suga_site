/// Keeps the screen on while the metronome plays. Only needed on the web, where a phone that goes to sleep also
/// stops the page's audio.
library;

export 'screen_awake_io.dart' if (dart.library.js_interop) 'screen_awake_web.dart';

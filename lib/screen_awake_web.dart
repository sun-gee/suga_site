import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

bool _wanted = false;
bool _listening = false;
web.WakeLockSentinel? _lock;

void keepScreenAwake(bool awake) {
  _wanted = awake;
  if (!_listening) {
    _listening = true;
    // The browser drops the lock whenever the tab is hidden, so take it again on coming back.
    web.document.addEventListener('visibilitychange', ((web.Event _) {
      _sync();
    }).toJS);
  }
  _sync();
}

Future<void> _sync() async {
  try {
    if (!_wanted) {
      final lock = _lock;
      _lock = null;
      await lock?.release().toDart;
    } else if ((_lock == null || _lock!.released) && web.document.visibilityState == 'visible') {
      final lock = await web.window.navigator.wakeLock.request('screen').toDart;
      _lock = lock;
      if (!_wanted) await _sync(); // Stopped while the request was pending
    }
  } catch (e) {
    debugPrint('Could not keep the screen on: $e'); // Not every browser supports it; the app still works
  }
}

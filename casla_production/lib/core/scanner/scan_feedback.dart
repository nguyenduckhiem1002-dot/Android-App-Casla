import 'dart:async';

import 'package:flutter/services.dart';

/// Confirms a scan without asking the operator to look at the screen.
///
/// On a shop floor the handset is often at hip height, held in a gloved hand,
/// pointed at a pallet. Haptics alone are easy to miss through a glove and a
/// wrist strap, and they cannot distinguish "accepted" from "rejected", so
/// success and failure get audibly different feedback as well.
class ScanFeedback {
  static bool _muted = false;

  const ScanFeedback._();

  /// Silences audio and haptics. Used by tests so a widget pump does not queue
  /// platform channel calls that never resolve.
  static void setMuted(bool muted) => _muted = muted;

  /// A code was read and accepted.
  static void success() {
    if (_muted) return;
    unawaited(SystemSound.play(SystemSoundType.click));
    unawaited(HapticFeedback.mediumImpact());
  }

  /// A code was read but rejected: wrong format, expired, out of scope.
  ///
  /// Two spaced alerts, because a single buzz reads as "done" to someone who
  /// is not looking and would send them on to the next pallet with nothing
  /// recorded.
  static void failure() {
    if (_muted) return;
    unawaited(SystemSound.play(SystemSoundType.alert));
    unawaited(
      Future<void>(() async {
        await HapticFeedback.heavyImpact();
        await Future<void>.delayed(const Duration(milliseconds: 140));
        await HapticFeedback.heavyImpact();
      }),
    );
  }

  /// A duplicate of the code just handled. Quieter than [success] so a reader
  /// that fires twice does not sound like two accepted scans.
  static void duplicate() {
    if (_muted) return;
    unawaited(HapticFeedback.selectionClick());
  }

  /// A key press on the on-screen number pad.
  static void keyPress() {
    if (_muted) return;
    unawaited(HapticFeedback.selectionClick());
  }
}

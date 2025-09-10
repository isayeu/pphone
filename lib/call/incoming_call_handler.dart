import '../services/ringtone_service.dart';

/// Example handler showing where to start/stop ringtone during incoming call flow.
/// Adapt this to your existing call manager / UI code.
class IncomingCallHandler {
  final RingtoneService _ringtone = RingtoneService.instance;

  IncomingCallHandler() {
    // init once
    _ringtone.init();
  }

  /// Should be called when an incoming call event is received.
  void onIncomingCall({required String from}) {
    // Start playing ringtone in loop
    _ringtone.playRingtone(assetPath: 'sounds/ringtone.mp3');

    // Show incoming call UI / notification / screen
    _showIncomingCallUi(from);
  }

  void _showIncomingCallUi(String from) {
    // Пример: открыть экран входящего вызова или отправить нотификацию.
    // Интегрируйте с вашей UI-логикой.
    // ignore: avoid_print
    print('Incoming call from $from — show UI');
  }

  /// Call when user accepts the call (or when outgoing connection established)
  void onAcceptCall() {
    // Stop ringtone immediately
    _ringtone.stop();

    // Continue with WebRTC setup / audio switch
  }

  /// Call when user rejects the call or caller cancelled
  void onRejectOrCancelCall() {
    _ringtone.stop();

    // Close UI / cleanup
  }

  /// Call when remote hangs up / call ended
  void onCallEnded() {
    _ringtone.stop();
  }
}

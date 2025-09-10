import 'package:audioplayers/audioplayers.dart';

/// Singleton service to play/stop ringtone and ringback from assets.
/// Usage:
///   await RingtoneService.instance.init();
///   RingtoneService.instance.playRingtone();
///   RingtoneService.instance.stop();
class RingtoneService {
  RingtoneService._internal();
  static final RingtoneService instance = RingtoneService._internal();

  final AudioPlayer _player = AudioPlayer();

  /// call once at app start or before first play
  Future<void> init() async {
    // loop the ringtone until stopped
    await _player.setReleaseMode(ReleaseMode.loop);
  }

  /// Play ringtone from assets. assetPath — relative to assets/ (e.g. 'sounds/ringtone.mp3')
  Future<void> playRingtone({String assetPath = 'sounds/ringtone.mp3', double volume = 1.0}) async {
    try {
      await _player.setVolume(volume);
      // AssetSource expects path relative to assets declared in pubspec
      await _player.play(AssetSource(assetPath));
    } catch (e) {
      // Replace with project logger if available
      // ignore: avoid_print
      print('RingtoneService.playRingtone error: $e');
    }
  }

  /// Stop playback (call on accept/reject/cancel)
  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (e) {
      // ignore: avoid_print
      print('RingtoneService.stop error: $e');
    }
  }

  Future<void> dispose() async {
    try {
      await _player.dispose();
    } catch (_) {}
  }
}
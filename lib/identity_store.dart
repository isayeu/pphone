import 'dart:convert';
import 'dart:io' show File; // на web этот импорт игнорируется компилятором
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

class IdentityStore {
  SimpleKeyPair? _idKey;   // X25519 (демо)
  String? _fingerprint;
  File? _file;             // null на web

  Future<void> init() async {
    try {
      if (!kIsWeb) {
        final dir = await getApplicationSupportDirectory();
        _file = File('${dir.path}/identity.json');
      }

      if (!kIsWeb && _file != null && await _file!.exists()) {
        // Читаем из файла (Android/Linux/Desktop)
        final j = jsonDecode(await _file!.readAsString());
        final pub = SimplePublicKey(base64Decode(j['pub']), type: KeyPairType.x25519);
        _idKey = SimpleKeyPairData(
          base64Decode(j['priv']),
          publicKey: pub,
          type: KeyPairType.x25519,
        );
        _fingerprint = j['fp'];
        return;
      }

      // Файл недоступен или мы на web -> создаём новую идентичность в памяти
      _idKey = await X25519().newKeyPair();
      final pub = await _idKey!.extractPublicKey();
      final hash = await Sha256().hash(pub.bytes);
      _fingerprint = base64Encode(hash.bytes).substring(0, 24);

      // Сохраним на диске, если не web
      if (!kIsWeb && _file != null) {
        await _file!.create(recursive: true);
        await _file!.writeAsString(jsonEncode({
          'pub': base64Encode(pub.bytes),
          'priv': base64Encode(await _idKey!.extractPrivateKeyBytes()),
          'fp': _fingerprint,
        }));
      }
    } catch (e) {
      // Любая ошибка — не валим UI: генерим временную идентичность в памяти
      _idKey ??= await X25519().newKeyPair();
      final pub = await _idKey!.extractPublicKey();
      final hash = await Sha256().hash(pub.bytes);
      _fingerprint ??= base64Encode(hash.bytes).substring(0, 24);
    }
  }

  // Безопасные геттеры
  bool get isReady => _fingerprint != null;
  String get fingerprint => _fingerprint ?? '(not ready)';
  Future<SimplePublicKey> publicKey() async =>
      (_idKey ??= await X25519().newKeyPair()).extractPublicKey();
}

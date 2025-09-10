// address_book.dart
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart'; // для ChangeNotifier

class Contact {
  final String fingerprint; // короткий fp (ключ контакта)
  String name;
  Map<String, dynamic>? pubBundle; // можно хранить доп. публичные ключи

  Contact({required this.fingerprint, required this.name, this.pubBundle});

  Map<String, dynamic> toJson() => {
        'fp': fingerprint,
        'name': name,
        'pub': pubBundle,
      };

  static Contact fromJson(Map<String, dynamic> j) =>
      Contact(fingerprint: j['fp'], name: j['name'], pubBundle: j['pub']);
}

class AddressBook extends ChangeNotifier {
  late final File _file;
  final Map<String, Contact> _byFp = {};

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _file = File('${dir.path}/contacts.json');
    if (await _file.exists()) {
      final txt = await _file.readAsString();
      if (txt.trim().isNotEmpty) {
        final list = (jsonDecode(txt) as List).cast<Map<String, dynamic>>();
        for (final m in list) {
          final c = Contact.fromJson(m);
          _byFp[c.fingerprint] = c;
        }
      }
    } else {
      await _file.create(recursive: true);
      await _file.writeAsString('[]');
    }

    // Уведомляем UI, что данные загружены
    notifyListeners();
  }

  Future<void> _save() async {
    final list = _byFp.values.map((c) => c.toJson()).toList();
    await _file.writeAsString(const JsonEncoder.withIndent('  ').convert(list));
  }

  Future<void> add(Contact c) async {
    _byFp[c.fingerprint] = c;
    await _save();
    notifyListeners();
  }

  Future<void> remove(String fingerprint) async {
    _byFp.remove(fingerprint);
    await _save();
    notifyListeners();
  }

  Contact? byFp(String fingerprint) => _byFp[fingerprint];

  List<Contact> get all => _byFp.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}

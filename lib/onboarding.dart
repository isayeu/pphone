import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:clipboard/clipboard.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'address_book.dart';
import 'identity_store.dart';

class OnboardingPage extends StatefulWidget {
  final IdentityStore identity;
  final AddressBook book;
  const OnboardingPage({super.key, required this.identity, required this.book});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  String? myCard;
  String? peerCard;
  final _nameCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _buildMyCard();
  }

  Future<void> _buildMyCard() async {
    myCard = jsonEncode({'type': 'card', 'fp': widget.identity.fingerprint});
    setState(() {});
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _savePeer() async {
    try {
      final data = jsonDecode(peerCard!);
      if (data['type'] != 'card' || data['fp'] == null) {
        return _snack('Неверная карточка');
      }
      final fp = data['fp'] as String;
      final name = _nameCtl.text.trim().isEmpty
          ? 'Peer ${fp.substring(0, 6)}'
          : _nameCtl.text.trim();
      await widget.book
          .add(Contact(fingerprint: fp, name: name, pubBundle: data));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _snack('Ошибка: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Onboarding (one-time)')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Шаг 1 — поделись своей карточкой',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  onPressed: myCard == null
                      ? null
                      : () => FlutterClipboard.copy(myCard!),
                  child: const Text('Copy My Card'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: myCard == null
                      ? null
                      : () {
                          try {
                            showDialog(
                              context: context,
                              builder: (_) => AlertDialog(
                                title: const Text('My Card (QR)'),
                                content: SizedBox(
                                  width: 320,
                                  height: 360,
                                  child: Center(
                                    child: SingleChildScrollView(
                                      child: QrImageView(
                                        data: myCard!,
                                        size: 280,
                                        version: QrVersions.auto,
                                      ),
                                    ),
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('Close'),
                                  )
                                ],
                              ),
                            );
                          } catch (e) {
                            _snack('QR render error: $e');
                          }
                        },
                  child: const Text('Show My Card (QR)'),
                ),
              ],
            ),
            const Divider(height: 24),
            const Text('Шаг 2 — импорт карточки собеседника',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: () async {
                    final txt = await FlutterClipboard.paste();
                    setState(() => peerCard = txt);
                  },
                  child: const Text('Paste Peer Card'),
                ),
                FilledButton(
                  onPressed: () async {
                    final s = await Navigator.of(context).push<String?>(
                      MaterialPageRoute(builder: (_) => const _QRScanPage()),
                    );
                    if (s != null) setState(() => peerCard = s);
                  },
                  child: const Text('Scan Peer Card'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameCtl,
              decoration: const InputDecoration(labelText: 'Имя контакта'),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration:
                    BoxDecoration(border: Border.all(color: Colors.white24)),
                child: Text(peerCard ?? '(сюда попадёт JSON карточки)'),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: peerCard == null ? null : _savePeer,
                child: const Text('Сохранить в адресную книгу'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QRScanPage extends StatefulWidget {
  const _QRScanPage({super.key});
  @override
  State<_QRScanPage> createState() => _QRScanPageState();
}

class _QRScanPageState extends State<_QRScanPage> {
  final controller = MobileScannerController();
  bool _done = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR')),
      body: MobileScanner(
        controller: controller,
        onDetect: (capture) {
          if (_done) return;
          for (final b in capture.barcodes) {
            final raw = b.rawValue;
            if (raw != null && raw.contains('"type":"card"')) {
              _done = true;
              Navigator.of(context).pop(raw);
              break;
            }
          }
        },
      ),
    );
  }
}

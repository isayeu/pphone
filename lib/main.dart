import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'address_book.dart';
import 'identity_store.dart';
import 'onboarding.dart';
import 'signaling.dart';
import 'utils.dart';

final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  runApp(const PPhoneApp());
}

class PPhoneApp extends StatefulWidget {
  const PPhoneApp({super.key});
  @override
  State<PPhoneApp> createState() => _PPhoneAppState();
}

class _PPhoneAppState extends State<PPhoneApp> {
  late final IdentityStore identity;
  late final AddressBook book;
  late final Signaling signaling;

  int _tab = 0;
  String _pcStatus = 'Idle';
  bool _ready = false;
  bool _inCall = false;
  String? _bootError;

  DateTime _callStartTime = DateTime(0);
  bool _expectingOffer = false;
  DateTime _expectingOfferTime = DateTime(0);
  String? _activeTargetFp;

  @override
  void initState() {
    super.initState();
    identity = IdentityStore();
    book = AddressBook();
    signaling = Signaling(roomId: 'default_room');

    _setupSignalingCallbacks();
    _bootstrap();
  }

  void _setupSignalingCallbacks() {
    signaling.onConnectionState = (state) {
      if (mounted) setState(() => _pcStatus = state);
    };

    signaling.onCallStateChanged = () {
      if (mounted) setState(() => _inCall = signaling.isInCall);

      // Обрабатываем завершение вызова
      if (signaling.callState == CallState.idle && _inCall) {
        _inCall = false;
        _pcStatus = 'Вызов завершен';
      }

      // ДОБАВЛЕНО: показываем уведомление о входящем звонке
      if (signaling.callState == CallState.ringing) {
        _showIncomingCallDialog();
      }
    };

    signaling.onWsStateChanged = () {
      if (mounted) setState(() {});
    };

    signaling.onRemoteTrack = (track) {
      if (track.kind == 'audio') {
        if (mounted) setState(() => _pcStatus = 'Audio connected');
      }
    };
  }

  Future<void> _bootstrap() async {
    try {
      await identity.init();
      await book.init();

      // Всегда подключаемся к своей персональной комнате
      signaling.roomId = personalRoom(identity.fingerprint);

      // ТОЛЬКО WebRTC и WebSocket
      await signaling.init(audio: true, video: false);
      await signaling.connect();

      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() {
        _bootError = e.toString();
        _ready = true;
      });
    }
  }

  Future<void> _acceptIncomingCall(String fromFp, String offerSdp) async {
    try {
      // Убеждаемся, что мы в правильной комнате
      final expectedRoom = symmetricRoom(identity.fingerprint, fromFp);
      if (signaling.roomId != expectedRoom) {
        signaling.roomId = expectedRoom;
        await signaling.connect(forceReconnect: true);
      }

      await signaling.acceptOfferSdpAndAnswer(offerSdp);
      if (mounted) {
        setState(() => _inCall = true);
      }
    } catch (e) {
      print('Error accepting call: $e');
      _cleanupCall();
    }
  }

  @override
  void dispose() {
    signaling.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'pphone',
      navigatorKey: navigatorKey,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData.dark(),
      home: _ready ? _buildHome() : _buildLoading(),
    );
  }

  Widget _buildLoading() {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildHome() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('pphone'),
        actions: _buildAppBarActions(),
      ),
      body: _tab == 0
          ? ContactsPage(identity: identity, book: book)
          : CallsPage(
              identity: identity,
              book: book,
              signaling: signaling,
              onCallStart: _handleCallStart,
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.people), label: 'Contacts'),
          NavigationDestination(icon: Icon(Icons.phone), label: 'Calls'),
        ],
      ),
      floatingActionButton: _inCall ? _buildCallControls() : null,
    );
  }

  // ДОБАВЛЕНО: универсальная кнопка для разных состояний вызова
  Widget _buildFloatingActionButton() {
    if (signaling.callState == CallState.ringing) {
      // Показываем кнопки принятия/отклонения при входящем звонке
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FloatingActionButton(
            onPressed: () {
              signaling.rejectCall();
              setState(() {});
            },
            backgroundColor: Colors.red,
            child: const Icon(Icons.call_end),
          ),
          const SizedBox(width: 20),
          FloatingActionButton(
            onPressed: () {
              signaling.acceptCall();
              setState(() {});
            },
            backgroundColor: Colors.green,
            child: const Icon(Icons.call),
          ),
        ],
      );
    } else if (_inCall) {
      // Кнопки управления активным звонком
      return _buildCallControls();
    }

    return const SizedBox.shrink();
  }

  List<Widget> _buildAppBarActions() {
    String callStatus = '';
    Color callStatusColor = Colors.white;

    switch (signaling.callState) {
      case CallState.ringing:
        callStatus = 'Входящий вызов!';
        callStatusColor = Colors.orange;
        break;
      case CallState.connecting:
        callStatus = 'Соединение...';
        callStatusColor = Colors.blue;
        break;
      case CallState.inCall:
        callStatus = 'Разговор';
        callStatusColor = Colors.green;
        break;
      case CallState.idle:
        callStatus = _pcStatus;
        break;
    }

    return [
      IconButton(
        icon: Icon(
          signaling.isConnected ? Icons.wifi : Icons.wifi_off,
          color: signaling.isConnected ? Colors.green : Colors.red,
          size: 20,
        ),
        onPressed: _showConnectionInfo,
      ),
      if (_bootError != null)
        const Tooltip(
          message: 'Ошибка загрузки',
          child: Icon(Icons.error_outline, color: Colors.orange),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(callStatus,
                style: TextStyle(fontSize: 10, color: callStatusColor)),
            Text(
              signaling.isConnected ? 'WS: Connected' : 'WS: Disconnected',
              style: TextStyle(
                fontSize: 8,
                color: signaling.isConnected ? Colors.green : Colors.red,
              ),
            ),
          ],
        ),
      ),
    ];
  }

  void _showIncomingCallDialog() {
    if (ModalRoute.of(navigatorKey.currentContext!)?.isCurrent ?? true) {
      showDialog(
        context: navigatorKey.currentContext!,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Входящий вызов'),
          content: const Text('Вам звонят!'),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                signaling.rejectCall();
                // После отклонения возвращаемся в персональную комнату
                final personalRoomId = personalRoom(identity.fingerprint);
                if (signaling.roomId != personalRoomId) {
                  signaling.roomId = personalRoomId;
                  await signaling.connect(forceReconnect: true);
                }
              },
              child: const Text('Отклонить', style: TextStyle(color: Colors.red)),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                signaling.acceptCall();
              },
              child: const Text('Принять', style: TextStyle(color: Colors.green)),
            ),
          ],
        ),
      );
    }
  }

  void _showConnectionInfo() {
    showDialog(
      context: navigatorKey.currentContext!,
      builder: (context) => AlertDialog(
        title: const Text('Connection Status'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('WebSocket: ${signaling.isConnected ? "✅ Connected" : "❌ Disconnected"}'),
            Text('Room: ${signaling.roomId}'),
            Text('WebRTC: $_pcStatus'),
            if (_bootError != null) Text('Error: $_bootError'),
          ],
        ),
        actions: [
          if (!signaling.isConnected)
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                await signaling.connect();
                setState(() {});
              },
              child: const Text('Reconnect'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _handleCallStart(String fp) async {
    try {
      setState(() {
        _activeTargetFp = fp;
        _inCall = true;
        _callStartTime = DateTime.now();
      });

      // Комната получателя = его персональная комната
      final targetRoom = personalRoom(fp);
      signaling.roomId = targetRoom;
      await signaling.connect(forceReconnect: true);

      // Даем время на установление соединения
      await Future.delayed(Duration(milliseconds: 1000));

      // Инициируем вызов
      print('Making call to $fp in room: $targetRoom');
      signaling.makeCall();
    } catch (e) {
      print('Error starting call: $e');
      setState(() => _inCall = false);
    }
  }

  Future<void> _cleanupCall() async {
    _debugPrint('UI cleanup started');

    if (mounted) {
      setState(() {
        _inCall = false;
        _pcStatus = 'Завершение вызова...';
      });
    }

    _expectingOffer = false;
    _callStartTime = DateTime(0);
    _activeTargetFp = null;

    // Используем новый метод hangup
    await signaling.hangup();

    // Возвращаемся в персональную комнату
    final personalRoomId = personalRoom(identity.fingerprint);
    if (signaling.roomId != personalRoomId) {
      signaling.roomId = personalRoomId;

      try {
        await signaling.connect(forceReconnect: true)
            .timeout(Duration(seconds: 5));
      } on TimeoutException {
        _debugPrint('Timeout reconnecting to personal room');
      } catch (e) {
        _debugPrint('Error reconnecting: $e');
      }
    }

    if (mounted) {
      setState(() {
        _pcStatus = 'Готов к вызовам';
      });
    }

    _debugPrint('UI cleanup completed');
  }

  // Добавляем отладочную печать
  void _debugPrint(String message) {
    print('[Main ${DateTime.now()}] $message');
  }

  Widget _buildCallControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FloatingActionButton.small(
          onPressed: signaling.toggleSpeaker,
          child: Icon(signaling.speakerOn ? Icons.volume_up : Icons.volume_off),
        ),
        const SizedBox(width: 20),
        FloatingActionButton(
          onPressed: () async {
            // Показываем индикатор загрузки
            if (mounted) {
              setState(() {
                _pcStatus = 'Завершение...';
              });
            }

            await _cleanupCall();
          },
          backgroundColor: Colors.red,
          child: const Icon(Icons.call_end),
        ),
      ],
    );
  }
}

// ContactsPage (заменяет предыдущую Stateless версию)
class ContactsPage extends StatefulWidget {
  final IdentityStore identity;
  final AddressBook book;

  const ContactsPage({
    super.key,
    required this.identity,
    required this.book,
  });

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  void _onBookChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.book.addListener(_onBookChanged);
  }

  @override
  void didUpdateWidget(covariant ContactsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.book != widget.book) {
      oldWidget.book.removeListener(_onBookChanged);
      widget.book.addListener(_onBookChanged);
    }
  }

  @override
  void dispose() {
    widget.book.removeListener(_onBookChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contacts = widget.book.all;

    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.fingerprint),
          title: const Text('My fingerprint'),
          subtitle: Text(widget.identity.fingerprint),
          trailing: FilledButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => OnboardingPage(identity: widget.identity, book: widget.book),
              ),
            ),
            child: const Text('Onboarding'),
          ),
        ),
        const Divider(),
        Expanded(
          child: contacts.isEmpty
              ? const Center(child: Text('Нет контактов'))
              : ListView.builder(
                  itemCount: contacts.length,
                  itemBuilder: (_, i) {
                    final contact = contacts[i];
                    return ListTile(
                      leading: const Icon(Icons.person),
                      title: Text(contact.name),
                      subtitle: Text(contact.fingerprint),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () async {
                          // удаляем и ждём — после удаления AddressBook вызовет notifyListeners()
                          await widget.book.remove(contact.fingerprint);
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// CallsPage остаётся без изменений (внизу файла)
class CallsPage extends StatelessWidget {
  final IdentityStore identity;
  final AddressBook book;
  final Signaling signaling;
  final ValueChanged<String> onCallStart;

  const CallsPage({
    super.key,
    required this.identity,
    required this.book,
    required this.signaling,
    required this.onCallStart,
  });

  @override
  Widget build(BuildContext context) {
    final contacts = book.all;

    return Column(
      children: [
        const ListTile(
          title: Text('Контакты'),
          subtitle: Text('Все контакты доступны для вызова через интернет'),
        ),
        const Divider(),
        Expanded(
          child: ListView.builder(
            itemCount: contacts.length,
            itemBuilder: (_, i) {
              final contact = contacts[i];

              return ListTile(
                leading: const Icon(Icons.person),
                title: Text(contact.name),
                subtitle: Text(contact.fingerprint),
                trailing: FilledButton(
                  onPressed: () => onCallStart(contact.fingerprint),
                  child: const Text('Call'),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

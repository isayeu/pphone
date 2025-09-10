// lib/signaling.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

enum CallState { idle, ringing, connecting, inCall }

class Signaling {
  // Добавляем флаги для защиты от повторных вызовов
  bool _isCleaningUp = false;
  bool _inCallActive = false;
  MediaStreamTrack? _remoteAudioTrack;

  String roomId;
  final String signalingUrl;

  Signaling({required this.roomId, this.signalingUrl = 'wss://prodg.winex.org/signal'});

  RTCPeerConnection? _pc;
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  Timer? _hbTimer;
  Timer? _statsTimer;
  int _missedPongs = 0;
  String? _wsRoom;

  // Состояние вызова
  CallState callState = CallState.idle;
  RTCSessionDescription? _pendingOffer;
  bool speakerOn = false;
  bool _wsConnected = false;

  // Callbacks
  void Function(String state)? onConnectionState;
  void Function(MediaStreamTrack track)? onRemoteTrack;
  void Function(RTCIceCandidate cand)? onLocalIce;
  VoidCallback? onCallStateChanged;
  VoidCallback? onWsStateChanged;

  bool get isConnected => _wsConnected;
  bool get isInCall => callState == CallState.inCall;

  // Добавляем отладочную печать
  void _debugPrint(String message) {
    print('[Signaling ${DateTime.now()}] $message');
  }

  Future<void> init({bool video = false, bool audio = true}) async {
    if (_pc != null) return;

    final config = {
      'iceServers': [
        {'urls': ['stun:stun.l.google.com:19302']},
        {
          'urls': [
            'turn:prodg.winex.org:3478?transport=udp',
            'turn:prodg.winex.org:3478?transport=tcp'
          ],
          'username': 'pphone',
          'credential': 'pphone_secret',
        },
        {
          'urls': ['turns:prodg.winex.org:5349?transport=tcp'],
          'username': 'pphone',
          'credential': 'pphone_secret',
        },
      ],
    };

    _pc = await createPeerConnection(config);

    // Получаем медиа потоки
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': audio,
      'video': video,
    });

    // Добавляем треки в peer connection
    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    // Устанавливаем обработчики
    _pc!.onIceConnectionState = (state) {
      _debugPrint('ICE State: $state');
      onConnectionState?.call(state.toString());

      // Автоматический cleanup при потере соединения
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        _debugPrint('ICE connection lost, cleaning up');
        _cleanupCall();
      }
    };

    _pc!.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        onLocalIce?.call(candidate);
        _send({
          'type': 'candidate',
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      }
    };

    _pc!.onTrack = (event) {
      if (event.track.kind == 'audio') {
        // Сохраняем удаленный трек для последующей очистки
        _remoteAudioTrack = event.track;
        _remoteStream = event.streams.isNotEmpty ? event.streams.first : null;

        onRemoteTrack?.call(event.track);
        // Автоматически переключаем на динамик при входящем аудио
        setSpeakerphoneOn(true);

        // Запускаем сбор статистики
        _startStatsDump();
      }
    };
  }

  // helper: если _pc был закрыт — повторно инициализируем
  Future<void> _ensurePcInitialized({bool audio = true, bool video = false}) async {
    if (_pc == null) {
      _debugPrint('PC is null, re-initializing');
      await init(video: video, audio: audio);
    }
  }

  // Добавляем сбор статистики
  void _startStatsDump() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        if (_pc == null) return;

        final stats = await _pc!.getStats();
        // FIXED: Итерация через список напрямую вместо .values
        for (final report in stats) {
          try {
            final type = report.type;
            final values = report.values ?? <String, dynamic>{};

            if (type == 'outbound-rtp') {
              final isAudio = (values['kind'] == 'audio') ||
                              (values['mediaType'] == 'audio') ||
                              (values['mimeType'] != null && values['mimeType'].toString().contains('audio'));
              if (isAudio) {
                final bytesSent = values['bytesSent'] ?? values['bytes_sent'] ?? 'n/a';
                final packetsSent = values['packetsSent'] ?? values['packets_sent'] ?? 'n/a';
                _debugPrint('[STATS] audio bytesSent=${bytesSent} packetsSent=${packetsSent}');
              }
            }
          } catch (e) {
            _debugPrint('Stats report error: $e');
          }
        }
      } catch (e) {
        _debugPrint('Stats error: $e');
      }
    });
  }

  Future<void> connect({bool forceReconnect = false}) async {
    _debugPrint('Connecting to room: $roomId, force: $forceReconnect');
    // Если нужно переподключиться или комната изменилась
    if (_ws != null && (_wsRoom != roomId || forceReconnect)) {
      _debugPrint('Disconnecting from previous room: $_wsRoom');
      await disconnect();
    }

    // Если есть объект _ws но флаг _wsConnected=false — считаем его "stale" и закрываем
    if (_ws != null) {
      if (_wsConnected && _wsRoom == roomId && !forceReconnect) {
        _debugPrint('Already connected to correct room');
        return;
      }

      _debugPrint('Stale or mismatched ws object detected, closing before reconnect');
      await close();
    }

    try {
      _ws = WebSocketChannel.connect(Uri.parse(signalingUrl));
      _wsSub = _ws!.stream.listen(_handleMessage, onError: _handleError, onDone: _handleDone);

      // Ждем подключения перед отправкой join
      await Future.delayed(Duration(milliseconds: 100));

      _send({'type': 'join', 'room': roomId});
      _wsRoom = roomId;
      _startHeartbeat();

      _wsConnected = true;
      onWsStateChanged?.call();

    } catch (e) {
      _debugPrint('WebSocket connection failed: $e');
      _wsConnected = false;
      onWsStateChanged?.call();
      rethrow;
    }
  }

  Future<void> disconnect() async {
    _wsRoom = null;
    _hbTimer?.cancel();
    _statsTimer?.cancel();
    _wsSub?.cancel();
    await _ws?.sink.close(ws_status.normalClosure);
    _ws = null;
    _wsSub = null;
    _wsConnected = false;
    onWsStateChanged?.call();
  }

  void _startHeartbeat() {
    _hbTimer?.cancel();
    _hbTimer = Timer.periodic(Duration(seconds: 10), (timer) {
      _send({'type': 'ping'});
    });
  }

  void _handleMessage(dynamic message) {
    try {
      final data = jsonDecode(message);
      final type = data['type'];

      switch (type) {
        case 'pong':
          _missedPongs = 0;
          break;

        case 'offer':
          _handleIncomingOffer(data);
          break;

        case 'answer':
          _handleAnswer(data);
          break;

        case 'candidate':
          _handleIceCandidate(data);
          break;

        case 'hangup':
        case 'bye':
          _debugPrint('Received hangup from peer');
          _handleHangup(); // Выносим в отдельный метод
          break;

        case 'reject':
          // При получении reject от другой стороны
          _debugPrint('Call was rejected by peer');
          _cleanupCall();
          break;

        default:
          _debugPrint('Unhandled message type: $type');
      }
    } catch (e) {
      _debugPrint('Error handling message: $e');
    }
  }

  // Выносим обработку hangup в отдельный метод
  Future<void> _handleHangup() async {
    _debugPrint('Received hangup from peer');
    await _cleanupCall(); // Без уведомления обратно
  }

  void _handleIncomingOffer(Map<String, dynamic> data) {
    _pendingOffer = RTCSessionDescription(data['sdp'], 'offer');
    callState = CallState.ringing;
    onCallStateChanged?.call();
  }

  void _handleAnswer(Map<String, dynamic> data) async {
    try {
      final answer = RTCSessionDescription(data['sdp'], 'answer');
      await _pc!.setRemoteDescription(answer);
      callState = CallState.inCall;
      onCallStateChanged?.call();
    } catch (e) {
      _debugPrint('Error setting remote answer: $e');
    }
  }

  void _handleIceCandidate(Map<String, dynamic> data) async {
    try {
      final candidate = RTCIceCandidate(
        data['candidate'],
        data['sdpMid'],
        data['sdpMLineIndex'],
      );
      await _pc!.addCandidate(candidate);
    } catch (e) {
      _debugPrint('Error adding ICE candidate: $e');
    }
  }

  Future<void> makeCall() async {
    try {
      // Если _pc был закрыт ранее — повторно инициализируем
      await _ensurePcInitialized();

      callState = CallState.connecting;
      onCallStateChanged?.call();

      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      _send({'type': 'offer', 'sdp': offer.sdp});

      callState = CallState.inCall;
      onCallStateChanged?.call();
      _startStatsDump();

    } catch (e) {
      _debugPrint('Error making call: $e');
      _cleanupCall();
    }
  }

  Future<void> acceptCall() async {
    if (_pendingOffer == null) return;

    try {
      await _ensurePcInitialized();

      callState = CallState.connecting;
      onCallStateChanged?.call();

      await _pc!.setRemoteDescription(_pendingOffer!);
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);

      _send({'type': 'answer', 'sdp': answer.sdp});

      callState = CallState.inCall;
      onCallStateChanged?.call();

      _startStatsDump();

    } catch (e) {
      _debugPrint('Error accepting call: $e');
      _cleanupCall();
    }
  }

  void rejectCall() {
    _send({'type': 'reject'});
    _cleanupCall();
  }

  Future<void> hangup({bool notifyPeer = true}) async {
    _debugPrint('Hangup called, notifyPeer: $notifyPeer');

    try {
      if (notifyPeer) {
        _send({'type': 'hangup'});
      }
    } catch (e) {
      _debugPrint('Error sending hangup: $e');
    }

    await _cleanupCall();
  }

  Future<void> setSpeakerphoneOn(bool on) async {
    try {
      // Только для Android и iOS
      if (Platform.isAndroid || Platform.isIOS) {
        await Helper.setSpeakerphoneOn(on);
        speakerOn = on;
      }
    } catch (e) {
      _debugPrint('Error setting speakerphone: $e');
    }
  }

  void toggleSpeaker() {
    setSpeakerphoneOn(!speakerOn);
  }

  Future<void> _cleanupCall() async {
    if (_isCleaningUp) {
      _debugPrint('[CLEANUP] skip: already running');
      return;
    }
    _isCleaningUp = true;

    _debugPrint('[CLEANUP] begin');

    try {
      _inCallActive = false;

      // 0) Немедленно заглушаем микрофон
      try {
        for (final track in (_localStream?.getAudioTracks() ?? [])) {
          track.enabled = false;
        }
      } catch (e) {
        _debugPrint('Mute error: $e');
      }

      // 1) Отписываем senders от треков
      try {
        final senders = await _pc?.getSenders() ?? [];
        for (final sender in senders) {
          try {
            await sender.replaceTrack(null);
          } catch (e) {
            _debugPrint('replaceTrack error: $e');
          }
        }
      } catch (e) {
        _debugPrint('Senders error: $e');
      }

      // 2) Останавливаем все transceivers
      try {
        if (_pc != null) {
          final transceivers = await _pc!.getTransceivers();
          for (final transceiver in transceivers) {
            try {
              // Безопасный вызов stop
              transceiver.stop();
            } catch (e) {
              _debugPrint('Transceiver stop error: $e');
            }
          }
        }
      } catch (e) {
        _debugPrint('Transceivers error: $e');
      }

      // 3) Останавливаем и освобождаем локальные треки
      try {
        for (final track in (_localStream?.getTracks() ?? [])) {
          await track.stop();
        }
        await _localStream?.dispose();
      } catch (e) {
        _debugPrint('localStream dispose error: $e');
      } finally {
        _localStream = null;
      }

      // 4) Останавливаем удаленный аудиотрек
      try {
        await _remoteAudioTrack?.stop();
      } catch (e) {
        _debugPrint('remoteAudioTrack stop error: $e');
      } finally {
        _remoteAudioTrack = null;
      }

      // 5) Останавливаем и освобождаем удаленный поток
      try {
        for (final track in (_remoteStream?.getTracks() ?? [])) {
          await track.stop();
        }
        await _remoteStream?.dispose();
      } catch (e) {
        _debugPrint('remoteStream dispose error: $e');
      } finally {
        _remoteStream = null;
      }

      // 6) Закрываем соединение
      try {
        if (_pc != null) {
          await _pc!.close();
          _pc = null;
        }
      } catch (e) {
        _debugPrint('PC close error: $e');
      }

      // 7) Останавливаем таймеры
      _hbTimer?.cancel();
      _statsTimer?.cancel();
      _statsTimer = null;

      // 8) Обновляем состояние
      callState = CallState.idle;
      onCallStateChanged?.call();

    } finally {
      _isCleaningUp = false;
      _debugPrint('[CLEANUP] end');
    }
  }

  void _send(Map<String, dynamic> message) {
    if (_ws == null) return;

    try {
      final jsonMessage = jsonEncode(message);
      _ws!.sink.add(jsonMessage);
    } catch (e) {
      _debugPrint('Error sending message: $e');
    }
  }

  void _handleError(Object error) {
    _debugPrint('WebSocket error: $error');
    _wsConnected = false;

    // Очистим объект сокета и подписку, чтобы connect() мог повторно создать соединение
    try { _wsSub?.cancel(); } catch (_) {}
    _wsSub = null;
    try { _ws?.sink.close(); } catch (_) {}
    _ws = null;

    onWsStateChanged?.call();
  }

  void _handleDone() {
    _debugPrint('WebSocket done');
    _wsConnected = false;

    try { _wsSub?.cancel(); } catch (_) {}
    _wsSub = null;
    _ws = null;

    onWsStateChanged?.call();
  }

  Future<void> close() async {
    _hbTimer?.cancel();
    _statsTimer?.cancel();
    _wsSub?.cancel();
    await _ws?.sink.close();
    _ws = null;
    _wsSub = null;
    _wsConnected = false;
    onWsStateChanged?.call();
  }

  Future<void> dispose() async {
    await close();
    await _localStream?.dispose();
    await _remoteStream?.dispose();
    await _pc?.close();
    _pc = null;
    _localStream = null;
    _remoteStream = null;
  }

  Future<void> setRemoteAnswer(String sdp) async {
    try {
      await _ensurePcInitialized();
      final answer = RTCSessionDescription(sdp, 'answer');
      await _pc!.setRemoteDescription(answer);
      callState = CallState.inCall;
      onCallStateChanged?.call();
    } catch (e) {
      _debugPrint('Error setting remote answer: $e');
      rethrow;
    }
  }

  Future<void> acceptOfferSdpAndAnswer(String remoteOfferSdp) async {
    try {
      _debugPrint('Accepting offer and creating answer...');

      await _ensurePcInitialized();

      // Устанавливаем удаленное описание (offer)
      final offer = RTCSessionDescription(remoteOfferSdp, 'offer');
      await _pc!.setRemoteDescription(offer);

      // Создаем answer
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);

      // Отправляем answer через WebSocket
      _send({'type': 'answer', 'sdp': answer.sdp});

      callState = CallState.inCall;
      onCallStateChanged?.call();
      _startStatsDump();

      _debugPrint('Answer created and sent successfully');
    } catch (e) {
      _debugPrint('Error accepting offer: $e');
      _cleanupCall();
      rethrow;
    }
  }
}
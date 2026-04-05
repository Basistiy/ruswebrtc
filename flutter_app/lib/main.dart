import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/io.dart';

void main() {
  runApp(const RUSWebRtcApp());
}

class RUSWebRtcApp extends StatelessWidget {
  const RUSWebRtcApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RUS WebRTC',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const CallPage(),
    );
  }
}

class CallPage extends StatefulWidget {
  const CallPage({super.key});

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  late final TextEditingController _serverController;
  final TextEditingController _roomController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();
  final List<String> _logs = <String>[];

  IOWebSocketChannel? _ws;
  StreamSubscription<dynamic>? _wsSubscription;
  bool _wsReady = false;

  RTCPeerConnection? _pc;
  RTCRtpSender? _audioSender;
  Timer? _statsTimer;
  MediaStream? _localAudioStream;
  MediaStreamTrack? _localAudioTrack;
  RTCDataChannel? _dataChannel;
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  bool _callInitialized = false;
  bool _createdRoom = false;
  bool _startedAsCaller = false;
  bool _useTurn = true;
  bool _hasActiveMediaPath = false;
  String _peerId = '';
  int _peerCount = 0;
  bool _busy = false;
  String _currentRoom = '';
  String _rtcConfigForServer = '';
  Map<String, dynamic>? _rtcConfig;

  final List<Map<String, dynamic>> _pendingCandidates = <Map<String, dynamic>>[];
  Future<void> _signalChain = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _serverController = TextEditingController(text: _defaultServerBase());
    unawaited(_remoteRenderer.initialize());
  }

  @override
  void dispose() {
    _roomController.dispose();
    _messageController.dispose();
    _serverController.dispose();
    unawaited(_closeWebSocket());
    unawaited(_disposePeerResources(stopLocalAudio: true));
    _remoteRenderer.dispose();
    super.dispose();
  }

  String _defaultServerBase() {
    return 'https://basisty.duckdns.org';
  }

  void _log(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    setState(() {
      _logs.add('[$timestamp] $message');
      if (_logs.length > 200) {
        _logs.removeRange(0, _logs.length - 200);
      }
    });
  }

  String _sanitizeRoom(String rawRoom) {
    final cleaned = rawRoom.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '');
    if (cleaned.isEmpty) {
      return 'default';
    }
    return cleaned.substring(0, min(cleaned.length, 64));
  }

  String _generateRoomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    final code = List<String>.generate(6, (_) => chars[random.nextInt(chars.length)]).join();
    return 'room-$code';
  }

  Uri _serverUriForPath(String path) {
    var base = Uri.parse(_serverController.text.trim());
    if (base.scheme == 'ws') {
      base = base.replace(scheme: 'http');
    } else if (base.scheme == 'wss') {
      base = base.replace(scheme: 'https');
    }
    return base.replace(path: path, queryParameters: null);
  }

  Uri _wsUriForRoom(String room) {
    var base = Uri.parse(_serverController.text.trim());
    if (base.scheme == 'http') {
      base = base.replace(scheme: 'ws');
    } else if (base.scheme == 'https') {
      base = base.replace(scheme: 'wss');
    }
    return base.replace(path: '/ws', queryParameters: <String, String>{'room': room});
  }

  Future<void> _loadRtcConfig() async {
    final normalizedServer = _serverController.text.trim();
    if (_rtcConfig != null && _rtcConfigForServer == normalizedServer) {
      return;
    }

    final uri = _serverUriForPath('/rtc-config');
    final client = HttpClient()
      ..badCertificateCallback = (
        X509Certificate cert,
        String host,
        int port,
      ) => true;
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw StateError('RTC config request failed: ${response.statusCode}');
      }
      final body = await utf8.decoder.bind(response).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('RTC config must be a JSON object');
      }
      _rtcConfig = decoded;
      _rtcConfigForServer = normalizedServer;
      final iceServers = decoded['iceServers'];
      _log('[webrtc] TURN config loaded: $iceServers (enabled=$_useTurn)');
    } finally {
      client.close();
    }
  }

  Future<RTCPeerConnection> _ensurePeerConnection() async {
    if (_pc != null) {
      return _pc!;
    }

    final pc = await createPeerConnection(_effectiveRtcConfig(), <String, dynamic>{});
    await _ensureLocalAudioSender(pc);

    pc.onIceCandidate = (RTCIceCandidate candidate) {
      final payload = <String, dynamic>{
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      };
      _sendSignal('candidate', payload);
    };

    pc.onConnectionState = (RTCPeerConnectionState state) {
      _log('[webrtc] connection state: $state');
      final stateText = state.toString().toLowerCase();
      if (stateText.contains('connected')) {
        _hasActiveMediaPath = true;
        _startStatsPolling();
      } else if (stateText.contains('failed') ||
          stateText.contains('closed') ||
          stateText.contains('disconnected')) {
        _hasActiveMediaPath = false;
        _stopStatsPolling();
      }
    };

    pc.onIceConnectionState = (RTCIceConnectionState state) {
      _log('[webrtc] ice state: $state');
    };

    pc.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        _remoteRenderer.srcObject = event.streams.first;
      }
      _log('[voice] remote ${event.track.kind} track received');
    };

    pc.onDataChannel = (RTCDataChannel channel) {
      _dataChannel = channel;
      _attachDataChannelHandlers(channel);
      if (mounted) {
        setState(() {});
      }
    };

    _pc = pc;
    return pc;
  }

  Map<String, dynamic> _effectiveRtcConfig() {
    if (!_useTurn) {
      return <String, dynamic>{'iceServers': <dynamic>[]};
    }
    return _rtcConfig ?? <String, dynamic>{'iceServers': <dynamic>[]};
  }

  Future<void> _ensureLocalAudioSender(RTCPeerConnection pc) async {
    final localTrack = _localAudioTrack;
    final localStream = _localAudioStream;
    if (localTrack == null || localStream == null) {
      return;
    }

    if (_audioSender == null) {
      _audioSender = await pc.addTrack(localTrack, localStream);
      _log('[voice] local audio sender added');
      return;
    }

    final senderTrack = _audioSender!.track;
    if (senderTrack?.id != localTrack.id) {
      await _audioSender!.replaceTrack(localTrack);
      _log('[voice] local audio sender track replaced');
    }
  }

  void _startStatsPolling() {
    if (_statsTimer != null) {
      return;
    }
    _log('[stats] polling started');
    _statsTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      unawaited(_logPeerStats());
    });
  }

  void _stopStatsPolling() {
    if (_statsTimer == null) {
      return;
    }
    _statsTimer?.cancel();
    _statsTimer = null;
    _log('[stats] polling stopped');
  }

  String _reportType(dynamic report) => (report as dynamic).type?.toString() ?? '';
  String _reportId(dynamic report) => (report as dynamic).id?.toString() ?? '';

  Map<String, dynamic> _reportValues(dynamic report) {
    final raw = (report as dynamic).values;
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return <String, dynamic>{};
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  String _asString(dynamic value) => value?.toString() ?? '';

  bool _isTruthy(dynamic value) {
    if (value is bool) return value;
    if (value is String) return value.toLowerCase() == 'true';
    return false;
  }

  Future<void> _logPeerStats() async {
    final pc = _pc;
    if (pc == null) {
      return;
    }

    try {
      final reports = await pc.getStats();
      final candidatePairs = <String, Map<String, dynamic>>{};
      final localCandidates = <String, Map<String, dynamic>>{};
      final remoteCandidates = <String, Map<String, dynamic>>{};
      String selectedPairId = '';
      int audioOutBytes = 0;
      int audioInBytes = 0;

      for (final report in reports) {
        final type = _reportType(report);
        final id = _reportId(report);
        final values = _reportValues(report);

        if (type == 'transport') {
          if (selectedPairId.isEmpty) {
            selectedPairId = _asString(values['selectedCandidatePairId']);
          }
          continue;
        }

        if (type == 'candidate-pair') {
          candidatePairs[id] = values;
          if (selectedPairId.isEmpty && _isTruthy(values['selected'])) {
            selectedPairId = id;
          }
          continue;
        }

        if (type == 'local-candidate') {
          localCandidates[id] = values;
          continue;
        }

        if (type == 'remote-candidate') {
          remoteCandidates[id] = values;
          continue;
        }

        if (type == 'outbound-rtp' && _asString(values['kind']) == 'audio') {
          audioOutBytes += _asInt(values['bytesSent']);
          continue;
        }

        if (type == 'inbound-rtp' && _asString(values['kind']) == 'audio') {
          audioInBytes += _asInt(values['bytesReceived']);
        }
      }

      final selectedPair = candidatePairs[selectedPairId] ?? <String, dynamic>{};
      final localCandidateId = _asString(selectedPair['localCandidateId']);
      final remoteCandidateId = _asString(selectedPair['remoteCandidateId']);
      final localCandidate = localCandidates[localCandidateId] ?? <String, dynamic>{};
      final remoteCandidate = remoteCandidates[remoteCandidateId] ?? <String, dynamic>{};

      final pairState = _asString(selectedPair['state']);
      final localType = _asString(localCandidate['candidateType']);
      final localProtocol = _asString(localCandidate['protocol']);
      final remoteType = _asString(remoteCandidate['candidateType']);
      final remoteProtocol = _asString(remoteCandidate['protocol']);

      _log(
        '[stats] pair=${selectedPairId.isEmpty ? 'none' : selectedPairId}'
        ' state=${pairState.isEmpty ? 'unknown' : pairState}'
        ' local=${localType.isEmpty ? '-' : localType}/${localProtocol.isEmpty ? '-' : localProtocol}'
        ' remote=${remoteType.isEmpty ? '-' : remoteType}/${remoteProtocol.isEmpty ? '-' : remoteProtocol}'
        ' audioOutBytes=$audioOutBytes audioInBytes=$audioInBytes',
      );
    } catch (error) {
      _log('[stats][error] $error');
    }
  }

  void _attachDataChannelHandlers(RTCDataChannel channel) {
    channel.onDataChannelState = (RTCDataChannelState state) {
      _log('[data] channel state: $state');
      if (mounted) {
        setState(() {});
      }
    };
    channel.onMessage = (RTCDataChannelMessage message) {
      if (!message.isBinary) {
        _log('[peer] ${message.text}');
      }
    };
  }

  void _sendSignal(String type, Map<String, dynamic> payload) {
    if (_ws == null || !_wsReady) {
      _log('[signal] websocket not connected');
      return;
    }
    final message = jsonEncode(<String, dynamic>{'type': type, 'payload': payload});
    _ws!.sink.add(message);
  }

  Future<void> _enableMicrophone() async {
    if (_localAudioTrack == null) {
      final stream = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': <String, dynamic>{
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });
      _localAudioStream = stream;
      final tracks = stream.getAudioTracks();
      if (tracks.isEmpty) {
        throw StateError('No audio track available from microphone');
      }
      _localAudioTrack = tracks.first;
      _log('[voice] microphone enabled');
    } else {
      _localAudioTrack!.enabled = true;
      _log('[voice] microphone unmuted');
    }

    final pc = _pc;
    if (pc != null && _localAudioTrack != null) {
      await _ensureLocalAudioSender(pc);
      await _renegotiateIfNeeded();
    }
  }

  Future<void> _flushPendingCandidates(RTCPeerConnection pc) async {
    if (await pc.getRemoteDescription() == null) {
      return;
    }

    while (_pendingCandidates.isNotEmpty) {
      final raw = _pendingCandidates.removeAt(0);
      final candidate = RTCIceCandidate(
        raw['candidate'] as String?,
        raw['sdpMid'] as String?,
        (raw['sdpMLineIndex'] as num?)?.toInt(),
      );
      try {
        await pc.addCandidate(candidate);
      } catch (error) {
        _log('[signal][error] queued candidate failed: $error');
      }
    }
  }

  Future<void> _renegotiateIfNeeded() async {
    final pc = _pc;
    if (pc == null || !_wsReady) {
      return;
    }
    final remoteDescription = await pc.getRemoteDescription();
    if (remoteDescription == null) {
      return;
    }
    if (pc.signalingState != RTCSignalingState.RTCSignalingStateStable) {
      return;
    }

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _sendSignal('offer', <String, dynamic>{'type': offer.type, 'sdp': offer.sdp});
    _log('[signal] renegotiation offer sent');
  }

  Future<void> _startAsCaller() async {
    if (_startedAsCaller) {
      _log('[webrtc] caller already started');
      return;
    }
    if (_peerCount < 2) {
      _log('[webrtc] waiting for second peer');
      return;
    }

    _startedAsCaller = true;
    final pc = await _ensurePeerConnection();
    await _ensureLocalAudioSender(pc);

    final dataChannelInit = RTCDataChannelInit();
    final channel = await pc.createDataChannel('chat', dataChannelInit);
    _dataChannel = channel;
    _attachDataChannelHandlers(channel);
    if (mounted) {
      setState(() {});
    }

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _sendSignal('offer', <String, dynamic>{'type': offer.type, 'sdp': offer.sdp});
    _log('[signal] offer sent');
  }

  Future<void> _handleSignalMessage(dynamic data) async {
    final text = switch (data) {
      String value => value,
      List<int> bytes => utf8.decode(bytes),
      _ => data.toString(),
    };

    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      _log('[signal][error] malformed message');
      return;
    }

    final type = decoded['type']?.toString() ?? '';
    final payload = decoded['payload'];

    if (type == 'welcome') {
      _peerId = decoded['peerId']?.toString() ?? '';
      _log('[signal] connected as peer ${decoded['peerId']} in room ${decoded['roomId']}');
      return;
    }

    if (type == 'peers') {
      _peerCount = (decoded['count'] as num?)?.toInt() ?? 0;
      _log('[signal] peers in room: $_peerCount');
      if (_peerCount == 2 && !_startedAsCaller) {
        final localPeerNum = int.tryParse(_peerId);
        final shouldStartAsCaller = _createdRoom || (localPeerNum != null && localPeerNum.isOdd);
        if (shouldStartAsCaller) {
          await _startAsCaller();
        } else {
          _log('[webrtc] waiting for caller offer');
        }
      }
      return;
    }

    if (type == 'peer-left') {
      _log('[signal] peer disconnected');
      _startedAsCaller = false;
      await _disposePeerResources(stopLocalAudio: false);
      return;
    }

    if (type == 'error') {
      _log('[signal][error] ${decoded['message']}');
      return;
    }

    await _loadRtcConfig();
    final pc = await _ensurePeerConnection();

    if (type == 'offer') {
      if (payload is! Map<String, dynamic>) {
        _log('[signal][error] invalid offer payload');
        return;
      }

      if (pc.signalingState != RTCSignalingState.RTCSignalingStateStable) {
        try {
          await pc.setLocalDescription(RTCSessionDescription('', 'rollback'));
        } catch (error) {
          _log('[signal] rollback skipped: $error');
        }
      }

      final remoteOffer = RTCSessionDescription(payload['sdp'] as String?, payload['type'] as String?);
      await pc.setRemoteDescription(remoteOffer);
      await _flushPendingCandidates(pc);

      await _ensureLocalAudioSender(pc);

      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      _sendSignal('answer', <String, dynamic>{'type': answer.type, 'sdp': answer.sdp});
      _log('[signal] answer sent');
      return;
    }

    if (type == 'answer') {
      if (payload is! Map<String, dynamic>) {
        _log('[signal][error] invalid answer payload');
        return;
      }
      final remoteAnswer = RTCSessionDescription(payload['sdp'] as String?, payload['type'] as String?);
      await pc.setRemoteDescription(remoteAnswer);
      await _flushPendingCandidates(pc);
      _log('[signal] answer received');
      return;
    }

    if (type == 'candidate') {
      if (payload is! Map<String, dynamic>) {
        _log('[signal][error] invalid candidate payload');
        return;
      }
      final hasRemote = await pc.getRemoteDescription() != null;
      if (!hasRemote) {
        _pendingCandidates.add(payload);
        _log('[signal] candidate queued');
        return;
      }
      final candidate = RTCIceCandidate(
        payload['candidate'] as String?,
        payload['sdpMid'] as String?,
        (payload['sdpMLineIndex'] as num?)?.toInt(),
      );
      try {
        await pc.addCandidate(candidate);
        _log('[signal] candidate applied');
      } catch (error) {
        _log('[signal][error] addCandidate failed: $error');
      }
    }
  }

  Future<void> _connectSignaling() async {
    if (_ws != null) {
      _log('[signal] already connected');
      return;
    }

    final wsUri = _wsUriForRoom(_currentRoom);
    _ws = IOWebSocketChannel.connect(wsUri.toString());

    _ws!.ready.then((_) {
      _wsReady = true;
      _log('[signal] websocket open ($wsUri)');
    }).catchError((Object error) {
      _log('[signal][error] websocket failed to open: $error');
      _wsReady = false;
    });

    _wsSubscription = _ws!.stream.listen(
      (dynamic event) {
        _signalChain = _signalChain.then((_) => _handleSignalMessage(event)).catchError((Object error) {
          _log('[signal][error] $error');
        });
      },
      onError: (Object error) {
        _log('[signal][error] websocket error: $error');
      },
      onDone: () async {
        _log('[signal] websocket closed');
        _wsReady = false;
        _peerCount = 0;
        await _wsSubscription?.cancel();
        _wsSubscription = null;
        _ws = null;

        if (_hasActiveMediaPath) {
          _log('[signal] signaling dropped; keeping active media session');
        } else {
          _startedAsCaller = false;
          _peerId = '';
          _callInitialized = false;
          await _disposePeerResources(stopLocalAudio: true);
          _pendingCandidates.clear();
        }

        if (mounted) {
          setState(() {});
        }
      },
      cancelOnError: false,
    );
  }

  Future<void> _closeWebSocket() async {
    final ws = _ws;
    if (ws == null) {
      return;
    }
    await _wsSubscription?.cancel();
    _wsSubscription = null;
    await ws.sink.close();
    _ws = null;
    _wsReady = false;
  }

  Future<void> _disposePeerResources({required bool stopLocalAudio}) async {
    _stopStatsPolling();
    _hasActiveMediaPath = false;

    final dataChannel = _dataChannel;
    _dataChannel = null;
    await dataChannel?.close();

    final pc = _pc;
    _pc = null;
    _audioSender = null;
    await pc?.close();

    _remoteRenderer.srcObject = null;

    if (stopLocalAudio) {
      final stream = _localAudioStream;
      _localAudioStream = null;
      _localAudioTrack = null;
      if (stream != null) {
        for (final track in stream.getTracks()) {
          await track.stop();
        }
        await stream.dispose();
      }
    }
  }

  Future<void> _startCall() async {
    if (_busy) {
      return;
    }
    if (_callInitialized) {
      _log('[call] already initialized');
      return;
    }

    setState(() {
      _busy = true;
    });

    try {
      final roomInput = _roomController.text.trim();
      if (roomInput.isEmpty) {
        _currentRoom = _generateRoomId();
        _createdRoom = true;
        _roomController.text = _currentRoom;
        _log('[call] room created: $_currentRoom');
      } else {
        _currentRoom = _sanitizeRoom(roomInput);
        _createdRoom = false;
        _roomController.text = _currentRoom;
        _log('[call] joining room: $_currentRoom');
      }

      if (_useTurn) {
        await _loadRtcConfig();
      } else {
        _rtcConfig = <String, dynamic>{'iceServers': <dynamic>[]};
        _rtcConfigForServer = _serverController.text.trim();
        _log('[webrtc] TURN disabled; using direct ICE only');
      }
      await Helper.setSpeakerphoneOn(true);
      await _enableMicrophone();
      await _connectSignaling();

      _callInitialized = true;
    } catch (error) {
      _log('[call][error] $error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _endCall() async {
    if (_busy) {
      return;
    }

    setState(() {
      _busy = true;
    });

    try {
      await _closeWebSocket();
      await _disposePeerResources(stopLocalAudio: true);
      _wsReady = false;
      _peerCount = 0;
      _startedAsCaller = false;
      _peerId = '';
      _callInitialized = false;
      _pendingCandidates.clear();
      _signalChain = Future<void>.value();
      _log('[call] ended');
    } catch (error) {
      _log('[call][error] failed to end call: $error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _copyRoomId() async {
    final room = _roomController.text.trim();
    if (room.isEmpty) {
      _log('[signal] room is empty');
      return;
    }
    await Clipboard.setData(ClipboardData(text: room));
    _log('[signal] room id copied: $room');
  }

  void _sendChatMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) {
      return;
    }
    final channel = _dataChannel;
    if (channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      _log('[data] channel not open');
      return;
    }
    channel.send(RTCDataChannelMessage(text));
    _log('[you] $text');
    _messageController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final canSend = _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen;
    final buttonLabel = _busy
        ? 'Starting...'
        : _callInitialized
            ? (_createdRoom ? 'Waiting For Peer...' : 'Connected')
            : 'Start Call';

    return Scaffold(
      appBar: AppBar(title: const Text('RUS WebRTC (Flutter)')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                controller: _serverController,
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'http://localhost:8080',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Use TURN relay'),
                subtitle: const Text('Disable to test direct peer-to-peer ICE'),
                value: _useTurn,
                onChanged: (_busy || _callInitialized)
                    ? null
                    : (bool value) {
                        setState(() {
                          _useTurn = value;
                          _rtcConfigForServer = '';
                          _rtcConfig = value ? null : <String, dynamic>{'iceServers': <dynamic>[]};
                        });
                        _log(value
                            ? '[webrtc] TURN relay enabled (applies to next call)'
                            : '[webrtc] TURN relay disabled (applies to next call)');
                      },
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _roomController,
                      decoration: const InputDecoration(
                        labelText: 'Room ID',
                        hintText: 'Leave empty to create one',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _copyRoomId,
                    icon: const Icon(Icons.copy),
                    tooltip: 'Copy Room ID',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _busy ? null : _startCall,
                child: Text(buttonLabel),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: (_busy || !_callInitialized) ? null : _endCall,
                child: const Text('End Call'),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: const InputDecoration(
                        labelText: 'Message',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _sendChatMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: canSend ? _sendChatMessage : null,
                    child: const Text('Send'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView.builder(
                    itemCount: _logs.length,
                    itemBuilder: (BuildContext context, int index) {
                      return Text(_logs[index], style: const TextStyle(fontSize: 13));
                    },
                  ),
                ),
              ),
              SizedBox(
                width: 1,
                height: 1,
                child: RTCVideoView(_remoteRenderer),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

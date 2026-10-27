// LanBridge Android 端主程序 (Flutter: lib/main.dart)
// 支持：安卓 <-> Windows 互通 & 双安卓 (Android <-> Android) 互联互通
// 功能：
// 1. 局域网 UDP 自动发现电脑端与其他安卓手机（自动过滤本机，支持多设备列表点击切换）
// 2. 双向文件秒传（电脑 <-> 手机、手机 A <-> 手机 B，接收文件存入 Download 目录）
// 3. 双向实时投屏（自适应手机竖屏 9:16 与电脑横屏 16:9 画面，零黑边坐标偏移）
// 4. 双向远程操控（统一 TAP / DOUBLE_TAP / SWIPE / KEY 协议，支持手机控手机、手机控电脑、电脑控手机）

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

const int udpDiscoveryPort = 50001;
const int fileTransferPort = 50002;
const int screenStreamPort = 50003;
const int controlEventPort = 50004;

void main() {
  runApp(const LanBridgeAndroidApp());
}

class LanBridgeAndroidApp extends StatelessWidget {
  const LanBridgeAndroidApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LanBridge 跨端互传与双向投屏',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class DiscoveredPeer {
  final String id;
  final String name;
  final String ip;
  final String type; // 'WINDOWS_PC' or 'ANDROID_PHONE'

  DiscoveredPeer({
    required this.id,
    required this.name,
    required this.ip,
    required this.type,
  });
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const MethodChannel _nativeChannel =
      MethodChannel('com.lanbridge.app/native_bridge');

  final String _myDeviceId =
      'AND-${1000 + Random().nextInt(8999)}';
  String _myLocalIp = '';

  final TextEditingController _targetIpController = TextEditingController();
  final Map<String, DiscoveredPeer> _peers = {};

  String _status = '正在搜索局域网内的电脑或其他安卓设备...';
  double _progress = 0.0;
  bool _isCastingToPeer = false;

  Uint8List? _remoteScreenFrame;
  double _remoteAspectRatio = 9 / 16; // 默认竖屏比例，收到画面后自动根据图像宽高动态调整
  Offset? _panStartNorm;
  Socket? _controlSocket;

  @override
  void initState() {
    super.initState();
    _initLocalIpAndDiscovery();
    _startFileReceiveServer();
    _startRemoteScreenReceiver();
    _startRemoteControlReceiver();
  }

  Future<String> _resolveLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback &&
              (addr.address.startsWith('192.168.') ||
                  addr.address.startsWith('10.') ||
                  addr.address.startsWith('172.'))) {
            return addr.address;
          }
        }
      }
      if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
        return interfaces.first.addresses.first.address;
      }
    } catch (_) {}
    return '';
  }

  // ===================== 1. 局域网 UDP 自动发现（支持 Windows 与双安卓互通） =====================
  Future<void> _initLocalIpAndDiscovery() async {
    _myLocalIp = await _resolveLocalIp();
    setState(() {
      _status = _myLocalIp.isEmpty
          ? '本机标识: $_myDeviceId | 正在搜索局域网设备...'
          : '本机 IP: $_myLocalIp ($_myDeviceId) | 正在搜索设备...';
    });

    final RawDatagramSocket udp = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      udpDiscoveryPort,
      reuseAddress: true,
    );
    udp.broadcastEnabled = true;

    // 监听局域网内 Windows 电脑或其他 Android 手机的广播
    udp.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        final Datagram? dg = udp.receive();
        if (dg == null) return;
        try {
          final Map<String, dynamic> msg =
              jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
          final String peerType = (msg['type'] as String?) ?? '';
          final String peerId = (msg['id'] as String?) ?? '';
          final String peerIp = (msg['ip'] as String?) ?? dg.address.address;
          final String peerName = (msg['name'] as String?) ?? peerIp;

          // 过滤本机自身的广播
          if (peerId == _myDeviceId ||
              (peerIp == _myLocalIp && _myLocalIp.isNotEmpty)) {
            return;
          }

          if (peerType == 'WINDOWS_PC' || peerType == 'ANDROID_PHONE') {
            final bool isNew = !_peers.containsKey(peerIp);
            _peers[peerIp] = DiscoveredPeer(
              id: peerId.isEmpty ? peerIp : peerId,
              name: peerName,
              ip: peerIp,
              type: peerType,
            );
            if (_targetIpController.text.isEmpty) {
              _targetIpController.text = peerIp;
              _connectControlSocket(peerIp);
            }
            if (isNew && mounted) {
              setState(() {
                final tag = peerType == 'WINDOWS_PC' ? '电脑' : '安卓';
                _status = '已发现$tag设备: $peerName ($peerIp)';
              });
            }
          }
        } catch (_) {}
      }
    });

    // 定时广播本机在线状态（携带本机唯一 ID 与 IP，方便其他安卓或电脑发现）
    Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_myLocalIp.isEmpty) {
        _myLocalIp = await _resolveLocalIp();
      }
      final List<int> payload = utf8.encode(jsonEncode({
        'type': 'ANDROID_PHONE',
        'id': _myDeviceId,
        'name': 'Android_${_myDeviceId.split("-").last}',
        'ip': _myLocalIp,
      }));
      try {
        udp.send(
            payload, InternetAddress('255.255.255.255'), udpDiscoveryPort);
      } catch (_) {}
    });
  }

  void _selectPeer(DiscoveredPeer peer) {
    setState(() {
      _targetIpController.text = peer.ip;
      final tag = peer.type == 'WINDOWS_PC' ? '电脑' : '安卓手机';
      _status = '已切换目标$tag: ${peer.name} (${peer.ip})';
    });
    _connectControlSocket(peer.ip);
  }

  // ===================== 2. 双端文件互传（支持安卓<->电脑、安卓<->安卓） =====================
  Future<void> _pickAndSendFile() async {
    final String targetIp = _targetIpController.text.trim();
    if (targetIp.isEmpty) {
      _showSnack('请先选择或输入对方设备（手机或电脑）的局域网 IP');
      return;
    }
    final FilePickerResult? result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.single.path == null) return;

    final File file = File(result.files.single.path!);
    final String filename = result.files.single.name;
    final int filesize = await file.length();

    try {
      setState(() => _status = '正在发送: $filename -> $targetIp');
      final Socket sock = await Socket.connect(targetIp, fileTransferPort,
          timeout: const Duration(seconds: 5));
      final List<int> headerBytes =
          utf8.encode(jsonEncode({'filename': filename, 'size': filesize}));
      final ByteData lenBuf = ByteData(4)..setUint32(0, headerBytes.length);
      sock.add(lenBuf.buffer.asUint8List());
      sock.add(headerBytes);

      int sent = 0;
      await for (final List<int> chunk in file.openRead()) {
        sock.add(chunk);
        sent += chunk.length;
        setState(() => _progress = sent / (filesize == 0 ? 1 : filesize));
      }
      await sock.flush();
      await sock.close();
      setState(() => _status = '发送成功: $filename');
    } catch (e) {
      setState(() => _status = '发送失败: $e');
    }
  }

  Future<void> _startFileReceiveServer() async {
    final ServerSocket server = await ServerSocket.bind(
        InternetAddress.anyIPv4, fileTransferPort,
        shared: true);
    await for (final Socket client in server) {
      _handleIncomingFile(client);
    }
  }

  Future<void> _handleIncomingFile(Socket client) async {
    try {
      final BytesBuilder buffer = BytesBuilder();
      int? headerLen;
      Map<String, dynamic>? header;
      IOSink? fileSink;
      String savedPath = '';
      int received = 0;
      int totalSize = 1;

      await for (final Uint8List chunk in client) {
        buffer.add(chunk);
        final Uint8List bytes = buffer.toBytes();

        if (headerLen == null && bytes.length >= 4) {
          headerLen = ByteData.sublistView(bytes, 0, 4).getUint32(0);
        }
        if (headerLen != null &&
            header == null &&
            bytes.length >= 4 + headerLen) {
          header = jsonDecode(utf8.decode(bytes.sublist(4, 4 + headerLen)))
              as Map<String, dynamic>;
          final String rawName = (header['filename'] as String?) ?? 'file.bin';
          final String safeName = rawName.split(RegExp(r'[/\\]')).last;
          totalSize = (header['size'] as int?) ?? 1;

          final Directory dlDir = Directory('/storage/emulated/0/Download');
          if (!await dlDir.exists()) {
            await dlDir.create(recursive: true);
          }
          savedPath = '${dlDir.path}/$safeName';
          fileSink = File(savedPath).openWrite();

          final Uint8List remain = bytes.sublist(4 + headerLen);
          fileSink.add(remain);
          received += remain.length;
          buffer.clear();
          setState(() => _status = '正在接收文件: $safeName');
        } else if (header != null && fileSink != null) {
          fileSink.add(chunk);
          received += chunk.length;
          buffer.clear();
          setState(() => _progress = received / (totalSize == 0 ? 1 : totalSize));
        }
      }
      await fileSink?.flush();
      await fileSink?.close();
      setState(() => _status = '已收到文件并保存至: $savedPath');
      _showSnack('已接收文件: $savedPath');
    } catch (e) {
      setState(() => _status = '接收文件异常: $e');
    } finally {
      client.destroy();
    }
  }

  // ===================== 3. 双向实时投屏（自适应手机竖屏与电脑横屏） =====================
  Future<void> _startRemoteScreenReceiver() async {
    final ServerSocket server = await ServerSocket.bind(
        InternetAddress.anyIPv4, screenStreamPort,
        shared: true);
    await for (final Socket client in server) {
      if (_targetIpController.text.isEmpty) {
        _targetIpController.text = client.remoteAddress.address;
      }
      final BytesBuilder buf = BytesBuilder();
      int? frameLen;
      await for (final Uint8List chunk in client) {
        buf.add(chunk);
        while (true) {
          final Uint8List current = buf.toBytes();
          if (frameLen == null) {
            if (current.length < 4) break;
            frameLen = ByteData.sublistView(current, 0, 4).getUint32(0);
          }
          if (current.length < 4 + frameLen!) break;
          final Uint8List frameBytes = current.sublist(4, 4 + frameLen!);
          final Uint8List leftover = current.sublist(4 + frameLen!);
          buf.clear();
          buf.add(leftover);
          frameLen = null;
          _updateRemoteFrame(frameBytes);
        }
      }
    }
  }

  void _updateRemoteFrame(Uint8List frameBytes) {
    // 解析 JPEG 帧宽高以动态匹配横屏（电脑）或竖屏（另一台安卓手机），消除触控坐标偏移
    decodeImageFromList(frameBytes, (img) {
      if (!mounted) return;
      final double ratio =
          (img.width > 0 && img.height > 0) ? (img.width / img.height) : (9 / 16);
      setState(() {
        _remoteScreenFrame = frameBytes;
        _remoteAspectRatio = ratio;
      });
    });
  }

  Future<void> _toggleCastScreenToPeer() async {
    final String targetIp = _targetIpController.text.trim();
    if (targetIp.isEmpty) {
      _showSnack('请先选择或输入对方设备（电脑或另一台安卓）的 IP');
      return;
    }
    if (_isCastingToPeer) {
      await _nativeChannel.invokeMethod('stopScreenCapture');
      setState(() {
        _isCastingToPeer = false;
        _status = '已停止向 $targetIp 投屏';
      });
    } else {
      await _nativeChannel.invokeMethod('startScreenCapture', {
        'targetIp': targetIp,
        'port': screenStreamPort,
      });
      setState(() {
        _isCastingToPeer = true;
        _status = '正在向 $targetIp 实时投送本机屏幕...';
      });
    }
  }

  // ===================== 4. 双向远程操控（支持手机控手机 & 手机控电脑） =====================
  Future<void> _connectControlSocket(String targetIp) async {
    try {
      _controlSocket?.destroy();
      _controlSocket = await Socket.connect(targetIp, controlEventPort,
          timeout: const Duration(seconds: 3));
    } catch (_) {
      _controlSocket = null;
    }
  }

  Future<void> _sendRemoteControlCmd(Map<String, dynamic> cmd) async {
    final String targetIp = _targetIpController.text.trim();
    if (targetIp.isEmpty) return;
    if (_controlSocket == null) {
      await _connectControlSocket(targetIp);
    }
    try {
      _controlSocket?.write('${jsonEncode(cmd)}\n');
    } catch (_) {
      _controlSocket = null;
    }
  }

  Future<void> _startRemoteControlReceiver() async {
    final ServerSocket server = await ServerSocket.bind(
        InternetAddress.anyIPv4, controlEventPort,
        shared: true);
    await for (final Socket client in server) {
      utf8.decoder
          .bind(client)
          .transform(const LineSplitter())
          .listen((String line) async {
        if (line.trim().isEmpty) return;
        try {
          final Map<String, dynamic> msg =
              jsonDecode(line) as Map<String, dynamic>;
          // 转发给本机 Android AccessibilityService 执行真实点击/滑动/返回/桌面手势
          await _nativeChannel.invokeMethod('dispatchRemoteGesture', msg);
        } catch (_) {}
      });
    }
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ===================== 极简卡片式 UI =====================
  @override
  Widget build(BuildContext context) {
    final peerList = _peers.values.toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('LanBridge 跨端互传与双向投屏'),
        backgroundColor: const Color(0xFF1E293B),
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          // 卡片 1：局域网设备自动发现（同时支持电脑与安卓手机）
          Card(
            elevation: 0,
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _status,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 10),
                  if (peerList.isNotEmpty) ...[
                    const Text(
                      '点击下方已发现的设备一键切换连接（支持电脑与安卓）：',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: peerList.map((peer) {
                        final isSelected =
                            _targetIpController.text.trim() == peer.ip;
                        final icon = peer.type == 'WINDOWS_PC'
                            ? Icons.computer
                            : Icons.phone_android;
                        return ChoiceChip(
                          avatar: Icon(icon, size: 16),
                          label: Text('${peer.name} (${peer.ip})'),
                          selected: isSelected,
                          onSelected: (_) => _selectPeer(peer),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 10),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _targetIpController,
                          decoration: const InputDecoration(
                            labelText: '目标设备 IP（电脑或另一台安卓手机）',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonal(
                        onPressed: () {
                          final ip = _targetIpController.text.trim();
                          if (ip.isNotEmpty) {
                            _connectControlSocket(ip);
                            _showSnack('已连接目标设备: $ip');
                          }
                        },
                        child: const Text('连接'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),

          // 卡片 2：文件互传与投屏开关
          Card(
            elevation: 0,
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _pickAndSendFile,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('发送文件到对方设备（手机/电脑）'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: _progress),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: _toggleCastScreenToPeer,
                      icon: Icon(_isCastingToPeer
                          ? Icons.stop_screen_share
                          : Icons.screen_share),
                      label: Text(_isCastingToPeer
                          ? '停止投送本机屏幕'
                          : '将本机屏幕投屏给对方（允许对方反控）'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => _nativeChannel
                          .invokeMethod('openAccessibilitySettings'),
                      icon: const Icon(Icons.touch_app),
                      label: const Text('开启无障碍权限（当本机被控时需开启）'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),

          // 卡片 3：远程投屏画面显示与触控反控区（自适应手机竖屏与电脑横屏）
          Card(
            elevation: 0,
            color: const Color(0xFF0F172A),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                children: [
                  AspectRatio(
                    aspectRatio: _remoteAspectRatio,
                    child: _remoteScreenFrame == null
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(16),
                              child: Text(
                                '📱💻 远程投屏与触控反控区\n\n当另一台安卓手机或电脑开启「投屏」时，画面实时显示在此\n• 单击 = 轻触点击\n• 滑动 = 远程滑动/拖拽\n• 双击 = 双击操作\n• 长按 = 电脑右键',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white60),
                              ),
                            ),
                          )
                        : LayoutBuilder(
                            builder: (context, constraints) {
                              final w = constraints.maxWidth;
                              final h = constraints.maxHeight;
                              return GestureDetector(
                                onTapUp: (details) {
                                  final nx =
                                      (details.localPosition.dx / w).clamp(0.0, 1.0);
                                  final ny =
                                      (details.localPosition.dy / h).clamp(0.0, 1.0);
                                  _sendRemoteControlCmd(
                                      {'cmd': 'TAP', 'x': nx, 'y': ny});
                                },
                                onDoubleTapDown: (details) {
                                  final nx =
                                      (details.localPosition.dx / w).clamp(0.0, 1.0);
                                  final ny =
                                      (details.localPosition.dy / h).clamp(0.0, 1.0);
                                  _sendRemoteControlCmd(
                                      {'cmd': 'DOUBLE_TAP', 'x': nx, 'y': ny});
                                },
                                onLongPressStart: (details) {
                                  final nx =
                                      (details.localPosition.dx / w).clamp(0.0, 1.0);
                                  final ny =
                                      (details.localPosition.dy / h).clamp(0.0, 1.0);
                                  _sendRemoteControlCmd(
                                      {'cmd': 'RIGHT_CLICK', 'x': nx, 'y': ny});
                                },
                                onPanStart: (details) {
                                  final nx =
                                      (details.localPosition.dx / w).clamp(0.0, 1.0);
                                  final ny =
                                      (details.localPosition.dy / h).clamp(0.0, 1.0);
                                  _panStartNorm = Offset(nx, ny);
                                },
                                onPanEnd: (details) {
                                  _panStartNorm = null;
                                },
                                onPanUpdate: (details) {
                                  final nx =
                                      (details.localPosition.dx / w).clamp(0.0, 1.0);
                                  final ny =
                                      (details.localPosition.dy / h).clamp(0.0, 1.0);
                                  if (_panStartNorm != null) {
                                    final dx = (nx - _panStartNorm!.dx).abs();
                                    final dy = (ny - _panStartNorm!.dy).abs();
                                    if (dx > 0.04 || dy > 0.04) {
                                      final start = _panStartNorm!;
                                      _panStartNorm = Offset(nx, ny);
                                      _sendRemoteControlCmd({
                                        'cmd': 'SWIPE',
                                        'x1': start.dx,
                                        'y1': start.dy,
                                        'x2': nx,
                                        'y2': ny,
                                        'duration': 200,
                                      });
                                    }
                                  }
                                },
                                child: Image.memory(
                                  _remoteScreenFrame!,
                                  gaplessPlayback: true,
                                  fit: BoxFit.fill,
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 8),
                  // 底部远程系统导航栏（方便手机控手机时点击对方手机的返回/桌面/多任务）
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton.icon(
                        onPressed: () =>
                            _sendRemoteControlCmd({'cmd': 'KEY', 'key': 'BACK'}),
                        icon: const Icon(Icons.arrow_back_ios_new,
                            color: Colors.white70, size: 16),
                        label: const Text('对方返回',
                            style: TextStyle(color: Colors.white70)),
                      ),
                      TextButton.icon(
                        onPressed: () =>
                            _sendRemoteControlCmd({'cmd': 'KEY', 'key': 'HOME'}),
                        icon: const Icon(Icons.circle_outlined,
                            color: Colors.white70, size: 16),
                        label: const Text('对方桌面',
                            style: TextStyle(color: Colors.white70)),
                      ),
                      TextButton.icon(
                        onPressed: () => _sendRemoteControlCmd(
                            {'cmd': 'KEY', 'key': 'RECENTS'}),
                        icon: const Icon(Icons.crop_square,
                            color: Colors.white70, size: 16),
                        label: const Text('对方多任务',
                            style: TextStyle(color: Colors.white70)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
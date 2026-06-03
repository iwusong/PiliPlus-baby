/// BLE 远程锁屏服务，作为 GATT Server（外设）广播并接收家长端指令。
///
/// ## 架构
/// ```
/// 家长端 (nRF Connect / 遥控App)
///   │ 1. 扫描 BLE 广播
///   │ 2. 看到设备名 "PiliPlus" + Service UUID 0000abcd
///   │ 3. 连接 → 写入 Characteristic 0000abce
///   ▼
/// 本机 (Android GATT Server)
///   ├── GattServerPlugin.kt      原生层: 广播 + 接收写入(纯透传)
///   ├── BlePeripheralService     桥接层: MethodChannel/EventChannel
///   └── BleLockService           应用层: 认证 + 协议解析 + 锁屏
/// ```
///
/// ## 通信协议 (写入 Characteristic 0000abce-...)
/// ```
/// [0] Version (0x01)
/// [1] Command
///      0x01 = LOCK    锁屏
///      0x02 = UNLOCK  解锁
///      0x03 = AUTH    密码认证
/// [2-3] Magic "PI" (0x50 0x49)
/// [4+]  Payload (仅 AUTH 时有, UTF-8 密码)
/// ```
///
/// ## 安全流程
/// 1. 家长端连接 → 写入 AUTH + 密码("dudu")
/// 2. 认证通过后, LOCK/UNLOCK 才生效
/// 3. 断开连接 → 认证状态自动重置
///
/// ## 生命周期
/// App 启动 → onInit → 检查权限/蓝牙 → 自动开启 GATT Server + 广播
/// App 退出 → onClose → 停止广播, 释放资源
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:PiliPlus/services/ble_peripheral_service.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

class BleLockService extends GetxService {
  static BleLockService get instance => Get.find();

  /// 是否正在 BLE 广播
  final RxBool isAdvertising = false.obs;
  /// 是否有远程设备连接
  final RxBool isConnected = false.obs;
  /// 设备是否支持 BLE
  final RxBool isSupported = false.obs;
  /// 蓝牙是否已开启
  final RxBool isBluetoothOn = false.obs;
  /// 连接的远程设备 MAC 地址
  final RxString connectedDevice = ''.obs;
  /// 最后一次收到的原始指令文本
  final RxString lastCommand = ''.obs;
  /// 远程设备是否已通过密码认证
  final RxBool isAuthenticated = false.obs;

  /// 通信密码，家长端连接后需先发送 AUTH 指令携带此密码
  final String _password = 'dudu';

  final BlePeripheralService _peripheral = BlePeripheralService();
  StreamSubscription? _cmdSub;
  StreamSubscription? _connSub;
  StreamSubscription? _adapterSub;
  bool _starting = false;

  @override
  void onInit() {
    super.onInit();
    _init();
  }

  /// 初始化流程: 检查 BLE 支持 → 申请权限 → 检查蓝牙状态 → 启动 GATT Server
  Future<void> _init() async {
    if (kDebugMode) debugPrint('[BLE] ===== BleLockService init =====');
    isSupported.value = await _peripheral.isSupported();
    if (kDebugMode) debugPrint('[BLE] isSupported: ${isSupported.value}');
    if (!isSupported.value) return;

    final hasPermission = await _requestPermissions();
    if (kDebugMode) debugPrint('[BLE] permissions granted: $hasPermission');
    if (!hasPermission) return;

    // 监听蓝牙开关状态变化 (原生 BroadcastReceiver → EventChannel)
    _adapterSub = _peripheral.adapterStateStream.listen((state) {
      if (kDebugMode) debugPrint('[BLE] adapterState changed: $state');
      isBluetoothOn.value = state == 'on';
      if (state == 'on' && !isAdvertising.value) {
        if (kDebugMode) debugPrint('[BLE] adapter ON -> starting GATT server');
        _startGattServer();
      }
    });

    // 查询当前蓝牙状态, 决定启动还是弹开关
    final currentState = await _peripheral.getAdapterState();
    if (kDebugMode) debugPrint('[BLE] current adapterState: $currentState');
    isBluetoothOn.value = currentState == 'on';
    if (currentState == 'on') {
      if (kDebugMode) debugPrint('[BLE] BT already ON -> starting GATT server');
      await _startGattServer();
    } else {
      if (kDebugMode) debugPrint('[BLE] BT OFF -> requesting turnOn');
      _turnOnBluetooth();
    }
  }

  /// 申请 Android 12+ BLE 三件套权限: 扫描 + 连接 + 广播
  Future<bool> _requestPermissions() async {
    if (kDebugMode) debugPrint('[BLE] requesting permissions...');
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
    ].request();
    if (kDebugMode) {
      for (final e in statuses.entries) {
        debugPrint('[BLE]   ${e.key}: ${e.value}');
      }
    }
    return statuses[Permission.bluetoothScan] == PermissionStatus.granted &&
        statuses[Permission.bluetoothAdvertise] == PermissionStatus.granted;
  }

  /// 弹出系统蓝牙开关对话框, 用户同意后 adapterState 监听器会自动调用 _startGattServer
  Future<void> _turnOnBluetooth() async {
    try {
      if (kDebugMode) debugPrint('[BLE] _turnOnBluetooth: calling native turnOn');
      await _peripheral.turnOn();
      if (kDebugMode) debugPrint('[BLE] _turnOnBluetooth: success');
    } catch (e) {
      if (kDebugMode) debugPrint('[BLE] _turnOnBluetooth: FAILED $e');
    }
  }

  /// 启动原生 GATT Server: 创建 Service/Characteristic, 开始 BLE 广播
  /// 同时订阅远程命令流和连接状态流
  Future<void> _startGattServer() async {
    // 防重复启动
    if (_starting) {
      if (kDebugMode) debugPrint('[BLE] _startGattServer: already starting, skip');
      return;
    }
    if (isAdvertising.value) {
      if (kDebugMode) debugPrint('[BLE] _startGattServer: already advertising, skip');
      return;
    }
    _starting = true;
    if (kDebugMode) debugPrint('[BLE] _startGattServer: calling native start...');

    // 订阅远程 Characteristic 写入 → 命令解析
    _cmdSub?.cancel();
    _cmdSub = _peripheral.commandStream.listen((data) {
      if (kDebugMode) {
        final hex = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        debugPrint('[BLE] native rx: $hex (${data.length}B)');
      }
      _parseCommand(data);
    });

    // 订阅远程设备连接/断开事件
    _connSub?.cancel();
    _connSub = _peripheral.connectionStream.listen((event) {
      final dev = event['device'] as String? ?? '';
      final conn = event['connected'] as bool? ?? false;
      if (kDebugMode) {
        debugPrint('[BLE] native ${conn ? "CONNECTED" : "DISCONNECTED"}: $dev');
      }
      isConnected.value = conn;
      connectedDevice.value = dev;
      // 设备断开时重置认证状态, 重连需重新输入密码
      if (!conn) {
        isAuthenticated.value = false;
        if (kDebugMode) debugPrint('[BLE] auth reset on disconnect');
      }
    });

    // 向原生层发起广播 (传入设备名 "PiliPlus")
    final ok = await _peripheral.start(name: 'PiliPlus');
    _starting = false;
    if (kDebugMode) debugPrint('[BLE] _startGattServer: native start returned $ok');
    isAdvertising.value = ok;

    if (!ok) {
      if (kDebugMode) debugPrint('[BLE] >>> GATT server start FAILED <<<');
    }
  }

  /// 协议解析入口, 由原生侧收到数据后回调
  ///
  /// 流程: 检查最小长度 → 校验魔术字 "PI" → 处理 AUTH / LOCK / UNLOCK
  void _parseCommand(Uint8List data) {
    // 最短有效包: Version(1) + Cmd(1) + PI(2) = 4 字节
    if (data.length < 4) {
      if (kDebugMode) debugPrint('[BLE] ignored: too short (${data.length}B)');
      return;
    }

    // 魔术字校验, 过滤掉非本协议的 BLE 数据
    if (data[2] != 0x50 || data[3] != 0x49) {
      if (kDebugMode) debugPrint('[BLE] invalid protocol (no PI magic)');
      return;
    }

    final commandByte = data[1];

    // AUTH: 密码认证, payload 是 UTF-8 密码
    if (commandByte == 0x03) {
      final payload = data.length > 4
          ? utf8.decode(data.sublist(4))
          : '';
      if (kDebugMode) debugPrint('[BLE] AUTH: $payload');
      if (payload == _password) {
        isAuthenticated.value = true;
        if (kDebugMode) debugPrint('[BLE] AUTH OK');
      } else {
        isAuthenticated.value = false;
        if (kDebugMode) debugPrint('[BLE] AUTH FAILED');
      }
      return;
    }

    // 未认证的设备忽略锁屏/解锁指令
    if (!isAuthenticated.value) {
      if (kDebugMode) debugPrint('[BLE] cmd ignored: not authenticated');
      return;
    }

    if (commandByte == 0x01) {
      if (kDebugMode) debugPrint('[BLE] >>> LOCK <<<');
    } else if (commandByte == 0x02) {
      if (kDebugMode) debugPrint('[BLE] >>> UNLOCK <<<');
    } else {
      if (kDebugMode) debugPrint('[BLE] unknown cmd: $commandByte');
    }
  }

  @override
  void onClose() {
    if (kDebugMode) debugPrint('[BLE] BleLockService onClose');
    _cmdSub?.cancel();
    _connSub?.cancel();
    _adapterSub?.cancel();
    _peripheral.stop();
    super.onClose();
  }
}

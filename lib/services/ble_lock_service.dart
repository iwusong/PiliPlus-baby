/// BLE GATT Server 服务，作为外设广播并接收远程写入数据。
///
/// ## 架构
/// ```
/// 远程设备 (nRF Connect / 遥控App)
///   │ 1. 扫描 BLE 广播
///   │ 2. 看到设备名 "PiliPlus" + Service UUID 0000abcd
///   │ 3. 连接 → 写入 Characteristic 0000abce
///   ▼
/// 本机 (Android GATT Server)
///   ├── GattServerPlugin.kt      原生层: 广播 + 接收写入(纯透传)
///   ├── BlePeripheralService     桥接层: MethodChannel/EventChannel
///   └── BleLockService           应用层: 广播管理 + 连接/数据日志
/// ```
///
/// ## 生命周期
/// App 启动 → onInit → 检查权限/蓝牙 → 自动开启 GATT Server + 广播
/// App 退出 → onClose → 停止广播, 释放资源
import 'dart:async';
import 'dart:typed_data';

import 'package:PiliPlus/services/ble_peripheral_service.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

class BleLockService extends GetxService {
  static BleLockService get instance => Get.find();

  final RxBool isAdvertising = false.obs;
  final RxBool isConnected = false.obs;
  final RxBool isSupported = false.obs;
  final RxBool isBluetoothOn = false.obs;
  final RxString connectedDevice = ''.obs;

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

  Future<void> _init() async {
    if (kDebugMode) debugPrint('[BLE] ===== BleLockService init =====');
    isSupported.value = await _peripheral.isSupported();
    if (kDebugMode) debugPrint('[BLE] isSupported: ${isSupported.value}');
    if (!isSupported.value) return;

    final hasPermission = await _requestPermissions();
    if (kDebugMode) debugPrint('[BLE] permissions granted: $hasPermission');
    if (!hasPermission) return;

    _adapterSub = _peripheral.adapterStateStream.listen((state) {
      if (kDebugMode) debugPrint('[BLE] adapterState changed: $state');
      isBluetoothOn.value = state == 'on';
      if (state == 'on' && !isAdvertising.value) {
        _startGattServer();
      }
    });

    final currentState = await _peripheral.getAdapterState();
    if (kDebugMode) debugPrint('[BLE] current adapterState: $currentState');
    isBluetoothOn.value = currentState == 'on';
    if (currentState == 'on') {
      await _startGattServer();
    } else {
      _turnOnBluetooth();
    }
  }

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

  Future<void> _turnOnBluetooth() async {
    try {
      if (kDebugMode) debugPrint('[BLE] _turnOnBluetooth: calling native turnOn');
      await _peripheral.turnOn();
      if (kDebugMode) debugPrint('[BLE] _turnOnBluetooth: success');
    } catch (e) {
      if (kDebugMode) debugPrint('[BLE] _turnOnBluetooth: FAILED $e');
    }
  }

  Future<void> _startGattServer() async {
    if (_starting || isAdvertising.value) return;
    _starting = true;
    if (kDebugMode) debugPrint('[BLE] _startGattServer: calling native start...');

    _cmdSub?.cancel();
    _cmdSub = _peripheral.commandStream.listen((event) {
      final address = event['address'] as String? ?? '';
      final data = event['value'] as Uint8List?;
      if (data == null) return;
      if (kDebugMode) {
        final hex = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        debugPrint('[BLE] rx $hex from $address (${data.length}B)');
      }
    });

    _connSub?.cancel();
    _connSub = _peripheral.connectionStream.listen((event) {
      final mac = event['device'] as String? ?? '';
      final name = event['name'] as String? ?? mac;
      final conn = event['connected'] as bool? ?? false;
      if (kDebugMode) {
        debugPrint('[BLE] ${conn ? "CONNECTED" : "DISCONNECTED"}: $name ($mac)');
      }
      isConnected.value = conn;
      connectedDevice.value = name;
    });

    final ok = await _peripheral.start(name: 'PiliPlus');
    _starting = false;
    if (kDebugMode) debugPrint('[BLE] _startGattServer: $ok');
    isAdvertising.value = ok;
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

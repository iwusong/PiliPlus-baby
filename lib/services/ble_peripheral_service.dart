import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

class BlePeripheralService {
  static const _methodChannel = MethodChannel('com.piliplus/gatt_server');
  static const _cmdEvent = EventChannel('com.piliplus/gatt_server/command');
  static const _connEvent = EventChannel('com.piliplus/gatt_server/connection');
  static const _adapterEvent = EventChannel('com.piliplus/gatt_server/adapter');

  static final BlePeripheralService _instance = BlePeripheralService._();
  factory BlePeripheralService() => _instance;

  BlePeripheralService._() {
    _cmdEvent.receiveBroadcastStream().listen((raw) {
      if (raw is Map) {
        final value = raw['value'];
        final address = raw['address'] as String? ?? '';
        final data = value is Uint8List
            ? value
            : value is List<int>
                ? Uint8List.fromList(value)
                : null;
        if (data != null) {
          _onCommand.add({'address': address, 'value': data});
        }
      }
    });
    _connEvent.receiveBroadcastStream().listen((raw) {
      if (raw is Map) {
        _onConnection.add(Map<String, dynamic>.from(raw));
      }
    });
    _adapterEvent.receiveBroadcastStream().listen((raw) {
      if (raw is String) {
        _onAdapter.add(raw);
      }
    });
  }

  final _onCommand = StreamController<Map<String, dynamic>>.broadcast();
  final _onConnection = StreamController<Map<String, dynamic>>.broadcast();
  final _onAdapter = StreamController<String>.broadcast();

  /// 收到的 Characteristic 写入: {"address": "MAC", "value": Uint8List}
  Stream<Map<String, dynamic>> get commandStream => _onCommand.stream;
  Stream<Map<String, dynamic>> get connectionStream => _onConnection.stream;

  /// 蓝牙开关状态变化流: "on" / "off" / "turningOn" / "turningOff"
  Stream<String> get adapterStateStream => _onAdapter.stream;

  /// 查询当前蓝牙开关状态
  Future<String> getAdapterState() async =>
      await _methodChannel.invokeMethod<String>('getAdapterState') ?? 'unknown';

  /// 设备是否支持 BLE
  Future<bool> isSupported() async =>
      await _methodChannel.invokeMethod<bool>('isSupported') ?? false;

  /// 弹出系统对话框请求用户开启蓝牙
  Future<bool> turnOn() async =>
      await _methodChannel.invokeMethod<bool>('turnOn') ?? false;

  Future<bool> start({String name = 'PiliPlus'}) async =>
      await _methodChannel.invokeMethod<bool>('start', {'name': name}) ?? false;

  Future<bool> stop() async =>
      await _methodChannel.invokeMethod<bool>('stop') ?? false;
}

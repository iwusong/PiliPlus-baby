import 'dart:io';

import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

class BatteryOutPage extends StatefulWidget {
  const BatteryOutPage({super.key});

  @override
  State<BatteryOutPage> createState() => _BatteryOutPageState();
}

class _BatteryOutPageState extends State<BatteryOutPage> {
  Player? _player;

  @override
  void initState() {
    super.initState();
    _playAlert();
  }

  Future<void> _playAlert() async {
    try {
      final data = await rootBundle.load('assets/audio/y2284.wav');
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/battery_alert.wav');
      await tempFile.writeAsBytes(data.buffer.asUint8List());

      _player = await Player.create(
        configuration: PlayerConfiguration(
          options: Platform.isAndroid
              ? {
                  'volume-max': '100',
                  'ao': Pref.audioOutput,
                }
              : {},
        ),
      );
      await _player!.open(Media('file://${tempFile.path}'));
    } catch (e) {
      if (kDebugMode) debugPrint('[Audio] play error: $e');
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox.expand(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.battery_alert_rounded,
                size: 120,
                color: Colors.red.shade400,
              ),
              const SizedBox(height: 24),
              const Text(
                '电量耗尽',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 28,
                  fontWeight: FontWeight.w300,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '请充电',
                style: TextStyle(color: Colors.white38, fontSize: 16),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

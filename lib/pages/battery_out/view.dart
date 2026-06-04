import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class BatteryOutPage extends StatelessWidget {
  const BatteryOutPage({super.key});

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

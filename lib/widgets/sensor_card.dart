import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../constants/app_colors.dart';

class SensorCard extends StatelessWidget {
  final String title;
  final String value;
  final String ideal;
  final bool isAuto;
  final String modeKey;    // e.g. "auto_water"
  final String manualKey;  // e.g. "manual_water" — written to Firebase so MCU can act
  final IconData icon;
  final String logLabel;
  final int zoneIndex;
  final bool isOutOfRange;
  final Future<void> Function(String action) onLog;

  const SensorCard({
    super.key,
    required this.title,
    required this.value,
    required this.ideal,
    required this.isAuto,
    required this.modeKey,
    required this.manualKey,
    required this.icon,
    required this.logLabel,
    required this.zoneIndex,
    required this.onLog,
    this.isOutOfRange = false,
  });

  @override
  Widget build(BuildContext context) {
    final db = FirebaseDatabase.instance.ref();
    const canControl = true;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: isOutOfRange
            ? const BorderSide(color: alertRed, width: 1.5)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon,
                    color: isOutOfRange ? alertRed : primaryGreen,
                    size: 20),
                if (isOutOfRange) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.warning_rounded,
                      color: alertRed, size: 14),
                ],
              ],
            ),
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 12)),
            Text(value,
                style: TextStyle(
                    fontSize: 18,
                    color: isOutOfRange ? alertRed : primaryGreen,
                    fontWeight: FontWeight.bold)),
            Text(ideal,
                style: const TextStyle(fontSize: 9, color: Colors.grey)),
            const Spacer(),
            Switch(
              value: isAuto,
              activeColor: primaryGreen,
              onChanged: canControl
                  ? (val) {
                      db.child("zones/$zoneIndex/mode/$modeKey").set(val);
                      onLog("Toggled Auto $logLabel ${val ? 'ON' : 'OFF'}");
                    }
                  : null,
            ),
            ElevatedButton(
              onPressed: (!isAuto && canControl)
                  ? () async {
                      // FIX: write manual flag to Firebase so the MCU sees it
                      await db
                          .child("zones/$zoneIndex/mode/$manualKey")
                          .set(true);
                      onLog("Manual $logLabel Triggered");
                    }
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: accentGreen,
                minimumSize: const Size(double.infinity, 30),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text("Manual",
                  style: TextStyle(color: Colors.white, fontSize: 10)),
            ),
          ],
        ),
      ),
    );
  }
}

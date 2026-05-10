import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../constants/app_colors.dart';

class ActionCard extends StatelessWidget {
  final String title;
  final bool isAuto;
  final String modeKey;    // e.g. "auto_pesticide"
  final String manualKey;  // e.g. "manual_pesticide" — written to Firebase so MCU can act
  final IconData icon;
  final String logLabel;
  final int zoneIndex;
  final Future<void> Function(String action) onLog;

  const ActionCard({
    super.key,
    required this.title,
    required this.isAuto,
    required this.modeKey,
    required this.manualKey,
    required this.icon,
    required this.logLabel,
    required this.zoneIndex,
    required this.onLog,
  });

  @override
  Widget build(BuildContext context) {
    final db = FirebaseDatabase.instance.ref();

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: primaryGreen, size: 22),
            const SizedBox(height: 2),
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 12)),
            const Spacer(),
            Switch(
              value: isAuto,
              activeColor: primaryGreen,
              onChanged: (v) {
                db.child("zones/$zoneIndex/mode/$modeKey").set(v);
                onLog("Auto $logLabel ${v ? 'ON' : 'OFF'}");
              },
            ),
            ElevatedButton(
              onPressed: !isAuto
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

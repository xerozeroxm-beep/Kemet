import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../constants/app_colors.dart';

class CeilingCard extends StatefulWidget {
  final Map mode;
  final Map prof;
  final int zoneIndex;
  final Future<void> Function(String action) onLog;

  const CeilingCard({
    super.key,
    required this.mode,
    required this.prof,
    required this.zoneIndex,
    required this.onLog,
  });

  @override
  State<CeilingCard> createState() => _CeilingCardState();
}

class _CeilingCardState extends State<CeilingCard> {
  String? _pendingState;

  @override
  void didUpdateWidget(covariant CeilingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final confirmedState = (widget.prof['ceiling_state'] ?? 'closed').toString();
    if (_pendingState != null && _pendingState == confirmedState) {
      _pendingState = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final db = FirebaseDatabase.instance.ref();
    final bool isAuto = widget.mode['auto_ceiling'] ?? false;
    final String confirmedState = (widget.prof['ceiling_state'] ?? 'closed').toString();
    final String currentState = _pendingState ?? confirmedState;

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.roofing, color: primaryGreen, size: 22),
            const Text("Ceiling",
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 12)),
            Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                  color: _stateColor(currentState).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8)),
              child: Text(
                currentState.toUpperCase(),
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: _stateColor(currentState)),
              ),
            ),
            Switch(
              value: isAuto,
              activeColor: primaryGreen,
              onChanged: (v) {
                db.child("zones/${widget.zoneIndex}/mode/auto_ceiling").set(v);
                widget.onLog("Ceiling Auto ${v ? 'ON' : 'OFF'}");
              },
            ),
            DropdownButton<String>(
              value: currentState,
              isDense: true,
              items: ["open", "closed", "semi-closed"]
                  .map((s) => DropdownMenuItem(
                        value: s,
                        child: Text(s,
                            style: const TextStyle(fontSize: 11)),
                      ))
                  .toList(),
              onChanged: isAuto
                  ? null
                  : (v) {
                      if (v == null) return;
                      setState(() {
                        _pendingState = v;
                      });
                      // Write to mode/ceiling_state — this is the path
                      // the NodeMCU reads in manual mode to move the servo.
                      db.child("zones/${widget.zoneIndex}/mode/ceiling_state").set(v);
                      widget.onLog("Manual Ceiling set to $v");
                    },
            ),
          ],
        ),
      ),
    );
  }

  Color _stateColor(String state) {
    switch (state) {
      case 'open':
        return Colors.blue;
      case 'semi-closed':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }
}

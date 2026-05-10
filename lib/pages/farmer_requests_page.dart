import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../utils/firebase_parsing.dart';
import '../constants/app_colors.dart';

/// Owner-only page: lists pending farmer registration requests.
/// Owner can approve (and assign zones) or reject each request.
class FarmerRequestsPage extends StatelessWidget {
  final List allZones; // the full zones list from the dashboard stream
  const FarmerRequestsPage({super.key, required this.allZones});

  @override
  Widget build(BuildContext context) {
    final db = FirebaseDatabase.instance.ref();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Farmer Requests",
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: primaryGreen,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder(
        stream: db.child("owner_notifications").onValue,
        builder: (context, AsyncSnapshot<DatabaseEvent> snap) {
          if (!snap.hasData || snap.data!.snapshot.value == null) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.inbox_outlined, size: 60, color: Colors.grey),
                  SizedBox(height: 12),
                  Text("No pending requests",
                      style: TextStyle(color: Colors.grey, fontSize: 16)),
                ],
              ),
            );
          }

          final raw = firebaseMapFrom(snap.data!.snapshot.value);
          final pending = raw.entries
              .where((e) => e.value is Map && (e.value as Map)['status'] == 'pending')
              .toList();

          if (pending.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_outline,
                      size: 60, color: primaryGreen),
                  SizedBox(height: 12),
                  Text("All requests handled!",
                      style: TextStyle(color: Colors.grey, fontSize: 16)),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: pending.length,
            itemBuilder: (ctx, i) {
              final uid = pending[i].key;
              final info = firebaseMapFrom(pending[i].value);
              return _RequestCard(
                uid: uid,
                name: info['name'] ?? '',
                email: info['email'] ?? '',
                requestedAt: info['requested_at'] ?? '',
                allZones: allZones,
              );
            },
          );
        },
      ),
    );
  }
}

class _RequestCard extends StatefulWidget {
  final String uid;
  final String name;
  final String email;
  final String requestedAt;
  final List allZones;

  const _RequestCard({
    required this.uid,
    required this.name,
    required this.email,
    required this.requestedAt,
    required this.allZones,
  });

  @override
  State<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends State<_RequestCard> {
  bool _busy = false;

  void _approve() async {
    // Show zone assignment dialog first
    final selected = await showDialog<List<int>>(
      context: context,
      builder: (_) => _ZonePickerDialog(allZones: widget.allZones),
    );

    // If the dialog was dismissed without selecting, do nothing
    if (selected == null) return;

    setState(() => _busy = true);
    final db = FirebaseDatabase.instance.ref();
    try {
      // Update user status + assigned zones
      await db.child("users/${widget.uid}").update({
        "status": "approved",
        "assigned_zones": selected,
      });
      // Mark notification handled
      await db
          .child("owner_notifications/${widget.uid}")
          .update({"status": "approved"});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _reject() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Reject Request"),
        content: Text(
            "Are you sure you want to reject ${widget.name}'s registration?"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Cancel")),
          ElevatedButton(
            style:
                ElevatedButton.styleFrom(backgroundColor: alertRed),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Reject",
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    final db = FirebaseDatabase.instance.ref();
    try {
      await db.child("users/${widget.uid}").update({"status": "rejected"});
      await db
          .child("owner_notifications/${widget.uid}")
          .update({"status": "rejected"});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    String dateStr = '';
    try {
      final dt = DateTime.parse(widget.requestedAt);
      dateStr = "${dt.day}/${dt.month}/${dt.year}";
    } catch (_) {}

    return Card(
      elevation: 3,
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: primaryGreen.withOpacity(0.15),
                  child: Text(
                    widget.name.isNotEmpty
                        ? widget.name[0].toUpperCase()
                        : '?',
                    style: const TextStyle(
                        color: primaryGreen, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                      Text(widget.email,
                          style: const TextStyle(
                              color: Colors.grey, fontSize: 12)),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text("Pending",
                      style: TextStyle(
                          color: Colors.orange,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            if (dateStr.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text("Requested on $dateStr",
                  style: const TextStyle(color: Colors.grey, fontSize: 11)),
            ],
            const SizedBox(height: 14),
            if (_busy)
              const Center(child: CircularProgressIndicator())
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.close, size: 16),
                      label: const Text("Reject"),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: alertRed,
                        side: const BorderSide(color: alertRed),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _reject,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.check, size: 16),
                      label: const Text("Approve & Assign"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryGreen,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _approve,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Dialog that lets the owner pick which zones to assign to the new farmer.
class _ZonePickerDialog extends StatefulWidget {
  final List allZones;
  const _ZonePickerDialog({required this.allZones});

  @override
  State<_ZonePickerDialog> createState() => _ZonePickerDialogState();
}

class _ZonePickerDialogState extends State<_ZonePickerDialog> {
  final Set<int> _selected = {};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text("Assign Zones"),
      content: widget.allZones.isEmpty
          ? const Text("No zones exist yet. You can assign zones later from the farmer's profile.")
          : SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Select one or more zones for this farmer:",
                      style: TextStyle(color: Colors.grey, fontSize: 13)),
                  const SizedBox(height: 10),
                  ...List.generate(widget.allZones.length, (i) {
                    final z = widget.allZones[i];
                    final selected = _selected.contains(i);
                    return CheckboxListTile(
                      value: selected,
                      onChanged: (v) =>
                          setState(() => v! ? _selected.add(i) : _selected.remove(i)),
                      activeColor: primaryGreen,
                      title: Text(
                          "Zone ${z['zoneid']} — ${z['crop_name']}",
                          style: const TextStyle(fontSize: 14)),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    );
                  }),
                ],
              ),
            ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text("Cancel")),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: primaryGreen,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12))),
          onPressed: () => Navigator.pop(context, _selected.toList()),
          child: const Text("Confirm",
              style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

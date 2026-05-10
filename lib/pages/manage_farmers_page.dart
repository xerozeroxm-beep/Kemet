import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../utils/firebase_parsing.dart';
import '../constants/app_colors.dart';

/// Owner-only page: lists all approved farmers and lets the owner
/// edit their assigned zones.
class ManageFarmersPage extends StatelessWidget {
  final List allZones;
  const ManageFarmersPage({super.key, required this.allZones});

  @override
  Widget build(BuildContext context) {
    final db = FirebaseDatabase.instance.ref();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Manage Farmers",
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: primaryGreen,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder(
        stream: db.child("users").onValue,
        builder: (context, AsyncSnapshot<DatabaseEvent> snap) {
          if (!snap.hasData || snap.data!.snapshot.value == null) {
            return const Center(child: CircularProgressIndicator());
          }

          final raw = firebaseMapFrom(snap.data!.snapshot.value);
          final farmers = raw.entries
              .where((e) {
                if (e.value is! Map) return false;
                final u = e.value as Map;
                return u['role'] == 'farmer' &&
                    (u['status'] == 'approved' || u['status'] == null);
              })
              .toList();

          if (farmers.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.agriculture, size: 60, color: Colors.grey),
                  SizedBox(height: 12),
                  Text("No approved farmers yet.",
                      style: TextStyle(color: Colors.grey, fontSize: 16)),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: farmers.length,
            itemBuilder: (ctx, i) {
              final uid = farmers[i].key;
              final data = firebaseMapFrom(farmers[i].value);
              final assignedZones = firebaseIntListFrom(data['assigned_zones']);

              return _FarmerTile(
                uid: uid,
                name: data['name'] ?? '',
                email: data['email'] ?? '',
                assignedZones: assignedZones,
                allZones: allZones,
              );
            },
          );
        },
      ),
    );
  }
}

class _FarmerTile extends StatefulWidget {
  final String uid;
  final String name;
  final String email;
  final List<int> assignedZones;
  final List allZones;

  const _FarmerTile({
    required this.uid,
    required this.name,
    required this.email,
    required this.assignedZones,
    required this.allZones,
  });

  @override
  State<_FarmerTile> createState() => _FarmerTileState();
}

class _FarmerTileState extends State<_FarmerTile> {
  void _editZones() async {
    final result = await showDialog<List<int>>(
      context: context,
      builder: (_) => _ZoneEditDialog(
        allZones: widget.allZones,
        currentAssigned: widget.assignedZones,
        farmerName: widget.name,
      ),
    );
    if (result == null) return;
    await FirebaseDatabase.instance
        .ref("users/${widget.uid}")
        .update({"assigned_zones": result});
  }

  @override
  Widget build(BuildContext context) {
    final assignedNames = widget.assignedZones
        .where((i) => i < widget.allZones.length && widget.allZones[i] is Map)
        .map((i) {
          final z = widget.allZones[i] as Map;
          return "Zone ${z['zoneid']} (${z['crop_name']})";
        })
        .join(", ");

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        leading: CircleAvatar(
          backgroundColor: primaryGreen.withOpacity(0.15),
          child: Text(
            widget.name.isNotEmpty ? widget.name[0].toUpperCase() : '?',
            style: const TextStyle(
                color: primaryGreen, fontWeight: FontWeight.bold),
          ),
        ),
        title: Text(widget.name,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.email,
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 4),
            Text(
              assignedNames.isEmpty
                  ? "No zones assigned"
                  : assignedNames,
              style: TextStyle(
                  color: assignedNames.isEmpty ? alertRed : primaryGreen,
                  fontSize: 12,
                  fontWeight: FontWeight.w500),
            ),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.edit_outlined, color: primaryGreen),
          tooltip: "Edit assigned zones",
          onPressed: _editZones,
        ),
        isThreeLine: true,
      ),
    );
  }
}

class _ZoneEditDialog extends StatefulWidget {
  final List allZones;
  final List<int> currentAssigned;
  final String farmerName;

  const _ZoneEditDialog({
    required this.allZones,
    required this.currentAssigned,
    required this.farmerName,
  });

  @override
  State<_ZoneEditDialog> createState() => _ZoneEditDialogState();
}

class _ZoneEditDialogState extends State<_ZoneEditDialog> {
  late Set<int> _selected;

  @override
  void initState() {
    super.initState();
    _selected = Set<int>.from(widget.currentAssigned);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text("Zones for ${widget.farmerName}"),
      content: widget.allZones.isEmpty
          ? const Text("No zones exist yet.")
          : SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(widget.allZones.length, (i) {
                  final z = widget.allZones[i];
                  return CheckboxListTile(
                    value: _selected.contains(i),
                    onChanged: (v) => setState(
                        () => v! ? _selected.add(i) : _selected.remove(i)),
                    activeColor: primaryGreen,
                    title: Text(
                        "Zone ${z['zoneid']} — ${z['crop_name']}",
                        style: const TextStyle(fontSize: 14)),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  );
                }),
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
          child: const Text("Save",
              style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

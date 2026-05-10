import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../utils/firebase_parsing.dart';
import '../constants/app_colors.dart';
import '../services/gemini_service.dart';
import '../services/user_session.dart';
import 'zone_detail_page.dart';
import 'alerts_page.dart';
import 'profile_page.dart';
import 'auth_screen.dart';
import 'farmer_requests_page.dart';
import 'manage_farmers_page.dart';

class ZonesDashboard extends StatefulWidget {
  const ZonesDashboard({super.key});

  @override
  State<ZonesDashboard> createState() => _ZonesDashboardState();
}

class _ZonesDashboardState extends State<ZonesDashboard> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final GeminiService _gemini = GeminiService();

  // ── Zone CRUD (owner only) ─────────────────────────────────────────────────

  Future<void> _handleZone(String crop, {int? index}) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final data = await _gemini.getCropDetails(crop);
    if (mounted) Navigator.pop(context);

    // FIX 1: Guard every post-await context usage. If the user navigated away
    // while Gemini was running, `mounted` is false and any call that touches
    // the widget tree (ScaffoldMessenger, Navigator) would throw
    // "Looking up a deactivated widget's ancestor is unsafe".
    if (!mounted) return;

    if (data == null || data.containsKey('error')) {
      _showError("Invalid crop name! Gemini could not identify: $crop");
      return;
    }

    // FIX 3: Wrap the Firebase read-modify-write in try/catch so that a
    // network failure or permission error doesn't crash the screen with an
    // unhandled exception.
    try {
      final snap = await _db.child("zones").get();
      final zones = firebaseListFrom(snap.value);

      final newZone = {
        "zoneid": index != null ? index + 1 : zones.length + 1,
        "crop_name": crop,
        "icon_code": data['icon_code'],
        "mode": {
          "auto_water": true,
          "auto_ec": true,
          "auto_pesticide": true,
          "auto_ceiling": true,
          // FIX: NodeMCU reads mode/ceiling_state (string) in manual mode.
          // The old key "manual_ceiling: false" was never read by the hardware
          // or the CeilingCard widget, so the servo had no initial state to use.
          "ceiling_state": "open",
        },
        "crop_profile": {
          "min_moisture": data['min_m'],
          "max_moisture": data['max_m'],
          "current_moisture": 50,
          "min_ec": data['min_ec'],
          "max_ec": data['max_ec'],
          "current_ec": 1.2,
          "pesticide": false,
          "rain_detected": false,
          "ceiling_state": "closed",
          "weather_api": 0,
        },
        "logs": [],
        "cv_alerts": {
          "harvest": {"detected": false, "count": 0, "timestamp": "", "message": ""},
          "disease": {"detected": false, "count": 0, "timestamp": "", "message": ""},
          "pest": {"detected": false, "scenario": "none", "counts": {}, "timestamp": "", "message": ""},
        },
      };

      if (index != null) {
        zones[index] = newZone;
      } else {
        zones.add(newZone);
      }
      await _db.child("zones").set(zones);
    } catch (e) {
      if (mounted) _showError("Failed to save zone. Please check your connection.");
    }
  }

  void _confirmDelete(int i, List zones) async {
    if (zones.length <= 1) {
      _showError("Minimum 1 zone required.");
      return;
    }
    bool? confirmed = await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Delete Zone"),
        content: const Text(
            "Are you sure? This zone and all its logs will be permanently deleted."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Cancel")),
          ElevatedButton(
              style:
                  ElevatedButton.styleFrom(backgroundColor: alertRed),
              onPressed: () => Navigator.pop(context, true),
              child: const Text("Delete",
                  style: TextStyle(color: Colors.white))),
        ],
      ),
    );
    if (confirmed == true) {
      zones.removeAt(i);
      for (int k = 0; k < zones.length; k++) {
        zones[k]['zoneid'] = k + 1;
      }
      await _db.child("zones").set(zones);
    }
  }

  void _showInputDialog({int? index, String? old}) {
    final controller = TextEditingController(text: old);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(index == null ? "Add New Zone" : "Rename Zone"),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: "e.g. Tomato, Wheat, Blueberry",
            prefixIcon: Icon(Icons.eco, color: primaryGreen),
          ),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Cancel")),
          ElevatedButton(
            style:
                ElevatedButton.styleFrom(backgroundColor: primaryGreen),
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty) {
                _handleZone(text, index: index);
                Navigator.pop(ctx);
              }
            },
            child: const Text("Save",
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: alertRed));
  }

  int _countAlerts(List visibleZones) {
    int count = 0;
    for (var z in visibleZones) {
      if (z is! Map) continue;
      // ── Sensor alerts ──────────────────────────────────────────────────────
      final prof = z['crop_profile'];
      if (prof is Map) {
        final moisture = (prof['current_moisture'] ?? 0).toDouble();
        final ec = (prof['current_ec'] ?? 0).toDouble();
        final minM = (prof['min_moisture'] ?? 0).toDouble();
        final maxM = (prof['max_moisture'] ?? 100).toDouble();
        final minEc = (prof['min_ec'] ?? 0).toDouble();
        final maxEc = (prof['max_ec'] ?? 10).toDouble();
        if (moisture < minM || moisture > maxM) count++;
        if (ec < minEc || ec > maxEc) count++;
      }

      // ── CV model alerts ────────────────────────────────────────────────────
      final cvAlerts = z['cv_alerts'];
      if (cvAlerts is Map) {
        if (cvAlerts['harvest'] is Map && cvAlerts['harvest']['detected'] == true) count++;
        if (cvAlerts['disease'] is Map && cvAlerts['disease']['detected'] == true) count++;
        if (cvAlerts['pest'] is Map && cvAlerts['pest']['detected'] == true) count++;
      }
    }
    return count;
  }

  void _logout() async {
    UserSession.instance.clear();
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      Navigator.pushAndRemoveUntil(context,
          MaterialPageRoute(builder: (_) => const AuthScreen()),
          (r) => false);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isOwner = UserSession.instance.isOwner;

    return StreamBuilder(
      stream: _db.child("zones").onValue,
      builder: (context, AsyncSnapshot<DatabaseEvent> snapshot) {
        final allZones = snapshot.hasData &&
                snapshot.data!.snapshot.value != null
            ? firebaseListFrom(snapshot.data!.snapshot.value)
            : <dynamic>[];

        // Farmers only see their assigned zones
        final visibleZones = isOwner
            ? allZones
            : allZones.asMap().entries
                .where((e) => UserSession.instance.canAccessZone(e.key))
                .map((e) => e.value)
                .toList();

        // We pass the real index in allZones so DB writes still work
        final visibleIndices = isOwner
            ? List.generate(allZones.length, (i) => i)
            : allZones.asMap().entries
                .where((e) => UserSession.instance.canAccessZone(e.key))
                .map((e) => e.key)
                .toList();

        final alertCount = _countAlerts(visibleZones);

        return StreamBuilder(
          stream: _db.child("owner_notifications").onValue,
          builder: (context, AsyncSnapshot<DatabaseEvent> notifSnap) {
            int pendingRequests = 0;
            if (isOwner &&
                notifSnap.hasData &&
                notifSnap.data!.snapshot.value != null) {
              final raw = firebaseMapFrom(notifSnap.data!.snapshot.value);
              pendingRequests = raw.values
                  .where((v) => v is Map && v['status'] == 'pending')
                  .length;
            }

            return Scaffold(
              appBar: AppBar(
                title: const Text("KEMET DASHBOARD",
                    style: TextStyle(fontWeight: FontWeight.bold)),
                backgroundColor: primaryGreen,
                foregroundColor: Colors.white,
                centerTitle: true,
                actions: [
                  // Alert bell
                  Stack(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.notifications_outlined),
                        onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    AlertsPage(zones: visibleZones))),
                      ),
                      if (alertCount > 0)
                        Positioned(
                          right: 6,
                          top: 6,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: const BoxDecoration(
                                color: alertRed, shape: BoxShape.circle),
                            child: Text('$alertCount',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold)),
                          ),
                        ),
                    ],
                  ),

                  // Owner: farmer requests badge
                  if (isOwner)
                    Stack(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.person_add_outlined),
                          tooltip: "Farmer Requests",
                          onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => FarmerRequestsPage(
                                      allZones: allZones))),
                        ),
                        if (pendingRequests > 0)
                          Positioned(
                            right: 6,
                            top: 6,
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              decoration: const BoxDecoration(
                                  color: Colors.orange,
                                  shape: BoxShape.circle),
                              child: Text('$pendingRequests',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ),
                      ],
                    ),

                  // Owner: manage farmers
                  if (isOwner)
                    IconButton(
                      icon: const Icon(Icons.group_outlined),
                      tooltip: "Manage Farmers",
                      onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  ManageFarmersPage(allZones: allZones))),
                    ),

                  // Profile
                  IconButton(
                    icon: const Icon(Icons.account_circle_outlined),
                    onPressed: () => Navigator.push(context,
                        MaterialPageRoute(
                            builder: (_) => const ProfilePage())),
                  ),
                  // Logout
                  IconButton(
                    icon: const Icon(Icons.logout),
                    onPressed: _logout,
                  ),
                ],
              ),

              body: Column(
                children: [
                  // Role badge bar
                  Container(
                    color: isOwner
                        ? primaryGreen.withOpacity(0.1)
                        : accentGreen.withOpacity(0.08),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Row(
                      children: [
                        Icon(
                          isOwner ? Icons.manage_accounts : Icons.agriculture,
                          size: 16,
                          color: primaryGreen,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          "${UserSession.instance.name}  •  ${isOwner ? 'Owner' : 'Farmer'}",
                          style: const TextStyle(
                              color: primaryGreen,
                              fontWeight: FontWeight.w600,
                              fontSize: 13),
                        ),
                        if (isOwner) ...[
                          const Spacer(),
                          const Text("Full Access",
                              style: TextStyle(
                                  color: primaryGreen, fontSize: 11)),
                        ] else ...[
                          const Spacer(),
                          Text(
                            "${visibleZones.length} Zone${visibleZones.length == 1 ? '' : 's'} Assigned",
                            style: const TextStyle(
                                color: primaryGreen, fontSize: 11),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Expanded(
                      child: _buildGrid(visibleZones, visibleIndices, allZones)),
                ],
              ),

              // FAB — owner only
              floatingActionButton: isOwner
                  ? FloatingActionButton.extended(
                      backgroundColor: primaryGreen,
                      foregroundColor: Colors.white,
                      icon: const Icon(Icons.add),
                      label: const Text("Add Zone"),
                      onPressed: () => _showInputDialog(),
                    )
                  : null,
            );
          },
        );
      },
    );
  }

  Widget _buildGrid(List visibleZones, List<int> visibleIndices, List allZones) {
    if (visibleZones.isEmpty) {
      final isOwner = UserSession.instance.isOwner;
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.eco_outlined, size: 60, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              isOwner ? "No zones yet." : "No zones assigned to you yet.",
              style: const TextStyle(color: Colors.grey, fontSize: 16),
            ),
            Text(
              isOwner
                  ? "Tap + to add a zone."
                  : "Ask the owner to assign your zones.",
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(15),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: visibleZones.length == 1 ? 1 : 2,
        mainAxisExtent: visibleZones.length == 1 ? 250 : 190,
        crossAxisSpacing: 15,
        mainAxisSpacing: 15,
      ),
      itemCount: visibleZones.length,
      itemBuilder: (ctx, i) =>
          _buildZoneCard(visibleZones, i, visibleIndices[i], allZones),
    );
  }

  Widget _buildZoneCard(
      List visibleZones, int visibleIdx, int realIdx, List allZones) {
    final z = visibleZones[visibleIdx];
    if (z is! Map) {
      return const SizedBox.shrink();
    }
    final prof = z['crop_profile'];
    final isOwner = UserSession.instance.isOwner;
    final iconCode = z['icon_code'] is int ? z['icon_code'] as int : 0xe3ad;

    bool hasSensorAlert = false;
    if (prof is Map) {
      final moisture = (prof['current_moisture'] ?? 0).toDouble();
      final ec = (prof['current_ec'] ?? 0).toDouble();
      if (moisture < (prof['min_moisture'] ?? 0) ||
          moisture > (prof['max_moisture'] ?? 100) ||
          ec < (prof['min_ec'] ?? 0) ||
          ec > (prof['max_ec'] ?? 10)) {
        hasSensorAlert = true;
      }
    }

    // Also flag the card when a CV model has raised an alert, so the zone
    // card badge matches what the notification bell counts.
    bool hasCvAlert = false;
    final cvAlerts = z['cv_alerts'];
    if (cvAlerts is Map) {
      if (cvAlerts['harvest'] is Map && cvAlerts['harvest']['detected'] == true) hasCvAlert = true;
      if (cvAlerts['disease'] is Map && cvAlerts['disease']['detected'] == true) hasCvAlert = true;
      if (cvAlerts['pest']    is Map && cvAlerts['pest']['detected']    == true) hasCvAlert = true;
    }

    // hasAlert drives the ⚠ badge — true for either kind of alert.
    // hasSensorAlert is kept separate so only out-of-range sensor readings
    // colour the moisture/EC text red (a CV alert should not make normal
    // sensor readings appear red).
    final bool hasAlert = hasSensorAlert || hasCvAlert;

    return Card(
      elevation: 4,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ZoneDetailPage(zoneIndex: realIdx)),
        ),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    IconData(iconCode, fontFamily: 'MaterialIcons'),
                    size: 48,
                    color: primaryGreen,
                  ),
                  const SizedBox(height: 4),
                  Text("ZONE ${z['zoneid']}",
                      style: const TextStyle(
                          fontSize: 11, color: Colors.grey)),
                  Text(
                    "${z['crop_name']}".toUpperCase(),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  if (prof is Map) ...[
                    const SizedBox(height: 6),
                    Text(
                      "💧${prof['current_moisture']}%  ⚡${prof['current_ec']}",
                      style: TextStyle(
                          fontSize: 11,
                          color: hasSensorAlert ? alertRed : Colors.grey),
                    ),
                  ]
                ],
              ),
            ),

            if (hasAlert)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                      color: alertRed,
                      borderRadius: BorderRadius.circular(8)),
                  child: const Text("⚠ Alert",
                      style:
                          TextStyle(color: Colors.white, fontSize: 10)),
                ),
              ),

            if (isOwner)
              Positioned(
                top: 4,
                right: 4,
                child: PopupMenuButton(
                  icon: const Icon(Icons.more_vert,
                      size: 18, color: Colors.grey),
                  onSelected: (v) {
                    if (v == 'edit') {
                      _showInputDialog(
                          index: realIdx, old: z['crop_name']);
                    } else {
                      _confirmDelete(realIdx, allZones);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'edit',
                        child: Row(children: [
                          Icon(Icons.edit, size: 16),
                          SizedBox(width: 8),
                          Text("Rename Zone"),
                        ])),
                    const PopupMenuItem(
                        value: 'delete',
                        child: Row(children: [
                          Icon(Icons.delete_outline,
                              size: 16, color: alertRed),
                          SizedBox(width: 8),
                          Text("Delete Zone",
                              style: TextStyle(color: alertRed)),
                        ])),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

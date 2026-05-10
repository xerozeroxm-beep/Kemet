import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';
import '../utils/firebase_parsing.dart';
import '../constants/app_colors.dart';
import '../services/user_session.dart';
import '../widgets/sensor_card.dart';
import '../widgets/ceiling_card.dart';
import '../widgets/action_card.dart';
import '../widgets/status_card.dart';
import 'auth_screen.dart';
import 'analytics_page.dart';

class ZoneDetailPage extends StatefulWidget {
  final int zoneIndex;
  const ZoneDetailPage({super.key, required this.zoneIndex});

  @override
  State<ZoneDetailPage> createState() => _ZoneDetailPageState();
}

class _ZoneDetailPageState extends State<ZoneDetailPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _cleanOldLogs();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _cleanOldLogs() async {
    final logRef = _db.child("zones/${widget.zoneIndex}/logs");
    final snap = await logRef.get();
    // FIX: guard against logs being null or a non-List type (e.g. Map from pushJSON)
    if (!snap.exists) return;

    final rawLogs = firebaseListFrom(snap.value);
    if (rawLogs.isEmpty) return;

    final logs = List<Map<String, dynamic>>.from(rawLogs.whereType<Map>().map(
      (entry) => Map<String, dynamic>.from(entry),
    ));
    final weekAgo = DateTime.now().subtract(const Duration(days: 7));
    logs.removeWhere((l) {
      try {
        final parsed = DateTime.parse(l['timestamp'].toString());
        // Keep fallback timestamps written by hardware logs (year < 2025).
        // They are synthetic and should not be pruned by the 7-day cleanup.
        if (parsed.year < 2025) return false;
        return parsed.isBefore(weekAgo);
      } catch (_) {
        return false; // keep entries with unparseable timestamps (e.g. "SYSTEM_AUTO")
      }
    });
    await logRef.set(logs);
  }

  Future<void> _logAction(String action) async {
    final logRef = _db.child("zones/${widget.zoneIndex}/logs");
    final snap = await logRef.get();
    List logs = [];
    if (snap.exists) {
      logs = firebaseListFrom(snap.value).whereType<Map>().toList();
    }
    logs.add({
      "timestamp": DateTime.now().toIso8601String(),
      "action": action,
      "user": UserSession.instance.name,
    });
    await logRef.set(logs);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: _db.child("zones/${widget.zoneIndex}").onValue,
      builder: (context, snapshot) {
        if (!snapshot.hasData ||
            snapshot.data!.snapshot.value == null) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        final zone = firebaseMapFrom(snapshot.data!.snapshot.value);
        final prof = zone['crop_profile'] is Map
            ? Map<String, dynamic>.from(zone['crop_profile'] as Map)
            : <String, dynamic>{};
        final mode = zone['mode'] is Map
            ? Map<String, dynamic>.from(zone['mode'] as Map)
            : <String, dynamic>{};

        return Scaffold(
          appBar: AppBar(
            title: Text("${zone['crop_name']}".toUpperCase(),
                style: const TextStyle(fontWeight: FontWeight.bold)),
            backgroundColor: primaryGreen,
            foregroundColor: Colors.white,
            actions: [
              IconButton(
                icon: const Icon(Icons.bar_chart),
                tooltip: "Analytics",
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => AnalyticsPage(
                              zoneIndex: widget.zoneIndex,
                              cropName: zone['crop_name'],
                              prof: prof,
                            ))),
              ),
            ],
            bottom: TabBar(
              controller: _tabCtrl,
              indicatorColor: Colors.white,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white60,
              tabs: const [
                Tab(icon: Icon(Icons.dashboard_outlined), text: "Controls"),
                Tab(icon: Icon(Icons.history), text: "History"),
              ],
            ),
          ),
          drawer: _buildDrawer(),
          body: TabBarView(
            controller: _tabCtrl,
            children: [
              _buildSensorGrid(prof, mode, zone),
              _buildHistory(zone['logs'] ?? []),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDrawer() {
    final isOwner = UserSession.instance.isOwner;
    return Drawer(
      child: Column(
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(color: primaryGreen),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.eco_rounded,
                    color: Colors.white, size: 40),
                const SizedBox(height: 8),
                const Text("KEMET MENU",
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                      color: isOwner
                          ? Colors.amber.shade700
                          : Colors.green.shade300,
                      borderRadius: BorderRadius.circular(20)),
                  child: Text(
                    isOwner ? "Owner" : "Farmer",
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading:
                const Icon(Icons.dashboard, color: primaryGreen),
            title: const Text("All Zones"),
            onTap: () =>
                Navigator.popUntil(context, (r) => r.isFirst),
          ),
          const Divider(),
          const Spacer(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text("Logout"),
            onTap: () {
              UserSession.instance.clear();
              FirebaseAuth.instance.signOut();
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(
                    builder: (_) => const AuthScreen()),
                (r) => false,
              );
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildSensorGrid(Map prof, Map mode, Map zone) {
    return GridView.count(
      padding: const EdgeInsets.all(12),
      crossAxisCount: 2,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      children: [
        SensorCard(
          title: "Soil Moisture",
          value: "${prof['current_moisture']}%",
          ideal:
              "Ideal: ${prof['min_moisture']}-${prof['max_moisture']}%",
          isAuto: mode['auto_water'] ?? true,
          modeKey: "auto_water",
          manualKey: "manual_water", // FIX: tells MCU to trigger manual irrigation
          icon: Icons.water_drop,
          logLabel: "Irrigation",
          zoneIndex: widget.zoneIndex,
          onLog: _logAction,
          isOutOfRange: _isOutOfRange(
              (prof['current_moisture'] ?? 0).toDouble(),
              (prof['min_moisture'] ?? 0).toDouble(),
              (prof['max_moisture'] ?? 100).toDouble()),
        ),
        SensorCard(
          title: "EC Level",
          value: "${prof['current_ec']}",
          ideal: "Ideal: ${prof['min_ec']}-${prof['max_ec']}",
          isAuto: mode['auto_ec'] ?? true,
          modeKey: "auto_ec",
          manualKey: "manual_ec", // FIX: tells MCU to trigger manual EC dose
          icon: Icons.bolt,
          logLabel: "EC Dose",
          zoneIndex: widget.zoneIndex,
          onLog: _logAction,
          isOutOfRange: _isOutOfRange(
              (prof['current_ec'] ?? 0).toDouble(),
              (prof['min_ec'] ?? 0).toDouble(),
              (prof['max_ec'] ?? 10).toDouble()),
        ),
        CeilingCard(
          mode: mode,
          prof: prof,
          zoneIndex: widget.zoneIndex,
          onLog: _logAction,
        ),
        ActionCard(
          title: "Pesticide",
          isAuto: mode['auto_pesticide'] ?? true,
          modeKey: "auto_pesticide",
          manualKey: "manual_pesticide", // FIX: tells MCU to trigger manual pesticide
          icon: Icons.bug_report,
          logLabel: "Pesticide Spray",
          zoneIndex: widget.zoneIndex,
          onLog: _logAction,
        ),
        StatusCard(
          title: "Rain Sensor",
          value: (prof['rain_detected'] ?? false)
              ? "Rain Detected"
              : "Dry",
          icon: Icons.umbrella,
          color: (prof['rain_detected'] ?? false)
              ? Colors.blue
              : Colors.grey,
        ),
        StatusCard(
          title: "Weather API",
          value: "${prof['weather_api'] ?? '--'}% Rain Prob.",
          icon: Icons.cloud,
          color: Colors.blueGrey,
        ),
        // ── CV Model status cards ──────────────────────────────────────────
        _buildCvStatusCard(
          "CV Harvest",
          zone['cv_alerts']?['harvest'],
          Icons.agriculture,
          Colors.green.shade700,
        ),
        _buildCvStatusCard(
          "CV Disease",
          zone['cv_alerts']?['disease'],
          Icons.coronavirus,
          Colors.purple.shade600,
        ),
        _buildCvStatusCard(
          "CV Pest",
          zone['cv_alerts']?['pest'],
          Icons.pest_control,
          Colors.orange.shade700,
        ),
      ],
    );
  }

  bool _isOutOfRange(double value, double min, double max) {
    return value < min || value > max;
  }

  /// Builds a read-only status card for a CV model alert node from Firebase.
  /// [cvAlert] is the map at /zones/N/cv_alerts/<model>  (may be null).
  Widget _buildCvStatusCard(
      String title, dynamic cvAlert, IconData icon, Color activeColor) {
    if (cvAlert == null) {
      return StatusCard(
        title: title,
        value: "No data yet",
        icon: icon,
        color: Colors.grey,
      );
    }
    if (cvAlert is! Map) {
      return StatusCard(
        title: title,
        value: "No data yet",
        icon: icon,
        color: Colors.grey,
      );
    }
    final detected = cvAlert['detected'] == true;
    String value;
    if (cvAlert.containsKey('scenario')) {
      final scenario = cvAlert['scenario'] ?? 'none';
      value = scenario == 'none'
          ? "Clear"
          : scenario.toString().replaceAll('_', ' ');
    } else {
      final count = cvAlert['count'] ?? 0;
      value = detected ? "Detected ($count)" : "Clear";
    }
    return StatusCard(
      title: title,
      value: value,
      icon: icon,
      color: detected ? activeColor : Colors.grey,
    );
  }

  String _formatLogSubtitle(String user, String timestamp) {
    String timeStr;
    try {
      timeStr = DateFormat('MMM d, HH:mm').format(DateTime.parse(timestamp));
    } catch (_) {
      timeStr = timestamp; // fallback for non-ISO timestamps
    }
    final displayUser = user == 'CV_System_Automated' ? 'CV System' : user;
    return "$displayUser • $timeStr";
  }

  Widget _buildHistory(dynamic logsRaw) {
    // FIX: Firebase pushJSON creates a Map<key, value>; app writes a List.
    // Normalise both into a flat List so the UI never crashes.
    List logs = [];
    if (logsRaw is List) {
      logs = logsRaw.whereType<Map>().toList();
    } else if (logsRaw is Map) {
      logs = logsRaw.values.whereType<Map>().toList();
    }
    if (logs.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history_toggle_off,
                size: 50, color: Colors.grey),
            SizedBox(height: 12),
            Text("No activity in the last 7 days.",
                style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return Column(
      children: [
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: lightGreen,
          child: Row(
            children: [
              const Icon(Icons.history, color: primaryGreen, size: 18),
              const SizedBox(width: 8),
              const Text("ZONE HISTORY — LAST 7 DAYS",
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: primaryGreen,
                      fontSize: 13)),
              const Spacer(),
              Text("${logs.length} entries",
                  style: const TextStyle(
                      color: Colors.grey, fontSize: 12)),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: logs.length,
            itemBuilder: (_, i) {
              final log = logs[logs.length - 1 - i];
              final action = (log['action'] as String? ?? '');
              final user   = (log['user']   as String? ?? '');
              final isManual = action.contains('Manual');
              final isCv     = user == 'CV_System_Automated';
              final iconData = isCv
                  ? Icons.camera_alt
                  : isManual
                      ? Icons.touch_app
                      : Icons.auto_mode;
              final iconColor = isCv
                  ? Colors.purple.shade400
                  : isManual
                      ? warningOrange
                      : primaryGreen;
              return ListTile(
                leading: CircleAvatar(
                  radius: 16,
                  backgroundColor: iconColor.withOpacity(0.15),
                  child: Icon(iconData, size: 16, color: iconColor),
                ),
                title: Text(action,
                    style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                  _formatLogSubtitle(user, log['timestamp'] as String? ?? ''),
                  style: const TextStyle(fontSize: 11),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}


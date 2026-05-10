import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../utils/firebase_parsing.dart';
import '../constants/app_colors.dart';

class AlertsPage extends StatelessWidget {
  final List zones;
  const AlertsPage({super.key, required this.zones});

  // NOTE: _buildSensorAlerts has been moved into _AlertsBody so that both
  // sensor alerts and CV alerts are derived from the same live Firebase
  // snapshot. Building sensor alerts from the stale `zones` constructor
  // argument while CV alerts used a fresh stream caused the two sections to
  // reflect different moments in time (Bug 7).

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Alerts & Warnings",
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: primaryGreen,
        foregroundColor: Colors.white,
      ),
      body: _AlertsBody(zones: zones),
    );
  }
}

// ── Body with Firebase stream for ALL alerts (sensor + CV) ───────────────────

class _AlertsBody extends StatelessWidget {
  final List zones;

  const _AlertsBody({required this.zones});

  // FIX: accepts fresh zone data from the StreamBuilder — no longer uses the
  // stale snapshot passed to AlertsPage at construction time.
  List<_Alert> _buildSensorAlerts(List freshZones) {
    final alerts = <_Alert>[];
    for (var z in freshZones) {
      if (z is! Map) continue;
      final prof = z['crop_profile'];
      if (prof is! Map) continue;
      final crop = "${z['crop_name']}".toUpperCase();
      final zoneId = z['zoneid'];
      if (zoneId is! int) continue;

      final moisture = (prof['current_moisture'] ?? 0).toDouble();
      final minM = (prof['min_moisture'] ?? 0).toDouble();
      final maxM = (prof['max_moisture'] ?? 100).toDouble();

      if (moisture < minM) {
        alerts.add(_Alert(
          zoneId: zoneId,
          crop: crop,
          type: AlertType.low,
          metric: "Soil Moisture",
          current: moisture,
          min: minM,
          max: maxM,
          unit: "%",
          icon: Icons.water_drop,
        ));
      } else if (moisture > maxM) {
        alerts.add(_Alert(
          zoneId: zoneId,
          crop: crop,
          type: AlertType.high,
          metric: "Soil Moisture",
          current: moisture,
          min: minM,
          max: maxM,
          unit: "%",
          icon: Icons.water_drop,
        ));
      }

      final ec = (prof['current_ec'] ?? 0).toDouble();
      final minEc = (prof['min_ec'] ?? 0).toDouble();
      final maxEc = (prof['max_ec'] ?? 10).toDouble();

      if (ec < minEc) {
        alerts.add(_Alert(
          zoneId: zoneId,
          crop: crop,
          type: AlertType.low,
          metric: "EC Level",
          current: ec,
          min: minEc,
          max: maxEc,
          unit: "",
          icon: Icons.bolt,
        ));
      } else if (ec > maxEc) {
        alerts.add(_Alert(
          zoneId: zoneId,
          crop: crop,
          type: AlertType.high,
          metric: "EC Level",
          current: ec,
          min: minEc,
          max: maxEc,
          unit: "",
          icon: Icons.bolt,
        ));
      }

      if (prof['rain_detected'] == true) {
        alerts.add(_Alert(
          zoneId: zoneId,
          crop: crop,
          type: AlertType.info,
          metric: "Rain Sensor",
          current: 1,
          min: 0,
          max: 0,
          unit: "",
          icon: Icons.umbrella,
          customMessage: "Rain detected in zone $zoneId",
        ));
      }
    }
    return alerts;
  }

  List<_Alert> _buildCvAlerts(List freshZones, Map<int, Map> cvAlertsByZone) {
    final alerts = <_Alert>[];
    for (var z in freshZones) {
      if (z is! Map) continue;
      final zoneId = z['zoneid'];
      if (zoneId is! int) continue;
      final crop = "${z['crop_name']}".toUpperCase();
      final cvAlerts = cvAlertsByZone[zoneId];
      if (cvAlerts == null) continue;

      // ── Harvest alert ──────────────────────────────────────────────────────
      final harvest = cvAlerts['harvest'];
      if (harvest != null && harvest['detected'] == true) {
        alerts.add(_Alert(
          zoneId: zoneId,
          crop: crop,
          type: AlertType.cv,
          metric: "CV · Harvest Ready",
          current: (harvest['count'] ?? 0).toDouble(),
          min: 0,
          max: 0,
          unit: " fruit(s)",
          icon: Icons.agriculture,
          customMessage: harvest['message'] ?? "Ripe fruits detected",
          timestamp: harvest['timestamp'],
        ));
      }

      // ── Disease alert ──────────────────────────────────────────────────────
      final disease = cvAlerts['disease'];
      if (disease != null && disease['detected'] == true) {
        alerts.add(_Alert(
          zoneId: zoneId,
          crop: crop,
          type: AlertType.cv,
          metric: "CV · Disease Detected",
          current: (disease['count'] ?? 0).toDouble(),
          min: 0,
          max: 0,
          unit: " area(s)",
          icon: Icons.coronavirus,
          customMessage: disease['message'] ?? "Disease detected on plants",
          timestamp: disease['timestamp'],
        ));
      }

      // ── Pest alert ─────────────────────────────────────────────────────────
      final pest = cvAlerts['pest'];
      if (pest != null && pest['detected'] == true) {
        final scenario = pest['scenario'] ?? '';
        final isUrgent = scenario == 'spray_high_risk' || scenario == 'spray_harmful';
        alerts.add(_Alert(
          zoneId: zoneId,
          crop: crop,
          type: isUrgent ? AlertType.cvUrgent : AlertType.cv,
          metric: "CV · Pest Alert",
          current: 0,
          min: 0,
          max: 0,
          unit: "",
          icon: Icons.pest_control,
          customMessage: pest['message'] ?? "Pests detected",
          timestamp: pest['timestamp'],
        ));
      }
    }
    return alerts;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: FirebaseDatabase.instance.ref("zones").onValue,
      builder: (context, AsyncSnapshot<DatabaseEvent> snap) {
        // FIX: Build both sensor alerts and CV alerts from the same live
        // snapshot. Previously, sensor alerts used the stale `zones` list
        // passed at widget construction while CV alerts used this stream,
        // causing them to reflect different moments in time.

        // Derive the set of zone IDs the current user is allowed to see,
        // so farmer zone filtering is still respected.
        final allowedIds = <int>{};
        for (final z in zones) {
          if (z is Map && z['zoneid'] is int) {
            allowedIds.add(z['zoneid'] as int);
          }
        }

        final freshZones = <dynamic>[];
        final cvAlertsByZone = <int, Map>{};

        if (snap.hasData && snap.data!.snapshot.value != null) {
          final rawZones = firebaseListFrom(snap.data!.snapshot.value);
          for (final z in rawZones) {
            if (z is! Map) continue;
            final zoneId = z['zoneid'];
            if (zoneId is! int) continue;
            // Apply farmer zone filter (for the owner, allowedIds contains
            // all zone IDs so no zone is skipped; for a farmer, only their
            // assigned zones pass through).
            if (allowedIds.isNotEmpty && !allowedIds.contains(zoneId)) continue;

            freshZones.add(z);
            final rawCvAlerts = z['cv_alerts'];
            if (rawCvAlerts is Map) {
              cvAlertsByZone[zoneId] = Map<String, dynamic>.from(rawCvAlerts);
            }
          }
        } else {
          // Stream not ready yet — fall back to the construction-time snapshot
          // so the page doesn't flash empty on first load.
          freshZones.addAll(zones);
        }

        final sensorAlerts = _buildSensorAlerts(freshZones);
        final cvAlerts = _buildCvAlerts(freshZones, cvAlertsByZone);
        final allAlerts = [...cvAlerts, ...sensorAlerts];

        if (allAlerts.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle_outline, size: 70, color: accentGreen),
                SizedBox(height: 16),
                Text("All zones are healthy!",
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: primaryGreen)),
                SizedBox(height: 8),
                Text("No sensors or CV models are out of range.",
                    style: TextStyle(color: Colors.grey)),
              ],
            ),
          );
        }

        return Column(
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              color: alertRed.withOpacity(0.08),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: alertRed),
                  const SizedBox(width: 10),
                  Text(
                    "${allAlerts.length} alert${allAlerts.length > 1 ? 's' : ''} require attention",
                    style: const TextStyle(
                        color: alertRed, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: allAlerts.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _AlertCard(alert: allAlerts[i]),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── Alert model ───────────────────────────────────────────────────────────────

enum AlertType { low, high, info, cv, cvUrgent }

class _Alert {
  final int zoneId;
  final String crop;
  final AlertType type;
  final String metric;
  final double current;
  final double min;
  final double max;
  final String unit;
  final IconData icon;
  final String? customMessage;
  final String? timestamp;

  _Alert({
    required this.zoneId,
    required this.crop,
    required this.type,
    required this.metric,
    required this.current,
    required this.min,
    required this.max,
    required this.unit,
    required this.icon,
    this.customMessage,
    this.timestamp,
  });

  Color get color {
    switch (type) {
      case AlertType.info:
        return Colors.blue.shade700;
      case AlertType.cv:
        return Colors.purple.shade600;
      case AlertType.cvUrgent:
        return alertRed;
      default:
        return alertRed;
    }
  }

  String get message {
    if (customMessage != null) return customMessage!;
    if (type == AlertType.low) {
      return "$metric is too low (${current.toStringAsFixed(1)}$unit). Minimum: ${min.toStringAsFixed(1)}$unit";
    }
    return "$metric is too high (${current.toStringAsFixed(1)}$unit). Maximum: ${max.toStringAsFixed(1)}$unit";
  }

  String get severity {
    switch (type) {
      case AlertType.info:
        return "INFO";
      case AlertType.low:
        return "LOW";
      case AlertType.high:
        return "HIGH";
      case AlertType.cv:
        return "CV";
      case AlertType.cvUrgent:
        return "URGENT";
    }
  }
}

class _AlertCard extends StatelessWidget {
  final _Alert alert;
  const _AlertCard({required this.alert});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: alert.color.withOpacity(0.12),
                  shape: BoxShape.circle),
              child: Icon(alert.icon, color: alert.color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        "Zone ${alert.zoneId} • ${alert.crop}",
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                            color: alert.color.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8)),
                        child: Text(
                          alert.severity,
                          style: TextStyle(
                              color: alert.color,
                              fontSize: 10,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(alert.metric,
                      style: TextStyle(
                          fontSize: 11,
                          color: alert.color,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(alert.message,
                      style: const TextStyle(
                          fontSize: 13, color: Colors.black87)),
                  if (alert.timestamp != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      _formatTimestamp(alert.timestamp!),
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                  ],
                  if (alert.type != AlertType.info &&
                      alert.type != AlertType.cv &&
                      alert.type != AlertType.cvUrgent) ...[
                    const SizedBox(height: 8),
                    _RangeBar(
                        current: alert.current,
                        min: alert.min,
                        max: alert.max,
                        color: alert.color),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTimestamp(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return "Detected: ${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    } catch (_) {
      return iso;
    }
  }
}

class _RangeBar extends StatelessWidget {
  final double current;
  final double min;
  final double max;
  final Color color;

  const _RangeBar(
      {required this.current,
      required this.min,
      required this.max,
      required this.color});

  @override
  Widget build(BuildContext context) {
    final range = max - min;
    final clamped = current.clamp(min - range * 0.5, max + range * 0.5);
    final total = (max - min) * 2;
    final fraction = total > 0
        ? ((clamped - (min - range * 0.5)) / total).clamp(0.0, 1.0)
        : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Stack(
            children: [
              Container(height: 6, color: Colors.grey.shade200),
              FractionallySizedBox(
                widthFactor: fraction,
                child: Container(height: 6, color: color),
              ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text("Min: $min",
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
            Text("Max: $max",
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
      ],
    );
  }
}

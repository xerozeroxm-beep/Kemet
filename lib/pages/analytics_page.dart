import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:fl_chart/fl_chart.dart';
import '../utils/firebase_parsing.dart';
import '../constants/app_colors.dart';

class AnalyticsPage extends StatelessWidget {
  final int zoneIndex;
  final String cropName;
  final Map prof;

  const AnalyticsPage({
    super.key,
    required this.zoneIndex,
    required this.cropName,
    required this.prof,
  });

  @override
  Widget build(BuildContext context) {
    final zoneRef = FirebaseDatabase.instance.ref('zones/$zoneIndex');
    return StreamBuilder<DatabaseEvent>(
      stream: zoneRef.onValue,
      builder: (context, snap) {
        final liveZone = firebaseMapFrom(snap.hasData ? snap.data!.snapshot.value : null);

        final liveProf = Map<String, dynamic>.from(
          liveZone['crop_profile'] is Map ? liveZone['crop_profile'] as Map : prof,
        );
        final liveCropName = (liveZone['crop_name'] ?? cropName).toString();

        final moisture = (liveProf['current_moisture'] ?? 0).toDouble();
        final minM = (liveProf['min_moisture'] ?? 0).toDouble();
        final maxM = (liveProf['max_moisture'] ?? 100).toDouble();

        final ec = (liveProf['current_ec'] ?? 0).toDouble();
        final minEc = (liveProf['min_ec'] ?? 0).toDouble();
        final maxEc = (liveProf['max_ec'] ?? 10).toDouble();

        final bool moistureOk = moisture >= minM && moisture <= maxM;
        final bool ecOk = ec >= minEc && ec <= maxEc;

        return Scaffold(
          appBar: AppBar(
            title: Text(
              "${liveCropName.toUpperCase()} — Analytics",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            backgroundColor: primaryGreen,
            foregroundColor: Colors.white,
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Status summary ──────────────────────────────────────
                _SectionHeader(
                    icon: Icons.monitor_heart_outlined,
                    title: "Zone Status — Zone ${zoneIndex + 1}"),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _StatusChip(
                        label: "Moisture",
                        ok: moistureOk,
                        value: "$moisture%"),
                    const SizedBox(width: 10),
                    _StatusChip(
                        label: "EC Level", ok: ecOk, value: "$ec"),
                  ],
                ),
                const SizedBox(height: 24),

                // ── Moisture gauge ──────────────────────────────────────
                _SectionHeader(
                    icon: Icons.water_drop, title: "Soil Moisture"),
                const SizedBox(height: 12),
                _GaugeCard(
                  label: "Current Moisture",
                  current: moisture,
                  min: minM,
                  max: maxM,
                  unit: "%",
                  color: moistureOk ? accentGreen : alertRed,
                ),
                const SizedBox(height: 24),

                // ── EC gauge ────────────────────────────────────────────
                _SectionHeader(icon: Icons.bolt, title: "EC Level"),
                const SizedBox(height: 12),
                _GaugeCard(
                  label: "Current EC",
                  current: ec,
                  min: minEc,
                  max: maxEc,
                  unit: " mS/cm",
                  color: ecOk ? accentGreen : alertRed,
                ),
                const SizedBox(height: 24),

                // ── Crop profile bar chart ──────────────────────────────
                _SectionHeader(
                    icon: Icons.bar_chart,
                    title: "Crop Profile Ranges"),
                const SizedBox(height: 12),
                _CropProfileChart(prof: liveProf),
                const SizedBox(height: 24),

                // ── Quick stats ─────────────────────────────────────────
                _SectionHeader(
                    icon: Icons.info_outline, title: "Zone Profile"),
                const SizedBox(height: 10),
                _ProfileGrid(prof: liveProf),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  const _SectionHeader({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: primaryGreen, size: 18),
        const SizedBox(width: 8),
        Text(title,
            style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
                color: primaryGreen)),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final bool ok;
  final String value;
  const _StatusChip(
      {required this.label, required this.ok, required this.value});

  @override
  Widget build(BuildContext context) {
    final color = ok ? accentGreen : alertRed;
    return Expanded(
      child: Container(
        padding:
            const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withOpacity(0.4))),
        child: Column(
          children: [
            Icon(ok ? Icons.check_circle : Icons.warning_rounded,
                color: color, size: 22),
            const SizedBox(height: 4),
            Text(label,
                style: const TextStyle(
                    fontSize: 12, color: Colors.black54)),
            Text(value,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: color)),
          ],
        ),
      ),
    );
  }
}

class _GaugeCard extends StatelessWidget {
  final String label;
  final double current;
  final double min;
  final double max;
  final String unit;
  final Color color;

  const _GaugeCard({
    required this.label,
    required this.current,
    required this.min,
    required this.max,
    required this.unit,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    // Extend range for visual context
    final lower = (min - (max - min) * 0.3).clamp(0.0, double.infinity);
    final upper = max + (max - min) * 0.3;
    final total = upper - lower;
    final fraction =
        total > 0 ? ((current - lower) / total).clamp(0.0, 1.0) : 0.0;

    return Card(
      elevation: 2,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w500, fontSize: 13)),
                Text(
                  "${current.toStringAsFixed(1)}$unit",
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 22,
                      color: color),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Bar
            Stack(
              children: [
                // Background track
                Container(
                  height: 14,
                  decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(7)),
                ),
                // Ideal range highlight
                FractionallySizedBox(
                  widthFactor: total > 0
                      ? ((max - min) / total).clamp(0.0, 1.0)
                      : 0,
                  alignment: Alignment.centerLeft,
                  child: FractionalTranslation(
                    translation: Offset(
                        total > 0
                            ? ((min - lower) / (max - min)).clamp(
                                0.0, 1.0)
                            : 0,
                        0),
                    child: Container(
                      height: 14,
                      decoration: BoxDecoration(
                          color: accentGreen.withOpacity(0.25),
                          borderRadius: BorderRadius.circular(7)),
                    ),
                  ),
                ),
                // Current marker
                FractionallySizedBox(
                  widthFactor: fraction,
                  child: Container(
                    height: 14,
                    decoration: BoxDecoration(
                        color: color.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(7)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("Min: ${min.toStringAsFixed(1)}$unit",
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey)),
                Text("Ideal range",
                    style: TextStyle(
                        fontSize: 11,
                        color: accentGreen,
                        fontWeight: FontWeight.w500)),
                Text("Max: ${max.toStringAsFixed(1)}$unit",
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CropProfileChart extends StatelessWidget {
  final Map prof;
  const _CropProfileChart({required this.prof});

  @override
  Widget build(BuildContext context) {
    final groups = [
      BarChartGroupData(x: 0, barRods: [
        BarChartRodData(
          toY: (prof['max_moisture'] ?? 0).toDouble(),
          color: accentGreen,
          width: 22,
          borderRadius: BorderRadius.circular(6),
          rodStackItems: [
            BarChartRodStackItem(
                0,
                (prof['min_moisture'] ?? 0).toDouble(),
                accentGreen.withOpacity(0.3)),
          ],
        ),
      ]),
      BarChartGroupData(x: 1, barRods: [
        BarChartRodData(
          toY: (prof['max_ec'] ?? 0).toDouble() * 20, // scale EC for visibility
          color: Colors.blueAccent,
          width: 22,
          borderRadius: BorderRadius.circular(6),
          rodStackItems: [
            BarChartRodStackItem(
                0,
                (prof['min_ec'] ?? 0).toDouble() * 20,
                Colors.blueAccent.withOpacity(0.3)),
          ],
        ),
      ]),
    ];

    return Card(
      elevation: 2,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            SizedBox(
              height: 180,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: 110,
                  barGroups: groups,
                  gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      horizontalInterval: 20),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 30,
                          interval: 20,
                          getTitlesWidget: (v, _) => Text(
                                "${v.toInt()}",
                                style: const TextStyle(fontSize: 10),
                              )),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (v, _) {
                          final labels = ["Moisture %", "EC ×20"];
                          return Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              v.toInt() < labels.length
                                  ? labels[v.toInt()]
                                  : '',
                              style: const TextStyle(fontSize: 10),
                            ),
                          );
                        },
                      ),
                    ),
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: false),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _LegendDot(color: accentGreen, label: "Moisture range"),
                const SizedBox(width: 16),
                _LegendDot(
                    color: Colors.blueAccent, label: "EC range (×20)"),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
            width: 10,
            height: 10,
            decoration:
                BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}

class _ProfileGrid extends StatelessWidget {
  final Map prof;
  const _ProfileGrid({required this.prof});

  @override
  Widget build(BuildContext context) {
    final items = [
      ("Min Moisture", "${prof['min_moisture'] ?? '--'}%", Icons.water_drop),
      ("Max Moisture", "${prof['max_moisture'] ?? '--'}%", Icons.water_drop),
      ("Min EC", "${prof['min_ec'] ?? '--'}", Icons.bolt),
      ("Max EC", "${prof['max_ec'] ?? '--'}", Icons.bolt),
      ("Ceiling",
          "${prof['ceiling_state'] ?? '--'}",
          Icons.roofing),
      ("Weather",
          "${prof['weather_api'] ?? '--'}% rain",
          Icons.cloud),
    ];

    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: 1.2,
      children: items
          .map((item) => Card(
                elevation: 1,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(item.$3, size: 18, color: primaryGreen),
                    const SizedBox(height: 4),
                    Text(item.$1,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 9, color: Colors.grey)),
                    Text(item.$2,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13)),
                  ],
                ),
              ))
          .toList(),
    );
  }
}

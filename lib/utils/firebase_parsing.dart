List<dynamic> firebaseListFrom(dynamic raw) {
  if (raw is List) {
    return List<dynamic>.from(raw);
  }
  if (raw is Map) {
    final entries = raw.entries.toList()
      ..sort((a, b) => _compareFirebaseKeys(a.key, b.key));
    return entries.map((e) => e.value).toList();
  }
  return <dynamic>[];
}

Map<String, dynamic> firebaseMapFrom(dynamic raw) {
  if (raw is Map) {
    return Map<String, dynamic>.from(raw as Map);
  }
  return <String, dynamic>{};
}

List<int> firebaseIntListFrom(dynamic raw) {
  final list = firebaseListFrom(raw);
  return list
      .map((value) {
        if (value is int) return value;
        if (value is num) return value.toInt();
        return int.tryParse(value.toString());
      })
      .whereType<int>()
      .toList();
}

int _compareFirebaseKeys(dynamic a, dynamic b) {
  final ai = int.tryParse(a.toString());
  final bi = int.tryParse(b.toString());
  if (ai != null && bi != null) return ai.compareTo(bi);
  return a.toString().compareTo(b.toString());
}

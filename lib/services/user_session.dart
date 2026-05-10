/// Singleton that holds the current user's profile after login.
class UserSession {
  UserSession._();
  static final UserSession instance = UserSession._();

  String uid = '';
  String name = '';
  String email = '';
  String role = 'farmer'; // 'owner' | 'farmer'

  /// Zone indices (0-based) this farmer is allowed to see.
  /// For owners this list is empty and is ignored — owners see all zones.
  List<int> assignedZones = [];

  bool get isOwner => role == 'owner';

  /// Returns true if this user can access the zone at [zoneIndex] (0-based).
  bool canAccessZone(int zoneIndex) {
    if (isOwner) return true;
    return assignedZones.contains(zoneIndex);
  }

  void clear() {
    uid = '';
    name = '';
    email = '';
    role = 'farmer';
    assignedZones = [];
  }
}

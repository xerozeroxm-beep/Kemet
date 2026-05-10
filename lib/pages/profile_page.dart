import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../constants/app_colors.dart';
import '../services/user_session.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _newPass = TextEditingController();
  final _confirmNewPass = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _editingName = false;
  bool _changingPass = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl.text = UserSession.instance.name;
  }

  Future<void> _saveName() async {
    final newName = _nameCtrl.text.trim();
    if (newName.isEmpty) return;
    await FirebaseDatabase.instance
        .ref("users/${UserSession.instance.uid}/name")
        .set(newName);
    UserSession.instance.name = newName;
    setState(() => _editingName = false);
    _showSnack("Name updated successfully");
  }

  Future<void> _changePassword() async {
    if (_newPass.text != _confirmNewPass.text) {
      _showSnack("Passwords do not match", error: true);
      return;
    }
    if (_newPass.text.length < 6) {
      _showSnack("Password must be at least 6 characters", error: true);
      return;
    }
    try {
      await FirebaseAuth.instance.currentUser!
          .updatePassword(_newPass.text);
      _newPass.clear();
      _confirmNewPass.clear();
      setState(() => _changingPass = false);
      _showSnack("Password changed successfully");
    } catch (e) {
      _showSnack(e.toString(), error: true);
    }
  }

  void _showSnack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? alertRed : accentGreen,
    ));
  }

  @override
  void dispose() {
    _newPass.dispose();
    _confirmNewPass.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = UserSession.instance;
    final isOwner = session.isOwner;

    return Scaffold(
      appBar: AppBar(
        title: const Text("My Profile",
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: primaryGreen,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // ── Avatar ──────────────────────────────────────────────
            const SizedBox(height: 10),
            CircleAvatar(
              radius: 48,
              backgroundColor: primaryGreen,
              child: Text(
                session.name.isNotEmpty
                    ? session.name[0].toUpperCase()
                    : '?',
                style: const TextStyle(
                    fontSize: 38,
                    color: Colors.white,
                    fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              session.name,
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                  color: isOwner
                      ? Colors.amber.shade100
                      : lightGreen,
                  borderRadius: BorderRadius.circular(20)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isOwner ? Icons.manage_accounts : Icons.agriculture,
                    size: 14,
                    color: isOwner
                        ? Colors.amber.shade800
                        : primaryGreen,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isOwner ? "Owner" : "Farmer",
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: isOwner
                            ? Colors.amber.shade800
                            : primaryGreen),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),

            // ── Info card ────────────────────────────────────────────
            Card(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Account Details",
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: primaryGreen)),
                    const Divider(),

                    // Name row
                    _editingName
                        ? Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _nameCtrl,
                                  decoration: const InputDecoration(
                                    labelText: "Full Name",
                                    prefixIcon: Icon(Icons.person,
                                        color: primaryGreen),
                                  ),
                                ),
                              ),
                              IconButton(
                                  onPressed: _saveName,
                                  icon: const Icon(Icons.check,
                                      color: accentGreen)),
                              IconButton(
                                  onPressed: () => setState(
                                      () => _editingName = false),
                                  icon: const Icon(Icons.close,
                                      color: Colors.grey)),
                            ],
                          )
                        : ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.person,
                                color: primaryGreen),
                            title: const Text("Full Name"),
                            subtitle: Text(session.name),
                            trailing: IconButton(
                              icon: const Icon(Icons.edit,
                                  size: 18, color: Colors.grey),
                              onPressed: () =>
                                  setState(() => _editingName = true),
                            ),
                          ),

                    const Divider(),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading:
                          const Icon(Icons.email, color: primaryGreen),
                      title: const Text("Email"),
                      subtitle: Text(session.email),
                    ),
                    const Divider(),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                          isOwner
                              ? Icons.manage_accounts
                              : Icons.agriculture,
                          color: primaryGreen),
                      title: const Text("Role"),
                      subtitle: Text(isOwner ? "Owner" : "Farmer"),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── Change password ──────────────────────────────────────
            Card(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text("Security",
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: primaryGreen)),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () => setState(
                              () => _changingPass = !_changingPass),
                          icon: Icon(
                              _changingPass ? Icons.close : Icons.lock,
                              size: 16),
                          label: Text(
                              _changingPass ? "Cancel" : "Change Password"),
                          style: TextButton.styleFrom(
                              foregroundColor: primaryGreen),
                        ),
                      ],
                    ),
                    if (_changingPass) ...[
                      const Divider(),
                      _passField(
                          _newPass, "New Password", _obscureNew, () {
                        setState(() => _obscureNew = !_obscureNew);
                      }),
                      const SizedBox(height: 10),
                      _passField(
                          _confirmNewPass,
                          "Confirm New Password",
                          _obscureConfirm, () {
                        setState(
                            () => _obscureConfirm = !_obscureConfirm);
                      }),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: primaryGreen),
                          onPressed: _changePassword,
                          child: const Text("Update Password",
                              style: TextStyle(color: Colors.white)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _passField(TextEditingController ctrl, String hint, bool obscure,
      VoidCallback toggle) {
    return TextField(
      controller: ctrl,
      obscureText: obscure,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon:
            const Icon(Icons.lock_outline, color: primaryGreen),
        suffixIcon: IconButton(
          icon:
              Icon(obscure ? Icons.visibility_off : Icons.visibility),
          onPressed: toggle,
        ),
        border:
            OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

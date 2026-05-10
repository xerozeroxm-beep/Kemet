import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../utils/firebase_parsing.dart';
import '../constants/app_colors.dart';
import '../services/user_session.dart';
import 'zones_dashboard.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _confirmPass = TextEditingController();
  final _name = TextEditingController();
  bool _isLogin = true;
  bool _obscure = true;
  bool _obscureConfirm = true;
  bool _loading = false;

  // All new registrations are ALWAYS farmers. Status = 'pending' until owner approves.
  Future<void> _register() async {
    if (_pass.text != _confirmPass.text) {
      _showMessage("Passwords do not match");
      return;
    }
    if (_name.text.trim().isEmpty) {
      _showMessage("Please enter your full name");
      return;
    }
    setState(() => _loading = true);
    try {
      final userCred =
          await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _email.text.trim(),
        password: _pass.text.trim(),
      );
      final uid = userCred.user!.uid;
      final now = DateTime.now().toIso8601String();

      // Write user record — role is always 'farmer', status 'pending'
      await FirebaseDatabase.instance.ref("users/$uid").set({
        "name": _name.text.trim(),
        "email": _email.text.trim(),
        "role": "farmer",
        "status": "pending",
        "assigned_zones": [],
        "registered_at": now,
      });

      // Write a notification entry for the owner
      await FirebaseDatabase.instance
          .ref("owner_notifications/$uid")
          .set({
        "uid": uid,
        "name": _name.text.trim(),
        "email": _email.text.trim(),
        "requested_at": now,
        "status": "pending",
      });

      // Sign out immediately
      await FirebaseAuth.instance.signOut();

      if (mounted) _showPendingDialog();
    } catch (e) {
      _showMessage(e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showPendingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [
          Icon(Icons.hourglass_top, color: primaryGreen),
          SizedBox(width: 10),
          Text("Registration Sent"),
        ]),
        content: const Text(
          "Your registration request has been sent to the owner for approval.\n\n"
          "You will be able to log in once the owner approves your account and assigns your zones.",
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: primaryGreen,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            onPressed: () {
              Navigator.pop(context);
              setState(() => _isLogin = true);
            },
            child: const Text("OK", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _login() async {
    setState(() => _loading = true);
    try {
      final userCred =
          await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _email.text.trim(),
        password: _pass.text.trim(),
      );

      final snap = await FirebaseDatabase.instance
          .ref("users/${userCred.user!.uid}")
          .get();

      if (!snap.exists) {
        await FirebaseAuth.instance.signOut();
        _showMessage("Account data not found. Please contact the owner.");
        return;
      }

      final data = firebaseMapFrom(snap.value);
      final status = data['status'] ?? 'approved'; // legacy accounts default approved
      final role = data['role'] ?? 'farmer';

      if (status == 'pending') {
        await FirebaseAuth.instance.signOut();
        _showMessage("Your account is awaiting owner approval. Please try again later.");
        return;
      }

      if (status == 'rejected') {
        await FirebaseAuth.instance.signOut();
        _showMessage("Your registration was rejected by the owner.");
        return;
      }

      UserSession.instance.uid = userCred.user!.uid;
      UserSession.instance.name = data['name'] ?? '';
      UserSession.instance.email = data['email'] ?? '';
      UserSession.instance.role = role;

      final rawZones = data['assigned_zones'];
      UserSession.instance.assignedZones =
          firebaseIntListFrom(rawZones);

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const ZonesDashboard()),
        );
      }
    } catch (e) {
      _showMessage(e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    if (_isLogin) {
      await _login();
    } else {
      await _register();
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(30),
          child: Column(
            children: [
              const Icon(Icons.eco_rounded, size: 90, color: primaryGreen),
              const Text(
                "KEMET GREENHOUSE",
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: primaryGreen),
              ),
              const SizedBox(height: 8),
              Text(
                _isLogin ? "Welcome back" : "Create your account",
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 28),

              if (!_isLogin) _buildField(_name, "Full Name", Icons.person),
              _buildField(_email, "Email", Icons.email,
                  keyboardType: TextInputType.emailAddress),
              _buildField(_pass, "Password", Icons.lock,
                  obscure: _obscure,
                  toggle: () => setState(() => _obscure = !_obscure)),
              if (!_isLogin)
                _buildField(
                  _confirmPass,
                  "Confirm Password",
                  Icons.lock_outline,
                  obscure: _obscureConfirm,
                  toggle: () =>
                      setState(() => _obscureConfirm = !_obscureConfirm),
                ),

              if (!_isLogin) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: primaryGreen.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: primaryGreen.withOpacity(0.3), width: 1),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.agriculture, color: primaryGreen, size: 20),
                      SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Farmer Account",
                                style: TextStyle(
                                    color: primaryGreen,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13)),
                            SizedBox(height: 2),
                            Text(
                              "New accounts are registered as Farmers. "
                              "The owner will review your request and assign your zones.",
                              style: TextStyle(color: Colors.grey, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryGreen,
                  minimumSize: const Size(double.infinity, 55),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15)),
                ),
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Text(
                        _isLogin ? "LOGIN" : "REGISTER",
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold),
                      ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => setState(() => _isLogin = !_isLogin),
                child: Text(
                  _isLogin
                      ? "Don't have an account? Register"
                      : "Already have an account? Login",
                  style: const TextStyle(color: primaryGreen),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(
    TextEditingController controller,
    String hint,
    IconData icon, {
    bool obscure = false,
    VoidCallback? toggle,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          prefixIcon: Icon(icon, color: primaryGreen),
          suffixIcon: toggle != null
              ? IconButton(
                  icon: Icon(
                      obscure ? Icons.visibility_off : Icons.visibility),
                  onPressed: toggle,
                )
              : null,
          hintText: hint,
          border:
              OutlineInputBorder(borderRadius: BorderRadius.circular(15)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(15),
              borderSide:
                  const BorderSide(color: primaryGreen, width: 2)),
        ),
      ),
    );
  }
}

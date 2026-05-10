import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../utils/firebase_parsing.dart';
import '../constants/app_colors.dart';
import '../services/user_session.dart';
import 'auth_screen.dart';
import 'zones_dashboard.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _anim;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200));
    _fadeAnim = CurvedAnimation(parent: _anim, curve: Curves.easeIn);
    _anim.forward();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    await Future.delayed(const Duration(seconds: 2));
    final user = FirebaseAuth.instance.currentUser;
    if (!mounted) return;

    if (user == null) {
      _go(const AuthScreen());
      return;
    }

    final snap =
        await FirebaseDatabase.instance.ref("users/${user.uid}").get();

    // If the user record is missing entirely, the account is broken — sign out.
    if (!snap.exists) {
      await FirebaseAuth.instance.signOut();
      if (mounted) _go(const AuthScreen());
      return;
    }

    final data = firebaseMapFrom(snap.value);
    final status = data['status'] ?? 'approved';

    // If still pending or rejected, force back to auth screen
    if (status == 'pending' || status == 'rejected') {
      await FirebaseAuth.instance.signOut();
      if (mounted) _go(const AuthScreen());
      return;
    }

    UserSession.instance.uid = user.uid;
    UserSession.instance.name = data['name'] ?? '';
    UserSession.instance.email = data['email'] ?? '';
    UserSession.instance.role = data['role'] ?? 'farmer';

    final rawZones = data['assigned_zones'];
    UserSession.instance.assignedZones =
        firebaseIntListFrom(rawZones);

    if (mounted) _go(const ZonesDashboard());
  }

  void _go(Widget screen) {
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => screen));
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: primaryGreen,
      body: FadeTransition(
        opacity: _fadeAnim,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.eco_rounded,
                    size: 90, color: Colors.white),
              ),
              const SizedBox(height: 24),
              const Text(
                'KEMET',
                style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 6),
              ),
              const Text(
                'GREENHOUSE',
                style: TextStyle(
                    fontSize: 16,
                    color: Colors.white70,
                    letterSpacing: 4),
              ),
              const SizedBox(height: 60),
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '../core.dart';

/// بوابة كلمة السر — تُطلب عند الدخول إذا كانت مفعّلة
class SecurityGate extends StatefulWidget {
  final Widget child;
  const SecurityGate({super.key, required this.child});

  @override
  State<SecurityGate> createState() => _SecurityGateState();
}

class _SecurityGateState extends State<SecurityGate> {
  bool _ok = false;
  final _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ok = !Prefs.lockEnabled || Prefs.password.isEmpty;
  }

  void _try() {
    if (_ctrl.text == Prefs.password) {
      setState(() => _ok = true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('كلمة السر غير صحيحة', style: TextStyle(fontSize: 13))));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ok) return widget.child;
    return Scaffold(
      backgroundColor: AppColors.primary,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🔐', style: TextStyle(fontSize: 52)),
            const SizedBox(height: 18),
            const Text('كلمة السر', style: TextStyle(color: Colors.white, fontSize: 20)),
            const SizedBox(height: 18),
            SizedBox(
              width: 250,
              child: TextField(
                controller: _ctrl,
                obscureText: true,
                autofocus: true,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 18),
                onSubmitted: (_) => _try(),
                decoration: const InputDecoration(
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white54)),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white)),
                ),
              ),
            ),
            const SizedBox(height: 22),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: AppColors.primary),
              onPressed: _try,
              child: const Text('دخول'),
            ),
          ],
        ),
      ),
    );
  }
}

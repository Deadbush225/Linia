import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../sync_service.dart';

class AuthGate extends StatelessWidget {
  final Widget child;
  const AuthGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.data == null) {
          return const _EmailPasswordAuthScreen();
        }
        return child;
      },
    );
  }
}

class _EmailPasswordAuthScreen extends StatefulWidget {
  const _EmailPasswordAuthScreen();

  @override
  State<_EmailPasswordAuthScreen> createState() => _EmailPasswordAuthScreenState();
}

class _EmailPasswordAuthScreenState extends State<_EmailPasswordAuthScreen> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _registerMode = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailCtrl.text.trim();
    final pass = _passCtrl.text;
    if (email.isEmpty || pass.isEmpty) {
      setState(() => _error = 'Email and password are required');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    String? err;
    if (_registerMode) {
      err = await SyncService.register(
        baseUrl: '',
        email: email,
        password: pass,
        firstName: '',
        lastName: '',
      );
    } else {
      err = await SyncService.login(email: email, password: pass);
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _registerMode ? 'Create Account' : 'Sign In',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Sign in is required before cloud sync can read or write your tasks.',
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password'),
                    onSubmitted: (_) => _submit(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_registerMode ? 'Create Account' : 'Sign In'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _registerMode = !_registerMode;
                                _error = null;
                              }),
                      child: Text(
                        _registerMode
                            ? 'Already have an account? Sign in'
                            : 'No account yet? Create one',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

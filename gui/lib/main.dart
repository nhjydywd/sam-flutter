import 'package:flutter/material.dart';

void main() {
  runApp(const SamFlutterApp());
}

class SamFlutterApp extends StatelessWidget {
  const SamFlutterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sam-flutter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const _HomePage(),
    );
  }
}

class _HomePage extends StatelessWidget {
  const _HomePage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('sam-flutter')),
      body: const Center(
        child: Text('Hello, world'),
      ),
    );
  }
}


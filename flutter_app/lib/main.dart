import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'screens/root_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ja_JP');
  runApp(const ShiftAgentApp());
}

class ShiftAgentApp extends StatelessWidget {
  const ShiftAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AI Shift Agent',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const RootShell(),
    );
  }
}

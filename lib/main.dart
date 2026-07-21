import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import 'theme/app_theme.dart';
import 'android_app.dart';

/// ESW 主入口 — 自动适配平台
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EswApp());
}

class EswApp extends StatelessWidget {
  const EswApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Android 使用移动端 UI
    if (Platform.isAndroid) {
      return MaterialApp(
        title: 'ESW',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppTheme.primaryBlue,
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        ),
        home: const AndroidEswApp(),
      );
    }
    return MaterialApp(
      title: 'ESW',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppTheme.primaryBlue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: 'Microsoft YaHei',
      ),
      home: const Center(
        child: Text('Windows 版本请使用备份的 main_windows.dart.bak', style: TextStyle(fontSize: 16)),
      ),
    );
  }
}

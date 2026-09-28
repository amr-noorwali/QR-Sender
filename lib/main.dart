import 'package:flutter/material.dart';
import 'package:qr_sender/screens/home_screen.dart';

void main() => runApp(const QrVideoApp());

class QrVideoApp extends StatelessWidget {
  const QrVideoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'نقل فيديو بـ QR',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff4355d8)),
        useMaterial3: true,
      ),
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: HomeScreen(),
      ),
    );
  }
}

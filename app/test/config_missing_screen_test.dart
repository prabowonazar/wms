import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warehouse_mobile/features/bootstrap/config_missing_screen.dart';

void main() {
  testWidgets('menampilkan semua kunci yang hilang', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ConfigMissingScreen(
          missingKeys: ['FB_API_KEY', 'GOOGLE_SERVER_CLIENT_ID'],
        ),
      ),
    );

    expect(find.text('Konfigurasi Firebase belum lengkap'), findsOneWidget);
    expect(find.text('- FB_API_KEY'), findsOneWidget);
    expect(find.text('- GOOGLE_SERVER_CLIENT_ID'), findsOneWidget);
    expect(find.textContaining('docs/runbook-vs0.md'), findsOneWidget);
  });
}

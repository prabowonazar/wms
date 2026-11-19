import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warehouse_mobile/features/bootstrap/bootstrap_failure_screen.dart';

void main() {
  testWidgets('menampilkan pesan error lengkap, bukan hanya tipe', (
    tester,
  ) async {
    final error = StateError(
      'SqfliteDatabaseException: file is not a database (code 26)',
    );

    await tester.pumpWidget(
      MaterialApp(home: BootstrapFailureScreen(error: error)),
    );

    expect(find.byKey(const Key('bootstrap-error-detail')), findsOneWidget);
    final detail = tester.widget<SelectableText>(
      find.byKey(const Key('bootstrap-error-detail')),
    );
    expect(
      detail.data,
      'SqfliteDatabaseException: file is not a database (code 26)',
    );
    expect(find.text('Salin detail'), findsOneWidget);
  });
}

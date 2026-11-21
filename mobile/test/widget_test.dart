import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yardim_agi/features/auth/presentation/screens/login_screen.dart';

void main() {
  testWidgets('giriş ekranı temel alanları gösterir', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));

    expect(find.text('YardımAğı'), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(find.text('E-posta'), findsOneWidget);
    expect(find.text('Şifre'), findsOneWidget);
    expect(find.text('Giriş Yap'), findsOneWidget);
  });
}

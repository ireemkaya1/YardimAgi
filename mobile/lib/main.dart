import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'routing/app_router.dart';

void main() {
  runApp(const ProviderScope(child: YardimAgiApp()));
}

class YardimAgiApp                                                                 extends StatelessWidget {
  const YardimAgiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'YardımAğı',
      theme: AppTheme.lightTheme,
      routerConfig: appRouter,
    );
  }
}

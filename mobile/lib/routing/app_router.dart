import 'package:go_router/go_router.dart';

import '../features/auth/presentation/screens/login_screen.dart';

abstract final class AppRouteNames {
  static const login = 'login';
}

final GoRouter appRouter = GoRouter(
  initialLocation: '/login',
  routes: [
    GoRoute(
      path: '/login',
      name: AppRouteNames.login,
      builder: (context, state) => const LoginScreen(),
    ),
  ],
);

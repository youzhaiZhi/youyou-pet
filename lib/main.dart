import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/controller.dart';
import 'ui/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const PetApp());
}

class PetApp extends StatefulWidget {
  const PetApp({super.key});

  @override
  State<PetApp> createState() => _PetAppState();
}

class _PetAppState extends State<PetApp> with WidgetsBindingObserver {
  final PetController _controller = PetController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回前台时重新确认高刷与音频轨，部分 ROM 会在这两处偷偷降级。
    if (state == AppLifecycleState.resumed) {
      _controller.bridge.requestHighRefreshRate();
      _controller.bridge.keepScreenOn(true);
    } else if (state == AppLifecycleState.paused) {
      _controller.stopAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '悠悠',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        canvasColor: kBg,
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        colorScheme: const ColorScheme.dark(
          surface: kBg,
          primary: Colors.white,
          secondary: kGray,
        ),
        textTheme: Typography.whiteMountainView,
      ),
      builder: (context, child) {
        // 锁定字体缩放，避免系统字号把极简排版撑破。
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: const TextScaler.linear(1.0),
            viewPadding: mq.viewPadding,
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: HomePage(controller: _controller),
    );
  }
}
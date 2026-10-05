import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/db_init.dart';
import 'core/desktop.dart';
import 'core/desktop_net.dart';
import 'core/windows_firewall.dart';
import 'core/media_paths.dart';
import 'core/database.dart';
import 'core/sfx.dart';
import 'core/theme.dart';
import 'data/providers.dart';
import 'data/repository.dart';
import 'data/sync/firebase_auth_service.dart';
import 'data/sync/sync_engine.dart';
import 'services/floating_pos_overlay.dart';
import 'services/floating_pos_service.dart';
import 'ui/splash.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initDbForPlatform();
  // (دفعة 52) سطح المكتب: بروكسي تلقائي + مهلات + تشخيص أخطاء TLS دقيق
  // لكل عملاء HTTP في التطبيق، وتسجيل قاعدة جدار حماية ويندوز بلا انتظار.
  if (isDesktop) {
    HttpOverrides.global = DesktopHttpOverrides();
    unawaited(WindowsFirewall.ensureRegistered());
  }
  await initializeDateFormatting('ar');
  await initializeDateFormatting('en');
  // جذر documents لمسارات الوسائط النسبية (chat_media/...).
  try {
    await MediaPaths.ensureDocsDir();
  } catch (_) {}

  // التقاط أي خطأ غير مُعالج في إطار الـ UI بدل تعليق الشاشة بيضاء.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint(
      'FlutterError: ${details.exceptionAsString()}\n${details.stack}',
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught error: $error\n$stack');
    return true;
  };

  // Repo واحد ومُهيّأ تُستخدمه كل شاشات التطبيق عبر Riverpod.
  // كل خطوة بمهلة قصوى حتى لا يعلق الإقلاع للأبد في حالة فساد قاعدة البيانات أو انسداد المقبس.
  final repo = Repo();
  try {
    await repo.initSyncInfra().timeout(const Duration(seconds: 8));
  } catch (e) {
    debugPrint('initSyncInfra timeout/error: $e');
  }
  // (المرحلة 2) هوية الجهاز المجهولة — **قبل** أي اتصال بـ RTDB.
  // بلا نافذة ولا إذن: يُنشئ حساباً مجهولاً (أو يستعيده من التخزين) فيصبح
  // لكل طلب ?auth=<idToken> صالح، فتعمل قواعد الأمان بـ auth.uid.
  // الفشل هنا لا يُسقط الإقلاع — يُستأنف عند أول طلب سحابي.
  try {
    await FirebaseAuthRest.initSilentAuth(repo)
        .timeout(const Duration(seconds: 8));
  } catch (e) {
    debugPrint('initSilentAuth timeout/error: $e');
  }
  SyncEngine engine;
  try {
    engine = SyncEngine(
      repo: repo,
      dbProvider: () => AppDatabase.instance.database,
    );
    await engine.start().timeout(const Duration(seconds: 6));
  } catch (e) {
    debugPrint('engine.start timeout/error: $e');
    engine = SyncEngine(
      repo: repo,
      dbProvider: () => AppDatabase.instance.database,
    );
  }

  var themeMode = ThemeMode.system;
  var hideBalances = false;
  Map<String, String> initialSettings = const {};
  try {
    initialSettings = await repo.settings().timeout(const Duration(seconds: 4));
    themeMode = switch (initialSettings['theme']) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    hideBalances = initialSettings['hideBalances'] == '1';
    Sfx.applySettings(
      sound: (initialSettings['sfxSound'] ?? '1') == '1',
      haptic: (initialSettings['sfxHaptic'] ?? '1') == '1',
      mute: (initialSettings['sfxMute'] ?? '0') == '1',
    );
  } catch (e) {
    debugPrint('initial settings failed: $e');
  }

  runApp(
    ProviderScope(
      overrides: [
        repoProvider.overrideWithValue(repo),
        syncEngineProvider.overrideWithValue(engine),
        themeModeProvider.overrideWith((ref) => themeMode),
        hideBalancesProvider.overrideWith((ref) => hideBalances),
      ],
      child: const NexoraApp(),
    ),
  );

  // الزر العائم للاستعلام والبيع السريع (أندرويد فقط): يربط مستمع الرسائل
  // بالمستودع ثم يعيد إظهار الفقاعة إن كان المستخدم قد فعّلها على الجهاز.
  unawaited(_initFloatingPos(repo));
}

/// تهيئة الزر العائم — لا تُسقط الإقلاع إن فشلت (جهاز بلا صلاحية/غير مدعوم).
Future<void> _initFloatingPos(Repo repo) async {
  if (!FloatingPosService.supported) return;
  try {
    await FloatingPosService.instance.bind(repo);
    await FloatingPosService.instance.restore();
  } catch (e) {
    debugPrint('floating pos init: $e');
  }
}

/// نقطة دخول محرك النافذة العائمة (الفقاعة + بطاقة البيع السريع).
///
/// يجب أن تبقى في مكتبة الجذر (main.dart) ليجدها `DartEntrypoint` الأصلي
/// بالاسم "overlayMain". المحرك الذي يُشغّلها **لا تُسجَّل فيه إضافات
/// فلاتر**، لذا الواجهة هنا خفيفة وصرفة: كل البيانات تمرّ عبر رسائل JSON
/// إلى التطبيق الأم الذي يقرأ SQLite ويكتبها.
@pragma('vm:entry-point')
void overlayMain() => runQuickPosOverlay();

class NexoraApp extends ConsumerWidget {
  const NexoraApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'مدير الحسابات',
      debugShowCheckedModeBanner: false,
      // سطح المكتب: تمرير طبيعي بعجلة الفأرة وبالسحب بالماوس معاً
      // في كل القوائم والصفوف الأفقية.
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.stylus,
          PointerDeviceKind.trackpad,
        },
      ),
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        Widget w = Directionality(
          textDirection: TextDirection.rtl,
          child: child ?? const SizedBox.shrink(),
        );
        // سطح المكتب/الشاشات الكبيرة: تكبير الخط الأساسي ~15% لراحة
        // العين في الجداول المالية وبنود الفواتير وحقول الإدخال.
        final mq = MediaQuery.maybeOf(context);
        if (mq != null &&
            (isDesktopPlatform || mq.size.width > kDesktopBreakpoint)) {
          w = MediaQuery(
            data: mq.copyWith(textScaler: const TextScaler.linear(1.15)),
            child: w,
          );
        }
        return w;
      },
      home: const SplashScreen(),
    );
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/accounting.dart';
import '../core/shell_nav.dart';
import '../core/desktop.dart';
import '../core/models.dart';
import '../core/app_version.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/sync/device_registry.dart';
import '../data/update_installer.dart';
import '../data/sync/cloud_join.dart';
import '../data/update_service.dart';
import 'update_section.dart';
import 'profile_dialog.dart';
import 'account_form.dart';
import 'accounts_screen.dart';
import 'backup_screen.dart';
import 'chat_screen.dart';
import 'currencies_screen.dart';
import 'dashboard_screen.dart';
import 'inventory_screen.dart';

import 'dart:async';

import 'reports_screen.dart';
import 'settings_screen.dart';
import 'trash_screen.dart';
import 'transactions_screen.dart';
import 'tx_form.dart';
import 'vouchers_screen.dart';
import 'pos_screen.dart';
import 'widgets/sync_arrows_indicator.dart';
import 'widgets/golden_bell_icon.dart';
import 'sync_ops_screen.dart';
import '../data/sync/sync_service.dart';

import 'group_management_screen.dart';
import 'notifications_sheet.dart';
import 'app_notice.dart';
import '../core/sfx.dart';
import '../core/keep_alive_service.dart';
import '../data/sync/device_id.dart';
import '../data/sync/sync_engine.dart';
import '../data/sync/sync_activity.dart';
import '../data/sync/subscription_guard.dart';
import '../data/repository.dart';
import '../data/sync/workspace_service.dart';
import '../data/sync/chat_hooks.dart';
import '../data/sync/cloud_control_service.dart';
import 'trial_ui.dart';
import 'dialogs/sync_resolution_dialog.dart';
import 'widgets.dart' show showSnack;
import '../core/cloud_config.dart';

/// كل شاشات التطبيق الاثنتي عشرة.
enum AppScreen {
  dashboard('لوحة التحكم', Icons.dashboard_outlined, Icons.dashboard),
  pos('نقطة البيع (POS)', Icons.point_of_sale_outlined, Icons.point_of_sale),
  accounts('الحسابات', Icons.people_alt_outlined, Icons.people_alt),
  transactions('العمليات', Icons.receipt_long_outlined, Icons.receipt_long),
  vouchers('السندات', Icons.receipt_outlined, Icons.receipt),
  reports('التقارير', Icons.bar_chart_outlined, Icons.bar_chart),
  inventory('إدارة المنتجات', Icons.inventory_2_outlined, Icons.inventory_2),
  currencies(
    'العملات',
    Icons.currency_exchange_outlined,
    Icons.currency_exchange,
  ),
  chat('الدردشة', Icons.forum_outlined, Icons.forum),
  group('إدارة المجموعة', Icons.groups_outlined, Icons.groups),
  trash('سلة المهملات', Icons.delete_outline, Icons.delete),
  activity('سجل النشاط', Icons.history, Icons.history),
  backup('النسخ الاحتياطي', Icons.backup_outlined, Icons.backup),
  syncOps('العمليات المتزامنة', Icons.cloud_sync_outlined, Icons.cloud_sync),
  settings('الإعدادات', Icons.settings_outlined, Icons.settings);

  const AppScreen(this.title, this.icon, this.activeIcon);
  final String title;
  final IconData icon;
  final IconData activeIcon;
}

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with WidgetsBindingObserver {
  AppScreen _screen = AppScreen.dashboard;

  // (3.70.0) لوحة التحكم مثبّتة كأول شاشة دائمة على كل المنصات —
  // عند الإقلاع وبعد تجاوز شاشة القفل (أُلغي الإقلاع المباشر على POS).

  /// الشريط الجانبي المكتبي: مطوي (أيقونات) أو موسّع (أيقونات + عناوين).
  bool _railExtended = true;

  Timer? _syncTimer;
  bool _updatePrompted = false;

  Timer? _greetingTimer;
  DateTime _lastDeliveredNotice = DateTime.fromMillisecondsSinceEpoch(0);

  // (دفعة 58 — متطلب 20) مستمع سحابي عالمي لطلبات الانضمام على جهاز
  // المدير: يعمل من إقلاع التطبيق وعلى أي شاشة — حوار الموافقة/الرفض
  // يظهر فوق كل شيء لحظة وصول الطلب، لا فقط داخل شاشة إدارة المجموعة.
  JoinRequestWatcher? _globalJoinWatcher;
  bool _joinSheetShowing = false;

  /// (منع تكرار الحوار) مفاتيح طلبات الانضمام التي عُرض حوارها واكتمل
  /// اتخاذ قرار فيها خلال هذه الجلسة — فلا يُعاد فتح نفس الحوار لنفس
  /// الجهاز عند كل نبضة SSE، ويبقى الطلب الجديد (بمفتاح مختلف) ظاهراً.
  /// (منع تكرار الحوار) مفاتيح الطلبات التي سُوّي أمرها → وقت التسوية (ms).
  ///
  /// كانت مجموعة في الذاكرة فقط: إعادة تشغيل التطبيق تُعيد فتح حوار طلب
  /// عُولج سابقاً. صارت تُحفظ في `settings` مع مهلة 6 ساعات — تكفي لضمان
  /// عدم تكرار الحوار، ولا تمنع طلباً جديداً حقيقياً من نفس الجهاز لاحقاً.
  final Map<String, int> _handledJoinRequests = <String, int>{};

  /// مفتاح التخزين في جدول settings.
  static const _handledJoinKey = 'joinRequests.handled';

  /// مهلة صلاحية السجل المحفوظ.
  static const _handledJoinTtl = Duration(hours: 6);

  /// مفتاح تفرّد الطلب: معرّف الجهاز + وقت تقديمه (يتغيّر مع كل طلب جديد).
  String _joinRequestKey(Map<String, Object?> r) =>
      '${r['deviceId'] ?? ''}|${r['requestedAt'] ?? r['created_at'] ?? ''}';

  /// تحميل الطلبات المعالجة سابقاً مع إسقاط ما انقضت مهلته.
  Future<void> _loadHandledJoinRequests() async {
    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final raw = (st[_handledJoinKey] ?? '').trim();
      if (raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final cutoff = DateTime.now().millisecondsSinceEpoch -
          _handledJoinTtl.inMilliseconds;
      for (final e in decoded.entries) {
        final at = (e.value as num?)?.toInt() ?? 0;
        if (at >= cutoff) _handledJoinRequests['${e.key}'] = at;
      }
    } catch (_) {
      // سجل تالف أو غير متاح — الحوار قد يتكرر مرة، وهو أقل ضرراً من تعطّل الشاشة.
    }
  }

  /// حفظ السجل بعد تسوية طلب، مع تقليم المنتهي.
  Future<void> _saveHandledJoinRequests() async {
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final cutoff = nowMs - _handledJoinTtl.inMilliseconds;
      _handledJoinRequests.removeWhere((_, at) => at < cutoff);
      final repo = ref.read(repoProvider);
      await repo.setSetting(_handledJoinKey, jsonEncode(_handledJoinRequests));
    } catch (_) {}
  }

  /// (إصلاح تسليم الإدارة) نبضات نشاط المزامنة → تحديث حي لمزودي
  /// الملكية/الدور/الوضع، فتظهر «إدارة المجموعة» وشاشات الأجهزة فوراً
  /// عند استلام الملكية دون إعادة تشغيل أو تسجيل خروج.
  StreamSubscription<int>? _activityBus;

  /// تجميع النبضات المتتالية بمهلة قصيرة: bump فوري مع كل نبضة كان يطلق
  /// استعلامات المزودين أثناء معاملة كتابة مفتوحة فيقفل قاعدة البيانات
  /// (database locked) — التأجيل يترك المعاملة تكتمل أولاً.
  Timer? _activityDebounce;

  /// هل بانر «نافذة الخطر» ظاهر حالياً؟ (لمنع تكرار الصوت مع كل فحص).
  bool _dangerShown = false;
  bool _dangerSyncing = false; // سبينر «إعادة المحاولة» داخل بانر الخطر.
  DateTime? _dangerSnoozedUntil; // «إخفاء» = غفوة 30 دقيقة لا كتم دائم.

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // (2026-09-24) قناة تنقّل من الشاشات الداخلية (زر الرئيسية في نقطة البيع).
    ShellNav.request.addListener(_onShellNavRequest);
    // (منع تكرار الحوار) استعادة سجل الطلبات المعالجة قبل أي استطلاع.
    unawaited(_loadHandledJoinRequests());
    _refreshSync();
    _syncTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _refreshSync(),
    );
    _checkForUpdateOnStart();
    _wireSyncNotices();
    _scheduleGreeting();
    _greetingTimer = Timer.periodic(
      const Duration(minutes: 20),
      (_) => _scheduleGreeting(),
    );
    // فُتح التطبيق بالضغط على إشعار خارجي أو بدء مسار الإقلاع التلقائي
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyStartupRouting();
      _consumeNotifyTap();
    });
    // (دفعة 58) المستمع العالمي لطلبات الانضمام — للمدير فقط.
    _startGlobalJoinWatcher();
    // 🔒 الفترة التجريبية: ترحيب أول مرة + رصد الانتهاء.
    _watchTrialLifecycle();
    // (إصلاح تسليم الإدارة) أي دفعة عمليات مطبقة (ومنها نقل الملكية أو
    // تغيير دور) تعيد بناء كل المزودات المشتقة من refreshProvider —
    // الشريط الجانبي والإعدادات يعكسان الصلاحيات الجديدة لحظياً.
    _activityBus = SyncActivityBus.instance.stream.listen((_) {
      _activityDebounce?.cancel();
      _activityDebounce = Timer(const Duration(milliseconds: 400), () {
        if (!mounted) return;
        // إبطال موجّه لمزودي الهوية/الصلاحيات فقط — لا bump شاملاً حتى
        // لا تُفرَّغ قوائم البيانات (العمليات/الحسابات) أثناء إعادة البناء.
        ref.invalidate(isOwnerProvider);
        ref.invalidate(deviceRoleProvider);
        ref.invalidate(workspaceModeProvider);
        ref.invalidate(devicesProvider);
        // (إصلاح مزامنة الكتالوج وإدارة المنتجات) تحديث فوري للأقسام والفئات والأصناف
        ref.invalidate(itemsProvider);
        ref.invalidate(itemCategoriesProvider);
        ref.invalidate(itemCategoryTreeProvider);
        ref.invalidate(sectionsProvider);
        ref.invalidate(inventorySummaryProvider);
      });
    });
    // يقظة المجموعة + أذونات النظام الحقيقية (إشعارات/بطارية).
    _ensureGroupKeepAlive();
    // 🌐 مركز التحكم السحابي والتنبيهات المباشرة والإدارة عن بعد
    CloudControlService.instance
        .startPeriodicHeartbeat(ref.read(repoProvider));
  }

  /// (متطلب 5) سلوك الإقلاع وتوجيه البداية حسب المنصة والدور
  Future<void> _applyStartupRouting() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;

    final isDesktopPlatform = Platform.isWindows;
    if (isDesktopPlatform) {
      ref.read(navAppModeProvider.notifier).setMode(NavAppMode.pos);
      if (mounted) setState(() => _screen = AppScreen.pos);
      // استدعاء فوري للأقسام والأصناف
      ref.read(itemsProvider);
      ref.read(itemCategoriesProvider);
      ref.read(sectionsProvider);
      return;
    }

    try {
      final roleAsync = await ref.read(deviceRoleProvider.future);
      final user = await ref.read(repoProvider).currentUser();
      final effectiveRole = roleAsync?.role ?? user?.role;

      if (effectiveRole == UserRole.viewer || effectiveRole == UserRole.cashier) {
        ref.read(navAppModeProvider.notifier).setMode(NavAppMode.pos);
        if (mounted) setState(() => _screen = AppScreen.pos);
        ref.read(itemsProvider);
        ref.read(itemCategoriesProvider);
      } else if (effectiveRole == UserRole.dataentry) {
        ref.read(navAppModeProvider.notifier).setMode(NavAppMode.pos);
        if (mounted) setState(() => _screen = AppScreen.inventory);
      } else {
        final sp = await SharedPreferences.getInstance();
        final saved = sp.getString('app_nav_mode');
        if (saved == 'pos') {
          if (mounted) setState(() => _screen = AppScreen.pos);
        } else {
          if (mounted) setState(() => _screen = AppScreen.dashboard);
        }
      }
    } catch (_) {}
  }

  /// داخل مجموعة: يشغّل خدمة اليقظة (foreground service) ليستقبل الجهاز
  /// العمليات والإشعارات فوراً حتى والشاشة مطفأة، ويطلب — بنوافذ النظام
  /// الرسمية — إذن الإشعارات (أندرويد 13+) والإعفاء من تحسينات البطارية.
  Future<void> _ensureGroupKeepAlive() async {
    try {
      final repo0 = ref.read(repoProvider);
      final mode = await repo0.workspaceMode();
      final st0 = await repo0.settings();
      // إعداد المستخدم «المزامنة في الخلفية وأثناء السكون» (افتراضي: مفعّل).
      final wantBg = (st0['bgKeepAlive'] ?? '1') != '0';
      final inGroup = mode != 'standalone';
      await NexKeepAlive.setEnabled(inGroup && wantBg);
      if (!inGroup || !wantBg) return;
      // إذن الإشعارات: نافذة النظام مباشرة (لا نافذة مصطنعة).
      if (!await NexKeepAlive.hasPermission(NexKeepAlive.permNotifications)) {
        await NexKeepAlive.requestPermission(NexKeepAlive.permNotifications);
      }
      // الإعفاء من تحسينات البطارية: نافذة النظام الرسمية، مرة واحدة فقط
      // (إن رفض لا نلاحقه في كل إقلاع).
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      if (!await NexKeepAlive.isBatteryExempt() &&
          st['batteryExemptAsked'] != '1') {
        await repo.setSetting('batteryExemptAsked', '1');
        await NexKeepAlive.requestBatteryExempt();
      }
    } catch (_) {
      // اليقظة كمالية — لا تعطل الإقلاع.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // عاد التطبيق للمقدمة بنقرة إشعار خارجي: افتح السجل المقصود فوراً.
    if (state == AppLifecycleState.resumed) {
      _consumeNotifyTap();
      // إعادة تقييم اليقظة (ربما اقترن/غادر مجموعة أثناء عمل التطبيق).
      _ensureGroupKeepAlive();
    }
  }

  /// يستهلك نقرة إشعار النظام (إن وُجدت) ويفتح السجل المرتبط بها.
  Future<void> _consumeNotifyTap() async {
    final tap = await Sfx.takeNotifyTap();
    if (tap == null || !mounted) return;
    await openNotificationEntity(tap['entityType']!, tap['entityId'] ?? '');
  }

  /// نافذة منبثقة داخلية لكل إشعار — تستجيب للضغط: تفتح السجل المرتبط
  /// أو نافذة توضيحية إن لم يكن للإشعار سجل محدد.
  void _showTappableNotice(
    String title,
    String body, {
    String entityType = '',
    String entityId = '',
  }) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        content: InkWell(
          onTap: () {
            messenger.hideCurrentSnackBar();
            if (entityType.isNotEmpty) {
              openNotificationEntity(entityType, entityId);
            } else {
              showAppNotice(
                context,
                title: title,
                message: body,
                kind: AppNoticeKind.info,
                playSound: false,
              );
            }
          },
          child: Row(
            children: [
              const Icon(
                Icons.notifications_active,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    if (body.isNotEmpty)
                      Text(
                        body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11.5),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_left, color: Colors.white70, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  /// يفتح الشاشة/السجل المرتبط بإشعار: عملية مالية → قسم العمليات مع نافذة
  /// تفاصيلها فوراً؛ أنواع أخرى → قسمها المناسب. يعيد false إن لم يكن للنوع
  /// وجهة معروفة (إشعار عام بلا سجل محدد).
  Future<bool> openNotificationEntity(String type, String id) async {
    switch (type) {
      case 'tx':
        _go(AppScreen.transactions);
        final txId = int.tryParse(id);
        if (txId == null) return true;
        final repo = ref.read(repoProvider);
        final tx = await repo.transactionById(txId);
        if (!mounted) return true;
        if (tx == null) {
          await showAppNotice(
            context,
            title: 'العملية غير موجودة',
            message: 'العملية المشار إليها في الإشعار حُذفت أو لم تعد متاحة.',
            kind: AppNoticeKind.warning,
            playSound: false,
          );
          return true;
        }
        final acc = tx.type == OpType.transfer
            ? (tx.fromId == null ? null : await repo.account(tx.fromId!))
            : (tx.accountId == null ? null : await repo.account(tx.accountId!));
        final toAcc = tx.toId == null ? null : await repo.account(tx.toId!);
        if (!mounted) return true;
        await showTxDetails(
          context,
          ref,
          tx: tx,
          account: acc,
          toAccount: toAcc,
        );
        return true;
      case 'account':
        _go(AppScreen.accounts);
        return true;
      case 'item' || 'stockMove' || 'itemCategory':
        _go(AppScreen.inventory);
        return true;
      case 'voucher':
        _go(AppScreen.vouchers);
        return true;
      case 'message' || 'conversation':
        _go(AppScreen.chat);
        return true;
      case 'sync':
        _go(AppScreen.syncOps);
        return true;
      case 'user':
        _go(AppScreen.group);
        return true;
      case 'cloud_alert':
        await showCloudAlertsSheet(context, ref);
        return true;
      case 'update_download':
        // (2026-09-22) إشعار اكتمال تنزيل التحديث: نقرة تفتح مجلد
        // التنزيلات العام (Download/Nexora) ليصل المستخدم للملف مباشرة.
        await UpdateInstaller.openDownloadsFolder(id);
        return true;
    }
    // نوع بلا وجهة معروفة: نافذة توضيحية بدل تجاهل النقرة.
    if (mounted) {
      await showAppNotice(
        context,
        title: 'إشعار عام',
        message: 'هذا الإشعار لا يقود إلى سجل محدد يمكن فتحه.',
        kind: AppNoticeKind.info,
        playSound: false,
      );
    }
    return true;
  }

  /// ربط أحداث المزامنة بالإشعارات: «تمت مزامنة العملية» عند التسليم،
  /// و«الجهاز متصل» عند عودة قرين — إشعار خارجي بصوت مميز + صوت داخلي.
  void _wireSyncNotices() {
    SyncEngine.onOpDelivered = (opDesc, deviceName0, entityType, entityId) {
      // الاسم الموحد: جهاز بلا اسم يظهر «مستخدم جديد» في كل الإشعارات.
      final deviceName =
          deviceName0.trim().isEmpty ? kDefaultMemberName : deviceName0;
      Sfx.synced();
      // لا نغرق المستخدم: إشعار خارجي واحد كحد أقصى كل 20 ثانية.
      final now = DateTime.now();
      if (now.difference(_lastDeliveredNotice) > const Duration(seconds: 20)) {
        _lastDeliveredNotice = now;
        Sfx.systemNotify(
          title: 'تمت مزامنة العملية',
          body: '$opDesc — وصلت إلى $deviceName بنجاح',
          entityType: entityType,
          entityId: entityId,
        );
      }
      // حدث مالي مهم → يُسجَّل في جدول الإشعارات الداخلية (الجرس) أيضاً.
      try {
        ref.read(repoProvider).notify(
              title: 'تمت مزامنة العملية',
              body: '$opDesc — وصلت إلى $deviceName',
              kind: 'success',
              entityType: entityType,
              entityId: entityId,
            );
      } catch (_) {}
      _showTappableNotice(
        'تمت مزامنة العملية',
        '$opDesc — وصلت إلى $deviceName',
        entityType: entityType,
        entityId: entityId,
      );
    };
    // جهاز عاد للاتصال: حدث تشغيلي عابر — صوت + بانر داخلي فقط،
    // لا يلوث جدول الإشعارات الداخلية (المخصص للمالي والإداري المهم).
    SyncEngine.onPeerJoined = (deviceName0) {
      final deviceName =
          deviceName0.trim().isEmpty ? kDefaultMemberName : deviceName0;
      Sfx.pair();
      _showTappableNotice(
        'جهاز متصل',
        '$deviceName عاد للاتصال — تجري المزامنة الفورية الآن',
        entityType: 'sync',
      );
    };
    // (3.71.0) المدير عدّل صلاحيات هذا العضو — التنفيذ فوري عبر السحب
    // اللحظي (SSE + دورة 5 ثوانٍ)، والإخطار فوري على جهاز العضو:
    // إشعار نظام قابل للنقر + جرس داخل التطبيق، بلا إعادة تشغيل.
    SyncEngine.onPermissionsChanged = (roleLabel) {
      Sfx.pair();
      try {
        ref.read(repoProvider).notify(
              title: 'تم تعديل صلاحياتك',
              body: 'دورك في المجموعة الآن: «$roleLabel» — التعديل نافذ فوراً',
              kind: 'success',
              entityType: 'sync',
            );
      } catch (_) {}
      _showTappableNotice(
        'تم تعديل صلاحياتك',
        'دورك في المجموعة الآن: «$roleLabel» — نافذ فوراً',
        entityType: 'sync',
      );
    };
    // اكتمال المزامنة مع جهاز: حدث تشغيلي عابر — توست سفلي خفيف يختفي
    // وحده، لا يُخزَّن أبداً في جدول notifications الداخلي (قاعدة صارمة).
    SyncEngine.onDeviceSyncComplete = (deviceName0) {
      final deviceName =
          deviceName0.trim().isEmpty ? kDefaultMemberName : deviceName0;
      Sfx.synced();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
            content: Text('تم اكتمال المزامنة مع $deviceName ✅'),
          ),
        );
    };
    // «نافذة الخطر»: تباين خطير محتمل في السجلات — بانر مثبّت أعلى
    // الشاشة يتكرر مع كل فحص حتى تُستعاد سلامة المزامنة، ثم يُزال.
    // البانر قابل للحل مباشرة: زر «إعادة المحاولة والمزامنة فوراً» ينفّذ
    // triggerImmediateSync() مع سبينر داخل البانر، والنجاح يخفيه لحظياً
    // (المحرك يبثّ null فور تفريغ الطابور). «إخفاء» = غفوة 30 دقيقة.
    SyncEngine.onSyncDanger = (message) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (message == null) {
        // زوال الخطر يلغي أي غفوة سارية — الحالة القادمة تبدأ من جديد.
        _dangerSnoozedUntil = null;
        if (_dangerShown) {
          _dangerShown = false;
          _dangerSyncing = false;
          messenger.hideCurrentMaterialBanner();
        }
        return;
      }
      // غفوة سارية (ضغط المستخدم «إخفاء»)؟ نصمت حتى تنقضي الـ 30 دقيقة.
      final snooze = _dangerSnoozedUntil;
      if (snooze != null && DateTime.now().isBefore(snooze)) return;
      _dangerSnoozedUntil = null;
      if (!_dangerShown) Sfx.error();
      _dangerShown = true;
      _showDangerBanner(messenger, message);
    };
    // رسالة دردشة واردة — قاعدة صارمة: مكانها الوحيد (1) إشعار النظام
    // الخارجي بصوته المرفق بالنص و(2) شارة العداد على أيقونة الدردشة.
    // يُمنع إدراجها في جدول notifications الداخلي (مخصص للمالي/الإداري)،
    // والبانر الداخلي يظهر فقط إن كان المستخدم على شاشة أخرى غير الدردشة.
    ChatHooks.onChatMessage = (senderName0, body) {
      final senderName =
          senderName0.trim().isEmpty ? kDefaultMemberName : senderName0;
      final short = body.length > 80 ? '${body.substring(0, 80)}…' : body;
      // إشعار النظام يحمل النص والصوت معاً — لا صوت معزولاً بلا محتوى.
      Sfx.systemNotify(
        title: 'رسالة من $senderName',
        body: short,
        entityType: 'message',
      );
      bump(ref); // تحديث شارة العداد غير المقروء فوراً.
      if (_screen != AppScreen.chat) {
        _showTappableNotice(
          '💬 رسالة جديدة من $senderName',
          short,
          entityType: 'message',
        );
      }
    };
    // وصول تنبيه سحابي أو إداري جديد (Broadcast / In-App Alert)
    CloudControlService.instance.onNewAlertReceived = (alert) {
      if (!mounted) return;
      Sfx.systemNotify(
        title: alert.title,
        body: alert.body,
        entityType: 'cloud_alert',
        entityId: alert.id,
      );
      if (alert.isModal) {
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.campaign_rounded, color: Color(0xFF7C3AED)),
                const SizedBox(width: 8),
                Expanded(child: Text(alert.title)),
              ],
            ),
            content: Text(alert.body),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('حسناً، فهمت'),
              ),
            ],
          ),
        );
      } else {
        _showTappableNotice(
          alert.title,
          alert.body,
          entityType: 'cloud_alert',
          entityId: alert.id,
        );
      }
    };
    // تغيير أجراه المدير على هذا العضو (اسم/دور/صلاحيات): حدث إداري
    // مهم → إشعار داخلي (الجرس) + خارجي + بانر.
    ChatHooks.onMemberNotice = (title, body) {
      Sfx.systemNotify(title: title, body: body);
      try {
        ref.read(repoProvider).notify(title: title, body: body, kind: 'info');
      } catch (_) {}
      _showTappableNotice(title, body);
    };
  }

  /// تحية داخلية موقوتة: «صباح الخير» (5-11:59) و«مساء الخير» (16-21:59)
  /// مرة واحدة لكل فترة يومياً، بصوت هادئ ونافذة منبثقة أنيقة.
  Future<void> _scheduleGreeting() async {
    try {
      // وضع الاختبار الصامت: لا نوافذ تحية تحجب الشاشة وتكسر اختبارات E2E
      // (كانت نافذة «مساء الخير» تفتح فوق الشاشة فتحجب كل النقرات).
      if (Sfx.muted) return;
      final now = DateTime.now();
      final isMorning = now.hour >= 5 && now.hour < 12;
      final isEvening = now.hour >= 16 && now.hour < 22;
      if (!isMorning && !isEvening) return;
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final key = isMorning ? 'lastMorningGreeting' : 'lastEveningGreeting';
      final today = '${now.year}-${now.month}-${now.day}';
      if (st[key] == today) return;
      await repo.setSetting(key, today);
      final title = isMorning ? 'صباح الخير' : 'مساء الخير';
      final msg = isMorning
          ? 'صباح الخير! نتمنى لك يوماً موفقاً مليئاً بالمبيعات الطيبة.'
          : 'مساء الخير! نتمنى لك أمسية هادئة وحسابات رابحة.';
      // صوت هادئ عبر إشعار النظام + نافذة داخلية أنيقة.
      Sfx.systemNotify(title: title, body: msg, peaceful: true);
      if (!mounted) return;
      await showAppNotice(
        context,
        title: title,
        message: msg,
        kind: AppNoticeKind.info,
        playSound: false,
      );
    } catch (_) {
      // التحية كمالية — لا تعطل شيئاً.
    }
  }

  /// 🔒 دورة حياة الفترة التجريبية على الشاشة الرئيسية:
  ///  - نافذة ترحيب راقية مرة واحدة فقط عند أول تفعيل (trialWelcomed).
  ///  - عند رصد الانتهاء لأول مرة: بطاقة «انتهت الفترة» مع خيارات
  ///    التجديد والتواصل (trialExpiredShown يمنع التكرار المزعج).
  Future<void> _watchTrialLifecycle() async {
    try {
      // مهلة قصيرة حتى تكتمل تهيئة السحابة والمزودات.
      await Future<void>.delayed(const Duration(seconds: 3));
      if (!mounted) return;
      final repo = ref.read(repoProvider);
      // (2026-09-22 — جوجل فقط) حُذف الاسترداد الصامت ببصمة العتاد:
      // بعد مسح بيانات التطبيق لا يُسترجع أي شيء إلا بتسجيل الدخول
      // بحساب جوجل (AccountWorkspace.linkAccountOnly يجلب المساحة
      // والبيانات تلقائياً فور الدخول). لا استرجاع مجهول بعد اليوم.
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isEmpty) return; // لا سحابة = لا تجربة بعد.
      final db = await repo.database;
      // (3.71.0 — ربط حتمي) المساحة الصريحة/الأحدث — لا اختيار عشوائياً.
      final ws = await ensureWorkspace(db, repo: repo);
      // (الفهرس السحابي) تثبيت ربط بصمة الجهاز بمساحته ودوره الحاليين.
      try {
        await DeviceRegistry.upsertBinding(repo, backendUrl: url);
      } catch (_) {}
      // (المرحلة 2) عضوية المالك في /members/{auth.uid} — تُثبَّت عند كل
      // إقلاع (لا تُعاد كتابتها إن وُجدت) فتعمل قواعد الأمان بـ auth.uid
      // للمساحات المنفردة والمجموعات على حد سواء.
      try {
        if (await repo.isWorkspaceOwner()) {
          await CloudJoin.ensureOwnerMembership(
            repo,
            backendUrl: url,
            workspaceId: ws,
          );
        }
      } catch (_) {}
      // (الاسترداد السيادي) تسجيل منشئ المساحة بأثر رجعي عند الإقلاع:
      // للمجموعات القائمة قبل الميزة — المالك الحالي يُسجَّل منشئاً إن
      // كانت العقدة السحابية الدائمة غائبة (تُكتب مرة واحدة ولا تتغير).
      try {
        if (await repo.isWorkspaceOwner() &&
            await repo.workspaceMode() != 'standalone') {
          await CloudJoin.registerCreatorIfAbsent(
            repo,
            backendUrl: url,
            workspaceId: ws,
            deviceId: repo.requireDeviceId,
          );
        } else {
          // عضو: كاش سجل المنشئ محلياً (يلزم للتحقق من creator_recovery
          // ولإظهار خيار الاسترداد على جهاز المنشئ الذي فقد الملكية).
          final creator = await CloudJoin.fetchCreatorDeviceId(
            backendUrl: url,
            workspaceId: ws,
          );
          if (creator.isNotEmpty) {
            await repo.setSetting('creatorDeviceId', creator);
          }
        }
      } catch (_) {}
      // (ترحيل الاشتراك) تهيئة كسولة عند الإقلاع: المساحات القديمة
      // المسجلة قبل نظام التجربة بلا عقدة subscription — الفحص القسري
      // ينشئها تلقائياً بختم خادم (created_at = لحظة هذا الفتح،
      // expires_at = +24h) مرة واحدة فقط، ثم لا تُعاد تهيئتها أبداً.
      final sub = await SubscriptionGuard.check(
        repo,
        backendUrl: url,
        workspaceId: ws,
        force: true,
      );
      if (!mounted || sub.status == 'none') return;
      // (أ) الترحيب — مرة واحدة فقط.
      if (sub.status == 'trial' &&
          !sub.expired &&
          (st['trialWelcomed'] ?? '') != '1') {
        await repo.setSetting('trialWelcomed', '1');
        if (mounted) await showTrialWelcomeDialog(context);
      }
      // (ب) الانتهاء — مرة واحدة لكل انتهاء، برسالة بحسب الدور والخطة:
      // المدير يرى بطاقة الشراء/التجديد؛ جهاز الموظف في مؤسسة يرى تنبيه
      // «راجع إدارة النظام» (القسم 3 — لا يُطالَب الموظف بالدفع).
      if (sub.expired && (st['trialExpiredShown'] ?? '') != '1') {
        await repo.setSetting('trialExpiredShown', '1');
        final owner = await repo.isWorkspaceOwner();
        if (!mounted) return;
        if (owner) {
          await showTrialExpiredSheet(context);
        } else {
          ChatHooks.onMemberNotice?.call(
            '☁️ المزامنة السحابية متوقفة',
            'المزامنة السحابية متوقفة؛ يرجى مراجعة إدارة النظام '
                'لتجديد الباقة. عملك المحلي مستمر بأمان.',
          );
        }
      }
    } catch (_) {
      // شبكة غائبة — الفحص الدوري في المحرك يغطي.
    }
  }

  /// (دفعة 58 — متطلب 20) يشغّل قناة SSE عالمية على /joinRequests لجهاز
  /// المدير: أي طلب انضمام يفتح حوار الموافقة فوق الشاشة الحالية أياً
  /// كانت. تُعاد المحاولة تلقائياً داخل JoinRequestWatcher عند الانقطاع.
  Future<void> _startGlobalJoinWatcher() async {
    try {
      final repo = ref.read(repoProvider);
      if (!await repo.isWorkspaceOwner()) return;
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isEmpty || !mounted) return;
      final db = await repo.database;
      // (3.71.0 — ربط حتمي) المراقب يستمع لمساحة المجموعة الفعلية:
      // طلبات المغادرة كانت تُكتب لمساحة ميتة فلا يصل المدير شيء.
      final ws = await ensureWorkspace(db, repo: repo);
      _globalJoinWatcher = JoinRequestWatcher(
        backendUrl: url,
        workspaceId: ws,
        onRequestsChanged: () {
          if (mounted) _handleGlobalJoinRequests(url, ws);
        },
      )..start();
      // فحص أولي: طلب وصل والتطبيق مغلق يظهر فور الإقلاع.
      await _handleGlobalJoinRequests(url, ws);
    } catch (_) {}
  }

  Future<void> _handleGlobalJoinRequests(String url, String ws) async {
    if (!mounted || _joinSheetShowing) return;
    try {
      final repo = ref.read(repoProvider);
      if (!await repo.isWorkspaceOwner()) return;
      final reqs = await CloudJoin.fetchJoinRequests(
        repo,
        backendUrl: url,
        workspaceId: ws,
      );
      if (reqs.isEmpty || !mounted || _joinSheetShowing) return;
      // (منع تكرار الحوار) تجاوز كل طلب سُوّي أمره في هذه الجلسة.
      final next = reqs.firstWhere(
        (r) => !_handledJoinRequests.containsKey(_joinRequestKey(r)),
        orElse: () => const <String, Object?>{},
      );
      if (next.isEmpty) return;
      final key = _joinRequestKey(next);
      _joinSheetShowing = true;
      try {
        // فوق أي شاشة: نستخدم سياق جذر الملاحة لا سياق الشاشة الحالية.
        final rootCtx = Navigator.of(context, rootNavigator: true).context;
        // (الجلسة قد تُغلق أثناء الفجوة غير المتزامنة) حراسة السياق نفسه.
        if (!rootCtx.mounted) return;
        await showJoinApprovalSheet(
          rootCtx,
          ref,
          next,
          backendUrl: url,
          workspaceId: ws,
        );
        // اكتمل الحوار (قبول أو رفض) — لا نعيد فتحه لهذا الطلب،
        // ولا بعد إعادة تشغيل التطبيق (السجل محفوظ مع مهلة 6 ساعات).
        _handledJoinRequests[key] = DateTime.now().millisecondsSinceEpoch;
        unawaited(_saveHandledJoinRequests());
      } finally {
        _joinSheetShowing = false;
      }
      if (mounted) bump(ref);
      // طلبات إضافية متراكمة؟ عالجها تباعاً.
      if (mounted) await _handleGlobalJoinRequests(url, ws);
    } catch (_) {
      _joinSheetShowing = false;
    }
  }

  /// (دفعة 58 — متطلب 12) «الجديد في هذا التحديث» الديناميكي:
  /// يُعرض مرة واحدة فقط بعد كل ترقية فعلية (تغيّر kAppVersion عن آخر
  /// إصدار شوهد)، وبملاحظات هذا الإصدار حصراً — تُقرأ من بيان التحديث
  /// عندما يطابق رقمه إصدارنا المثبَّت، فلا يظهر أي نص قديم أبداً.
  Future<void> _maybeShowWhatsNew(UpdateInfo info) async {
    final repo = ref.read(repoProvider);
    final st = await repo.settings();
    // (3.70.0+133) المفتاح مربوط برقم البناء: إعادة نشر نفس الإصدار
    // ببناء أحدث (+132 ← +133) تستحق تنبيه «ما الجديد» أيضاً — لا فقط
    // عند تغيير الإصدار التسويقي (كانت الأجهزة المثبَّت لها نفس الرقم
    // لا ترى أي إشعار رغم تغيّر محتوى الحزمة).
    const buildKey = '$kAppVersion+$kAppBuild';
    final seen = (st['whatsNewSeenVersion'] ?? '').trim();
    if (seen == buildKey) return; // عُرض لهذا البناء من قبل.
    // أول تثبيت (لا قيمة سابقة): سجّل بصمت بلا حوار.
    if (seen.isEmpty) {
      await repo.setSetting('whatsNewSeenVersion', buildKey);
      return;
    }
    // ملاحظات البيان تخص أحدث إصدار منشور — نعرضها فقط إن كانت نسختنا
    // (إصداراً وبناءً) هي ذاتها الأحدث (ترقية اكتملت للتو).
    final latest = info.latest;
    final isCurrentRelease = latest != null &&
        '${latest.major}.${latest.minor}.${latest.patch}' == kAppVersion &&
        latest.build == kAppBuild;
    await repo.setSetting('whatsNewSeenVersion', buildKey);
    if (!isCurrentRelease || info.notes.trim().isEmpty) return;
    if (!mounted) return;
    await showWhatsNewDialog(context, kAppVersion, info.notes);
  }

  /// فحص تحديث صامت عند الإقلاع: لا يزعج المستخدم إلا إذا وُجد تحديث فعلًا،
  /// ولا يظهر الحوار الاختياري أكثر من مرة واحدة في اليوم.
  Future<void> _checkForUpdateOnStart() async {
    if (_updatePrompted) return;
    _updatePrompted = true;
    try {
      final repo = ref.read(repoProvider);
      final info = await ref.read(updateServiceProvider).check();
      if (!mounted) return;
      // «الجديد في هذا التحديث» بعد اكتمال ترقية — قبل أي حوار تحديث آخر.
      try {
        await _maybeShowWhatsNew(info);
      } catch (_) {}
      if (!mounted || !info.hasUpdate) return;
      if (!info.isMandatory) {
        // كتم الحوار الاختياري 24 ساعة بعد آخر عرض/تأجيل — **إلا** إذا
        // نُشر بناء أحدث منذ الكتم: كل بناء جديد يستحق تنبيهاً فورياً
        // مرة واحدة (كان الجهاز الذي حدّث اليوم لا يرى بناء الغد إلا
        // بعد 24 ساعة).
        final st = await repo.settings();
        final last = DateTime.tryParse(st['lastUpdatePrompt'] ?? '');
        final lastBuild = (st['lastUpdatePromptBuild'] ?? '').trim();
        final latestKey = info.latest?.toString() ?? '';
        if (last != null &&
            lastBuild == latestKey &&
            DateTime.now().difference(last) < const Duration(hours: 24)) {
          return;
        }
        await repo.setSetting(
          'lastUpdatePrompt',
          DateTime.now().toIso8601String(),
        );
        await repo.setSetting('lastUpdatePromptBuild', latestKey);
      }
      if (!mounted) return;
      await showUpdateDialog(context, ref, info);
    } catch (_) {
      // الفحص الصامت لا يجب أن يعطّل الإقلاع أبدًا.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncTimer?.cancel();
    _greetingTimer?.cancel();
    _globalJoinWatcher?.stop();
    _activityBus?.cancel();
    _activityDebounce?.cancel();
    if (SyncEngine.onOpDelivered != null) SyncEngine.onOpDelivered = null;
    if (SyncEngine.onPeerJoined != null) SyncEngine.onPeerJoined = null;
    if (SyncEngine.onPermissionsChanged != null) {
      SyncEngine.onPermissionsChanged = null;
    }
    SyncEngine.onDeviceSyncComplete = null;
    SyncEngine.onSyncDanger = null;
    ChatHooks.onChatMessage = null;
    ChatHooks.onMemberNotice = null;
    ShellNav.request.removeListener(_onShellNavRequest);
    CloudControlService.instance.stop();
    super.dispose();
  }

  void _refreshSync() {
    final repo = ref.read(repoProvider);
    final engine = ref.read(syncEngineProvider);
    if (!engine.hasStarted) engine.start();
    // (2026-09-24) أُزيلت شارة المزامنة المكرّرة من الشريط؛ نُبقي الاستعلام
    // الدوري (يهيّئ حالة المزامنة) بلا تخزين نتيجته — لا مستهلك لها بعد الآن.
    unawaited(_safeSyncStatus(repo, engine));
  }

  /// (3.71.0+136) درع سباق الإغلاق: تحديث دوري قيد الطيران قد يكتمل بعد
  /// التفكيك وإغلاق القاعدة — database_closed يُبتلع ويعاد وضع خامد صامت
  /// بدل خطأ غير معالج خارج النطاق غير المتزامن (أسقط شارد CI رغم خضرة محلية).
  Future<SyncStatusInfo> _safeSyncStatus(Repo repo, SyncEngine engine) async {
    try {
      return await SyncService(repo: repo, engine: engine).status();
    } catch (_) {
      return const SyncStatusInfo(
        state: SyncState.offline,
        pending: 0,
        failed: 0,
        cloudConfigured: false,
      );
    }
  }

  /// فحص تحديث التطبيق يدوياً (زر التحديث بسطح المكتب): يجري بالخلفية
  /// وعند توفر إصدار أحدث يظهر إشعار فوري بزر يقود لشاشة الإعدادات
  /// (قسم التحديث). الفشل صامت — الفحص الدوري يغطي لاحقاً.
  bool _updateCheckBusy = false;
  Future<void> _checkForAppUpdate() async {
    if (_updateCheckBusy) return;
    _updateCheckBusy = true;
    try {
      final info = await UpdateService().check();
      if (!mounted) return;
      if (info.hasUpdate) {
        Sfx.notify();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 8),
            content: Text(
              '🚀 يتوفر إصدار أحدث: ${info.latest} — التحديث من الإعدادات',
            ),
            action: SnackBarAction(
              label: 'فتح',
              onPressed: () => _go(AppScreen.settings),
            ),
          ),
        );
      }
    } catch (_) {
      // صامت — لا نزعج المستخدم بفشل فحص خلفي.
    } finally {
      _updateCheckBusy = false;
    }
  }

  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// يعرض بانر التحذير المصغّر الأنيق وغير المزعج.
  void _showDangerBanner(ScaffoldMessengerState messenger, String message) {
    final syncing = _dangerSyncing;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    messenger
      ..hideCurrentMaterialBanner()
      ..showMaterialBanner(
        MaterialBanner(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          backgroundColor: isDark
              ? const Color(0xFF2D1E0F)
              : const Color(0xFFFFFBEB),
          leading: syncing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFFD97706),
                  ),
                )
              : const Icon(
                  Icons.warning_amber_rounded,
                  color: Color(0xFFD97706),
                  size: 20,
                ),
          content: InkWell(
            onTap: () {
              messenger.hideCurrentMaterialBanner();
              _dangerShown = false;
              SyncResolutionDialog.show(context);
            },
            child: Text(
              syncing
                  ? 'جارٍ إعادة المحاولة ودفع العمليات المعلّقة…'
                  : (message.isNotEmpty
                      ? message
                      : 'تنبيه مزامنة: توجد عمليات معلقة لم تكتمل بعد'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isDark
                    ? const Color(0xFFFDE68A)
                    : const Color(0xFF92400E),
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'مزامنة الآن',
              icon: const Icon(Icons.sync_rounded, size: 18),
              onPressed: syncing ? null : () => _dangerRetryNow(messenger),
            ),
            TextButton(
              onPressed: () {
                messenger.hideCurrentMaterialBanner();
                _dangerShown = false;
                SyncResolutionDialog.show(context);
              },
              child: const Text(
                'عرض التفاصيل والحلول',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 11.5,
                ),
              ),
            ),
            IconButton(
              tooltip: 'إخفاء',
              icon: const Icon(Icons.close, size: 16),
              onPressed: () {
                _dangerSnoozedUntil = DateTime.now().add(
                  const Duration(minutes: 30),
                );
                messenger.hideCurrentMaterialBanner();
                _dangerShown = false;
              },
            ),
          ],
        ),
      );
  }

  /// زر «إعادة المحاولة والمزامنة فوراً»: يصفّر backoff ويدفع كل المعلّق
  /// حالاً. النجاح يبثّ null عبر onSyncDanger فيختفي البانر تلقائياً؛
  /// وإن بقيت عمليات عالقة يعود البانر برسالته دون السبينر.
  Future<void> _dangerRetryNow(ScaffoldMessengerState messenger) async {
    if (_dangerSyncing) return;
    Sfx.click();
    final engine = ref.read(syncEngineProvider);
    _dangerSyncing = true;
    // أعد عرض البانر بحالة «جارٍ المزامنة» (سبينر + تعطيل الأزرار).
    if (_dangerShown && mounted) {
      _showDangerBanner(messenger, '');
    }
    try {
      await engine.triggerImmediateSync().timeout(const Duration(seconds: 45));
    } catch (_) {
      // فشل/مهلة: يبقى الخطر قائماً وسيُعاد بثه بالدورة التالية.
    } finally {
      _dangerSyncing = false;
      // إن كان البانر ما زال معروضاً (لم يصل null) نعيد الرسالة الحية
      // من المحرك بالفحص الفوري — وإلا فقد أُخفي تلقائياً بالنجاح.
      if (mounted && _dangerShown) {
        try {
          await engine.recheckDangerNow();
        } catch (_) {}
      }
    }
  }

  /// (2026-09-24) يستجيب لطلبات التنقّل القادمة من الشاشات الداخلية.
  void _onShellNavRequest() {
    final target = ShellNav.request.value;
    if (target.isEmpty) return;
    switch (target) {
      case ShellNav.home:
        _go(AppScreen.dashboard);
      case ShellNav.inventory:
        _go(AppScreen.inventory);
    }
  }

  void _go(AppScreen s) {
    final user = ref.read(currentUserProvider).valueOrNull;
    final wsMode = ref.read(workspaceModeProvider).valueOrNull ?? 'standalone';
    final isOwnerAsync = ref.read(isOwnerProvider).valueOrNull;
    final isOwner = (wsMode == 'member') ? false : (isOwnerAsync ?? true);
    final isAdmin = (wsMode == 'member')
        ? false
        : (isOwner || user?.role == UserRole.admin || user?.role == UserRole.agent);
    final isAccountant = user?.role == UserRole.accountant;
    bool can(String p) => isAdmin || (user?.can(p) ?? false);

    // حظر الوصول للشاشات المقيدة
    if (s == AppScreen.settings && !isAdmin) {
      showSnack(context, 'الإعدادات مقيدة ومتاحة لمدير النظام فقط', error: true);
      return;
    }
    if (s == AppScreen.accounts && !isAdmin && !isAccountant && !can('edit_tx')) {
      showSnack(context, 'الوصول لقسم الحسابات مقيد لهذا المستخدم', error: true);
      return;
    }
    if (s == AppScreen.transactions && !isAdmin && !isAccountant && !can('edit_tx')) {
      showSnack(context, 'الوصول لقسم العمليات مقيد لهذا المستخدم', error: true);
      return;
    }
    if (s == AppScreen.reports && !can('view_reports')) {
      showSnack(context, 'عرض التقارير مقيد ويتطلب صلاحية المشرف', error: true);
      return;
    }
    if (s == AppScreen.inventory && !can('edit_tx')) {
      showSnack(context, 'إدارة المنتجات مقيدة لهذا المستخدم', error: true);
      return;
    }
    if (s == AppScreen.trash && !can('delete_tx')) {
      showSnack(context, 'سلة المهملات مقيدة وتتطلب صلاحية الحذف', error: true);
      return;
    }
    if (s == AppScreen.backup && !can('manage_backup')) {
      showSnack(context, 'النسخ الاحتياطي متاح لمدير النظام فقط', error: true);
      return;
    }
    if (s == AppScreen.group && !isAdmin) {
      showSnack(context, 'إدارة المجموعة متاحة لمدير النظام فقط', error: true);
      return;
    }

    _screenHistory
      ..clear()
      ..add(AppScreen.dashboard);
    if (s != AppScreen.dashboard) {
      _screenHistory.add(s);
    }
    setState(() => _screen = s);
    // فتح شاشة الدردشة يوسم الرسائل كمقروءة ويصفّر شارتها.
    if (s == AppScreen.chat) {
      Future(() async {
        try {
          await ref.read(repoProvider).markChatSeen();
          bump(ref);
        } catch (_) {}
      });
    }
  }

  Widget _body() => switch (_screen) {
        AppScreen.pos => const PosScreen(),
        AppScreen.dashboard => DashboardScreen(onOpen: _go),
        AppScreen.accounts => const AccountsScreen(),
        AppScreen.transactions => const TransactionsScreen(),
        AppScreen.vouchers => const VouchersScreen(),
        AppScreen.reports => const ReportsScreen(),
        AppScreen.inventory => const InventoryScreen(),
        AppScreen.currencies => const CurrenciesScreen(),
        AppScreen.chat => const ChatScreen(),
        AppScreen.group => const GroupManagementScreen(),
        AppScreen.trash => const TrashScreen(),
        AppScreen.activity => const ActivityScreen(),
        AppScreen.backup => const BackupScreen(),
        AppScreen.syncOps => const SyncOpsScreen(),
        AppScreen.settings => const SettingsScreen(),
      };

  /// زر العملية العائم المميّز بالتدرج الدائري كما في هوية التطبيق
  Widget? _fab() {
    final me = ref.watch(currentUserProvider).valueOrNull;
    bool can(String p) => me != null && me.can(p);
    final add = can('add_tx');
    if (!add) return null;

    if (_screen == AppScreen.pos) {
      return FloatingActionButton.extended(
        heroTag: 'omni',
        onPressed: () => PosScreen.openCheckoutBridge?.call(),
        icon: const Icon(Icons.shopping_cart_checkout_rounded),
        label: const Text('الدفع'),
      );
    }

    // (2026-09-22) زر الإضافة السريعة (+) يظهر في الشاشة الرئيسية فقط —
    // بقية الشاشات بلا زر عائم إطلاقاً.
    if (_screen != AppScreen.dashboard) return null;

    // (قانون 2026-09-19) الزر العائم «إجراء سريع» كما كان: يفتح ورقة
    // الخيارات (عملية، سند، حساب، نقطة بيع) بدل نموذج مباشر.
    return _MarkedOperationFab(onPressed: _quickActionSheet);
  }

  /// ورقة الإجراء السريع من زر Omni على الرئيسية: أكثر 4 مهام تكراراً
  /// بلا تشتيت — عملية، سند، حساب، فتح نقطة البيع.
  void _quickActionSheet() {
    Sfx.click();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('تسجيل عملية مالية'),
              onTap: () {
                Navigator.pop(ctx);
                openTxForm(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.receipt_outlined),
              title: const Text('سند قبض / صرف'),
              onTap: () {
                Navigator.pop(ctx);
                openVoucherForm(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.person_add_alt_outlined),
              title: const Text('حساب جديد'),
              onTap: () {
                Navigator.pop(ctx);
                openAccountForm(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.point_of_sale_outlined),
              title: const Text('فتح نقطة البيع'),
              onTap: () {
                Navigator.pop(ctx);
                _go(AppScreen.pos);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  final List<AppScreen> _screenHistory = [AppScreen.dashboard];
  bool _isExitDialogOpen = false;

  /// زر رجوع النظام:
  /// 1. إغلاق القائمة الجانبية (Drawer) أولاً إن كانت مفتوحة.
  /// 2. إغلاق أي حوار أو مسار منبثق إن وُجد.
  /// 3. الرجوع للشاشة السابقة إن كان المستخدم في شاشة فرعية.
  /// 4. على الصفحة الرئيسية: إظهار مربع حوار تأكيد الخروج (نعم / لا) مباشرة وسلساً.
  void _handleRootPop(bool didPop) {
    if (didPop) return;

    // 1) إغلاق القائمة الجانبية إن كانت مفتوحة
    final scaffold = _scaffoldKey.currentState;
    if (scaffold != null && scaffold.isDrawerOpen) {
      scaffold.closeDrawer();
      return;
    }
    if (scaffold != null && scaffold.isEndDrawerOpen) {
      scaffold.closeEndDrawer();
      return;
    }

    // 2) إغلاق أي حوار أو مسار فرعي مفتوح
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
      return;
    }

    // 3) أي شاشة فرعية داخل القشرة تعود مباشرة إلى الرئيسية بضغطة واحدة فقط
    // دون المرور على سجل كل النوافذ والأيقونات التي زارها المستخدم.
    if (_screen != AppScreen.dashboard) {
      _screenHistory
        ..clear()
        ..add(AppScreen.dashboard);
      setState(() => _screen = AppScreen.dashboard);
      return;
    }

    // 4) الصفحة الرئيسية: عرض حوار تأكيد الخروج مباشرة
    _showExitConfirmationDialog();
  }

  /// مربع حوار تأكيد الخروج من التطبيق عند ضغط زر رجوع النظام في الرئيسية
  Future<void> _showExitConfirmationDialog() async {
    if (_isExitDialogOpen || !mounted) return;
    _isExitDialogOpen = true;
    try {
      final shouldExit = await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Color(0x1FFF0000),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.exit_to_app, color: Colors.red, size: 24),
              ),
              const SizedBox(width: 12),
              const Text(
                'الخروج من التطبيق',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: const Text(
            'هل تريد الخروج من التطبيق؟',
            style: TextStyle(fontSize: 15),
          ),
          actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text(
                'لا',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                elevation: 0,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text(
                'نعم',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      );

      if (shouldExit == true && mounted) {
        await SystemNavigator.pop();
        if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
          exit(0);
        }
      }
    } finally {
      _isExitDialogOpen = false;
    }
  }

  /// الشريط الجانبي المكتبي (Navigation Rail) — يحل محل الشريط السفلي
  /// على الشاشات الكبيرة: أيقونات واضحة + عناوين، قابل للطي، وفي RTL
  /// يظهر على يمين الشاشة تلقائياً (بداية الاتجاه).
  Widget _desktopRail() {
    // في الوضع المستقل تُخفى «حالة المزامنة والأجهزة» — لا شبكات إطلاقاً.
    final standalone =
        (ref.watch(workspaceModeProvider).valueOrNull ?? 'standalone') ==
            'standalone';
    final entries = <(AppScreen, IconData, String)>[
      (AppScreen.pos, Icons.point_of_sale_outlined, 'نقطة البيع'),
      (AppScreen.accounts, Icons.menu_book_outlined, 'دفتر الحسابات والديون'),
      (
        AppScreen.transactions,
        Icons.receipt_long_outlined,
        'سجل الفواتير اليومية',
      ),
      (AppScreen.inventory, Icons.inventory_2_outlined, 'إدارة المنتجات'),
      if (!standalone)
        (
          AppScreen.syncOps,
          Icons.cloud_sync_outlined,
          'حالة المزامنة والأجهزة',
        ),
      (AppScreen.settings, Icons.settings_outlined, 'الإعدادات'),
    ];
    final selectedIdx =
        entries.indexWhere((e) => e.$1 == _screen).clamp(-1, entries.length);
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: BorderDirectional(
          end: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.18),
            width: 1.2,
          ),
        ),
      ),
      child: SafeArea(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: _railExtended ? 218 : 68,
          child: Column(
            children: [
              const SizedBox(height: 6),
              // زر الطي/التوسيع.
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: IconButton(
                  tooltip: _railExtended ? 'طيّ الشريط' : 'توسيع الشريط',
                  icon: Icon(
                    _railExtended
                        ? Icons.menu_open_rounded
                        : Icons.menu_rounded,
                  ),
                  onPressed: () =>
                      setState(() => _railExtended = !_railExtended),
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (var i = 0; i < entries.length; i++)
                      _RailTile(
                        icon: entries[i].$2,
                        label: entries[i].$3,
                        selected: i == selectedIdx,
                        extended: _railExtended,
                        onTap: () => _go(entries[i].$1),
                      ),
                    const Divider(height: 20),
                    // «المزيد» يفتح القائمة الجانبية بكل الأقسام الأخرى.
                    _RailTile(
                      icon: Icons.apps_rounded,
                      label: 'كل الأقسام',
                      selected: false,
                      extended: _railExtended,
                      onTap: () => _scaffoldKey.currentState?.openDrawer(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _appBarSquircleAction({
    required Widget icon,
    required String tooltip,
    required VoidCallback onTap,
    required Color bg,
    required Color fg,
    Border? border,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
        child: Tooltip(
          message: tooltip,
          child: Container(
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: border,
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                child: SizedBox(
                  width: 38,
                  height: 38,
                  child: Center(child: icon),
                ),
              ),
            ),
          ),
        ),
      );


  @override
  Widget build(BuildContext context) {
    ref.watch(hideBalancesProvider);
    final desktop = isDesktopLayout(context);

    return ValueListenableBuilder<bool>(
      valueListenable: CloudControlService.instance.isFrozenNotifier,
      builder: (ctx, frozen, _) {
        if (frozen) {
          return const FrozenAccountBarrier();
        }
        return ValueListenableBuilder<bool>(
          valueListenable: CloudControlService.instance.forceUpdateNotifier,
          builder: (ctx, forceUpdate, _) {
            if (forceUpdate) {
              return const ForceUpdateBarrier();
            }
            return ValueListenableBuilder<bool>(
              valueListenable:
                  CloudControlService.instance.maintenanceActiveNotifier,
              builder: (ctx, inMaintenance, _) {
                if (inMaintenance) {
                  return const MaintenanceModeBarrier();
                }
                return PopScope(
                  canPop: false,
                  onPopInvokedWithResult: (didPop, _) => _handleRootPop(didPop),
                  child: Scaffold(
                    key: _scaffoldKey,
        appBar: AppBar(
          leading: Builder(
            builder: (ctx) {
              final isDark = Theme.of(ctx).brightness == Brightness.dark;
              return Padding(
                padding: const EdgeInsets.all(8),
                child: Material(
                  color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => Scaffold.of(ctx).openDrawer(),
                    child: Icon(
                      Icons.menu,
                      size: 20,
                      color: AppColors.textOf(ctx),
                    ),
                  ),
                ),
              );
            },
          ),
          title: Consumer(
            builder: (ctx, rref, _) {
              if (_screen != AppScreen.dashboard) return Text(_screen.title);
              final devName =
                  rref.watch(ownDeviceNameProvider).valueOrNull?.trim();
              if (devName != null && devName.isNotEmpty) {
                return Text(devName, overflow: TextOverflow.ellipsis);
              }
              return const Text('مدير الحسابات');
            },
          ),
          actions: [
            const SyncArrowsIndicator(),
            Consumer(
              builder: (ctx, rref, _) {
                final unreadLocal =
                    rref.watch(unreadCountProvider).valueOrNull ?? 0;
                final isDark = Theme.of(ctx).brightness == Brightness.dark;
                return ValueListenableBuilder<int>(
                  valueListenable:
                      CloudControlService.instance.unreadAlertCountNotifier,
                  builder: (ctx, unreadCloud, _) {
                    final unread = unreadLocal + unreadCloud;
                    return _appBarSquircleAction(
                      tooltip: 'الإشعارات',
                      bg: isDark
                          ? const Color(0xFF291E04)
                          : const Color(0xFFFEF9C3),
                      fg: const Color(0xFFB45309),
                      border: Border.all(
                        color: isDark
                            ? const Color(0xFF854D0E)
                            : const Color(0xFFFDE047),
                        width: 1.1,
                      ),
                      icon: Badge(
                        isLabelVisible: unread > 0,
                        label: Text(
                          '$unread',
                          style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                              color: Colors.white),
                        ),
                        backgroundColor: const Color(0xFFDC2626),
                        child: const GoldenBellIcon(size: 22),
                      ),
                      onTap: () => openNotifications(
                        context,
                        ref,
                        onOpenEntity: openNotificationEntity,
                      ),
                    );
                  },
                );
              },
            ),
            // قائمة الخيارات الإضافية (⋮) — نقل الوضع الليلي، إخفاء الأرصدة، وتبديل الوردية
            Consumer(
              builder: (ctx, rref, _) {
                final isDark = Theme.of(ctx).brightness == Brightness.dark;
                final currentTheme = rref.watch(themeModeProvider);
                final darkActive = currentTheme == ThemeMode.dark ||
                    (currentTheme == ThemeMode.system && isDark);
                final hidden = rref.watch(hideBalancesProvider);

                return Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: PopupMenuButton<String>(
                    tooltip: 'خيارات إضافية',
                    icon: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.more_vert_rounded,
                        size: 20,
                        color: AppColors.textOf(ctx),
                      ),
                    ),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    onSelected: (val) {
                      if (val == 'theme') {
                        Sfx.tap();
                        rref.read(themeModeProvider.notifier).state =
                            darkActive ? ThemeMode.light : ThemeMode.dark;
                      } else if (val == 'balances') {
                        Sfx.tap();
                        rref.read(hideBalancesProvider.notifier).state = !hidden;
                      } else if (val == 'refresh') {
                        bump(ref);
                        _refreshSync();
                        try {
                          ref.read(syncEngineProvider).forceSyncNow();
                        } catch (_) {}
                        _checkForAppUpdate();
                      }
                    },
                    itemBuilder: (c) => [
                      PopupMenuItem(
                        value: 'theme',
                        child: Row(
                          children: [
                            Icon(
                              darkActive ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                              size: 19,
                              color: darkActive ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
                            ),
                            const SizedBox(width: 10),
                            Text(darkActive ? 'التبديل إلى الوضع النهاري' : 'التبديل إلى الوضع الليلي'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'balances',
                        child: Row(
                          children: [
                            Icon(
                              hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                              size: 19,
                              color: const Color(0xFF7C3AED),
                            ),
                            const SizedBox(width: 10),
                            Text(hidden ? 'إظهار الأرصدة' : 'إخفاء الأرصدة'),
                          ],
                        ),
                      ),
                      if (desktop) ...[
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: 'refresh',
                          child: Row(
                            children: [
                              Icon(Icons.refresh_rounded, size: 19, color: Color(0xFF16A34A)),
                              SizedBox(width: 10),
                              Text('تحديث والتحقق من الإصدار'),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ],
        ),
        drawer: _Drawer(current: _screen, onSelect: _go),
        // سطح المكتب (>900dp): شريط جانبي قابل للطي على يمين الشاشة (RTL)
        // بدل الشريط السفلي؛ الهاتف يبقى على الشريط السفلي كما هو.
        // 🔒 شريط الفترة التجريبية أعلى المحتوى (غير مزعج، يختفي ذاتياً).
        body: Column(
          children: [
            const TrialCountdownBanner(),
            Expanded(
              child: desktop
                  ? Row(
                      children: [
                        _desktopRail(),
                        Expanded(child: _body()),
                      ],
                    )
                  : _body(),
            ),
          ],
        ),
        floatingActionButton: _fab(),
        bottomNavigationBar: desktop
            ? null
            : _MarkedBottomBar(
                currentScreen: _screen,
                onSelect: (s) => _go(s),
              ),
      ),
    );
              },
            );
          },
        );
      },
    );
  }
}

/// شريط التنقل السفلي الحديث ذو الأيقونات المُعلّمة والمميّزة بصرياً
/// كما في هوية التطبيق (العملاء، الحركات، التقارير، الإعدادات).
class _MarkedBottomBar extends ConsumerWidget {
  final AppScreen currentScreen;
  final ValueChanged<AppScreen> onSelect;

  const _MarkedBottomBar({
    required this.currentScreen,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).valueOrNull;
    final isCashier = user?.role == UserRole.cashier;
    final navMode = ref.watch(navAppModeProvider);

    if (isCashier || navMode == NavAppMode.pos) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomPadding = MediaQuery.paddingOf(context).bottom;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
            width: 1,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.05),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      padding: EdgeInsets.only(
        top: 6,
        bottom: bottomPadding > 0 ? bottomPadding : 6,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _BottomItem(
            label: 'العملاء',
            tone: AppTone.blue,
            selected: currentScreen == AppScreen.accounts,
            icon: (sel, fg) => Icon(
              Icons.people_alt_rounded,
              color: fg,
              size: 21,
            ),
            onTap: () => onSelect(AppScreen.accounts),
          ),
          _BottomItem(
            label: 'الحركات',
            tone: AppTone.green,
            selected: currentScreen == AppScreen.transactions,
            icon: (sel, fg) => _MarkedReceiptIcon(selected: sel),
            onTap: () => onSelect(AppScreen.transactions),
          ),
          _BottomItem(
            label: 'التقارير',
            tone: AppTone.violet,
            selected: currentScreen == AppScreen.reports,
            icon: (sel, fg) => _MarkedBarChartIcon(selected: sel),
            onTap: () => onSelect(AppScreen.reports),
          ),
          _BottomItem(
            label: 'الإعدادات',
            tone: AppTone.teal,
            selected: currentScreen == AppScreen.settings,
            icon: (sel, fg) => _MarkedGearIcon(selected: sel),
            onTap: () => onSelect(AppScreen.settings),
          ),
        ],
      ),
    );
  }
}

class _BottomItem extends StatelessWidget {
  final String label;
  final bool selected;
  final AppTone tone;
  final Widget Function(bool selected, Color fg) icon;
  final VoidCallback onTap;

  const _BottomItem({
    required this.label,
    required this.selected,
    required this.tone,
    required this.icon,
    required this.onTap,
  });


  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final squircleBg = selected
        ? tone.foreground
        : (isDark ? tone.foreground.withValues(alpha: .22) : tone.background);
    final squircleFg = selected
        ? Colors.white
        : (isDark ? Colors.white : tone.foreground);

    return InkWell(
      onTap: () {
        Sfx.tap();
        onTap();
      },
      borderRadius: BorderRadius.circular(16),
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: selected ? 52 : 44,
              height: 34,
              decoration: BoxDecoration(
                color: squircleBg,
                borderRadius: BorderRadius.circular(14),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: tone.foreground.withValues(alpha: 0.35),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              alignment: Alignment.center,
              child: icon(selected, squircleFg),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected
                    ? (isDark ? Colors.white : tone.foreground)
                    : (isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B)),
                fontFamily: 'Tajawal',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// أيقونة الرسم البياني ثلاثية الأعمدة والملوّنة المميزة للتقارير (أخضر، أصفر، أزرق)
class _MarkedBarChartIcon extends StatelessWidget {
  final bool selected;
  const _MarkedBarChartIcon({required this.selected});


  @override
  Widget build(BuildContext context) {
    if (selected) {
      return const Icon(Icons.bar_chart_rounded, color: Colors.white, size: 22);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Container(
          width: 4,
          height: 12,
          decoration: BoxDecoration(
            color: const Color(0xFF22C55E),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 2.5),
        Container(
          width: 4,
          height: 20,
          decoration: BoxDecoration(
            color: const Color(0xFFF59E0B),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 2.5),
        Container(
          width: 4,
          height: 16,
          decoration: BoxDecoration(
            color: const Color(0xFF3B82F6),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ],
    );
  }
}

/// أيقونة الفاتورة / السند المميّزة بخطوط زرقاء للحركات
class _MarkedReceiptIcon extends StatelessWidget {
  final bool selected;
  const _MarkedReceiptIcon({required this.selected});


  @override
  Widget build(BuildContext context) {
    if (selected) {
      return const Icon(
        Icons.receipt_long_rounded,
        color: Colors.white,
        size: 21,
      );
    }
    return Container(
      width: 20,
      height: 22,
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFF38BDF8), width: 1.4),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 2.5, vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            height: 2,
            width: 14,
            decoration: BoxDecoration(
              color: const Color(0xFF0284C7),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          Container(
            height: 2,
            width: 9,
            decoration: BoxDecoration(
              color: const Color(0xFF38BDF8),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          Container(
            height: 2,
            width: 12,
            decoration: BoxDecoration(
              color: const Color(0xFF0284C7),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ),
    );
  }
}

/// أيقونة الترس المعدني للإعدادات
class _MarkedGearIcon extends StatelessWidget {
  final bool selected;
  const _MarkedGearIcon({required this.selected});


  @override
  Widget build(BuildContext context) {
    if (selected) {
      return const Icon(Icons.settings_rounded, color: Colors.white, size: 22);
    }
    return const Icon(
      Icons.settings_rounded,
      color: Color(0xFF64748B),
      size: 22,
    );
  }
}

/// زر العملية العائم المميّز بالتدرج الدائري كما في الصورة
class _MarkedOperationFab extends StatelessWidget {
  final VoidCallback? onPressed;
  const _MarkedOperationFab({required this.onPressed});


  @override
  Widget build(BuildContext context) {
    return Container(
      width: 58,
      height: 58,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [Color(0xFFFB923C), Color(0xFF0284C7)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0284C7).withValues(alpha: 0.4),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: const Color(0xFFFB923C).withValues(alpha: 0.25),
            blurRadius: 8,
            offset: const Offset(-2, -2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_rounded, color: Colors.white, size: 22),
              Text(
                'عملية',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  fontFamily: 'Tajawal',
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// عنصر واحد في الشريط الجانبي المكتبي — hover ناعم + تمييز واضح للمحدد.
class _RailTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool extended;
  final VoidCallback onTap;
  const _RailTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.extended,
    required this.onTap,
  });


  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final color = selected ? primary : AppColors.text2Of(context);
    final tile = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: HoverLift(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            color:
                selected ? primary.withValues(alpha: 0.1) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: color),
              if (extended) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return extended ? tile : Tooltip(message: label, child: tile);
  }
}

class _Drawer extends ConsumerWidget {
  final AppScreen current;
  final void Function(AppScreen) onSelect;
  const _Drawer({required this.current, required this.onSelect});

  /// المستخدم يحدد اسم جهازه بنفسه — يظهر أعلى القائمة الجانبية والرئيسية.
  Future<void> _renameSelf(
    BuildContext context,
    WidgetRef ref,
    String currentName,
  ) async {
    Sfx.click();
    final ctl = TextEditingController(
      text: currentName == 'مدير الحسابات' ? '' : currentName,
    );
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('اسمك / اسم هذا الجهاز'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(
            hintText: 'مثال: أحمد — فرع الجملة',
            helperText: 'يظهر أعلى الشاشة الرئيسية ولدى بقية أجهزة المجموعة',
            helperMaxLines: 2,
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      await ref.read(repoProvider).renameSelfDevice(name);
      // بثّ الاسم الجديد فوراً لكل الأقران (LAN + سحابة) — توحيد الهوية.
      try {
        await ref.read(syncEngineProvider).broadcastRosterChange();
      } catch (_) {}
      bump(ref);
      Sfx.pop();
    } catch (e) {
      if (context.mounted) showSnack(context, 'تعذّر الحفظ: $e', error: true);
    }
  }

  /// (3.70.0) قسم في الدرج: عنوان صغير بارز + بلاطات الشاشات المسموحة
  /// (تصفية الصلاحيات/الوضع من _DrawerItems + بوابة Google للمجموعة).
  List<Widget> _drawerSection(
    BuildContext context,
    String title,
    List<AppScreen> order,
    List<AppScreen> items,
    bool googleLinked,
    AppScreen current,
    bool dark,
    void Function(AppScreen) onSelect,
  ) {
    final visible = order
        .where(
          (s) => items.contains(s) && !(s == AppScreen.group && !googleLinked),
        )
        .toList();
    if (visible.isEmpty) return const [];
    return [
      Builder(
        builder: (ctx) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Text(
            title,
            style: TextStyle(
              color: AppColors.text3Of(ctx),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: .2,
            ),
          ),
        ),
      ),
      for (final s in visible)
        _DrawerTile(
          screen: s,
          active: current == s,
          color: _colorOf(s),
          dark: dark,
          onTap: () {
            Navigator.pop(context);
            scheduleMicrotask(() => onSelect(s));
          },
        ),
    ];
  }

  /// (2026-09-22) أيقونة المؤسسة: ملك للمؤسسة — المدير وحده يغيّرها أو
  /// يحذفها، والأعضاء يرونها بلا أي تحكم. تُخزَّن base64 في الإعدادات
  /// وتُصعَّد كعملية إعدادات متزامنة فتصل كل أجهزة المجموعة.
  Future<void> _manageOrgIcon(
    BuildContext context,
    WidgetRef ref,
    bool isOwner,
  ) async {
    if (!isOwner) {
      Sfx.tap();
      showSnack(context, 'أيقونة المؤسسة يحددها المدير — للعرض فقط');
      return;
    }
    Sfx.click();
    final repo = ref.read(repoProvider);
    var hasIcon = false;
    try {
      hasIcon = ((await repo.settings())['org.icon.b64'] ?? '').isNotEmpty;
    } catch (_) {}
    if (!context.mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('تغيير أيقونة المؤسسة'),
              subtitle: const Text('تظهر لكل أجهزة المجموعة'),
              onTap: () => Navigator.pop(ctx, 'change'),
            ),
            if (hasIcon)
              ListTile(
                leading: Icon(Icons.delete_outline,
                    color: AppColors.dangerOf(ctx)),
                title: const Text('حذف أيقونة المؤسسة'),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
            ListTile(
              leading: const Icon(Icons.close_rounded),
              title: const Text('إلغاء'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    try {
      if (action == 'delete') {
        await repo.setSyncedSetting('org.icon.b64', '');
        ref.invalidate(drawerPhotoProvider);
        bump(ref);
        Sfx.pop();
        if (context.mounted) showSnack(context, 'حُذفت أيقونة المؤسسة');
        return;
      }
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 256,
        maxHeight: 256,
        imageQuality: 80,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final b64 = base64Encode(bytes);
      // حد عملي: العملية تمر عبر السحابة — صورة صغيرة تكفي للأيقونة.
      if (b64.length > 400000) {
        if (context.mounted) {
          showSnack(context, 'الصورة أكبر من اللازم — اختر صورة أصغر',
              error: true);
        }
        return;
      }
      await repo.setSyncedSetting('org.icon.b64', b64);
      ref.invalidate(drawerPhotoProvider);
      bump(ref);
      Sfx.pop();
      if (context.mounted) {
        showSnack(context, '✅ حُدّثت أيقونة المؤسسة لكل المجموعة');
      }
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر تحديث الأيقونة: $e', error: true);
      }
    }
  }

  /// لون مميز لكل قسم (كما في التصميم المرجعي).
  Color _colorOf(AppScreen s) => switch (s) {
        AppScreen.dashboard => const Color(0xFF2563EB),
        AppScreen.transactions => const Color(0xFF0EA5E9),
        AppScreen.accounts => const Color(0xFF2563EB),
        AppScreen.reports => const Color(0xFF6366F1),
        AppScreen.settings => const Color(0xFF64748B),
        AppScreen.inventory => const Color(0xFF8B5CF6),
        AppScreen.currencies => AppColors.primary2,
        AppScreen.vouchers => const Color(0xFFF59E0B),
        AppScreen.pos => const Color(0xFF16A34A),
        AppScreen.chat => const Color(0xFF22C55E),
        AppScreen.group => const Color(0xFF8B5CF6),
        AppScreen.trash => const Color(0xFFE11D48),
        AppScreen.activity => const Color(0xFF64748B),
        AppScreen.backup => AppColors.primary2,
        AppScreen.syncOps => const Color(0xFF0284C7),
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).valueOrNull;
    final wsMode = ref.watch(workspaceModeProvider).valueOrNull ?? 'standalone';
    final isOwnerAsync = ref.watch(isOwnerProvider).valueOrNull;
    final isOwner = (wsMode == 'member') ? false : (isOwnerAsync ?? true);
    final roleAsync = ref.watch(deviceRoleProvider);
    final role = roleAsync.valueOrNull;
    final navMode = ref.watch(navAppModeProvider);

    final rawRole = user?.role ?? role?.role;
    // حماية سيادية: مالك المنشأة على جهازه هو دائماً وأبداً مدير النظام!
    final effectiveRole = isOwner
        ? UserRole.admin
        : ((rawRole == UserRole.admin)
            ? UserRole.cashier
            : (rawRole ?? UserRole.cashier));
    final isMasterAdmin = (wsMode == 'member')
        ? false
        : (isOwner || effectiveRole == UserRole.admin || effectiveRole == UserRole.agent);

    // (3.70.0) «إدارة المجموعة» مشروطة بحساب Google موثّق (جدول google_auth).
    final googleLinked = ref.watch(googleLinkedProvider).valueOrNull ?? false;
    final items = _DrawerItems.of(
      user: user,
      isOwner: isOwner,
      workspaceMode: (wsMode == 'standalone' && googleLinked) ? 'host' : wsMode,
    );
    final dark = Theme.of(context).brightness == Brightness.dark;

    final (roleLabel, roleColor, roleIcon) = switch (effectiveRole) {
      UserRole.admin => ('مدير النظام', Colors.amber.shade300, Icons.security),
      UserRole.agent => ('وكيل المدير', Colors.greenAccent.shade200, Icons.verified_user),
      UserRole.accountant => ('محاسب', Colors.lightBlueAccent, Icons.calculate),
      UserRole.cashier => ('كاشير / مبيعات', Colors.orangeAccent.shade200, Icons.point_of_sale),
      UserRole.dataentry => ('إدخال وجرد', Colors.tealAccent, Icons.edit_note),
      UserRole.viewer => ('عرض فقط', Colors.blueGrey.shade100, Icons.visibility_outlined),
    };

    return Drawer(
      backgroundColor: AppColors.surfaceOf(context),
      child: SafeArea(
        child: Column(
          children: [
            // ---------- ترويسة الملف الشخصي والمنشأة ----------
            InkWell(
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(22),
                bottomRight: Radius.circular(22),
              ),
              onTap: () => showAccountProfileDialog(context, ref),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF1E3A5F), AppColors.primary],
                  ),
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(22),
                    bottomRight: Radius.circular(22),
                  ),
                ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // (2026-09-22) أيقونة المؤسسة: المدير يغيّرها/يحذفها،
                      // والعضو يراها فقط للقراءة بلا إمكانية للتعديل.
                      Consumer(
                        builder: (ctx, rref, _) {
                          final photo =
                              rref.watch(drawerPhotoProvider).valueOrNull ?? '';
                          const fallback = Icon(
                            Icons.person,
                            color: Colors.white,
                            size: 30,
                          );
                          final Widget face = photo.startsWith('http')
                              ? Image.network(
                                  photo,
                                  width: 54,
                                  height: 54,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => fallback,
                                )
                              : (photo.isNotEmpty
                                  ? Image.file(
                                      File(photo),
                                      width: 54,
                                      height: 54,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => fallback,
                                    )
                                  : fallback);
                          final avatarContainer = Container(
                            width: 54,
                            height: 54,
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white38,
                                width: 2,
                              ),
                            ),
                            child: ClipOval(child: face),
                          );
                          if (!isMasterAdmin) return avatarContainer;
                          return InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => _manageOrgIcon(ctx, rref, isOwner),
                            child: avatarContainer,
                          );
                        },
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // اسم المستخدم / الجهاز المحدد
                            Consumer(
                              builder: (ctx, rref, _) {
                                final devName = rref
                                    .watch(ownDeviceNameProvider)
                                    .valueOrNull
                                    ?.trim();
                                final label = (user?.name != null && user!.name.isNotEmpty)
                                    ? user.name
                                    : ((devName != null && devName.isNotEmpty)
                                        ? devName
                                        : 'مدير الحسابات');
                                return Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        label,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 16,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (isMasterAdmin) ...[
                                      const SizedBox(width: 6),
                                      InkWell(
                                        borderRadius: BorderRadius.circular(12),
                                        onTap: () =>
                                            _renameSelf(ctx, rref, label),
                                        child: const Padding(
                                          padding: EdgeInsets.all(3),
                                          child: Icon(
                                            Icons.edit_outlined,
                                            size: 15,
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                );
                              },
                            ),
                            const SizedBox(height: 4),
                            // شارة الدور المنقولة حصرياً لرأس القائمة الجانبية بجوار الاسم
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: roleColor.withValues(alpha: .22),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: roleColor.withValues(alpha: .4)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(roleIcon, size: 12, color: roleColor),
                                  const SizedBox(width: 4),
                                  Text(
                                    roleLabel,
                                    style: TextStyle(
                                      color: roleColor,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // بيانات المنشأة — محمية وغير قابلة للتعديل لغير المدير العام
                            Consumer(
                              builder: (ctx, rref, _) {
                                final st =
                                    rref.watch(settingsProvider).valueOrNull ??
                                        const <String, String>{};
                                final email = googleLinked
                                    ? (st['account.email'] ?? '').trim()
                                    : '';
                                final biz = (st['businessName'] ?? '').trim();
                                if (email.isEmpty && biz.isEmpty) {
                                  return Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          wsMode == 'member'
                                              ? Icons.groups_rounded
                                              : Icons.cloud_sync_rounded,
                                          size: 13,
                                          color: Colors.white70,
                                        ),
                                        const SizedBox(width: 4),
                                        Flexible(
                                          child: Text(
                                            wsMode == 'member'
                                                ? 'جهاز عضو مرتبط بالمجموعة'
                                                : 'اضغط لتسجيل الدخول بـ Google أو ربط الأعضاء',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }
                                return Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (biz.isNotEmpty)
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                biz,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                            if (isMasterAdmin) ...[
                                              const SizedBox(width: 4),
                                              InkWell(
                                                onTap: () => showAccountProfileDialog(context, ref),
                                                child: const Icon(Icons.edit_outlined, size: 13, color: Colors.white70),
                                              ),
                                            ],
                                          ],
                                        ),
                                      if (email.isNotEmpty)
                                        Text(
                                          email,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 10.5,
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            ),

            // ---------- مفتاح كبسولي للتبديل بين وضع المبيعات ووضع المحاسبة ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: dark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: dark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () {
                          ref.read(navAppModeProvider.notifier).setMode(NavAppMode.pos);
                          if (current != AppScreen.pos &&
                              current != AppScreen.inventory &&
                              current != AppScreen.transactions) {
                            scheduleMicrotask(() => onSelect(AppScreen.pos));
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: navMode == NavAppMode.pos
                                ? const Color(0xFF0284C7)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(18),
                            boxShadow: navMode == NavAppMode.pos
                                ? [
                                    BoxShadow(
                                      color: const Color(0xFF0284C7).withValues(alpha: .3),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ]
                                : null,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.point_of_sale_rounded,
                                size: 16,
                                color: navMode == NavAppMode.pos
                                    ? Colors.white
                                    : AppColors.text2Of(context),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'وضع المبيعات (POS)',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.bold,
                                    color: navMode == NavAppMode.pos
                                        ? Colors.white
                                        : AppColors.text2Of(context),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () {
                          if (effectiveRole == UserRole.cashier) {
                            showSnack(context, 'وضع الدفاتر مقيد ويتطلب حساب المحاسب أو المدير', error: true);
                            return;
                          }
                          ref.read(navAppModeProvider.notifier).setMode(NavAppMode.ledger);
                          if (current != AppScreen.accounts &&
                              current != AppScreen.vouchers &&
                              current != AppScreen.currencies &&
                              current != AppScreen.reports) {
                            scheduleMicrotask(() => onSelect(AppScreen.accounts));
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: navMode == NavAppMode.ledger
                                ? const Color(0xFF0F766E)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(18),
                            boxShadow: navMode == NavAppMode.ledger
                                ? [
                                    BoxShadow(
                                      color: const Color(0xFF0F766E).withValues(alpha: .3),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ]
                                : null,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.account_balance_wallet_rounded,
                                size: 16,
                                color: navMode == NavAppMode.ledger
                                    ? Colors.white
                                    : AppColors.text2Of(context),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'وضع المحاسبة',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.bold,
                                    color: navMode == NavAppMode.ledger
                                        ? Colors.white
                                        : AppColors.text2Of(context),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ---------- عناصر القائمة حسب الوضع النشط ----------
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                children: [
                  if (navMode == NavAppMode.pos) ...[
                    // وضع المبيعات: نقطة البيع، إدارة المنتجات، وسجل العمليات/الفواتير فقط
                    ..._drawerSection(
                      context,
                      'المبيعات والمنتجات',
                      const [
                        AppScreen.pos,
                        AppScreen.inventory,
                        AppScreen.transactions,
                      ],
                      items,
                      googleLinked,
                      current,
                      dark,
                      onSelect,
                    ),
                  ] else ...[
                    // وضع المحاسبة: الحسابات، السندات، العملات، والتقارير فقط
                    ..._drawerSection(
                      context,
                      'الدفاتر والمحاسبة',
                      const [
                        AppScreen.accounts,
                        AppScreen.vouchers,
                        AppScreen.currencies,
                        AppScreen.reports,
                      ],
                      items,
                      googleLinked,
                      current,
                      dark,
                      onSelect,
                    ),
                  ],
                  // العناصر الثابتة في كلا الوضعين
                  ..._drawerSection(
                    context,
                    'المنشأة والنظام',
                    const [
                      AppScreen.group,
                      AppScreen.backup,
                      AppScreen.trash,
                      AppScreen.activity,
                      AppScreen.settings,
                    ],
                    items,
                    googleLinked,
                    current,
                    dark,
                    onSelect,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // ---------- التحديثات (الإصدار وسجل التغييرات 3 أسطر) ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Consumer(
                builder: (ctx, rref, _) {
                  final updateAsync = rref.watch(updateCheckProvider);
                  final info = updateAsync.valueOrNull;
                  final hasUpdate = info?.hasUpdate ?? false;
                  return Material(
                    color: hasUpdate
                        ? const Color(0xFFFEF3C7)
                        : AppColors.surface2Of(context),
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () {
                        Navigator.pop(context);
                        showModalBottomSheet(
                          context: context,
                          isScrollControlled: true,
                          backgroundColor: Colors.transparent,
                          builder: (_) => DraggableScrollableSheet(
                            initialChildSize: .7,
                            minChildSize: .4,
                            maxChildSize: .9,
                            builder: (c, s) => SingleChildScrollView(
                              controller: s,
                              child: const Padding(
                                padding: EdgeInsets.all(16),
                                child: UpdateSection(),
                              ),
                            ),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: hasUpdate
                                    ? const Color(0xFFF59E0B)
                                    : AppColors.primary.withValues(alpha: .14),
                                borderRadius: BorderRadius.circular(11),
                              ),
                              child: Icon(
                                hasUpdate
                                    ? Icons.system_update_rounded
                                    : Icons.system_update_alt_rounded,
                                color: hasUpdate ? Colors.white : AppColors.primary,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'التحديثات',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13.5,
                                    ),
                                  ),
                                  Text(
                                    hasUpdate
                                        ? 'يتوفر تحديث جديد: ${info?.latest}'
                                        : 'الإصدار $appVersionLabel (محدث)',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: hasUpdate
                                          ? const Color(0xFFB45309)
                                          : AppColors.text3Of(context),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (hasUpdate)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF59E0B),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Text(
                                  'تحديث',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                appVersionLabel,
                style: TextStyle(
                  fontSize: 10.5,
                  color: AppColors.text3Of(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// صف عنصر في القائمة الجانبية بتصميم البطاقة النشطة.
class _DrawerTile extends StatelessWidget {
  final AppScreen screen;
  final bool active;
  final Color color;
  final bool dark;
  final VoidCallback onTap;
  const _DrawerTile({
    required this.screen,
    required this.active,
    required this.color,
    required this.dark,
    required this.onTap,
  });


  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: active ? AppColors.infoSoftOf(context) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: active
                  ? Border.all(color: AppColors.infoOf(context), width: 1.4)
                  : null,
            ),
            child: Row(
              children: [
                // أيقونة الدردشة تحمل شارة عدد الرسائل غير المقروءة —
                // المكان الرسمي لإشعار الرسائل داخل التطبيق.
                if (screen == AppScreen.chat)
                  Consumer(
                    builder: (ctx, rref, _) {
                      final n = rref.watch(unreadChatProvider).valueOrNull ?? 0;
                      return Badge(
                        isLabelVisible: n > 0,
                        label: Text('$n'),
                        child: Icon(
                          active ? screen.activeIcon : screen.icon,
                          color: active ? AppColors.infoOf(context) : color,
                          size: 22,
                        ),
                      );
                    },
                  )
                else
                  Icon(
                    active ? screen.activeIcon : screen.icon,
                    color: active ? AppColors.infoOf(context) : color,
                    size: 22,
                  ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    screen.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: active ? FontWeight.w800 : FontWeight.w700,
                      color: active
                          ? AppColors.infoOf(context)
                          : AppColors.textOf(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// عناصر الدرج: كل الشاشات ما عدا الموجودة في الشريط السفلي، حتى لا تتكرر
/// الأيقونة نفسها في مكانين. إدارة المجموعة للمدير فقط.
class DrawerItems {
  static List<AppScreen> of({
    AppUser? user,
    required bool isOwner,
    String workspaceMode = 'standalone',
  }) =>
      AppScreen.values.where((s) {
        // (3.70.0) لوحة التحكم لم تعد عنصر قائمة — هي الشاشة الرئيسية
        // الثابتة عند الإقلاع وبعد القفل (تُفتح من زر الرئيسية/الشعار).
        if (s == AppScreen.dashboard) {
          return false;
        }
        final standalone = workspaceMode == 'standalone';
        // العزل الكامل للوضع المستقل: لا دردشة — الجهاز الفردي لا يرى
        // أي أثر للشبكات. الترقية من الإعدادات.
        if (standalone && s == AppScreen.chat) {
          return false;
        }
        // التحقق من الصلاحيات يعتمد حصراً على المستخدم الفعلي بالجلسة والمالك
        final isAdmin = user?.role == UserRole.admin ||
            user?.role == UserRole.agent ||
            (isOwner &&
                user?.role != UserRole.cashier &&
                user?.role != UserRole.viewer);
        final isAccountant = user?.role == UserRole.accountant;
        bool can(String p) => isAdmin || (user?.can(p) ?? false);

        // إدارة المجموعة للمنشآت (وضع المضيف) فقط وتُحجب عن الحساب الفردي المستقل
        if (s == AppScreen.group) {
          if (standalone) return false;
          return isAdmin && (isOwner || workspaceMode == 'host');
        }
        // قسم العمليات والمزامنة يُفتح من أيقونة المزامنة أعلى الشاشة فقط.
        if (s == AppScreen.syncOps) return false;
        // التقارير تتطلب صلاحية عرض التقارير.
        if (s == AppScreen.reports) return can('view_reports');
        // (3.70) الأصناف: إدارة المخزون للمدير/الوكيل/المحاسب/الإدخال —
        // تُحجب عن الكاشير (بلا صلاحية تعديل) فوراً ودون شبكة.
        if (s == AppScreen.inventory) return can('edit_tx');
        // النسخ الاحتياطي محظور ومحجوب تماماً عن أجهزة الأعضاء داخل المجموعة
        if (s == AppScreen.backup) {
          if (workspaceMode == 'member') return false;
          return can('manage_backup');
        }
        // سلة المهملات: الاسترجاع والحذف النهائي شأن من يملك حذف العمليات.
        if (s == AppScreen.trash) return can('delete_tx');
        // ══ بقية الأيقونات حسب صلاحية المستخدم حرفياً ══
        // نقطة البيع لمن يضيف عمليات.
        if (s == AppScreen.pos) return can('add_tx');
        // العملاء: للمدير أو المحاسب أو من يملك تعديل العمليات (محجوبة عن الكاشير).
        if (s == AppScreen.accounts) {
          return isAdmin || isAccountant || can('edit_tx');
        }
        // العمليات: شاشة عمل — للمدير أو المحاسب أو من يملك تعديل العمليات.
        if (s == AppScreen.transactions) {
          return isAdmin || isAccountant || can('edit_tx');
        }
        // السندات: للمدير أو المحاسب أو من ينشئ عمليات ويملك اعتماد السندات.
        if (s == AppScreen.vouchers) {
          return isAdmin || isAccountant || can('approve_vouchers');
        }
        // العملات: إعداد مالي للمدير أو المحاسب فقط.
        if (s == AppScreen.currencies) return isAdmin || isAccountant;
        // سجل النشاط: اطلاع تدقيقي — تقارير أو حذف.
        if (s == AppScreen.activity) {
          return can('view_reports') || can('delete_tx');
        }
        // الإعدادات: للمدير العام والوكيل فقط.
        if (s == AppScreen.settings) {
          return isAdmin;
        }
        return true;
      }).toList();
}

typedef _DrawerItems = DrawerItems;

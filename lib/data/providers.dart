import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/media_paths.dart';
import '../core/models.dart';
import '../core/rbac.dart';
import 'repository.dart';
import 'sync/device_id.dart';
import 'sync/google_auth_service.dart';
import 'device_license.dart';
import 'sync/subscription_guard.dart';
import 'sync/sync_engine.dart';
import 'sync/sync_queue.dart';
import '../core/cloud_config.dart';

/// Repo واحدة ومُهيّأة مسبقًا تُحقن عبر ProviderScope.override في main.
/// لا ننشئ نسخة جديدة هنا لضمان أن initSyncInfra() استُدعيت مرة واحدة.
/// (3.70) مفتاح الملاحة العام — مسارات الخروج المؤمَّن وطلبات الخروج
/// تعمل عبره حتى بعد إغلاق الدرج الجانبي.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

final repoProvider = Provider<Repo>(
  (ref) => throw StateError('repoProvider must be overridden in ProviderScope'),
);

final syncEngineProvider = Provider<SyncEngine>(
  (ref) => throw StateError(
    'syncEngineProvider must be overridden in ProviderScope',
  ),
);

final googleAuthProvider = FutureProvider<GoogleUser?>((ref) async {
  ref.watch(refreshProvider);
  final repo = ref.read(repoProvider);
  final db = await repo.database;
  return GoogleAuthService(db).currentUserFromDb();
});

/// عدّاد يُزاد بعد كل تعديل ليُعيد بناء كل ما يعتمد على البيانات.
final refreshProvider = StateProvider<int>((ref) => 0);

void bump(WidgetRef ref) => ref.read(refreshProvider.notifier).state++;

/// الإعدادات كخريطة مفتاح/قيمة — تقابل settings() في نسخة الويب.
final settingsProvider = FutureProvider<Map<String, String>>((ref) async {
  ref.watch(refreshProvider);
  // مهلة قصوى حتى لا يعلق المزود للأبد في أي حالة.
  return ref
      .read(repoProvider)
      .settings()
      .timeout(const Duration(seconds: 8), onTimeout: () => <String, String>{});
});

/// وضع السمة.
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

/// إخفاء الأرصدة.
final hideBalancesProvider = StateProvider<bool>((ref) => false);

/// وضع واجهة التطبيق والقائمة الجانبية (المبيعات / المحاسبة).
enum NavAppMode {
  pos, // وضع المبيعات
  ledger, // وضع المحاسبة
}

class NavAppModeNotifier extends StateNotifier<NavAppMode> {
  NavAppModeNotifier() : super(NavAppMode.ledger) {
    _load();
  }

  static const _prefKey = 'app_nav_mode';

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final val = sp.getString(_prefKey);
      if (val == 'ledger') {
        state = NavAppMode.ledger;
      } else if (val == 'pos') {
        state = NavAppMode.pos;
      }
    } catch (_) {}
  }

  Future<void> setMode(NavAppMode mode) async {
    state = mode;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_prefKey, mode == NavAppMode.ledger ? 'ledger' : 'pos');
    } catch (_) {}
  }
}

final navAppModeProvider =
    StateNotifierProvider<NavAppModeNotifier, NavAppMode>((ref) {
  return NavAppModeNotifier();
});

/// العملات المعرَّفة.
final currenciesProvider = FutureProvider<List<CurrencyDef>>((ref) async {
  ref.watch(refreshProvider);
  return ref
      .read(repoProvider)
      .currencies()
      .timeout(const Duration(seconds: 8), onTimeout: () => kDefaultCurrencies);
});

/// فلاتر شاشة الحسابات.
class AccountFilter {
  final String query;
  final AccountKind? kind;
  final String? currency;
  final bool showArchived;
  const AccountFilter({
    this.query = '',
    this.kind,
    this.currency,
    this.showArchived = false,
  });

  AccountFilter copyWith({
    String? query,
    AccountKind? kind,
    bool clearKind = false,
    String? currency,
    bool clearCurrency = false,
    bool? showArchived,
  }) => AccountFilter(
    query: query ?? this.query,
    kind: clearKind ? null : (kind ?? this.kind),
    currency: clearCurrency ? null : (currency ?? this.currency),
    showArchived: showArchived ?? this.showArchived,
  );
}

final accountFilterProvider = StateProvider<AccountFilter>(
  (ref) => const AccountFilter(),
);

/// الحسابات مع أرصدتها، مطبَّقًا عليها الفلتر.
final accountsProvider = FutureProvider<List<AccountWithBalance>>((ref) async {
  ref.watch(refreshProvider);
  final f = ref.watch(accountFilterProvider);
  final repo = ref.read(repoProvider);

  final all = await repo.accounts(includeArchived: f.showArchived);
  final balances = await repo.allBalances(all);

  final q = f.query.trim();
  final numericQ = q.isNotEmpty && Fmt.isNumericQuery(q);
  final out = <AccountWithBalance>[];
  for (final a in all) {
    if (f.showArchived && !a.archived) continue;
    if (f.kind != null && a.kind != f.kind) continue;
    if (f.currency != null && a.currency != f.currency) continue;
    if (q.isNotEmpty) {
      // بحث ذكي: الاستعلام الرقمي يستهدف الهاتف/المبالغ؛ والنصي يمر
      // بتطبيع عربي (تجاهل التشكيل، أ/إ/آ→ا، ة→ه، ى→ي).
      final hay = numericQ
          ? '${a.phone} ${a.whatsapp} '
                '${balances[a.id]?.abs().toStringAsFixed(0) ?? ''}'
          : '${a.name} ${a.phone} ${a.whatsapp} ${a.notes} '
                '${a.tags.join(' ')}';
      if (!Fmt.smartContains(hay, q)) continue;
    }
    out.add(AccountWithBalance(a, balances[a.id] ?? a.openingBalance));
  }
  return out;
});

/// كل الحسابات بلا فلتر — للقوائم المنسدلة.
final allAccountsProvider = FutureProvider<List<Account>>((ref) async {
  ref.watch(refreshProvider);
  return ref
      .read(repoProvider)
      .accounts()
      .timeout(const Duration(seconds: 8), onTimeout: () => []);
});

/// ملخّص لوحة التحكم.
class Summary {
  /// مستحق لنا (أرصدة موجبة) لكل عملة.
  final Map<String, double> owedToUs;

  /// مستحق علينا (أرصدة سالبة) لكل عملة.
  final Map<String, double> owedByUs;
  final Map<String, double> net;
  final double inflow;
  final double outflow;
  final int accountsCount;
  final int txCount;

  const Summary({
    required this.owedToUs,
    required this.owedByUs,
    required this.net,
    required this.inflow,
    required this.outflow,
    required this.accountsCount,
    required this.txCount,
  });
}

/// ملخّص مالي — الأرصدة لا تُخلط بين العملات أبدًا.
final summaryProvider = FutureProvider<Summary>((ref) async {
  ref.watch(refreshProvider);
  final repo = ref.read(repoProvider);
  List<Account> accounts = const [];
  List<Tx> txs = const [];
  Map<int, double> balances = const {};
  try {
    accounts = await repo.accounts().timeout(const Duration(seconds: 6));
    balances = await repo
        .allBalances(accounts)
        .timeout(const Duration(seconds: 6));
    txs = await repo.transactions().timeout(const Duration(seconds: 6));
  } catch (_) {}

  final toUs = <String, double>{};
  final byUs = <String, double>{};
  final net = <String, double>{};

  for (final a in accounts) {
    final b = balances[a.id] ?? 0;
    net[a.currency] = (net[a.currency] ?? 0) + b;
    if (b > 0) {
      toUs[a.currency] = (toUs[a.currency] ?? 0) + b;
    } else if (b < 0) {
      byUs[a.currency] = (byUs[a.currency] ?? 0) + b.abs();
    }
  }

  var inflow = 0.0;
  var outflow = 0.0;
  for (final t in txs) {
    final g = opGroup(t.type);
    if (g == 'inflow') inflow += t.amount;
    if (g == 'outflow') outflow += t.amount;
  }

  return Summary(
    owedToUs: toUs,
    owedByUs: byUs,
    net: net,
    inflow: inflow,
    outflow: outflow,
    accountsCount: accounts.length,
    txCount: txs.length,
  );
});

/// آخر العمليات.
final recentTxProvider = FutureProvider<List<Tx>>((ref) async {
  ref.watch(refreshProvider);
  final all = await ref.read(repoProvider).transactions();
  return all.take(12).toList();
});

/// عمليات حساب بعينه.
final accountTxProvider = FutureProvider.family<List<Tx>, int>((ref, id) async {
  ref.watch(refreshProvider);
  return ref
      .read(repoProvider)
      .transactions(accountId: id)
      .timeout(const Duration(seconds: 8), onTimeout: () => []);
});

/// عدد عمليات كل حساب.
final accountTxCountsProvider = FutureProvider<Map<int, int>>((ref) async {
  ref.watch(refreshProvider);
  final repo = ref.read(repoProvider);
  final txs = await repo.transactions().timeout(
    const Duration(seconds: 8),
    onTimeout: () => [],
  );
  final map = <int, int>{};
  for (final tx in txs) {
    if (tx.accountId != null) {
      map[tx.accountId!] = (map[tx.accountId!] ?? 0) + 1;
    }
  }
  return map;
});

/// تنبيهات: تجاوز الحد الائتماني.
final alertsProvider = FutureProvider<List<AccountWithBalance>>((ref) async {
  ref.watch(refreshProvider);
  final repo = ref.read(repoProvider);
  final accounts = await repo.accounts();
  final balances = await repo.allBalances(accounts);
  return accounts
      .map((a) => AccountWithBalance(a, balances[a.id] ?? 0))
      .where((x) => x.overLimit)
      .toList();
});

/// الإشعارات الداخلية (الأحدث أولًا).
final notificationsProvider = FutureProvider<List<Map<String, Object?>>>((
  ref,
) async {
  ref.watch(refreshProvider);
  return ref
      .read(repoProvider)
      .notifications()
      .timeout(const Duration(seconds: 8), onTimeout: () => const []);
});

/// عدد الإشعارات غير المقروءة (للشارة في الشريط العلوي).
final unreadCountProvider = FutureProvider<int>((ref) async {
  ref.watch(refreshProvider);
  return ref
      .read(repoProvider)
      .unreadNotifications()
      .timeout(const Duration(seconds: 8), onTimeout: () => 0);
});

/// عدد رسائل الدردشة غير المقروءة (شارة أيقونة الدردشة) —
/// المكان الرسمي الوحيد لعدّ رسائل الدردشة (لا تدخل جدول الإشعارات).
final unreadChatProvider = FutureProvider<int>((ref) async {
  ref.watch(refreshProvider);
  return ref
      .read(repoProvider)
      .unreadChatMessages()
      .timeout(const Duration(seconds: 8), onTimeout: () => 0);
});

/// سجل النشاط.
final activityProvider = FutureProvider<List<Map<String, Object?>>>((
  ref,
) async {
  ref.watch(refreshProvider);
  return ref
      .read(repoProvider)
      .recentActivity()
      .timeout(const Duration(seconds: 8), onTimeout: () => const []);
});

// ==================== تصفية العمليات ====================

/// معايير تصفية شاشة العمليات — مطابقة لأشرطة الأدوات في نسخة الويب.
class TxFilter {
  final String query;
  final OpType? type;
  final int? accountId;
  final String? currency;
  final DateTime? from;
  final DateTime? to;
  final TxSort sort;

  const TxFilter({
    this.query = '',
    this.type,
    this.accountId,
    this.currency,
    this.from,
    this.to,
    this.sort = TxSort.newest,
  });

  TxFilter copyWith({
    String? query,
    OpType? type,
    int? accountId,
    String? currency,
    DateTime? from,
    DateTime? to,
    TxSort? sort,
    bool clearType = false,
    bool clearAccount = false,
    bool clearCurrency = false,
    bool clearFrom = false,
    bool clearTo = false,
  }) => TxFilter(
    query: query ?? this.query,
    type: clearType ? null : (type ?? this.type),
    accountId: clearAccount ? null : (accountId ?? this.accountId),
    currency: clearCurrency ? null : (currency ?? this.currency),
    from: clearFrom ? null : (from ?? this.from),
    to: clearTo ? null : (to ?? this.to),
    sort: sort ?? this.sort,
  );

  /// هل هناك أي مرشّح فعّال غير الترتيب؟
  bool get isActive =>
      query.isNotEmpty ||
      type != null ||
      accountId != null ||
      currency != null ||
      from != null ||
      to != null;
}

enum TxSort {
  newest('الأحدث أولاً'),
  amount('الأكبر مبلغًا'),
  account('بالحساب');

  const TxSort(this.label);
  final String label;
}

final txFilterProvider = StateProvider<TxFilter>((ref) => const TxFilter());

/// نتيجة شاشة العمليات: العمليات المصفّاة + خريطة أسماء الحسابات + الإجماليات.
class TxPage {
  final List<Tx> items;
  final Map<int, Account> accounts;
  final Map<String, double> inflowByCurrency;
  final Map<String, double> outflowByCurrency;

  const TxPage({
    required this.items,
    required this.accounts,
    required this.inflowByCurrency,
    required this.outflowByCurrency,
  });
}

final txPageProvider = FutureProvider<TxPage>((ref) async {
  ref.watch(refreshProvider);
  final f = ref.watch(txFilterProvider);
  final repo = ref.watch(repoProvider);

  final all = await repo.transactions(
    accountId: f.accountId,
    from: f.from,
    to: f.to,
    type: f.type,
  );
  final accs = await repo.accounts(includeArchived: true);
  final byId = {for (final a in accs) a.id!: a};

  final q = f.query.trim();
  final numericQ = q.isNotEmpty && Fmt.isNumericQuery(q);
  var list = all.where((t) {
    if (f.currency != null && t.currency != f.currency) return false;
    if (q.isEmpty) return true;
    final accName = t.type == OpType.transfer
        ? 'تحويل'
        : (byId[t.accountId]?.name ?? '');
    // الاستعلام الرقمي يبحث في المرجع والمبلغ أيضاً؛ النصي بتطبيع عربي.
    final hay = numericQ
        ? '${t.reference} ${t.amount.toStringAsFixed(0)} ${t.description}'
        : '${t.description} ${t.reference} $accName ${t.notes}';
    return Fmt.smartContains(hay, q);
  }).toList();

  switch (f.sort) {
    case TxSort.amount:
      list.sort((a, b) => b.amount.compareTo(a.amount));
    case TxSort.account:
      list.sort(
        (a, b) => (byId[a.accountId]?.name ?? '').compareTo(
          byId[b.accountId]?.name ?? '',
        ),
      );
    case TxSort.newest:
      list.sort((a, b) => b.date.compareTo(a.date));
  }

  // إجماليات الداخل والخارج لكل عملة على المجموعة المعروضة.
  final inflow = <String, double>{};
  final outflow = <String, double>{};
  for (final t in list) {
    final g = opGroup(t.type);
    if (g == 'inflow') {
      inflow[t.currency] = (inflow[t.currency] ?? 0) + t.amount;
    } else if (g == 'outflow') {
      outflow[t.currency] = (outflow[t.currency] ?? 0) + t.amount;
    }
  }

  return TxPage(
    items: list,
    accounts: byId,
    inflowByCurrency: inflow,
    outflowByCurrency: outflow,
  );
});

// ==================== السندات ====================

class VoucherFilter {
  final String query;
  final VoucherKind? kind;
  final String? status;
  const VoucherFilter({this.query = '', this.kind, this.status});

  VoucherFilter copyWith({
    String? query,
    VoucherKind? kind,
    String? status,
    bool clearKind = false,
    bool clearStatus = false,
  }) => VoucherFilter(
    query: query ?? this.query,
    kind: clearKind ? null : (kind ?? this.kind),
    status: clearStatus ? null : (status ?? this.status),
  );
}

final voucherFilterProvider = StateProvider<VoucherFilter>(
  (ref) => const VoucherFilter(),
);

final vouchersProvider = FutureProvider<List<Voucher>>((ref) async {
  ref.watch(refreshProvider);
  final f = ref.watch(voucherFilterProvider);
  final repo = ref.watch(repoProvider);
  final list = await repo.vouchers(kind: f.kind, status: f.status);
  final accs = await repo.accounts(includeArchived: true);
  final byId = {for (final a in accs) a.id!: a};
  final q = f.query.trim().toLowerCase();
  if (q.isEmpty) return list;
  return list.where((v) {
    final name = byId[v.accountId]?.name ?? '';
    return '${v.number} $name ${v.statement}'.toLowerCase().contains(q);
  }).toList();
});

// ==================== المستخدمون ====================

final usersProvider = FutureProvider<List<AppUser>>((ref) async {
  ref.watch(refreshProvider);
  return ref
      .watch(repoProvider)
      .users()
      .timeout(const Duration(seconds: 8), onTimeout: () => []);
});

final currentUserProvider = FutureProvider<AppUser?>((ref) async {
  ref.watch(refreshProvider);
  return ref
      .watch(repoProvider)
      .currentUser()
      .timeout(const Duration(seconds: 8), onTimeout: () => null);
});

// ==================== التقارير ====================

/// نطاق التقرير: الفترة والعملة والحساب.
class ReportScope {
  final DateTime from;
  final DateTime to;
  final String? currency;
  final int? accountId;
  final String? cashier;

  const ReportScope({
    required this.from,
    required this.to,
    this.currency,
    this.accountId,
    this.cashier,
  });

  ReportScope copyWith({
    DateTime? from,
    DateTime? to,
    String? currency,
    int? accountId,
    String? cashier,
    bool clearCurrency = false,
    bool clearAccount = false,
    bool clearCashier = false,
  }) => ReportScope(
    from: from ?? this.from,
    to: to ?? this.to,
    currency: clearCurrency ? null : (currency ?? this.currency),
    accountId: clearAccount ? null : (accountId ?? this.accountId),
    cashier: clearCashier ? null : (cashier ?? this.cashier),
  );
}

final reportScopeProvider = StateProvider<ReportScope>((ref) {
  final now = DateTime.now();
  return ReportScope(
    from: DateTime(now.year, now.month, 1),
    to: DateTime(now.year, now.month, now.day, 23, 59, 59),
  );
});

/// بيانات التقرير الخام: العمليات المصفّاة + الحسابات + أرصدتها ضمن النطاق.
class ReportData {
  final List<Tx> txs;
  final List<Account> accounts;
  final Map<int, double> balances;
  final Map<int, int> txCount;

  const ReportData({
    required this.txs,
    required this.accounts,
    required this.balances,
    required this.txCount,
  });
}

final reportDataProvider = FutureProvider<ReportData>((ref) async {
  ref.watch(refreshProvider);
  final s = ref.watch(reportScopeProvider);
  final repo = ref.watch(repoProvider);

  var txs = (await repo.transactions(
    from: s.from,
    to: s.to,
    accountId: s.accountId,
  )).where((t) => s.currency == null || t.currency == s.currency).toList();

  if (s.cashier != null && s.cashier!.isNotEmpty) {
    txs = txs.where((t) {
      final name = t.cashierName.trim();
      final uid = t.createdByUserId?.toString() ?? '';
      return name == s.cashier || uid == s.cashier;
    }).toList();
  }

  final accounts = await repo.accounts(includeArchived: true);

  // الرصيد ضمن النطاق = الافتتاحي + أثر عمليات النطاق فقط،
  // تمامًا كما يفعل accountBalance(a, d.txs) في نسخة الويب.
  final balances = <int, double>{};
  final counts = <int, int>{};
  for (final a in accounts) {
    var bal = a.openingBalance;
    var n = 0;
    for (final t in txs) {
      final e = t.effectOn(a.id!);
      if (e != null) {
        bal += e;
        n++;
      }
    }
    balances[a.id!] = bal;
    counts[a.id!] = n;
  }

  return ReportData(
    txs: txs,
    accounts: accounts,
    balances: balances,
    txCount: counts,
  );
});

// ==================== التصنيفات وسلة المهملات ====================

final categoriesProvider = FutureProvider<List<String>>((ref) async {
  ref.watch(refreshProvider);
  return ref
      .watch(repoProvider)
      .categories()
      .timeout(const Duration(seconds: 8), onTimeout: () => const []);
});

final trashProvider = FutureProvider<List<Map<String, Object?>>>((ref) async {
  ref.watch(refreshProvider);
  return ref
      .watch(repoProvider)
      .trash()
      .timeout(const Duration(seconds: 8), onTimeout: () => []);
});

final countsProvider = FutureProvider<Map<String, int>>((ref) async {
  ref.watch(refreshProvider);
  return ref
      .watch(repoProvider)
      .counts()
      .timeout(const Duration(seconds: 8), onTimeout: () => <String, int>{});
});

// ==================== الدردشة ====================

final conversationsProvider = FutureProvider<List<Map<String, Object?>>>((
  ref,
) async {
  ref.watch(refreshProvider);
  return ref
      .watch(repoProvider)
      .conversations()
      .timeout(
        const Duration(seconds: 8),
        onTimeout: () => <Map<String, Object?>>[],
      );
});

final messagesProvider = FutureProvider.family<List<ChatMessage>, int>((
  ref,
  convId,
) async {
  ref.watch(refreshProvider);
  return ref
      .watch(repoProvider)
      .messages(convId)
      .timeout(const Duration(seconds: 8), onTimeout: () => const []);
});

// ==================== الأصناف والمخزون ====================

/// (2026-09-22) أقسام المتجر (المستوى الأول: قسم ← فئة ← صنف).
final sectionsProvider = FutureProvider<List<Section>>((ref) async {
  ref.watch(refreshProvider);
  return ref
      .read(repoProvider)
      .sections()
      .timeout(const Duration(seconds: 8), onTimeout: () => []);
});

/// فئات الأصناف التي تظهر أولًا في شاشة المخزون.
final itemCategoriesProvider = FutureProvider<List<ItemCategory>>((ref) async {
  ref.watch(refreshProvider);
  return ref
      .read(repoProvider)
      .itemCategories()
      .timeout(const Duration(seconds: 8), onTimeout: () => []);
});

/// (2026-09-22) شجرة الفئات: الفئات الرئيسية وفي كل واحدة أبناؤها
/// المباشرون — قراءة واحدة تُجمَّع محلياً (بلا استعلام لكل فئة).
final itemCategoryTreeProvider = FutureProvider<List<ItemCategory>>((ref) async {
  ref.watch(refreshProvider);
  return ref
      .read(repoProvider)
      .itemCategoryTree()
      .timeout(const Duration(seconds: 8), onTimeout: () => []);
});

/// نص البحث في شاشة المخزون.
final itemQueryProvider = StateProvider<String>((ref) => '');

/// الأصناف المطابقة للبحث الحالي.
final itemsProvider = FutureProvider<List<Item>>((ref) async {
  ref.watch(refreshProvider);
  final q = ref.watch(itemQueryProvider);
  return ref
      .read(repoProvider)
      .items(q: q)
      .timeout(const Duration(seconds: 8), onTimeout: () => []);
});

/// ملخّص المخزون: التكلفة والقيمة والأرباح.
final inventorySummaryProvider = FutureProvider<Map<String, double>>((
  ref,
) async {
  ref.watch(refreshProvider);
  return ref.read(repoProvider).inventorySummary();
});

/// حركات صنف بعينه.
final stockMovesProvider = FutureProvider.family<List<StockMove>, int>((
  ref,
  itemId,
) async {
  ref.watch(refreshProvider);
  return ref
      .read(repoProvider)
      .stockMoves(itemId: itemId)
      .timeout(const Duration(seconds: 8), onTimeout: () => const []);
});

/// قائمة الأجهزة المرتبطة (تحتاج صلاحية manage_users).
final devicesProvider = FutureProvider<List<Map<String, Object?>>>((ref) async {
  ref.watch(refreshProvider);
  return ref
      .read(repoProvider)
      .devices()
      .timeout(const Duration(seconds: 8), onTimeout: () => []);
});

/// وضع المساحة الحالي: standalone/host/member.
final workspaceModeProvider = FutureProvider<String>((ref) async {
  ref.watch(refreshProvider);
  return ref
      .read(repoProvider)
      .workspaceMode()
      .timeout(const Duration(seconds: 8), onTimeout: () => 'standalone');
});

/// هل هذا الجهاز هو مالك المساحة (المدير).
/// (إصلاح أندرويد 7) انتهاء المهلة كان يعيد false فتختفي «إدارة المجموعة»
/// من واجهة المالك على الأجهزة البطيئة — الآن نسقط على آخر وضع معروف
/// (workspaceMode=host يعني هذا الجهاز مدير) بدل الإخفاء الخاطئ.
final isOwnerProvider = FutureProvider<bool>((ref) async {
  ref.watch(refreshProvider);
  final repo = ref.read(repoProvider);
  try {
    return await repo.isWorkspaceOwner().timeout(const Duration(seconds: 3));
  } catch (_) {
    try {
      return (await repo.workspaceMode().timeout(const Duration(seconds: 2))) ==
          'host';
    } catch (_) {
      return false;
    }
  }
});

/// (3.70.0 — التجديد البصري) هل يوجد حساب Google موثق (جدول google_auth)؟
/// بوابة أمان: ربط الأعضاء/رموز الدعوة وعرض «إدارة المجموعة» في الدرج.
final googleLinkedProvider = FutureProvider<bool>((ref) async {
  ref.watch(refreshProvider);
  try {
    final db = await ref.read(repoProvider).database;
    final r = await db.query('google_auth', where: 'id = 1', limit: 1);
    return r.isNotEmpty && '${r.first['google_id'] ?? ''}'.trim().isNotEmpty;
  } catch (_) {
    return false;
  }
});

/// (3.70.0 — التجديد البصري) صورة أفاتار الدرج.
/// الأولوية: صورة مختارة محلياً (account.photoPath) ← photo_url المخزن في
/// google_auth (رابط شبكة أو مسار محلي بعد اختيار صورة) ← لا صورة (أيقونة).
final drawerPhotoProvider = FutureProvider<String?>((ref) async {
  ref.watch(refreshProvider);
  try {
    final repo = ref.read(repoProvider);
    final st = await repo.settings();
    // (2026-09-22) أيقونة المؤسسة أولاً: يضعها المدير وتصل الأعضاء
    // متزامنة (org.icon.b64) — تُفك لملف محلي صغير ليعرضها الدرج.
    final b64 = (st['org.icon.b64'] ?? '').trim();
    if (b64.isNotEmpty) {
      try {
        final bytes = base64Decode(b64);
        final docs = await MediaPaths.ensureDocsDir();
        if (docs != null) {
          final f = File('$docs/org_icon.jpg');
          if (!f.existsSync() || f.lengthSync() != bytes.length) {
            await f.writeAsBytes(bytes, flush: true);
          }
          return f.path;
        }
      } catch (_) {}
    }
    final local = (st['account.photoPath'] ?? '').trim();
    if (local.isNotEmpty) return local;
    final db = await repo.database;
    final r = await db.query('google_auth', where: 'id = 1', limit: 1);
    if (r.isEmpty) return null;
    final p = '${r.first['photo_url'] ?? ''}'.trim();
    return p.isEmpty ? null : p;
  } catch (_) {
    return null;
  }
});

/// (صمام أمان) هل يحق لهذا الجهاز استرجاع الإدارة بعد تسليم متعثر؟
/// متاح للمدير السابق فقط خلال 24 ساعة من التسليم.
final reclaimOwnershipProvider = FutureProvider<bool>((ref) async {
  ref.watch(refreshProvider);
  return ref
      .read(repoProvider)
      .reclaimOwnershipAvailable()
      .timeout(const Duration(seconds: 8), onTimeout: () => false);
});

/// (استرداد طارئ) هل هذا الجهاز هو منشئ المساحة المسجل سحابياً وليس
/// المالك الحالي؟ — يُظهر خيار «استرداد ملكية مساحة العمل».
final creatorRecoveryProvider = FutureProvider<bool>((ref) async {
  ref.watch(refreshProvider);
  return ref
      .read(repoProvider)
      .creatorRecoveryAvailable()
      .timeout(const Duration(seconds: 12), onTimeout: () => false);
});

/// (استرداد طارئ) اسم المدير السابق إن كان يمكن إرجاع الإدارة إليه من
/// هذا الجهاز (نحن المالك الحالي بعد تسليم سابق) — null يخفي الخيار.
final handbackTargetProvider = FutureProvider<String?>((ref) async {
  ref.watch(refreshProvider);
  try {
    final repo = ref.read(repoProvider);
    if (!await repo.isWorkspaceOwner()) return null;
    if (await repo.workspaceMode() == 'standalone') return null;
    final db = await repo.database;
    // المدير السابق المعروف من آخر نقل ملكية وصلنا.
    final mem = await db.query(
      'sync_meta',
      where: "key = 'prevOwnerDeviceId'",
      limit: 1,
    );
    String prev = mem.isNotEmpty ? '${mem.first['value']}' : '';
    if (prev.isEmpty) {
      final ops = await db.query(
        'operations',
        where: "entity_id = 'ownershipTransfer'",
        orderBy: 'timestamp DESC',
        limit: 5,
      );
      for (final o in ops) {
        try {
          final v = jsonDecode(
            '${(jsonDecode('${o['payload']}') as Map)['value']}',
          );
          final cand = '${v['previous_owner_device_id'] ?? ''}';
          if (cand.isNotEmpty) {
            prev = cand;
            break;
          }
        } catch (_) {}
      }
    }
    if (prev.isEmpty) return null;
    final rows = await db.query(
      'devices',
      where: 'id = ?',
      whereArgs: [prev],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    // لا نعرض الخيار إن كان «السابق» هو جهازنا نفسه.
    try {
      if (prev == repo.requireDeviceId) return null;
    } catch (_) {}
    final name = '${rows.first['name'] ?? ''}'.trim();
    return name.isEmpty ? 'المدير السابق' : name;
  } catch (_) {
    return null;
  }
});

/// دور المستخدم/الجهاز الحالي (للعرض في الشارة أعلى الشاشة).
final deviceRoleProvider = FutureProvider<AppUser?>((ref) async {
  ref.watch(refreshProvider);
  return ref.watch(currentUserProvider.future);
});

/// يُستخدم من الواجهة لاختبار صلاحية معيّنة (لإخفاء/تعطيل الأزرار).
final canProvider = FutureProvider.family<bool, String>((ref, perm) async {
  ref.watch(refreshProvider);
  final user = await ref.watch(currentUserProvider.future);
  if (user == null || !user.active) return false;
  return user.can(perm);
});

/// الصلاحيات الفعالة الشاملة للمستخدم الحالي بالجلسة
final effectivePermissionsProvider =
    FutureProvider<EffectivePermissions>((ref) async {
  ref.watch(refreshProvider);
  ref.watch(currentUserProvider);
  return ref.watch(repoProvider).effectivePermissions();
});

// ---------- شاشة العمليات المتزامنة ----------

/// صف واحد من شاشة العمليات: صف الطابور مع العملية المرتبطة به.
class SyncOpRow {
  final int queueId;
  final String status; // pending | syncing | synced | failed
  final String target; // cloud | lan
  final int attempts;
  final String lastError;
  final String entityType;
  final String opType;
  final String entityId;
  final String updatedAt;
  final String deviceId;

  /// عدد الأجهزة التي استلمت العملية فعلاً.
  final int deliveredCount;

  /// إجمالي الأجهزة المقترنة المطلوب التسليم إليها.
  final int totalPeers;

  /// موجز مقروء من حمولة العملية (البيان/المبلغ/الاسم...).
  final String summary;

  const SyncOpRow({
    required this.queueId,
    required this.status,
    required this.target,
    required this.attempts,
    required this.lastError,
    required this.entityType,
    required this.opType,
    required this.entityId,
    required this.updatedAt,
    required this.deviceId,
    this.deliveredCount = 0,
    this.totalPeers = 0,
    this.summary = '',
  });

  /// هل وصلت لكل الأجهزة؟ (تظهر ✅ بدل العداد)
  bool get deliveredToAll => totalPeers > 0 && deliveredCount >= totalPeers;
}

/// يستخرج موجزاً مقروءاً من حمولة عملية المزامنة (لعرضه في القائمة).
String syncOpSummary(String payloadJson) {
  try {
    final m = jsonDecode(payloadJson);
    if (m is! Map) return '';
    final parts = <String>[];
    final desc = (m['description'] ?? m['name'] ?? '').toString().trim();
    if (desc.isNotEmpty) parts.add(desc);
    final amount = m['amount'];
    if (amount is num && amount > 0) {
      final cur = (m['currency'] ?? '').toString();
      parts.add('${Fmt.money(amount.toDouble())} $cur'.trim());
    }
    final qty = m['quantity'];
    if (qty is num && desc.isEmpty) parts.add('الكمية: $qty');
    return parts.join(' — ');
  } catch (_) {
    return '';
  }
}

/// كل صفوف المزامنة النشطة (غير المكتملة) منضمةً إلى نوع العملية.
final syncOpsProvider = FutureProvider<List<SyncOpRow>>((ref) async {
  ref.watch(refreshProvider);
  final repo = ref.read(repoProvider);
  final db = await repo.database;
  final q = SyncQueueOps(db);
  final rows = await q.activeRows(limit: 300);
  final opIds = rows
      .map((r) => r['operation_id'] as String?)
      .whereType<String>()
      .toSet()
      .toList();
  final ops = <String, Map<String, Object?>>{};
  final deliveries = <String, int>{};
  if (opIds.isNotEmpty) {
    final placeholders = List.filled(opIds.length, '?').join(',');
    final opRows = await db.rawQuery(
      'SELECT id, entity_type, op_type, entity_id, device_id, payload '
      'FROM operations WHERE id IN ($placeholders)',
      opIds,
    );
    for (final o in opRows) {
      ops[o['id'] as String] = o;
    }
    // (دفعة 58) لا op_deliveries بعد الآن: العملية المدفوعة للسحابة
    // (synced=1) تُعد واصلة لكل الأقران — SSE يسلّمها لحظياً.
    final dRows = await db.rawQuery(
      'SELECT id, synced FROM operations WHERE id IN ($placeholders)',
      opIds,
    );
    for (final d in dRows) {
      deliveries[d['id'] as String] = ((d['synced'] as int?) ?? 0) == 1
          ? 1 << 20
          : 0;
    }
  }
  // إجمالي الأقران المقترنين (المطلوب الوصول إليهم).
  final ourId = (await repo.settings())['sync.deviceId'] ?? '';
  final peersR = await db.rawQuery(
    "SELECT COUNT(*) c FROM devices WHERE is_paired = 1 "
    "AND COALESCE(revoked_at,'') = '' AND COALESCE(expelled_at,'') = '' "
    "AND id <> ?",
    [ourId],
  );
  final totalPeers = (peersR.first['c'] as int?) ?? 0;
  return rows.map((r) {
    final opId = r['operation_id'] as String? ?? '';
    final o = ops[opId];
    return SyncOpRow(
      queueId: r['id'] as int,
      status: (r['status'] as String?) ?? 'pending',
      target: (r['target'] as String?) ?? '',
      attempts: (r['attempts'] as int?) ?? 0,
      lastError: (r['last_error'] as String?) ?? '',
      entityType: (o?['entity_type'] as String?) ?? '?',
      opType: (o?['op_type'] as String?) ?? '?',
      entityId: (o?['entity_id'] as String?) ?? '',
      updatedAt: (r['updated_at'] as String?) ?? '',
      deviceId: (o?['device_id'] as String?) ?? '',
      deliveredCount: (deliveries[opId] ?? 0) > totalPeers
          ? totalPeers
          : (deliveries[opId] ?? 0),
      totalPeers: totalPeers,
      summary: syncOpSummary((o?['payload'] as String?) ?? ''),
    );
  }).toList();
});

/// شارة تسليم المعاملات: لكل معاملة (entity_id) عدد الأجهزة التي استلمت
/// أحدث عملية تخصها + إجمالي الأقران. تُعرض كرقم صغير في قائمة العمليات
/// وتتحول ✅ عند وصولها لكل الأجهزة.
class TxDeliveryBadge {
  final int delivered;
  final int total;
  const TxDeliveryBadge(this.delivered, this.total);
  bool get all => total > 0 && delivered >= total;
}

final txDeliveryBadgesProvider = FutureProvider<Map<String, TxDeliveryBadge>>((
  ref,
) async {
  ref.watch(refreshProvider);
  final repo = ref.read(repoProvider);
  final db = await repo.database;
  final ourId = (await repo.settings())['sync.deviceId'] ?? '';
  final peersR = await db.rawQuery(
    "SELECT COUNT(*) c FROM devices WHERE is_paired = 1 "
    "AND COALESCE(revoked_at,'') = '' AND COALESCE(expelled_at,'') = '' "
    "AND id <> ?",
    [ourId],
  );
  final total = (peersR.first['c'] as int?) ?? 0;
  if (total <= 0) return const {};
  // أحدث عملية محلية لكل معاملة + عدد الأجهزة التي استلمتها.
  // (دفعة 58) شارة التسليم سحابية: synced=1 = وصلت السحابة = وصلت الجميع.
  final rows = await db.rawQuery(
    '''
    SELECT o.entity_id AS eid,
           CASE WHEN o.synced = 1 THEN $total ELSE 0 END AS delivered
    FROM operations o
    WHERE o.entity_type = 'tx' AND o.device_id = ?
      AND o.version = (
        SELECT MAX(v.version) FROM operations v
        WHERE v.entity_type = 'tx' AND v.entity_id = o.entity_id
          AND v.device_id = o.device_id
      )
  ''',
    [ourId],
  );
  final out = <String, TxDeliveryBadge>{};
  for (final r in rows) {
    out[(r['eid'] as String?) ?? ''] = TxDeliveryBadge(
      (r['delivered'] as int?) ?? 0,
      total,
    );
  }
  return out;
});

/// حالة جهاز في المجموعة (لشريط الدردشة الجماعية).
/// اسم هذا الجهاز كما عيّنه المدير (من جدول devices) — يظهر في الشريط
/// العلوي لجهاز العضو بدل «مدير الحسابات».
final ownDeviceNameProvider = FutureProvider<String?>((ref) async {
  ref.watch(refreshProvider);
  final repo = ref.read(repoProvider);
  final ourId = (await repo.settings())['sync.deviceId'];
  if (ourId == null || ourId.isEmpty) return null;
  final db = await repo.database;
  final rows = await db.query(
    'devices',
    columns: ['name'],
    where: 'id = ?',
    whereArgs: [ourId],
    limit: 1,
  );
  if (rows.isEmpty) return null;
  final n = (rows.first['name'] as String?)?.trim();
  // الاسم الافتراضي قبل أي تخصيص لا يُعرض كعنوان — يبقى «مدير الحسابات».
  if (n == null ||
      n.isEmpty ||
      n == 'جهاز مدير الحسابات' || // اسم افتراضي قديم.
      n == kDefaultMemberName) {
    return null;
  }
  return n;
});

/// أسماء كل الأجهزة بما فيها المطرودة — لعرض اسم المرسل على رسائله
/// وعملياته حتى بعد مغادرته المجموعة (العمليات تبقى منسوبة لصاحبها).
final allDeviceNamesProvider = FutureProvider<Map<String, String>>((ref) async {
  ref.watch(refreshProvider);
  final db = await ref.read(repoProvider).database;
  final rows = await db.query('devices', columns: ['id', 'name']);
  return {
    for (final r in rows)
      r['id'] as String: (r['name'] as String?)?.trim().isNotEmpty == true
          ? (r['name'] as String).trim()
          : 'جهاز',
  };
});

class GroupPeer {
  final String deviceId;
  final String name;
  final bool isOwner;
  final bool isSelf;
  final bool online;
  final bool suspended; // موقوف من المدير (revoked)
  final bool pendingUser; // حسابه معلق (لم يعين المدير مستخدماً له)
  const GroupPeer({
    required this.deviceId,
    required this.name,
    required this.isOwner,
    required this.isSelf,
    required this.online,
    required this.suspended,
    required this.pendingUser,
  });
}

/// أجهزة المجموعة مع حالة كل جهاز (متصل/غير متصل/موقوف/معلق).
/// الأجهزة المطرودة (expelled) تُخفى نهائياً.
final groupPeersProvider = FutureProvider<List<GroupPeer>>((ref) async {
  ref.watch(refreshProvider);
  final repo = ref.read(repoProvider);
  final db = await repo.database;
  final ourId = (await repo.settings())['sync.deviceId'] ?? '';
  final rows = await db.query(
    'devices',
    where: "COALESCE(expelled_at,'') = ''",
    orderBy: 'is_owner DESC, name ASC',
  );
  final out = <GroupPeer>[];
  for (final d in rows) {
    final id = d['id'] as String;
    final isSelf = id == ourId;
    final revoked = ((d['revoked_at'] as String?) ?? '').isNotEmpty;
    // (دفعة 58) متصل: نحن دائماً؛ الأقران وفق آخر ظهور/مزامنة سحابية
    // حديثة (< 5 دقائق) — لا مسبار LAN بعد اليوم.
    bool online = isSelf;
    if (!isSelf) {
      final seen = DateTime.tryParse((d['last_seen_at'] as String?) ?? '');
      final ls = DateTime.tryParse((d['last_sync_at'] as String?) ?? '');
      final freshest = (ls != null && (seen == null || ls.isAfter(seen)))
          ? ls
          : seen;
      online =
          freshest != null &&
          DateTime.now().difference(freshest) < const Duration(minutes: 5);
    }
    out.add(
      GroupPeer(
        deviceId: id,
        name: (d['name'] as String?) ?? 'جهاز',
        isOwner: (d['is_owner'] as int? ?? 0) == 1,
        isSelf: isSelf,
        online: online,
        suspended: revoked,
        pendingUser:
            !revoked &&
            (d['is_owner'] as int? ?? 0) != 1 &&
            d['user_id'] == null,
      ),
    );
  }
  return out;
});

/// رسائل دردشة المجموعة.
final groupMessagesProvider = FutureProvider<List<ChatMessage>>((ref) async {
  ref.watch(refreshProvider);
  return ref.read(repoProvider).groupMessages();
});

/// ملخّص أعداد حالات المزامنة (للشارة والبطاقات العلوية).
/// حالة مزامنة كل جهاز في المجموعة: هل استلم كل عملياتنا أم كم بقي له؟
/// تُعرض في قسم العمليات والمزامنة (أجهزة متزامنة بالكامل / غير مكتملة).
class DeviceSyncStatus {
  final String deviceId;
  final String name;
  final bool isOwner;
  final bool online;
  final int missingOps; // عمليات محلية لم تصل هذا الجهاز بعد.
  final String roleCode; // دور مستخدم الجهاز (admin/agent/…) — للقب الدور.
  final String lastSyncAt; // آخر تسليم ناجح لهذا الجهاز (ISO) أو ''.
  const DeviceSyncStatus({
    required this.deviceId,
    required this.name,
    required this.isOwner,
    required this.online,
    required this.missingOps,
    this.roleCode = '',
    this.lastSyncAt = '',
  });
  bool get fullySynced => missingOps == 0;

  /// اللقب الموحد بحسب الدور: «المدير (اسم الجهاز)» وهكذا — يُستخدم في
  /// كل واجهات المزامنة والتنبيهات.
  String get displayName =>
      roleDisplayName(roleCode: roleCode, isOwner: isOwner, deviceName: name);
}

/// يبني الاسم المعروض الموحّد «اللقب (اسم الجهاز)» بحسب دور الجهاز.
/// المالك دائماً «المدير» حتى لو لم يُربط بمستخدم.
String roleDisplayName({
  required String roleCode,
  required bool isOwner,
  required String deviceName,
}) {
  final label = isOwner
      ? 'المدير'
      : switch (roleCode) {
          'admin' || 'manager' => 'المدير',
          'agent' => 'الشريك / الوكيل',
          'accountant' => 'الكاشير',
          'dataentry' => 'مدخل البيانات',
          _ => '',
        };
  final name = deviceName.trim().isEmpty ? 'جهاز' : deviceName.trim();
  return label.isEmpty ? name : '$label ($name)';
}

final deviceSyncStatusProvider = FutureProvider<List<DeviceSyncStatus>>((
  ref,
) async {
  ref.watch(refreshProvider);
  final repo = ref.read(repoProvider);
  final db = await repo.database;
  final ourId = (await repo.settings())['sync.deviceId'] ?? '';
  if (ourId.isEmpty) return const [];
  // نضمّ دور المستخدم المرتبط بالجهاز لعرض اللقب «المدير (اسم الجهاز)».
  final peers = await db.rawQuery(
    '''
    SELECT d.*, COALESCE(u.role, '') AS peer_role
    FROM devices d
    LEFT JOIN users u ON u.id = d.user_id
    WHERE d.is_paired = 1 AND COALESCE(d.revoked_at,'') = ''
      AND COALESCE(d.expelled_at,'') = '' AND d.id <> ?
    ORDER BY d.is_owner DESC, d.name ASC
  ''',
    [ourId],
  );
  if (peers.isEmpty) return const [];
  final out = <DeviceSyncStatus>[];
  for (final d in peers) {
    final id = d['id'] as String;
    // (دفعة 58) «الناقص» سحابياً = عملياتنا التي لم تُدفع للسحابة بعد —
    // ما إن تصل السحابة يسحبها كل قرين لحظياً عبر SSE.
    final missing = await db.rawQuery(
      '''
      SELECT COUNT(*) c FROM operations o
      WHERE o.device_id = ?
        AND o.entity_type NOT IN ${SyncQueueOps.silentEntities}
        AND COALESCE(o.synced, 0) = 0
        AND NOT EXISTS (
          -- العمليات التي ألغى المستخدم مزامنتها لا تُحسب ضد الجهاز.
          SELECT 1 FROM sync_queue cq
          WHERE cq.operation_id = o.id AND cq.status = 'cancelled'
        )
    ''',
      [ourId],
    );
    // حالة الاتصال: آخر ظهور/مزامنة سحابية خلال 5 دقائق = متصل.
    final seen = DateTime.tryParse((d['last_seen_at'] as String?) ?? '');
    final lastSyncAt = DateTime.tryParse((d['last_sync_at'] as String?) ?? '');
    final freshest =
        (lastSyncAt != null && (seen == null || lastSyncAt.isAfter(seen)))
        ? lastSyncAt
        : seen;
    final online =
        freshest != null &&
        DateTime.now().difference(freshest) < const Duration(minutes: 5);
    // «آخر مزامنة» = آخر دفع سحابي معروف لهذا الجهاز.
    final lastSync = (d['last_sync_at'] as String?) ?? '';
    out.add(
      DeviceSyncStatus(
        deviceId: id,
        name: (d['name'] as String?) ?? 'جهاز',
        isOwner: (d['is_owner'] as int? ?? 0) == 1,
        online: online,
        missingOps: (missing.first['c'] as int?) ?? 0,
        roleCode: (d['peer_role'] as String?) ?? '',
        lastSyncAt: lastSync,
      ),
    );
  }
  return out;
});

final syncCountsProvider = FutureProvider<Map<String, int>>((ref) async {
  ref.watch(refreshProvider);
  final repo = ref.read(repoProvider);
  final db = await repo.database;
  final q = SyncQueueOps(db);
  final pending = await q.countPending();
  final withError = await q.countWithError();
  final syncedR = await db.rawQuery(
    "SELECT COUNT(*) c FROM sync_queue sq "
    "JOIN operations o ON o.id = sq.operation_id "
    "WHERE sq.status = ? "
    "AND o.entity_type NOT IN ${SyncQueueOps.silentEntities}",
    ['synced'],
  );
  final syncedToday = (syncedR.first['c'] as int?) ?? 0;
  return {'pending': pending, 'withError': withError, 'synced': syncedToday};
});

// ---------- 🔒 الفترة التجريبية (Trial Engine) ----------

/// حالة الاشتراك/التجربة الحية — تُحدَّث كل دقيقة (العدّاد التنازلي في
/// الشريط العلوي) وبنبضات refreshProvider. القرار بوقت خادم فيربيس حصراً.
final subscriptionProvider = FutureProvider<SubscriptionState>((ref) async {
  ref.watch(refreshProvider);
  // تحديث ذاتي كل دقيقة لعدّاد الوقت المتبقي.
  final t = Timer(const Duration(minutes: 1), () => ref.invalidateSelf());
  ref.onDispose(t.cancel);
  final repo = ref.read(repoProvider);
  final st = await repo.settings();
  final url = effectiveBackendUrl(st['cloudBackendUrl']);
  if (url.isEmpty) return SubscriptionState.none;
  // (إصلاح 2026-09-23) المرجع الموحّد: أول صف بلا ترتيب كان يقرأ ترخيص
  // مساحة شخصية قديمة حتى بعد ربط الجهاز بمجموعة.
  final ws = await SubscriptionGuard.workspaceIdFor(repo);
  return SubscriptionGuard.check(
    repo,
    backendUrl: url,
    workspaceId: ws,
  ).timeout(
    const Duration(seconds: 10),
    onTimeout: () => SubscriptionGuard.lastState,
  );
});

/// (الخطط المزدوجة) بوابة ميزة مدفوعة للواجهة: true = الميزة مفتوحة.
/// أثناء التجربة/الاشتراك الفعّال كل شيء مفتوح؛ بعد الانتهاء تُقفل
/// المزايا المدفوعة (تبقى ظاهرة بمؤشر 🔒 وتحوّل لشاشة الشراء).
/// المفاتيح: categories | notifications | cloud_backup | restore |
/// advanced_search | multi_device | roles | audit.
final featureUnlockedProvider = FutureProvider.family<bool, String>((
  ref,
  key,
) async {
  final sub = await ref.watch(subscriptionProvider.future);
  return sub.featureUnlocked(
    (f) => switch (key) {
      'categories' => f.canUseCategories,
      'notifications' => f.canSendNotifications,
      'cloud_backup' => f.canCloudBackup,
      'restore' => f.canRestoreData,
      'advanced_search' => f.canAdvancedSearch,
      'multi_device' => f.multiDeviceSync,
      'roles' => f.rolePermissions,
      'audit' => f.auditLog,
      _ => true,
    },
  );
});

/// (باقة المؤسسات) عدّاد المقاعد: (المتصلة حالياً، الحد الأقصى).
/// null عندما لا تنطبق (فردي/لا سحابة).
final seatUsageProvider = FutureProvider<(int, int)?>((ref) async {
  ref.watch(refreshProvider);
  try {
    final sub = await ref.watch(subscriptionProvider.future);
    if (sub.status == 'none' || sub.planType != 'enterprise') return null;
    // مصدر واحد للعدّ والمقاعد (نفس قاعدة DeviceLicense) بدل مسارين
    // مختلفين كانا يعطيان «الأجهزة N/M» متناقضاً مع استنتاج الخطة.
    final lic = await DeviceLicense.check(ref.read(repoProvider));
    if (!lic.resolved) return null;
    return (lic.connectedDevices, lic.maxSeats);
  } catch (_) {
    return null;
  }
});

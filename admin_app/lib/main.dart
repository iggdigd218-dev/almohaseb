// ignore_for_file: deprecated_member_use
// تطبيق المدير المستقل — لوحة تفعيل تراخيص ومركز التحكم السحابي (مالك النظام فقط).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:url_launcher/url_launcher.dart';

import 'license_model.dart';
import 'rtdb.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ar', null);
  await Rtdb.instance.load();
  runApp(const AdminApp());
}

/// نبضة تحديث عامة: كل تفعيل/تمديد يُبلغ شاشات اللوحة فتُعيد التحميل.
final ValueNotifier<int> adminRefreshTick = ValueNotifier<int>(0);

class AdminApp extends StatelessWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'مركز التحكم السحابي — Nexora Admin',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF7C3AED),
        fontFamily: 'Roboto',
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          isDense: true,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

String fmtDate(int ms, {bool lifetime = false}) {
  if (lifetime || ms > DateTime(2090).millisecondsSinceEpoch) return 'دائم ∞';
  if (ms <= 0) return '—';
  try {
    return DateFormat('yyyy/MM/dd — hh:mm a', 'ar')
        .format(DateTime.fromMillisecondsSinceEpoch(ms));
  } catch (_) {
    return DateFormat('yyyy/MM/dd')
        .format(DateTime.fromMillisecondsSinceEpoch(ms));
  }
}

Future<void> copyText(BuildContext context, String label, String value) async {
  if (value.isEmpty) return;
  await Clipboard.setData(ClipboardData(text: value));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('تم نسخ $label ✓ ($value)'),
      duration: const Duration(milliseconds: 1400),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

Future<void> callPhone(BuildContext context, String rawPhone) async {
  final clean = rawPhone.replaceAll(RegExp(r'[^0-9\+]'), '');
  if (clean.isEmpty) return;
  final uri = Uri.parse('tel:$clean');
  try {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذّر فتح تطبيق الاتصال')),
      );
    }
  }
}

Future<void> openWhatsApp(BuildContext context, String rawPhone,
    {String? msg}) async {
  final clean = rawPhone.replaceAll(RegExp(r'[^0-9]'), '');
  if (clean.isEmpty) return;
  final text = Uri.encodeComponent(msg ?? '');
  final direct = Uri.parse('whatsapp://send?phone=$clean&text=$text');
  final web = Uri.parse('https://wa.me/$clean?text=$text');

  try {
    if (await canLaunchUrl(direct)) {
      if (await launchUrl(direct, mode: LaunchMode.externalApplication)) return;
    }
  } catch (_) {}
  try {
    if (await launchUrl(web, mode: LaunchMode.externalApplication)) return;
  } catch (_) {}
  try {
    await launchUrl(web);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذّر فتح تطبيق واتساب')),
      );
    }
  }
}

// ==================== الشاشة الرئيسية ====================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('☁️ مركز التحكم السحابي والتراخيص',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'إعدادات الاتصال بقاعدة البيانات',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await showDialog<void>(
                  context: context, builder: (_) => const _ConfigDialog());
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: const [
          ActivationScreen(),
          SubscribersScreen(),
          VouchersScreen(),
          SupportInboxScreen(),
          SystemControlScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.verified_outlined),
              selectedIcon: Icon(Icons.verified),
              label: 'تفعيل حساب'),
          NavigationDestination(
              icon: Icon(Icons.people_outline),
              selectedIcon: Icon(Icons.people),
              label: 'المشتركون'),
          NavigationDestination(
              icon: Icon(Icons.confirmation_number_outlined),
              selectedIcon: Icon(Icons.confirmation_number),
              label: 'أكواد الشحن'),
          NavigationDestination(
              icon: Icon(Icons.headset_mic_outlined),
              selectedIcon: Icon(Icons.headset_mic),
              label: 'الدعم الفني'),
          NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune),
              label: 'مركز التحكم'),
        ],
      ),
    );
  }
}

// ==================== إعدادات الاتصال ====================

class _ConfigDialog extends StatefulWidget {
  const _ConfigDialog();
  @override
  State<_ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<_ConfigDialog> {
  late final _url = TextEditingController(text: Rtdb.instance.baseUrl);
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('⚙️ رابط قاعدة البيانات'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _url,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                labelText: 'رابط Firebase RTDB',
                hintText: kOfficialRtdbUrl,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء')),
        FilledButton(
          onPressed: _busy
              ? null
              : () async {
                  final nav = Navigator.of(context);
                  setState(() => _busy = true);
                  try {
                    await Rtdb.instance.save(_url.text);
                    if (mounted) nav.pop();
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}

// ==================== شاشة التفعيل الفردي ====================

class ActivationScreen extends StatefulWidget {
  const ActivationScreen({super.key});
  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final _input = TextEditingController();
  final _clientName = TextEditingController();
  final _storeName = TextEditingController();
  final _phone = TextEditingController();
  final _licenseKey = TextEditingController();
  final _amountCtrl = TextEditingController(text: '0');
  final _notesCtrl = TextEditingController();

  PlanDuration _duration = PlanDuration.year;
  String _planType = 'individual';
  int _maxDevices = 1;
  String _currency = 'YER';
  String _paymentMethod = 'نقداً';
  bool _busy = false;
  ActivationResult? _result;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    _clientName.dispose();
    _storeName.dispose();
    _phone.dispose();
    _licenseKey.dispose();
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  void _showActivationReceipt(
    ActivationResult r,
    double amount,
    String currency,
    String method,
  ) {
    final expStr = fmtDate(r.expiresAtMs, lifetime: r.lifetime);
    final phone = _phone.text.trim();
    final receiptText = '''
══════════════════════════════
 🧾 سند تفعيل ترخيص نظام Nexora
══════════════════════════════
المنشأة: ${r.storeName.isNotEmpty ? r.storeName : (_storeName.text.trim().isNotEmpty ? _storeName.text.trim() : '—')}
المسؤول: ${r.clientName.isNotEmpty ? r.clientName : (_clientName.text.trim().isNotEmpty ? _clientName.text.trim() : '—')}
الهاتف: ${phone.isNotEmpty ? phone : '—'}
كود الترخيص: ${r.licenseKey}
تاريخ التفعيل: ${DateFormat('yyyy/MM/dd hh:mm a', 'ar').format(DateTime.now())}
صالح حتى: $expStr
المبلغ المدفوع: $amount $currency
طريقة الدفع: $method
══════════════════════════════
شكراً لثقتكم بنظام Nexora Ledger
''';

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.receipt_long, color: Color(0xFF7C3AED)),
            SizedBox(width: 8),
            Text('سند التفعيل الإلكتروني'),
          ],
        ),
        content: SelectableText(
          receiptText,
          style: const TextStyle(
              fontFamily: 'monospace', fontSize: 12, height: 1.45),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              copyText(context, 'سند التفعيل', receiptText);
              Navigator.pop(ctx);
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('نسخ السند'),
          ),
          if (phone.isNotEmpty)
            FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF16A34A)),
              onPressed: () {
                Navigator.pop(ctx);
                openWhatsApp(context, phone, msg: receiptText);
              },
              icon: const Icon(Icons.send, size: 16),
              label: const Text('إرسال للعميل عبر واتساب'),
            ),
        ],
      ),
    );
  }

  Future<void> _activate() async {
    final raw = _input.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = 'أدخل معرف الجهاز أو مساحة العمل أولاً');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });

    try {
      final res = await Rtdb.instance.activate(
        rawInput: raw,
        planType: _planType,
        duration: _duration,
        maxDevices: _planType == 'enterprise' ? _maxDevices : 1,
        clientName: _clientName.text.trim(),
        storeName: _storeName.text.trim(),
        phone: _phone.text.trim(),
        licenseKey: _licenseKey.text.trim().isNotEmpty
            ? _licenseKey.text.trim()
            : generateLicenseKey(raw),
      );

      final amount = double.tryParse(_amountCtrl.text.trim()) ?? 0.0;
      if (amount > 0) {
        final txId = 'bill_${DateTime.now().millisecondsSinceEpoch}';
        final record = BillingRecord(
          id: txId,
          workspaceId: res.workspaceId,
          clientName: res.clientName.isNotEmpty
              ? res.clientName
              : _clientName.text.trim(),
          storeName: res.storeName.isNotEmpty
              ? res.storeName
              : _storeName.text.trim(),
          amount: amount,
          currency: _currency,
          paymentMethod: _paymentMethod,
          durationDays: _duration.span.inDays,
          isLifetime: _duration == PlanDuration.lifetime,
          notes: _notesCtrl.text.trim().isNotEmpty
              ? _notesCtrl.text.trim()
              : 'تفعيل ترخيص ${_planType == 'enterprise' ? 'مؤسسة' : 'فردي'} (${_duration.label})',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
        await Rtdb.instance.recordBillingPayment(record);
      }

      setState(() => _result = res);
      adminRefreshTick.value++;

      if (amount > 0 && mounted) {
        _showActivationReceipt(res, amount, _currency, _paymentMethod);
      }
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('🔑 تفعيل أو تجديد ترخيص عميل',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                TextField(
                  controller: _input,
                  decoration: const InputDecoration(
                    labelText: 'معرف الجهاز أو مساحة العمل *',
                    hintText: 'مثال: DEVICE-ABC1234 أو بصمة 32 خانة',
                    prefixIcon: Icon(Icons.phonelink),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _storeName,
                  decoration: const InputDecoration(
                    labelText: 'اسم المنشأة / المحل',
                    hintText: 'سوبرماركت المدينة',
                    prefixIcon: Icon(Icons.storefront_outlined),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _clientName,
                  decoration: const InputDecoration(
                    labelText: 'اسم العميل / المسؤول',
                    hintText: 'محمد علي',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'رقم الهاتف / الواتساب',
                    hintText: '771234567',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                ),
                const SizedBox(height: 14),
                const Text('مدة الاشتراك:',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                DropdownButtonFormField<PlanDuration>(
                  value: _duration,
                  decoration: const InputDecoration(),
                  items: PlanDuration.values
                      .map((d) => DropdownMenuItem(
                            value: d,
                            child: Text(d.label),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _duration = v ?? _duration),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: RadioListTile<String>(
                        title: const Text('فردي'),
                        value: 'individual',
                        groupValue: _planType,
                        onChanged: (v) =>
                            setState(() => _planType = v ?? 'individual'),
                      ),
                    ),
                    Expanded(
                      child: RadioListTile<String>(
                        title: const Text('مؤسسة'),
                        value: 'enterprise',
                        groupValue: _planType,
                        onChanged: (v) =>
                            setState(() => _planType = v ?? 'enterprise'),
                      ),
                    ),
                  ],
                ),
                if (_planType == 'enterprise') ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('عدد الأجهزة المصرحة:'),
                      const SizedBox(width: 14),
                      DropdownButton<int>(
                        value: _maxDevices,
                        items: [2, 3, 5, 10, 20]
                            .map((n) => DropdownMenuItem(
                                value: n, child: Text('$n أجهزة')))
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _maxDevices = v ?? 5),
                      ),
                    ],
                  ),
                ],
                const Divider(height: 28),
                const Text('💰 بيانات الدفع والإيرادات:',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _amountCtrl,
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'المبلغ المدفوع / المحصل',
                          hintText: '0',
                          prefixIcon: Icon(Icons.attach_money_rounded),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<String>(
                        value: _currency,
                        decoration: const InputDecoration(
                          labelText: 'العملة',
                        ),
                        items: ['YER', 'SAR', 'USD']
                            .map((c) =>
                                DropdownMenuItem(value: c, child: Text(c)))
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _currency = v ?? _currency),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: _paymentMethod,
                  decoration: const InputDecoration(
                    labelText: 'طريقة الدفع',
                    prefixIcon: Icon(Icons.payment_rounded),
                  ),
                  items: [
                    'نقداً',
                    'بنك الكريمي',
                    'تحويل بنكي',
                    'جيب',
                    'ون كاش',
                    'أخرى'
                  ]
                      .map((m) =>
                          DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _paymentMethod = v ?? _paymentMethod),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _notesCtrl,
                  decoration: const InputDecoration(
                    labelText: 'ملاحظات الدفع (اختياري)',
                    hintText: 'رقم الحوالة، اسم المودع، إلخ...',
                    prefixIcon: Icon(Icons.note_alt_outlined),
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    backgroundColor: const Color(0xFF7C3AED),
                  ),
                  onPressed: _busy ? null : _activate,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.check_circle_outline),
                  label: const Text('تفعيل الترخيص فوراً بالسحابة',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEE2E2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(_error!,
                        style: const TextStyle(
                            color: Color(0xFFDC2626),
                            fontWeight: FontWeight.w700)),
                  ),
                ],
                if (_result != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE7F7EE),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.verified,
                                color: Color(0xFF16A34A), size: 20),
                            SizedBox(width: 6),
                            Text('تم التفعيل بنجاح!',
                                style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF16A34A))),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                            'المساحة: ${_result!.workspaceId}\nينتهي في: ${fmtDate(_result!.expiresAtMs, lifetime: _result!.lifetime)}'),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ==================== سجل المشتركين وبطاقات الإدارة ====================

class SubscribersScreen extends StatefulWidget {
  const SubscribersScreen({super.key});
  @override
  State<SubscribersScreen> createState() => _SubscribersScreenState();
}

class _SubscribersScreenState extends State<SubscribersScreen> {
  final _search = TextEditingController();
  late Future<List<SubscriberEntry>> _future = _load();
  late Future<AdminMetrics> _metricsFuture = _loadMetrics();
  int _serverNow = 0;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    adminRefreshTick.addListener(_onTick);
    _loadServerClock();
  }

  @override
  void dispose() {
    adminRefreshTick.removeListener(_onTick);
    _search.dispose();
    super.dispose();
  }

  void _onTick() => _refresh();

  Future<void> _loadServerClock() async {
    try {
      final now = await Rtdb.instance.serverNowMs();
      if (mounted) setState(() => _serverNow = now);
    } catch (_) {
      if (mounted) {
        setState(() => _serverNow = DateTime.now().millisecondsSinceEpoch);
      }
    }
  }

  Future<List<SubscriberEntry>> _load() => Rtdb.instance.configured
      ? Rtdb.instance.recentSubscribers()
      : Future.value(const []);

  Future<AdminMetrics> _loadMetrics() => Rtdb.instance.configured
      ? Rtdb.instance.metrics()
      : Future.value(const AdminMetrics(
          totalWorkspaces: 0, activePaid: 0, activeTrials: 0, expired: 0));

  Future<void> _refresh() async {
    await _loadServerClock();
    if (!mounted) return;
    setState(() {
      _future = _load();
      _metricsFuture = _loadMetrics();
    });
  }

  Future<void> _extendWithPayment(SubscriberEntry s) async {
    final dur = await showModalBottomSheet<PlanDuration>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('⏳ تمديد الاشتراك — اختر المدة',
                  style: TextStyle(fontWeight: FontWeight.w800)),
            ),
            ...PlanDuration.values.map((x) => ListTile(
                  leading: const Icon(Icons.add_alarm),
                  title: Text(x.label),
                  onTap: () => Navigator.pop(ctx, x),
                )),
          ],
        ),
      ),
    );
    if (dur == null || !mounted) return;

    final amountCtrl = TextEditingController(text: '0');
    final notesCtrl = TextEditingController();
    String method = 'نقداً';
    String currency = 'YER';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          title: const Text('💰 تسجيل الدفع والتحصيل'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'تمديد لـ: ${s.storeName.isNotEmpty ? s.storeName : s.clientName}\nالمدة: ${dur.label}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: amountCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'المبلغ المحصل'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: currency,
                        items: ['YER', 'SAR', 'USD']
                            .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                            .toList(),
                        onChanged: (v) => setDState(() => currency = v ?? currency),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: method,
                  decoration: const InputDecoration(labelText: 'طريقة الدفع'),
                  items: ['نقداً', 'بنك الكريمي', 'تحويل بنكي', 'جيب', 'ون كاش', 'أخرى']
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) => setDState(() => method = v ?? method),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: notesCtrl,
                  decoration: const InputDecoration(labelText: 'ملاحظات / رقم الإيصال'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('إلغاء'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('تخطي الدفع والتمديد فقط'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حفظ وتمديد'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == null) return;

    try {
      final r = await Rtdb.instance.activate(
        rawInput: s.workspaceId.isNotEmpty ? s.workspaceId : s.deviceId,
        planType: s.planType,
        duration: dur,
        maxDevices: s.maxDevices,
        extend: true,
        clientName: s.clientName,
        storeName: s.storeName,
        phone: s.phone,
        licenseKey: s.licenseKey,
      );

      final amount = double.tryParse(amountCtrl.text.trim()) ?? 0.0;
      if (confirmed == true && amount > 0) {
        final txId = 'bill_${DateTime.now().millisecondsSinceEpoch}';
        final record = BillingRecord(
          id: txId,
          workspaceId: s.workspaceId,
          clientName: s.clientName,
          storeName: s.storeName,
          amount: amount,
          currency: currency,
          paymentMethod: method,
          durationDays: dur.span.inDays,
          isLifetime: dur == PlanDuration.lifetime,
          notes: notesCtrl.text.trim(),
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
        await Rtdb.instance.recordBillingPayment(record);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: const Color(0xFF16A34A),
        content: Text('✅ مُدِّد بنجاح حتى ${fmtDate(r.expiresAtMs, lifetime: r.lifetime)}'),
      ));

      if (mounted) {
        _showRenewalReceipt(s, r, amount, currency, method);
      }

      adminRefreshTick.value++;
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: const Color(0xFFDC2626), content: Text('$e')),
      );
    }
  }

  void _showRenewalReceipt(
    SubscriberEntry s,
    ActivationResult r,
    double amount,
    String currency,
    String method,
  ) {
    final expStr = fmtDate(r.expiresAtMs, lifetime: r.lifetime);
    final receiptText = '''
══════════════════════════════
 🧾 سند تجديد ترخيص نظام Nexora
══════════════════════════════
المنشأة: ${s.storeName.isNotEmpty ? s.storeName : '—'}
المسؤول: ${s.clientName.isNotEmpty ? s.clientName : '—'}
الهاتف: ${s.phone.isNotEmpty ? s.phone : '—'}
كود الترخيص: ${s.licenseKey}
تاريخ التجديد: ${DateFormat('yyyy/MM/dd hh:mm a', 'ar').format(DateTime.now())}
صالح حتى: $expStr
المبلغ المحصل: $amount $currency
طريقة الدفع: $method
══════════════════════════════
شكراً لثقتكم بنظام Nexora Ledger
''';

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.receipt_long, color: Color(0xFF7C3AED)),
            SizedBox(width: 8),
            Text('سند التجديد الإلكتروني'),
          ],
        ),
        content: SelectableText(
          receiptText,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.45),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              copyText(context, 'سند التجديد', receiptText);
              Navigator.pop(ctx);
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('نسخ السند'),
          ),
          if (s.phone.isNotEmpty)
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF16A34A)),
              onPressed: () {
                Navigator.pop(ctx);
                openWhatsApp(context, s.phone, msg: receiptText);
              },
              icon: const Icon(Icons.send, size: 16),
              label: const Text('إرسال للعميل عبر واتساب'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nowMs =
        _serverNow > 0 ? _serverNow : DateTime.now().millisecondsSinceEpoch;

    return RefreshIndicator(
      onRefresh: _refresh,
      child: FutureBuilder<List<SubscriberEntry>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final all = snap.data ?? const [];
          final q = _search.text.trim().toLowerCase();
          final qPhone = q.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');

          var filtered = all.where((s) {
            final matchStore = s.storeName.toLowerCase().contains(q);
            final matchUser = s.clientName.toLowerCase().contains(q);
            final cleanSPhone = s.phone.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');
            final matchPhone =
                qPhone.isNotEmpty && cleanSPhone.contains(qPhone);
            final matchDevice = s.deviceId.toLowerCase().contains(q) ||
                s.deviceRef.toLowerCase().contains(q);
            final matchKey = s.licenseKey.toLowerCase().contains(q);
            final matchWs = s.workspaceId.toLowerCase().contains(q);

            return matchStore ||
                matchUser ||
                matchPhone ||
                matchDevice ||
                matchKey ||
                matchWs;
          }).toList();

          if (_filter == 'active') {
            filtered = filtered
                .where((s) =>
                    !s.isFrozen &&
                    s.status == 'active' &&
                    (s.expiresAtMs > nowMs ||
                        s.expiresAtMs >
                            DateTime(2090).millisecondsSinceEpoch))
                .toList();
          } else if (_filter == 'expired') {
            filtered = filtered
                .where((s) =>
                    !s.isFrozen &&
                    s.status != 'trial' &&
                    s.expiresAtMs <= nowMs &&
                    s.expiresAtMs < DateTime(2090).millisecondsSinceEpoch)
                .toList();
          } else if (_filter == 'trial') {
            filtered = filtered
                .where((s) => s.status == 'trial' || s.planType == 'trial')
                .toList();
          } else if (_filter == 'expiring_7d') {
            final sevenDays = nowMs + 7 * 86400000;
            filtered = filtered
                .where((s) =>
                    !s.isFrozen &&
                    s.expiresAtMs > nowMs &&
                    s.expiresAtMs <= sevenDays)
                .toList();
          } else if (_filter == 'suspended') {
            filtered = filtered.where((s) => s.isFrozen).toList();
          }

          return Column(
            children: [
              FutureBuilder<AdminMetrics>(
                future: _metricsFuture,
                builder: (context, mSnap) {
                  final m = mSnap.data;
                  if (m == null) return const SizedBox.shrink();
                  return Container(
                    margin: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _MetricChip(
                            label: 'النشطون',
                            value: '${m.activePaid}',
                            color: const Color(0xFF16A34A),
                            isSelected: _filter == 'active',
                            onTap: () {
                              setState(() {
                                _filter =
                                    _filter == 'active' ? 'all' : 'active';
                              });
                            },
                          ),
                          const SizedBox(width: 8),
                          _MetricChip(
                            label: 'المنتهون',
                            value: '${m.expired}',
                            color: const Color(0xFFDC2626),
                            isSelected: _filter == 'expired',
                            onTap: () {
                              setState(() {
                                _filter =
                                    _filter == 'expired' ? 'all' : 'expired';
                              });
                            },
                          ),
                          const SizedBox(width: 8),
                          _MetricChip(
                            label: 'التجريبيون',
                            value: '${m.activeTrials}',
                            color: const Color(0xFF7C3AED),
                            isSelected: _filter == 'trial',
                            onTap: () {
                              setState(() {
                                _filter = _filter == 'trial' ? 'all' : 'trial';
                              });
                            },
                          ),
                          const SizedBox(width: 8),
                          _MetricChip(
                            label: 'خلال 7 أيام',
                            value: '${m.expiringIn7Days}',
                            color: const Color(0xFFEA580C),
                            isSelected: _filter == 'expiring_7d',
                            onTap: () {
                              setState(() {
                                _filter = _filter == 'expiring_7d'
                                    ? 'all'
                                    : 'expiring_7d';
                              });
                            },
                          ),
                          const SizedBox(width: 8),
                          _MetricChip(
                            label: 'الإيراد الشهري',
                            value: '${m.monthlyRevenue.toInt()}',
                            color: const Color(0xFF2563EB),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    labelText: 'بحث بالمنشأة، العميل، الهاتف، أو كود الترخيص',
                    hintText: 'ابحث باسم المتجر أو المسؤول...',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _search.clear();
                              setState(() {});
                            },
                          ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    FilterChip(
                      label: const Text('الكل'),
                      selected: _filter == 'all',
                      onSelected: (_) => setState(() => _filter = 'all'),
                    ),
                    const SizedBox(width: 6),
                    FilterChip(
                      label: const Text('النشطون'),
                      selected: _filter == 'active',
                      onSelected: (_) => setState(() => _filter = 'active'),
                    ),
                    const SizedBox(width: 6),
                    FilterChip(
                      label: const Text('المنتهون'),
                      selected: _filter == 'expired',
                      onSelected: (_) => setState(() => _filter = 'expired'),
                    ),
                    const SizedBox(width: 6),
                    FilterChip(
                      label: const Text('التجريبيون'),
                      selected: _filter == 'trial',
                      onSelected: (_) => setState(() => _filter = 'trial'),
                    ),
                    const SizedBox(width: 6),
                    FilterChip(
                      label: const Text('خلال 7 أيام'),
                      selected: _filter == 'expiring_7d',
                      onSelected: (_) =>
                          setState(() => _filter = 'expiring_7d'),
                    ),
                    const SizedBox(width: 6),
                    FilterChip(
                      label: const Text('المعلقون ❄️'),
                      selected: _filter == 'suspended',
                      onSelected: (_) => setState(() => _filter = 'suspended'),
                    ),
                  ],
                ),
              ),
              Expanded(child: _buildList(filtered, nowMs)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildList(List<SubscriberEntry> list, int nowMs) {
    if (list.isEmpty) {
      return ListView(children: const [
        Padding(
          padding: EdgeInsets.all(40),
          child: Column(children: [
            Icon(Icons.inbox_outlined, size: 56, color: Colors.grey),
            SizedBox(height: 10),
            Text('لا توجد سجلات مطابقة',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700)),
          ]),
        ),
      ]);
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: list.length,
      separatorBuilder: (_, i) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final s = list[i];
        return SubscriberCard(
          entry: s,
          nowMs: nowMs,
          onExtend: () => _extendWithPayment(s),
          onRefresh: _refresh,
        );
      },
    );
  }
}

class _MetricChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final bool isSelected;
  final VoidCallback? onTap;

  const _MetricChip({
    required this.label,
    required this.value,
    required this.color,
    this.isSelected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? color : color.withValues(alpha: .1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: color,
            width: isSelected ? 1.8 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: .3),
                    blurRadius: 4,
                    offset: const Offset(0, 1.5),
                  )
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$label: ',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: isSelected ? Colors.white : color,
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: isSelected ? Colors.white : color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== بطاقة المشترك الموسعة ====================

class SubscriberCard extends StatelessWidget {
  final SubscriberEntry entry;
  final VoidCallback onExtend;
  final VoidCallback? onRefresh;
  final int? nowMs;

  const SubscriberCard({
    super.key,
    required this.entry,
    required this.onExtend,
    this.onRefresh,
    this.nowMs,
  });

  @override
  Widget build(BuildContext context) {
    final s = entry;
    final currentMs = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final lifetime = s.expiresAtMs > DateTime(2090).millisecondsSinceEpoch;
    final expired = !lifetime && s.expiresAtMs <= currentMs;

    Color color;
    String statusText;

    if (s.isFrozen) {
      color = const Color(0xFF6B7280);
      statusText = 'معلّق ❄️';
    } else if (expired) {
      color = const Color(0xFFDC2626);
      statusText = 'منتهي';
    } else if (lifetime) {
      color = const Color(0xFF7C3AED);
      statusText = 'دائم ∞';
    } else if (s.status == 'trial') {
      color = const Color(0xFFD97706);
      statusText = 'تجريبي';
    } else {
      color = const Color(0xFF16A34A);
      statusText = 'فعّال';
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withValues(alpha: .35), width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.storefront_rounded, size: 24, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.storeName.isNotEmpty
                            ? s.storeName
                            : (s.workspaceId.isNotEmpty
                                ? s.workspaceId
                                : 'منشأة غير مسمّاة'),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          const Icon(Icons.person_outline,
                              size: 14, color: Colors.grey),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              s.clientName.isNotEmpty
                                  ? s.clientName
                                  : 'مسؤول غير محدد',
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (s.phone.isNotEmpty) ...[
                            const Text('  •  ',
                                style: TextStyle(color: Colors.grey)),
                            Directionality(
                              textDirection: TextDirection.ltr,
                              child: Text(
                                s.phone,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF2563EB),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: color.withValues(alpha: .3)),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
            if (s.phone.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    ActionChip(
                      avatar: const Icon(Icons.phone_in_talk,
                          size: 14, color: Color(0xFF2563EB)),
                      label: const Text('اتصال سريع',
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF2563EB))),
                      backgroundColor:
                          const Color(0xFF2563EB).withValues(alpha: .08),
                      side: BorderSide(
                          color:
                              const Color(0xFF2563EB).withValues(alpha: .2)),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => callPhone(context, s.phone),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.chat_bubble_outline,
                          size: 14, color: Color(0xFF16A34A)),
                      label: const Text('واتساب بنقرة',
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF16A34A))),
                      backgroundColor:
                          const Color(0xFF16A34A).withValues(alpha: .08),
                      side: BorderSide(
                          color:
                              const Color(0xFF16A34A).withValues(alpha: .2)),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => openWhatsApp(
                        context,
                        s.phone,
                        msg:
                            'مرحباً ${s.clientName.isNotEmpty ? s.clientName : ''}، بخصوص ترخيص تطبيق Nexora Ledger.',
                      ),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.notifications_active_outlined,
                          size: 14, color: Color(0xFF7C3AED)),
                      label: const Text('تذكير بالتجديد',
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF7C3AED))),
                      backgroundColor:
                          const Color(0xFF7C3AED).withValues(alpha: .08),
                      side: BorderSide(
                          color:
                              const Color(0xFF7C3AED).withValues(alpha: .2)),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        final storeTitle = s.storeName.isNotEmpty
                            ? s.storeName
                            : (s.clientName.isNotEmpty ? s.clientName : 'عميلنا العزيز');
                        final expStr = fmtDate(s.expiryDate, lifetime: lifetime);
                        final reminderMsg =
                            'مرحباً $storeTitle، نود تذكيركم بأن ترخيص البرنامج سينتهي بتاريخ $expStr، للتجديد يرجى التواصل معنا.';
                        openWhatsApp(context, s.phone, msg: reminderMsg);
                      },
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),

            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: .06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.key, size: 15, color: Color(0xFF7C3AED)),
                  const SizedBox(width: 6),
                  const Text('كود الترخيص: ',
                      style: TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w700)),
                  Expanded(
                    child: Text(
                      s.licenseKey,
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'نسخ كود الترخيص',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    icon: const Icon(Icons.copy, size: 14),
                    onPressed: () =>
                        copyText(context, 'كود الترخيص', s.licenseKey),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 5),

            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: .06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.devices, size: 15, color: Colors.grey),
                  const SizedBox(width: 6),
                  const Text('معرف الجهاز: ',
                      style: TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w700)),
                  Expanded(
                    child: Text(
                      s.deviceId.isNotEmpty ? s.deviceId : s.deviceRef,
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(
                          fontSize: 11.5, color: Colors.black87),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'نسخ معرف الجهاز',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    icon: const Icon(Icons.copy, size: 14),
                    onPressed: () => copyText(context, 'معرف الجهاز',
                        s.deviceId.isNotEmpty ? s.deviceId : s.deviceRef),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            Row(
              children: [
                Icon(
                  s.planType == 'enterprise' ? Icons.business : Icons.person,
                  size: 15,
                  color: Colors.grey.shade700,
                ),
                const SizedBox(width: 5),
                Text(
                  s.planType == 'enterprise'
                      ? 'باقة مؤسسة (${s.maxDevices} أجهزة مصرحة)'
                      : 'باقة فردية (جهاز واحد مصرح)',
                  style: const TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  'ينتهي: ${fmtDate(s.expiryDate, lifetime: lifetime)}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: expired ? const Color(0xFFDC2626) : Colors.black87,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            Row(
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: onExtend,
                  icon: const Icon(Icons.more_time, size: 16),
                  label: const Text('تمديد بنقرة',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () => _openRemoteActionsMenu(context),
                  icon: const Icon(Icons.settings_remote_rounded, size: 16),
                  label: const Text('إجراءات التحكم عن بعد',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _openRemoteActionsMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.settings_remote, color: Color(0xFF7C3AED)),
                    const SizedBox(width: 8),
                    Text(
                      'إجراءات التحكم عن بعد — ${entry.storeName.isNotEmpty ? entry.storeName : entry.workspaceId}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
              const Divider(),
              ListTile(
                leading: Icon(
                  entry.isFrozen ? Icons.lock_open_rounded : Icons.lock_person_rounded,
                  color: entry.isFrozen ? Colors.green : Colors.red,
                ),
                title: Text(entry.isFrozen ? 'فك تجميد الحساب واستئناف الخدمة' : 'قفل وتعليق التطبيق فوراً (Kill Switch)'),
                subtitle: Text(entry.isFrozen ? 'إلغاء شاشة القفل والسماح للمستخدم بالدخول' : 'إظهار شاشة قفل مانعة للنزاعات أو تأخر السداد'),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await Rtdb.instance.toggleFreezeSubscriber(entry.workspaceId, !entry.isFrozen);
                    onRefresh?.call();
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$e'), backgroundColor: Colors.red),
                      );
                    }
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.link_off_rounded, color: Colors.orange),
                title: const Text('إلغاء الترخيص وفك ارتباط الجهاز (Unlink)'),
                subtitle: const Text('مسح كود الجهاز لإتاحة تفعيله على هاتف جديد'),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await Rtdb.instance.unlinkSubscriberDevice(entry.workspaceId);
                    onRefresh?.call();
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$e'), backgroundColor: Colors.red),
                      );
                    }
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.toggle_on_outlined, color: Colors.teal),
                title: const Text('إدارة الميزات والصلاحيات (Feature Flags)'),
                subtitle: const Text('تفعيل/تعطيل المزامنة، النسخ، وسقوف الأجهزة'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showFeatureFlagsDialog(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.devices_other_rounded, color: Colors.blue),
                title: const Text('استعراض أجهزة المنشأة وطرد جهاز (Kick)'),
                subtitle: const Text('عرض قائمة الكاشيرات المتصلة وفك ارتباط جهاز مسروق/معطل'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showConnectedDevicesDialog(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.cloud_upload_outlined, color: Colors.indigo),
                title: const Text('أمر النسخ الفوري عن بعد (Remote Backup)'),
                subtitle: const Text('إرسال إشارة للتطبيق لأخذ نسخة سحابية في الخلفية فوراً'),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await Rtdb.instance.requestInstantBackup(entry.workspaceId);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('تم إرسال إشارة النسخ الفوري للجهاز ✓')),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$e'), backgroundColor: Colors.red),
                      );
                    }
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.add_alert_outlined, color: Colors.deepPurple),
                title: const Text('إرسال إشعار وتنبيه مباشر للعميل'),
                subtitle: const Text('إشعار مخصص يظهر في شريط إشعارات العميل والتطبيق'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showDirectAlertModal(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.history_edu_rounded, color: Colors.brown),
                title: const Text('سجل المدفوعات والتحصيل السابق'),
                subtitle: const Text('استعراض الفواتير والمبالغ المحصلة من هذه المنشأة'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showBillingHistoryDialog(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showFeatureFlagsDialog(BuildContext context) {
    final flags = Map<String, bool>.from(entry.featureFlags);
    bool cloudSync = flags['cloud_sync'] ?? true;
    bool cloudBackup = flags['cloud_backup'] ?? true;
    bool multiBranch = flags['multi_branch'] ?? true;
    bool multiUser = flags['multi_user'] ?? true;
    bool advancedInvoicing = flags['advanced_invoicing'] ?? true;
    final maxDevCtrl = TextEditingController(text: '${entry.maxDevices}');

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          title: const Text('⚙️ إدارة الميزات وسقوف الاستخدام'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  title: const Text('المزامنة السحابية'),
                  value: cloudSync,
                  onChanged: (v) => setDState(() => cloudSync = v),
                ),
                SwitchListTile(
                  title: const Text('النسخ الاحتياطي السحابي'),
                  value: cloudBackup,
                  onChanged: (v) => setDState(() => cloudBackup = v),
                ),
                SwitchListTile(
                  title: const Text('تعدد الفروع'),
                  value: multiBranch,
                  onChanged: (v) => setDState(() => multiBranch = v),
                ),
                SwitchListTile(
                  title: const Text('تعدد المستخدمين'),
                  value: multiUser,
                  onChanged: (v) => setDState(() => multiUser = v),
                ),
                SwitchListTile(
                  title: const Text('الفواتير المتقدمة'),
                  value: advancedInvoicing,
                  onChanged: (v) => setDState(() => advancedInvoicing = v),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: maxDevCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'سقف عدد الأجهزة المسموحة',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () async {
                final newFlags = {
                  'cloud_sync': cloudSync,
                  'cloud_backup': cloudBackup,
                  'multi_branch': multiBranch,
                  'multi_user': multiUser,
                  'advanced_invoicing': advancedInvoicing,
                };
                final maxD = int.tryParse(maxDevCtrl.text.trim()) ?? entry.maxDevices;
                await Rtdb.instance.updateFeatureFlags(entry.workspaceId, newFlags, maxDevices: maxD);
                if (ctx.mounted) Navigator.pop(ctx);
                onRefresh?.call();
              },
              child: const Text('حفظ التغييرات'),
            ),
          ],
        ),
      ),
    );
  }

  void _showConnectedDevicesDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => FutureBuilder<List<ConnectedDevice>>(
        future: Rtdb.instance.getConnectedDevices(entry.workspaceId),
        builder: (ctx, snap) {
          final devices = snap.data ?? [];
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.devices, color: Color(0xFF2563EB)),
                SizedBox(width: 8),
                Text('أجهزة المنشأة المتصلة'),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: snap.connectionState == ConnectionState.waiting
                  ? const Center(child: CircularProgressIndicator())
                  : devices.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(20),
                          child: Text('لا توجد أجهزة متصلة مسجلة بعد', textAlign: TextAlign.center),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: devices.length,
                          separatorBuilder: (_, __) => const Divider(),
                          itemBuilder: (ctx, i) {
                            final d = devices[i];
                            return ListTile(
                              leading: const Icon(Icons.point_of_sale_rounded),
                              title: Text(d.deviceName.isNotEmpty ? d.deviceName : d.deviceId),
                              subtitle: Text(
                                'موديل: ${d.model} • نظام: ${d.platform}\nآخر ظهور: ${fmtDate(d.lastSeenAt)}',
                                style: const TextStyle(fontSize: 11),
                              ),
                              trailing: IconButton(
                                tooltip: 'طرد الجهاز (Kick)',
                                icon: const Icon(Icons.delete_forever, color: Colors.red),
                                onPressed: () async {
                                  await Rtdb.instance.kickDevice(entry.workspaceId, d.deviceId);
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  onRefresh?.call();
                                },
                              ),
                            );
                          },
                        ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
            ],
          );
        },
      ),
    );
  }

  void _showDirectAlertModal(BuildContext context) {
    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();
    bool isModal = false;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          title: const Text('🔔 إرسال إشعار موجه للعميل'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(labelText: 'عنوان الإشعار'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: bodyCtrl,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'نص الإشعار'),
              ),
              const SizedBox(height: 10),
              SwitchListTile(
                title: const Text('نافذة منبثقة إجبارية (Modal Dialog)'),
                value: isModal,
                onChanged: (v) => setDState(() => isModal = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () async {
                final t = titleCtrl.text.trim();
                final b = bodyCtrl.text.trim();
                if (t.isEmpty || b.isEmpty) return;
                await Rtdb.instance.sendTargetedNotification(
                  entry.workspaceId,
                  title: t,
                  body: b,
                  isModal: isModal,
                );
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('تم إرسال الإشعار للعميل بنجاح ✓')),
                  );
                }
              },
              child: const Text('إرسال الآن'),
            ),
          ],
        ),
      ),
    );
  }

  void _showBillingHistoryDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => FutureBuilder<List<BillingRecord>>(
        future: Rtdb.instance.getBillingHistory(entry.workspaceId),
        builder: (ctx, snap) {
          final list = snap.data ?? [];
          return AlertDialog(
            title: const Text('📜 سجل المدفوعات والتحصيل'),
            content: SizedBox(
              width: double.maxFinite,
              child: snap.connectionState == ConnectionState.waiting
                  ? const Center(child: CircularProgressIndicator())
                  : list.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(20),
                          child: Text('لا توجد عمليات دفع مسجلة', textAlign: TextAlign.center),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: list.length,
                          separatorBuilder: (_, __) => const Divider(),
                          itemBuilder: (ctx, i) {
                            final b = list[i];
                            return ListTile(
                              leading: const Icon(Icons.monetization_on, color: Colors.green),
                              title: Text('${b.amount} ${b.currency} — ${b.paymentMethod}'),
                              subtitle: Text(
                                'التاريخ: ${fmtDate(b.timestamp)}\nالمدة: ${b.durationDays} يوماً ${b.notes.isNotEmpty ? '• ${b.notes}' : ''}',
                                style: const TextStyle(fontSize: 11),
                              ),
                            );
                          },
                        ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
            ],
          );
        },
      ),
    );
  }
}

// ==================== شاشة أكواد الشحن والتفعيل (Voucher Keys) ====================

class VouchersScreen extends StatefulWidget {
  const VouchersScreen({super.key});
  @override
  State<VouchersScreen> createState() => _VouchersScreenState();
}

class _VouchersScreenState extends State<VouchersScreen> {
  late Future<List<VoucherModel>> _future = Rtdb.instance.getVouchers();
  String _filter = 'all';

  Future<void> _refresh() async {
    setState(() => _future = Rtdb.instance.getVouchers());
  }

  Future<void> _generateDialog() async {
    int durationDays = 30;
    bool isLifetime = false;
    int count = 5;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          title: const Text('🎟️ توليد أكواد تفعيل مسبقة الدفع'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                value: isLifetime ? 99999 : durationDays,
                decoration: const InputDecoration(labelText: 'مدة الصلاحية'),
                items: const [
                  DropdownMenuItem(value: 30, child: Text('شهر واحد (30 يوماً)')),
                  DropdownMenuItem(value: 90, child: Text('3 أشهر (90 يوماً)')),
                  DropdownMenuItem(value: 365, child: Text('سنة كاملة (365 يوماً)')),
                  DropdownMenuItem(value: 99999, child: Text('تفعيل دائم (مدى الحياة)')),
                ],
                onChanged: (v) {
                  setDState(() {
                    if (v == 99999) {
                      isLifetime = true;
                    } else {
                      isLifetime = false;
                      durationDays = v ?? 30;
                    }
                  });
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                value: count,
                decoration: const InputDecoration(labelText: 'عدد الأكواد المطلوبة'),
                items: [1, 5, 10, 20]
                    .map((n) => DropdownMenuItem(value: n, child: Text('$n أكواد')))
                    .toList(),
                onChanged: (v) => setDState(() => count = v ?? 5),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await Rtdb.instance.generateVouchers(
                  durationDays: durationDays,
                  isLifetime: isLifetime,
                  count: count,
                );
                _refresh();
              },
              child: const Text('توليد وحفظ بالسحابة'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<VoucherModel>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final all = snap.data ?? [];
            var list = all;
            if (_filter == 'available') {
              list = all.where((v) => !v.isUsed).toList();
            } else if (_filter == 'used') {
              list = all.where((v) => v.isUsed).toList();
            }

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                  child: Row(
                    children: [
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF7C3AED),
                        ),
                        onPressed: _generateDialog,
                        icon: const Icon(Icons.add_card, size: 18),
                        label: const Text('توليد حزمة أكواد جديدة',
                            style: TextStyle(fontWeight: FontWeight.w800)),
                      ),
                      const Spacer(),
                      Text('الإجمالي: ${all.length}',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      FilterChip(
                        label: const Text('الكل'),
                        selected: _filter == 'all',
                        onSelected: (_) => setState(() => _filter = 'all'),
                      ),
                      const SizedBox(width: 6),
                      FilterChip(
                        label: const Text('متاحة للشحن'),
                        selected: _filter == 'available',
                        onSelected: (_) => setState(() => _filter = 'available'),
                      ),
                      const SizedBox(width: 6),
                      FilterChip(
                        label: const Text('مستخدمة'),
                        selected: _filter == 'used',
                        onSelected: (_) => setState(() => _filter = 'used'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: list.isEmpty
                      ? const Center(child: Text('لا توجد أكواد تفعيل مطابقة'))
                      : ListView.separated(
                          padding: const EdgeInsets.all(14),
                          itemCount: list.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (ctx, i) {
                            final v = list[i];
                            return Card(
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                  color: v.isUsed
                                      ? Colors.grey.shade300
                                      : const Color(0xFF7C3AED).withValues(alpha: .35),
                                ),
                              ),
                              child: ListTile(
                                leading: Icon(
                                  v.isUsed ? Icons.check_circle : Icons.vpn_key_rounded,
                                  color: v.isUsed ? Colors.grey : const Color(0xFF7C3AED),
                                ),
                                title: Row(
                                  children: [
                                    SelectableText(
                                      v.code,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontWeight: FontWeight.w900,
                                        fontSize: 14,
                                        color: v.isUsed ? Colors.grey : const Color(0xFF7C3AED),
                                      ),
                                    ),
                                    const Spacer(),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: v.isUsed
                                            ? Colors.grey.shade200
                                            : const Color(0xFF16A34A).withValues(alpha: .15),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        v.isUsed ? 'مستخدم' : 'متاح للشحن',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w800,
                                          color: v.isUsed ? Colors.grey : const Color(0xFF16A34A),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                subtitle: Text(
                                  'المدة: ${v.durationLabel} • أُنشئ: ${fmtDate(v.createdAt)}'
                                  '${v.isUsed ? '\nاستُخدم بواسطة: ${v.usedByWs} (${fmtDate(v.usedAt)})' : ''}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: 'نسخ الكود',
                                      icon: const Icon(Icons.copy, size: 16),
                                      onPressed: () => copyText(context, 'كود التفعيل', v.code),
                                    ),
                                    if (!v.isUsed)
                                      IconButton(
                                        tooltip: 'مشاركة الكود (واتساب)',
                                        icon: const Icon(Icons.share, size: 16),
                                        onPressed: () {
                                          final shareMsg =
                                              'كود تفعيل اشتراكك في نظام Nexora:\n${v.code}\nصالح لمدة: ${v.durationLabel}\nاشحن الكود من شاشة تفاصيل الاشتراك بالتطبيق.';
                                          Clipboard.setData(ClipboardData(text: shareMsg));
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text('تم نسخ رسالة المشاركة للكود ✓')),
                                          );
                                        },
                                      ),
                                    IconButton(
                                      tooltip: 'حذف',
                                      icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                                      onPressed: () async {
                                        await Rtdb.instance.deleteVoucher(v.code);
                                        _refresh();
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ==================== صندوق وارد الدعم الفني (Support Inbox) ====================

class SupportInboxScreen extends StatefulWidget {
  const SupportInboxScreen({super.key});
  @override
  State<SupportInboxScreen> createState() => _SupportInboxScreenState();
}

class _SupportInboxScreenState extends State<SupportInboxScreen> {
  late Future<List<Map<String, dynamic>>> _future =
      Rtdb.instance.getSupportConversations();

  Future<void> _refresh() async {
    setState(() => _future = Rtdb.instance.getSupportConversations());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final list = snap.data ?? [];
            if (list.isEmpty) {
              return const Center(
                child: Text('لا توجد محادثات دعم فني واردة بعد'),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (ctx, i) {
                final c = list[i];
                final unread = c['unreadByAdmin'] == true;
                return Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                      color: unread
                          ? const Color(0xFF7C3AED)
                          : Colors.grey.shade300,
                      width: unread ? 1.5 : 1,
                    ),
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: unread
                          ? const Color(0xFF7C3AED)
                          : const Color(0xFFE2E8F0),
                      child: Icon(
                        Icons.storefront_outlined,
                        color: unread ? Colors.white : Colors.black54,
                      ),
                    ),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${c['storeName']}',
                            style: TextStyle(
                              fontWeight:
                                  unread ? FontWeight.w900 : FontWeight.w700,
                            ),
                          ),
                        ),
                        if (unread)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFDC2626),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Text('جديد',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800)),
                          ),
                      ],
                    ),
                    subtitle: Text(
                      '${c['clientName'].toString().isNotEmpty ? c['clientName'] : 'عميل'} • ${c['phone'].toString().isNotEmpty ? c['phone'] : 'بلا هاتف'}\n${c['lastMessage']}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AdminSupportChatDetailScreen(
                            workspaceId: c['workspaceId'] as String,
                            storeName: c['storeName'] as String,
                            clientName: (c['clientName'] ?? '') as String,
                            phone: c['phone'] as String,
                          ),
                        ),
                      );
                      _refresh();
                    },
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class AdminSupportChatDetailScreen extends StatefulWidget {
  final String workspaceId;
  final String storeName;
  final String clientName;
  final String phone;

  const AdminSupportChatDetailScreen({
    super.key,
    required this.workspaceId,
    required this.storeName,
    this.clientName = '',
    required this.phone,
  });

  @override
  State<AdminSupportChatDetailScreen> createState() =>
      _AdminSupportChatDetailScreenState();
}

class _AdminSupportChatDetailScreenState
    extends State<AdminSupportChatDetailScreen> {
  final TextEditingController _textCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  List<SupportMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    Rtdb.instance.markSupportChatRead(widget.workspaceId);
    _fetch();
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    final list = await Rtdb.instance.getSupportMessages(widget.workspaceId);
    if (mounted) {
      setState(() {
        _messages = list;
        _loading = false;
      });
    }
  }

  Future<void> _send() async {
    final t = _textCtrl.text.trim();
    if (t.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await Rtdb.instance.sendSupportReply(widget.workspaceId, t);
      _textCtrl.clear();
      await _fetch();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.storeName.isNotEmpty
                  ? widget.storeName
                  : widget.workspaceId,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
            Text(
              [
                if (widget.clientName.isNotEmpty) widget.clientName,
                if (widget.phone.isNotEmpty) widget.phone,
              ].join(' • '),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          if (widget.phone.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.chat_bubble_outline),
              onPressed: () => openWhatsApp(context, widget.phone),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.all(14),
                    itemCount: _messages.length,
                    itemBuilder: (ctx, idx) {
                      final m = _messages[idx];
                      final isMe = m.sender == 'admin';
                      return Align(
                        alignment:
                            isMe ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.78,
                          ),
                          decoration: BoxDecoration(
                            color: isMe
                                ? const Color(0xFF7C3AED)
                                : Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            m.text,
                            style: TextStyle(
                              color: isMe ? Colors.white : Colors.black87,
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      decoration: const InputDecoration(
                        hintText: 'اكتب رد الدعم الفني (نص فقط)...',
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== مركز التحكم السحابي وإعدادات النظام ====================

class SystemControlScreen extends StatefulWidget {
  const SystemControlScreen({super.key});
  @override
  State<SystemControlScreen> createState() => _SystemControlScreenState();
}

class _SystemControlScreenState extends State<SystemControlScreen> {
  final _bcastTitle = TextEditingController();
  final _bcastBody = TextEditingController();
  final _maintMsg = TextEditingController();
  final _minBuildCtrl = TextEditingController(text: '162');
  final _minVerCtrl = TextEditingController(text: '3.81.0');

  bool _maintActive = false;
  int _retentionDays = 7;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadSystemSettings();
  }

  @override
  void dispose() {
    _bcastTitle.dispose();
    _bcastBody.dispose();
    _maintMsg.dispose();
    _minBuildCtrl.dispose();
    _minVerCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSystemSettings() async {
    try {
      final maint = await Rtdb.instance.getMaintenanceMode();
      if (maint != null && mounted) {
        setState(() {
          _maintActive = maint['is_active'] == true;
          _maintMsg.text = '${maint['message'] ?? ''}';
        });
      }
    } catch (_) {}

    try {
      final policy = await Rtdb.instance.getForceUpdatePolicy();
      if (policy != null && mounted) {
        setState(() {
          _minBuildCtrl.text = '${policy['min_build'] ?? '162'}';
          _minVerCtrl.text = '${policy['min_version'] ?? '3.81.0'}';
        });
      }
    } catch (_) {}

    try {
      final ret = await Rtdb.instance.getGroupChatRetentionDays();
      if (mounted) setState(() => _retentionDays = ret);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(Icons.campaign_rounded, color: Color(0xFF7C3AED)),
                    SizedBox(width: 8),
                    Text('📢 إرسال تنبيه جماعي شامل (Broadcast Alert)',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _bcastTitle,
                  decoration: const InputDecoration(labelText: 'عنوان التنبيه'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _bcastBody,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'نص التنبيه لكافة العملاء'),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          final t = _bcastTitle.text.trim();
                          final b = _bcastBody.text.trim();
                          if (t.isEmpty || b.isEmpty) return;
                          setState(() => _busy = true);
                          await Rtdb.instance.sendBroadcastNotification(title: t, body: b);
                          _bcastTitle.clear();
                          _bcastBody.clear();
                          setState(() => _busy = false);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('تم بث التنبيه لجميع العملاء بنجاح ✓')),
                            );
                          }
                        },
                  icon: const Icon(Icons.send_rounded, size: 16),
                  label: const Text('بث التنبيه لجميع الأجهزة'),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 10),

        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(Icons.engineering_rounded, color: Colors.orange),
                    SizedBox(width: 8),
                    Text('🛑 وضع الصيانة السحابي (Maintenance Mode)',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ],
                ),
                SwitchListTile(
                  title: const Text('تفعيل وضع الصيانة'),
                  subtitle: const Text('تعطيل المزامنة مؤقتاً للجميع أثناء ترقية الخوادم'),
                  value: _maintActive,
                  onChanged: (v) => setState(() => _maintActive = v),
                ),
                TextField(
                  controller: _maintMsg,
                  decoration: const InputDecoration(labelText: 'رسالة الصيانة التوضيحية'),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () async {
                    await Rtdb.instance.setMaintenanceMode(
                      active: _maintActive,
                      message: _maintMsg.text.trim(),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('تم تحديث وضع الصيانة بالسحابة ✓')),
                      );
                    }
                  },
                  child: const Text('حفظ إعداد وضع الصيانة'),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 10),

        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(Icons.system_update_alt_rounded, color: Colors.blue),
                    SizedBox(width: 8),
                    Text('🚀 فرض التحديث الإجباري (Force Update)',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _minBuildCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'الحد الأدنى لرقم البناء (Build)'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _minVerCtrl,
                        decoration: const InputDecoration(labelText: 'رقم الإصدار (Version)'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () async {
                    final b = int.tryParse(_minBuildCtrl.text.trim()) ?? 162;
                    await Rtdb.instance.setForceUpdateMinVersion(b, _minVerCtrl.text.trim());
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('تم تطبيق سياسة التحديث الإجباري ✓')),
                      );
                    }
                  },
                  child: const Text('حفظ سياسة التحديث الإجباري'),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 10),

        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(Icons.auto_delete_rounded, color: Colors.red),
                    SizedBox(width: 8),
                    Text('⏱️ فترة بقاء رسائل المجموعات (Retention & Purge)',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  value: _retentionDays,
                  decoration: const InputDecoration(labelText: 'مهلة صلاحية وبقاء الرسائل'),
                  items: const [
                    DropdownMenuItem(value: 3, child: Text('3 أيام')),
                    DropdownMenuItem(value: 7, child: Text('أسبوع واحد (7 أيام)')),
                    DropdownMenuItem(value: 30, child: Text('شهر واحد (30 يوماً)')),
                  ],
                  onChanged: (v) => setState(() => _retentionDays = v ?? 7),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          await Rtdb.instance.setGroupChatRetentionDays(_retentionDays);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('تم حفظ فترة البقاء ✓')),
                            );
                          }
                        },
                        child: const Text('حفظ السياسة'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: () async {
                          final count = await Rtdb.instance.purgeOldGroupChatMessages(_retentionDays);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('تم تنظيف $count عملية ورسالة قديمة من السحابة ✓')),
                            );
                          }
                        },
                        child: const Text('تنظيف فوري الآن'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

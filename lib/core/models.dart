import 'accounting.dart';

/// حساب: عميل أو مورد أو حساب عام.
class Account {
  final int? id;
  final String name;
  final AccountKind kind;

  /// موجب = مستحق لنا (عليه)، سالب = مستحق منا (له).
  final double openingBalance;
  final String currency;
  final String phone;
  final String whatsapp;
  final String address;
  final String notes;
  final String category;
  final double? creditLimit;
  final List<String> tags;
  final bool archived;
  final String image;

  /// قناة إشعار السند: 'whatsapp' / 'sms' / 'none'.
  final String notifyChannel;

  final DateTime createdAt;
  final DateTime updatedAt;

  const Account({
    this.id,
    required this.name,
    this.kind = AccountKind.customer,
    this.openingBalance = 0,
    this.currency = 'YER',
    this.phone = '',
    this.whatsapp = '',
    this.address = '',
    this.notes = '',
    this.category = '',
    this.creditLimit,
    this.tags = const [],
    this.archived = false,
    this.image = '',
    this.notifyChannel = 'whatsapp',
    required this.createdAt,
    required this.updatedAt,
  });

  /// الرقم المستخدم للتواصل: واتساب إن وُجد وإلا الهاتف.
  String get contactNumber {
    final ch = notifyChannel;
    if (ch == 'sms') return phone.trim();
    if (ch == 'whatsapp') {
      return whatsapp.trim().isNotEmpty ? whatsapp : phone;
    }
    return '';
  }

  Account copyWith({
    int? id,
    String? name,
    AccountKind? kind,
    double? openingBalance,
    String? currency,
    String? phone,
    String? whatsapp,
    String? address,
    String? notes,
    String? category,
    double? creditLimit,
    bool clearCreditLimit = false,
    List<String>? tags,
    bool? archived,
    String? image,
    String? notifyChannel,
  }) =>
      Account(
        id: id ?? this.id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        openingBalance: openingBalance ?? this.openingBalance,
        currency: currency ?? this.currency,
        phone: phone ?? this.phone,
        whatsapp: whatsapp ?? this.whatsapp,
        address: address ?? this.address,
        notes: notes ?? this.notes,
        category: category ?? this.category,
        creditLimit:
            clearCreditLimit ? null : (creditLimit ?? this.creditLimit),
        tags: tags ?? this.tags,
        archived: archived ?? this.archived,
        image: image ?? this.image,
        notifyChannel: notifyChannel ?? this.notifyChannel,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'kind': kind.code,
        'opening_balance': openingBalance,
        'currency': currency,
        'phone': phone,
        'whatsapp': whatsapp,
        'address': address,
        'notes': notes,
        'category': category,
        'credit_limit': creditLimit,
        'tags': tags.join(','),
        'archived': archived ? 1 : 0,
        'image': image,
        'notify_channel': notifyChannel,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Account.fromMap(Map<String, Object?> m) {
    final raw = (m['tags'] ?? '') as String;
    return Account(
      id: m['id'] as int?,
      name: (m['name'] ?? '') as String,
      kind: AccountKind.fromCode((m['kind'] ?? 'customer') as String),
      openingBalance: ((m['opening_balance'] ?? 0) as num).toDouble(),
      currency: (m['currency'] ?? 'YER') as String,
      phone: (m['phone'] ?? '') as String,
      whatsapp: (m['whatsapp'] ?? '') as String,
      address: (m['address'] ?? '') as String,
      notes: (m['notes'] ?? '') as String,
      category: (m['category'] ?? '') as String,
      creditLimit: (m['credit_limit'] as num?)?.toDouble(),
      tags: raw.isEmpty
          ? const []
          : raw
              .split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
      archived: ((m['archived'] ?? 0) as int) == 1,
      image: (m['image'] ?? '') as String,
      notifyChannel: (m['notify_channel'] ?? 'whatsapp') as String,
      createdAt: DateTime.parse(m['created_at'] as String),
      updatedAt: DateTime.parse(m['updated_at'] as String),
    );
  }
}

/// عملية مالية.
class Tx {
  final int? id;
  final int? accountId;
  final AccountKind accountKind;
  final OpType type;
  final double amount;
  final String currency;

  /// علامة التسوية: '+' أو '-'. تُستخدم لنوع settle فقط.
  final String sign;
  final int? fromId;
  final int? toId;
  final double rate;
  final String description;
  final String reference;
  final String notes;
  final String category;
  final String attachment;

  /// تجزئة SHA-256 لملف المرفق/الصورة — تسمح للأجهزة الأخرى بجلب الملف
  /// عبر LAN عند الطلب (GET /attachments/:hash) بدل تضمينه في المزامنة.
  final String attachmentHash;

  /// مسار صورة الإيصال المولّدة أو المختارة لهذه العملية (واحدة لكل عملية).
  final String image;
  final String status;

  /// حالة المزامنة المستقلة عن حالة العملية:
  ///  - 'synced': تمت المزامنة بنجاح.
  ///  - 'pending': بانتظار المزامنة.
  ///  - 'syncing': جاري المزامنة.
  ///  - 'failed': فشلت المزامنة.
  ///  - 'local': محلي فقط (جهاز مستقل / غير مُرسل بعد).
  final String syncState;
  final int? createdByUserId;
  final String cashierName;
  final DateTime date;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Tx({
    this.id,
    this.accountId,
    this.accountKind = AccountKind.customer,
    required this.type,
    required this.amount,
    this.currency = 'YER',
    this.sign = '',
    this.fromId,
    this.toId,
    this.rate = 1,
    this.description = '',
    this.reference = '',
    this.notes = '',
    this.category = '',
    this.attachment = '',
    this.attachmentHash = '',
    this.image = '',
    this.status = 'done',
    this.syncState = 'synced',
    this.createdByUserId,
    this.cashierName = '',
    required this.date,
    required this.createdAt,
    required this.updatedAt,
  });

  /// أثر هذه العملية على رصيد الحساب [accId]، أو null إن لم تمسّه.
  ///
  /// منقول حرفيًا من `txEffect` في نسخة الويب.
  double? effectOn(int accId) {
    if (type == OpType.transfer) {
      if (fromId == accId) return -amount;
      if (toId == accId) return amount * rate;
      return null;
    }
    if (accountId != accId) return null;
    var eff = opEffect(type, accountKind);
    if (type == OpType.settle) {
      eff = (sign == '+' || sign == '1') ? 1 : -1;
    }
    return eff * amount;
  }

  Tx copyWith({
    int? id,
    int? accountId,
    AccountKind? accountKind,
    OpType? type,
    double? amount,
    String? currency,
    String? sign,
    int? fromId,
    int? toId,
    double? rate,
    String? description,
    String? reference,
    String? notes,
    String? category,
    String? attachment,
    String? attachmentHash,
    String? image,
    String? status,
    String? syncState,
    int? createdByUserId,
    String? cashierName,
    DateTime? date,
    bool clearAccountId = false,
    bool clearFromId = false,
    bool clearToId = false,
  }) =>
      Tx(
        id: id ?? this.id,
        accountId: clearAccountId ? null : (accountId ?? this.accountId),
        accountKind: accountKind ?? this.accountKind,
        type: type ?? this.type,
        amount: amount ?? this.amount,
        currency: currency ?? this.currency,
        sign: sign ?? this.sign,
        fromId: clearFromId ? null : (fromId ?? this.fromId),
        toId: clearToId ? null : (toId ?? this.toId),
        rate: rate ?? this.rate,
        description: description ?? this.description,
        reference: reference ?? this.reference,
        notes: notes ?? this.notes,
        category: category ?? this.category,
        attachment: attachment ?? this.attachment,
        attachmentHash: attachmentHash ?? this.attachmentHash,
        image: image ?? this.image,
        status: status ?? this.status,
        syncState: syncState ?? this.syncState,
        createdByUserId: createdByUserId ?? this.createdByUserId,
        cashierName: cashierName ?? this.cashierName,
        date: date ?? this.date,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'account_id': accountId,
        'account_kind': accountKind.code,
        'type': type.code,
        'amount': amount,
        'currency': currency,
        'sign': sign,
        'from_id': fromId,
        'to_id': toId,
        'rate': rate,
        'description': description,
        'reference': reference,
        'notes': notes,
        'category': category,
        'attachment': attachment,
        'attachment_hash': attachmentHash,
        'image': image,
        'status': status,
        'sync_state': syncState,
        if (createdByUserId != null) 'created_by_user_id': createdByUserId,
        if (cashierName.isNotEmpty) 'cashier_name': cashierName,
        'date': date.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Tx.fromMap(Map<String, Object?> m) => Tx(
        id: m['id'] as int?,
        accountId: m['account_id'] as int?,
        accountKind: AccountKind.fromCode(
          (m['account_kind'] ?? 'customer') as String,
        ),
        type: OpType.fromCode((m['type'] ?? 'debit') as String),
        amount: ((m['amount'] ?? 0) as num).toDouble(),
        currency: (m['currency'] ?? 'YER') as String,
        sign: (m['sign'] ?? '') as String,
        fromId: m['from_id'] as int?,
        toId: m['to_id'] as int?,
        rate: ((m['rate'] ?? 1) as num).toDouble(),
        description: (m['description'] ?? '') as String,
        reference: (m['reference'] ?? '') as String,
        notes: (m['notes'] ?? '') as String,
        category: (m['category'] ?? '') as String,
        attachment: (m['attachment'] ?? '') as String,
        attachmentHash: (m['attachment_hash'] ?? '') as String,
        image: (m['image'] ?? '') as String,
        status: (m['status'] ?? 'done') as String,
        syncState: (m['sync_state'] ?? 'synced') as String,
        createdByUserId: m['created_by_user_id'] as int?,
        cashierName: (m['cashier_name'] ?? '') as String,
        date: DateTime.parse(m['date'] as String),
        createdAt: DateTime.parse(m['created_at'] as String),
        updatedAt: DateTime.parse(m['updated_at'] as String),
      );
}

/// حساب مع رصيده المحسوب.
class AccountWithBalance {
  final Account account;
  final double balance;
  const AccountWithBalance(this.account, this.balance);

  /// هل تجاوز الحد الائتماني؟
  bool get overLimit {
    final l = account.creditLimit;
    return l != null && l > 0 && balance > l;
  }
}

// ==================== السندات ====================

/// أنواع السندات — نقل حرفي من `VOUCHER_TYPES` في نسخة الويب.
enum VoucherKind {
  receipt('سند قبض', '🧾', 'receipt', 'ق'),
  payment('سند صرف', '💳', 'payment', 'ص'),
  debit('سند قيد مدين', '📥', 'debit', 'ق'),
  credit('سند قيد دائن', '📤', 'credit', 'د'),
  transfer('سند تحويل', '🔁', 'transfer', 'تح');

  const VoucherKind(this.label, this.icon, this.code, this.prefix);
  final String label;
  final String icon;
  final String code;
  final String prefix;

  static VoucherKind fromCode(String c) => VoucherKind.values.firstWhere(
        (e) => e.code == c,
        orElse: () => VoucherKind.receipt,
      );
}

class Voucher {
  final int? id;
  final String number;
  final VoucherKind kind;
  final int? accountId;
  final int? txId;
  final double amount;
  final String currency;
  final String statement;
  final String notes;

  /// draft / approved / cancelled
  final String status;
  final int? createdByUserId;
  final String cashierName;

  final DateTime date;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Voucher({
    this.id,
    required this.number,
    required this.kind,
    this.accountId,
    this.txId,
    required this.amount,
    this.currency = 'YER',
    this.statement = '',
    this.notes = '',
    this.status = 'draft',
    this.createdByUserId,
    this.cashierName = '',
    required this.date,
    required this.createdAt,
    required this.updatedAt,
  });

  String get statusLabel => switch (status) {
        'approved' => 'معتمد',
        'cancelled' => 'ملغى',
        _ => 'مسودة',
      };

  Voucher copyWith({
    int? id,
    String? number,
    VoucherKind? kind,
    int? accountId,
    int? txId,
    double? amount,
    String? currency,
    String? statement,
    String? notes,
    String? status,
    int? createdByUserId,
    String? cashierName,
    DateTime? date,
    DateTime? updatedAt,
  }) =>
      Voucher(
        id: id ?? this.id,
        number: number ?? this.number,
        kind: kind ?? this.kind,
        accountId: accountId ?? this.accountId,
        txId: txId ?? this.txId,
        amount: amount ?? this.amount,
        currency: currency ?? this.currency,
        statement: statement ?? this.statement,
        notes: notes ?? this.notes,
        status: status ?? this.status,
        createdByUserId: createdByUserId ?? this.createdByUserId,
        cashierName: cashierName ?? this.cashierName,
        date: date ?? this.date,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'number': number,
        'kind': kind.code,
        'account_id': accountId,
        'tx_id': txId,
        'amount': amount,
        'currency': currency,
        'statement': statement,
        'notes': notes,
        'status': status,
        if (createdByUserId != null) 'created_by_user_id': createdByUserId,
        if (cashierName.isNotEmpty) 'cashier_name': cashierName,
        'date': date.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Voucher.fromMap(Map<String, Object?> m) => Voucher(
        id: m['id'] as int?,
        number: (m['number'] ?? '') as String,
        kind: VoucherKind.fromCode((m['kind'] ?? 'receipt') as String),
        accountId: m['account_id'] as int?,
        txId: m['tx_id'] as int?,
        amount: ((m['amount'] ?? 0) as num).toDouble(),
        currency: (m['currency'] ?? 'YER') as String,
        statement: (m['statement'] ?? '') as String,
        notes: (m['notes'] ?? '') as String,
        status: (m['status'] ?? 'draft') as String,
        createdByUserId: m['created_by_user_id'] as int?,
        cashierName: (m['cashier_name'] ?? '') as String,
        date: DateTime.parse(m['date'] as String),
        createdAt: DateTime.parse(m['created_at'] as String),
        updatedAt: DateTime.parse(m['updated_at'] as String),
      );
}

// ==================== المستخدمون والصلاحيات ====================

/// الأدوار — نقل حرفي من `ROLES` في نسخة الويب.
enum UserRole {
  admin('مدير النظام', '👑', 'admin'),
  agent('وكيل المدير', '🛡️', 'agent'),
  accountant('محاسب', '🧮', 'accountant'),
  cashier('كاشير', '🛒', 'cashier'),
  dataentry('موظف إدخال', '⌨️', 'dataentry'),
  viewer('عرض فقط', '👁️', 'viewer');

  const UserRole(this.label, this.icon, this.code);
  final String label;
  final String icon;
  final String code;

  static UserRole fromCode(String c) {
    // توافق خلفي: البذرة القديمة كانت تستخدم 'manager' بدل 'admin'
    if (c == 'manager') return UserRole.admin;
    if (c == 'pos' || c == 'sales') return UserRole.cashier;
    return UserRole.values.firstWhere(
      (e) => e.code == c,
      orElse: () => UserRole.cashier,
    );
  }
}

/// الصلاحيات — نقل حرفي من `PERMS`.
class Perm {
  final String key;
  final String label;
  const Perm(this.key, this.label);
}

const kPerms = <Perm>[
  Perm('add_tx', 'إضافة العمليات'),
  Perm('edit_tx', 'تعديل العمليات'),
  Perm('delete_tx', 'حذف العمليات'),
  Perm('view_reports', 'عرض التقارير'),
  Perm('export', 'تصدير البيانات'),
  Perm('manage_backup', 'إدارة النسخ الاحتياطي'),
  Perm('manage_users', 'إدارة المستخدمين'),
  Perm('approve_vouchers', 'اعتماد/إلغاء السندات'),
];

/// الصلاحيات الافتراضية لكل دور — منقولة حرفيًا من `defaultPerms`.
Map<String, bool> defaultPerms(UserRole role) {
  switch (role) {
    case UserRole.admin:
      return {for (final p in kPerms) p.key: true};
    // الوكيل يقوم بعمل المدير أثناء غيابه: كل الصلاحيات افتراضياً.
    case UserRole.agent:
      return {for (final p in kPerms) p.key: true};
    case UserRole.accountant:
      return {
        'add_tx': true,
        'edit_tx': true,
        'delete_tx': true,
        'view_reports': true,
        'export': true,
        'approve_vouchers': true,
        'manage_backup': false,
        'manage_users': false,
      };
    case UserRole.cashier:
      return {
        'add_tx': true,
        'edit_tx': false,
        'delete_tx': false,
        'view_reports': false,
        'export': false,
        'approve_vouchers': false,
        'manage_backup': false,
        'manage_users': false,
      };
    case UserRole.dataentry:
      return {
        'add_tx': true,
        'edit_tx': true,
        'delete_tx': false,
        'view_reports': false,
        'export': false,
        'approve_vouchers': false,
        'manage_backup': false,
        'manage_users': false,
      };
    case UserRole.viewer:
      return {
        'add_tx': false,
        'edit_tx': false,
        'delete_tx': false,
        'view_reports': true,
        'export': false,
        'approve_vouchers': false,
        'manage_backup': false,
        'manage_users': false,
      };
  }
}

class AppUser {
  final int? id;
  final String name;

  /// (3.70) البريد — مفتاح RBAC في user_permissions (فارغ لصفوف قديمة).
  final String email;
  final UserRole role;
  final String pin;

  /// تجزئة كلمة مرور المستخدم (SHA-256). فارغة = بلا حماية.
  final String password;
  final Map<String, bool> permissions;
  final bool isMe;
  final bool active;
  final bool canApplyDiscount;
  final DateTime createdAt;
  final DateTime updatedAt;

  const AppUser({
    this.id,
    required this.name,
    this.email = '',
    this.role = UserRole.cashier,
    this.pin = '',
    this.password = '',
    this.permissions = const {},
    this.isMe = false,
    this.active = true,
    this.canApplyDiscount = false,
    required this.createdAt,
    required this.updatedAt,
  });

  /// هل يحتاج التبديل إلى هذا المستخدم كلمة مرور؟
  bool get locked => password.isNotEmpty;

  /// المدير والوكيل لهما كل شيء دائمًا — كما في `can()`.
  bool can(String perm) {
    if (role == UserRole.admin || role == UserRole.agent) return true;
    if (perm == 'can_discount') {
      return canApplyDiscount || (permissions['can_discount'] ?? false);
    }
    if (permissions.isEmpty) {
      return defaultPerms(role)[perm] ?? false;
    }
    return permissions[perm] ?? false;
  }

  String get permSummary {
    if (role == UserRole.admin) return 'جميع الصلاحيات';
    final granted =
        kPerms.where((p) => permissions[p.key] == true).map((p) => p.label);
    if (granted.isEmpty) return 'لا صلاحيات';
    return granted.join('، ');
  }

  AppUser copyWith({
    int? id,
    String? name,
    UserRole? role,
    String? pin,
    String? password,
    Map<String, bool>? permissions,
    bool? isMe,
    bool? active,
    bool? canApplyDiscount,
    DateTime? updatedAt,
  }) =>
      AppUser(
        id: id ?? this.id,
        name: name ?? this.name,
        role: role ?? this.role,
        pin: pin ?? this.pin,
        password: password ?? this.password,
        permissions: permissions ?? this.permissions,
        isMe: isMe ?? this.isMe,
        active: active ?? this.active,
        canApplyDiscount: canApplyDiscount ?? this.canApplyDiscount,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'role': role.code,
        'pin': pin,
        'password': password,
        'permissions': permissions.entries
            .where((e) => e.value)
            .map((e) => e.key)
            .join(','),
        'is_me': isMe ? 1 : 0,
        'active': active ? 1 : 0,
        'can_apply_discount': canApplyDiscount ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory AppUser.fromMap(Map<String, Object?> m) {
    final raw = ((m['permissions'] ?? '') as String)
        .split(',')
        .where((s) => s.trim().isNotEmpty)
        .toSet();
    final role = UserRole.fromCode((m['role'] ?? 'cashier') as String);
    final discountDefault = role == UserRole.admin || role == UserRole.agent;
    final permsMap = raw.isEmpty
        ? defaultPerms(role)
        : {for (final p in kPerms) p.key: raw.contains(p.key)};
    return AppUser(
      id: m['id'] as int?,
      name: (m['name'] ?? '') as String,
      email: '${m['email'] ?? ''}',
      role: role,
      pin: (m['pin'] ?? '') as String,
      password: (m['password'] ?? '') as String,
      permissions: permsMap,
      isMe: ((m['is_me'] ?? 0) as int) == 1,
      active: ((m['active'] ?? 1) as int) == 1,
      canApplyDiscount: ((m['can_apply_discount'] ?? (discountDefault ? 1 : 0)) as int) == 1,
      createdAt: DateTime.parse(m['created_at'] as String),
      updatedAt: DateTime.parse(m['updated_at'] as String),
    );
  }
}

// ==================== الدردشة ====================

class ChatMessage {
  final int? id;
  final int conversationId;
  final String sender;
  final String body;

  /// text / statement / voucher
  final String kind;
  final String payload;
  final DateTime createdAt;

  const ChatMessage({
    this.id,
    required this.conversationId,
    this.sender = '',
    this.body = '',
    this.kind = 'text',
    this.payload = '',
    required this.createdAt,
  });

  bool get isMine => sender == 'me';

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'conversation_id': conversationId,
        'sender': sender,
        'body': body,
        'kind': kind,
        'payload': payload,
        'created_at': createdAt.toIso8601String(),
      };

  factory ChatMessage.fromMap(Map<String, Object?> m) => ChatMessage(
        id: m['id'] as int?,
        conversationId: (m['conversation_id'] ?? 0) as int,
        sender: (m['sender'] ?? '') as String,
        body: (m['body'] ?? '') as String,
        kind: (m['kind'] ?? 'text') as String,
        payload: (m['payload'] ?? '') as String,
        createdAt: DateTime.parse(m['created_at'] as String),
      );
}


/// فئة/قسم أصناف داخل المخزون.
///
/// الفئات مستقلة عن تصنيفات الحسابات، ويمكن إنشاء عدد غير محدود منها.
/// (2026-09-22) معرّف افتراضي لمجموعة «عام»: الفئات بلا قسم تُعرض تحته
/// (ليس صفاً حقيقياً في جدول sections بل تجميعة عرض).
const int kGeneralSectionId = -1;


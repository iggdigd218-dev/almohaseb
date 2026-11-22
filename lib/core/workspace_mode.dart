// وضع مساحة العمل — توحيد نهائي للتسمية (كان يتأرجح بين 'host' و'managed').
// التخزين في SQLite يبقى نصاً ('standalone' / 'host' / 'member') لكن كل
// المقارنات في الكود يجب أن تمر عبر هذا الـ enum ودواله.
enum WorkspaceMode {
  /// جهاز مستقل خارج أي مجموعة.
  standalone,

  /// جهاز المدير (مضيف المجموعة). القيمة القديمة 'managed' تُطبَّع إليه.
  host,

  /// جهاز عضو داخل مجموعة.
  member;

  /// تحويل النص المخزّن إلى enum مع تطبيع القيم القديمة.
  static WorkspaceMode parse(String? raw) {
    switch ((raw ?? '').trim()) {
      case 'host':
      case 'managed': // تسمية قديمة — تُطبَّع دائماً إلى host.
        return WorkspaceMode.host;
      case 'member':
        return WorkspaceMode.member;
      default:
        return WorkspaceMode.standalone;
    }
  }

  /// النص القانوني للتخزين.
  String get storageValue => name;

  bool get isHost => this == WorkspaceMode.host;
  bool get isMember => this == WorkspaceMode.member;
  bool get isStandalone => this == WorkspaceMode.standalone;

  /// داخل مجموعة (مضيف أو عضو).
  bool get inGroup => this != WorkspaceMode.standalone;
}

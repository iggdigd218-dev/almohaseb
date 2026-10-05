// (دفعة 58) خطافات واجهة الدردشة والإشعارات — كانت حقولاً static داخل
// LanSyncService قبل اجتثاث طبقة LAN نهائياً. الناقل السحابي يستدعيها
// عند وصول رسالة دردشة أو بلاغ عضوية، و home_shell يضبطها عند الإقلاع.
class ChatHooks {
  /// يُستدعى عند وصول رسالة دردشة من قرين (اسم المرسل + النص) —
  /// home_shell يعرض إشعاراً نظامياً + صوتاً + شارة غير مقروء.
  static void Function(String senderName, String body)? onChatMessage;

  /// يُستدعى عند بلاغ عضوية موجه للواجهة (عنوان + نص) — انضمام عضو،
  /// تغيير دور، طرد... يظهر كإشعار منبثق أنيق.
  static void Function(String title, String body)? onMemberNotice;
}

// 💬 شاشة الدعم الفني المباشر مع إدارة النظام (In-App Support Chat).
//
// حظر شامل للوسائط:
//  - دعم حصري للرسائل النصية والرموز التعبيرية فقط (Text & Emojis Only).
//  - لا كاميرا، لا تسجيلات صوتية، لا صور، لا ملفات نهائياً لتوفير مساحة السحابة وسرعة المزامنة.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/cloud_config.dart';
import '../core/license_model.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/sync/cloud_control_service.dart';
import '../data/sync/subscription_guard.dart';
import 'widgets.dart' show showSnack;

class SupportChatScreen extends ConsumerStatefulWidget {
  const SupportChatScreen({super.key});

  @override
  ConsumerState<SupportChatScreen> createState() => _SupportChatScreenState();
}

class _SupportChatScreenState extends ConsumerState<SupportChatScreen> {
  final TextEditingController _textCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  List<SupportMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _fetchMessages();
    _refreshTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      _fetchMessages(silent: true);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchMessages({bool silent = false}) async {
    if (!mounted) return;
    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final backendUrl =
          effectiveBackendUrl((st['cloudBackendUrl'] ?? '').toString());
      if (backendUrl.isEmpty) {
        if (mounted && !silent) setState(() => _loading = false);
        return;
      }
      final wsId = await SubscriptionGuard.workspaceIdFor(repo);
      final list = await CloudControlService.instance
          .fetchSupportMessages(backendUrl, wsId);
      if (mounted) {
        setState(() {
          _messages = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  Future<void> _sendMessage() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);
    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final backendUrl =
          effectiveBackendUrl((st['cloudBackendUrl'] ?? '').toString());
      if (backendUrl.isEmpty) {
        if (mounted) {
          showSnack(context, 'المزامنة السحابية غير مفعلة', error: true);
        }
        return;
      }
      final wsId = await SubscriptionGuard.workspaceIdFor(repo);
      await CloudControlService.instance.sendSupportMessage(
        repo,
        backendUrl: backendUrl,
        workspaceId: wsId,
        text: text,
      );
      _textCtrl.clear();
      Sfx.click();
      await _fetchMessages(silent: true);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر إرسال الرسالة: $e', error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.support_agent_rounded, size: 24),
            SizedBox(width: 8),
            Text('الدعم الفني وخدمة العملاء'),
          ],
        ),
      ),
      body: Column(
        children: [
          // شريط توضيحي لطبيعة المحادثة (نصوص فقط لتوفير السعة)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            color: AppColors.primarySoftOf(context),
            child: Row(
              children: [
                Icon(Icons.lock_outline_rounded,
                    size: 16, color: AppColors.primaryOf(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'محادثة مباشرة ومشفرة مع إدارة النظام. (رسائل نصية ورموز تعبيرية فقط).',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.primaryOf(context),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // قائمة الرسائل
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.chat_bubble_outline_rounded,
                                size: 56, color: AppColors.text3Of(context)),
                            const SizedBox(height: 12),
                            const Text(
                              'لا توجد رسائل سابقة',
                              style: TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'اكتب استفسارك أدناه وسيقوم فريق الدعم بالرد المباشر.',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.text2Of(context)),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        itemCount: _messages.length,
                        itemBuilder: (ctx, idx) {
                          final msg = _messages[idx];
                          final isMe = msg.sender == 'client';
                          return Align(
                            alignment: isMe
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.78,
                              ),
                              decoration: BoxDecoration(
                                color: isMe
                                    ? AppColors.primaryOf(context)
                                    : AppColors.surfaceOf(context),
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(16),
                                  topRight: const Radius.circular(16),
                                  bottomLeft: Radius.circular(isMe ? 16 : 4),
                                  bottomRight: Radius.circular(isMe ? 4 : 16),
                                ),
                                border: isMe
                                    ? null
                                    : Border.all(
                                        color: AppColors.borderOf(context)),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.04),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: isMe
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.start,
                                children: [
                                  if (!isMe)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 4),
                                      child: Text(
                                        'إدارة النظام',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w800,
                                          color: AppColors.violetOf(context),
                                        ),
                                      ),
                                    ),
                                  Text(
                                    msg.text,
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      height: 1.45,
                                      color: isMe
                                          ? Colors.white
                                          : AppColors.textOf(context),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),

          // شريط الإدخال المقفل حصراً للنصوص والرموز التعبيرية (Text & Emojis Only)
          SafeArea(
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              color: AppColors.surfaceOf(context),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'اكتب استفسارك للدعم الفني (نص فقط)...',
                        isDense: true,
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'إرسال',
                    onPressed: _sending ? null : _sendMessage,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded, size: 20),
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

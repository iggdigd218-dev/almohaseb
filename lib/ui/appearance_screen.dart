// شاشة المظهر المستقلة: حجم الخط، والأصوات/الاهتزاز.
// (2026-11-21) أُعيد تنسيقها بنمط «دفتر الحسابات»: صفوف إيموجي مسطّحة
// بمفاتيح وردية، بلا بطاقات مرفوعة ولا أيقونات رمادية.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'widgets.dart';

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(settingsProvider).valueOrNull ?? {};

    Future<void> save(String key, bool v) async {
      await ref.read(repoProvider).setSetting(key, v ? '1' : '0');
      ref.invalidate(settingsProvider);
    }

    Widget row({
      required String emoji,
      required String title,
      required String sub,
      required String key,
      String on = '1',
      void Function(bool)? after,
    }) {
      final v = (st[key] ?? on) == '1';
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          EmojiTile(
            emoji: emoji,
            title: title,
            subtitle: sub,
            trailing: pinkSwitch(
              value: v,
              onChanged: (x) async {
                await save(key, x);
                after?.call(x);
              },
            ),
          ),
          const Divider(height: 0.7, color: AppColors.border),
        ],
      );
    }

    return Scaffold(
      appBar: simpleBar(context, 'المظهر والأصوات'),
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          const SectionLabel('العرض'),
          row(
            emoji: '🔠',
            title: 'خط أكبر في لوحة التحكم',
            sub: 'تكبير الأرقام والعناوين',
            key: 'bigText',
          ),
          const SectionLabel('الأصوات والاهتزاز'),
          row(
            emoji: '🔇',
            title: 'الوضع الصامت',
            sub: 'كتم كل الأصوات والاهتزازات — تصل الإشعارات صامتة',
            key: 'sfxMute',
            on: '0',
            after: (v) {
              Sfx.applySettings(
                sound: (st['sfxSound'] ?? '1') == '1',
                haptic: (st['sfxHaptic'] ?? '1') == '1',
                mute: v,
              );
              if (!v) Sfx.pop();
            },
          ),
          row(
            emoji: '🔊',
            title: 'الأصوات',
            sub: 'نغمات النجاح والخطأ والأزرار',
            key: 'sfxSound',
            after: (v) {
              Sfx.applySettings(
                  sound: v, haptic: (st['sfxHaptic'] ?? '1') == '1');
              if (v) Sfx.pop();
            },
          ),
          row(
            emoji: '📳',
            title: 'الاهتزاز',
            sub: 'ردود اهتزازية عند الحفظ والدفع',
            key: 'sfxHaptic',
            after: (v) {
              Sfx.applySettings(
                  sound: (st['sfxSound'] ?? '1') == '1', haptic: v);
              if (v) Sfx.success();
            },
          ),
          const SectionLabel('معاينة'),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Text(
              'لكل نوع تفاعل صوت مميز — اضغط أي زر لتجربته.',
              style: const TextStyle(fontSize: 12, color: AppColors.text3),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 20),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (_, label, play) in Sfx.previewable())
                  InkWell(
                    onTap: play,
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        border: Border.all(color: AppColors.border),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.play_arrow,
                              size: 15, color: AppColors.primary),
                          const SizedBox(width: 4),
                          Text(label,
                              style: const TextStyle(
                                  fontSize: 12, color: AppColors.text)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

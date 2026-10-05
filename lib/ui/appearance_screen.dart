// شاشة المظهر المستقلة: حجم الخط، والأصوات/الاهتزاز.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(settingsProvider).valueOrNull ?? {};
    return Scaffold(
      appBar: AppBar(title: const Text('المظهر والأصوات')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.format_size),
                  title: const Text('خط أكبر في لوحة التحكم'),
                  subtitle: const Text('تكبير الأرقام والعناوين'),
                  value: (st['bigText'] ?? '1') == '1',
                  onChanged: (v) async {
                    await ref
                        .read(repoProvider)
                        .setSetting('bigText', v ? '1' : '0');
                    ref.invalidate(settingsProvider);
                  },
                ),
                const Divider(height: 1),
                // (دفعة 58 — متطلب 7) الوضع الصامت الشامل: يكتم كل الأصوات
                // والاهتزازات وحتى صوت إشعارات النظام الخارجية بمفتاح واحد.
                SwitchListTile(
                  secondary: const Icon(Icons.volume_off_outlined),
                  title: const Text('الوضع الصامت'),
                  subtitle: const Text(
                      'كتم كل الأصوات والاهتزازات — تصل الإشعارات صامتة'),
                  value: (st['sfxMute'] ?? '0') == '1',
                  onChanged: (v) async {
                    await ref
                        .read(repoProvider)
                        .setSetting('sfxMute', v ? '1' : '0');
                    Sfx.applySettings(
                      sound: (st['sfxSound'] ?? '1') == '1',
                      haptic: (st['sfxHaptic'] ?? '1') == '1',
                      mute: v,
                    );
                    if (!v) Sfx.pop();
                    ref.invalidate(settingsProvider);
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.volume_up_outlined),
                  title: const Text('الأصوات'),
                  subtitle: const Text('نغمات النجاح والخطأ والأزرار'),
                  value: (st['sfxSound'] ?? '1') == '1',
                  onChanged: (v) async {
                    await ref
                        .read(repoProvider)
                        .setSetting('sfxSound', v ? '1' : '0');
                    Sfx.applySettings(
                        sound: v, haptic: (st['sfxHaptic'] ?? '1') == '1');
                    if (v) Sfx.pop();
                    ref.invalidate(settingsProvider);
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.vibration_outlined),
                  title: const Text('الاهتزاز'),
                  subtitle: const Text('ردود اهتزازية عند الحفظ والدفع'),
                  value: (st['sfxHaptic'] ?? '1') == '1',
                  onChanged: (v) async {
                    await ref
                        .read(repoProvider)
                        .setSetting('sfxHaptic', v ? '1' : '0');
                    Sfx.applySettings(
                        sound: (st['sfxSound'] ?? '1') == '1', haptic: v);
                    if (v) Sfx.success();
                    ref.invalidate(settingsProvider);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // معاينة الأصوات: جرّب كل نوع تفاعل قبل استخدامه فعلياً.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.music_note_outlined,
                          color: AppColors.primaryOf(context), size: 20),
                      const SizedBox(width: 8),
                      const Text('معاينة الأصوات والاهتزازات',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 14.5)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'لكل نوع تفاعل صوت مميز — اضغط أي زر لتجربته.',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.text3Of(context)),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (_, label, play) in Sfx.previewable())
                        ActionChip(
                          avatar: const Icon(Icons.play_arrow, size: 16),
                          label: Text(label,
                              style: const TextStyle(fontSize: 12)),
                          onPressed: play,
                        ),
                    ],
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

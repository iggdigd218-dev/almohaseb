import 'package:flutter/material.dart';
import 'package:math_expressions/math_expressions.dart';
import '../core.dart';

/// حاسبة 🧮 — تُرجع النتيجة إلى حقل المبلغ
Future<double?> showCalculator(BuildContext context) {
  final ctrl = TextEditingController();
  return showDialog<double>(
    context: context,
    builder: (ctx) => AlertDialog(
      contentPadding: const EdgeInsets.all(12),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              readOnly: true,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22),
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            for (final row in [
              ['7', '8', '9', '/'],
              ['4', '5', '6', '*'],
              ['1', '2', '3', '-'],
              ['0', '.', '=', '+'],
            ])
              Row(
                children: [
                  for (final k in row)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: Material(
                          color: k == '=' ? AppColors.primary : const Color(0xFFEEEEEE),
                          borderRadius: BorderRadius.circular(6),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: () {
                              if (k == '=') {
                                try {
                                  final exp = Parser().parse(ctrl.text);
                                  final v = exp.evaluate(EvaluationType.REAL, ContextModel());
                                  ctrl.text = (v as double)
                                      .toStringAsFixed(2)
                                      .replaceAll(RegExp(r'\.?0+$'), '');
                                } catch (_) {
                                  ctrl.text = 'خطأ';
                                }
                              } else if (k == '+' || k == '-' || k == '*' || k == '/') {
                                ctrl.text += k;
                              } else {
                                ctrl.text += k;
                              }
                              ctrl.selection =
                                  TextSelection.collapsed(offset: ctrl.text.length);
                            },
                            child: Container(
                              alignment: Alignment.center,
                              height: 42,
                              child: Text(
                                k == '*' ? '×' : k == '/' ? '÷' : k,
                                style: TextStyle(
                                    fontSize: 18,
                                    color: k == '=' ? Colors.white : AppColors.ink),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء', style: TextStyle(color: AppColors.sub))),
        TextButton(
          onPressed: () {
            final v = double.tryParse(ctrl.text.trim().replaceAll(',', '')) ?? 0;
            Navigator.pop(ctx, v);
          },
          child: const Text('إدخال', style: TextStyle(color: AppColors.primary)),
        ),
      ],
    ),
  );
}

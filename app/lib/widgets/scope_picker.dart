import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';

const _kSteps = [
  (value: 'step1', label: 'Step 1',    subtitle: 'Basic sciences'),
  (value: 'step2', label: 'Step 2 CK', subtitle: 'Clinical dx & tx'),
  (value: 'step3', label: 'Step 3',    subtitle: 'Patient mgmt'),
];

/// Horizontal pill row that reads/writes AppState.usmleStep and persists it.
class ScopePicker extends StatelessWidget {
  const ScopePicker({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.school_rounded, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Text('Exam scope', style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w500)),
        ]),
        const SizedBox(height: 10),
        Row(
          children: _kSteps.map((s) {
            final active = state.usmleStep == s.value;
            return Expanded(
              child: GestureDetector(
                onTap: () {
                  state.usmleStep = s.value;
                  state.saveSettings();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  margin: EdgeInsets.only(right: s.value == 'step3' ? 0 : 8),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: active ? cs.primary : cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: active ? cs.primary : cs.outlineVariant),
                  ),
                  child: Column(children: [
                    Text(s.label, style: tt.labelMedium?.copyWith(
                      color: active ? cs.onPrimary : cs.onSurface,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    )),
                    const SizedBox(height: 2),
                    Text(s.subtitle, style: tt.bodySmall?.copyWith(
                      color: active ? cs.onPrimary.withOpacity(0.8) : cs.onSurfaceVariant,
                      fontSize: 10,
                    )),
                  ]),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

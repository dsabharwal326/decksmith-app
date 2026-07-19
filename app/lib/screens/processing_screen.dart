import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/api_service.dart';

class ProcessingScreen extends StatelessWidget {
  const ProcessingScreen({super.key});

  Future<void> _cancel(BuildContext context) async {
    final state = context.read<AppState>();
    final jobId = state.activeJobId;
    if (jobId != null) {
      await ApiService(state).cancelJob(jobId);
    }
    state.setError('Cancelled');
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final hasJob = state.activeJobId != null;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 56,
              height: 56,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 28),
            Text(state.processingStatus.isEmpty ? 'Working…' : state.processingStatus,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: state.processingProgress),
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOut,
                builder: (_, value, __) => LinearProgressIndicator(
                  value: value,
                  minHeight: 6,
                ),
              ),
            ),
            if (hasJob) ...[
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: () => _cancel(context),
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('Cancel'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                  side: BorderSide(color: Theme.of(context).colorScheme.error.withOpacity(0.5)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

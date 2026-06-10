import 'package:flutter/material.dart';
import '../../../../core/theme/app_theme.dart';

/// Shows MIUI-specific guidance for disabling battery optimization
/// and enabling auto-start, which are the root causes of 15-minute kill.
class XiaomiGuidanceDialog extends StatelessWidget {
  final VoidCallback onDismiss;

  const XiaomiGuidanceDialog({super.key, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.surfaceColor,
      title: const Row(
        children: [
          Text('⚠️', style: TextStyle(fontSize: 20)),
          SizedBox(width: 8),
          Text(
            'Xiaomi Battery Settings',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'MIUI may stop location tracking after ~15 minutes. '
              'Follow these steps to fix it:',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 16),
            const _Step(
              number: '1',
              text: 'Settings → Apps → Driver Tracker → Battery Saver → No restrictions',
            ),
            const _Step(
              number: '2',
              text: 'Security → Permissions → Auto-start → Enable for Driver Tracker',
            ),
            const _Step(
              number: '3',
              text: 'Settings → Battery & Performance → App Battery Saver → Driver Tracker → No restrictions',
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.warningColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.warningColor.withOpacity(0.3)),
              ),
              child: const Text(
                'Without these settings, tracking may stop when your screen locks.',
                style: TextStyle(
                  color: AppTheme.warningColor,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: onDismiss,
          child: const Text(
            'Got it',
            style: TextStyle(color: AppTheme.primaryColor),
          ),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  final String number;
  final String text;

  const _Step({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withOpacity(0.2),
              shape: BoxShape.circle,
              border: Border.all(color: AppTheme.primaryColor.withOpacity(0.5)),
            ),
            child: Center(
              child: Text(
                number,
                style: const TextStyle(
                  color: AppTheme.primaryColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

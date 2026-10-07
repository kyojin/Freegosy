import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/save/save_sync_service.dart';
import '../../core/save/state_sync_service.dart';

class SaveConflictDialog extends StatelessWidget {
  final String _gameName;
  final DateTime _localTime;
  final DateTime _cloudTime;
  final String? _targetSlot;

  /// What the two copies are, as it reads in the dialog sentence
  /// (`...local and cloud $subject have been modified`).
  final String _subject;

  SaveConflictDialog({super.key, required SaveConflictException conflict})
      : _gameName = conflict.game.name,
        _localTime = conflict.localTime,
        _cloudTime = conflict.cloudTime,
        _targetSlot = conflict.targetSlot,
        _subject = 'saves';

  SaveConflictDialog.forState({super.key, required StateConflict conflict})
      : _gameName = conflict.game.name,
        _localTime = conflict.localTime,
        _cloudTime = conflict.cloudTime,
        _targetSlot = null,
        _subject = 'versions of save state "${conflict.fileName}"';

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.orange),
          SizedBox(width: 12),
          Text('Sync Conflict Detected'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _targetSlot == null
                ? 'Both local and cloud $_subject have been modified for $_gameName. Please choose which version to keep.'
                : 'The "$_targetSlot" RomM slot already has a save for $_gameName. '
                    'Choose whether to replace it with this PC’s save or restore the cloud save.',
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 24),
          _buildOption(
            context,
            title: 'Use Local Version',
            time: _localTime,
            dateFormat: dateFormat,
            icon: Icons.computer,
            onTap: () => Navigator.pop(context, 'local'),
            isNewer: _localTime.isAfter(_cloudTime),
          ),
          const SizedBox(height: 12),
          _buildOption(
            context,
            title: 'Use Cloud Version',
            time: _cloudTime,
            dateFormat: dateFormat,
            icon: Icons.cloud_outlined,
            onTap: () => Navigator.pop(context, 'cloud'),
            isNewer: _cloudTime.isAfter(_localTime),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel Sync'),
        ),
      ],
    );
  }

  Widget _buildOption(
    BuildContext context, {
    required String title,
    required DateTime time,
    required DateFormat dateFormat,
    required IconData icon,
    required VoidCallback onTap,
    required bool isNewer,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(
            color: isNewer ? Colors.deepPurple : Colors.grey.withValues(alpha: 0.3),
            width: isNewer ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
          color: isNewer ? Colors.deepPurple.withValues(alpha: 0.05) : null,
        ),
        child: Row(
          children: [
            Icon(icon, color: isNewer ? Colors.deepPurple : Colors.grey),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                      if (isNewer) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.green,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'NEWER',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    'Modified: ${dateFormat.format(time)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}

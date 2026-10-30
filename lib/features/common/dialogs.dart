import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../core/catalog_models.dart';
import '../../data/device/device_bridge.dart';

Future<String?> promptText(
  BuildContext context, {
  required String title,
  required String label,
  String initialValue = '',
  String action = 'Save',
  int maxLength = 120,
}) async {
  final controller = TextEditingController(text: initialValue);
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: AppText(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: maxLength,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          labelText: context.tr(label),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const AppText('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: AppText(action),
        ),
      ],
    ),
  );
  controller.dispose();
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: AppText(title),
        content: AppText(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const AppText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: AppText(action),
          ),
        ],
      ),
    ) ==
    true;

/// Confirms an action that cannot be undone, then asks for the phone's
/// fingerprint, face or screen-lock PIN. Phones without a screen lock rely on
/// the dialog alone.
Future<bool> confirmIrreversible(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
  DeviceBridge? device,
}) async {
  if (!await confirmAction(
        context,
        title: title,
        message: message,
        action: action,
      ) ||
      !context.mounted) {
    return false;
  }
  final check = await (device ?? DeviceBridge.instance).confirmUser(
    title: title,
    subtitle: 'Confirm it\'s you to continue.',
  );
  return check != UserCheck.cancelled;
}

/// Asks for a password; with [confirm] the user must type it twice.
Future<String?> promptPassword(
  BuildContext context, {
  required String title,
  String? message,
  bool confirm = false,
}) async {
  final first = TextEditingController();
  final second = TextEditingController();
  String? error;
  final value = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: AppText(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message != null) ...[Text(message), const SizedBox(height: 12)],
            TextField(
              controller: first,
              autofocus: true,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(labelText: context.tr('Password')),
            ),
            if (confirm)
              TextField(
                controller: second,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: context.tr('Confirm password'),
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const AppText('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (confirm && first.text.length < 10) {
                setState(() => error = 'Use at least 10 characters.');
              } else if (confirm && first.text != second.text) {
                setState(() => error = 'Passwords do not match.');
              } else if (first.text.isNotEmpty) {
                Navigator.pop(context, first.text);
              }
            },
            child: const AppText('Continue'),
          ),
        ],
      ),
    ),
  );
  first.dispose();
  second.dispose();
  return value;
}

/// Lets the user pick an album, or create one inline.
Future<String?> pickAlbum(
  BuildContext context,
  List<MediaAlbum> albums, {
  required Future<void> Function(String name) createAlbum,
}) => showModalBottomSheet<String>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: AppText(
              'Add to album',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.add_rounded),
            title: const AppText('New album'),
            onTap: () async {
              final name = await promptText(
                context,
                title: 'Create album',
                label: 'Album name',
                action: 'Create',
              );
              if (name == null) return;
              await createAlbum(name);
              if (context.mounted) Navigator.pop(context, 'new:$name');
            },
          ),
          for (final album in albums.where((album) => !album.isReadOnly))
            ListTile(
              leading: const Icon(Icons.photo_album_rounded),
              title: Text(album.name),
              subtitle: Text('${album.itemIds.length} items'),
              onTap: () => Navigator.pop(context, album.id),
            ),
        ],
      ),
    ),
  ),
);

/// Resolves a [pickAlbum] result to an album id; new albums are the newest
/// album with the chosen name.
String? resolvePickedAlbum(String? picked, List<MediaAlbum> albums) {
  if (picked == null || !picked.startsWith('new:')) return picked;
  final name = picked.substring(4);
  final matches = albums.where((album) => album.name == name).toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return matches.isEmpty ? null : matches.first.id;
}

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

String friendlyError(Object error) {
  final text = error
      .toString()
      .replaceFirst(RegExp(r'^[A-Za-z]+(Exception|Error): '), '')
      .replaceFirst('Bad state: ', '')
      .replaceFirst('Unsupported operation: ', '');
  return text.length > 200 ? '${text.substring(0, 200)}…' : text;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// "1 item", "3 items".
String itemCount(int count) => count == 1 ? '1 item' : '$count items';

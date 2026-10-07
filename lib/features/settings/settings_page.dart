import 'package:flutter/material.dart';

import '../../core/gallery_settings.dart';
import '../../src/gallery_model.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({required this.model, required this.isWindows, super.key});
  final GalleryModel model;
  final bool isWindows;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: AnimatedBuilder(animation: model, builder: (context, _) => ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Appearance', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        DropdownButtonFormField<GalleryAppearance>(
          initialValue: model.settings.appearance,
          decoration: const InputDecoration(labelText: 'Theme', border: OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: GalleryAppearance.system, child: Text('Use device theme')),
            DropdownMenuItem(value: GalleryAppearance.light, child: Text('Light')),
            DropdownMenuItem(value: GalleryAppearance.dark, child: Text('Dark')),
          ],
          onChanged: (value) {
            if (value != null) model.updateSettings(model.settings.copyWith(appearance: value));
          },
        ),
        const SizedBox(height: 24),
        Text('Library', style: Theme.of(context).textTheme.titleLarge),
        if (isWindows) ...[
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Refresh PC folders automatically'),
            subtitle: const Text('Keep selected folders up to date when files change or drives reconnect.'),
            value: model.settings.autoRefresh,
            onChanged: (value) => model.updateSettings(model.settings.copyWith(autoRefresh: value)),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Include hidden files'),
            subtitle: const Text('Show hidden files inside the folders you selected.'),
            value: model.settings.includeHiddenFiles,
            onChanged: (value) => model.updateSettings(model.settings.copyWith(includeHiddenFiles: value)),
          ),
        ] else ...[
          ListTile(contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose photos and videos'),
            subtitle: Text(model.hasLimitedAccess ? 'Access is limited to selected media.' : 'Choose which media nexGallery may read.'),
            onTap: model.requestAccessAndRefresh,
          ),
          ListTile(contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.manage_accounts_outlined),
            title: const Text('Android app permissions'), onTap: model.openAccessSettings,
          ),
        ],
        const SizedBox(height: 24),
        Text('Privacy', style: Theme.of(context).textTheme.titleLarge),
        const ListTile(contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.shield_outlined), title: Text('Local library'),
          subtitle: Text('Your library, albums, settings and playback positions stay on this device. Remote access is configured separately.'),
        ),
        if (model.errorMessage != null)
          Text(model.errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    )),
  );
}

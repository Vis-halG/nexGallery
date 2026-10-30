import 'package:flutter/widgets.dart';

import 'background_backup.dart';

@pragma('vm:entry-point')
Future<void> backgroundBackupEntry() async {
  WidgetsFlutterBinding.ensureInitialized();
  await runBackgroundBackup();
}

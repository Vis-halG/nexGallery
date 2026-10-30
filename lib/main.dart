import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'src/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      ['Natural Earth'],
      await rootBundle.loadString('docs/third-party/NATURAL_EARTH_NOTICE.txt'),
    );
    yield LicenseEntryWithLineBreaks([
      'OpenCV YuNet',
    ], await rootBundle.loadString('docs/third-party/YUNET_LICENSE.txt'));
    yield LicenseEntryWithLineBreaks([
      'OpenCV SFace',
    ], await rootBundle.loadString('docs/third-party/SFACE_LICENSE.txt'));
    yield LicenseEntryWithLineBreaks([
      'GeoNames',
    ], await rootBundle.loadString('docs/third-party/GEONAMES_NOTICE.txt'));
    yield LicenseEntryWithLineBreaks([
      'MobileNetV2',
      'PaddleOCR',
      'RapidOCR',
    ], await rootBundle.loadString('docs/third-party/MODEL_PACKS_NOTICE.txt'));
  });
  runApp(const NexGalleryApp());
}

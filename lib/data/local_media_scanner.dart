import 'local_media_scanner_stub.dart'
    if (dart.library.io) 'local_media_scanner_io.dart'
    as platform;

export 'local_media_scanner_types.dart';

import 'local_media_scanner_types.dart';

LocalMediaScanner createLocalMediaScanner() =>
    platform.createLocalMediaScanner();

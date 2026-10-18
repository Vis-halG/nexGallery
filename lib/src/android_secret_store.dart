import '../data/android_media/android_media_bridge.dart';
import '../services/remote/remote_session.dart';

/// Stores the pairing secret with the Android Keystore-wrapped bridge.
final class AndroidSecretStore implements SecretStore {
  const AndroidSecretStore();

  @override
  Future<String?> read(String key) =>
      AndroidMediaBridge.instance.readSecret(key);

  @override
  Future<void> write(String key, String value) =>
      AndroidMediaBridge.instance.storeSecret(key, value);

  @override
  Future<void> delete(String key) async {
    await AndroidMediaBridge.instance.deleteSecret(key);
  }
}

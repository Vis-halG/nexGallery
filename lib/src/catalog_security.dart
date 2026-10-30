/// Optional capabilities exposed by the device-backed gallery.
abstract interface class CatalogSecurity {
  bool get catalogueEncrypted;
  Future<void> setCatalogueEncryption(bool enabled);
}

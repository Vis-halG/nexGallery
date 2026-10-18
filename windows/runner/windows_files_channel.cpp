#include "windows_files_channel.h"

#include <flutter/standard_method_codec.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <iomanip>
#include <cwchar>
#include <sstream>
#include <string>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

std::string ToUtf8(const wchar_t* value) {
  const int length = static_cast<int>(wcslen(value));
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value,
                                     length, nullptr, 0, nullptr, nullptr);
  if (size <= 0) return std::string();
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, length,
                      result.data(), size, nullptr, nullptr);
  return result;
}

std::wstring FromUtf8(const std::string& value) {
  const int length = static_cast<int>(value.length());
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                     value.data(), length, nullptr, 0);
  if (size <= 0) return std::wstring();
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), length,
                      result.data(), size);
  return result;
}

std::string FileIdentity(const std::string& path) {
  const auto wide_path = FromUtf8(path);
  if (wide_path.empty()) return std::string();
  HANDLE file = CreateFileW(wide_path.c_str(), FILE_READ_ATTRIBUTES,
                            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING,
                            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) return std::string();
  FILE_ID_INFO identity{};
  FILE_BASIC_INFO basic{};
  const bool succeeded =
      GetFileInformationByHandleEx(file, FileIdInfo, &identity, sizeof(identity)) &&
      GetFileInformationByHandleEx(file, FileBasicInfo, &basic, sizeof(basic));
  CloseHandle(file);
  if (!succeeded) return std::string();
  if ((basic.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0) {
    return std::string();
  }

  std::ostringstream result;
  result << "winfile_" << std::hex << std::setfill('0') << std::setw(16)
         << identity.VolumeSerialNumber << '_';
  for (const auto byte : identity.FileId.Identifier) {
    result << std::setw(2) << static_cast<unsigned int>(byte);
  }
  // Creation time prevents accidentally inheriting metadata from a recycled ID.
  result << '_' << std::setw(16) << basic.CreationTime.QuadPart;
  return result.str();
}

}  // namespace

WindowsFilesChannel::WindowsFilesChannel(flutter::BinaryMessenger* messenger,
                                         HWND owner)
    : owner_(owner) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "nexgallery/windows_files",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() == "chooseFolder") {
          if (dialog_open_) {
            result->Error("dialog_busy", "A folder dialog is already open.");
            return;
          }
          dialog_open_ = true;
          ComPtr<IFileOpenDialog> dialog;
          HRESULT status = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                            CLSCTX_INPROC_SERVER,
                                            IID_PPV_ARGS(&dialog));
          if (SUCCEEDED(status)) {
            FILEOPENDIALOGOPTIONS options;
            status = dialog->GetOptions(&options);
            if (SUCCEEDED(status)) {
              status = dialog->SetOptions(options | FOS_PICKFOLDERS |
                                          FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST |
                                          FOS_NOCHANGEDIR);
            }
            if (SUCCEEDED(status)) status = dialog->SetTitle(L"Choose a folder for nexGallery");
            if (SUCCEEDED(status)) status = dialog->SetOkButtonLabel(L"Add folder");
            if (SUCCEEDED(status)) status = dialog->Show(owner_);
          }
          dialog_open_ = false;
          if (status == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
            result->Success();
            return;
          }
          ComPtr<IShellItem> folder;
          if (SUCCEEDED(status)) status = dialog->GetResult(&folder);
          PWSTR path = nullptr;
          if (SUCCEEDED(status)) status = folder->GetDisplayName(SIGDN_FILESYSPATH, &path);
          if (FAILED(status) || path == nullptr) {
            if (path != nullptr) CoTaskMemFree(path);
            result->Error("folder_dialog_failed", "Windows could not select this folder.",
                          EncodableValue(static_cast<int64_t>(status)));
            return;
          }
          const std::string selected = ToUtf8(path);
          CoTaskMemFree(path);
          if (selected.empty()) {
            result->Error("folder_path_invalid", "Windows returned an invalid folder path.");
            return;
          }
          result->Success(EncodableValue(selected));
          return;
        }
        if (call.method_name() == "setPrivacyScreen") {
          const auto* arguments = call.arguments() == nullptr ? nullptr : std::get_if<EncodableMap>(call.arguments());
          const auto entry = arguments == nullptr ? EncodableMap::const_iterator() : arguments->find(EncodableValue("enabled"));
          const auto* enabled = arguments == nullptr || entry == arguments->end() ? nullptr : std::get_if<bool>(&entry->second);
          if (enabled == nullptr) { result->Error("invalid_argument", "Provide enabled."); return; }
          // WDA_EXCLUDEFROMCAPTURE on Windows 10 2004+, WDA_MONITOR on older builds.
          if (!SetWindowDisplayAffinity(owner_, *enabled ? 0x00000011 : WDA_NONE) &&
              !SetWindowDisplayAffinity(owner_, *enabled ? WDA_MONITOR : WDA_NONE)) {
            result->Error("privacy_failed", "Windows could not protect this window from capture."); return;
          }
          result->Success(); return;
        }
        if (call.method_name() == "fileIdentities") {
          const auto* arguments = call.arguments() == nullptr
                                      ? nullptr
                                      : std::get_if<EncodableMap>(call.arguments());
          const auto entry = arguments == nullptr
                                 ? EncodableMap::const_iterator()
                                 : arguments->find(EncodableValue("paths"));
          const auto* paths = arguments == nullptr || entry == arguments->end()
                                  ? nullptr
                                  : std::get_if<flutter::EncodableList>(&entry->second);
          if (paths == nullptr || paths->size() > 256) {
            result->Error("invalid_paths", "Provide at most 256 file paths.");
            return;
          }
          EncodableMap identities;
          for (const auto& value : *paths) {
            const auto* path = std::get_if<std::string>(&value);
            if (path == nullptr || path->empty() || path->find('\0') != std::string::npos) {
              result->Error("invalid_path", "Every path must be a non-empty string.");
              return;
            }
            const auto identity = FileIdentity(*path);
            if (!identity.empty()) {
              identities.emplace(EncodableValue(*path), EncodableValue(identity));
            }
          }
          result->Success(EncodableValue(identities));
          return;
        }
        result->NotImplemented();
      });
}

WindowsFilesChannel::~WindowsFilesChannel() {
  channel_->SetMethodCallHandler(nullptr);
}

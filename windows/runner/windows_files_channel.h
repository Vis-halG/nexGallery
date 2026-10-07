#ifndef RUNNER_WINDOWS_FILES_CHANNEL_H_
#define RUNNER_WINDOWS_FILES_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// Native capabilities remain scoped to explicit calls from the local UI.
class WindowsFilesChannel {
 public:
  WindowsFilesChannel(flutter::BinaryMessenger* messenger, HWND owner);
  ~WindowsFilesChannel();

 private:
  HWND owner_;
  bool dialog_open_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_WINDOWS_FILES_CHANNEL_H_

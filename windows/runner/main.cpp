#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kSingleInstanceMutexName[] =
    L"Local\\FreeVPNFinder.SingleInstance";
constexpr wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"Free VPN Finder";

HWND FindMainWindow() {
  HWND window = FindWindowW(kWindowClassName, kWindowTitle);
  if (window == nullptr) {
    window = FindWindowW(nullptr, kWindowTitle);
  }
  return window;
}

void FocusMainWindow() {
  HWND window = nullptr;
  // The first process may still be creating its Flutter window when the
  // second launch is rejected.
  for (int attempt = 0; attempt < 40 && window == nullptr; ++attempt) {
    window = FindMainWindow();
    if (window == nullptr) {
      Sleep(50);
    }
  }
  if (window == nullptr) {
    return;
  }
  if (IsIconic(window)) {
    ShowWindow(window, SW_RESTORE);
  } else {
    ShowWindow(window, SW_SHOW);
  }
  BringWindowToTop(window);
  SetForegroundWindow(window);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE single_instance_mutex =
      CreateMutexW(nullptr, TRUE, kSingleInstanceMutexName);
  const bool another_instance_running =
      single_instance_mutex != nullptr && GetLastError() == ERROR_ALREADY_EXISTS;
  if (another_instance_running ||
      (single_instance_mutex != nullptr && FindMainWindow() != nullptr)) {
    FocusMainWindow();
    if (single_instance_mutex != nullptr) {
      CloseHandle(single_instance_mutex);
    }
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1080, 720);
  if (!window.Create(L"Free VPN Finder", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(false);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance_mutex != nullptr) {
    CloseHandle(single_instance_mutex);
  }
  return EXIT_SUCCESS;
}

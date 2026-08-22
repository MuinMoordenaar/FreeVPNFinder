#include <windows.h>

#include <cwchar>
#include <string>

int wmain(int argc, wchar_t** argv) {
  if (argc < 6) return 2;
  const DWORD process_id = std::wcstoul(argv[1], nullptr, 10);
  const std::wstring installer = argv[2];
  const std::wstring install_dir = argv[3];
  const std::wstring executable = argv[4];
  const std::wstring log = argv[5];

  HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, process_id);
  if (process != nullptr) {
    WaitForSingleObject(process, INFINITE);
    CloseHandle(process);
  }

  std::wstring command = L"\"" + installer + L"\" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /DIR=\"" + install_dir + L"\" /LOG=\"" + log + L"\"";
  STARTUPINFOW startup = {sizeof(startup)};
  PROCESS_INFORMATION info = {};
  if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, 0,
                      nullptr, install_dir.c_str(), &startup, &info)) {
    return static_cast<int>(GetLastError());
  }
  WaitForSingleObject(info.hProcess, INFINITE);
  DWORD exit_code = 1;
  GetExitCodeProcess(info.hProcess, &exit_code);
  CloseHandle(info.hThread);
  CloseHandle(info.hProcess);
  if (exit_code != 0) return static_cast<int>(exit_code);

  ShellExecuteW(nullptr, L"open", executable.c_str(), nullptr,
                install_dir.c_str(), SW_SHOWNORMAL);
  return 0;
}

#include <windows.h>
#include <shlobj.h>

#include <algorithm>
#include <cwctype>
#include <fstream>
#include <string>
#include <vector>

namespace {

std::wstring Quote(const std::wstring& value) {
  std::wstring out = L"\"";
  for (wchar_t ch : value) {
    if (ch == L'\"') {
      out += L"\\\"";
    } else {
      out += ch;
    }
  }
  out += L"\"";
  return out;
}

void AppendLog(const std::wstring& path, const std::wstring& message) {
  if (path.empty()) return;
  HANDLE file = CreateFileW(
      path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
      nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;

  SYSTEMTIME st{};
  GetLocalTime(&st);
  wchar_t prefix[64]{};
  swprintf_s(prefix, L"[%04u-%02u-%02u %02u:%02u:%02u] ",
             st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
  std::wstring line = prefix + message + L"\r\n";
  int bytes_needed =
      WideCharToMultiByte(CP_UTF8, 0, line.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (bytes_needed > 1) {
    std::string utf8(static_cast<size_t>(bytes_needed - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, line.c_str(), -1, utf8.data(), bytes_needed,
                        nullptr, nullptr);
    DWORD written = 0;
    WriteFile(file, utf8.data(), static_cast<DWORD>(utf8.size()), &written, nullptr);
  }
  CloseHandle(file);
}

void WriteStatus(const std::wstring& path, const std::wstring& value) {
  if (path.empty()) return;
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  int bytes_needed =
      WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (bytes_needed > 1) {
    std::string utf8(static_cast<size_t>(bytes_needed - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, utf8.data(), bytes_needed,
                        nullptr, nullptr);
    DWORD written = 0;
    WriteFile(file, utf8.data(), static_cast<DWORD>(utf8.size()), &written, nullptr);
  }
  CloseHandle(file);
}

bool FileExists(const std::wstring& path) {
  const DWORD attrs = GetFileAttributesW(path.c_str());
  return attrs != INVALID_FILE_ATTRIBUTES &&
         (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

std::wstring ReadRegistryInstallLocation(HKEY root, const wchar_t* subkey_root) {
  HKEY root_key = nullptr;
  if (RegOpenKeyExW(root, subkey_root, 0, KEY_READ, &root_key) != ERROR_SUCCESS) {
    return L"";
  }

  DWORD index = 0;
  wchar_t child_name[256]{};
  DWORD child_len = 256;
  while (RegEnumKeyExW(root_key, index++, child_name, &child_len, nullptr, nullptr,
                       nullptr, nullptr) == ERROR_SUCCESS) {
    child_len = 256;
    HKEY child = nullptr;
    if (RegOpenKeyExW(root_key, child_name, 0, KEY_READ, &child) != ERROR_SUCCESS) {
      continue;
    }

    wchar_t display_name[512]{};
    DWORD display_size = sizeof(display_name);
    DWORD type = 0;
    const LONG name_result =
        RegQueryValueExW(child, L"DisplayName", nullptr, &type,
                         reinterpret_cast<LPBYTE>(display_name), &display_size);
    if (name_result == ERROR_SUCCESS && type == REG_SZ &&
        _wcsicmp(display_name, L"Orvix") == 0) {
      wchar_t install_location[MAX_PATH * 4]{};
      DWORD location_size = sizeof(install_location);
      type = 0;
      const LONG location_result =
          RegQueryValueExW(child, L"InstallLocation", nullptr, &type,
                           reinterpret_cast<LPBYTE>(install_location),
                           &location_size);
      RegCloseKey(child);
      RegCloseKey(root_key);
      if (location_result == ERROR_SUCCESS && type == REG_SZ) {
        std::wstring location = install_location;
        if (!location.empty() && location.back() != L'\\') location += L'\\';
        return location + L"orvix.exe";
      }
      return L"";
    }
    RegCloseKey(child);
  }

  RegCloseKey(root_key);
  return L"";
}

std::wstring FindInstalledOrvix(const std::wstring& fallback) {
  const wchar_t* uninstall = L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall";
  std::wstring candidate = ReadRegistryInstallLocation(HKEY_CURRENT_USER, uninstall);
  if (FileExists(candidate)) return candidate;

  candidate = ReadRegistryInstallLocation(HKEY_LOCAL_MACHINE, uninstall);
  if (FileExists(candidate)) return candidate;

  PWSTR local_app_data = nullptr;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                     &local_app_data)) &&
      local_app_data != nullptr) {
    candidate = std::wstring(local_app_data) + L"\\Programs\\Orvix\\orvix.exe";
    CoTaskMemFree(local_app_data);
    if (FileExists(candidate)) return candidate;
  }

  if (FileExists(fallback)) return fallback;
  return L"";
}

bool StartProcessAndWait(const std::wstring& executable,
                         const std::wstring& arguments,
                         DWORD* exit_code) {
  std::wstring command = Quote(executable);
  if (!arguments.empty()) {
    command += L" ";
    command += arguments;
  }

  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  std::vector<wchar_t> buffer(command.begin(), command.end());
  buffer.push_back(L'\0');

  if (!CreateProcessW(nullptr, buffer.data(), nullptr, nullptr, FALSE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
    return false;
  }

  WaitForSingleObject(pi.hProcess, INFINITE);
  DWORD code = 1;
  GetExitCodeProcess(pi.hProcess, &code);
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  if (exit_code != nullptr) *exit_code = code;
  return true;
}

bool StartDetached(const std::wstring& executable) {
  if (executable.empty()) return false;
  std::wstring command = Quote(executable);
  std::vector<wchar_t> buffer(command.begin(), command.end());
  buffer.push_back(L'\0');

  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  const BOOL ok = CreateProcessW(
      nullptr, buffer.data(), nullptr, nullptr, FALSE,
      DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP, nullptr, nullptr, &si, &pi);
  if (ok) {
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  }
  return ok == TRUE;
}

std::wstring ArgValue(const std::vector<std::wstring>& args,
                      const std::wstring& key) {
  for (size_t i = 0; i + 1 < args.size(); ++i) {
    if (args[i] == key) return args[i + 1];
  }
  return L"";
}

bool HasArg(const std::vector<std::wstring>& args, const std::wstring& key) {
  return std::find(args.begin(), args.end(), key) != args.end();
}

}  // namespace

int wmain(int argc, wchar_t* argv[]) {
  std::vector<std::wstring> args;
  for (int i = 1; i < argc; ++i) args.emplace_back(argv[i]);

  const std::wstring parent_text = ArgValue(args, L"--parent-pid");
  const std::wstring installer = ArgValue(args, L"--installer");
  const std::wstring restart_exe = ArgValue(args, L"--restart-exe");
  const std::wstring target_version = ArgValue(args, L"--target-version");
  const std::wstring log_path = ArgValue(args, L"--log");
  const std::wstring installer_log = ArgValue(args, L"--installer-log");
  const std::wstring status_path = ArgValue(args, L"--status");
  const bool no_restart = HasArg(args, L"--no-restart");

  if (parent_text.empty() || installer.empty() || target_version.empty() ||
      status_path.empty()) {
    return 64;
  }

  const DWORD parent_pid =
      static_cast<DWORD>(wcstoul(parent_text.c_str(), nullptr, 10));
  AppendLog(log_path, L"Native updater helper started.");
  AppendLog(log_path, L"Waiting for Orvix PID " + parent_text + L" to exit.");

  HANDLE parent = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                              FALSE, parent_pid);
  if (parent != nullptr) {
    const DWORD wait = WaitForSingleObject(parent, 30000);
    CloseHandle(parent);
    if (wait != WAIT_OBJECT_0) {
      AppendLog(log_path, L"Parent process did not exit within 30 seconds.");
      WriteStatus(status_path, L"failed|parent_timeout|" + target_version);
      if (!no_restart) StartDetached(restart_exe);
      return 2;
    }
  }

  Sleep(300);
  if (!FileExists(installer)) {
    AppendLog(log_path, L"Downloaded installer no longer exists.");
    WriteStatus(status_path, L"failed|installer_missing|" + target_version);
    if (!no_restart) StartDetached(restart_exe);
    return 3;
  }

  std::wstring installer_args =
      L"/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-";
  if (!installer_log.empty()) {
    installer_args += L" /LOG=" + Quote(installer_log);
  }

  AppendLog(log_path, L"Starting installer.");
  DWORD installer_exit = 1;
  if (!StartProcessAndWait(installer, installer_args, &installer_exit)) {
    const DWORD error = GetLastError();
    AppendLog(log_path, L"CreateProcess for installer failed with Win32 error " +
                            std::to_wstring(error) + L".");
    WriteStatus(status_path, L"failed|create_process_" +
                                 std::to_wstring(error) + L"|" + target_version);
    if (!no_restart) StartDetached(restart_exe);
    return 4;
  }

  AppendLog(log_path,
            L"Installer exit code: " + std::to_wstring(installer_exit));
  if (installer_exit != 0) {
    WriteStatus(status_path, L"failed|" + std::to_wstring(installer_exit) + L"|" +
                                 target_version);
    if (!no_restart) StartDetached(restart_exe);
    return static_cast<int>(installer_exit == 0 ? 1 : installer_exit);
  }

  WriteStatus(status_path, L"success|0|" + target_version);
  if (!no_restart) {
    const std::wstring installed = FindInstalledOrvix(restart_exe);
    AppendLog(log_path, L"Launching installed Orvix: " + installed);
    StartDetached(installed);
  }
  return 0;
}

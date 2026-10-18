#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>

#include <algorithm>
#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Настройка «Запускать от имени администратора» (settings.runAsAdmin в state.json; по умолчанию
// включена, как и в Dart). Настройки в файле открытым текстом, шифруются только подписки.
bool RunAsAdminSetting(const wchar_t* app_name) {
  wchar_t appdata[MAX_PATH];
  const DWORD n = ::GetEnvironmentVariableW(L"APPDATA", appdata, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return true;
  const std::wstring path = std::wstring(appdata) + L"\\" + app_name + L"\\state.json";
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return true;
  std::string text;
  LARGE_INTEGER size{};
  if (::GetFileSizeEx(file, &size) && size.QuadPart > 0 && size.QuadPart < 64 * 1024 * 1024) {
    text.resize(static_cast<size_t>(size.QuadPart));
    DWORD read = 0;
    if (!::ReadFile(file, text.data(), static_cast<DWORD>(text.size()), &read, nullptr)) read = 0;
    text.resize(read);
  }
  ::CloseHandle(file);
  size_t pos = text.find("\"runAsAdmin\"");
  if (pos == std::string::npos) return true;
  pos += 12;
  while (pos < text.size() && (text[pos] == ' ' || text[pos] == ':' || text[pos] == '\r' || text[pos] == '\n')) pos++;
  return text.compare(pos, 5, "false") != 0;
}

// Права администратора просим сразу, ещё до запуска Flutter: раньше это делал Dart после загрузки
// (через PowerShell), и программа загружалась дважды — около секунды лишнего ожидания при каждом
// запуске. true — этой копии нужно выйти: запущена копия с правами или в окне Windows ответили «Нет»
// (тогда программа не открывается вовсе). Если запросить права не удалось по другой причине, к
// аргументам добавляется --no-elevate: программа работает без прав, и Dart второй раз не спрашивает.
bool RelaunchElevatedEarly(std::vector<std::string>& args, int show_command) {
  for (const auto& a : args) {
    if (a == "--elevated" || a == "--no-elevate" || a == "--quit") return false;
  }
  if (::IsUserAnAdmin()) return false;
  const wchar_t* app_name = IsDevBuild() ? L"SkipIt Dev" : L"SkipIt";
  // Программа уже открыта — аргументы ей передаст сама новая копия (main.dart), права не нужны.
  if (::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", app_name)) return false;
  if (!RunAsAdminSetting(app_name)) return false;

  wchar_t exe[MAX_PATH];
  const DWORD n = ::GetModuleFileNameW(nullptr, exe, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return false;
  // Каждый аргумент — в кавычках, а кавычки внутри него убираются: иначе ссылка skipit://… могла бы
  // добавить свои ключи (так же делал Dart, см. WinSys.relaunchAsAdmin).
  std::wstring params = L"--elevated";
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv != nullptr) {
    for (int i = 1; i < argc; i++) {
      std::wstring a = argv[i];
      a.erase(std::remove(a.begin(), a.end(), L'"'), a.end());
      params += L" \"" + a + L"\"";
    }
    ::LocalFree(argv);
  }

  SHELLEXECUTEINFOW info{sizeof(info)};
  info.fMask = SEE_MASK_NOASYNC;
  info.lpVerb = L"runas";
  info.lpFile = exe;
  info.lpParameters = params.c_str();
  info.nShow = show_command;
  if (::ShellExecuteExW(&info) || ::GetLastError() == ERROR_CANCELLED) return true;
  args.push_back("--no-elevate");
  return false;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
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
  if (RelaunchElevatedEarly(command_line_arguments, show_command)) {
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(IsDevBuild() ? L"SkipIt Dev" : L"SkipIt", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}

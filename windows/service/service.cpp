// Служба SkipIt: работает с правами системы, чтобы окну программы не нужны были права
// администратора (окно UAC при каждом запуске). Сама ничего не решает — выполняет команды
// программы, которые приходят по именованному каналу.
//
// Безопасность. Служба работает от имени системы, поэтому команды принимаются только от одного
// файла — SkipIt.exe, путь к которому записан в параметры службы при установке (их может менять
// только администратор; установщик кладёт программу в Program Files, куда без прав не записать).
// Канал создаётся первым экземпляром (FILE_FLAG_FIRST_PIPE_INSTANCE): если имя уже занял кто-то
// другой, служба не запускается. Программа со своей стороны сверяет, что на том конце канала
// именно процесс службы (см. lib\core\service_client.dart).
//
//   skipit-service.exe --install --name SkipIt --client "C:\Program Files\SkipIt\SkipIt.exe"
//   skipit-service.exe --stop --name SkipIt
//   skipit-service.exe --uninstall --name SkipIt
// Запуск без этих ключей делает Windows (диспетчер служб): --name <имя> --client <путь>.

#include <windows.h>
#include <sddl.h>

#include <iterator>
#include <string>
#include <vector>

namespace {

// Версия протокола между программой и службой: растёт, когда меняются команды.
constexpr char kProtocol[] = "skipit-service 1";

std::wstring g_name;
std::wstring g_client;
SERVICE_STATUS_HANDLE g_status_handle = nullptr;
SERVICE_STATUS g_status{};
HANDLE g_stop_event = nullptr;

std::wstring PipeName(const std::wstring& name) { return L"\\\\.\\pipe\\" + name; }

// Имя службы — только латиница и цифры: оно же имя канала и ключа в реестре.
bool NameOk(const std::wstring& name) {
  if (name.empty() || name.size() > 32) return false;
  for (wchar_t c : name) {
    if (!((c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') || (c >= L'0' && c <= L'9'))) return false;
  }
  return true;
}

std::wstring Arg(int argc, wchar_t** argv, const wchar_t* key) {
  for (int i = 1; i + 1 < argc; i++) {
    if (_wcsicmp(argv[i], key) == 0) return argv[i + 1];
  }
  return L"";
}

bool HasArg(int argc, wchar_t** argv, const wchar_t* key) {
  for (int i = 1; i < argc; i++) {
    if (_wcsicmp(argv[i], key) == 0) return true;
  }
  return false;
}

// Полный путь к exe процесса на том конце канала.
std::wstring ClientPath(HANDLE pipe) {
  ULONG pid = 0;
  if (!::GetNamedPipeClientProcessId(pipe, &pid)) return L"";
  HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) return L"";
  wchar_t path[MAX_PATH * 2];
  DWORD size = static_cast<DWORD>(std::size(path));
  const bool ok = ::QueryFullProcessImageNameW(process, 0, path, &size) != 0;
  ::CloseHandle(process);
  return ok ? std::wstring(path, size) : L"";
}

// Ответ на одну команду. Пока команда одна — «hello»: программа узнаёт, что служба на месте.
std::string Handle(const std::string& request) {
  if (request == "hello") return kProtocol;
  return "error unknown command";
}

void Serve(HANDLE pipe) {
  const std::wstring client = ClientPath(pipe);
  if (client.empty() || _wcsicmp(client.c_str(), g_client.c_str()) != 0) return;
  std::vector<char> buffer(64 * 1024);
  while (true) {
    DWORD read = 0;
    if (!::ReadFile(pipe, buffer.data(), static_cast<DWORD>(buffer.size()), &read, nullptr) || read == 0) return;
    const std::string reply = Handle(std::string(buffer.data(), read));
    DWORD written = 0;
    if (!::WriteFile(pipe, reply.data(), static_cast<DWORD>(reply.size()), &written, nullptr)) return;
  }
}

// Канал: система и администраторы — полный доступ, вошедшие в Windows пользователи — чтение и запись.
// Кто именно подключился, проверяет Serve() по пути к exe.
HANDLE CreatePipe(bool first) {
  PSECURITY_DESCRIPTOR sd = nullptr;
  if (!::ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)",
                                                             SDDL_REVISION_1, &sd, nullptr)) {
    return INVALID_HANDLE_VALUE;
  }
  SECURITY_ATTRIBUTES sa{sizeof(sa), sd, FALSE};
  DWORD mode = PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED;
  if (first) mode |= FILE_FLAG_FIRST_PIPE_INSTANCE;
  HANDLE pipe = ::CreateNamedPipeW(PipeName(g_name).c_str(), mode,
                                   PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                                   PIPE_UNLIMITED_INSTANCES, 64 * 1024, 64 * 1024, 0, &sa);
  ::LocalFree(sd);
  return pipe;
}

DWORD WINAPI ClientThread(LPVOID param) {
  HANDLE pipe = static_cast<HANDLE>(param);
  Serve(pipe);
  ::FlushFileBuffers(pipe);
  ::DisconnectNamedPipe(pipe);
  ::CloseHandle(pipe);
  return 0;
}

// Ждёт подключений, пока не придёт команда остановки. Каждое подключение — в своём потоке.
void Listen() {
  bool first = true;
  while (true) {
    HANDLE pipe = CreatePipe(first);
    if (pipe == INVALID_HANDLE_VALUE) return;
    first = false;
    OVERLAPPED ov{};
    ov.hEvent = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
    bool connected = ::ConnectNamedPipe(pipe, &ov) != 0;
    if (!connected) {
      const DWORD err = ::GetLastError();
      if (err == ERROR_PIPE_CONNECTED) {
        connected = true;
      } else if (err == ERROR_IO_PENDING) {
        HANDLE waits[] = {ov.hEvent, g_stop_event};
        if (::WaitForMultipleObjects(2, waits, FALSE, INFINITE) == WAIT_OBJECT_0) {
          DWORD unused = 0;
          connected = ::GetOverlappedResult(pipe, &ov, &unused, FALSE) != 0;
        } else {
          ::CancelIo(pipe);
          ::CloseHandle(ov.hEvent);
          ::CloseHandle(pipe);
          return;
        }
      }
    }
    ::CloseHandle(ov.hEvent);
    if (!connected) {
      ::CloseHandle(pipe);
      continue;
    }
    HANDLE thread = ::CreateThread(nullptr, 0, ClientThread, pipe, 0, nullptr);
    if (thread == nullptr) {
      ::DisconnectNamedPipe(pipe);
      ::CloseHandle(pipe);
    } else {
      ::CloseHandle(thread);
    }
  }
}

void SetState(DWORD state, DWORD exit_code = NO_ERROR) {
  g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  g_status.dwCurrentState = state;
  g_status.dwControlsAccepted = state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN : 0;
  g_status.dwWin32ExitCode = exit_code;
  g_status.dwWaitHint = state == SERVICE_RUNNING || state == SERVICE_STOPPED ? 0 : 5000;
  ::SetServiceStatus(g_status_handle, &g_status);
}

DWORD WINAPI Control(DWORD control, DWORD, LPVOID, LPVOID) {
  if (control == SERVICE_CONTROL_STOP || control == SERVICE_CONTROL_SHUTDOWN) {
    SetState(SERVICE_STOP_PENDING);
    ::SetEvent(g_stop_event);
    return NO_ERROR;
  }
  return control == SERVICE_CONTROL_INTERROGATE ? NO_ERROR : ERROR_CALL_NOT_IMPLEMENTED;
}

void WINAPI ServiceMain(DWORD, LPWSTR*) {
  g_status_handle = ::RegisterServiceCtrlHandlerExW(g_name.c_str(), Control, nullptr);
  if (g_status_handle == nullptr) return;
  g_stop_event = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  SetState(SERVICE_RUNNING);
  Listen();
  SetState(SERVICE_STOPPED);
}

// ---------- установка ----------

void Wait(SC_HANDLE service, DWORD until) {
  for (int i = 0; i < 100; i++) {
    SERVICE_STATUS status{};
    if (!::QueryServiceStatus(service, &status) || status.dwCurrentState == until) return;
    ::Sleep(100);
  }
}

void Stop(SC_HANDLE service) {
  SERVICE_STATUS status{};
  if (::ControlService(service, SERVICE_CONTROL_STOP, &status)) Wait(service, SERVICE_STOPPED);
}

int Install(const std::wstring& client) {
  wchar_t exe[MAX_PATH * 2];
  const DWORD n = ::GetModuleFileNameW(nullptr, exe, static_cast<DWORD>(std::size(exe)));
  if (n == 0 || n >= std::size(exe)) return 1;
  const std::wstring command =
      L"\"" + std::wstring(exe, n) + L"\" --name " + g_name + L" --client \"" + client + L"\"";
  SC_HANDLE scm = ::OpenSCManagerW(nullptr, nullptr, SC_MANAGER_ALL_ACCESS);
  if (scm == nullptr) return 2;
  SC_HANDLE service = ::OpenServiceW(scm, g_name.c_str(), SERVICE_ALL_ACCESS);
  if (service != nullptr) {
    // Обновление: служба уже есть — останавливаем и меняем путь к файлам.
    Stop(service);
    ::ChangeServiceConfigW(service, SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START, SERVICE_ERROR_NORMAL,
                           command.c_str(), nullptr, nullptr, nullptr, nullptr, nullptr, g_name.c_str());
  } else {
    service = ::CreateServiceW(scm, g_name.c_str(), g_name.c_str(), SERVICE_ALL_ACCESS, SERVICE_WIN32_OWN_PROCESS,
                               SERVICE_AUTO_START, SERVICE_ERROR_NORMAL, command.c_str(), nullptr, nullptr, nullptr,
                               nullptr, nullptr);
  }
  if (service == nullptr) {
    ::CloseServiceHandle(scm);
    return 3;
  }
  std::wstring text = L"Подключение SkipIt без запроса прав администратора при каждом запуске";
  SERVICE_DESCRIPTIONW description{text.data()};
  ::ChangeServiceConfig2W(service, SERVICE_CONFIG_DESCRIPTION, &description);
  // Упала — Windows перезапускает её через 5 секунд.
  SC_ACTION actions[] = {{SC_ACTION_RESTART, 5000}, {SC_ACTION_RESTART, 5000}, {SC_ACTION_NONE, 0}};
  SERVICE_FAILURE_ACTIONSW failure{86400, nullptr, nullptr, 3, actions};
  ::ChangeServiceConfig2W(service, SERVICE_CONFIG_FAILURE_ACTIONS, &failure);
  const bool started = ::StartServiceW(service, 0, nullptr) || ::GetLastError() == ERROR_SERVICE_ALREADY_RUNNING;
  if (started) Wait(service, SERVICE_RUNNING);
  ::CloseServiceHandle(service);
  ::CloseServiceHandle(scm);
  return started ? 0 : 4;
}

int StopOrUninstall(bool uninstall) {
  SC_HANDLE scm = ::OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (scm == nullptr) return 2;
  SC_HANDLE service = ::OpenServiceW(scm, g_name.c_str(), SERVICE_STOP | SERVICE_QUERY_STATUS | DELETE);
  if (service == nullptr) {
    ::CloseServiceHandle(scm);
    return 0;  // Службы нет — делать нечего.
  }
  Stop(service);
  const bool ok = !uninstall || ::DeleteService(service);
  ::CloseServiceHandle(service);
  ::CloseServiceHandle(scm);
  return ok ? 0 : 3;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  g_name = Arg(argc, argv, L"--name");
  if (!NameOk(g_name)) return 10;
  if (HasArg(argc, argv, L"--uninstall")) return StopOrUninstall(true);
  if (HasArg(argc, argv, L"--stop")) return StopOrUninstall(false);
  g_client = Arg(argc, argv, L"--client");
  if (g_client.empty()) return 11;
  if (HasArg(argc, argv, L"--install")) return Install(g_client);

  SERVICE_TABLE_ENTRYW table[] = {{g_name.data(), ServiceMain}, {nullptr, nullptr}};
  return ::StartServiceCtrlDispatcherW(table) ? 0 : 12;
}

// Служба SkipIt: работает с правами системы, чтобы окну программы не нужны были права
// администратора (окно UAC при каждом запуске). Сама ничего не решает — выполняет команды
// программы, которые приходят по именованному каналу.
//
// Безопасность. Служба работает от имени системы, поэтому:
//  - команды принимаются только от одного файла — SkipIt.exe, путь к которому записан в параметры
//    службы при установке (их может менять только администратор; установщик кладёт программу в
//    Program Files, куда без прав не записать);
//  - пользователи могут только читать и писать в канал, но не создавать его экземпляры: иначе можно
//    было бы перехватывать подключения программы. Программа со своей стороны сверяет, что на том
//    конце канала именно процесс службы (см. lib\core\service_client.dart);
//  - присланный конфиг ядра считается враждебным: ядро исполнит его с правами системы, а в конфигах
//    Xray и sing-box есть пути к файлам (журналы, кэш, сертификаты). Любой путь, который может уйти
//    за рабочую папку ядра, отклоняется (см. ConfigProblem);
//  - ядро запускается только из папки core рядом со службой, с рабочей папкой work там же
//    (в Program Files: туда без прав не записать), и живёт в задании Windows — закрылась служба,
//    закрывается и ядро. Отключилась программа — ядро тоже останавливается.
//
//   skipit-service.exe --install --name SkipIt --client "C:\Program Files\SkipIt\SkipIt.exe"
//   skipit-service.exe --stop --name SkipIt
//   skipit-service.exe --uninstall --name SkipIt
//   skipit-service.exe --check-config <файл>   (проверка конфига для тестов: «ok» или причина отказа)
// Запуск без этих ключей делает Windows (диспетчер служб): --name <имя> --client <путь>.
//
// Протокол — сообщения канала в режиме сообщений:
//   «hello»                          → «skipit-service 2»
//   «start\n<ядро>\n<папка гео>\n<конфиг>» (ядро — xray или sing-box) → «started <pid>» или «error <текст>»,
//       затем по тому же подключению: «o<кусок вывода ядра>» … «x<код выхода>».
//       Программа закрыла это подключение — ядро останавливается.
//   «stop <pid>»                     → «ok»: остановить ядро, запущенное этой службой.
//   «ks engage\n<адрес v4>\n<адрес v6>» → «ok» или «error <текст>»: Kill Switch (windows\runner\kill_switch.cpp).
//       Выпускаются ядра из папки службы и исходящий TCP самой программы. Фильтры держатся, пока открыто
//       это подключение (как и раньше: закрылась программа — Windows убирает фильтры); после «ks release»
//       по нему приходит «released».
//   «ks release»                     → «ok <ответ Windows> <фильтров осталось>».
//   «ks status»                      → «<1|0 — фильтры стоят> <фильтров в Windows>».
//   «cleanup own» / «cleanup stale»  → «ok»: убрать свои зависшие адаптеры или неработающие чужие
//       (Wintun). Скрипт зашит в службу, программа присылает только команду.

#include <windows.h>
#include <sddl.h>

#include "kill_switch.h"

#include <cstdlib>
#include <iterator>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

// Версия протокола между программой и службой: растёт, когда меняются команды.
constexpr char kProtocol[] = "skipit-service 3";
constexpr size_t kMaxMessage = 16 * 1024 * 1024;

std::wstring g_name;
std::wstring g_client;
std::wstring g_dir;  // Папка службы: в ней core\ и work\.
SERVICE_STATUS_HANDLE g_status_handle = nullptr;
SERVICE_STATUS g_status{};
HANDLE g_stop_event = nullptr;
HANDLE g_job = nullptr;
std::mutex g_cores_mutex;
std::map<DWORD, HANDLE> g_cores;  // pid → процесс ядра, запущенного службой.

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

std::wstring Wide(const std::string& s) {
  if (s.empty()) return L"";
  const int n = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), nullptr, 0);
  if (n <= 0) return L"";
  std::wstring w(static_cast<size_t>(n), L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), w.data(), n);
  return w;
}

std::wstring ExeDir() {
  wchar_t exe[MAX_PATH * 2];
  const DWORD n = ::GetModuleFileNameW(nullptr, exe, static_cast<DWORD>(std::size(exe)));
  if (n == 0 || n >= std::size(exe)) return L"";
  std::wstring path(exe, n);
  return path.substr(0, path.find_last_of(L'\\'));
}

// ---------- проверка конфига ----------

bool IsPathSep(char c) { return c == '/' || c == '\\'; }

// Диск с позиции [i]: «C:», «C:\…», «C:/…» и «C:файл» (относительно текущей папки диска).
// Адрес IPv6 вида «a::1» диском не считается.
bool DriveAt(const std::string& s, size_t i) {
  return i + 1 < s.size() && ((s[i] >= 'A' && s[i] <= 'Z') || (s[i] >= 'a' && s[i] <= 'z')) && s[i + 1] == ':' &&
         (i + 2 == s.size() || s[i + 2] != ':');
}

// Строка, которая как путь к файлу может выйти за рабочую папку ядра: диск — в начале или после «ext:»
// (внешний файл гео-базы Xray), сетевой путь («\\сервер»), корень текущего диска («/x», «\x») или
// переход вверх («..»). Адреса вида «https://…» путём не считаются: в них за буквой и двоеточием
// идёт не начало строки.
bool Escapes(const std::string& s, bool leading_slash_ok) {
  if (DriveAt(s, 0)) return true;
  if (s.rfind("ext:", 0) == 0 && DriveAt(s, 4)) return true;
  if (s.size() >= 2 && IsPathSep(s[0]) && IsPathSep(s[1])) return true;
  if (!leading_slash_ok && !s.empty() && IsPathSep(s[0])) return true;
  for (size_t i = 0; i + 1 < s.size(); i++) {
    if (s[i] == '.' && s[i + 1] == '.' &&
        (i == 0 || IsPathSep(s[i - 1])) && (i + 2 == s.size() || IsPathSep(s[i + 2]))) {
      return true;
    }
  }
  return false;
}

// Разбор строки JSON с позиции после открывающей кавычки; pos — после закрывающей.
bool ReadJsonString(const std::string& text, size_t& pos, std::string& out) {
  out.clear();
  while (pos < text.size()) {
    const char c = text[pos++];
    if (c == '"') return true;
    if (c != '\\') {
      out += c;
      continue;
    }
    if (pos >= text.size()) return false;
    const char e = text[pos++];
    switch (e) {
      case '"': case '\\': case '/': out += e; break;
      case 'b': out += '\b'; break;
      case 'f': out += '\f'; break;
      case 'n': out += '\n'; break;
      case 'r': out += '\r'; break;
      case 't': out += '\t'; break;
      case 'u': {
        if (pos + 4 > text.size()) return false;
        const unsigned long code = std::strtoul(text.substr(pos, 4).c_str(), nullptr, 16);
        pos += 4;
        // Для проверки путей важны только символы ASCII; остальное — заглушка.
        out += code < 0x80 ? static_cast<char>(code) : '?';
        break;
      }
      default: return false;
    }
  }
  return false;
}

// Причина отказа или пустая строка, если конфиг можно отдать ядру. Проверяются все строки JSON с
// учётом ключа, под которым они стоят:
//  - process (правила Xray по программам), process_path, process_path_regex (то же у sing-box) —
//    пути к exe, с которыми сравнивается программа соединения; по ним ничего не пишется и не читается;
//  - path у транспорта и DNS-сервера (в объекте под ключом wsSettings, httpupgradeSettings,
//    xhttpSettings, splithttpSettings, httpSettings, request — HTTP-заголовок TCP, transport или в
//    списке servers) — адрес на сервере, «/ws», «/dns-query»;
//  - остальное не должно быть путём за пределы рабочей папки.
std::string ConfigProblem(const std::string& text) {
  struct Level {
    bool object;
    std::string key;     // Текущий ключ (у объекта) или ключ, под которым стоит список.
    std::string parent;  // Ключ, под которым стоит сам этот объект или список.
    bool expect_key;
  };
  std::vector<Level> stack;
  size_t pos = 0;
  std::string s;
  while (pos < text.size()) {
    const char c = text[pos++];
    if (c == '{' || c == '[') {
      const std::string under = stack.empty() ? "" : stack.back().key;
      const std::string parent = stack.empty() ? "" : stack.back().parent;
      stack.push_back({c == '{', c == '{' ? "" : under, c == '{' ? under : parent, c == '{'});
      if (stack.size() > 64) return "конфиг слишком глубокий";
    } else if (c == '}' || c == ']') {
      if (stack.empty()) return "конфиг не разобран";
      stack.pop_back();
    } else if (c == ',') {
      if (!stack.empty() && stack.back().object) stack.back().expect_key = true;
    } else if (c == '"') {
      if (!ReadJsonString(text, pos, s)) return "конфиг не разобран";
      if (!stack.empty() && stack.back().object && stack.back().expect_key) {
        stack.back().key = s;
        stack.back().expect_key = false;
        continue;
      }
      const std::string key = stack.empty() ? "" : stack.back().key;
      const std::string parent = stack.empty() ? "" : stack.back().parent;
      if (key == "process" || key == "process_path" || key == "process_path_regex") continue;
      const bool route_path = key == "path" && (parent == "wsSettings" || parent == "httpupgradeSettings" ||
                                                parent == "xhttpSettings" || parent == "splithttpSettings" ||
                                                parent == "httpSettings" || parent == "request" ||
                                                parent == "transport" || parent == "servers");
      if (Escapes(s, route_path)) return "в конфиге путь к файлу за пределами папки ядра: " + key + " = " + s;
    }
  }
  return stack.empty() ? "" : "конфиг не разобран";
}

// ---------- канал ----------

// Запись одного сообщения (ручка канала открыта для перекрывающегося ввода-вывода).
bool PipeWrite(HANDLE pipe, const std::string& data) {
  OVERLAPPED ov{};
  ov.hEvent = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (ov.hEvent == nullptr) return false;
  DWORD n = 0;
  bool ok = ::WriteFile(pipe, data.data(), static_cast<DWORD>(data.size()), nullptr, &ov) != 0 ||
            ::GetLastError() == ERROR_IO_PENDING;
  ok = ok && ::GetOverlappedResult(pipe, &ov, &n, TRUE) && n == data.size();
  ::CloseHandle(ov.hEvent);
  return ok;
}

// Чтение одного сообщения целиком. 1 — прочитано, 0 — программа отключилась (или сбой),
// 2 — раньше сработал [also] (например, ядро завершилось).
int PipeRead(HANDLE pipe, std::string& out, HANDLE also = nullptr) {
  out.clear();
  std::vector<char> buf(64 * 1024);
  while (true) {
    OVERLAPPED ov{};
    ov.hEvent = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (ov.hEvent == nullptr) return 0;
    if (!::ReadFile(pipe, buf.data(), static_cast<DWORD>(buf.size()), nullptr, &ov)) {
      const DWORD err = ::GetLastError();
      if (err != ERROR_IO_PENDING && err != ERROR_MORE_DATA) {
        ::CloseHandle(ov.hEvent);
        return 0;
      }
    }
    if (also != nullptr) {
      HANDLE waits[] = {ov.hEvent, also};
      if (::WaitForMultipleObjects(2, waits, FALSE, INFINITE) != WAIT_OBJECT_0) {
        ::CancelIoEx(pipe, &ov);
        DWORD unused = 0;
        ::GetOverlappedResult(pipe, &ov, &unused, TRUE);
        ::CloseHandle(ov.hEvent);
        return 2;
      }
    }
    DWORD n = 0;
    const bool ok = ::GetOverlappedResult(pipe, &ov, &n, TRUE) != 0;
    const DWORD err = ok ? 0 : ::GetLastError();
    ::CloseHandle(ov.hEvent);
    out.append(buf.data(), n);
    if (ok) return 1;
    if (err != ERROR_MORE_DATA || out.size() > kMaxMessage) return 0;
  }
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

// ---------- ядра ----------

// Рабочая папка ядра: относительные пути из конфига (если ядро что-то пишет) попадают сюда.
std::wstring WorkDir() {
  const std::wstring dir = g_dir + L"\\work";
  ::CreateDirectoryW(dir.c_str(), nullptr);
  return dir;
}

// Окружение службы плюс XRAY_LOCATION_ASSET (папка гео-баз программы) для Xray.
std::vector<wchar_t> Environment(const std::wstring& assets) {
  std::vector<wchar_t> env;
  wchar_t* block = ::GetEnvironmentStringsW();
  if (block != nullptr) {
    for (const wchar_t* p = block; *p != L'\0'; p += wcslen(p) + 1) {
      if (_wcsnicmp(p, L"XRAY_LOCATION_ASSET=", 20) == 0) continue;
      env.insert(env.end(), p, p + wcslen(p) + 1);
    }
    ::FreeEnvironmentStringsW(block);
  }
  if (!assets.empty()) {
    const std::wstring var = L"XRAY_LOCATION_ASSET=" + assets;
    env.insert(env.end(), var.c_str(), var.c_str() + var.size() + 1);
  }
  env.push_back(L'\0');
  return env;
}

// Папка гео-баз — только существующая папка, абсолютный путь без «..».
bool AssetsOk(const std::wstring& dir) {
  if (dir.empty()) return true;
  if (dir.size() < 3 || dir[1] != L':' || dir[2] != L'\\' || dir.find(L"..") != std::wstring::npos) return false;
  const DWORD attrs = ::GetFileAttributesW(dir.c_str());
  return attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY) &&
         !(attrs & FILE_ATTRIBUTE_REPARSE_POINT);
}

void RunCore(HANDLE pipe, const std::string& request) {
  // «start\n<ядро>\n<папка гео>\n<конфиг>»
  const size_t a = request.find('\n');
  const size_t b = a == std::string::npos ? a : request.find('\n', a + 1);
  const size_t c = b == std::string::npos ? b : request.find('\n', b + 1);
  if (c == std::string::npos) {
    PipeWrite(pipe, "error неверная команда");
    return;
  }
  const std::string core = request.substr(a + 1, b - a - 1);
  const std::wstring assets = Wide(request.substr(b + 1, c - b - 1));
  const std::string config = request.substr(c + 1);
  const wchar_t* exe_name = core == "xray" ? L"skipit-xray.exe" : core == "sing-box" ? L"skipit-sing-box.exe" : nullptr;
  if (exe_name == nullptr) {
    PipeWrite(pipe, "error неизвестное ядро");
    return;
  }
  if (!AssetsOk(assets)) {
    PipeWrite(pipe, "error неверная папка гео-баз");
    return;
  }
  const std::string problem = ConfigProblem(config);
  if (!problem.empty()) {
    PipeWrite(pipe, "error " + problem);
    return;
  }

  const std::wstring exe = g_dir + L"\\core\\" + exe_name;
  std::wstring command = L"\"" + exe + L"\" run -c " + (core == "xray" ? L"stdin:" : L"stdin");
  SECURITY_ATTRIBUTES inherit{sizeof(inherit), nullptr, TRUE};
  HANDLE out_read = nullptr, out_write = nullptr, in_read = nullptr, in_write = nullptr;
  if (!::CreatePipe(&out_read, &out_write, &inherit, 0) || !::CreatePipe(&in_read, &in_write, &inherit, 0)) {
    PipeWrite(pipe, "error не удалось создать канал ядра");
    return;
  }
  ::SetHandleInformation(out_read, HANDLE_FLAG_INHERIT, 0);
  ::SetHandleInformation(in_write, HANDLE_FLAG_INHERIT, 0);
  // Ядру достаются только его ввод и вывод, а не все наследуемые ручки службы.
  HANDLE handles[] = {in_read, out_write};
  SIZE_T size = 0;
  ::InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
  std::vector<char> attr_buf(size);
  auto attrs = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attr_buf.data());
  ::InitializeProcThreadAttributeList(attrs, 1, 0, &size);
  ::UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handles, sizeof(handles), nullptr, nullptr);
  STARTUPINFOEXW si{};
  si.StartupInfo.cb = sizeof(si);
  si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  si.StartupInfo.hStdInput = in_read;
  si.StartupInfo.hStdOutput = out_write;
  si.StartupInfo.hStdError = out_write;
  si.lpAttributeList = attrs;
  std::vector<wchar_t> env = Environment(core == "xray" ? assets : L"");
  const std::wstring work = WorkDir();
  PROCESS_INFORMATION pi{};
  const bool created = ::CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr, TRUE,
                                        CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED |
                                            EXTENDED_STARTUPINFO_PRESENT,
                                        env.data(), work.c_str(), &si.StartupInfo, &pi) != 0;
  const DWORD create_error = ::GetLastError();
  ::DeleteProcThreadAttributeList(attrs);
  ::CloseHandle(in_read);
  ::CloseHandle(out_write);
  if (!created) {
    ::CloseHandle(out_read);
    ::CloseHandle(in_write);
    PipeWrite(pipe, "error не удалось запустить ядро (код " + std::to_string(create_error) + ")");
    return;
  }
  ::AssignProcessToJobObject(g_job, pi.hProcess);
  ::ResumeThread(pi.hThread);
  ::CloseHandle(pi.hThread);
  {
    std::lock_guard<std::mutex> lock(g_cores_mutex);
    g_cores[pi.dwProcessId] = pi.hProcess;
  }
  PipeWrite(pipe, "started " + std::to_string(pi.dwProcessId));

  // Конфиг — на стандартный вход ядра (на диск он не пишется), затем вход закрывается.
  std::thread input([in_write, config] {
    DWORD written = 0;
    ::WriteFile(in_write, config.data(), static_cast<DWORD>(config.size()), &written, nullptr);
    ::CloseHandle(in_write);
  });
  // Вывод ядра — программе; не удалось отправить (программа отключилась) — ядро останавливается.
  HANDLE process = pi.hProcess;
  std::thread output([out_read, pipe, process] {
    std::vector<char> buf(32 * 1024);
    DWORD n = 0;
    while (::ReadFile(out_read, buf.data(), static_cast<DWORD>(buf.size()), &n, nullptr) && n > 0) {
      if (!PipeWrite(pipe, "o" + std::string(buf.data(), n))) {
        ::TerminateProcess(process, 1);
        break;
      }
    }
    ::CloseHandle(out_read);
  });
  // Ждём, пока ядро не завершится или программа не отключится.
  std::string message;
  while (true) {
    const int r = PipeRead(pipe, message, process);
    if (r == 2) break;
    if (r == 0) {
      ::TerminateProcess(process, 1);
      break;
    }
  }
  ::WaitForSingleObject(process, INFINITE);
  input.join();
  output.join();
  DWORD code = 0;
  ::GetExitCodeProcess(process, &code);
  {
    std::lock_guard<std::mutex> lock(g_cores_mutex);
    g_cores.erase(pi.dwProcessId);
  }
  ::CloseHandle(process);
  PipeWrite(pipe, "x" + std::to_string(code));
}

void StopCore(HANDLE pipe, const std::string& request) {
  const DWORD pid = std::strtoul(request.c_str() + 5, nullptr, 10);
  std::lock_guard<std::mutex> lock(g_cores_mutex);
  const auto it = g_cores.find(pid);
  if (it != g_cores.end()) ::TerminateProcess(it->second, 1);
  PipeWrite(pipe, "ok");
}

// ---------- Kill Switch ----------

std::mutex g_ks_mutex;
HANDLE g_ks_holder = nullptr;  // Событие подключения, которое держит фильтры: сработало — фильтры сняты.

// Адрес адаптера: только цифры, буквы a–f, точки и двоеточия.
bool AddressOk(const std::string& s) {
  if (s.empty() || s.size() > 45) return false;
  for (char c : s) {
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c == '.' || c == ':')) {
      return false;
    }
  }
  return true;
}

void KsHold(HANDLE pipe, const std::string& request) {
  // «ks engage\n<v4>\n<v6>»
  const size_t a = request.find('\n');
  const size_t b = a == std::string::npos ? a : request.find('\n', a + 1);
  if (b == std::string::npos) {
    PipeWrite(pipe, "error неверная команда");
    return;
  }
  const std::string v4 = request.substr(a + 1, b - a - 1), v6 = request.substr(b + 1);
  if (!AddressOk(v4) || !AddressOk(v6)) {
    PipeWrite(pipe, "error неверный адрес адаптера");
    return;
  }
  HANDLE released = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (released == nullptr) return;
  std::wstring error;
  {
    std::lock_guard<std::mutex> lock(g_ks_mutex);
    error = KillSwitchEngage({g_dir + L"\\core\\skipit-xray.exe", g_dir + L"\\core\\skipit-sing-box.exe"},
                             Wide(v4), Wide(v6), g_client);
    if (error.empty()) {
      // Прежний держатель (если был) больше ничего не держит: KillSwitchEngage сняла его фильтры.
      if (g_ks_holder != nullptr) ::SetEvent(g_ks_holder);
      g_ks_holder = released;
    }
  }
  if (!error.empty()) {
    ::CloseHandle(released);
    std::string text;  // Текст ошибки — латиница и цифры («open: 0x…»).
    for (wchar_t c : error) text += c < 0x80 ? static_cast<char>(c) : '?';
    PipeWrite(pipe, "error " + text);
    return;
  }
  PipeWrite(pipe, "ok");
  std::string message;
  int r;
  while ((r = PipeRead(pipe, message, released)) == 1) {
  }
  {
    std::lock_guard<std::mutex> lock(g_ks_mutex);
    if (g_ks_holder == released) {
      // Программа отключилась, не сняв фильтры (закрылась или упала) — снимаем, как сделала бы Windows.
      KillSwitchRelease();
      g_ks_holder = nullptr;
    }
  }
  if (r == 2) PipeWrite(pipe, "released");
  ::CloseHandle(released);
}

void KsRelease(HANDLE pipe) {
  unsigned long code;
  int left;
  {
    std::lock_guard<std::mutex> lock(g_ks_mutex);
    code = KillSwitchRelease();
    left = KillSwitchCountFilters();
    if (g_ks_holder != nullptr) {
      ::SetEvent(g_ks_holder);
      g_ks_holder = nullptr;
    }
  }
  PipeWrite(pipe, "ok " + std::to_string(code) + " " + std::to_string(left));
}

void KsStatus(HANDLE pipe) {
  std::lock_guard<std::mutex> lock(g_ks_mutex);
  PipeWrite(pipe, std::string(KillSwitchEngaged() ? "1 " : "0 ") + std::to_string(KillSwitchCountFilters()));
}

// ---------- уборка адаптеров ----------

// Те же скрипты, что делала программа с правами администратора (WinSys.removeOwnTunAdapters и
// removeStaleForeignTunAdapters). Свои адаптеры: GUID устройства sing-box выводит из имени адаптера
// (MD5 от «wintun» + имя), имена — как у программы (у тестовой сборки «SkipIt Dev»), с прежними «… 2»–«… 4».
void Cleanup(HANDLE pipe, bool own) {
  const std::wstring app = g_name == L"SkipItDev" ? L"SkipIt Dev" : L"SkipIt";
  std::wstring names = L"'" + app + L"'";
  for (int i = 2; i <= 4; i++) names += L",'" + app + L" " + std::to_wstring(i) + L"'";
  std::wstring script =
      L"$md5 = [Security.Cryptography.MD5]::Create(); $own = @(" + names +
      L") | ForEach-Object { ('SWD\\WINTUN\\{' + ([Guid]::new($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("
      L"'wintun' + $_)))).ToString() + '}').ToUpper() }; ";
  script += own ? L"foreach ($id in $own) { pnputil /remove-device $id 2>$null | Out-Null }"
                : L"Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like "
                  L"'SWD\\WINTUN\\*' -and $_.Status -ne 'OK' -and $own -notcontains $_.InstanceId.ToUpper() } | "
                  L"ForEach-Object { pnputil /remove-device $_.InstanceId 2>$null | Out-Null }";
  wchar_t windows[MAX_PATH];
  const UINT n = ::GetSystemDirectoryW(windows, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) {
    PipeWrite(pipe, "error нет папки Windows");
    return;
  }
  const std::wstring exe = std::wstring(windows, n) + L"\\WindowsPowerShell\\v1.0\\powershell.exe";
  std::wstring command = L"\"" + exe + L"\" -NoProfile -NonInteractive -Command \"" + script + L"\"";
  STARTUPINFOW si{sizeof(si)};
  PROCESS_INFORMATION pi{};
  if (::CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr,
                       WorkDir().c_str(), &si, &pi)) {
    if (::WaitForSingleObject(pi.hProcess, 20000) == WAIT_TIMEOUT) ::TerminateProcess(pi.hProcess, 1);
    ::CloseHandle(pi.hThread);
    ::CloseHandle(pi.hProcess);
  }
  PipeWrite(pipe, "ok");
}

void Serve(HANDLE pipe) {
  const std::wstring client = ClientPath(pipe);
  if (client.empty() || _wcsicmp(client.c_str(), g_client.c_str()) != 0) return;
  std::string request;
  while (PipeRead(pipe, request) == 1) {
    if (request == "hello") {
      if (!PipeWrite(pipe, kProtocol)) return;
    } else if (request.rfind("start\n", 0) == 0) {
      RunCore(pipe, request);
      return;  // Подключение запуска ядра живёт, пока живёт ядро.
    } else if (request.rfind("stop ", 0) == 0) {
      StopCore(pipe, request);
    } else if (request.rfind("ks engage\n", 0) == 0) {
      KsHold(pipe, request);
      return;  // Подключение держит фильтры, пока не закроется или не придёт «ks release».
    } else if (request == "ks release") {
      KsRelease(pipe);
    } else if (request == "ks status") {
      KsStatus(pipe);
    } else if (request == "cleanup own" || request == "cleanup stale") {
      Cleanup(pipe, request == "cleanup own");
    } else if (!PipeWrite(pipe, "error неизвестная команда")) {
      return;
    }
  }
}

// Канал: система и администраторы — полный доступ, вошедшие в Windows пользователи — только чтение,
// запись данных и смена режима канала (0x12018B: без права создавать свои экземпляры канала, иначе
// ими можно было бы перехватывать подключения программы). Кто подключился, проверяет Serve().
HANDLE CreatePipe(bool first) {
  PSECURITY_DESCRIPTOR sd = nullptr;
  if (!::ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x12018B;;;IU)",
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
  // Задание Windows: закрылась служба (остановили, упала) — закрываются и все её ядра.
  g_job = ::CreateJobObjectW(nullptr, nullptr);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  ::SetInformationJobObject(g_job, JobObjectExtendedLimitInformation, &limits, sizeof(limits));
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

// Проверка конфига из файла (для тестов): печатает «ok» или причину отказа.
int CheckConfig(const std::wstring& path) {
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
  if (file == INVALID_HANDLE_VALUE) return 2;
  std::string text;
  char buf[64 * 1024];
  DWORD n = 0;
  while (::ReadFile(file, buf, sizeof(buf), &n, nullptr) && n > 0) text.append(buf, n);
  ::CloseHandle(file);
  const std::string problem = ConfigProblem(text);
  const std::string out = (problem.empty() ? "ok" : problem) + "\n";
  DWORD written = 0;
  ::WriteFile(::GetStdHandle(STD_OUTPUT_HANDLE), out.data(), static_cast<DWORD>(out.size()), &written, nullptr);
  return problem.empty() ? 0 : 1;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  const std::wstring check = Arg(argc, argv, L"--check-config");
  if (!check.empty()) return CheckConfig(check);
  g_name = Arg(argc, argv, L"--name");
  if (!NameOk(g_name)) return 10;
  if (HasArg(argc, argv, L"--uninstall")) return StopOrUninstall(true);
  if (HasArg(argc, argv, L"--stop")) return StopOrUninstall(false);
  g_client = Arg(argc, argv, L"--client");
  if (g_client.empty()) return 11;
  if (HasArg(argc, argv, L"--install")) return Install(g_client);

  g_dir = ExeDir();
  SERVICE_TABLE_ENTRYW table[] = {{g_name.data(), ServiceMain}, {nullptr, nullptr}};
  return ::StartServiceCtrlDispatcherW(table) ? 0 : 12;
}

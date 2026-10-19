#include "bypass.h"

// Заголовки Windows не рассчитаны на строгий уровень предупреждений проекта (/W4 /WX).
#pragma warning(push, 0)
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <evntprov.h>
#include <evntrace.h>
#include <evntcons.h>
#include <tdh.h>
#pragma warning(pop)

#include <climits>
#include <cstring>
#include <mutex>
#include <set>
#include <thread>
#include <unordered_map>

namespace {

// Microsoft-Windows-Kernel-Network: событие 42 — «UDPv4: N bytes transmitted from saddr:sport to daddr:dport»,
// поля PID, size, daddr, saddr, dport, sport…; ключевое слово 0x10 — IPv4.
constexpr GUID kKernelNetwork = {0x7dd42a49, 0x5329, 0x4832, {0x8d, 0xfd, 0x43, 0xd9, 0x79, 0x15, 0x3a, 0x88}};
constexpr USHORT kUdpSendV4 = 42;
constexpr ULONGLONG kKeywordIpv4 = 0x10;
// Больше маршрутов не ставим: столько адресов у игр не бывает, а таблица маршрутов Windows не резиновая.
constexpr size_t kMaxRoutes = 2048;
// Через сколько миллисекунд заново узнавать, какая программа у номера процесса (номера переиспользуются).
constexpr ULONGLONG kPidTtl = 10000;

std::mutex g_mutex;  // Маршруты, просмотренные адреса и файл состояния.
TRACEHANDLE g_session = 0;
TRACEHANDLE g_trace = INVALID_PROCESSTRACE_HANDLE;
std::thread g_thread;
std::wstring g_session_name;
std::wstring g_state_file;
ULONG g_tun = 0;
std::vector<std::wstring> g_rules;
std::function<void(unsigned long)> g_before;
std::function<void(unsigned long, const std::wstring&)> g_after;
std::vector<MIB_IPFORWARD_ROW2> g_routes;
std::set<ULONG> g_seen;  // Адреса, по которым уже решено (с маршрутом или без).

// Дальше — только поток событий.
struct Known {
  ULONGLONG at;
  bool direct;
  std::wstring name;
};
std::unordered_map<DWORD, Known> g_pids;
bool g_layout_checked = false;
bool g_pid_by_name = false;  // Номер процесса — не первое поле события: берём его по имени поля.

std::wstring Lower(const std::wstring& s) {
  if (s.empty()) return s;
  std::wstring out(s.size(), L'\0');
  const int n = ::LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, s.data(), static_cast<int>(s.size()),
                                out.data(), static_cast<int>(out.size()), nullptr, nullptr, 0);
  return n == static_cast<int>(s.size()) ? out : s;
}

// Путь для сравнения с правилами: прямые слэши, нижний регистр.
std::wstring Normalize(std::wstring s) {
  for (wchar_t& c : s) {
    if (c == L'\\') c = L'/';
  }
  return Lower(s);
}

// Совпадение с правилом так же, как у ядер: папка — начало пути, путь — целиком, иначе имя процесса.
bool Matches(const std::wstring& path) {
  const size_t slash = path.rfind(L'/');
  const std::wstring base = slash == std::wstring::npos ? path : path.substr(slash + 1);
  for (const std::wstring& rule : g_rules) {
    if (rule.back() == L'/') {
      if (path.compare(0, rule.size(), rule) == 0) return true;
    } else if (rule.find(L'/') != std::wstring::npos) {
      if (path == rule) return true;
    } else if (base == rule || base == rule + L".exe") {
      return true;
    }
  }
  return false;
}

// Программа процесса [pid] — из списка «Напрямую»; [name] — имя её exe.
bool IsDirect(DWORD pid, std::wstring& name) {
  if (pid <= 4) return false;
  const ULONGLONG now = ::GetTickCount64();
  const auto it = g_pids.find(pid);
  if (it != g_pids.end() && now - it->second.at < kPidTtl) {
    name = it->second.name;
    return it->second.direct;
  }
  if (g_pids.size() > 4096) g_pids.clear();
  Known known{now, false, L""};
  HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process != nullptr) {
    wchar_t path[MAX_PATH * 2];
    DWORD size = static_cast<DWORD>(sizeof(path) / sizeof(path[0]));
    if (::QueryFullProcessImageNameW(process, 0, path, &size)) {
      const std::wstring full(path, size);
      const size_t slash = full.find_last_of(L"\\/");
      known.name = slash == std::wstring::npos ? full : full.substr(slash + 1);
      known.direct = Matches(Normalize(full));
    }
    ::CloseHandle(process);
  }
  g_pids[pid] = known;
  name = known.name;
  return known.direct;
}

// Адрес не в интернете: локальная сеть, сам компьютер, служебные и групповые адреса.
bool Local(ULONG net) {
  const ULONG h = ntohl(net);
  const ULONG top = h >> 24;
  return top == 0 || top == 10 || top == 127 || (h & 0xFFC00000) == 0x64400000 ||
         (h & 0xFFFF0000) == 0xA9FE0000 || (h & 0xFFF00000) == 0xAC100000 || (h & 0xFFFF0000) == 0xC0A80000 ||
         h >= 0xE0000000;
}

// Маршрут по умолчанию через настоящую сетевую карту: самый дешёвый, кроме маршрута адаптера VPN.
bool PhysicalDefault(MIB_IPFORWARD_ROW2& out) {
  NET_LUID tun{};
  bool have_tun = false;
  PMIB_UNICASTIPADDRESS_TABLE addresses = nullptr;
  if (::GetUnicastIpAddressTable(AF_INET, &addresses) == NO_ERROR) {
    for (ULONG i = 0; i < addresses->NumEntries; i++) {
      if (addresses->Table[i].Address.Ipv4.sin_addr.s_addr == g_tun) {
        tun = addresses->Table[i].InterfaceLuid;
        have_tun = true;
      }
    }
    ::FreeMibTable(addresses);
  }
  // Адаптера ещё (или уже) нет — не отличить его маршрут от настоящего.
  if (!have_tun) return false;
  PMIB_IPFORWARD_TABLE2 table = nullptr;
  if (::GetIpForwardTable2(AF_INET, &table) != NO_ERROR) return false;
  ULONG best = ULONG_MAX;
  for (ULONG i = 0; i < table->NumEntries; i++) {
    const MIB_IPFORWARD_ROW2& row = table->Table[i];
    if (row.DestinationPrefix.PrefixLength != 0 || row.InterfaceLuid.Value == tun.Value) continue;
    MIB_IPINTERFACE_ROW iface;
    ::InitializeIpInterfaceEntry(&iface);
    iface.Family = AF_INET;
    iface.InterfaceLuid = row.InterfaceLuid;
    if (::GetIpInterfaceEntry(&iface) != NO_ERROR || !iface.Connected) continue;
    const ULONG metric = row.Metric + iface.Metric;
    if (metric < best) {
      best = metric;
      out = row;
    }
  }
  ::FreeMibTable(table);
  return best != ULONG_MAX;
}

void SaveState() {
  if (g_state_file.empty()) return;
  if (g_routes.empty()) {
    ::DeleteFileW(g_state_file.c_str());
    return;
  }
  std::string text;
  for (const MIB_IPFORWARD_ROW2& row : g_routes) {
    char address[INET_ADDRSTRLEN] = {};
    ::InetNtopA(AF_INET, &row.DestinationPrefix.Prefix.Ipv4.sin_addr, address, sizeof(address));
    text += address;
    text += '\n';
  }
  HANDLE file = ::CreateFileW(g_state_file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  ::WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written, nullptr);
  ::CloseHandle(file);
}

// Маршрут к [address] (порядок байт сети) мимо адаптера. Вызывается под g_mutex.
bool AddRoute(ULONG address) {
  MIB_IPFORWARD_ROW2 base;
  if (!PhysicalDefault(base)) return false;
  MIB_IPFORWARD_ROW2 row;
  ::InitializeIpForwardEntry(&row);
  row.InterfaceLuid = base.InterfaceLuid;
  row.InterfaceIndex = base.InterfaceIndex;
  row.DestinationPrefix.Prefix.Ipv4.sin_family = AF_INET;
  row.DestinationPrefix.Prefix.Ipv4.sin_addr.s_addr = address;
  row.DestinationPrefix.PrefixLength = 32;
  row.NextHop = base.NextHop;
  row.Metric = 0;
  row.Protocol = MIB_IPPROTO_NETMGMT;
  // Такой маршрут уже есть (поставил кто-то другой) — он не наш, и убирать его не нам.
  if (::CreateIpForwardEntry2(&row) != NO_ERROR) return false;
  g_routes.push_back(row);
  SaveState();
  return true;
}

void Handle(ULONG address, const std::wstring& name) {
  if (Local(address)) return;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_seen.count(address) || g_seen.size() >= kMaxRoutes) return;
    g_seen.insert(address);
  }
  if (g_before) g_before(address);
  bool added;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    added = AddRoute(address);
  }
  if (added && g_after) g_after(address, name);
}

bool Prop(PEVENT_RECORD e, const wchar_t* name, void* out, ULONG size) {
  PROPERTY_DATA_DESCRIPTOR d{};
  d.PropertyName = reinterpret_cast<ULONGLONG>(name);
  d.ArrayIndex = ULONG_MAX;
  return ::TdhGetProperty(e, 0, nullptr, 1, &d, size, static_cast<PBYTE>(out)) == ERROR_SUCCESS;
}

void WINAPI OnEvent(PEVENT_RECORD e) {
  if (e->EventHeader.EventDescriptor.Id != kUdpSendV4 || !::IsEqualGUID(e->EventHeader.ProviderId, kKernelNetwork) ||
      e->UserDataLength < 12) {
    return;
  }
  // Номер процесса — первое поле события: так проверка каждой отправки UDP почти ничего не стоит. Один раз
  // сверяемся с описанием события; если поле не первое — дальше берём его по имени.
  DWORD pid = 0;
  std::memcpy(&pid, e->UserData, sizeof(pid));
  if (!g_layout_checked) {
    DWORD named = 0;
    if (Prop(e, L"PID", &named, sizeof(named))) {
      g_layout_checked = true;
      g_pid_by_name = named != pid;
    }
  }
  if (g_pid_by_name && !Prop(e, L"PID", &pid, sizeof(pid))) return;
  std::wstring name;
  if (!IsDirect(pid, name)) return;
  ULONG address = 0;
  if (!Prop(e, L"daddr", &address, sizeof(address))) return;
  Handle(address, name);
}

std::vector<BYTE> Properties(const std::wstring& name) {
  std::vector<BYTE> buf(sizeof(EVENT_TRACE_PROPERTIES) + (name.size() + 1) * sizeof(wchar_t));
  auto* p = reinterpret_cast<EVENT_TRACE_PROPERTIES*>(buf.data());
  p->Wnode.BufferSize = static_cast<ULONG>(buf.size());
  p->Wnode.Flags = WNODE_FLAG_TRACED_GUID;
  p->Wnode.ClientContext = 1;
  p->LogFileMode = EVENT_TRACE_REAL_TIME_MODE;
  // Маленькие буферы и сброс раз в секунду: события доходят быстро и при редких пакетах.
  p->BufferSize = 4;
  p->MinimumBuffers = 4;
  p->MaximumBuffers = 64;
  p->FlushTimer = 1;
  p->LoggerNameOffset = sizeof(EVENT_TRACE_PROPERTIES);
  return buf;
}

void StopSession(const std::wstring& name) {
  std::vector<BYTE> props = Properties(name);
  ::ControlTraceW(0, name.c_str(), reinterpret_cast<EVENT_TRACE_PROPERTIES*>(props.data()), EVENT_TRACE_CONTROL_STOP);
}

void DeleteHostRoutes(const std::set<ULONG>& addresses) {
  PMIB_IPFORWARD_TABLE2 table = nullptr;
  if (::GetIpForwardTable2(AF_INET, &table) != NO_ERROR) return;
  for (ULONG i = 0; i < table->NumEntries; i++) {
    MIB_IPFORWARD_ROW2& row = table->Table[i];
    if (row.DestinationPrefix.PrefixLength == 32 && row.Protocol == MIB_IPPROTO_NETMGMT &&
        addresses.count(row.DestinationPrefix.Prefix.Ipv4.sin_addr.s_addr)) {
      ::DeleteIpForwardEntry2(&row);
    }
  }
  ::FreeMibTable(table);
}

}  // namespace

std::wstring BypassStart(const std::wstring& session_name, const std::wstring& tun_v4,
                         const std::vector<std::wstring>& rules, const std::wstring& state_file,
                         std::function<void(unsigned long)> before_route,
                         std::function<void(unsigned long, const std::wstring&)> on_route) {
  BypassStop();
  IN_ADDR tun{};
  if (::InetPtonW(AF_INET, tun_v4.c_str(), &tun) != 1) return L"неверный адрес адаптера";
  BypassCleanupStale(state_file);

  g_session_name = session_name;
  g_state_file = state_file;
  g_tun = tun.s_addr;
  g_rules.clear();
  for (const std::wstring& rule : rules) {
    if (!rule.empty()) g_rules.push_back(Normalize(rule));
  }
  g_before = std::move(before_route);
  g_after = std::move(on_route);
  g_pids.clear();
  g_layout_checked = g_pid_by_name = false;

  // Сеанс с тем же именем мог остаться после сбоя службы.
  StopSession(session_name);
  std::vector<BYTE> props = Properties(session_name);
  TRACEHANDLE session = 0;
  ULONG rc = ::StartTraceW(&session, session_name.c_str(), reinterpret_cast<EVENT_TRACE_PROPERTIES*>(props.data()));
  if (rc != ERROR_SUCCESS) return L"не удалось начать слежение (код " + std::to_wstring(rc) + L")";

  // Только отправка UDP по IPv4; старая Windows фильтр по номеру события не знает — тогда отбираем сами.
  std::vector<BYTE> ids_buf(offsetof(EVENT_FILTER_EVENT_ID, Events) + sizeof(USHORT));
  auto* ids = reinterpret_cast<EVENT_FILTER_EVENT_ID*>(ids_buf.data());
  ids->FilterIn = TRUE;
  ids->Count = 1;
  ids->Events[0] = kUdpSendV4;
  EVENT_FILTER_DESCRIPTOR filter{reinterpret_cast<ULONGLONG>(ids), static_cast<ULONG>(ids_buf.size()),
                                 EVENT_FILTER_TYPE_EVENT_ID};
  ENABLE_TRACE_PARAMETERS params{};
  params.Version = ENABLE_TRACE_PARAMETERS_VERSION_2;
  params.EnableFilterDesc = &filter;
  params.FilterDescCount = 1;
  rc = ::EnableTraceEx2(session, &kKernelNetwork, EVENT_CONTROL_CODE_ENABLE_PROVIDER, TRACE_LEVEL_INFORMATION,
                        kKeywordIpv4, 0, 0, &params);
  if (rc != ERROR_SUCCESS) {
    rc = ::EnableTraceEx2(session, &kKernelNetwork, EVENT_CONTROL_CODE_ENABLE_PROVIDER, TRACE_LEVEL_INFORMATION,
                          kKeywordIpv4, 0, 0, nullptr);
  }
  if (rc != ERROR_SUCCESS) {
    ::ControlTraceW(session, nullptr, reinterpret_cast<EVENT_TRACE_PROPERTIES*>(props.data()), EVENT_TRACE_CONTROL_STOP);
    return L"не удалось включить события сети (код " + std::to_wstring(rc) + L")";
  }

  EVENT_TRACE_LOGFILEW log{};
  log.LoggerName = g_session_name.data();
  log.ProcessTraceMode = PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD;
  log.EventRecordCallback = OnEvent;
  const TRACEHANDLE trace = ::OpenTraceW(&log);
  if (trace == INVALID_PROCESSTRACE_HANDLE) {
    ::ControlTraceW(session, nullptr, reinterpret_cast<EVENT_TRACE_PROPERTIES*>(props.data()), EVENT_TRACE_CONTROL_STOP);
    return L"не удалось читать события сети (код " + std::to_wstring(::GetLastError()) + L")";
  }
  g_session = session;
  g_trace = trace;
  g_thread = std::thread([trace] {
    TRACEHANDLE handle = trace;
    ::ProcessTrace(&handle, 1, nullptr, nullptr);
  });
  return std::wstring();
}

void BypassStop() {
  if (g_session != 0) {
    std::vector<BYTE> props = Properties(g_session_name);
    ::ControlTraceW(g_session, nullptr, reinterpret_cast<EVENT_TRACE_PROPERTIES*>(props.data()),
                    EVENT_TRACE_CONTROL_STOP);
    g_session = 0;
  }
  if (g_trace != INVALID_PROCESSTRACE_HANDLE) {
    ::CloseTrace(g_trace);
    g_trace = INVALID_PROCESSTRACE_HANDLE;
  }
  if (g_thread.joinable()) g_thread.join();
  std::lock_guard<std::mutex> lock(g_mutex);
  for (MIB_IPFORWARD_ROW2& row : g_routes) ::DeleteIpForwardEntry2(&row);
  g_routes.clear();
  g_seen.clear();
  SaveState();
  g_before = nullptr;
  g_after = nullptr;
}

std::vector<unsigned long> BypassAddresses() {
  std::lock_guard<std::mutex> lock(g_mutex);
  std::vector<unsigned long> out;
  for (const MIB_IPFORWARD_ROW2& row : g_routes) out.push_back(row.DestinationPrefix.Prefix.Ipv4.sin_addr.s_addr);
  return out;
}

void BypassCleanupStale(const std::wstring& state_file) {
  HANDLE file = ::CreateFileW(state_file.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  std::string text;
  char buf[4096];
  DWORD n = 0;
  while (::ReadFile(file, buf, sizeof(buf), &n, nullptr) && n > 0 && text.size() < 1024 * 1024) text.append(buf, n);
  ::CloseHandle(file);
  std::set<ULONG> addresses;
  size_t start = 0;
  while (start < text.size()) {
    size_t end = text.find('\n', start);
    if (end == std::string::npos) end = text.size();
    const std::string line = text.substr(start, end - start);
    IN_ADDR address{};
    if (::InetPtonA(AF_INET, line.c_str(), &address) == 1) addresses.insert(address.s_addr);
    start = end + 1;
  }
  DeleteHostRoutes(addresses);
  ::DeleteFileW(state_file.c_str());
}

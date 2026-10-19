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

// Маршрут, поставленный службой.
struct Route {
  MIB_IPFORWARD_ROW2 row;
  ULONG net;   // Порядок байт сети.
  ULONG mask;  // Порядок байт сети.
  LONGLONG at;  // Когда поставлен: системное время (FILETIME), в нём же время событий.
};

std::mutex g_mutex;  // Маршруты, просмотренные адреса и файл состояния.
TRACEHANDLE g_session = 0;
TRACEHANDLE g_trace = INVALID_PROCESSTRACE_HANDLE;
std::thread g_thread;
std::wstring g_session_name;
std::wstring g_state_file;
ULONG g_tun = 0;
std::vector<std::wstring> g_rules;       // Для сравнения: прямые слэши, нижний регистр.
std::vector<std::wstring> g_rule_texts;  // Как прислала программа.
std::function<bool(const BypassNet&)> g_before;
std::function<void(unsigned long, const std::wstring&, const std::wstring&)> g_after;
std::function<void(unsigned long, const std::wstring&)> g_stuck;
std::vector<Route> g_routes;
std::set<ULONG> g_seen;  // Адреса, по которым уже решено (с маршрутом или без).

// Дальше — только поток событий.
struct Known {
  ULONGLONG at;
  int rule;  // Номер правила, под которое подошла программа; -1 — не из списка.
  std::wstring name;
};
std::unordered_map<DWORD, Known> g_pids;
bool g_layout_checked = false;
bool g_pid_by_name = false;  // Номер процесса — не первое поле события: берём его по имени поля.
// Пакеты с адресом адаптера уже после маршрута: программа + адрес → сколько; сообщено — больше не считаем.
std::unordered_map<ULONGLONG, int> g_stuck_count;
// Пакеты, отправленные раньше чем через 0,3 с после маршрута, не считаются: события доходят с задержкой.
constexpr LONGLONG kStuckMargin = 3000000;  // В сотнях наносекунд.
// Столько пакетов мимо маршрута — уже не случайность, а привязанный к адаптеру сокет.
constexpr int kStuckPackets = 20;

ULONG Mask(unsigned char prefix) { return prefix == 0 ? 0 : htonl(0xFFFFFFFFUL << (32 - prefix)); }

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

// Номер правила, под которое подошёл путь, или -1. Так же, как у ядер: папка — начало пути, путь — целиком,
// иначе имя процесса.
int Match(const std::wstring& path) {
  const size_t slash = path.rfind(L'/');
  const std::wstring base = slash == std::wstring::npos ? path : path.substr(slash + 1);
  for (size_t i = 0; i < g_rules.size(); i++) {
    const std::wstring& rule = g_rules[i];
    if (rule.back() == L'/') {
      if (path.compare(0, rule.size(), rule) == 0) return static_cast<int>(i);
    } else if (rule.find(L'/') != std::wstring::npos) {
      if (path == rule) return static_cast<int>(i);
    } else if (base == rule || base == rule + L".exe") {
      return static_cast<int>(i);
    }
  }
  return -1;
}

// Правило из списка «Напрямую», под которое подходит программа процесса [pid], или -1; [name] — имя её exe.
int DirectRule(DWORD pid, std::wstring& name) {
  if (pid <= 4) return -1;
  const ULONGLONG now = ::GetTickCount64();
  const auto it = g_pids.find(pid);
  if (it != g_pids.end() && now - it->second.at < kPidTtl) {
    name = it->second.name;
    return it->second.rule;
  }
  if (g_pids.size() > 4096) g_pids.clear();
  Known known{now, -1, L""};
  HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process != nullptr) {
    wchar_t path[MAX_PATH * 2];
    DWORD size = static_cast<DWORD>(sizeof(path) / sizeof(path[0]));
    if (::QueryFullProcessImageNameW(process, 0, path, &size)) {
      const std::wstring full(path, size);
      const size_t slash = full.find_last_of(L"\\/");
      known.name = slash == std::wstring::npos ? full : full.substr(slash + 1);
      known.rule = Match(Normalize(full));
    }
    ::CloseHandle(process);
  }
  g_pids[pid] = known;
  name = known.name;
  return known.rule;
}

// Адрес не в интернете: локальная сеть, сам компьютер, служебные и групповые адреса.
bool Local(ULONG net) {
  const ULONG h = ntohl(net);
  const ULONG top = h >> 24;
  return top == 0 || top == 10 || top == 127 || (h & 0xFFC00000) == 0x64400000 ||
         (h & 0xFFFF0000) == 0xA9FE0000 || (h & 0xFFF00000) == 0xAC100000 || (h & 0xFFFF0000) == 0xC0A80000 ||
         h >= 0xE0000000;
}

// Маршрут, под который попадает адрес; nullptr — такого нет. Вызывается под g_mutex.
const Route* Covering(ULONG address) {
  for (const Route& r : g_routes) {
    if ((address & r.mask) == r.net) return &r;
  }
  return nullptr;
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

std::string NetText(ULONG net, unsigned char prefix) {
  const auto* b = reinterpret_cast<const unsigned char*>(&net);
  return std::to_string(b[0]) + "." + std::to_string(b[1]) + "." + std::to_string(b[2]) + "." +
         std::to_string(b[3]) + "/" + std::to_string(prefix);
}

void SaveState() {
  if (g_state_file.empty()) return;
  if (g_routes.empty()) {
    ::DeleteFileW(g_state_file.c_str());
    return;
  }
  std::string text;
  for (const Route& r : g_routes) text += NetText(r.net, r.row.DestinationPrefix.PrefixLength) + "\n";
  HANDLE file = ::CreateFileW(g_state_file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  ::WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written, nullptr);
  ::CloseHandle(file);
}

// Маршрут к подсети мимо адаптера. Вызывается под g_mutex.
bool AddRoute(const BypassNet& net) {
  MIB_IPFORWARD_ROW2 base;
  if (!PhysicalDefault(base)) return false;
  const ULONG mask = Mask(net.second);
  MIB_IPFORWARD_ROW2 row;
  ::InitializeIpForwardEntry(&row);
  row.InterfaceLuid = base.InterfaceLuid;
  row.InterfaceIndex = base.InterfaceIndex;
  row.DestinationPrefix.Prefix.Ipv4.sin_family = AF_INET;
  row.DestinationPrefix.Prefix.Ipv4.sin_addr.s_addr = net.first & mask;
  row.DestinationPrefix.PrefixLength = net.second;
  row.NextHop = base.NextHop;
  row.Metric = 0;
  row.Protocol = MIB_IPPROTO_NETMGMT;
  // Такой маршрут уже есть (поставил кто-то другой) — он не наш, и убирать его не нам.
  if (::CreateIpForwardEntry2(&row) != NO_ERROR) return false;
  FILETIME now;
  ::GetSystemTimePreciseAsFileTime(&now);
  g_routes.push_back(
      {row, net.first & mask, mask, (static_cast<LONGLONG>(now.dwHighDateTime) << 32) | now.dwLowDateTime});
  SaveState();
  return true;
}

// Сначала Kill Switch пропускает подсеть, потом к ней ставится маршрут.
bool Allow(const BypassNet& net) { return !g_before || g_before(net); }

void Handle(ULONG address, const std::wstring& name, int rule) {
  if (Local(address)) return;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_seen.count(address) || g_seen.size() >= kMaxRoutes) return;
    g_seen.insert(address);
    // Адрес из уже открытой подсети (запомненной раньше) — маршрут к нему есть.
    if (Covering(address) != nullptr) return;
  }
  const BypassNet net{address, static_cast<unsigned char>(32)};
  if (!Allow(net)) return;
  bool added;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    added = g_routes.size() < kMaxRoutes && AddRoute(net);
  }
  if (added && g_after) g_after(address, name, g_rule_texts[static_cast<size_t>(rule)]);
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
    g_layout_checked = true;
    DWORD named = 0;
    g_pid_by_name = Prop(e, L"PID", &named, sizeof(named)) && named != pid;
  }
  if (g_pid_by_name && !Prop(e, L"PID", &pid, sizeof(pid))) return;
  std::wstring name;
  const int rule = DirectRule(pid, name);
  if (rule < 0) return;
  // Адрес назначения — третье поле (после PID и size), если описание события недоступно.
  ULONG address = 0;
  if (!Prop(e, L"daddr", &address, sizeof(address))) std::memcpy(&address, static_cast<BYTE*>(e->UserData) + 8, 4);
  // Отправитель — адрес адаптера, хотя маршрут к этому адресу уже идёт мимо: программа «подключила» сокет
  // UDP (connect), и Windows привязала его к адаптеру. Такой сокет до закрытия шлёт через ядро; мимо пойдёт
  // только новое соединение. Сообщаем один раз на программу и адрес.
  ULONG source = 0;
  if (!Prop(e, L"saddr", &source, sizeof(source)) && e->UserDataLength >= 16) {
    std::memcpy(&source, static_cast<BYTE*>(e->UserData) + 12, 4);
  }
  if (source == g_tun && g_stuck) {
    LONGLONG routed = 0;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      const Route* r = Covering(address);
      if (r != nullptr) routed = r->at;
    }
    if (routed != 0 && e->EventHeader.TimeStamp.QuadPart > routed + kStuckMargin) {
      int& count = g_stuck_count[(static_cast<ULONGLONG>(pid) << 32) | address];
      if (count >= 0 && ++count >= kStuckPackets) {
        count = -1;
        g_stuck(address, name);
      }
    }
  }
  Handle(address, name, rule);
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

}  // namespace

bool BypassNetOk(const BypassNet& net) {
  return net.second >= 16 && net.second <= 32 && !Local(net.first & Mask(net.second));
}

std::wstring BypassStart(const std::wstring& session_name, const std::wstring& tun_v4,
                         const std::vector<std::wstring>& rules, const std::vector<BypassNet>& preload,
                         const std::wstring& state_file, std::function<bool(const BypassNet&)> before_route,
                         std::function<void(unsigned long, const std::wstring&, const std::wstring&)> on_route,
                         std::function<void(unsigned long, const std::wstring&)> on_stuck) {
  BypassStop();
  IN_ADDR tun{};
  if (::InetPtonW(AF_INET, tun_v4.c_str(), &tun) != 1) return L"неверный адрес адаптера";
  BypassCleanupStale(state_file);

  g_session_name = session_name;
  g_state_file = state_file;
  g_tun = tun.s_addr;
  g_rules.clear();
  g_rule_texts.clear();
  for (const std::wstring& rule : rules) {
    if (rule.empty()) continue;
    g_rules.push_back(Normalize(rule));
    g_rule_texts.push_back(rule);
  }
  g_before = std::move(before_route);
  g_after = std::move(on_route);
  g_stuck = std::move(on_stuck);
  g_stuck_count.clear();
  g_pids.clear();
  g_layout_checked = g_pid_by_name = false;

  // Запомненные подсети — до первого пакета программы.
  for (const BypassNet& net : preload) {
    if (!BypassNetOk(net) || !Allow(net)) continue;
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_routes.size() >= kMaxRoutes) break;
    if (Covering(net.first) == nullptr) AddRoute(net);
  }

  // Сеанс с тем же именем мог остаться после сбоя службы.
  StopSession(session_name);
  std::vector<BYTE> props = Properties(session_name);
  TRACEHANDLE session = 0;
  ULONG rc = ::StartTraceW(&session, session_name.c_str(), reinterpret_cast<EVENT_TRACE_PROPERTIES*>(props.data()));
  if (rc != ERROR_SUCCESS) {
    BypassStop();
    return L"не удалось начать слежение (код " + std::to_wstring(rc) + L")";
  }

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
    BypassStop();
    return L"не удалось включить события сети (код " + std::to_wstring(rc) + L")";
  }

  EVENT_TRACE_LOGFILEW log{};
  log.LoggerName = g_session_name.data();
  log.ProcessTraceMode = PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD;
  log.EventRecordCallback = OnEvent;
  const TRACEHANDLE trace = ::OpenTraceW(&log);
  if (trace == INVALID_PROCESSTRACE_HANDLE) {
    const DWORD error = ::GetLastError();
    ::ControlTraceW(session, nullptr, reinterpret_cast<EVENT_TRACE_PROPERTIES*>(props.data()), EVENT_TRACE_CONTROL_STOP);
    BypassStop();
    return L"не удалось читать события сети (код " + std::to_wstring(error) + L")";
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
  for (Route& r : g_routes) ::DeleteIpForwardEntry2(&r.row);
  g_routes.clear();
  g_seen.clear();
  SaveState();
  g_before = nullptr;
  g_after = nullptr;
  g_stuck = nullptr;
}

std::vector<BypassNet> BypassNets() {
  std::lock_guard<std::mutex> lock(g_mutex);
  std::vector<BypassNet> out;
  for (const Route& r : g_routes) out.emplace_back(r.net, r.row.DestinationPrefix.PrefixLength);
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
  // Строки «a.b.c.d/префикс» (у прежних записей — просто адрес, это /32).
  std::set<std::pair<ULONG, UINT8>> nets;
  size_t start = 0;
  while (start < text.size()) {
    size_t end = text.find('\n', start);
    if (end == std::string::npos) end = text.size();
    std::string line = text.substr(start, end - start);
    start = end + 1;
    unsigned prefix = 32;
    const size_t slash = line.find('/');
    if (slash != std::string::npos) {
      prefix = static_cast<unsigned>(std::strtoul(line.c_str() + slash + 1, nullptr, 10));
      line.resize(slash);
    }
    IN_ADDR address{};
    if (prefix <= 32 && ::InetPtonA(AF_INET, line.c_str(), &address) == 1) {
      nets.insert({address.s_addr, static_cast<UINT8>(prefix)});
    }
  }
  PMIB_IPFORWARD_TABLE2 table = nullptr;
  if (::GetIpForwardTable2(AF_INET, &table) == NO_ERROR) {
    for (ULONG i = 0; i < table->NumEntries; i++) {
      MIB_IPFORWARD_ROW2& row = table->Table[i];
      if (row.Protocol == MIB_IPPROTO_NETMGMT &&
          nets.count({row.DestinationPrefix.Prefix.Ipv4.sin_addr.s_addr, row.DestinationPrefix.PrefixLength})) {
        ::DeleteIpForwardEntry2(&row);
      }
    }
    ::FreeMibTable(table);
  }
  ::DeleteFileW(state_file.c_str());
}

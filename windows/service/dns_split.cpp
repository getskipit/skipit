// DNS по программам.
//
// Программа не спрашивает адрес сама: она просит Windows, и запрос DNS отправляет системная служба
// «DNS-клиент», одна на всех. Поэтому в ядро он приходит без имени программы, и раньше программы из
// списка «напрямую» получали адреса, найденные через VPN, — «как из страны VPN-сервера». Сайты с узлами
// в разных странах (CDN) называли далёкий узел, а то и такой, что напрямую не открывается.
//
// Кто спросил, Windows пишет в журнал событий DNS-клиента (ETW, событие 3006 «вызван запрос DNS»
// пишется в процессе самой программы). Служба читает этот журнал, а запросы DNS из адаптера ядро
// присылает сюда, на 127.0.0.1. Имя спросила программа из списка «напрямую» — запрос уходит местному
// DNS мимо VPN (через вход Xray с выходом «напрямую»), иначе — во встроенный DNS Xray, как раньше.
// Не нашлось записи в журнале (программа шлёт запросы DNS сама, мимо Windows) — тоже как раньше.

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <evntcons.h>
#include <evntrace.h>
#include <mstcpip.h>
#include <tlhelp32.h>

#include "dns_split.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <map>
#include <mutex>
#include <thread>

// Сборка задаёт старую версию Windows, и заголовки прячут эти значения (есть с Windows 8 и XP).
#ifndef EVENT_TRACE_USE_MS_FLUSH_TIMER
#define EVENT_TRACE_USE_MS_FLUSH_TIMER 0x00000010
#endif
#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif

namespace {

// Microsoft-Windows-DNS-Client.
const GUID kDnsClient = {0x1c95126e, 0x7eea, 0x49a9, {0xa3, 0xfe, 0xa3, 0x78, 0xb0, 0x3d, 0xdb, 0x4d}};
constexpr USHORT kQueryCalled = 3006;

// Сколько ждать записи журнала, если запрос пришёл раньше неё, и сколько запись считается свежей.
constexpr auto kWait = std::chrono::milliseconds(150);
constexpr ULONGLONG kFreshMs = 5000;
constexpr int kMaxInflight = 256;

struct Ask {
  DWORD pid;
  ULONGLONG tick;
};

std::wstring Lower(std::wstring s) {
  if (!s.empty()) ::CharLowerBuffW(s.data(), static_cast<DWORD>(s.size()));
  return s;
}

// Имя в том виде, как его сравниваем: нижний регистр, без точки в конце.
std::string Key(std::string s) {
  while (!s.empty() && s.back() == '.') s.pop_back();
  for (char& c : s) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
  }
  return s;
}

std::string Utf8(const std::wstring& w) {
  if (w.empty()) return "";
  const int n = ::WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
  if (n <= 0) return "";
  std::string s(static_cast<size_t>(n), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), s.data(), n, nullptr, nullptr);
  return s;
}

// Имя из вопроса запроса DNS; пустая строка — пакет не разобрать.
std::string QueryName(const std::string& packet) {
  if (packet.size() < 12 || ((static_cast<unsigned char>(packet[4]) << 8) | static_cast<unsigned char>(packet[5])) == 0) {
    return "";
  }
  std::string name;
  size_t i = 12;
  while (i < packet.size()) {
    const size_t len = static_cast<unsigned char>(packet[i]);
    if (len == 0) return Key(name);
    // Сжатия в вопросе не бывает; метка длиннее 63 — это оно или мусор.
    if (len > 63 || i + 1 + len > packet.size() || name.size() + len + 1 > 255) return "";
    if (!name.empty()) name += '.';
    name.append(packet, i + 1, len);
    i += 1 + len;
  }
  return "";
}

SOCKET Loopback(int type, unsigned short port, bool bind_it) {
  SOCKET s = ::socket(AF_INET, type, type == SOCK_STREAM ? IPPROTO_TCP : IPPROTO_UDP);
  if (s == INVALID_SOCKET) return s;
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_port = ::htons(port);
  a.sin_addr.s_addr = ::htonl(INADDR_LOOPBACK);
  const int r = bind_it ? ::bind(s, reinterpret_cast<sockaddr*>(&a), sizeof(a))
                        : ::connect(s, reinterpret_cast<sockaddr*>(&a), sizeof(a));
  if (r != 0) {
    ::closesocket(s);
    return INVALID_SOCKET;
  }
  return s;
}

void Timeouts(SOCKET s, DWORD ms) {
  ::setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&ms), sizeof(ms));
  ::setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&ms), sizeof(ms));
}

bool ReadExact(SOCKET s, char* buf, int n) {
  while (n > 0) {
    const int r = ::recv(s, buf, n, 0);
    if (r <= 0) return false;
    buf += r;
    n -= r;
  }
  return true;
}

bool WriteAll(SOCKET s, const char* buf, int n) {
  while (n > 0) {
    const int r = ::send(s, buf, n, 0);
    if (r <= 0) return false;
    buf += r;
    n -= r;
  }
  return true;
}

// Запрос DNS по TCP: два байта длины и сам запрос.
bool ReadTcpMessage(SOCKET s, std::string& out) {
  unsigned char len[2];
  if (!ReadExact(s, reinterpret_cast<char*>(len), 2)) return false;
  const int n = (len[0] << 8) | len[1];
  if (n == 0) return false;
  out.assign(static_cast<size_t>(n), '\0');
  return ReadExact(s, out.data(), n);
}

bool WriteTcpMessage(SOCKET s, const std::string& data) {
  if (data.size() > 0xFFFF) return false;
  std::string framed;
  framed += static_cast<char>(data.size() >> 8);
  framed += static_cast<char>(data.size() & 0xFF);
  framed += data;
  return WriteAll(s, framed.data(), static_cast<int>(framed.size()));
}

}  // namespace

bool DnsSplitMatches(const std::wstring& match, const std::wstring& path) {
  if (match.empty()) return false;
  if (match.back() == L'\\') return path.compare(0, match.size(), match) == 0;
  if (match.find(L'\\') != std::wstring::npos) return path == match;
  const size_t slash = path.find_last_of(L'\\');
  const std::wstring name = slash == std::wstring::npos ? path : path.substr(slash + 1);
  return name == match || name == match + L".exe";
}

class DnsSplit : public std::enable_shared_from_this<DnsSplit> {
 public:
  explicit DnsSplit(const DnsSplitConfig& config) : config_(config) {
    for (auto& m : config_.matches) {
      for (auto& c : m) {
        if (c == L'/') c = L'\\';
      }
      m = Lower(m);
    }
  }

  bool Start(std::wstring& error) {
    udp_ = Loopback(SOCK_DGRAM, config_.listen, true);
    tcp_ = Loopback(SOCK_STREAM, config_.listen, true);
    if (udp_ == INVALID_SOCKET || tcp_ == INVALID_SOCKET || ::listen(tcp_, SOMAXCONN) != 0) {
      error = L"port";
      return false;
    }
    // Иначе ответ «порт недоступен» на прежний ответ ломал бы приём следующих запросов.
    BOOL off = FALSE;
    DWORD unused = 0;
    ::WSAIoctl(udp_, SIO_UDP_CONNRESET, &off, sizeof(off), nullptr, 0, &unused, nullptr, nullptr);
    if (!StartTrace(error)) return false;
    auto self = shared_from_this();
    trace_thread_ = std::thread([self] { ::ProcessTrace(&self->trace_, 1, nullptr, nullptr); });
    udp_thread_ = std::thread([self] { self->ServeUdp(); });
    tcp_thread_ = std::thread([self] { self->ServeTcp(); });
    return true;
  }

  void Stop() {
    if (stopped_.exchange(true)) return;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      cv_.notify_all();
    }
    StopTrace();
    {
      // Ответы, которые ещё в пути, сокет после закрытия не тронут (см. ServeUdp).
      std::lock_guard<std::mutex> lock(udp_mutex_);
      if (udp_ != INVALID_SOCKET) ::closesocket(udp_);
    }
    if (tcp_ != INVALID_SOCKET) ::closesocket(tcp_);
    for (std::thread* t : {&trace_thread_, &udp_thread_, &tcp_thread_}) {
      if (t->joinable()) t->join();
    }
    if (trace_ != INVALID_PROCESSTRACE_HANDLE) ::CloseTrace(trace_);
    trace_ = INVALID_PROCESSTRACE_HANDLE;
  }

  ~DnsSplit() { Stop(); }

 private:
  // ---------- журнал DNS-клиента ----------

  EVENT_TRACE_PROPERTIES* Props() {
    const size_t size = sizeof(EVENT_TRACE_PROPERTIES) + (config_.session_name.size() + 1) * sizeof(wchar_t);
    props_.assign(size, 0);
    auto* p = reinterpret_cast<EVENT_TRACE_PROPERTIES*>(props_.data());
    p->Wnode.BufferSize = static_cast<ULONG>(size);
    p->Wnode.Flags = WNODE_FLAG_TRACED_GUID;
    p->Wnode.ClientContext = 1;
    // Записи нужны сразу: запрос DNS ждёт решения. Буферы маленькие и сбрасываются раз в 20 мс.
    p->LogFileMode = EVENT_TRACE_REAL_TIME_MODE | EVENT_TRACE_USE_MS_FLUSH_TIMER;
    p->FlushTimer = 20;
    p->BufferSize = 4;
    p->MinimumBuffers = 4;
    p->MaximumBuffers = 32;
    p->LoggerNameOffset = sizeof(EVENT_TRACE_PROPERTIES);
    return p;
  }

  bool StartTrace(std::wstring& error) {
    const wchar_t* name = config_.session_name.c_str();
    // Сеанс с тем же именем мог остаться после сбоя службы.
    ::ControlTraceW(0, name, Props(), EVENT_TRACE_CONTROL_STOP);
    ULONG rc = ::StartTraceW(&session_, name, Props());
    if (rc != ERROR_SUCCESS) {
      session_ = 0;
      error = L"trace " + std::to_wstring(rc);
      return false;
    }
    // Только событие 3006: остальные записи DNS-клиента (их около двадцати на запрос) не нужны.
    struct {
      EVENT_FILTER_EVENT_ID head;
    } ids{};
    ids.head.FilterIn = TRUE;
    ids.head.Count = 1;
    ids.head.Events[0] = kQueryCalled;
    EVENT_FILTER_DESCRIPTOR filter{reinterpret_cast<ULONGLONG>(&ids), sizeof(ids), EVENT_FILTER_TYPE_EVENT_ID};
    ENABLE_TRACE_PARAMETERS params{};
    params.Version = ENABLE_TRACE_PARAMETERS_VERSION_2;
    params.EnableFilterDesc = &filter;
    params.FilterDescCount = 1;
    rc = ::EnableTraceEx2(session_, &kDnsClient, EVENT_CONTROL_CODE_ENABLE_PROVIDER, TRACE_LEVEL_VERBOSE,
                          ~0ULL, 0, 0, &params);
    if (rc != ERROR_SUCCESS) {
      rc = ::EnableTraceEx2(session_, &kDnsClient, EVENT_CONTROL_CODE_ENABLE_PROVIDER, TRACE_LEVEL_VERBOSE, ~0ULL, 0,
                            0, nullptr);
    }
    if (rc != ERROR_SUCCESS) {
      error = L"enable " + std::to_wstring(rc);
      return false;
    }
    EVENT_TRACE_LOGFILEW log{};
    log.LoggerName = config_.session_name.data();
    log.ProcessTraceMode = PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD;
    log.EventRecordCallback = OnEvent;
    log.Context = this;
    trace_ = ::OpenTraceW(&log);
    if (trace_ == INVALID_PROCESSTRACE_HANDLE) {
      error = L"open " + std::to_wstring(::GetLastError());
      return false;
    }
    return true;
  }

  void StopTrace() {
    if (session_ == 0) return;
    ::ControlTraceW(session_, nullptr, Props(), EVENT_TRACE_CONTROL_STOP);
    session_ = 0;
  }

  static void WINAPI OnEvent(PEVENT_RECORD e) {
    if (e->EventHeader.EventDescriptor.Id != kQueryCalled || !::IsEqualGUID(e->EventHeader.ProviderId, kDnsClient)) {
      return;
    }
    // Первое поле события — имя (строка UTF-16 с нулём в конце).
    const size_t max = e->UserDataLength / sizeof(wchar_t);
    std::wstring name(max, L'\0');
    if (max > 0) memcpy(name.data(), e->UserData, max * sizeof(wchar_t));
    const size_t end = name.find(L'\0');
    if (end == std::wstring::npos || end == 0) return;
    name.resize(end);
    static_cast<DnsSplit*>(e->UserContext)->Asked(Key(Utf8(name)), e->EventHeader.ProcessId);
  }

  void Asked(const std::string& name, DWORD pid) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      const ULONGLONG now = ::GetTickCount64();
      asked_[name] = {pid, now};
      if (asked_.size() > 2048) {
        for (auto it = asked_.begin(); it != asked_.end();) it = now - it->second.tick > kFreshMs ? asked_.erase(it) : ++it;
      }
      cv_.notify_all();
    }
    // Программа из списка спрашивает адреса — дальше её запросы стоит подождать (см. ListedRunning).
    std::lock_guard<std::mutex> lock(proc_mutex_);
    if (ListedLocked(pid)) {
      running_ = true;
      running_checked_ = ::GetTickCount64();
    }
  }

  // ---------- кто спросил ----------

  bool Listed(DWORD pid) {
    std::lock_guard<std::mutex> lock(proc_mutex_);
    return ListedLocked(pid);
  }

  // Подходит ли процесс под список (результат помнится 10 с: номера процессов Windows раздаёт заново).
  // Под proc_mutex_.
  bool ListedLocked(DWORD pid) {
    const ULONGLONG now = ::GetTickCount64();
    const auto it = pids_.find(pid);
    if (it != pids_.end() && now - it->second.second < 10000) return it->second.first;
    bool listed = false;
    HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (process != nullptr) {
      wchar_t path[MAX_PATH * 2];
      DWORD size = static_cast<DWORD>(sizeof(path) / sizeof(path[0]));
      if (::QueryFullProcessImageNameW(process, 0, path, &size)) {
        const std::wstring lower = Lower(std::wstring(path, size));
        for (const auto& m : config_.matches) {
          if (DnsSplitMatches(m, lower)) {
            listed = true;
            break;
          }
        }
      }
      ::CloseHandle(process);
    }
    if (pids_.size() > 4096) pids_.clear();
    pids_[pid] = {listed, now};
    return listed;
  }

  // Запущена ли сейчас хоть одна программа из списка. Если нет — ждать записи журнала незачем: запрос без
  // записи (программа шлёт его сама) не задерживается. «Запущена» помнится 2 с, «нет» — 50 мс: только что
  // открытая игра спрашивает адреса сразу, и её первые запросы не должны проскочить мимо. Список процессов
  // перебирается под своим замком: запросы, у которых запись уже есть, и журнал его не ждут.
  bool ListedRunning() {
    std::lock_guard<std::mutex> lock(proc_mutex_);
    const ULONGLONG now = ::GetTickCount64();
    if (now - running_checked_ < (running_ ? 2000u : 50u)) return running_;
    running_checked_ = now;
    running_ = false;
    HANDLE snap = ::CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return running_ = true;
    PROCESSENTRY32W entry{sizeof(entry)};
    for (BOOL ok = ::Process32FirstW(snap, &entry); ok && !running_; ok = ::Process32NextW(snap, &entry)) {
      if (entry.th32ProcessID != 0 && ListedLocked(entry.th32ProcessID)) running_ = true;
    }
    ::CloseHandle(snap);
    return running_;
  }

  // Кто недавно спросил имя [name] (под mutex_).
  bool Asker(const std::string& name, DWORD& pid) {
    const auto it = asked_.find(name);
    if (it == asked_.end() || ::GetTickCount64() - it->second.tick >= kFreshMs) return false;
    pid = it->second.pid;
    return true;
  }

  // Куда отправить запрос об имени [name]: порт местного DNS или DNS ядра.
  unsigned short Route(const std::string& name) {
    if (name.empty()) return config_.remote;
    DWORD pid = 0;
    bool found;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      found = Asker(name, pid);
    }
    // Запись журнала приходит с задержкой в десятки миллисекунд — если есть кого, её стоит подождать.
    if (!found && (config_.only_selected || ListedRunning())) {
      std::unique_lock<std::mutex> lock(mutex_);
      cv_.wait_for(lock, kWait, [&] { return stopped_ || Asker(name, pid); });
      found = Asker(name, pid);
    }
    if (!found) return config_.remote;
    // «Все, кроме списка»: программа из списка — напрямую. «Только выбранные»: из списка — через VPN.
    return Listed(pid) != config_.only_selected ? config_.local : config_.remote;
  }

  // ---------- пересылка ----------

  bool ForwardUdp(unsigned short port, const std::string& query, std::string& reply) {
    SOCKET s = Loopback(SOCK_DGRAM, port, false);
    if (s == INVALID_SOCKET) return false;
    Timeouts(s, 5000);
    bool ok = ::send(s, query.data(), static_cast<int>(query.size()), 0) == static_cast<int>(query.size());
    if (ok) {
      reply.assign(65536, '\0');
      const int n = ::recv(s, reply.data(), static_cast<int>(reply.size()), 0);
      ok = n > 0;
      reply.resize(ok ? static_cast<size_t>(n) : 0);
    }
    ::closesocket(s);
    return ok;
  }

  bool ForwardTcp(unsigned short port, const std::string& query, std::string& reply) {
    SOCKET s = Loopback(SOCK_STREAM, port, false);
    if (s == INVALID_SOCKET) return false;
    Timeouts(s, 10000);
    const bool ok = WriteTcpMessage(s, query) && ReadTcpMessage(s, reply);
    ::closesocket(s);
    return ok;
  }

  void ServeUdp() {
    std::string buf(65536, '\0');
    while (!stopped_) {
      sockaddr_in from{};
      int from_len = sizeof(from);
      const int n = ::recvfrom(udp_, buf.data(), static_cast<int>(buf.size()), 0, reinterpret_cast<sockaddr*>(&from), &from_len);
      if (n <= 0) {
        if (stopped_ || ::WSAGetLastError() == WSAENOTSOCK) return;
        continue;
      }
      if (inflight_ >= kMaxInflight) continue;
      inflight_++;
      auto self = shared_from_this();
      std::thread([self, query = buf.substr(0, static_cast<size_t>(n)), from] {
        std::string reply;
        if (self->ForwardUdp(self->Route(QueryName(query)), query, reply)) {
          std::lock_guard<std::mutex> lock(self->udp_mutex_);
          if (!self->stopped_) {
            ::sendto(self->udp_, reply.data(), static_cast<int>(reply.size()), 0,
                     reinterpret_cast<const sockaddr*>(&from), sizeof(from));
          }
        }
        self->inflight_--;
      }).detach();
    }
  }

  void ServeTcp() {
    while (!stopped_) {
      SOCKET client = ::accept(tcp_, nullptr, nullptr);
      if (client == INVALID_SOCKET) {
        if (stopped_ || ::WSAGetLastError() == WSAENOTSOCK) return;
        continue;
      }
      if (inflight_ >= kMaxInflight) {
        ::closesocket(client);
        continue;
      }
      inflight_++;
      auto self = shared_from_this();
      std::thread([self, client] {
        Timeouts(client, 15000);
        std::string query, reply;
        while (!self->stopped_ && ReadTcpMessage(client, query)) {
          if (!self->ForwardTcp(self->Route(QueryName(query)), query, reply) || !WriteTcpMessage(client, reply)) break;
        }
        ::closesocket(client);
        self->inflight_--;
      }).detach();
    }
  }

  DnsSplitConfig config_;
  std::vector<char> props_;
  TRACEHANDLE session_ = 0;
  TRACEHANDLE trace_ = INVALID_PROCESSTRACE_HANDLE;
  SOCKET udp_ = INVALID_SOCKET, tcp_ = INVALID_SOCKET;
  std::thread trace_thread_, udp_thread_, tcp_thread_;
  std::atomic<bool> stopped_{false};
  std::atomic<int> inflight_{0};
  std::mutex udp_mutex_;   // Закрытие udp_ и отправка ответов.
  std::mutex mutex_;       // asked_ и ожидание записей журнала.
  std::condition_variable cv_;
  std::map<std::string, Ask> asked_;
  std::mutex proc_mutex_;  // pids_, running_, running_checked_.
  std::map<DWORD, std::pair<bool, ULONGLONG>> pids_;
  ULONGLONG running_checked_ = 0;
  bool running_ = false;
};

std::shared_ptr<DnsSplit> DnsSplitStart(const DnsSplitConfig& config, std::wstring& error) {
  static std::once_flag wsa;
  std::call_once(wsa, [] {
    WSADATA data;
    ::WSAStartup(MAKEWORD(2, 2), &data);
  });
  auto split = std::make_shared<DnsSplit>(config);
  if (!split->Start(error)) {
    split->Stop();
    return nullptr;
  }
  return split;
}

void DnsSplitStop(const std::shared_ptr<DnsSplit>& split) {
  if (split) split->Stop();
}

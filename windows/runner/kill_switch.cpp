#include "kill_switch.h"

// Заголовки WFP не рассчитаны на строгий уровень предупреждений проекта (/W4 /WX).
#pragma warning(push, 0)
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
// Определения GUID слоёв и условий WFP — в этом файле, без отдельной библиотеки.
#include <initguid.h>
#include <fwpmu.h>
#pragma warning(pop)

namespace {

HANDLE g_engine = nullptr;

// Чем больше вес, тем раньше фильтр проверяется; срабатывает первый подошедший.
constexpr UINT8 kWeightCores = 15;
constexpr UINT8 kWeightTunnel = 14;
constexpr UINT8 kWeightDns = 13;
constexpr UINT8 kWeightLan = 12;
constexpr UINT8 kWeightBlockAll = 10;

struct Net4 {
  UINT32 addr;
  UINT32 mask;
};

// Локальная сеть и служебные адреса (в том числе DHCP): 10/8, 172.16/12, 192.168/16, 169.254/16,
// 224/4, 255.255.255.255.
constexpr Net4 kLan4[] = {
    {0x0A000000, 0xFF000000}, {0xAC100000, 0xFFF00000}, {0xC0A80000, 0xFFFF0000},
    {0xA9FE0000, 0xFFFF0000}, {0xE0000000, 0xF0000000}, {0xFFFFFFFF, 0xFFFFFFFF},
};

struct Net6 {
  UINT8 first;
  UINT8 second;
  UINT8 prefix;
};

// fc00::/7, fe80::/10, ff00::/8.
constexpr Net6 kLan6[] = {{0xFC, 0x00, 7}, {0xFE, 0x80, 10}, {0xFF, 0x00, 8}};

std::wstring Error(const wchar_t* step, DWORD code) {
  wchar_t text[96];
  swprintf_s(text, L"%s: 0x%08lX", step, code);
  return text;
}

struct Context {
  HANDLE engine;
  GUID sublayer;
};

DWORD AddFilter(const Context& c, const GUID& layer, UINT8 weight, bool permit,
                FWPM_FILTER_CONDITION0* conditions, UINT32 count) {
  wchar_t name[] = L"SkipIt kill switch";
  FWPM_FILTER0 filter{};
  filter.displayData.name = name;
  filter.layerKey = layer;
  filter.subLayerKey = c.sublayer;
  filter.weight.type = FWP_UINT8;
  filter.weight.uint8 = weight;
  filter.numFilterConditions = count;
  filter.filterCondition = conditions;
  filter.action.type = permit ? FWP_ACTION_PERMIT : FWP_ACTION_BLOCK;
  return FwpmFilterAdd0(c.engine, &filter, nullptr, nullptr);
}

// Фильтры одного слоя: исходящие или входящие (|inbound|) соединения IPv4 или IPv6.
// Входящие закрываются так же, как исходящие: иначе программа, которая сама принимает подключения
// (торрент-клиент, игровой сервер), продолжала бы обмениваться данными через обычную сеть.
std::wstring AddLayer(const Context& c, bool v6, bool inbound, const std::vector<FWP_BYTE_BLOB*>& apps,
                      FWP_BYTE_BLOB* self, const std::wstring& tun) {
  const GUID& layer = inbound ? (v6 ? FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V6 : FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V4)
                              : (v6 ? FWPM_LAYER_ALE_AUTH_CONNECT_V6 : FWPM_LAYER_ALE_AUTH_CONNECT_V4);
  DWORD rc;

  if (inbound) {
    // Ответы сервера, который раздаёт компьютеру адрес (DHCP): он может быть и не из локальной сети —
    // без них компьютер со временем остался бы без адреса и без сети вообще.
    FWPM_FILTER_CONDITION0 conds[2]{};
    conds[0].fieldKey = FWPM_CONDITION_IP_PROTOCOL;
    conds[0].matchType = FWP_MATCH_EQUAL;
    conds[0].conditionValue.type = FWP_UINT8;
    conds[0].conditionValue.uint8 = IPPROTO_UDP;
    conds[1].fieldKey = FWPM_CONDITION_IP_LOCAL_PORT;
    conds[1].matchType = FWP_MATCH_EQUAL;
    conds[1].conditionValue.type = FWP_UINT16;
    conds[1].conditionValue.uint16 = v6 ? 546 : 68;
    if ((rc = AddFilter(c, layer, kWeightCores, true, conds, 2)) != ERROR_SUCCESS) return Error(L"dhcp", rc);
    if (v6) {
      // Служебные сообщения IPv6 (поиск соседей и роутера): без них IPv6 в локальной сети не работает.
      FWPM_FILTER_CONDITION0 icmp{};
      icmp.fieldKey = FWPM_CONDITION_IP_PROTOCOL;
      icmp.matchType = FWP_MATCH_EQUAL;
      icmp.conditionValue.type = FWP_UINT8;
      icmp.conditionValue.uint8 = IPPROTO_ICMPV6;
      if ((rc = AddFilter(c, layer, kWeightCores, true, &icmp, 1)) != ERROR_SUCCESS) return Error(L"icmp6", rc);
    }
  }

  // Ядра VPN: им нужен выход в сеть мимо адаптера — до сервера и для трафика «напрямую».
  for (FWP_BYTE_BLOB* app : apps) {
    FWPM_FILTER_CONDITION0 cond{};
    cond.fieldKey = FWPM_CONDITION_ALE_APP_ID;
    cond.matchType = FWP_MATCH_EQUAL;
    cond.conditionValue.type = FWP_BYTE_BLOB_TYPE;
    cond.conditionValue.byteBlob = app;
    if ((rc = AddFilter(c, layer, kWeightCores, true, &cond, 1)) != ERROR_SUCCESS) return Error(L"app", rc);
  }

  // Соединения внутри компьютера (в том числе с локальными портами прокси).
  {
    FWPM_FILTER_CONDITION0 cond{};
    cond.fieldKey = FWPM_CONDITION_FLAGS;
    cond.matchType = FWP_MATCH_FLAGS_ALL_SET;
    cond.conditionValue.type = FWP_UINT32;
    cond.conditionValue.uint32 = FWP_CONDITION_FLAG_IS_LOOPBACK;
    if ((rc = AddFilter(c, layer, kWeightCores, true, &cond, 1)) != ERROR_SUCCESS) return Error(L"loopback", rc);
  }

  // Соединения через адаптер VPN: у них локальный адрес — адрес адаптера.
  {
    FWPM_FILTER_CONDITION0 cond{};
    cond.fieldKey = FWPM_CONDITION_IP_LOCAL_ADDRESS;
    cond.matchType = FWP_MATCH_EQUAL;
    FWP_BYTE_ARRAY16 address6{};
    if (v6) {
      IN6_ADDR parsed{};
      if (InetPtonW(AF_INET6, tun.c_str(), &parsed) != 1) return Error(L"tun6", ERROR_INVALID_PARAMETER);
      memcpy(address6.byteArray16, parsed.u.Byte, 16);
      cond.conditionValue.type = FWP_BYTE_ARRAY16_TYPE;
      cond.conditionValue.byteArray16 = &address6;
    } else {
      IN_ADDR parsed{};
      if (InetPtonW(AF_INET, tun.c_str(), &parsed) != 1) return Error(L"tun4", ERROR_INVALID_PARAMETER);
      cond.conditionValue.type = FWP_UINT32;
      cond.conditionValue.uint32 = ntohl(parsed.S_un.S_addr);
    }
    if ((rc = AddFilter(c, layer, kWeightTunnel, true, &cond, 1)) != ERROR_SUCCESS) return Error(L"tun", rc);
  }

  // DNS мимо адаптера — нельзя даже в локальную сеть (к роутеру): иначе имена сайтов уйдут провайдеру.
  if (!inbound) {
    FWPM_FILTER_CONDITION0 cond{};
    cond.fieldKey = FWPM_CONDITION_IP_REMOTE_PORT;
    cond.matchType = FWP_MATCH_EQUAL;
    cond.conditionValue.type = FWP_UINT16;
    cond.conditionValue.uint16 = 53;
    if ((rc = AddFilter(c, layer, kWeightDns, false, &cond, 1)) != ERROR_SUCCESS) return Error(L"dns", rc);
  }

  // Сама программа: только исходящие соединения TCP — так она меряет задержку до VPN-серверов мимо
  // адаптера (через адаптер рукопожатие занимает 0 мс у любого сервера). Весь остальной её трафик
  // идёт через адаптер, как у обычных программ. Вес ниже запрета DNS: к порту 53 не выпускается.
  if (!inbound && self) {
    FWPM_FILTER_CONDITION0 conds[2]{};
    conds[0].fieldKey = FWPM_CONDITION_ALE_APP_ID;
    conds[0].matchType = FWP_MATCH_EQUAL;
    conds[0].conditionValue.type = FWP_BYTE_BLOB_TYPE;
    conds[0].conditionValue.byteBlob = self;
    conds[1].fieldKey = FWPM_CONDITION_IP_PROTOCOL;
    conds[1].matchType = FWP_MATCH_EQUAL;
    conds[1].conditionValue.type = FWP_UINT8;
    conds[1].conditionValue.uint8 = IPPROTO_TCP;
    if ((rc = AddFilter(c, layer, kWeightLan, true, conds, 2)) != ERROR_SUCCESS) return Error(L"self", rc);
  }

  // Локальная сеть остаётся доступной: роутер, принтер, общие папки.
  // Несколько условий на одно поле означают «любое из них».
  if (v6) {
    FWP_V6_ADDR_AND_MASK nets[ARRAYSIZE(kLan6)]{};
    FWPM_FILTER_CONDITION0 conds[ARRAYSIZE(kLan6)]{};
    for (size_t i = 0; i < ARRAYSIZE(kLan6); i++) {
      nets[i].addr[0] = kLan6[i].first;
      nets[i].addr[1] = kLan6[i].second;
      nets[i].prefixLength = kLan6[i].prefix;
      conds[i].fieldKey = FWPM_CONDITION_IP_REMOTE_ADDRESS;
      conds[i].matchType = FWP_MATCH_EQUAL;
      conds[i].conditionValue.type = FWP_V6_ADDR_MASK;
      conds[i].conditionValue.v6AddrMask = &nets[i];
    }
    if ((rc = AddFilter(c, layer, kWeightLan, true, conds, ARRAYSIZE(conds))) != ERROR_SUCCESS) {
      return Error(L"lan6", rc);
    }
  } else {
    FWP_V4_ADDR_AND_MASK nets[ARRAYSIZE(kLan4)]{};
    FWPM_FILTER_CONDITION0 conds[ARRAYSIZE(kLan4)]{};
    for (size_t i = 0; i < ARRAYSIZE(kLan4); i++) {
      nets[i].addr = kLan4[i].addr;
      nets[i].mask = kLan4[i].mask;
      conds[i].fieldKey = FWPM_CONDITION_IP_REMOTE_ADDRESS;
      conds[i].matchType = FWP_MATCH_EQUAL;
      conds[i].conditionValue.type = FWP_V4_ADDR_MASK;
      conds[i].conditionValue.v4AddrMask = &nets[i];
    }
    if ((rc = AddFilter(c, layer, kWeightLan, true, conds, ARRAYSIZE(conds))) != ERROR_SUCCESS) {
      return Error(L"lan4", rc);
    }
  }

  // Всё остальное — не выпускать (и не принимать).
  if ((rc = AddFilter(c, layer, kWeightBlockAll, false, nullptr, 0)) != ERROR_SUCCESS) return Error(L"block", rc);
  return std::wstring();
}

}  // namespace

std::wstring KillSwitchEngage(const std::vector<std::wstring>& apps, const std::wstring& tun_v4,
                              const std::wstring& tun_v6) {
  KillSwitchRelease();

  wchar_t name[] = L"SkipIt kill switch";
  FWPM_SESSION0 session{};
  session.displayData.name = name;
  // Всё, что добавлено в таком сеансе, Windows убирает сама, когда сеанс закрывается.
  session.flags = FWPM_SESSION_FLAG_DYNAMIC;
  HANDLE engine = nullptr;
  DWORD rc = FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr, &session, &engine);
  if (rc != ERROR_SUCCESS) return Error(L"open", rc);

  std::vector<FWP_BYTE_BLOB*> ids;
  std::wstring error;
  // Фильтры ставятся одной операцией: либо все, либо ни одного.
  rc = FwpmTransactionBegin0(engine, 0);
  if (rc != ERROR_SUCCESS) {
    error = Error(L"begin", rc);
  } else {
    Context c{engine, GUID{}};
    FWPM_SUBLAYER0 sublayer{};
    if (UuidCreate(&c.sublayer) != RPC_S_OK) {
      error = Error(L"uuid", ERROR_GEN_FAILURE);
    } else {
      sublayer.subLayerKey = c.sublayer;
      sublayer.displayData.name = name;
      sublayer.weight = 0x8000;
      rc = FwpmSubLayerAdd0(engine, &sublayer, nullptr);
      if (rc != ERROR_SUCCESS) error = Error(L"sublayer", rc);
    }
    for (size_t i = 0; error.empty() && i < apps.size(); i++) {
      FWP_BYTE_BLOB* id = nullptr;
      rc = FwpmGetAppIdFromFileName0(apps[i].c_str(), &id);
      if (rc != ERROR_SUCCESS) {
        error = Error(L"appid", rc);
      } else {
        ids.push_back(id);
      }
    }
    // Сама программа (для проверки задержки). Не удалось узнать — обходимся без этого разрешения.
    FWP_BYTE_BLOB* self = nullptr;
    wchar_t own_path[MAX_PATH];
    const DWORD own_length = GetModuleFileNameW(nullptr, own_path, MAX_PATH);
    if (own_length > 0 && own_length < MAX_PATH && FwpmGetAppIdFromFileName0(own_path, &self) != ERROR_SUCCESS) {
      self = nullptr;
    }
    for (const bool inbound : {false, true}) {
      if (error.empty()) error = AddLayer(c, false, inbound, ids, self, tun_v4);
      if (error.empty()) error = AddLayer(c, true, inbound, ids, self, tun_v6);
    }
    if (self) FwpmFreeMemory0(reinterpret_cast<void**>(&self));
    if (error.empty()) {
      rc = FwpmTransactionCommit0(engine);
      if (rc != ERROR_SUCCESS) error = Error(L"commit", rc);
    } else {
      FwpmTransactionAbort0(engine);
    }
  }
  for (FWP_BYTE_BLOB* id : ids) FwpmFreeMemory0(reinterpret_cast<void**>(&id));

  if (!error.empty()) {
    FwpmEngineClose0(engine);
    return error;
  }
  g_engine = engine;
  return std::wstring();
}

unsigned long KillSwitchRelease() {
  if (!g_engine) return ERROR_SUCCESS;
  const DWORD rc = FwpmEngineClose0(g_engine);
  g_engine = nullptr;
  return rc;
}

bool KillSwitchEngaged() { return g_engine != nullptr; }

int KillSwitchCountFilters() {
  HANDLE engine = nullptr;
  if (FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr, nullptr, &engine) != ERROR_SUCCESS) return -1;
  int count = -1;
  HANDLE handle = nullptr;
  if (FwpmFilterCreateEnumHandle0(engine, nullptr, &handle) == ERROR_SUCCESS) {
    count = 0;
    for (;;) {
      FWPM_FILTER0** filters = nullptr;
      UINT32 returned = 0;
      if (FwpmFilterEnum0(engine, handle, 256, &filters, &returned) != ERROR_SUCCESS) {
        count = -1;
        break;
      }
      for (UINT32 i = 0; i < returned; i++) {
        const wchar_t* name = filters[i]->displayData.name;
        if (name && wcscmp(name, L"SkipIt kill switch") == 0) count++;
      }
      FwpmFreeMemory0(reinterpret_cast<void**>(&filters));
      if (returned < 256) break;
    }
    FwpmFilterDestroyEnumHandle0(engine, handle);
  }
  FwpmEngineClose0(engine);
  return count;
}

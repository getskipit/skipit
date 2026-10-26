#pragma warning(push, 0)
#include <winsock2.h>
#include <ws2ipdef.h>
#include <iphlpapi.h>
#include <netioapi.h>
#pragma warning(pop)

#include "net_watch.h"

namespace {

HWND g_hwnd = nullptr;
UINT g_message = 0;
HANDLE g_interfaces = nullptr;
HANDLE g_routes = nullptr;

// Вызываются в потоке Windows — только пересылаем в окно.
void NETIOAPI_API_ OnInterfaceChange(PVOID, PMIB_IPINTERFACE_ROW, MIB_NOTIFICATION_TYPE) {
  PostMessage(g_hwnd, g_message, 0, 0);
}

void NETIOAPI_API_ OnRouteChange(PVOID, PMIB_IPFORWARD_ROW2, MIB_NOTIFICATION_TYPE) {
  PostMessage(g_hwnd, g_message, 0, 0);
}

}  // namespace

void NetWatchStart(HWND hwnd, UINT message) {
  g_hwnd = hwnd;
  g_message = message;
  if (!g_interfaces) NotifyIpInterfaceChange(AF_UNSPEC, OnInterfaceChange, nullptr, FALSE, &g_interfaces);
  if (!g_routes) NotifyRouteChange2(AF_UNSPEC, OnRouteChange, nullptr, FALSE, &g_routes);
}

void NetWatchStop() {
  // CancelMibChangeNotify2 ждёт, пока закончатся уже идущие вызовы, — после него окно больше ничего не получит.
  if (g_interfaces) CancelMibChangeNotify2(g_interfaces);
  if (g_routes) CancelMibChangeNotify2(g_routes);
  g_interfaces = g_routes = nullptr;
}

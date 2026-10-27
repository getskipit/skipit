#ifndef RUNNER_NET_WATCH_H_
#define RUNNER_NET_WATCH_H_

#include <windows.h>

// Слежение за сменой сети: когда сетевая карта появляется или пропадает или меняется маршрут по умолчанию
// (Wi-Fi ↔ кабель, другой шлюз), окну |hwnd| посылается сообщение |message|. Уведомления приходят
// пачками — собирать их в одно должен получатель.
void NetWatchStart(HWND hwnd, UINT message);
void NetWatchStop();

#endif  // RUNNER_NET_WATCH_H_

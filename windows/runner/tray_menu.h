#ifndef RUNNER_TRAY_MENU_H_
#define RUNNER_TRAY_MENU_H_

#include <windows.h>

#include <string>
#include <vector>

// Сервер в меню значка: название, картинка флага (путь к PNG; пусто — флага нет) и провайдер.
// Когда у соседних серверов провайдер разный, перед сервером рисуется строка с его названием
// (пусто — без заголовков: провайдер один).
struct TrayMenuServer {
  std::wstring name;
  std::wstring flag;
  std::wstring group;
};

// Что показать в меню значка в трее. Подписи и состояние приходят из Dart (lib/core/tray.dart).
struct TrayMenuModel {
  std::wstring title = L"SkipIt";
  // «Подключено», «Не подключено»…
  std::wstring status;
  // Название выбранного сервера.
  std::wstring server;
  std::wstring label_open = L"Open";
  std::wstring label_toggle = L"Connect";
  std::wstring label_exit = L"Exit";
  std::wstring label_mode = L"Mode";
  std::wstring label_servers = L"Server";
  std::wstring label_core = L"TUN core";
  // 0 — не подключено, 1 — идёт подключение или отключение, 2 — подключено.
  int state = 0;
  // Тёмная или светлая тема программы.
  bool dark = true;
  // Режимы подключения (подписи) и номер выбранного.
  std::vector<std::wstring> modes;
  int mode = -1;
  // Ядра TUN (подписи) и номер выбранного; пусто — режим без TUN, переключатель не показывается.
  std::vector<std::wstring> cores;
  int core = -1;
  // Kill Switch: −1 — пункта нет (режим без TUN), 0 — выключен, 1 — включён.
  std::wstring label_kill_switch = L"Kill Switch";
  int kill_switch = -1;
  // Серверы и номер выбранного.
  std::vector<TrayMenuServer> servers;
  int selected_server = -1;
};

// Команды, которые меню отправляет владельцу. Режим, ядро TUN и сервер — это база плюс номер пункта.
struct TrayMenuCommands {
  UINT toggle;
  UINT open;
  UINT exit;
  UINT kill_switch;
  UINT mode_base;
  UINT core_base;
  UINT server_base;
};

// Показывает меню в стиле программы у точки |pt| (обычно — у курсора над значком в трее).
// Выбранный пункт приходит окну |owner| сообщением |message|, команда — в wParam.
// Меню закрывается само при клике мимо и по Esc.
void ShowTrayMenu(HWND owner, UINT message, POINT pt, const TrayMenuModel& model,
                  const TrayMenuCommands& commands);

#endif  // RUNNER_TRAY_MENU_H_

#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <shellapi.h>

#include <memory>
#include <string>

#include "tray_menu.h"
#include "win32_window.h"

// Окно с Flutter-интерфейсом и значком в системном трее.
// Трей управляется из Dart через канал "skipit/tray" (lib/core/tray.dart).
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Положение и размер окна между запусками (реестр HKCU\Software\SkipIt).
  void RestorePlacement();
  void SavePlacement();

  void AddTrayIcon();
  void RemoveTrayIcon();
  // Уведомление Windows у значка в трее.
  void ShowNotification(const std::wstring& title, const std::wstring& text);
  void ShowFromTray();
  void ShowTrayMenu();
  void HandleTrayCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  // Kill Switch: команды из Dart (lib/core/kill_switch.dart), сами фильтры — в kill_switch.cpp.
  void HandleKillSwitchCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> kill_switch_channel_;
  NOTIFYICONDATAW tray_icon_{};
  bool tray_added_ = false;
  // Крестик прячет окно в трей вместо выхода (настройка приходит из Dart).
  bool close_to_tray_ = true;
  // Текст уведомления «программа осталась в трее» (из Dart; пустой — уведомления выключены)
  // и отметка, что в этом запуске его уже показывали.
  std::wstring close_hint_;
  bool close_hint_shown_ = false;
  // В прошлый раз окно было развёрнуто на весь экран.
  bool start_maximized_ = false;
  // Идёт перетаскивание/изменение размера — сохраняем только в конце.
  bool in_size_move_ = false;
  // Содержимое меню значка (подписи, статус, тема) приходит из Dart; до этого — запасные английские подписи.
  TrayMenuModel tray_menu_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_

#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <shellapi.h>

#include <memory>
#include <utility>
#include <vector>
#include <string>

#include "notify_popup.h"
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
  // Уведомление: своё окно над треем, а во время игры во весь экран — обычное уведомление Windows.
  void ShowNotification(const std::wstring& title, const std::wstring& text, NotifyKind kind = NotifyKind::kInfo);
  void ShowFromTray();
  // Значок, выбранный в настройках SkipIt: картинки RGBA нескольких размеров (сторона → пиксели).
  // Пустой список — обычный значок из ресурсов exe.
  void SetCustomIcon(const std::vector<std::pair<int, std::vector<uint8_t>>>& images);
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
  // Свой значок (окно, трей, уведомления; кнопку на панели задач Windows 11 берёт из exe); nullptr — из ресурсов exe. Удаляются при смене.
  HICON icon_small_ = nullptr;
  HICON icon_big_ = nullptr;
  // Картинки своего значка: по ним он рисуется заново при смене масштаба монитора.
  std::vector<std::pair<int, std::vector<uint8_t>>> icon_images_;
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
  // Масштаб интерфейса из настроек SkipIt (0,8–1): во столько же раз меньше и наименьший размер окна.
  double ui_scale_ = 1.0;
  // Содержимое меню значка (подписи, статус, тема) приходит из Dart; до этого — запасные английские подписи.
  TrayMenuModel tray_menu_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_

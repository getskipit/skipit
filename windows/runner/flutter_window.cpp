#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "kill_switch.h"
#include "resource.h"
#include "utils.h"

namespace {

constexpr UINT kTrayMessage = WM_APP + 1;
// Отложенное закрытие по команде "quit" из Dart (после того как Dart всё остановил).
constexpr UINT kQuitMessage = WM_APP + 2;
// Выбран пункт меню значка в трее (wParam — команда).
constexpr UINT kTrayMenuCommand = WM_APP + 3;
constexpr UINT kCmdOpen = 1;
constexpr UINT kCmdToggle = 2;
constexpr UINT kCmdExit = 3;
// Выбор режима и сервера в меню значка: база плюс номер пункта.
constexpr UINT kCmdModeBase = 100;
constexpr UINT kCmdCoreBase = 200;
constexpr UINT kCmdServerBase = 1000;
constexpr wchar_t kRegPlacement[] = L"WindowPlacement";
// Наименьший размер окна при масштабе 100 %: с развёрнутым боковым меню помещается самая широкая
// страница — «Логи» с двумя панелями. Проверяется тестом test/min_window_test.dart (числа там те же).
constexpr int kMinWidth = 960;
constexpr int kMinHeight = 600;

// Положение окна тестовой сборки хранится отдельно от установленной программы.
const wchar_t* RegKey() {
  return IsDevBuild() ? L"Software\\SkipIt Dev" : L"Software\\SkipIt";
}

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
  return w;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // До создания Flutter-вида: размер поверхности должен совпасть с восстановленным окном.
  RestorePlacement();

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  tray_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "skipit/tray",
      &flutter::StandardMethodCodec::GetInstance());
  tray_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        HandleTrayCall(call, std::move(result));
      });
  AddTrayIcon();

  kill_switch_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "skipit/killswitch",
      &flutter::StandardMethodCodec::GetInstance());
  kill_switch_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        HandleKillSwitchCall(call, std::move(result));
      });

  // При автозапуске с Windows окно не показываем — программа сразу живёт в трее.
  const bool start_hidden = wcsstr(GetCommandLineW(), L"--autostart") != nullptr;
  flutter_controller_->engine()->SetNextFrameCallback([this, start_hidden]() {
    if (start_hidden) return;
    if (start_maximized_) {
      ShowWindow(GetHandle(), SW_SHOWMAXIMIZED);
    } else {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  tray_channel_ = nullptr;
  kill_switch_channel_ = nullptr;
  KillSwitchRelease();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::RestorePlacement() {
  WINDOWPLACEMENT wp{};
  DWORD size = sizeof(wp);
  if (RegGetValueW(HKEY_CURRENT_USER, RegKey(), kRegPlacement, RRF_RT_REG_BINARY, nullptr, &wp, &size) !=
          ERROR_SUCCESS ||
      size != sizeof(wp)) {
    return;
  }
  // Монитор, на котором было окно, могли отключить — тогда остаёмся на месте по умолчанию.
  if (MonitorFromRect(&wp.rcNormalPosition, MONITOR_DEFAULTTONULL) == nullptr) return;
  if (wp.rcNormalPosition.right - wp.rcNormalPosition.left < 400 ||
      wp.rcNormalPosition.bottom - wp.rcNormalPosition.top < 300) {
    return;
  }
  start_maximized_ = wp.showCmd == SW_SHOWMAXIMIZED;
  wp.length = sizeof(wp);
  wp.showCmd = SW_HIDE;  // Показывает окно Flutter после первого кадра.
  wp.flags = 0;
  SetWindowPlacement(GetHandle(), &wp);
}

void FlutterWindow::SavePlacement() {
  HWND hwnd = GetHandle();
  if (!hwnd || !IsWindowVisible(hwnd)) return;
  WINDOWPLACEMENT wp{};
  wp.length = sizeof(wp);
  if (!GetWindowPlacement(hwnd, &wp)) return;
  // Свёрнутое окно запоминаем обычным: открываться свёрнутым оно не должно.
  if (wp.showCmd == SW_SHOWMINIMIZED) wp.showCmd = SW_SHOWNORMAL;
  HKEY key;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, RegKey(), 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) ==
      ERROR_SUCCESS) {
    RegSetValueExW(key, kRegPlacement, 0, REG_BINARY, reinterpret_cast<const BYTE*>(&wp), sizeof(wp));
    RegCloseKey(key);
  }
}

void FlutterWindow::AddTrayIcon() {
  tray_icon_.cbSize = sizeof(tray_icon_);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = 1;
  tray_icon_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_icon_.uCallbackMessage = kTrayMessage;
  tray_icon_.hIcon = static_cast<HICON>(LoadImageW(
      GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR));
  if (tray_icon_.szTip[0] == L'\0') wcscpy_s(tray_icon_.szTip, IsDevBuild() ? L"SkipIt Dev" : L"SkipIt");
  tray_added_ = Shell_NotifyIconW(NIM_ADD, &tray_icon_) != FALSE;
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_added_) return;
  Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
  tray_added_ = false;
}

void FlutterWindow::ShowFromTray() {
  HWND hwnd = GetHandle();
  ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(hwnd);
}

void FlutterWindow::ShowTrayMenu() {
  // Своё меню в стиле программы (tray_menu.cpp); выбранный пункт придёт сообщением kTrayMenuCommand.
  POINT pt;
  GetCursorPos(&pt);
  if (tray_menu_.status.empty()) tray_menu_.title = IsDevBuild() ? L"SkipIt Dev" : L"SkipIt";
  ::ShowTrayMenu(GetHandle(), kTrayMenuCommand, pt, tray_menu_,
                 TrayMenuCommands{kCmdToggle, kCmdOpen, kCmdExit, kCmdModeBase, kCmdCoreBase, kCmdServerBase});
}

void FlutterWindow::HandleKillSwitchCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "engage") {
    std::vector<std::wstring> apps;
    std::wstring v4, v6;
    if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
      auto text = [args](const char* key) {
        auto it = args->find(flutter::EncodableValue(key));
        const auto* s = it == args->end() ? nullptr : std::get_if<std::string>(&it->second);
        return s ? Utf8ToWide(*s) : std::wstring();
      };
      v4 = text("v4");
      v6 = text("v6");
      auto it = args->find(flutter::EncodableValue("apps"));
      if (it != args->end()) {
        if (const auto* list = std::get_if<flutter::EncodableList>(&it->second)) {
          for (const auto& value : *list) {
            if (const auto* s = std::get_if<std::string>(&value)) apps.push_back(Utf8ToWide(*s));
          }
        }
      }
    }
    const std::wstring error = KillSwitchEngage(apps, v4, v6);
    if (error.empty()) {
      result->Success();
    } else {
      const int n = WideCharToMultiByte(CP_UTF8, 0, error.data(), static_cast<int>(error.size()), nullptr, 0,
                                        nullptr, nullptr);
      std::string message(n, '\0');
      WideCharToMultiByte(CP_UTF8, 0, error.data(), static_cast<int>(error.size()), message.data(), n, nullptr,
                          nullptr);
      result->Error("wfp", message);
    }
  } else if (method == "release" || method == "status") {
    // Ответ — для журнала: стояли ли фильтры, что ответила Windows и сколько их осталось.
    const bool engaged = KillSwitchEngaged();
    const unsigned long code = method == "release" ? KillSwitchRelease() : 0;
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("engaged"), flutter::EncodableValue(engaged)},
        {flutter::EncodableValue("code"), flutter::EncodableValue(static_cast<int64_t>(code))},
        {flutter::EncodableValue("left"), flutter::EncodableValue(KillSwitchCountFilters())},
    }));
  } else {
    result->NotImplemented();
  }
}

void FlutterWindow::HandleTrayCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "update") {
    if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
      auto text = [args](const char* key) -> std::optional<std::wstring> {
        auto it = args->find(flutter::EncodableValue(key));
        if (it == args->end()) return std::nullopt;
        if (const auto* s = std::get_if<std::string>(&it->second)) return Utf8ToWide(*s);
        return std::nullopt;
      };
      if (auto tip = text("tooltip")) {
        wcsncpy_s(tray_icon_.szTip, tip->c_str(), _TRUNCATE);
        if (tray_added_) {
          tray_icon_.uFlags = NIF_TIP;
          Shell_NotifyIconW(NIM_MODIFY, &tray_icon_);
          tray_icon_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
        }
      }
      if (auto v = text("open")) tray_menu_.label_open = *v;
      if (auto v = text("toggle")) tray_menu_.label_toggle = *v;
      if (auto v = text("exit")) tray_menu_.label_exit = *v;
      if (auto v = text("title")) tray_menu_.title = *v;
      if (auto v = text("status")) tray_menu_.status = *v;
      if (auto v = text("server")) tray_menu_.server = *v;
      auto state = args->find(flutter::EncodableValue("state"));
      if (state != args->end()) {
        if (const auto* n = std::get_if<int32_t>(&state->second)) tray_menu_.state = *n;
      }
      auto dark = args->find(flutter::EncodableValue("dark"));
      if (dark != args->end()) {
        if (const auto* b = std::get_if<bool>(&dark->second)) tray_menu_.dark = *b;
      }
      if (auto v = text("modeLabel")) tray_menu_.label_mode = *v;
      if (auto v = text("serversLabel")) tray_menu_.label_servers = *v;
      if (auto v = text("coreLabel")) tray_menu_.label_core = *v;
      auto number = [args](const char* key, int fallback) {
        auto it = args->find(flutter::EncodableValue(key));
        if (it == args->end()) return fallback;
        const auto* n = std::get_if<int32_t>(&it->second);
        return n ? static_cast<int>(*n) : fallback;
      };
      tray_menu_.mode = number("mode", tray_menu_.mode);
      tray_menu_.selected_server = number("selectedServer", tray_menu_.selected_server);
      tray_menu_.core = number("core", tray_menu_.core);
      auto strings = [args](const char* key, std::vector<std::wstring>& out) {
        auto it = args->find(flutter::EncodableValue(key));
        if (it == args->end()) return;
        if (const auto* list = std::get_if<flutter::EncodableList>(&it->second)) {
          out.clear();
          for (const auto& value : *list) {
            if (const auto* s = std::get_if<std::string>(&value)) out.push_back(Utf8ToWide(*s));
          }
        }
      };
      strings("modes", tray_menu_.modes);
      strings("cores", tray_menu_.cores);
      auto servers = args->find(flutter::EncodableValue("servers"));
      if (servers != args->end()) {
        if (const auto* list = std::get_if<flutter::EncodableList>(&servers->second)) {
          tray_menu_.servers.clear();
          for (const auto& value : *list) {
            const auto* entry = std::get_if<flutter::EncodableMap>(&value);
            if (!entry) continue;
            auto field = [entry](const char* key) {
              auto it = entry->find(flutter::EncodableValue(key));
              const auto* s = it == entry->end() ? nullptr : std::get_if<std::string>(&it->second);
              return s ? Utf8ToWide(*s) : std::wstring();
            };
            tray_menu_.servers.push_back(TrayMenuServer{field("name"), field("flag"), field("group")});
          }
        }
      }
      auto it = args->find(flutter::EncodableValue("closeToTray"));
      if (it != args->end()) {
        if (const auto* b = std::get_if<bool>(&it->second)) close_to_tray_ = *b;
      }
    }
    result->Success();
  } else if (method == "notify") {
    // Уведомление Windows у значка. Только когда окно спрятано или свёрнуто: иначе всё видно в нём самом.
    HWND hwnd = GetHandle();
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args && tray_added_ && (!IsWindowVisible(hwnd) || IsIconic(hwnd))) {
      auto text = [args](const char* key) {
        auto it = args->find(flutter::EncodableValue(key));
        const auto* s = it == args->end() ? nullptr : std::get_if<std::string>(&it->second);
        return s ? Utf8ToWide(*s) : std::wstring();
      };
      auto warning = args->find(flutter::EncodableValue("warning"));
      const auto* is_warning = warning == args->end() ? nullptr : std::get_if<bool>(&warning->second);
      NOTIFYICONDATAW data = tray_icon_;
      data.uFlags = NIF_INFO;
      wcsncpy_s(data.szInfoTitle, text("title").c_str(), _TRUNCATE);
      wcsncpy_s(data.szInfo, text("text").c_str(), _TRUNCATE);
      data.dwInfoFlags = is_warning && *is_warning ? NIIF_WARNING : NIIF_INFO;
      Shell_NotifyIconW(NIM_MODIFY, &data);
    }
    result->Success();
  } else if (method == "show") {
    ShowFromTray();
    result->Success();
  } else if (method == "hide") {
    ShowWindow(GetHandle(), SW_HIDE);
    result->Success();
  } else if (method == "quit") {
    // Значок убираем сразу — Dart может вызвать exit() сразу после ответа.
    RemoveTrayIcon();
    result->Success();
    PostMessage(GetHandle(), kQuitMessage, 0, 0);
  } else {
    result->NotImplemented();
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // После перезапуска Проводника значки трея пропадают — добавляем заново.
  static const UINT taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  if (message == taskbar_created) {
    tray_added_ = false;
    AddTrayIcon();
    return 0;
  }

  switch (message) {
    case WM_GETMINMAXINFO: {
      // Меньше этого окно не сжимается: иначе интерфейс разваливается (подписи в столбик, пустая полоска).
      // Размер задан для масштаба 100 % и умножается на масштаб монитора.
      const double scale = GetDpiForWindow(hwnd) / 96.0;
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = static_cast<LONG>(kMinWidth * scale);
      info->ptMinTrackSize.y = static_cast<LONG>(kMinHeight * scale);
      return 0;
    }
    case WM_ENTERSIZEMOVE:
      in_size_move_ = true;
      break;
    case WM_EXITSIZEMOVE:
      in_size_move_ = false;
      SavePlacement();
      break;
    case WM_SIZE:
      // Развернули/восстановили кнопкой — перетаскивания не было, сохраняем сразу.
      if (!in_size_move_ && (wparam == SIZE_MAXIMIZED || wparam == SIZE_RESTORED)) SavePlacement();
      break;
    case WM_CLOSE:
      SavePlacement();
      // Крестик прячет окно в трей; VPN продолжает работать.
      if (close_to_tray_ && tray_added_) {
        ShowWindow(hwnd, SW_HIDE);
        return 0;
      }
      break;
    case kTrayMessage:
      switch (LOWORD(lparam)) {
        case WM_LBUTTONUP:
        case WM_LBUTTONDBLCLK:
        // Клик по уведомлению открывает окно.
        case NIN_BALLOONUSERCLICK:
          ShowFromTray();
          break;
        case WM_RBUTTONUP:
        case WM_CONTEXTMENU:
          ShowTrayMenu();
          break;
      }
      return 0;
    case kTrayMenuCommand:
      switch (wparam) {
        case kCmdOpen:
          ShowFromTray();
          break;
        case kCmdToggle:
          if (tray_channel_) tray_channel_->InvokeMethod("toggle", nullptr);
          break;
        case kCmdExit:
          if (tray_channel_) tray_channel_->InvokeMethod("exit", nullptr);
          break;
        default:
          // Выбран режим, ядро TUN или сервер — номер пункта уходит в Dart.
          if (!tray_channel_) break;
          if (wparam >= kCmdServerBase) {
            tray_channel_->InvokeMethod(
                "server", std::make_unique<flutter::EncodableValue>(static_cast<int32_t>(wparam - kCmdServerBase)));
          } else if (wparam >= kCmdCoreBase) {
            tray_channel_->InvokeMethod(
                "core", std::make_unique<flutter::EncodableValue>(static_cast<int32_t>(wparam - kCmdCoreBase)));
          } else if (wparam >= kCmdModeBase) {
            tray_channel_->InvokeMethod(
                "mode", std::make_unique<flutter::EncodableValue>(static_cast<int32_t>(wparam - kCmdModeBase)));
          }
          break;
      }
      return 0;
    case kQuitMessage:
      SavePlacement();
      DestroyWindow(hwnd);
      return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

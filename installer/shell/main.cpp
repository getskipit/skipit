#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <gdiplus.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <sddl.h>
#include <bcrypt.h>
#include <richedit.h>
#include <uxtheme.h>

#include <initializer_list>
#include <algorithm>
#include <cmath>
#include <string>
#include <thread>

namespace {
// The dark notification palette (notify_popup.cpp, PaletteFor).
constexpr COLORREF kBg = RGB(0x1B, 0x1B, 0x1E), kPanel = RGB(0x14, 0x14, 0x17);
constexpr COLORREF kText = RGB(0xF7, 0xF7, 0xF8), kMuted = RGB(0xA8, 0xA8, 0xB0);
constexpr COLORREF kAccent = RGB(255, 95, 26), kBorder = RGB(0x29, 0x29, 0x2E);
constexpr COLORREF kHover = RGB(0x2E, 0x2E, 0x34), kGreen = RGB(0x4A, 0xDE, 0x80), kRed = RGB(0xFF, 0x4D, 0x4D);
constexpr UINT kFinished = WM_APP + 1;
enum { kEn = 201, kRu, kNext, kBack, kCancel, kAgree, kPath, kBrowse, kDesktop, kLaunch, kClose };
HWND window, heading, description, licenseBox, licenseViewport, licenseContent, agree, pathLabel, pathFrame, pathEdit;
HWND browse, desktop, launch, status, progress, next, back, cancel, en, ru, closeButton, pathWarning;
HFONT font, titleFont, brandFont;
HBRUSH bgBrush, panelBrush;
IStream* markStream = nullptr;
Gdiplus::Bitmap* mark = nullptr;
bool russian, busy = false, success = false;
bool nativeCorners = false, pathInvalid = false;
int page = 0;
UINT dpi = 96;
std::wstring installDirectory;
DWORD failureCode = 0;
int licenseHeight = 0;
double scrollOffset = 0, scrollTarget = 0;
ULONGLONG scrollTick = 0;
bool scrollAnimating = false, scrollDragging = false;
int scrollGrab = 0;

int S(int n) { return MulDiv(n, static_cast<int>(dpi), 96); }
const wchar_t* T(const wchar_t* r, const wchar_t* e) { return russian ? r : e; }
void Text(HWND control, const wchar_t* text) { SetWindowTextW(control, text); }
void Show(HWND control, bool visible) { ShowWindow(control, visible ? SW_SHOW : SW_HIDE); }
bool Checked(HWND control) { return SendMessageW(control, BM_GETCHECK, 0, 0) == BST_CHECKED; }

Gdiplus::Color Color(COLORREF value) {
  return Gdiplus::Color(255, GetRValue(value), GetGValue(value), GetBValue(value));
}

void Rounded(Gdiplus::Graphics& g, const Gdiplus::RectF& rect, float radius, COLORREF fill, COLORREF border) {
  const float d = radius * 2;
  Gdiplus::GraphicsPath shape;
  shape.AddArc(rect.X, rect.Y, d, d, 180.0f, 90.0f);
  shape.AddArc(rect.GetRight() - d, rect.Y, d, d, 270.0f, 90.0f);
  shape.AddArc(rect.GetRight() - d, rect.GetBottom() - d, d, d, 0.0f, 90.0f);
  shape.AddArc(rect.X, rect.GetBottom() - d, d, d, 90.0f, 90.0f);
  shape.CloseFigure();
  Gdiplus::SolidBrush brush(Color(fill)); g.FillPath(&brush, &shape);
  Gdiplus::Pen pen(Color(border)); g.DrawPath(&pen, &shape);
}

void ToggleCheckbox(HWND hwnd) {
  if (!IsWindowEnabled(hwnd)) return;
  SendMessageW(hwnd, BM_SETCHECK, Checked(hwnd) ? BST_UNCHECKED : BST_CHECKED, 0);
  SendMessageW(GetParent(hwnd), WM_COMMAND, MAKEWPARAM(GetDlgCtrlID(hwnd), BN_CLICKED), reinterpret_cast<LPARAM>(hwnd));
  InvalidateRect(hwnd, nullptr, FALSE);
}

void ExcludeChildren(HWND hwnd, HDC dc) {
  for (HWND child = GetWindow(hwnd, GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT)) {
    if (!(GetWindowLongPtrW(child, GWL_STYLE) & WS_VISIBLE)) continue;
    RECT bounds; GetWindowRect(child, &bounds);
    MapWindowPoints(nullptr, hwnd, reinterpret_cast<POINT*>(&bounds), 2);
    HRGN region = CreateRectRgn(0, 0, 0, 0);
    if (GetWindowRgn(child, region) != ERROR) {
      OffsetRgn(region, bounds.left, bounds.top);
      ExtSelectClipRgn(dc, region, RGN_DIFF);
    } else {
      ExcludeClipRect(dc, bounds.left, bounds.top, bounds.right, bounds.bottom);
    }
    DeleteObject(region);
  }
}

void ExcludeChildren(HWND hwnd, Gdiplus::Graphics& graphics) {
  for (HWND child = GetWindow(hwnd, GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT)) {
    if (!(GetWindowLongPtrW(child, GWL_STYLE) & WS_VISIBLE)) continue;
    RECT bounds; GetWindowRect(child, &bounds);
    MapWindowPoints(nullptr, hwnd, reinterpret_cast<POINT*>(&bounds), 2);
    HRGN region = CreateRectRgn(0, 0, 0, 0);
    if (GetWindowRgn(child, region) != ERROR) {
      OffsetRgn(region, bounds.left, bounds.top);
      Gdiplus::Region clip(region); graphics.ExcludeClip(&clip);
    } else {
      graphics.ExcludeClip(Gdiplus::Rect(bounds.left, bounds.top, bounds.right - bounds.left, bounds.bottom - bounds.top));
    }
    DeleteObject(region);
  }
}

// Retain the native checkbox state, mouse/keyboard behavior and accessibility;
// replace only its painting.
LRESULT CALLBACK CheckboxProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp, UINT_PTR, DWORD_PTR) {
  if (message == WM_ERASEBKGND) return 1;
  if (message == BM_CLICK) { ToggleCheckbox(hwnd); return 0; }
  if (message == WM_LBUTTONDOWN || message == WM_LBUTTONDBLCLK) {
    if (IsWindowEnabled(hwnd)) { SetFocus(hwnd); SetCapture(hwnd); SetPropW(hwnd, L"SkipItPressed", reinterpret_cast<HANDLE>(1)); }
    return 0;
  }
  if (message == WM_LBUTTONUP) {
    const bool pressed = GetPropW(hwnd, L"SkipItPressed") != nullptr;
    RemovePropW(hwnd, L"SkipItPressed");
    if (GetCapture() == hwnd) ReleaseCapture();
    RECT bounds; GetClientRect(hwnd, &bounds);
    POINT point{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
    if (pressed && PtInRect(&bounds, point)) ToggleCheckbox(hwnd);
    return 0;
  }
  if (message == WM_CAPTURECHANGED) RemovePropW(hwnd, L"SkipItPressed");
  if (message == WM_KEYDOWN && wp == VK_SPACE) {
    SetPropW(hwnd, L"SkipItKeyPressed", reinterpret_cast<HANDLE>(1)); return 0;
  }
  if (message == WM_KEYUP && wp == VK_SPACE) {
    const bool pressed = GetPropW(hwnd, L"SkipItKeyPressed") != nullptr;
    RemovePropW(hwnd, L"SkipItKeyPressed");
    if (pressed) ToggleCheckbox(hwnd);
    return 0;
  }
  if (message == WM_KILLFOCUS) RemovePropW(hwnd, L"SkipItKeyPressed");
  if (message == WM_PAINT || message == WM_PRINTCLIENT) {
    PAINTSTRUCT ps{};
    HDC output = message == WM_PAINT ? BeginPaint(hwnd, &ps) : reinterpret_cast<HDC>(wp);
    RECT rect; GetClientRect(hwnd, &rect);
    HDC dc = CreateCompatibleDC(output);
    HBITMAP bitmap = CreateCompatibleBitmap(output, rect.right, rect.bottom);
    HGDIOBJ oldBitmap = SelectObject(dc, bitmap);
    FillRect(dc, &rect, bgBrush);
    {
      Gdiplus::Graphics g(dc); g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
      const bool checked = Checked(hwnd);
      const int top = (rect.bottom - S(18)) / 2;
      Rounded(g, Gdiplus::RectF(static_cast<float>(S(1)), static_cast<float>(top), static_cast<float>(S(18)), static_cast<float>(S(18))),
          static_cast<float>(S(4)), checked ? kAccent : kPanel, checked || GetFocus() == hwnd ? kAccent : RGB(105, 105, 115));
      if (checked) {
        Gdiplus::Pen pen(Color(kText), static_cast<float>(S(2)));
        pen.SetStartCap(Gdiplus::LineCapRound); pen.SetEndCap(Gdiplus::LineCapRound); pen.SetLineJoin(Gdiplus::LineJoinRound);
        Gdiplus::Point points[] = {{S(5), top + S(9)}, {S(8), top + S(12)}, {S(15), top + S(5)}};
        g.DrawLines(&pen, points, 3);
      }
    }
    SelectObject(dc, font); SetBkMode(dc, TRANSPARENT); SetTextColor(dc, IsWindowEnabled(hwnd) ? kText : kMuted);
    rect.left = S(30);
    const int length = GetWindowTextLengthW(hwnd);
    std::wstring caption(static_cast<size_t>(length) + 1, L'\0'); GetWindowTextW(hwnd, caption.data(), length + 1);
    DrawTextW(dc, caption.c_str(), -1, &rect, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    BitBlt(output, 0, 0, rect.right, rect.bottom, dc, 0, 0, SRCCOPY);
    SelectObject(dc, oldBitmap); DeleteObject(bitmap); DeleteDC(dc);
    if (message == WM_PAINT) EndPaint(hwnd, &ps);
    return 0;
  }
  if (message == BM_SETCHECK || message == WM_SETTEXT || message == WM_SETFOCUS ||
      message == WM_KILLFOCUS || message == WM_ENABLE) {
    // The native button may paint directly while changing state or focus.
    // Suppress that intermediate paint and immediately draw our checkbox.
    const bool visible = (GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_VISIBLE) != 0;
    if (visible) DefSubclassProc(hwnd, WM_SETREDRAW, FALSE, 0);
    const LRESULT result = DefSubclassProc(hwnd, message, wp, lp);
    if (visible) DefSubclassProc(hwnd, WM_SETREDRAW, TRUE, 0);
    RedrawWindow(hwnd, nullptr, nullptr, RDW_INVALIDATE | RDW_NOERASE | RDW_UPDATENOW);
    return result;
  }
  return DefSubclassProc(hwnd, message, wp, lp);
}

int LicenseViewHeight() { RECT rect; GetClientRect(licenseViewport, &rect); return rect.bottom; }
int MaxScroll() { return std::max(0, licenseHeight + S(20) - LicenseViewHeight()); }

void MoveLicense(double position) {
  scrollOffset = std::clamp(position, 0.0, static_cast<double>(MaxScroll()));
  SetWindowPos(licenseBox, nullptr, S(13), S(8) - static_cast<int>(std::lround(scrollOffset)), 0, 0,
      SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOCOPYBITS);
  // Repaint the text and its container together, without copying stale window pixels.
  RedrawWindow(licenseViewport, nullptr, nullptr, RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_UPDATENOW);
}

void ScrollLicense(double target, bool animate = true) {
  scrollTarget = std::clamp(target, 0.0, static_cast<double>(MaxScroll()));
  BOOL animations = TRUE;
  SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &animations, 0);
  if (!animate || !animations) {
    scrollAnimating = false; KillTimer(licenseViewport, 1); MoveLicense(scrollTarget); return;
  }
  // Repeated wheel events update the target, but must not postpone the next frame.
  if (!scrollAnimating) {
    scrollTick = GetTickCount64(); scrollAnimating = true;
    SetTimer(licenseViewport, 1, 15, nullptr);
  }
}

void WheelLicense(WPARAM wp) {
  UINT lines = 3; SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
  const double step = lines == WHEEL_PAGESCROLL ? LicenseViewHeight() * 0.9 : S(18) * static_cast<double>(lines);
  ScrollLicense((scrollAnimating ? scrollTarget : scrollOffset) - static_cast<short>(HIWORD(wp)) * step / WHEEL_DELTA);
}

RECT ScrollThumb() {
  RECT view; GetClientRect(licenseViewport, &view);
  const int track = view.bottom - S(16);
  const int height = static_cast<int>(view.bottom);
  const int size = std::min(track, std::max(S(26), track * height / std::max(height, licenseHeight + S(20))));
  const int top = S(8) + (MaxScroll() ? static_cast<int>(std::lround(scrollOffset * (track - size) / MaxScroll())) : 0);
  return RECT{view.right - S(12), top, view.right - S(6), top + size};
}

LRESULT CALLBACK LicenseProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp, UINT_PTR, DWORD_PTR) {
  if (message == WM_MOUSEWHEEL) { WheelLicense(wp); return 0; }
  if (message == WM_KEYDOWN && !(GetKeyState(VK_SHIFT) & 0x8000)) {
    switch (wp) {
      case VK_HOME: ScrollLicense(0); return 0;
      case VK_END: ScrollLicense(MaxScroll()); return 0;
      case VK_PRIOR: ScrollLicense(scrollTarget - LicenseViewHeight() * 0.9); return 0;
      case VK_NEXT: ScrollLicense(scrollTarget + LicenseViewHeight() * 0.9); return 0;
      case VK_UP: ScrollLicense(scrollTarget - S(18)); return 0;
      case VK_DOWN: ScrollLicense(scrollTarget + S(18)); return 0;
    }
  }
  return DefSubclassProc(hwnd, message, wp, lp);
}

void PaintLicenseViewport(HWND hwnd, HDC dc) {
  const int saved = SaveDC(dc);
  ExcludeChildren(hwnd, dc);
  RECT view; GetClientRect(hwnd, &view); FillRect(dc, &view, bgBrush);
  {
  Gdiplus::Graphics g(dc); g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  ExcludeChildren(hwnd, g);
  Rounded(g, Gdiplus::RectF(0.5f, 0.5f, static_cast<float>(view.right - 1), static_cast<float>(view.bottom - 1)),
      static_cast<float>(S(10)), kPanel, kBorder);
  if (MaxScroll() > 0) {
    const RECT thumb = ScrollThumb();
    Rounded(g, Gdiplus::RectF(static_cast<float>(thumb.left), static_cast<float>(thumb.top),
        static_cast<float>(thumb.right - thumb.left), static_cast<float>(thumb.bottom - thumb.top)),
        static_cast<float>(S(3)), RGB(100, 100, 110), RGB(100, 100, 110));
  }
  }
  RestoreDC(dc, saved);
}

// The scrolling text is clipped inside a fixed inset, so it cannot paint over
// the viewport's stationary upper and lower borders.
LRESULT CALLBACK LicenseContentProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp, UINT_PTR, DWORD_PTR) {
  if (message == WM_NOTIFY) return SendMessageW(licenseViewport, message, wp, lp);
  if (message == WM_CTLCOLORSTATIC || message == WM_CTLCOLOREDIT) {
    SetTextColor(reinterpret_cast<HDC>(wp), kText); SetBkColor(reinterpret_cast<HDC>(wp), kPanel);
    return reinterpret_cast<LRESULT>(panelBrush);
  }
  if (message == WM_ERASEBKGND) {
    RECT rect; GetClientRect(hwnd, &rect); FillRect(reinterpret_cast<HDC>(wp), &rect, panelBrush); return 1;
  }
  return DefSubclassProc(hwnd, message, wp, lp);
}

LRESULT CALLBACK LicenseViewportProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) {
  switch (message) {
    case WM_NOTIFY: {
      const auto* notification = reinterpret_cast<NMHDR*>(lp);
      if (notification->hwndFrom == licenseBox && notification->code == EN_REQUESTRESIZE) {
        const auto* requested = reinterpret_cast<REQRESIZE*>(lp);
        const int height = requested->rc.bottom - requested->rc.top;
        if (height != licenseHeight && height > 0) {
          licenseHeight = height;
          SetWindowPos(licenseBox, nullptr, 0, 0, S(606), licenseHeight, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
          MoveLicense(scrollOffset);
        }
      }
      return 0;
    }
    case WM_MOUSEWHEEL: WheelLicense(wp); return 0;
    case WM_CTLCOLORSTATIC:
      SetTextColor(reinterpret_cast<HDC>(wp), kText);
      SetBkColor(reinterpret_cast<HDC>(wp), kPanel);
      return reinterpret_cast<LRESULT>(panelBrush);
    case WM_TIMER:
      if (wp == 1) {
        const ULONGLONG now = GetTickCount64();
        const double follow = 1 - std::exp(-static_cast<double>(now - scrollTick) / 65.0);
        scrollTick = now;
        const double position = scrollOffset + (scrollTarget - scrollOffset) * follow;
        const bool finished = std::abs(scrollTarget - position) < 0.25;
        MoveLicense(finished ? scrollTarget : position);
        if (finished) { KillTimer(hwnd, 1); scrollAnimating = false; }
      }
      return 0;
    case WM_LBUTTONDOWN: {
      RECT view; GetClientRect(hwnd, &view);
      if (GET_X_LPARAM(lp) >= view.right - S(22)) {
        const RECT thumb = ScrollThumb();
        const int y = GET_Y_LPARAM(lp);
        if (y >= thumb.top && y < thumb.bottom) {
          ScrollLicense(scrollOffset, false); scrollDragging = true; scrollGrab = y - thumb.top; SetCapture(hwnd);
        } else ScrollLicense(scrollOffset + (y < thumb.top ? -1 : 1) * LicenseViewHeight() * 0.9);
      } else SetFocus(licenseBox);
      return 0;
    }
    case WM_MOUSEMOVE:
      if (scrollDragging) {
        const RECT thumb = ScrollThumb();
        const int travel = LicenseViewHeight() - S(16) - (thumb.bottom - thumb.top);
        if (travel > 0) ScrollLicense(static_cast<double>(GET_Y_LPARAM(lp) - S(8) - scrollGrab) * MaxScroll() / travel, false);
      }
      return 0;
    case WM_LBUTTONUP: if (scrollDragging) { scrollDragging = false; ReleaseCapture(); } return 0;
    case WM_CAPTURECHANGED: scrollDragging = false; return 0;
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: {
      PAINTSTRUCT ps; HDC dc = BeginPaint(hwnd, &ps);
      PaintLicenseViewport(hwnd, dc);
      EndPaint(hwnd, &ps); return 0;
    }
    case WM_PRINTCLIENT: PaintLicenseViewport(hwnd, reinterpret_cast<HDC>(wp)); return 0;
  }
  return DefWindowProcW(hwnd, message, wp, lp);
}

// Keep a real single-line edit for typing/paste, centered inside the taller field.
LRESULT CALLBACK PathFrameProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp, UINT_PTR, DWORD_PTR) {
  if (message == WM_ERASEBKGND) return 1;
  if (message == WM_PAINT || message == WM_PRINTCLIENT) {
    PAINTSTRUCT ps{};
    HDC dc = message == WM_PAINT ? BeginPaint(hwnd, &ps) : reinterpret_cast<HDC>(wp);
    RECT rect; GetClientRect(hwnd, &rect);
    FillRect(dc, &rect, bgBrush);
    Gdiplus::Graphics g(dc); g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    Rounded(g, Gdiplus::RectF(0.5f, 0.5f, static_cast<float>(rect.right - 1), static_cast<float>(rect.bottom - 1)),
        static_cast<float>(S(7)), kPanel, GetFocus() == pathEdit ? kAccent : RGB(70, 70, 78));
    if (message == WM_PAINT) EndPaint(hwnd, &ps);
    return 0;
  }
  if (message == WM_CTLCOLOREDIT) {
    HDC dc = reinterpret_cast<HDC>(wp);
    SetTextColor(dc, kText); SetBkColor(dc, kPanel);
    return reinterpret_cast<LRESULT>(panelBrush);
  }
  if (message == WM_LBUTTONDOWN) { SetFocus(pathEdit); return 0; }
  return DefSubclassProc(hwnd, message, wp, lp);
}

LRESULT CALLBACK PathEditProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp, UINT_PTR, DWORD_PTR) {
  const LRESULT result = DefSubclassProc(hwnd, message, wp, lp);
  if (message == WM_SETFOCUS || message == WM_KILLFOCUS) InvalidateRect(pathFrame, nullptr, FALSE);
  return result;
}

LRESULT CALLBACK ButtonProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp, UINT_PTR, DWORD_PTR) {
  if (message == WM_MOUSEMOVE && !GetPropW(hwnd, L"SkipItHover")) {
    SetPropW(hwnd, L"SkipItHover", reinterpret_cast<HANDLE>(1));
    TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE, hwnd, 0}; TrackMouseEvent(&track);
    InvalidateRect(hwnd, nullptr, FALSE);
  } else if (message == WM_MOUSELEAVE) {
    RemovePropW(hwnd, L"SkipItHover"); InvalidateRect(hwnd, nullptr, FALSE);
  }
  return DefSubclassProc(hwnd, message, wp, lp);
}

// Quote one Windows command-line argument, including trailing backslashes.
std::wstring Quote(const std::wstring& value) {
  std::wstring result = L"\"";
  size_t slashes = 0;
  for (wchar_t c : value) {
    if (c == L'\\') { ++slashes; continue; }
    result.append(slashes * (c == L'"' ? 2 : 1), L'\\');
    if (c == L'"') result += L'\\';
    result += c;
    slashes = 0;
  }
  result.append(slashes * 2, L'\\');
  return result + L'"';
}

std::wstring ControlText(HWND control) {
  std::wstring value(static_cast<size_t>(GetWindowTextLengthW(control)) + 1, L'\0');
  value.resize(static_cast<size_t>(GetWindowTextW(control, value.data(), static_cast<int>(value.size()))));
  return value;
}

std::wstring ResourceText(int id) {
  HRSRC res = FindResourceW(nullptr, MAKEINTRESOURCEW(id), RT_RCDATA);
  const auto* bytes = static_cast<const char*>(LockResource(LoadResource(nullptr, res)));
  const int size = static_cast<int>(SizeofResource(nullptr, res));
  const int length = MultiByteToWideChar(CP_UTF8, 0, bytes, size, nullptr, 0);
  std::wstring result(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, bytes, size, result.data(), length);
  return result;
}

std::wstring DefaultDirectory() {
  wchar_t path[32768] = {};
  DWORD size = sizeof(path);
  if (RegGetValueW(HKEY_LOCAL_MACHINE,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{6E2D5B1A-7C3F-4B8E-9A41-5F0C2D8E3B17}_is1",
      L"InstallLocation", RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY, nullptr, path, &size) == ERROR_SUCCESS && path[0])
    return path;
  PWSTR programFiles = nullptr;
  std::wstring result = L"C:\\Program Files\\SkipIt";
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_ProgramFiles, 0, nullptr, &programFiles))) {
    result = std::wstring(programFiles) + L"\\SkipIt";
    CoTaskMemFree(programFiles);
  }
  return result;
}

#ifndef SKIPIT_PREVIEW
// Keep the elevated payload in a directory writable only by administrators/SYSTEM.
// It is removed after the inner installer has completely exited.
struct Payload {
  std::wstring directory, file;
  ~Payload() { if (!file.empty()) DeleteFileW(file.c_str()); if (!directory.empty()) RemoveDirectoryW(directory.c_str()); }
  bool Extract() {
    wchar_t windows[MAX_PATH] = {};
    if (!GetWindowsDirectoryW(windows, MAX_PATH)) return false;
    unsigned char random[16];
    if (BCryptGenRandom(nullptr, random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) return false;
    std::wstring suffix;
    for (auto byte : random) { suffix += L"0123456789abcdef"[byte >> 4]; suffix += L"0123456789abcdef"[byte & 15]; }
    PSECURITY_DESCRIPTOR security = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:P(A;;FA;;;SY)(A;;FA;;;BA)", SDDL_REVISION_1, &security, nullptr)) return false;
    SECURITY_ATTRIBUTES attributes{sizeof(attributes), security, FALSE};
    const std::wstring candidate = std::wstring(windows) + L"\\Temp\\SkipItSetup-" + suffix;
    const BOOL created = CreateDirectoryW(candidate.c_str(), &attributes);
    const DWORD error = GetLastError();
    LocalFree(security);
    if (!created) { SetLastError(error); return false; }
    directory = candidate;
    file = directory + L"\\setup.exe";
    HRSRC res = FindResourceW(nullptr, MAKEINTRESOURCEW(102), RT_RCDATA);
    if (!res) return false;
    const DWORD size = SizeofResource(nullptr, res);
    const void* bytes = LockResource(LoadResource(nullptr, res));
    HANDLE output = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (output == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    const bool ok = bytes && WriteFile(output, bytes, size, &written, nullptr) && written == size;
    const DWORD writeError = GetLastError();
    CloseHandle(output);
    if (!ok) SetLastError(writeError);
    return ok;
  }
};

DWORD RunPayload(const std::wstring& arguments, DWORD& error) {
  Payload payload;
  if (!payload.Extract()) { error = GetLastError(); return MAXDWORD; }
  std::wstring command = Quote(payload.file) + L" " + arguments;
  STARTUPINFOW startup{sizeof(startup)};
  PROCESS_INFORMATION child{};
  if (!CreateProcessW(payload.file.c_str(), command.data(), nullptr, nullptr, FALSE, 0, nullptr, payload.directory.c_str(), &startup, &child)) {
    error = GetLastError(); return MAXDWORD;
  }
  CloseHandle(child.hThread);
  WaitForSingleObject(child.hProcess, INFINITE);
  DWORD code = MAXDWORD;
  if (!GetExitCodeProcess(child.hProcess, &code)) error = GetLastError();
  CloseHandle(child.hProcess);
  return code;
}
#endif

void Update() {
  Text(window, T(L"Установка SkipIt", L"SkipIt Setup"));
  const wchar_t* titlesRu[] = {L"Лицензионное соглашение", L"Всё готово к установке", L"Устанавливаем SkipIt", L"SkipIt установлен", L"Не удалось установить SkipIt"};
  const wchar_t* titlesEn[] = {L"License agreement", L"Ready to install", L"Installing SkipIt", L"SkipIt is installed", L"Could not install SkipIt"};
  Text(heading, russian ? titlesRu[page] : titlesEn[page]);
  Text(description, page == 0 ? T(L"Прочтите условия лицензии перед продолжением.", L"Read the license terms before continuing.") :
      page == 1 ? T(L"Выберите папку и нужные параметры.", L"Choose the folder and installation options.") :
      page == 2 ? T(L"Пожалуйста, дождитесь завершения установки.", L"Please wait for the installation to finish.") :
      success ? T(L"Можно начинать пользоваться программой.", L"You can now start using the app.") :
      T(L"Проверьте сообщение ниже и повторите установку.", L"Check the message below and run Setup again."));
  Text(agree, T(L"Я принимаю условия лицензии", L"I accept the license terms"));
  Text(pathLabel, T(L"Папка установки", L"Installation folder"));
  Text(browse, T(L"Обзор…", L"Browse…"));
  Text(desktop, T(L"Создать ярлык на рабочем столе", L"Create a desktop shortcut"));
  Text(launch, T(L"Запустить SkipIt после закрытия", L"Launch SkipIt when Setup closes"));
  Text(next, page == 0 ? T(L"Далее", L"Next") : page == 1 ? T(L"Установить", L"Install") : T(L"Готово", L"Finish"));
  Text(back, T(L"Назад", L"Back"));
  Text(cancel, T(L"Отмена", L"Cancel"));
  Text(closeButton, T(L"Закрыть", L"Close"));
  Text(pathWarning, T(L"Укажите полный путь к папке на диске.", L"Enter a full folder path on a local drive."));
  Show(pathWarning, page == 1 && pathInvalid);
  Show(licenseViewport, page == 0); Show(agree, page == 0);
  for (HWND control : {pathLabel, pathFrame, browse, desktop}) Show(control, page == 1);
  Show(launch, page == 3);
  Show(progress, page == 2); Show(status, page >= 2);
  const std::wstring failure = T(L"Код ошибки: ", L"Error code: ") + std::to_wstring(failureCode);
  Text(status, page == 2 ? T(L"Копируем файлы и настраиваем службу…", L"Copying files and configuring the service…") :
      page == 3 ? T(L"Спасибо, что выбрали SkipIt.", L"Thank you for choosing SkipIt.") : failure.c_str());
  Show(back, page == 1); Show(cancel, page < 2); Show(next, page != 2);
  EnableWindow(next, page != 0 || Checked(agree));
  EnableWindow(closeButton, !busy);
#ifdef SKIPIT_PREVIEW
  if (page == 1) { EnableWindow(next, FALSE); Text(description, T(L"Предпросмотр: установка отключена.", L"Preview: installation is disabled.")); }
#endif
  InvalidateRect(window, nullptr, FALSE);
  InvalidateRect(en, nullptr, TRUE); InvalidateRect(ru, nullptr, TRUE);
}

HWND Control(const wchar_t* cls, const wchar_t* text, DWORD style, int id, int x, int y, int w, int h, HWND parent = nullptr) {
  HWND result = CreateWindowExW(0, cls, text, WS_CHILD | WS_VISIBLE | style, S(x), S(y), S(w), S(h), parent ? parent : window,
      reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
  SendMessageW(result, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
  if (wcscmp(cls, L"BUTTON") == 0 && (style & BS_TYPEMASK) == BS_OWNERDRAW)
    SetWindowSubclass(result, ButtonProc, 1, 0);
  return result;
}

void Browse() {
  IFileDialog* dialog = nullptr;
  if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)))) return;
  DWORD flags = 0;
  dialog->GetOptions(&flags);
  dialog->SetOptions(flags | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
  dialog->SetTitle(T(L"Папка установки SkipIt", L"SkipIt installation folder"));
  if (SUCCEEDED(dialog->Show(window))) {
    IShellItem* item = nullptr;
    if (SUCCEEDED(dialog->GetResult(&item))) {
      PWSTR value = nullptr;
      if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &value))) { Text(pathEdit, value); CoTaskMemFree(value); }
      item->Release();
    }
  }
  dialog->Release();
}

void Install() {
#ifndef SKIPIT_PREVIEW
  installDirectory = ControlText(pathEdit);
  if (installDirectory.size() < 3 || installDirectory[1] != L':' || installDirectory[2] != L'\\' || installDirectory.find(L'"') != std::wstring::npos) {
    pathInvalid = true; Update();
    return;
  }
  const std::wstring arguments = L"/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /LANG=" +
      std::wstring(russian ? L"russian" : L"english") + L" /DIR=" + Quote(installDirectory) +
      L" /TASKS=" + Quote(Checked(desktop) ? L"desktopicon" : L"");
  busy = true; page = 2; Update();
  SendMessageW(progress, PBM_SETMARQUEE, TRUE, 35);
  std::thread([arguments] {
    DWORD error = 0;
    const DWORD code = RunPayload(arguments, error);
    PostMessageW(window, kFinished, code, error);
  }).detach();
#endif
}

void DrawButton(const DRAWITEMSTRUCT* item) {
  Gdiplus::Graphics g(item->hDC);
  g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  const bool disabled = (item->itemState & ODS_DISABLED) != 0;
  const bool language = item->CtlID == kEn || item->CtlID == kRu;
  const bool selected = (item->CtlID == kRu && russian) || (item->CtlID == kEn && !russian);
  const bool hovered = !disabled && GetPropW(item->hwndItem, L"SkipItHover");
  const float w = static_cast<float>(item->rcItem.right), h = static_cast<float>(item->rcItem.bottom);
  if (item->CtlID == kClose) {
    FillRect(item->hDC, &item->rcItem, bgBrush);
    if (hovered) Rounded(g, Gdiplus::RectF(0.5f, 0.5f, w - 1, h - 1), static_cast<float>(S(5)), kHover, kHover);
    Gdiplus::Pen pen(Color(hovered ? kText : kMuted), 1.3f * dpi / 96);
    pen.SetStartCap(Gdiplus::LineCapRound); pen.SetEndCap(Gdiplus::LineCapRound);
    const float d = 4.5f * dpi / 96;
    g.DrawLine(&pen, w / 2 - d, h / 2 - d, w / 2 + d, h / 2 + d);
    g.DrawLine(&pen, w / 2 - d, h / 2 + d, w / 2 + d, h / 2 - d);
    return;
  }
  COLORREF fill = item->CtlID == kNext && !disabled ? kAccent : kPanel;
  if (hovered && item->CtlID != kNext) fill = kHover;
  if (selected) fill = RGB(58, 38, 30);
  if (item->itemState & ODS_SELECTED) fill = RGB(90, 45, 25);
  const COLORREF border = selected || (item->itemState & ODS_FOCUS) ? kAccent : kBorder;
  FillRect(item->hDC, &item->rcItem, bgBrush);
  Rounded(g, Gdiplus::RectF(0.5f, 0.5f, w - 1, h - 1), static_cast<float>(S(language ? 6 : 10)), fill, border);
  SetBkMode(item->hDC, TRANSPARENT);
  SetTextColor(item->hDC, disabled ? kMuted : (language && selected ? kAccent : kText));
  SelectObject(item->hDC, font);
  RECT rect = item->rcItem;
  const auto text = ControlText(item->hwndItem);
  DrawTextW(item->hDC, text.c_str(), -1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

void PaintShell(HWND hwnd, HDC dc) {
  const int saved = SaveDC(dc);
  // Parent invalidation (for example after a checkbox click) must not erase children.
  ExcludeChildren(hwnd, dc);
  RECT bounds; GetClientRect(hwnd, &bounds); FillRect(dc, &bounds, bgBrush);
  {
    Gdiplus::Graphics g(dc); g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    // GDI+ keeps its own clip: apply child exclusions there too.
    ExcludeChildren(hwnd, g);
    Rounded(g, Gdiplus::RectF(0.5f, 0.5f, static_cast<float>(bounds.right - 1), static_cast<float>(bounds.bottom - 1)),
        static_cast<float>(S(10)), kBg, kBorder);
    // The same restrained accent glow as the notification card.
    Gdiplus::GraphicsPath glowPath; glowPath.AddEllipse(S(400), -S(100), S(300), S(230));
    Gdiplus::PathGradientBrush glow(&glowPath);
    glow.SetCenterColor(Gdiplus::Color(24, 255, 95, 26));
    Gdiplus::Color edge(0, 255, 95, 26); INT count = 1; glow.SetSurroundColors(&edge, &count);
    const Gdiplus::GraphicsState beforeGlow = g.Save();
    g.SetClip(Gdiplus::Rect(S(2), S(2), S(708), S(77)), Gdiplus::CombineModeIntersect);
    g.FillPath(&glow, &glowPath); g.Restore(beforeGlow);
    if (mark) {
      g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
      const int width = S(52), height = static_cast<int>(std::lround(width * static_cast<double>(mark->GetHeight()) / mark->GetWidth()));
      g.DrawImage(mark, S(32), S(46) - height / 2, width, height);
    }
    Gdiplus::Pen line(Color(kBorder)); g.DrawLine(&line, S(32), S(80), S(680), S(80));
    if (page >= 3) {
      Gdiplus::SolidBrush badge(Color(success ? kGreen : kRed)); g.FillEllipse(&badge, S(32), S(202), S(30), S(30));
      Gdiplus::Pen pen(Color(kBg), static_cast<float>(S(2)));
      pen.SetStartCap(Gdiplus::LineCapRound); pen.SetEndCap(Gdiplus::LineCapRound); pen.SetLineJoin(Gdiplus::LineJoinRound);
      if (success) {
        Gdiplus::Point points[] = {{S(40), S(217)}, {S(45), S(222)}, {S(55), S(211)}}; g.DrawLines(&pen, points, 3);
      } else {
        g.DrawLine(&pen, S(42), S(212), S(52), S(222)); g.DrawLine(&pen, S(42), S(222), S(52), S(212));
      }
    }
  }
  SetBkMode(dc, TRANSPARENT); SetTextColor(dc, kText); SelectObject(dc, brandFont);
  RECT brand{S(95), S(24), S(300), S(63)}; DrawTextW(dc, L"SkipIt", -1, &brand, DT_LEFT | DT_SINGLELINE);
  if (page >= 2) { SelectObject(dc, font); SetTextColor(dc, kMuted); RECT version{S(32), S(500), S(350), S(526)}; DrawTextW(dc, APP_VERSION, -1, &version, DT_LEFT | DT_SINGLELINE); }
  RestoreDC(dc, saved);
}

LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) {
  switch (message) {
    // PaintShell covers the invalid area; a separate default erase flashes the header.
    case WM_ERASEBKGND: return 1;
    case WM_NCCALCSIZE: return 0;
    case WM_NCACTIVATE: return TRUE;
    case WM_NCHITTEST: {
      POINT point{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)}; ScreenToClient(hwnd, &point);
      return point.y < S(80) && point.x < S(510) ? HTCAPTION : HTCLIENT;
    }
    case WM_SIZE:
      if (!nativeCorners && wp != SIZE_MINIMIZED) {
        HRGN corners = CreateRoundRectRgn(0, 0, LOWORD(lp) + 1, HIWORD(lp) + 1, S(20), S(20));
        if (!SetWindowRgn(hwnd, corners, FALSE)) DeleteObject(corners);
      }
      return 0;
    case WM_GETMINMAXINFO: {
      auto* limits = reinterpret_cast<MINMAXINFO*>(lp);
      limits->ptMinTrackSize = POINT{S(712), S(552)}; limits->ptMaxTrackSize = limits->ptMinTrackSize;
      return 0;
    }
    case WM_CREATE: {
      window = hwnd; dpi = GetDpiForWindow(hwnd);
      font = CreateFontW(-S(14), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
      titleFont = CreateFontW(-S(24), 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
      brandFont = CreateFontW(-S(27), 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
      BOOL dark = TRUE; DwmSetWindowAttribute(hwnd, 20, &dark, sizeof(dark));
      const DWORD cornerPreference = 2;  // DWMWCP_ROUND; Windows 10 uses a rounded region below.
      nativeCorners = SUCCEEDED(DwmSetWindowAttribute(hwnd, 33, &cornerPreference, sizeof(cornerPreference)));
      const MARGINS shadow{1, 1, 1, 1}; DwmExtendFrameIntoClientArea(hwnd, &shadow);
      HRSRC markResource = FindResourceW(nullptr, MAKEINTRESOURCEW(104), RT_RCDATA);
      markStream = SHCreateMemStream(static_cast<const BYTE*>(LockResource(LoadResource(nullptr, markResource))), SizeofResource(nullptr, markResource));
      if (markStream) mark = Gdiplus::Bitmap::FromStream(markStream);
      en = Control(L"BUTTON", L"EN", BS_OWNERDRAW | WS_TABSTOP, kEn, 528, 26, 46, 30);
      ru = Control(L"BUTTON", L"RU", BS_OWNERDRAW | WS_TABSTOP, kRu, 582, 26, 46, 30);
      closeButton = Control(L"BUTTON", L"", BS_OWNERDRAW | WS_TABSTOP, kClose, 654, 18, 26, 24);
      heading = Control(L"STATIC", L"", 0, 0, 32, 100, 650, 38);
      SendMessageW(heading, WM_SETFONT, reinterpret_cast<WPARAM>(titleFont), TRUE);
      description = Control(L"STATIC", L"", 0, 0, 32, 145, 650, 28);
      licenseViewport = Control(L"SkipItLicenseViewport", L"", WS_CLIPCHILDREN, 0, 32, 188, 648, 222);
      SetWindowLongPtrW(licenseViewport, GWL_EXSTYLE, GetWindowLongPtrW(licenseViewport, GWL_EXSTYLE) | WS_EX_COMPOSITED);
      licenseContent = Control(L"STATIC", L"", WS_CLIPCHILDREN, 0, 1, 2, 630, 218, licenseViewport);
      HRGN contentCorners = CreateRoundRectRgn(0, 0, S(630) + 1, S(218) + 1, S(18), S(18));
      if (!SetWindowRgn(licenseContent, contentCorners, FALSE)) DeleteObject(contentCorners);
      SetWindowLongPtrW(licenseContent, GWL_EXSTYLE, GetWindowLongPtrW(licenseContent, GWL_EXSTYLE) | WS_EX_CONTROLPARENT);
      SetWindowSubclass(licenseContent, LicenseContentProc, 1, 0);
      licenseBox = Control(MSFTEDIT_CLASS, L"", ES_MULTILINE | ES_READONLY | WS_TABSTOP, 0, 13, 8, 606, 202, licenseContent);
      SetWindowSubclass(licenseBox, LicenseProc, 1, 0);
      SendMessageW(licenseBox, EM_SETEVENTMASK, 0, ENM_REQUESTRESIZE);
      SendMessageW(licenseBox, EM_SETBKGNDCOLOR, 0, kPanel);
      CHARFORMAT2W format{}; format.cbSize = sizeof(format); format.dwMask = CFM_COLOR; format.crTextColor = kText;
      SendMessageW(licenseBox, EM_SETCHARFORMAT, SCF_ALL, reinterpret_cast<LPARAM>(&format));
      Text(licenseBox, ResourceText(103).c_str());
      SendMessageW(licenseBox, EM_REQUESTRESIZE, 0, 0);
      agree = Control(L"BUTTON", L"", BS_AUTOCHECKBOX | WS_TABSTOP, kAgree, 32, 426, 648, 30);
      SetWindowSubclass(agree, CheckboxProc, 1, 0);
      pathLabel = Control(L"STATIC", L"", 0, 0, 32, 198, 648, 24);
      pathFrame = Control(L"STATIC", L"", WS_CLIPCHILDREN | SS_NOTIFY, 0, 32, 234, 536, 32);
      SetWindowLongPtrW(pathFrame, GWL_EXSTYLE, GetWindowLongPtrW(pathFrame, GWL_EXSTYLE) | WS_EX_CONTROLPARENT);
      SetWindowSubclass(pathFrame, PathFrameProc, 1, 0);
      pathEdit = Control(L"EDIT", DefaultDirectory().c_str(), ES_AUTOHSCROLL | WS_TABSTOP, kPath, 0, 0, 1, 1, pathFrame);
      SetWindowSubclass(pathEdit, PathEditProc, 1, 0);
      HDC pathDc = GetDC(pathEdit); HGDIOBJ oldFont = SelectObject(pathDc, font);
      TEXTMETRICW pathMetrics{}; GetTextMetricsW(pathDc, &pathMetrics);
      SelectObject(pathDc, oldFont); ReleaseDC(pathEdit, pathDc);
      RECT pathBounds; GetClientRect(pathFrame, &pathBounds);
      const int editHeight = pathMetrics.tmHeight + S(2);
      SetWindowPos(pathEdit, nullptr, S(6), (pathBounds.bottom - pathMetrics.tmHeight) / 2,
          pathBounds.right - S(12), editHeight, SWP_NOZORDER | SWP_NOACTIVATE);
      browse = Control(L"BUTTON", L"", BS_OWNERDRAW | WS_TABSTOP, kBrowse, 580, 234, 100, 32);
      pathWarning = Control(L"STATIC", L"", 0, 0, 32, 277, 648, 24);
      desktop = Control(L"BUTTON", L"", BS_AUTOCHECKBOX | WS_TABSTOP, kDesktop, 32, 314, 648, 30);
      SetWindowSubclass(desktop, CheckboxProc, 1, 0);
      SendMessageW(desktop, BM_SETCHECK, BST_CHECKED, 0);
      launch = Control(L"BUTTON", L"", BS_AUTOCHECKBOX | WS_TABSTOP, kLaunch, 32, 310, 648, 30);
      SetWindowSubclass(launch, CheckboxProc, 1, 0);
      SendMessageW(launch, BM_SETCHECK, BST_CHECKED, 0);
      status = Control(L"STATIC", L"", 0, 0, 32, 244, 648, 60);
      progress = Control(PROGRESS_CLASSW, L"", PBS_MARQUEE, 0, 32, 207, 648, 10);
      SetWindowTheme(progress, L"", L"");
      SendMessageW(progress, PBM_SETBARCOLOR, 0, kAccent);
      SendMessageW(progress, PBM_SETBKCOLOR, 0, kPanel);
      back = Control(L"BUTTON", L"", BS_OWNERDRAW | WS_TABSTOP, kBack, 32, 493, 100, 36);
      cancel = Control(L"BUTTON", L"", BS_OWNERDRAW | WS_TABSTOP, kCancel, 444, 493, 100, 36);
      next = Control(L"BUTTON", L"", BS_OWNERDRAW | WS_TABSTOP, kNext, 556, 493, 124, 36);
      Update(); return 0;
    }
    case WM_DRAWITEM: DrawButton(reinterpret_cast<DRAWITEMSTRUCT*>(lp)); return TRUE;
    case WM_CTLCOLORSTATIC: case WM_CTLCOLORBTN: case WM_CTLCOLOREDIT: {
      const HDC dc = reinterpret_cast<HDC>(wp);
      const bool edit = reinterpret_cast<HWND>(lp) == pathEdit || reinterpret_cast<HWND>(lp) == pathFrame;
      const bool secondary = reinterpret_cast<HWND>(lp) == description || reinterpret_cast<HWND>(lp) == status || reinterpret_cast<HWND>(lp) == pathLabel;
      SetTextColor(dc, reinterpret_cast<HWND>(lp) == pathWarning ? kRed : (secondary ? kMuted : kText)); SetBkColor(dc, edit ? kPanel : kBg);
      return reinterpret_cast<LRESULT>(edit ? panelBrush : bgBrush);
    }
    case WM_PAINT: {
      PAINTSTRUCT ps; HDC dc = BeginPaint(hwnd, &ps);
      PaintShell(hwnd, dc);
      EndPaint(hwnd, &ps); return 0;
    }
    case WM_PRINTCLIENT: PaintShell(hwnd, reinterpret_cast<HDC>(wp)); return 0;
    case WM_COMMAND:
      switch (LOWORD(wp)) {
        case kEn: russian = false; Update(); break;
        case kRu: russian = true; Update(); break;
        case kAgree: EnableWindow(next, Checked(agree)); break;
        case kBrowse: Browse(); break;
        case kBack: page = 0; Update(); break;
        case kCancel: SendMessageW(hwnd, WM_CLOSE, 0, 0); break;
        case kClose: SendMessageW(hwnd, WM_CLOSE, 0, 0); break;
        case kPath:
          if (HIWORD(wp) == EN_CHANGE) { pathInvalid = false; Show(pathWarning, false); }
          break;
        case kNext:
          if (page == 0 && Checked(agree)) { page = 1; Update(); }
          else if (page == 1) Install();
          else if (page >= 3) {
#ifndef SKIPIT_PREVIEW
            if (success && Checked(launch)) ShellExecuteW(nullptr, L"open", L"explorer.exe", Quote(installDirectory + L"\\SkipIt.exe").c_str(), nullptr, SW_SHOWNORMAL);
#endif
            DestroyWindow(hwnd);
          }
          break;
      }
      return 0;
    case kFinished:
      busy = false; success = wp == 0 || wp == 3010;
      page = success ? 3 : 4;
      failureCode = wp == MAXDWORD ? (lp ? static_cast<DWORD>(lp) : ERROR_GEN_FAILURE) : static_cast<DWORD>(wp);
      Update(); return 0;
    case WM_CLOSE: if (!busy) DestroyWindow(hwnd); return 0;
    case WM_DESTROY: PostQuitMessage(0); return 0;
  }
  return DefWindowProcW(hwnd, message, wp, lp);
}
}  // namespace

#ifdef SKIPIT_UI_TESTS
int RunUiTests(HWND hwnd);
#endif

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR arguments, int show) {
#ifndef SKIPIT_PREVIEW
  int count = 0; LPWSTR* args = CommandLineToArgvW(GetCommandLineW(), &count);
  bool passThrough = false;
  for (int i = 1; args && i < count; ++i)
    if (!_wcsicmp(args[i], L"/SILENT") || !_wcsicmp(args[i], L"/VERYSILENT") || !_wcsicmp(args[i], L"/?") || !_wcsicmp(args[i], L"/HELP")) passThrough = true;
  if (args) LocalFree(args);
  if (passThrough) { DWORD error = 0; const DWORD result = RunPayload(arguments, error); return static_cast<int>(result == MAXDWORD ? (error ? error : 1) : result); }
#else
  (void)arguments;
#endif
  russian = PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_RUSSIAN;
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  Gdiplus::GdiplusStartupInput gdiplusInput; ULONG_PTR gdiplusToken;
  Gdiplus::GdiplusStartup(&gdiplusToken, &gdiplusInput, nullptr);
  INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_PROGRESS_CLASS}; InitCommonControlsEx(&controls);
  HMODULE richEdit = LoadLibraryExW(L"Msftedit.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  bgBrush = CreateSolidBrush(kBg); panelBrush = CreateSolidBrush(kPanel);
  WNDCLASSW cls{}; cls.lpfnWndProc = WindowProc; cls.hInstance = instance;
  cls.lpszClassName = L"SkipItSetupShell"; cls.hbrBackground = bgBrush;
  cls.hCursor = LoadCursorW(nullptr, IDC_ARROW); cls.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(101));
  RegisterClassW(&cls);
  WNDCLASSW viewportClass{}; viewportClass.lpfnWndProc = LicenseViewportProc; viewportClass.hInstance = instance;
  viewportClass.lpszClassName = L"SkipItLicenseViewport"; viewportClass.hbrBackground = panelBrush;
  viewportClass.hCursor = LoadCursorW(nullptr, IDC_ARROW); RegisterClassW(&viewportClass);
  dpi = GetDpiForSystem();
  const DWORD style = WS_POPUP | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_CLIPCHILDREN;
  RECT rect{0, 0, S(712), S(552)};
  HWND hwnd = CreateWindowExW(0, cls.lpszClassName, L"SkipIt", style,
      (GetSystemMetrics(SM_CXSCREEN) - (rect.right - rect.left)) / 2,
      (GetSystemMetrics(SM_CYSCREEN) - (rect.bottom - rect.top)) / 2,
      rect.right - rect.left, rect.bottom - rect.top, nullptr, nullptr, instance, nullptr);
  if (!hwnd) return 1;
#ifdef SKIPIT_UI_TESTS
  (void)show;
  const int testResult = RunUiTests(hwnd);
  DestroyWindow(hwnd);
#else
  ShowWindow(hwnd, show); UpdateWindow(hwnd);
  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    if (!IsDialogMessageW(hwnd, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
  }
#endif
  DeleteObject(font); DeleteObject(titleFont); DeleteObject(brandFont); DeleteObject(bgBrush); DeleteObject(panelBrush);
  delete mark; if (markStream) markStream->Release();
  FreeLibrary(richEdit); Gdiplus::GdiplusShutdown(gdiplusToken); CoUninitialize();
#ifdef SKIPIT_UI_TESTS
  return testResult;
#else
  return 0;
#endif
}

#include "screen_image.h"

#include <dwmapi.h>

namespace {

// Пиксели картинки в 32 битах сверху вниз → оттенки серого.
bool ToGray(HDC dc, HBITMAP bitmap, int width, int height, GrayImage& out) {
  if (width <= 0 || height <= 0 || width > 16384 || height > 16384) return false;
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(info.bmiHeader);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  std::vector<uint8_t> bgra(static_cast<size_t>(width) * height * 4);
  if (GetDIBits(dc, bitmap, 0, height, bgra.data(), &info, DIB_RGB_COLORS) != height) return false;
  out.width = width;
  out.height = height;
  out.pixels.resize(static_cast<size_t>(width) * height);
  for (size_t i = 0; i < out.pixels.size(); i++) {
    const uint8_t* p = &bgra[i * 4];
    out.pixels[i] = static_cast<uint8_t>((p[2] * 299 + p[1] * 587 + p[0] * 114) / 1000);
  }
  return true;
}

}  // namespace

bool CaptureScreen(HWND hide, GrayImage& out) {
  const bool visible = hide && IsWindowVisible(hide) && !IsIconic(hide);
  if (visible) {
    // Без анимации исчезновения: иначе на снимок попадёт полупрозрачное окно.
    BOOL off = TRUE;
    DwmSetWindowAttribute(hide, DWMWA_TRANSITIONS_FORCEDISABLED, &off, sizeof(off));
    ShowWindow(hide, SW_HIDE);
    DwmFlush();
    Sleep(150);
  }
  const int x = GetSystemMetrics(SM_XVIRTUALSCREEN), y = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int w = GetSystemMetrics(SM_CXVIRTUALSCREEN), h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  HDC screen = GetDC(nullptr);
  HDC mem = CreateCompatibleDC(screen);
  HBITMAP bitmap = CreateCompatibleBitmap(screen, w, h);
  bool ok = false;
  if (mem && bitmap) {
    HGDIOBJ old = SelectObject(mem, bitmap);
    ok = BitBlt(mem, 0, 0, w, h, screen, x, y, SRCCOPY | CAPTUREBLT) != 0;
    SelectObject(mem, old);
    ok = ok && ToGray(mem, bitmap, w, h, out);
  }
  if (bitmap) DeleteObject(bitmap);
  if (mem) DeleteDC(mem);
  ReleaseDC(nullptr, screen);
  if (visible) {
    ShowWindow(hide, SW_SHOW);
    SetForegroundWindow(hide);
    BOOL on = FALSE;
    DwmSetWindowAttribute(hide, DWMWA_TRANSITIONS_FORCEDISABLED, &on, sizeof(on));
  }
  return ok;
}

bool ClipboardImage(HWND owner, GrayImage& out) {
  if (!IsClipboardFormatAvailable(CF_BITMAP) || !OpenClipboard(owner)) return false;
  bool ok = false;
  // Растр принадлежит буферу обмена — не удаляем. Windows сама делает его из CF_DIB и CF_DIBV5.
  if (auto bitmap = static_cast<HBITMAP>(GetClipboardData(CF_BITMAP))) {
    BITMAP bm{};
    if (GetObjectW(bitmap, sizeof(bm), &bm)) {
      HDC screen = GetDC(nullptr);
      ok = ToGray(screen, bitmap, bm.bmWidth, bm.bmHeight, out);
      ReleaseDC(nullptr, screen);
    }
  }
  CloseClipboard();
  return ok;
}

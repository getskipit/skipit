#include "notify_popup.h"

#include <shellapi.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <memory>

// GDI+ рассчитывает на макросы min/max из windows.h, а проект собирается с NOMINMAX.
namespace Gdiplus {
using std::max;
using std::min;
}  // namespace Gdiplus
// Заголовки GDI+ не рассчитаны на строгий уровень предупреждений проекта (/W4 /WX).
#pragma warning(push, 0)
#include <gdiplus.h>
#pragma warning(pop)

#include "resource.h"

namespace {

constexpr wchar_t kClassName[] = L"SkipItNotifyPopup";
constexpr UINT_PTR kAnimTimer = 1;

// Размеры в пикселях при масштабе 100 %; умножаются на масштаб монитора.
constexpr float kCardWidth = 384;
constexpr float kPad = 14;
// Поле вокруг карточки под тень и выступ значка над её верхним краем.
constexpr float kMargin = 14;
constexpr float kOverhang = 14;
constexpr float kPicture = 84;
constexpr float kRadius = 10;
// От края рабочей области (над панелью задач).
constexpr float kScreenGap = 12;

// Сколько уведомление висит само и сколько ещё — после того как курсор ушёл с него.
constexpr ULONGLONG kShowMs = 7000;
constexpr ULONGLONG kAfterHoverMs = 3000;
constexpr ULONGLONG kInMs = 260;
constexpr ULONGLONG kOutMs = 200;
constexpr ULONGLONG kBackMs = 200;

// Значки из системного шрифта Segoe Fluent Icons / Segoe MDL2 Assets (коды у них общие).
constexpr wchar_t kGlyphCheck[] = L"\xE73E";
constexpr wchar_t kGlyphCancel[] = L"\xE711";
constexpr wchar_t kGlyphClose[] = L"\xE8BB";

constexpr COLORREF kGreen = RGB(0x4A, 0xDE, 0x80);
constexpr COLORREF kWarn = RGB(0xFF, 0x9F, 0x1A);
constexpr COLORREF kRed = RGB(0xFF, 0x4D, 0x4D);

enum class Phase { kIn, kShown, kDrag, kBack, kOut };

struct Popup {
  HWND owner = nullptr;
  UINT message = 0;
  NotifyModel model;
  std::unique_ptr<Gdiplus::Bitmap> picture;
  float s = 1;
  // Размер окна и место карточки в нём.
  int width = 0, height = 0;
  Gdiplus::RectF card;
  Gdiplus::RectF close;
  // Где окно стоит без сдвига и в какую сторону уезжает: +1 — вправо, −1 — влево (панель задач слева).
  POINT home{};
  int dir = 1;
  // Готовая картинка окна (32 бита с предумноженной альфой).
  HDC dc = nullptr;
  HBITMAP bitmap = nullptr;
  HGDIOBJ old_bitmap = nullptr;
  void* bits = nullptr;

  Phase phase = Phase::kIn;
  ULONGLONG phase_start = 0;
  float offset = 0, alpha = 0;
  float from_offset = 0, from_alpha = 0, to_offset = 0;
  ULONGLONG hide_at = 0;
  bool hover = false, close_hover = false;
  // Перетаскивание: где нажали, был ли сдвиг и последние точки для скорости смахивания.
  bool pressed = false;
  int press_x = 0;
  float press_offset = 0;
  int last_x = 0, prev_x = 0;
  ULONGLONG last_t = 0, prev_t = 0;
};

HWND g_popup = nullptr;

Gdiplus::Color Rgb(COLORREF c, BYTE a = 255) {
  return Gdiplus::Color(a, GetRValue(c), GetGValue(c), GetBValue(c));
}

void AddRounded(Gdiplus::GraphicsPath& path, const Gdiplus::RectF& r, float radius) {
  const float d = radius * 2;
  path.AddArc(r.X, r.Y, d, d, 180, 90);
  path.AddArc(r.GetRight() - d, r.Y, d, d, 270, 90);
  path.AddArc(r.GetRight() - d, r.GetBottom() - d, d, d, 0, 90);
  path.AddArc(r.X, r.GetBottom() - d, d, d, 90, 90);
  path.CloseFigure();
}

// Картинка из RGBA (без предумножения) — для своего значка из настроек.
std::unique_ptr<Gdiplus::Bitmap> FromRgba(int size, const std::vector<uint8_t>& rgba) {
  if (size <= 0 || rgba.size() != static_cast<size_t>(size) * size * 4) return nullptr;
  auto bmp = std::make_unique<Gdiplus::Bitmap>(size, size, PixelFormat32bppARGB);
  Gdiplus::BitmapData data;
  Gdiplus::Rect rect(0, 0, size, size);
  if (bmp->LockBits(&rect, Gdiplus::ImageLockModeWrite, PixelFormat32bppARGB, &data) != Gdiplus::Ok) return nullptr;
  for (int y = 0; y < size; y++) {
    auto* row = static_cast<uint8_t*>(data.Scan0) + static_cast<ptrdiff_t>(y) * data.Stride;
    const uint8_t* src = rgba.data() + static_cast<size_t>(y) * size * 4;
    for (int x = 0; x < size; x++) {
      row[x * 4] = src[x * 4 + 2];
      row[x * 4 + 1] = src[x * 4 + 1];
      row[x * 4 + 2] = src[x * 4];
      row[x * 4 + 3] = src[x * 4 + 3];
    }
  }
  bmp->UnlockBits(&data);
  return bmp;
}

// Значок из ресурсов exe с прозрачностью (Bitmap::FromHICON прозрачность теряет).
std::unique_ptr<Gdiplus::Bitmap> FromResource(int size) {
  HICON icon = static_cast<HICON>(LoadImageW(GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
                                             size, size, LR_DEFAULTCOLOR));
  if (!icon) return nullptr;
  std::unique_ptr<Gdiplus::Bitmap> result;
  ICONINFO info{};
  if (GetIconInfo(icon, &info)) {
    BITMAPINFO bi{};
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = size;
    bi.bmiHeader.biHeight = -size;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    std::vector<uint8_t> bgra(static_cast<size_t>(size) * size * 4);
    HDC dc = GetDC(nullptr);
    if (info.hbmColor && GetDIBits(dc, info.hbmColor, 0, size, bgra.data(), &bi, DIB_RGB_COLORS) == size) {
      std::vector<uint8_t> rgba(bgra.size());
      for (size_t i = 0; i < bgra.size(); i += 4) {
        rgba[i] = bgra[i + 2];
        rgba[i + 1] = bgra[i + 1];
        rgba[i + 2] = bgra[i];
        rgba[i + 3] = bgra[i + 3];
      }
      result = FromRgba(size, rgba);
    }
    ReleaseDC(nullptr, dc);
    if (info.hbmColor) DeleteObject(info.hbmColor);
    if (info.hbmMask) DeleteObject(info.hbmMask);
  }
  DestroyIcon(icon);
  return result;
}

std::unique_ptr<Gdiplus::Bitmap> MakePicture(const NotifyModel& model, int want) {
  // Картинка не меньше нужного размера (ближайшая), иначе самая большая.
  const std::pair<int, std::vector<uint8_t>>* best = nullptr;
  for (const auto& image : model.images) {
    if (!best || (best->first < want ? image.first > best->first : image.first >= want && image.first < best->first)) {
      best = &image;
    }
  }
  if (best) {
    if (auto bmp = FromRgba(best->first, best->second)) return bmp;
  }
  return FromResource(want);
}

COLORREF KindColor(const Popup& p) {
  switch (p.model.kind) {
    case NotifyKind::kOk:
      return kGreen;
    case NotifyKind::kWarn:
      return kWarn;
    case NotifyKind::kError:
      return kRed;
    default:
      return p.model.accent;
  }
}

const wchar_t* IconFamily() {
  // В Windows 11 — Segoe Fluent Icons, в Windows 10 — Segoe MDL2 Assets.
  static const wchar_t* family = Gdiplus::FontFamily(L"Segoe Fluent Icons").IsAvailable()
                                     ? L"Segoe Fluent Icons"
                                     : L"Segoe MDL2 Assets";
  return family;
}

// Цвета — как у меню в трее и всплывающих меню программы (lib/ui/theme.dart).
struct Palette {
  COLORREF bg, border, text, muted, hover;
};

Palette PaletteFor(bool dark) {
  return dark ? Palette{RGB(0x1B, 0x1B, 0x1E), RGB(0x29, 0x29, 0x2E), RGB(0xF7, 0xF7, 0xF8), RGB(0xA8, 0xA8, 0xB0),
                        RGB(0x2E, 0x2E, 0x34)}
              : Palette{RGB(0xFF, 0xFF, 0xFF), RGB(0xE1, 0xE1, 0xE6), RGB(0x16, 0x16, 0x1A), RGB(0x5E, 0x5E, 0x68),
                        RGB(0xEE, 0xEE, 0xF2)};
}

// Высота текста сообщения (не больше трёх строк) при ширине |width|.
float TextHeight(const std::wstring& text, float width, float s) {
  HDC dc = GetDC(nullptr);
  float h;
  {
    Gdiplus::Graphics g(dc);
    Gdiplus::Font font(L"Segoe UI", 13.5f * s, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::RectF box;
    g.MeasureString(text.c_str(), -1, &font, Gdiplus::RectF(0, 0, width, 1000 * s), &box);
    h = std::min(box.Height, std::ceil(font.GetHeight(&g) * 3));
  }
  ReleaseDC(nullptr, dc);
  return h;
}

void Render(Popup& p) {
  const float s = p.s;
  const Palette pal = PaletteFor(p.model.dark);
  ZeroMemory(p.bits, static_cast<size_t>(p.width) * p.height * 4);
  Gdiplus::Bitmap canvas(p.width, p.height, p.width * 4, PixelFormat32bppPARGB, static_cast<BYTE*>(p.bits));
  Gdiplus::Graphics g(&canvas);
  g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
  g.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
  g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
  const Gdiplus::RectF& c = p.card;

  // Мягкая тень: несколько всё более широких полупрозрачных подложек.
  for (int i = 8; i >= 1; i--) {
    const float grow = i * 1.5f * s;
    Gdiplus::RectF r(c.X - grow, c.Y - grow + 3 * s, c.Width + grow * 2, c.Height + grow * 2);
    Gdiplus::GraphicsPath path;
    AddRounded(path, r, kRadius * s + grow);
    Gdiplus::SolidBrush shadow(Gdiplus::Color(static_cast<BYTE>(p.model.dark ? 14 : 7), 0, 0, 0));
    g.FillPath(&shadow, &path);
  }

  // Карточка.
  {
    Gdiplus::GraphicsPath path;
    AddRounded(path, c, kRadius * s);
    Gdiplus::SolidBrush bg(Rgb(pal.bg));
    g.FillPath(&bg, &path);
    // Свечение цвета уведомления за значком — внутри карточки.
    Gdiplus::Region clip(&path);
    g.SetClip(&clip);
    const float cx = c.GetRight() - (34 + kPicture / 2) * s, cy = c.Y + 26 * s;
    Gdiplus::GraphicsPath glow_path;
    const float gr = 92 * s;
    glow_path.AddEllipse(cx - gr, cy - gr, gr * 2, gr * 2);
    Gdiplus::PathGradientBrush glow(&glow_path);
    glow.SetCenterColor(Rgb(KindColor(p), static_cast<BYTE>(p.model.dark ? 70 : 50)));
    Gdiplus::Color edge = Rgb(KindColor(p), 0);
    INT count = 1;
    glow.SetSurroundColors(&edge, &count);
    g.FillEllipse(&glow, cx - gr, cy - gr, gr * 2, gr * 2);
    g.ResetClip();
    Gdiplus::Pen border(Rgb(pal.border), 1 * s);
    g.DrawPath(&border, &path);
  }

  // Крупный значок программы — выступает над верхним краем карточки.
  const Gdiplus::RectF pic(c.GetRight() - (34 + kPicture) * s, c.Y - kOverhang * s, kPicture * s, kPicture * s);
  if (p.picture) g.DrawImage(p.picture.get(), pic);
  // Отметка на значке: галочка, «!» или крестик в кружке цвета уведомления.
  if (p.model.kind != NotifyKind::kInfo) {
    const float b = 28 * s;
    const Gdiplus::RectF badge(pic.GetRight() - b + 2 * s, pic.GetBottom() - b + 2 * s, b, b);
    Gdiplus::SolidBrush ring(Rgb(pal.bg));
    g.FillEllipse(&ring, badge.X - 3 * s, badge.Y - 3 * s, b + 6 * s, b + 6 * s);
    Gdiplus::SolidBrush fill(Rgb(KindColor(p)));
    g.FillEllipse(&fill, badge);
    Gdiplus::StringFormat center;
    center.SetAlignment(Gdiplus::StringAlignmentCenter);
    center.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    Gdiplus::SolidBrush white(Gdiplus::Color(255, 255, 255, 255));
    if (p.model.kind == NotifyKind::kWarn) {
      Gdiplus::Font bang(L"Segoe UI", 17 * s, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
      g.DrawString(L"!", -1, &bang, Gdiplus::RectF(badge.X, badge.Y - 0.5f * s, b, b), &center, &white);
    } else {
      Gdiplus::Font glyph(IconFamily(), 13 * s, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
      g.DrawString(p.model.kind == NotifyKind::kOk ? kGlyphCheck : kGlyphCancel, -1, &glyph,
                   Gdiplus::RectF(badge.X, badge.Y + 0.5f * s, b, b), &center, &white);
    }
  }

  // Шапка: маленький значок и название, ниже — текст.
  const float x = c.X + kPad * s;
  const float text_w = pic.X - 12 * s - x;
  const float icon = 18 * s;
  if (p.picture) g.DrawImage(p.picture.get(), Gdiplus::RectF(x, c.Y + kPad * s + 1 * s, icon, icon));
  Gdiplus::StringFormat line;
  line.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  line.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
  line.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  Gdiplus::Font title(L"Segoe UI", 14 * s, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
  Gdiplus::SolidBrush text_brush(Rgb(pal.text));
  g.DrawString(p.model.title.c_str(), -1, &title,
               Gdiplus::RectF(x + icon + 8 * s, c.Y + kPad * s, text_w - icon - 8 * s, 20 * s), &line, &text_brush);
  Gdiplus::StringFormat wrap;
  wrap.SetTrimming(Gdiplus::StringTrimmingEllipsisWord);
  wrap.SetFormatFlags(Gdiplus::StringFormatFlagsLineLimit);
  Gdiplus::Font body(L"Segoe UI", 13.5f * s, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
  Gdiplus::SolidBrush muted(Rgb(pal.muted));
  const float body_y = c.Y + (kPad + 28) * s;
  g.DrawString(p.model.text.c_str(), -1, &body,
               Gdiplus::RectF(x, body_y, text_w, c.GetBottom() - kPad * s - body_y + 2 * s), &wrap, &muted);

  // Крестик — поверх значка, как у уведомлений Windows; подсветка при наведении.
  if (p.close_hover) {
    Gdiplus::GraphicsPath path;
    AddRounded(path, p.close, 5 * s);
    Gdiplus::SolidBrush hover(Rgb(pal.hover, 230));
    g.FillPath(&hover, &path);
  }
  Gdiplus::StringFormat center;
  center.SetAlignment(Gdiplus::StringAlignmentCenter);
  center.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  Gdiplus::Font close_font(IconFamily(), 10 * s, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
  g.DrawString(kGlyphClose, -1, &close_font, p.close, &center, p.close_hover ? &text_brush : &muted);
}

void Present(Popup& p) {
  POINT pos{p.home.x + static_cast<LONG>(std::lround(p.offset)), p.home.y};
  SIZE size{p.width, p.height};
  POINT src{0, 0};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, static_cast<BYTE>(std::clamp(p.alpha, 0.0f, 255.0f)), AC_SRC_ALPHA};
  UpdateLayeredWindow(g_popup, nullptr, &pos, &size, p.dc, &src, 0, &blend, ULW_ALPHA);
}

float EaseOut(float t) {
  t = std::clamp(t, 0.0f, 1.0f);
  return 1 - (1 - t) * (1 - t) * (1 - t);
}

// Насколько уведомление прозрачно, когда его тянут к краю.
float DragAlpha(const Popup& p) {
  const float away = std::max(0.0f, p.offset * p.dir) / (p.card.Width);
  return 255 * std::max(0.25f, 1 - away * 0.9f);
}

void StartPhase(Popup& p, Phase phase, float to_offset = 0) {
  p.phase = phase;
  p.phase_start = GetTickCount64();
  p.from_offset = p.offset;
  p.from_alpha = p.alpha;
  p.to_offset = to_offset;
}

// Уехать: крестиком или по времени — недалеко с растворением, смахиванием — за край экрана.
void Dismiss(Popup& p, bool fling) {
  if (p.phase == Phase::kOut) return;
  StartPhase(p, Phase::kOut, p.dir * (fling ? static_cast<float>(p.width) : 56 * p.s) + (fling ? p.offset : 0));
}

void Tick(HWND hwnd, Popup& p) {
  const ULONGLONG now = GetTickCount64();
  const float t = static_cast<float>(now - p.phase_start);
  switch (p.phase) {
    case Phase::kIn: {
      const float e = EaseOut(t / kInMs);
      p.offset = p.dir * 48 * p.s * (1 - e);
      p.alpha = 255 * std::min(1.0f, t / (kInMs * 0.6f));
      if (t >= kInMs) {
        p.offset = 0;
        p.alpha = 255;
        p.phase = Phase::kShown;
      }
      break;
    }
    case Phase::kShown:
      if (!p.hover && now >= p.hide_at) Dismiss(p, false);
      return;
    case Phase::kDrag:
      return;
    case Phase::kBack: {
      const float e = EaseOut(t / kBackMs);
      p.offset = p.from_offset * (1 - e);
      p.alpha = p.from_alpha + (255 - p.from_alpha) * e;
      if (t >= kBackMs) {
        p.offset = 0;
        p.alpha = 255;
        p.phase = Phase::kShown;
        p.hide_at = std::max(p.hide_at, now + kAfterHoverMs);
      }
      break;
    }
    case Phase::kOut: {
      const float e = EaseOut(t / kOutMs);
      p.offset = p.from_offset + (p.to_offset - p.from_offset) * e;
      p.alpha = p.from_alpha * (1 - e);
      if (t >= kOutMs) {
        DestroyWindow(hwnd);
        return;
      }
      break;
    }
  }
  Present(p);
}

bool InClose(const Popup& p, int x, int y) {
  return p.close.Contains(static_cast<float>(x), static_cast<float>(y));
}

bool InCard(const Popup& p, int x, int y) {
  return p.card.Contains(static_cast<float>(x), static_cast<float>(y));
}

LRESULT CALLBACK PopupProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  auto* p = reinterpret_cast<Popup*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  switch (msg) {
    case WM_MOUSEACTIVATE:
      // Уведомление не забирает фокус у того окна, где человек работает.
      return MA_NOACTIVATE;
    case WM_NCHITTEST: {
      // Тень и выступ значка над карточкой пропускают клики к окнам под ними.
      if (!p) break;
      POINT pt{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ScreenToClient(hwnd, &pt);
      const float px = p->card.X, py = p->card.Y;
      const bool in = InCard(*p, pt.x, pt.y) ||
                      (pt.x >= px && pt.x < p->card.GetRight() && pt.y >= py - kOverhang * p->s && pt.y < py);
      return in ? HTCLIENT : HTTRANSPARENT;
    }
    case WM_SETCURSOR:
      SetCursor(LoadCursor(nullptr, IDC_ARROW));
      return TRUE;
    case WM_MOUSEMOVE: {
      if (!p) break;
      const int x = GET_X_LPARAM(lparam), y = GET_Y_LPARAM(lparam);
      if (!p->hover) {
        p->hover = true;
        TRACKMOUSEEVENT tme{sizeof(tme), TME_LEAVE, hwnd, 0};
        TrackMouseEvent(&tme);
      }
      if (p->pressed) {
        POINT screen;
        GetCursorPos(&screen);
        const int dx = screen.x - p->press_x;
        if (p->phase != Phase::kDrag && std::abs(dx) > static_cast<int>(5 * p->s)) {
          StartPhase(*p, Phase::kDrag);
          p->press_offset = p->offset;
          p->press_x = screen.x;
        }
        if (p->phase == Phase::kDrag) {
          const float raw = p->press_offset + static_cast<float>(screen.x - p->press_x);
          // К краю экрана тянется свободно, в другую сторону — туго.
          p->offset = raw * p->dir > 0 ? raw : raw / 4;
          p->alpha = DragAlpha(*p);
          p->prev_x = p->last_x;
          p->prev_t = p->last_t;
          p->last_x = screen.x;
          p->last_t = GetTickCount64();
          Present(*p);
        }
        return 0;
      }
      const bool close_hover = InClose(*p, x, y);
      if (close_hover != p->close_hover) {
        p->close_hover = close_hover;
        Render(*p);
        Present(*p);
      }
      return 0;
    }
    case WM_MOUSELEAVE:
      if (!p) break;
      p->hover = false;
      p->hide_at = std::max(p->hide_at, GetTickCount64() + kAfterHoverMs);
      if (p->close_hover) {
        p->close_hover = false;
        Render(*p);
        Present(*p);
      }
      return 0;
    case WM_LBUTTONDOWN: {
      if (!p || p->phase == Phase::kOut) return 0;
      POINT screen;
      GetCursorPos(&screen);
      p->pressed = true;
      p->press_x = p->last_x = p->prev_x = screen.x;
      p->last_t = p->prev_t = GetTickCount64();
      SetCapture(hwnd);
      return 0;
    }
    case WM_LBUTTONUP: {
      if (!p || !p->pressed) return 0;
      p->pressed = false;
      const bool dragged = p->phase == Phase::kDrag;
      ReleaseCapture();
      if (dragged) {
        // Смахнули: дотянули дальше трети или резко бросили к краю.
        const ULONGLONG dt = std::max<ULONGLONG>(1, p->last_t - p->prev_t);
        const float speed = static_cast<float>(p->last_x - p->prev_x) / static_cast<float>(dt) / p->s;
        const bool recent = GetTickCount64() - p->last_t < 80;
        if (p->offset * p->dir > p->card.Width / 3 || (recent && speed * p->dir > 0.5f)) {
          Dismiss(*p, true);
        } else {
          StartPhase(*p, Phase::kBack);
        }
      } else if (InClose(*p, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam))) {
        Dismiss(*p, false);
      } else if (InCard(*p, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam))) {
        PostMessage(p->owner, p->message, 0, 0);
        Dismiss(*p, false);
      }
      return 0;
    }
    case WM_CAPTURECHANGED:
      // Захват мыши отняли посреди перетаскивания — уведомление возвращается на место.
      if (p && p->phase == Phase::kDrag && reinterpret_cast<HWND>(lparam) != hwnd) {
        p->pressed = false;
        StartPhase(*p, Phase::kBack);
      }
      return 0;
    case WM_TIMER:
      if (p && wparam == kAnimTimer) Tick(hwnd, *p);
      return 0;
    case WM_DESTROY:
      KillTimer(hwnd, kAnimTimer);
      if (p) {
        SetWindowLongPtr(hwnd, GWLP_USERDATA, 0);
        SelectObject(p->dc, p->old_bitmap);
        DeleteObject(p->bitmap);
        DeleteDC(p->dc);
        delete p;
      }
      if (g_popup == hwnd) g_popup = nullptr;
      return 0;
  }
  return DefWindowProc(hwnd, msg, wparam, lparam);
}

void EnsureReady() {
  static bool ready = false;
  if (ready) return;
  ready = true;
  Gdiplus::GdiplusStartupInput input;
  ULONG_PTR token = 0;
  Gdiplus::GdiplusStartup(&token, &input, nullptr);

  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = PopupProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.lpszClassName = kClassName;
  RegisterClassExW(&wc);
}

}  // namespace

bool ShowNotifyPopup(HWND owner, UINT message, const NotifyModel& model) {
  // Во время игры или презентации во весь экран и на заблокированном экране своё окно не показываем.
  QUERY_USER_NOTIFICATION_STATE state = QUNS_ACCEPTS_NOTIFICATIONS;
  if (SUCCEEDED(SHQueryUserNotificationState(&state)) && state != QUNS_ACCEPTS_NOTIFICATIONS && state != QUNS_APP) {
    return false;
  }
  EnsureReady();
  CloseNotifyPopup();

  // Монитор с панелью задач и сторона, у которой она стоит.
  HWND taskbar = FindWindowW(L"Shell_TrayWnd", nullptr);
  HMONITOR monitor = taskbar ? MonitorFromWindow(taskbar, MONITOR_DEFAULTTOPRIMARY)
                             : MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  APPBARDATA bar{sizeof(bar)};
  const UINT edge = SHAppBarMessage(ABM_GETTASKBARPOS, &bar) ? bar.uEdge : ABE_BOTTOM;
  UINT dpi_x = 96, dpi_y = 96;
  if (HMODULE shcore = LoadLibraryW(L"shcore.dll")) {
    using GetDpiForMonitorFn = HRESULT(WINAPI*)(HMONITOR, int, UINT*, UINT*);
    if (auto fn = reinterpret_cast<GetDpiForMonitorFn>(GetProcAddress(shcore, "GetDpiForMonitor"))) {
      fn(monitor, 0 /* MDT_EFFECTIVE_DPI */, &dpi_x, &dpi_y);
    }
    FreeLibrary(shcore);
  }

  auto p = std::make_unique<Popup>();
  p->owner = owner;
  p->message = message;
  p->model = model;
  const float s = p->s = dpi_x / 96.0f;
  p->picture = MakePicture(model, static_cast<int>(std::lround(kPicture * s)));

  // Размеры: карточка по тексту (не ниже значка), вокруг — поле под тень, сверху — под выступ значка.
  const float card_w = std::round(kCardWidth * s);
  const float text_w = card_w - (kPad + 34 + kPicture + 12) * s;
  const float card_h = std::round(std::max((kPicture - kOverhang + 18) * s,
                                           (kPad + 28) * s + TextHeight(model.text, text_w, s) + kPad * s));
  const float margin = std::round(kMargin * s), top = std::round((kMargin + kOverhang) * s);
  p->card = Gdiplus::RectF(margin, top, card_w, card_h);
  p->close = Gdiplus::RectF(p->card.GetRight() - 34 * s, p->card.Y + 8 * s, 26 * s, 24 * s);
  p->width = static_cast<int>(card_w + margin * 2);
  p->height = static_cast<int>(top + card_h + margin);

  MONITORINFO info{sizeof(info)};
  GetMonitorInfo(monitor, &info);
  const RECT work = info.rcWork;
  const LONG gap = std::lround(kScreenGap * s);
  p->dir = edge == ABE_LEFT ? -1 : 1;
  p->home.x = p->dir > 0 ? work.right - gap - static_cast<LONG>(card_w) - static_cast<LONG>(margin)
                         : work.left + gap - static_cast<LONG>(margin);
  p->home.y = edge == ABE_TOP ? work.top + gap - static_cast<LONG>(top)
                              : work.bottom - gap - static_cast<LONG>(card_h) - static_cast<LONG>(top);

  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
  bi.bmiHeader.biWidth = p->width;
  bi.bmiHeader.biHeight = -p->height;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  HDC screen = GetDC(nullptr);
  p->dc = CreateCompatibleDC(screen);
  p->bitmap = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &p->bits, nullptr, 0);
  ReleaseDC(nullptr, screen);
  if (!p->dc || !p->bitmap || !p->bits) {
    if (p->bitmap) DeleteObject(p->bitmap);
    if (p->dc) DeleteDC(p->dc);
    return false;
  }
  p->old_bitmap = SelectObject(p->dc, p->bitmap);
  Render(*p);

  HWND hwnd = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_NOACTIVATE, kClassName, L"",
                              WS_POPUP, p->home.x, p->home.y, p->width, p->height, owner, nullptr,
                              GetModuleHandle(nullptr), nullptr);
  if (!hwnd) {
    SelectObject(p->dc, p->old_bitmap);
    DeleteObject(p->bitmap);
    DeleteDC(p->dc);
    return false;
  }
  Popup& ref = *p;
  SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(p.release()));
  g_popup = hwnd;
  ref.phase_start = GetTickCount64();
  ref.hide_at = ref.phase_start + kShowMs;
  ref.offset = ref.dir * 48 * s;
  ref.alpha = 0;
  Present(ref);
  ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  SetTimer(hwnd, kAnimTimer, 10, nullptr);
  return true;
}

void CloseNotifyPopup() {
  if (g_popup) DestroyWindow(g_popup);
}

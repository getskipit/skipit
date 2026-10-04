#include "tray_menu.h"

#include <dwmapi.h>
#include <windowsx.h>

#include <algorithm>
#include <memory>
#include <vector>

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

constexpr wchar_t kClassName[] = L"SkipItTrayMenu";
constexpr UINT_PTR kFadeTimer = 1;

// Размеры в пикселях при масштабе 100 %; умножаются на масштаб монитора.
constexpr int kWidth = 286;
constexpr int kPadding = 6;
constexpr int kHeaderHeight = 58;
constexpr int kItemHeight = 36;
constexpr int kRowHeight = 34;
constexpr int kLabelHeight = 22;
constexpr int kSeparatorHeight = 9;
// Больше строк в списке серверов разом не показываем — остальные прокручиваются колесом мыши.
constexpr int kMaxVisibleServers = 7;

// Значки из системного шрифта Segoe Fluent Icons / Segoe MDL2 Assets (коды у них общие).
constexpr wchar_t kGlyphPlay = L'\xE768';
constexpr wchar_t kGlyphStop = L'\xE71A';
constexpr wchar_t kGlyphOpen = L'\xE8A7';
constexpr wchar_t kGlyphPower = L'\xE7E8';
constexpr wchar_t kGlyphGlobe = L'\xE774';
constexpr wchar_t kGlyphCheck = L'\xE73E';

enum class Kind { kAction, kMode, kCore, kSwitch, kServer };

struct Item {
  Kind kind = Kind::kAction;
  UINT command = 0;
  std::wstring text;
  wchar_t glyph = 0;
  // Главное действие (подключить) — оранжевым, опасное (выход) — красным при наведении.
  bool accent = false;
  bool danger = false;
  // Выбранный режим, ядро TUN или сервер.
  bool selected = false;
  // Номер сервера в модели (для флага) и его строка в списке серверов.
  int server = -1;
  int row = -1;
  // Пустой прямоугольник — пункт сейчас не виден (сервер за пределами прокрутки).
  RECT rect{};
};

struct Label {
  std::wstring text;
  RECT rect{};
};

struct Menu {
  HWND owner = nullptr;
  UINT message = 0;
  TrayMenuModel model;
  std::vector<Item> items;
  std::vector<Label> labels;
  // Названия провайдеров в списке серверов (видимые сейчас).
  std::vector<Label> groups;
  // Вертикальные позиции линий-разделителей.
  std::vector<int> separators;
  // Подложки переключателей режима и ядра TUN, область списка серверов.
  RECT mode_track{};
  RECT core_track{};
  RECT server_area{};
  // Строки списка серверов: номер сервера или, для заголовка провайдера, −1 − номер сервера под ним.
  std::vector<int> rows;
  // С какой строки начинается видимая часть списка.
  int server_offset = 0;
  int hover = -1;
  bool tracking = false;
  double scale = 1.0;
  int alpha = 0;
  HICON icon = nullptr;
  std::vector<std::unique_ptr<Gdiplus::Image>> flags;
};

HWND g_menu = nullptr;

Gdiplus::Color Rgb(COLORREF c, BYTE a = 255) {
  return Gdiplus::Color(a, GetRValue(c), GetGValue(c), GetBValue(c));
}

struct Palette {
  COLORREF bg, track, border, text, muted;
};

// Те же цвета, что у всплывающих меню внутри программы (lib/ui/theme.dart).
Palette PaletteFor(bool dark) {
  return dark ? Palette{RGB(0x1B, 0x1B, 0x1E), RGB(0x13, 0x13, 0x15), RGB(0x29, 0x29, 0x2E),
                        RGB(0xF7, 0xF7, 0xF8), RGB(0x8E, 0x8E, 0x96)}
              : Palette{RGB(0xFF, 0xFF, 0xFF), RGB(0xF0, 0xF0, 0xF3), RGB(0xE1, 0xE1, 0xE6),
                        RGB(0x16, 0x16, 0x1A), RGB(0x6E, 0x6E, 0x78)};
}

constexpr COLORREF kOrange = RGB(0xFF, 0x5F, 0x1A);
constexpr COLORREF kOrangeLight = RGB(0xFF, 0x9A, 0x3D);
constexpr COLORREF kGreen = RGB(0x4A, 0xDE, 0x80);
constexpr COLORREF kRed = RGB(0xFF, 0x4D, 0x4D);

Gdiplus::RectF ToRectF(const RECT& r) {
  return Gdiplus::RectF(static_cast<float>(r.left), static_cast<float>(r.top),
                        static_cast<float>(r.right - r.left), static_cast<float>(r.bottom - r.top));
}

void AddRounded(Gdiplus::GraphicsPath& path, const Gdiplus::RectF& r, float radius) {
  const float d = radius * 2;
  path.AddArc(r.X, r.Y, d, d, 180, 90);
  path.AddArc(r.GetRight() - d, r.Y, d, d, 270, 90);
  path.AddArc(r.GetRight() - d, r.GetBottom() - d, d, d, 0, 90);
  path.AddArc(r.X, r.GetBottom() - d, d, d, 90, 90);
  path.CloseFigure();
}

void FillRounded(Gdiplus::Graphics& g, const Gdiplus::RectF& r, float radius, Gdiplus::Color color) {
  Gdiplus::GraphicsPath path;
  AddRounded(path, r, radius);
  Gdiplus::SolidBrush brush(color);
  g.FillPath(&brush, &path);
}

int VisibleServers(const Menu& m) {
  return std::min(static_cast<int>(m.rows.size()), kMaxVisibleServers);
}

// Раскладывает пункты и возвращает высоту меню в пикселях экрана.
int Layout(Menu& m) {
  const auto px = [&m](int v) { return static_cast<int>(v * m.scale + 0.5); };
  const int left = px(kPadding), right = px(kWidth - kPadding);
  m.labels.clear();
  m.groups.clear();
  m.separators.clear();
  SetRectEmpty(&m.mode_track);
  SetRectEmpty(&m.core_track);
  SetRectEmpty(&m.server_area);

  int y = px(kPadding) + px(kHeaderHeight);
  const auto separator = [&] {
    m.separators.push_back(y + px(kSeparatorHeight) / 2);
    y += px(kSeparatorHeight);
  };
  const auto label = [&](const std::wstring& text) {
    m.labels.push_back(Label{text, RECT{left + px(10), y, right, y + px(kLabelHeight)}});
    y += px(kLabelHeight);
  };

  // Подключить / отключить.
  separator();
  for (Item& item : m.items) {
    if (item.kind == Kind::kAction && item.command == m.items.front().command) {
      item.rect = RECT{left, y, right, y + px(kItemHeight)};
      y += px(kItemHeight);
    }
  }

  // Переключатель в один ряд (режим, ядро TUN): ширина сегмента — по длине подписи.
  const auto segmented = [&](Kind kind, const std::wstring& title, RECT& track) {
    int total = 0;
    for (const Item& item : m.items) {
      if (item.kind == kind) total += static_cast<int>(item.text.size()) + 3;
    }
    if (total == 0) return;
    separator();
    label(title);
    track = RECT{left + px(4), y, right - px(4), y + px(kRowHeight)};
    const int inner_left = track.left + px(3);
    const int inner_width = (track.right - px(3)) - inner_left;
    int used = 0;
    for (Item& item : m.items) {
      if (item.kind != kind) continue;
      const int x0 = inner_left + inner_width * used / total;
      used += static_cast<int>(item.text.size()) + 3;
      const int x1 = inner_left + inner_width * used / total;
      item.rect = RECT{x0, y + px(3), x1, y + px(kRowHeight - 3)};
    }
    y += px(kRowHeight);
  };
  segmented(Kind::kMode, m.model.label_mode, m.mode_track);
  // Ядро TUN — только в режимах с адаптером (в остальных список ядер пуст).
  segmented(Kind::kCore, m.model.label_core, m.core_track);

  // Kill Switch — строка с выключателем (тоже только в режимах с адаптером).
  for (Item& item : m.items) {
    if (item.kind != Kind::kSwitch) continue;
    separator();
    item.rect = RECT{left, y, right, y + px(kItemHeight)};
    y += px(kItemHeight);
  }

  // Серверы: видимая часть списка, остальное — прокруткой.
  const int visible = VisibleServers(m);
  if (visible > 0) {
    separator();
    label(m.model.label_servers);
    m.server_area = RECT{left, y, right, y + px(kRowHeight) * visible};
    for (Item& item : m.items) {
      if (item.kind != Kind::kServer) continue;
      const int row = item.row - m.server_offset;
      if (row < 0 || row >= visible) {
        SetRectEmpty(&item.rect);
      } else {
        item.rect = RECT{left, y + px(kRowHeight) * row, right, y + px(kRowHeight) * (row + 1)};
      }
    }
    // Заголовки провайдеров — отдельными строками между серверами.
    for (int row = 0; row < visible; row++) {
      const int value = m.rows[row + m.server_offset];
      if (value >= 0) continue;
      const int top = y + px(kRowHeight) * row;
      m.groups.push_back(Label{m.model.servers[-1 - value].group,
                               RECT{left + px(4), top + px(5), right - px(8), top + px(kRowHeight - 3)}});
    }
    y += px(kRowHeight) * visible;
  }

  // Открыть окно и выйти.
  separator();
  bool first = true;
  for (Item& item : m.items) {
    if (item.kind != Kind::kAction) continue;
    if (first) {
      first = false;
      continue;
    }
    item.rect = RECT{left, y, right, y + px(kItemHeight)};
    y += px(kItemHeight);
  }
  return y + px(kPadding);
}

// Круглый флаг: картинка «вписана с обрезкой», края сглажены.
void DrawFlag(Gdiplus::Graphics& g, Gdiplus::Image* image, float x, float y, float size, COLORREF border) {
  const float iw = static_cast<float>(image->GetWidth()), ih = static_cast<float>(image->GetHeight());
  if (iw <= 0 || ih <= 0) return;
  const float scale = size / std::min(iw, ih);
  Gdiplus::TextureBrush brush(image, Gdiplus::WrapModeClamp);
  Gdiplus::Matrix matrix(scale, 0, 0, scale, x + (size - iw * scale) / 2, y + (size - ih * scale) / 2);
  brush.SetTransform(&matrix);
  g.FillEllipse(&brush, x, y, size, size);
  Gdiplus::Pen pen(Rgb(border), 1);
  g.DrawEllipse(&pen, x, y, size, size);
}

void Paint(HWND hwnd, HDC target) {
  auto* m = reinterpret_cast<Menu*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (!m) return;
  RECT client;
  GetClientRect(hwnd, &client);
  const int w = client.right, h = client.bottom;
  const float s = static_cast<float>(m->scale);
  const Palette p = PaletteFor(m->model.dark);

  // Рисуем в память и переносим одним куском — без мерцания.
  HDC mem = CreateCompatibleDC(target);
  HBITMAP bitmap = CreateCompatibleBitmap(target, w, h);
  HGDIOBJ old = SelectObject(mem, bitmap);
  {
    Gdiplus::Graphics g(mem);
    g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
    g.SetTextRenderingHint(Gdiplus::TextRenderingHintClearTypeGridFit);
    g.Clear(Rgb(p.bg));

    Gdiplus::StringFormat format;
    format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
    format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
    Gdiplus::StringFormat center;
    center.SetAlignment(Gdiplus::StringAlignmentCenter);
    center.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    center.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);

    Gdiplus::Font title_font(L"Segoe UI", 14 * s, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
    Gdiplus::Font small_font(L"Segoe UI", 12 * s, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::Font label_font(L"Segoe UI", 10.5f * s, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
    Gdiplus::Font group_font(L"Segoe UI", 12.5f * s, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
    Gdiplus::Font item_font(L"Segoe UI Semibold", 13.5f * s, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::Font mode_font(L"Segoe UI Semibold", 12 * s, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    // Значки: в Windows 11 — Segoe Fluent Icons, в Windows 10 — Segoe MDL2 Assets.
    Gdiplus::FontFamily fluent(L"Segoe Fluent Icons");
    const wchar_t* icon_family = fluent.IsAvailable() ? L"Segoe Fluent Icons" : L"Segoe MDL2 Assets";
    Gdiplus::Font icon_font(icon_family, 15 * s, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::Font small_icon_font(icon_family, 12 * s, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);

    Gdiplus::SolidBrush text_brush(Rgb(p.text));
    Gdiplus::SolidBrush muted_brush(Rgb(p.muted));
    Gdiplus::SolidBrush orange_brush(Rgb(kOrange));
    Gdiplus::SolidBrush white_brush(Gdiplus::Color(255, 255, 255, 255));

    // Шапка: название программы, под ним — точка состояния, статус и сервер.
    const float text_x = (kPadding + 46) * s;
    const float text_w = w - text_x - (kPadding + 8) * s;
    g.DrawString(m->model.title.c_str(), -1, &title_font,
                 Gdiplus::RectF(text_x, (kPadding + 9) * s, text_w, 20 * s), &format, &text_brush);
    const COLORREF dot = m->model.state == 2 ? kGreen : (m->model.state == 1 ? kOrange : p.muted);
    Gdiplus::SolidBrush dot_brush(Rgb(dot));
    g.FillEllipse(&dot_brush, text_x + 1 * s, (kPadding + 36) * s, 7 * s, 7 * s);
    std::wstring status = m->model.status;
    if (!m->model.server.empty()) status += L"  \x00B7  " + m->model.server;
    g.DrawString(status.c_str(), -1, &small_font,
                 Gdiplus::RectF(text_x + 13 * s, (kPadding + 30) * s, text_w - 13 * s, 19 * s), &format,
                 &muted_brush);

    // Разделители и подписи разделов.
    Gdiplus::SolidBrush line(Rgb(p.border));
    for (int y : m->separators) {
      g.FillRectangle(&line, (kPadding + 6) * s, static_cast<float>(y), w - (kPadding + 6) * 2 * s, 1 * s);
    }
    for (const Label& label : m->labels) {
      g.DrawString(label.text.c_str(), -1, &label_font, ToRectF(label.rect), &format, &muted_brush);
    }

    // Провайдер: плашка во всю ширину с оранжевой меткой и названием цветом основного текста —
    // чтобы заголовок не терялся среди серверов.
    for (const Label& group : m->groups) {
      const Gdiplus::RectF r = ToRectF(group.rect);
      FillRounded(g, r, 8 * s, Rgb(p.track));
      FillRounded(g, Gdiplus::RectF(r.X + 9 * s, r.Y + (r.Height - 12 * s) / 2, 3 * s, 12 * s), 1.5f * s,
                  Rgb(kOrange));
      g.DrawString(group.text.c_str(), -1, &group_font,
                   Gdiplus::RectF(r.X + 20 * s, r.Y, r.Width - 28 * s, r.Height), &format, &text_brush);
    }

    // Подложки переключателей режима и ядра TUN.
    if (!IsRectEmpty(&m->mode_track)) FillRounded(g, ToRectF(m->mode_track), 10 * s, Rgb(p.track));
    if (!IsRectEmpty(&m->core_track)) FillRounded(g, ToRectF(m->core_track), 10 * s, Rgb(p.track));

    for (size_t i = 0; i < m->items.size(); i++) {
      const Item& item = m->items[i];
      if (IsRectEmpty(&item.rect)) continue;
      const Gdiplus::RectF r = ToRectF(item.rect);
      const bool hovered = static_cast<int>(i) == m->hover;

      if (item.kind == Kind::kMode || item.kind == Kind::kCore) {
        // Выбранный режим (ядро) — оранжевая плашка с градиентом, как переключатель в окне программы.
        if (item.selected) {
          Gdiplus::GraphicsPath path;
          AddRounded(path, r, 8 * s);
          Gdiplus::LinearGradientBrush gradient(Gdiplus::PointF(r.X, r.Y), Gdiplus::PointF(r.GetRight(), r.GetBottom()),
                                                Rgb(kOrangeLight), Rgb(kOrange));
          g.FillPath(&gradient, &path);
        } else if (hovered) {
          FillRounded(g, r, 8 * s, Rgb(p.muted, 40));
        }
        g.DrawString(item.text.c_str(), -1, &mode_font, r, &center,
                     item.selected ? &white_brush : (hovered ? &text_brush : &muted_brush));
        continue;
      }

      const COLORREF accent = item.danger ? kRed : kOrange;
      if (hovered) {
        FillRounded(g, r, 9 * s, Rgb(accent, 34));
      } else if (item.kind == Kind::kServer && item.selected) {
        FillRounded(g, r, 9 * s, Rgb(kOrange, 20));
      }

      if (item.kind == Kind::kServer) {
        const float size = 18 * s;
        const float fx = r.X + 11 * s, fy = r.Y + (r.Height - size) / 2;
        Gdiplus::Image* flag = nullptr;
        if (item.server >= 0 && item.server < static_cast<int>(m->flags.size())) {
          auto& slot = m->flags[item.server];
          // Картинка флага читается с диска один раз, когда сервер впервые попал в видимую часть.
          if (!slot && !m->model.servers[item.server].flag.empty()) {
            slot = std::make_unique<Gdiplus::Image>(m->model.servers[item.server].flag.c_str());
          }
          if (slot && slot->GetLastStatus() == Gdiplus::Ok) flag = slot.get();
        }
        if (flag) {
          DrawFlag(g, flag, fx, fy, size, p.border);
        } else {
          const wchar_t globe[2] = {kGlyphGlobe, 0};
          g.DrawString(globe, 1, &icon_font, Gdiplus::RectF(r.X + 6 * s, r.Y + 1 * s, 28 * s, r.Height), &center,
                       &muted_brush);
        }
        g.DrawString(item.text.c_str(), -1, &item_font,
                     Gdiplus::RectF(r.X + 40 * s, r.Y, r.Width - 40 * s - 30 * s, r.Height), &format, &text_brush);
        if (item.selected) {
          const wchar_t check[2] = {kGlyphCheck, 0};
          g.DrawString(check, 1, &small_icon_font, Gdiplus::RectF(r.GetRight() - 30 * s, r.Y + 1 * s, 24 * s, r.Height),
                       &center, &orange_brush);
        }
        continue;
      }

      if (item.kind == Kind::kSwitch) {
        // Название слева, выключатель справа — как в настройках программы.
        g.DrawString(item.text.c_str(), -1, &item_font,
                     Gdiplus::RectF(r.X + 12 * s, r.Y, r.Width - 12 * s - 52 * s, r.Height), &format, &text_brush);
        const float tw = 34 * s, th = 18 * s;
        const Gdiplus::RectF track(r.GetRight() - tw - 10 * s, r.Y + (r.Height - th) / 2, tw, th);
        FillRounded(g, track, th / 2, item.selected ? Rgb(kOrange) : Rgb(p.muted, 90));
        const float knob = th - 6 * s;
        Gdiplus::SolidBrush knob_brush(item.selected ? Gdiplus::Color(255, 255, 255, 255) : Rgb(p.muted));
        g.FillEllipse(&knob_brush, item.selected ? track.GetRight() - knob - 3 * s : track.X + 3 * s, track.Y + 3 * s,
                      knob, knob);
        continue;
      }

      // Главное действие всегда оранжевое; остальные значки загораются при наведении.
      Gdiplus::SolidBrush glyph_brush(Rgb(hovered || item.accent ? accent : p.muted));
      Gdiplus::SolidBrush label_brush(Rgb(item.danger && hovered ? kRed : p.text));
      if (item.glyph == kGlyphStop) {
        // «Отключить» — закрашенный квадрат «стоп». Контурный значок из шрифта выглядел как пустая галочка.
        const float size = 11 * s;
        FillRounded(g, Gdiplus::RectF(r.X + 6 * s + (28 * s - size) / 2, r.Y + (r.Height - size) / 2, size, size),
                    2.5f * s, Rgb(hovered ? accent : p.muted));
      } else {
        const wchar_t glyph[2] = {item.glyph, 0};
        g.DrawString(glyph, 1, &icon_font, Gdiplus::RectF(r.X + 6 * s, r.Y + 1 * s, 28 * s, r.Height), &center,
                     &glyph_brush);
      }
      g.DrawString(item.text.c_str(), -1, &item_font,
                   Gdiplus::RectF(r.X + 40 * s, r.Y, r.Width - 48 * s, r.Height), &format, &label_brush);
    }

    // Полоска прокрутки списка серверов — только когда не все строки помещаются.
    const int count = static_cast<int>(m->rows.size());
    const int visible = VisibleServers(*m);
    if (count > visible && visible > 0) {
      const float area_top = static_cast<float>(m->server_area.top);
      const float area_height = static_cast<float>(m->server_area.bottom - m->server_area.top);
      const float thumb = area_height * visible / count;
      const float top = area_top + (area_height - thumb) * m->server_offset / (count - visible);
      FillRounded(g, Gdiplus::RectF(static_cast<float>(m->server_area.right) - 3 * s, top, 3 * s, thumb), 1.5f * s,
                  Rgb(p.muted, 140));
    }
  }
  // Значок программы в шапке — системной функцией, чтобы взять подходящий размер из .ico.
  if (m->icon) {
    const int size = static_cast<int>(28 * m->scale + 0.5);
    DrawIconEx(mem, static_cast<int>((kPadding + 9) * m->scale), static_cast<int>((kPadding + 14) * m->scale),
               m->icon, size, size, 0, nullptr, DI_NORMAL);
  }
  BitBlt(target, 0, 0, w, h, mem, 0, 0, SRCCOPY);
  SelectObject(mem, old);
  DeleteObject(bitmap);
  DeleteDC(mem);
}

int HitTest(const Menu& m, POINT pt) {
  for (size_t i = 0; i < m.items.size(); i++) {
    if (PtInRect(&m.items[i].rect, pt)) return static_cast<int>(i);
  }
  return -1;
}

void UpdateHover(HWND hwnd, Menu& m, POINT pt) {
  const int hover = HitTest(m, pt);
  if (hover == m.hover) return;
  m.hover = hover;
  InvalidateRect(hwnd, nullptr, FALSE);
}

LRESULT CALLBACK MenuProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* m = reinterpret_cast<Menu*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  switch (message) {
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC dc = BeginPaint(hwnd, &ps);
      Paint(hwnd, dc);
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_TIMER:
      // Плавное проявление: прозрачность растёт за несколько кадров.
      if (wparam == kFadeTimer && m) {
        m->alpha = std::min(255, m->alpha + 64);
        SetLayeredWindowAttributes(hwnd, 0, static_cast<BYTE>(m->alpha), LWA_ALPHA);
        if (m->alpha >= 255) KillTimer(hwnd, kFadeTimer);
      }
      return 0;
    case WM_MOUSEMOVE:
      if (m) {
        if (!m->tracking) {
          TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE, hwnd, 0};
          TrackMouseEvent(&track);
          m->tracking = true;
        }
        UpdateHover(hwnd, *m, POINT{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)});
      }
      return 0;
    case WM_MOUSELEAVE:
      if (m) {
        m->tracking = false;
        if (m->hover != -1) {
          m->hover = -1;
          InvalidateRect(hwnd, nullptr, FALSE);
        }
      }
      return 0;
    case WM_MOUSEWHEEL:
      // Колесо прокручивает список серверов, если они не помещаются.
      if (m) {
        const int count = static_cast<int>(m->rows.size());
        const int max_offset = count - VisibleServers(*m);
        if (max_offset > 0) {
          const int step = GET_WHEEL_DELTA_WPARAM(wparam) > 0 ? -1 : 1;
          const int offset = std::max(0, std::min(max_offset, m->server_offset + step));
          if (offset != m->server_offset) {
            m->server_offset = offset;
            Layout(*m);
            POINT pt{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
            ScreenToClient(hwnd, &pt);
            m->hover = HitTest(*m, pt);
            InvalidateRect(hwnd, nullptr, FALSE);
          }
        }
      }
      return 0;
    case WM_SETCURSOR:
      SetCursor(LoadCursor(nullptr, m && m->hover >= 0 ? IDC_HAND : IDC_ARROW));
      return TRUE;
    case WM_LBUTTONUP:
      if (m) {
        const int index = HitTest(*m, POINT{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)});
        if (index >= 0) {
          PostMessage(m->owner, m->message, m->items[index].command, 0);
          DestroyWindow(hwnd);
        }
      }
      return 0;
    case WM_KEYDOWN:
      if (wparam == VK_ESCAPE) DestroyWindow(hwnd);
      return 0;
    case WM_ACTIVATE:
      // Кликнули мимо меню или переключились в другое окно — закрываемся.
      if (LOWORD(wparam) == WA_INACTIVE) DestroyWindow(hwnd);
      return 0;
    case WM_NCDESTROY:
      if (m) {
        if (m->icon) DestroyIcon(m->icon);
        delete m;
        SetWindowLongPtr(hwnd, GWLP_USERDATA, 0);
      }
      if (g_menu == hwnd) g_menu = nullptr;
      break;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
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
  wc.style = CS_DROPSHADOW;
  wc.lpfnWndProc = MenuProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.lpszClassName = kClassName;
  RegisterClassExW(&wc);
}

}  // namespace

void ShowTrayMenu(HWND owner, UINT message, POINT pt, const TrayMenuModel& model,
                  const TrayMenuCommands& commands) {
  EnsureReady();
  if (g_menu) DestroyWindow(g_menu);

  auto menu = std::make_unique<Menu>();
  menu->owner = owner;
  menu->message = message;
  menu->model = model;
  menu->flags.resize(model.servers.size());

  // Первым идёт главное действие — подключить или отключить.
  Item toggle;
  toggle.command = commands.toggle;
  toggle.text = model.label_toggle;
  toggle.glyph = model.state == 2 ? kGlyphStop : kGlyphPlay;
  toggle.accent = model.state != 2;
  menu->items.push_back(toggle);
  for (size_t i = 0; i < model.modes.size(); i++) {
    Item mode;
    mode.kind = Kind::kMode;
    mode.command = commands.mode_base + static_cast<UINT>(i);
    mode.text = model.modes[i];
    mode.selected = static_cast<int>(i) == model.mode;
    menu->items.push_back(mode);
  }
  for (size_t i = 0; i < model.cores.size(); i++) {
    Item core;
    core.kind = Kind::kCore;
    core.command = commands.core_base + static_cast<UINT>(i);
    core.text = model.cores[i];
    core.selected = static_cast<int>(i) == model.core;
    menu->items.push_back(core);
  }
  if (model.kill_switch >= 0) {
    Item kill_switch;
    kill_switch.kind = Kind::kSwitch;
    kill_switch.command = commands.kill_switch;
    kill_switch.text = model.label_kill_switch;
    kill_switch.selected = model.kill_switch == 1;
    menu->items.push_back(kill_switch);
  }
  int selected_row = -1;
  for (size_t i = 0; i < model.servers.size(); i++) {
    // Провайдер сменился — перед сервером идёт строка с названием провайдера.
    const std::wstring& group = model.servers[i].group;
    if (!group.empty() && (i == 0 || model.servers[i - 1].group != group)) {
      menu->rows.push_back(-1 - static_cast<int>(i));
    }
    Item server;
    server.kind = Kind::kServer;
    server.command = commands.server_base + static_cast<UINT>(i);
    server.text = model.servers[i].name;
    server.server = static_cast<int>(i);
    server.row = static_cast<int>(menu->rows.size());
    server.selected = static_cast<int>(i) == model.selected_server;
    if (server.selected) selected_row = server.row;
    menu->rows.push_back(static_cast<int>(i));
    menu->items.push_back(server);
  }
  Item show;
  show.command = commands.open;
  show.text = model.label_open;
  show.glyph = kGlyphOpen;
  menu->items.push_back(show);
  Item quit;
  quit.command = commands.exit;
  quit.text = model.label_exit;
  quit.glyph = kGlyphPower;
  quit.danger = true;
  menu->items.push_back(quit);

  // Список открывается так, чтобы выбранный сервер был виден.
  const int count = static_cast<int>(menu->rows.size());
  const int visible = VisibleServers(*menu);
  if (count > visible && selected_row >= 0) {
    menu->server_offset = std::max(0, std::min(count - visible, selected_row - visible / 2));
  }

  // Масштаб того монитора, на котором открыто меню.
  HMONITOR monitor = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
  UINT dpi_x = 96, dpi_y = 96;
  if (HMODULE shcore = LoadLibraryW(L"shcore.dll")) {
    using GetDpiForMonitorFn = HRESULT(WINAPI*)(HMONITOR, int, UINT*, UINT*);
    if (auto fn = reinterpret_cast<GetDpiForMonitorFn>(GetProcAddress(shcore, "GetDpiForMonitor"))) {
      fn(monitor, 0 /* MDT_EFFECTIVE_DPI */, &dpi_x, &dpi_y);
    }
    FreeLibrary(shcore);
  }
  menu->scale = dpi_x / 96.0;
  const int width = static_cast<int>(kWidth * menu->scale + 0.5);
  const int height = Layout(*menu);
  const int icon_size = static_cast<int>(28 * menu->scale + 0.5);
  menu->icon = static_cast<HICON>(LoadImageW(GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON),
                                             IMAGE_ICON, icon_size, icon_size, LR_DEFAULTCOLOR));

  // Меню — над курсором (трей обычно внизу), правый край у курсора; за пределы рабочей области не выходит.
  MONITORINFO info{sizeof(info)};
  GetMonitorInfo(monitor, &info);
  const RECT work = info.rcWork;
  const int gap = static_cast<int>(8 * menu->scale);
  int x = pt.x - width + gap * 2;
  int y = pt.y - height - gap;
  if (y < work.top) y = pt.y + gap;
  x = std::max(static_cast<int>(work.left) + gap, std::min(x, static_cast<int>(work.right) - width - gap));
  y = std::max(static_cast<int>(work.top) + gap, std::min(y, static_cast<int>(work.bottom) - height - gap));

  HWND hwnd = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED, kClassName, L"", WS_POPUP,
                              x, y, width, height, owner, nullptr, GetModuleHandle(nullptr), nullptr);
  if (!hwnd) return;
  const bool dark = model.dark;
  SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(menu.release()));
  g_menu = hwnd;

  // Windows 11: скруглённые углы и рамка в цвет темы. В Windows 10 эти вызовы просто ничего не делают.
  const int corner = 2;  // DWMWCP_ROUND
  DwmSetWindowAttribute(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, &corner, sizeof(corner));
  const COLORREF border = PaletteFor(dark).border;
  DwmSetWindowAttribute(hwnd, 34 /* DWMWA_BORDER_COLOR */, &border, sizeof(border));

  SetLayeredWindowAttributes(hwnd, 0, 0, LWA_ALPHA);
  ShowWindow(hwnd, SW_SHOW);
  // Меню должно стать активным окном — иначе оно не узнает о клике мимо и не закроется.
  SetForegroundWindow(hwnd);
  SetTimer(hwnd, kFadeTimer, 15, nullptr);
}

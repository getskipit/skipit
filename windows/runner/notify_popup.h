#ifndef RUNNER_NOTIFY_POPUP_H_
#define RUNNER_NOTIFY_POPUP_H_

#include <windows.h>

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

// Вид уведомления — цвет отметки на значке: связь вернулась, сбой, ошибка или просто сообщение.
enum class NotifyKind { kInfo, kOk, kWarn, kError };

struct NotifyModel {
  std::wstring title;
  std::wstring text;
  NotifyKind kind = NotifyKind::kInfo;
  bool dark = true;
  COLORREF accent = RGB(0xFF, 0x5F, 0x1A);
  // Свой значок из настроек: картинки {сторона, RGBA}; пусто — значок из ресурсов exe.
  std::vector<std::pair<int, std::vector<uint8_t>>> images;
};

// Своё уведомление над треем: выезжает сбоку, прячется само через несколько секунд (пока над ним
// курсор — ждёт), закрывается крестиком или смахиванием к краю экрана. Нажатие на уведомление —
// сообщение |message| окну |owner|. Возвращает false, если показывать нельзя (игра или презентация
// во весь экран, экран заблокирован) — тогда нужно обычное уведомление Windows: его система отложит сама.
bool ShowNotifyPopup(HWND owner, UINT message, const NotifyModel& model);

// Закрывает уведомление сразу, если оно на экране.
void CloseNotifyPopup();

#endif  // RUNNER_NOTIFY_POPUP_H_

#ifndef RUNNER_SCREEN_IMAGE_H_
#define RUNNER_SCREEN_IMAGE_H_

#include <windows.h>

#include <cstdint>
#include <vector>

// Картинки для распознавания QR-кодов (lib/core/qr.dart) — в оттенках серого, построчно сверху вниз.
struct GrayImage {
  int width = 0;
  int height = 0;
  std::vector<uint8_t> pixels;
};

// Снимок всех мониторов. Окно |hide| на время снимка прячется, чтобы не закрывать код под собой.
bool CaptureScreen(HWND hide, GrayImage& out);

// Картинка из буфера обмена; false — картинки там нет.
bool ClipboardImage(HWND owner, GrayImage& out);

#endif  // RUNNER_SCREEN_IMAGE_H_

// Exercise the real native controls in a hidden, installation-free preview.
#define SKIPIT_UI_TESTS
#include "main.cpp"

#include <fstream>
#include <set>

int checkboxTextChanges = 0;
LRESULT CALLBACK ObserveCheckbox(HWND hwnd, UINT message, WPARAM wp, LPARAM lp, UINT_PTR, DWORD_PTR) {
  if (message == WM_SETTEXT) ++checkboxTextChanges;
  return DefSubclassProc(hwnd, message, wp, lp);
}

// Render only the hidden test window and its controls; never capture the desktop.
void RenderControl(HWND hwnd, HDC destination) {
  RECT bounds; GetClientRect(hwnd, &bounds);
  HDC dc = CreateCompatibleDC(destination);
  HBITMAP image = CreateCompatibleBitmap(destination, bounds.right, bounds.bottom);
  HGDIOBJ previous = SelectObject(dc, image);
  FillRect(dc, &bounds, bgBrush);
  SendMessageW(hwnd, WM_PRINTCLIENT, reinterpret_cast<WPARAM>(dc), PRF_CLIENT | PRF_ERASEBKGND);
  for (HWND child = GetWindow(hwnd, GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT)) {
    if (!(GetWindowLongPtrW(child, GWL_STYLE) & WS_VISIBLE)) continue;
    RECT childBounds; GetWindowRect(child, &childBounds);
    MapWindowPoints(nullptr, hwnd, reinterpret_cast<POINT*>(&childBounds), 2);
    HDC childDc = CreateCompatibleDC(dc);
    HBITMAP childImage = CreateCompatibleBitmap(dc, childBounds.right - childBounds.left, childBounds.bottom - childBounds.top);
    HGDIOBJ previousChild = SelectObject(childDc, childImage);
    HRGN childRegion = CreateRectRgn(0, 0, 0, 0);
    const bool hasRegion = GetWindowRgn(child, childRegion) != ERROR;
    if (hasRegion) SelectClipRgn(childDc, childRegion);
    RenderControl(child, childDc);
    const int saved = SaveDC(dc);
    if (hasRegion) { OffsetRgn(childRegion, childBounds.left, childBounds.top); ExtSelectClipRgn(dc, childRegion, RGN_AND); }
    BitBlt(dc, childBounds.left, childBounds.top, childBounds.right - childBounds.left, childBounds.bottom - childBounds.top, childDc, 0, 0, SRCCOPY);
    RestoreDC(dc, saved);
    DeleteObject(childRegion); SelectObject(childDc, previousChild); DeleteObject(childImage); DeleteDC(childDc);
  }
  BitBlt(destination, 0, 0, bounds.right, bounds.bottom, dc, 0, 0, SRCCOPY);
  SelectObject(dc, previous); DeleteObject(image); DeleteDC(dc);
}

bool SaveReview(HWND hwnd, const wchar_t* file) {
  RECT bounds; GetClientRect(hwnd, &bounds);
  HDC screen = GetDC(hwnd), dc = CreateCompatibleDC(screen);
  HBITMAP image = CreateCompatibleBitmap(screen, bounds.right, bounds.bottom);
  HGDIOBJ previous = SelectObject(dc, image);
  RenderControl(hwnd, dc);
  SelectObject(dc, previous);
  const CLSID png = {0x557cf406, 0x1a04, 0x11d3, {0x9a, 0x73, 0x00, 0x00, 0xf8, 0x1e, 0xf3, 0x2e}};
  bool saved;
  { Gdiplus::Bitmap bitmap(image, nullptr); saved = bitmap.Save(file, &png) == Gdiplus::Ok; }
  DeleteObject(image); DeleteDC(dc); ReleaseDC(hwnd, screen);
  return saved;
}

bool LicenseSurvivesParentPaint(HWND hwnd) {
  RECT bounds; GetClientRect(hwnd, &bounds);
  BITMAPINFO info{}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = bounds.right; info.bmiHeader.biHeight = -bounds.bottom;
  info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  HDC screen = GetDC(hwnd), dc = CreateCompatibleDC(screen);
  HBITMAP image = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  HGDIOBJ previous = SelectObject(dc, image);
  RenderControl(hwnd, dc);
  auto hashChildren = [&] {
    GdiFlush();
    unsigned long long hash = 14695981039346656037ull;
    auto* data = static_cast<const DWORD*>(pixels);
    for (HWND child : {heading, description, licenseViewport}) {
      RECT area; GetWindowRect(child, &area);
      MapWindowPoints(nullptr, hwnd, reinterpret_cast<POINT*>(&area), 2);
      for (LONG y = area.top; y < area.bottom; ++y)
        for (LONG x = area.left; x < area.right; ++x) { hash ^= data[y * bounds.right + x] & 0xffffff; hash *= 1099511628211ull; }
    }
    return hash;
  };
  const auto before = hashChildren();
  SendMessageW(agree, BM_CLICK, 0, 0);
  // Reproduce the background repaint that follows the checkbox event, over the existing frame.
  SendMessageW(hwnd, WM_PRINTCLIENT, reinterpret_cast<WPARAM>(dc), 0);
  const bool preserved = hashChildren() == before;
  SendMessageW(agree, BM_CLICK, 0, 0);
  SelectObject(dc, previous); DeleteObject(image); DeleteDC(dc); ReleaseDC(hwnd, screen);
  return preserved;
}

bool HeaderSurvivesErase(HWND hwnd) {
  RECT bounds; GetClientRect(hwnd, &bounds);
  BITMAPINFO info{}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = bounds.right; info.bmiHeader.biHeight = -bounds.bottom;
  info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  HDC screen = GetDC(hwnd), dc = CreateCompatibleDC(screen);
  HBITMAP image = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  HGDIOBJ previous = SelectObject(dc, image);
  RenderControl(hwnd, dc);
  auto hashHeader = [&] {
    GdiFlush(); unsigned long long hash = 14695981039346656037ull;
    auto* data = static_cast<const DWORD*>(pixels);
    for (int y = S(20); y < S(70); ++y)
      for (int x = S(25); x < S(260); ++x) { hash ^= data[y * bounds.right + x] & 0xffffff; hash *= 1099511628211ull; }
    return hash;
  };
  const auto before = hashHeader();
  SendMessageW(hwnd, WM_ERASEBKGND, reinterpret_cast<WPARAM>(dc), 0);
  const bool preserved = hashHeader() == before;
  SelectObject(dc, previous); DeleteObject(image); DeleteDC(dc); ReleaseDC(hwnd, screen);
  return preserved;
}

bool ViewportSurvivesOwnPaint() {
  RECT bounds; GetClientRect(licenseViewport, &bounds);
  BITMAPINFO info{}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = bounds.right; info.bmiHeader.biHeight = -bounds.bottom;
  info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  HDC screen = GetDC(licenseViewport), dc = CreateCompatibleDC(screen);
  HBITMAP image = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  HGDIOBJ previous = SelectObject(dc, image);
  RenderControl(licenseViewport, dc);
  RECT area; GetWindowRect(licenseContent, &area);
  MapWindowPoints(nullptr, licenseViewport, reinterpret_cast<POINT*>(&area), 2);
  HRGN contentRegion = CreateRectRgn(0, 0, 0, 0);
  const bool hasContentRegion = GetWindowRgn(licenseContent, contentRegion) != ERROR;
  auto hashContent = [&] {
    GdiFlush(); unsigned long long hash = 14695981039346656037ull;
    auto* data = static_cast<const DWORD*>(pixels);
    for (LONG y = area.top; y < area.bottom; ++y)
      for (LONG x = area.left; x < area.right; ++x) {
        if (hasContentRegion && !PtInRegion(contentRegion, x - area.left, y - area.top)) continue;
        hash ^= data[y * bounds.right + x] & 0xffffff; hash *= 1099511628211ull;
      }
    return hash;
  };
  const auto before = hashContent();
  SendMessageW(licenseViewport, WM_PRINTCLIENT, reinterpret_cast<WPARAM>(dc), 0);
  const bool preserved = hashContent() == before;
  DeleteObject(contentRegion); SelectObject(dc, previous); DeleteObject(image); DeleteDC(dc); ReleaseDC(licenseViewport, screen);
  return preserved;
}

int RunUiTests(HWND hwnd) {
  std::ofstream report("build/installer-ui-tests.txt");
  int failed = 0;
  auto check = [&](bool condition, const char* name) {
    report << (condition ? "PASS " : "FAIL ") << name << '\n';
    if (!condition) ++failed;
  };
  auto internalScroll = [] {
    POINT point{}; SendMessageW(licenseBox, EM_GETSCROLLPOS, 0, reinterpret_cast<LPARAM>(&point)); return point.y;
  };
  check(licenseHeight > LicenseViewHeight() * 5, "full license is laid out beyond the viewport");
  RECT inset; GetWindowRect(licenseContent, &inset);
  MapWindowPoints(nullptr, licenseViewport, reinterpret_cast<POINT*>(&inset), 2);
  check(GetParent(licenseBox) == licenseContent && inset.top >= S(2) && inset.bottom <= LicenseViewHeight() - S(2),
      "scrolling content is clipped away from both fixed borders");
  check(scrollOffset == 0 && internalScroll() == 0, "license starts at the beginning");
  check((GetWindowLongPtrW(licenseBox, GWL_STYLE) & (WS_VSCROLL | WS_HSCROLL)) == 0, "no native white scrollbar");
  check(!Checked(agree) && !IsWindowEnabled(next), "acceptance is required");
  check((GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_CAPTION) == 0 && IsWindowEnabled(closeButton), "own notification-style header and close button");
  check(SaveReview(hwnd, L"build/installer-license-ru.png"), "Russian license page renders");
  check(LicenseSurvivesParentPaint(hwnd), "checkbox background repaint preserves heading, description and license");
  check(HeaderSurvivesErase(hwnd), "background erase does not clear the logo and header");
  check(ViewportSurvivesOwnPaint(), "viewport repaint preserves scrolling content");
  SetWindowSubclass(agree, ObserveCheckbox, 2, 0);
  ValidateRect(hwnd, nullptr);
  SendMessageW(agree, BM_CLICK, 0, 0);
  check(Checked(agree) && IsWindowEnabled(next), "native checkbox enables Next");
  check(checkboxTextChanges == 0, "checkbox click does not reset its text");
  HRGN update = CreateRectRgn(0, 0, 0, 0);
  GetUpdateRgn(hwnd, update, FALSE);
  RECT headerArea{S(20), S(10), S(300), S(78)};
  check(!RectInRegion(update, &headerArea), "checkbox click does not invalidate the header");
  DeleteObject(update);
  RemoveWindowSubclass(agree, ObserveCheckbox, 2);
  SendMessageW(agree, BM_CLICK, 0, 0);
  check(!Checked(agree) && !IsWindowEnabled(next), "checkbox can revoke acceptance");
  SendMessageW(agree, WM_KEYDOWN, VK_SPACE, 0);
  SendMessageW(agree, WM_KEYUP, VK_SPACE, 0);
  check(Checked(agree) && IsWindowEnabled(next), "Space toggles acceptance");
  SendMessageW(agree, WM_KEYDOWN, VK_SPACE, 0);
  SendMessageW(agree, WM_KEYUP, VK_SPACE, 0);
  check(!Checked(agree) && !IsWindowEnabled(next), "Space can revoke acceptance");

  ScrollLicense(0, false);
  SendMessageW(licenseBox, WM_MOUSEWHEEL, MAKEWPARAM(0, static_cast<WORD>(-WHEEL_DELTA)), 0);
  std::set<int> positions;
  const ULONGLONG started = GetTickCount64();
  while (GetTickCount64() - started < 450) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&message); DispatchMessageW(&message); }
    RECT rect; GetWindowRect(licenseBox, &rect);
    MapWindowPoints(nullptr, licenseViewport, reinterpret_cast<POINT*>(&rect), 2);
    positions.insert(rect.top);
    Sleep(2);
  }
  report << "actual child-window positions:";
  for (int value : positions) report << ' ' << value;
  report << '\n';
  BOOL animations = TRUE; SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &animations, 0);
  check(!animations || positions.size() >= 8, "one wheel notch produces multiple intermediate pixel positions");
  check(!scrollAnimating && std::abs(scrollOffset - scrollTarget) < 0.1, "scroll animation reaches its target");
  check(internalScroll() == 0, "RichEdit does not add line-snapped internal scrolling");
  check(SaveReview(licenseViewport, L"build/installer-license-scrolled.png"), "scrolled license renders without stale copied pixels");

  ScrollLicense(0, false);
  const ULONGLONG burstStarted = GetTickCount64();
  ULONGLONG lastWheel = 0;
  int movingFrames = 0;
  double previousOffset = scrollOffset;
  while (GetTickCount64() - burstStarted < 150) {
    const ULONGLONG now = GetTickCount64();
    if (now - lastWheel >= 8) {
      SendMessageW(licenseBox, WM_MOUSEWHEEL, MAKEWPARAM(0, static_cast<WORD>(-WHEEL_DELTA / 4)), 0);
      lastWheel = now;
    }
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&message); DispatchMessageW(&message); }
    if (scrollOffset != previousOffset) { ++movingFrames; previousOffset = scrollOffset; }
    Sleep(1);
  }
  report << "moving frames during continuous wheel input: " << movingFrames << '\n';
  check(!animations || movingFrames >= 5, "continuous wheel input does not starve animation frames");
  ScrollLicense(0, false);

  ScrollLicense(MaxScroll(), false);
  POINT last{};
  SendMessageW(licenseBox, EM_POSFROMCHAR, reinterpret_cast<WPARAM>(&last), GetWindowTextLengthW(licenseBox) - 1);
  RECT child; GetWindowRect(licenseBox, &child); MapWindowPoints(nullptr, licenseViewport, reinterpret_cast<POINT*>(&child), 2);
  report << "last character in viewport: " << last.y + child.top << "; viewport height: " << LicenseViewHeight() << '\n';
  check(last.y + child.top >= 0 && last.y + child.top < LicenseViewHeight(), "end of the license remains reachable");
  SendMessageW(licenseBox, WM_KEYDOWN, VK_HOME, 0);
  ScrollLicense(0, false);

  SendMessageW(agree, BM_CLICK, 0, 0);
  SendMessageW(hwnd, WM_COMMAND, kEn, 0);
  check(ControlText(heading) == L"License agreement" && Checked(agree), "EN preserves acceptance");
  check(SaveReview(hwnd, L"build/installer-license-en.png"), "English license page renders");
  SendMessageW(hwnd, WM_COMMAND, kNext, 0);
  check(page == 1 && !IsWindowEnabled(next), "preview cannot install");
  check(SaveReview(hwnd, L"build/installer-options-en.png"), "English options page renders");
  RECT fieldBounds; GetClientRect(pathFrame, &fieldBounds);
  RECT editBounds; GetWindowRect(pathEdit, &editBounds);
  MapWindowPoints(nullptr, pathFrame, reinterpret_cast<POINT*>(&editBounds), 2);
  HDC pathDc = GetDC(pathEdit); HGDIOBJ oldFont = SelectObject(pathDc, font);
  TEXTMETRICW metrics{}; GetTextMetricsW(pathDc, &metrics);
  SelectObject(pathDc, oldFont); ReleaseDC(pathEdit, pathDc);
  const LRESULT firstCharacter = SendMessageW(pathEdit, EM_POSFROMCHAR, 0, 0);
  const int textTop = editBounds.top + static_cast<short>(HIWORD(firstCharacter));
  const int bottomGap = fieldBounds.bottom - textTop - metrics.tmHeight;
  report << "path text padding: top=" << textTop << ", bottom=" << bottomGap << '\n';
  check(std::abs(textTop - bottomGap) <= 2, "path text is vertically centered in the field");
  check((GetWindowLongPtrW(pathEdit, GWL_STYLE) & ES_MULTILINE) == 0, "path remains a single-line edit");
  HDC screen = GetDC(pathFrame); HDC render = CreateCompatibleDC(screen);
  HBITMAP image = CreateCompatibleBitmap(screen, fieldBounds.right, fieldBounds.bottom);
  HGDIOBJ oldImage = SelectObject(render, image);
  SendMessageW(pathFrame, WM_PRINT, reinterpret_cast<WPARAM>(render), PRF_CLIENT | PRF_CHILDREN | PRF_ERASEBKGND);
  SelectObject(render, oldImage);
  {
    Gdiplus::Bitmap bitmap(image, nullptr);
    const CLSID png = {0x557cf406, 0x1a04, 0x11d3, {0x9a, 0x73, 0x00, 0x00, 0xf8, 0x1e, 0xf3, 0x2e}};
    check(bitmap.Save(L"build/installer-path-field.png", &png) == Gdiplus::Ok, "path field renders to a review image");
  }
  DeleteObject(image); DeleteDC(render); ReleaseDC(pathFrame, screen);
  const auto directory = ControlText(pathEdit);
  const bool shortcut = Checked(desktop);
  SendMessageW(hwnd, WM_COMMAND, kRu, 0);
  check(ControlText(pathEdit) == directory && Checked(desktop) == shortcut, "RU preserves folder and shortcut option");
  check(SaveReview(hwnd, L"build/installer-options-ru.png"), "Russian options page renders");
  page = 3; success = true; Update();
  check(SaveReview(hwnd, L"build/installer-success-ru.png"), "success page renders");
  page = 4; success = false; failureCode = ERROR_ACCESS_DENIED; russian = false; Update();
  check(SaveReview(hwnd, L"build/installer-error-en.png"), "error page renders");
  busy = true; Update(); check(!IsWindowEnabled(closeButton), "close is disabled during installation");
  busy = false; Update(); check(IsWindowEnabled(closeButton), "close is enabled after installation");
  SendMessageW(hwnd, WM_COMMAND, kBack, 0);
  check(page == 0 && Checked(agree), "Back preserves acceptance");
  report << "failures: " << failed << '\n';
  return failed ? 1 : 0;
}

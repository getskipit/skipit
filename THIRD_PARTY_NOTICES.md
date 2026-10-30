# Сторонние компоненты

Код SkipIt распространяется по лицензии Apache-2.0 (см. [LICENSE](LICENSE) и [NOTICE](NOTICE));
версии 1.0.0 и 1.0.1 выходили под лицензией MIT.
В установщик SkipIt без изменений вложены отдельные программы со своими лицензиями.
SkipIt запускает их как самостоятельные процессы и **не связан** с их авторами и проектами.

## Xray-core

- Файл: `core\skipit-xray.exe` (оригинальный `xray.exe`, переименован)
- Лицензия: **Mozilla Public License 2.0** — https://www.mozilla.org/MPL/2.0/
  (текст лежит рядом с ядром: `core\LICENSE-Xray.txt`)
- Исходный код: https://github.com/XTLS/Xray-core

## sing-box

- Файл: `core\skipit-sing-box.exe` (оригинальный `sing-box.exe`, переименован)
- Лицензия: **GNU General Public License v3.0 или новее** — https://www.gnu.org/licenses/gpl-3.0.html
  (уведомление автора лежит рядом с ядром: `core\LICENSE-sing-box.txt`)
- Исходный код: https://github.com/SagerNet/sing-box (версия, вложенная в установщик, указана
  в SkipIt: Настройки → О программе). Архив с исходниками именно этой версии приложен к каждому
  релизу SkipIt: файл `sing-box-<версия>-source.zip` на странице релиза.
- Copyright (C) 2022 by nekohasekai. Дополнительное условие автора: производные работы
  не должны использовать название sing-box или подразумевать связь с этим проектом.
  SkipIt не является производной работой sing-box и не связан с ним.

## Flutter

- Движок и библиотеки интерфейса, встроенные в `SkipIt.exe` и `flutter_windows.dll`
- Лицензия: **BSD 3-Clause** — https://github.com/flutter/flutter/blob/master/LICENSE
- Вместе с Flutter в программу входит пакет `intl` (русские подписи встроенных элементов) —
  **BSD 3-Clause**, Copyright 2013, the Dart project authors: https://github.com/dart-lang/i18n

## Wintun

- Драйвер виртуального сетевого адаптера, используется в режиме TUN: встроен в sing-box,
  а для ядра Xray лежит отдельным файлом `core\wintun.dll` (из архива Xray-core, без изменений)
- Лицензия на готовые сборки — https://www.wintun.net (Copyright WireGuard LLC)

## Флаги стран

- Файлы `assets\flags\*.png` — https://flagcdn.com, общественное достояние.

#pragma once

#include <memory>
#include <string>
#include <vector>

// DNS по программам: см. dns_split.cpp.
struct DnsSplitConfig {
  // false — «все, кроме списка» (программы списка идут напрямую), true — «только выбранные через VPN».
  bool only_selected = false;
  unsigned short listen = 0;  // Порт посредника на 127.0.0.1: сюда ядро присылает запросы DNS программ.
  unsigned short remote = 0;  // Вход DNS ядра Xray (DNS из конфига, обычно через VPN).
  unsigned short local = 0;   // Вход Xray, который передаёт запрос местному DNS мимо VPN.
  std::vector<std::wstring> matches;  // Записи списка программ: имя, полный путь или папка (с «\» в конце).
  std::wstring session_name;          // Имя сеанса журнала событий Windows.
};

class DnsSplit;

// Запускает посредника. При ошибке — nullptr и причина в [error].
std::shared_ptr<DnsSplit> DnsSplitStart(const DnsSplitConfig& config, std::wstring& error);
void DnsSplitStop(const std::shared_ptr<DnsSplit>& split);

// Подходит ли exe по пути [path] под запись списка [match] (обе строки — в нижнем регистре, с «\»).
bool DnsSplitMatches(const std::wstring& match, const std::wstring& path);

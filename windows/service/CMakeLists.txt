cmake_minimum_required(VERSION 3.14)
project(service LANGUAGES CXX)

# Служба SkipIt (см. service.cpp): отдельный exe рядом с программой, без Flutter.
# Kill Switch — тот же код, что в оболочке окна (runner/kill_switch.cpp).
add_executable(skipit-service "service.cpp" "bypass.cpp" "../runner/kill_switch.cpp")
apply_standard_settings(skipit-service)
# Русские тексты ответов службы — в UTF-8 (без ключа компилятор переводит их в кодировку Windows-1251).
target_compile_options(skipit-service PRIVATE /utf-8)
target_include_directories(skipit-service PRIVATE "../runner")
target_link_libraries(skipit-service PRIVATE "advapi32.lib" "fwpuclnt.lib" "rpcrt4.lib" "ws2_32.lib" "iphlpapi.lib"
                      "tdh.lib")

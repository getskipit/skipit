cmake_minimum_required(VERSION 3.14)
project(service LANGUAGES CXX)

# Служба SkipIt (см. service.cpp): отдельный exe рядом с программой, без Flutter.
add_executable(skipit-service "service.cpp")
apply_standard_settings(skipit-service)
target_link_libraries(skipit-service PRIVATE "advapi32.lib")

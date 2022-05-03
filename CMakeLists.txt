# CMakeList.txt : CMake project for stellar-win, include source and define
# project specific logic here.
#
cmake_minimum_required (VERSION 3.8)
include(Z:/dev/vcpkg/scripts/buildsystems/vcpkg.cmake)
set(CURL_DIR "Z:/dev/vcpkg/installed/x64-windows/share/curl")

project ("stellar-win")

find_package(luajit CONFIG REQUIRED)
# Add source to this project's executable.
add_executable (stellar-win "stellar-win.cpp" "stellar-win.h")

# TODO: Add tests and install targets if needed.

﻿# CMakeList.txt : CMake project for stellar-win, include source and define
# project specific logic here.
#
cmake_minimum_required (VERSION 3.8)

project ("stellar-win")

set(CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake)
set(LUAJIT_BIN ${CMAKE_CURRENT_BINARY_DIR})


set(THIS_LUA_SRC ${CMAKE_BINARY_DIR}/lib/luajit/luajit-2.1/src)
set(LUA_INCLUDE_DIR ${THIS_LUA_SRC})
#TODO check osx
if(WIN32)
	if(MSVC)
		set(LUA_LIBRARY ${THIS_LUA_SRC}/lua51.lib)
	else() #mingw
		set(LUA_LIBRARY ${THIS_LUA_SRC}/lua51.dll)
	endif()
elseif(Darwin)
	set(LUA_LIBRARY ${THIS_LUA_SRC}/libluajit.dylib)
else() 
	set(LUA_LIBRARY  ${THIS_LUA_SRC}/libluajit.so)
endif()

add_subdirectory(lib/luajit)




set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
include (InstallRequiredSystemLibraries)

INSTALL(FILES ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS} DESTINATION ${LUAJIT_BIN})




# Add source to this project's executable.
add_executable (stellar-win "stellar-win.cpp" "stellar-win.h" "hooking_windows.h" "hooking_windows.cpp"  "stellaris-generic.h")
add_library (stellarstellaris SHARED "stellar-injected.cpp" "stellar-win.h" "hooking_windows.h" "hooking_windows.cpp" "stellar-injected.h" "stellaris-CGameIdler.h" "stellaris-generic.h" "lib/eigen/Eigen/core")
target_link_libraries(stellarstellaris ${LUA_LIBRARY})
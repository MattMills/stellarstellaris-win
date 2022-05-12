# CMakeList.txt : CMake project for stellar-win, include source and define
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
add_executable	( stellar-win 
					"src/stellar-win.cpp" 
					"src/hooking_windows.cpp"   
					"src/hooking_error.cpp" 
					"src/hooking_shared.cpp"
				)
add_library		( stellarstellaris SHARED 
					"src/stellar-injected.cpp" 
					"src/hooking_windows.cpp"  
					"src/hooking_asm.cpp"
					"src/hooking_error.cpp" 
					"src/hooking_shared.cpp"
				)


				
target_include_directories(stellar-win PUBLIC 
										"${CMAKE_CURRENT_SOURCE_DIR}"
										"${CMAKE_CURRENT_SOURCE_DIR}/include/"
										"lib/eigen/Eigen/"
										"lib/eigen/"
										)

										target_include_directories(stellarstellaris PUBLIC 
										"${CMAKE_CURRENT_SOURCE_DIR}"
										"${CMAKE_CURRENT_SOURCE_DIR}/include/"
										"lib/eigen/Eigen/"
										"lib/eigen/"
										)


target_link_libraries(stellarstellaris ${LUA_LIBRARY})
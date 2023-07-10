# CMakeList.txt : CMake project for stellar-win, include source and define
# project specific logic here.
#
cmake_minimum_required (VERSION 3.8)

project ("stellar-loader")

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
add_subdirectory(lib/capstone)
add_subdirectory(lib/sigmatch)


set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
include (InstallRequiredSystemLibraries)
include(cmake/CheckGit.cmake)
CheckGitSetup()


INSTALL(FILES ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS} DESTINATION ${LUAJIT_BIN})


# Add source to this project's executable.
add_executable	( stellar-loader
					"src/loader/main.cpp" 
					"src/hooking/windows.cpp"   
					"src/hooking/error.cpp" 
					"src/hooking/shared.cpp"
)
add_library		( stellar-injected SHARED 
					"src/dll/dllmain.cpp" 
					"src/dll/lua.cpp"
					"src/dll/hooking_common.cpp"
					"src/dll/address_helper.cpp"
					"src/dll/assembly_patches.cpp"
					"src/dll/ceffect.cpp"
					"src/dll/cevent.cpp"
					"src/dll/crandominlisteffect.cpp"
					"src/dll/ceveryinlisteffect.cpp"
					"src/dll/conactiondatabase.cpp"
					"src/dll/ceventscope.cpp"
					"src/dll/ctrigger.cpp"
					"src/dll/ctoken.cpp"
					"src/dll/cship.cpp"
					"src/dll/limit_once_in_x_seconds.cpp"
					"src/hooking/asm.cpp"
					"src/hooking/error.cpp" 
					"src/hooking/shared.cpp"
					"src/hooking/windows.cpp"  
				    "src/util/logging.cpp"
)


				
target_include_directories(stellar-loader PUBLIC 
										"${CMAKE_CURRENT_SOURCE_DIR}"
										"${CMAKE_CURRENT_SOURCE_DIR}/include/"
										#"${CMAKE_CURRENT_SOURCE_DIR}/include/dll/"
										#"${CMAKE_CURRENT_SOURCE_DIR}/include/hooking/"
										"lib/eigen/Eigen/"
										"lib/eigen/"
										)

target_include_directories(stellar-injected PUBLIC 
										"${CMAKE_CURRENT_SOURCE_DIR}"
										"${CMAKE_CURRENT_SOURCE_DIR}/include/"
										"${CMAKE_CURRENT_SOURCE_DIR}/include/dll/"
										#"${CMAKE_CURRENT_SOURCE_DIR}/include/hooking/"
										#"${CMAKE_CURRENT_SOURCE_DIR}/include/stellaris/"
										#"${CMAKE_CURRENT_SOURCE_DIR}/include/util/"
										"lib/eigen/Eigen/"
										"lib/eigen/"
										"lib/libzmq/include/"
										"lib/capstone/include/"
										#"lib/sigmatch/include/"
										#"lib/sigmatch/"
										)


target_link_libraries(stellar-injected ${LUA_LIBRARY})

target_link_libraries(stellar-loader git_version)
target_link_libraries(stellar-injected git_version)
target_link_libraries(stellar-injected capstone-static)
target_link_libraries(stellar-injected sigmatch)

target_compile_features(stellar-injected PRIVATE cxx_std_14)
target_compile_features(stellar-loader PRIVATE cxx_std_14)
# CMakeList.txt : CMake project for stellar-win, include source and define
# project specific logic here.
#
cmake_minimum_required (VERSION 3.16)

project ("stellar-loader")

set(CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake)

#
# LuaJIT, built as a static library and linked into stellar-injected, so the game process does not
# have to find a lua51.dll. Built from a copy, so that the submodule's work tree stays clean.
#
include(ExternalProject)
set(luajit_include_dir "${CMAKE_CURRENT_SOURCE_DIR}/lib/luajit/src")
set(luajit_dir "${CMAKE_CURRENT_BINARY_DIR}/luajit")
if (MSVC AND CMAKE_CROSSCOMPILING AND CMAKE_HOST_UNIX)
	# clang-cl on Linux (cmake/toolchain-clang-cl-xwin.cmake): msvcbuild.bat's steps, with the build
	# tools compiled by the host's C compiler. The CRT and SDK paths come from the toolchain's flags.
	set(luajit_library "${luajit_dir}/src/lua51.lib")
	find_program(LUAJIT_HOST_CC NAMES cc gcc clang REQUIRED)
	separate_arguments(luajit_target_flags UNIX_COMMAND "${CMAKE_C_FLAGS}")
	list(JOIN luajit_target_flags "|" luajit_target_flags)
	set(luajit_build_command ${CMAKE_COMMAND} "-DLUAJIT_SRC=${luajit_dir}/src" "-DHOST_CC=${LUAJIT_HOST_CC}"
		"-DCLANG_CL=${CMAKE_C_COMPILER}" "-DLLVM_LIB=${CMAKE_AR}"
		"-DTARGET_FLAGS=--target=${CMAKE_C_COMPILER_TARGET}|${luajit_target_flags}"
		-P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/luajit-cross-msvc.cmake")
	set(luajit_options LIST_SEPARATOR |)
elseif (MSVC)
	set(luajit_library "${luajit_dir}/src/lua51.lib")
	# CL=/MD: the static build would otherwise use the static C runtime (stellar-injected uses the
	# DLL one). msvcbuild.bat runs the tools it builds from the current directory, which cmd does
	# not search when NoDefaultCurrentDirectoryInExePath is set.
	set(luajit_build_command ${CMAKE_COMMAND} -E chdir "${luajit_dir}/src"
		${CMAKE_COMMAND} -E env --unset=NoDefaultCurrentDirectoryInExePath CL=/MD cmd /c msvcbuild.bat static)
else()
	set(luajit_library "${luajit_dir}/src/libluajit.a")
	set(luajit_build_command make -C "${luajit_dir}/src" BUILDMODE=static)
endif()
ExternalProject_Add(stellar_luajit
	SOURCE_DIR "${luajit_dir}"
	DOWNLOAD_COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/lib/luajit" "${luajit_dir}"
	CONFIGURE_COMMAND ""
	BUILD_COMMAND ${luajit_build_command}
	BUILD_IN_SOURCE TRUE
	INSTALL_COMMAND ""
	BUILD_BYPRODUCTS "${luajit_library}"
	${luajit_options}
)

#
# Lua bindings for stellar-fnmatch (function signatures, instruction decoding) and sigmatch (byte
# patterns), as static libraries built against the LuaJIT headers above
#
set(LUA_FNMATCH_LUA_INCLUDE_DIR "${luajit_include_dir}" CACHE PATH "" FORCE)
set(LUA_FNMATCH_BUILD_MODULE OFF CACHE BOOL "" FORCE)
if (MSVC AND CMAKE_CROSSCOMPILING AND CMAKE_HOST_UNIX)
	# The engine (Rust) for Windows x64, MSVC ABI. cargo runs through a wrapper that has cc-rs build
	# the C dependencies (zstd) with clang-cl and the toolchain's flags.
	set(LUA_FNMATCH_RUST_TARGET x86_64-pc-windows-msvc CACHE STRING "")
	find_program(STELLAR_CARGO NAMES cargo HINTS "$ENV{CARGO_HOME}/bin" "$ENV{HOME}/.cargo/bin" REQUIRED)
	separate_arguments(cargo_cross_cflags UNIX_COMMAND "${CMAKE_C_FLAGS}")
	list(JOIN cargo_cross_cflags " " cargo_cross_cflags)
	configure_file(cmake/cargo-cross-msvc.sh.in "${CMAKE_CURRENT_BINARY_DIR}/cargo-cross-msvc.sh" @ONLY)
	file(COPY "${CMAKE_CURRENT_BINARY_DIR}/cargo-cross-msvc.sh" DESTINATION "${CMAKE_CURRENT_BINARY_DIR}/cargo-cross"
		FILE_PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
	set(LUA_FNMATCH_CARGO "${CMAKE_CURRENT_BINARY_DIR}/cargo-cross/cargo-cross-msvc.sh" CACHE FILEPATH "" FORCE)
endif()
add_subdirectory(lib/lua_fnmatch)
set(LUA_SIGMATCH_LUA_INCLUDE_DIR "${luajit_include_dir}" CACHE PATH "" FORCE)
set(LUA_SIGMATCH_BUILD_MODULE OFF CACHE BOOL "" FORCE)
add_subdirectory(lib/lua_sigmatch)


set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
if (NOT (CMAKE_CROSSCOMPILING AND CMAKE_HOST_UNIX)) # it looks for Visual Studio on the host
	include (InstallRequiredSystemLibraries)
endif()
include(cmake/CheckGit.cmake)
CheckGitSetup()


#INSTALL(FILES ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS} DESTINATION ${LUAJIT_BIN})


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
					"src/dll/code_hook.cpp"
					"src/dll/lexer_hook.cpp"
					"src/dll/loading_hook.cpp"
					"src/dll/database_workers.cpp"
					"src/dll/access_trace.cpp"
					"src/dll/modifier_index.cpp"
					"src/dll/modifier_stats.cpp"
					"src/dll/modifier_shadow.cpp"
					"src/hooking/error.cpp" 
					"src/hooking/shared.cpp"
					"src/hooking/windows.cpp"  
				    "src/util/logging.cpp"
)


				
target_include_directories(stellar-loader PUBLIC 
										"${CMAKE_CURRENT_SOURCE_DIR}"
										"${CMAKE_CURRENT_SOURCE_DIR}/include/"
										)

target_include_directories(stellar-injected PUBLIC 
										"${CMAKE_CURRENT_SOURCE_DIR}"
										"${CMAKE_CURRENT_SOURCE_DIR}/include/"
										"${CMAKE_CURRENT_SOURCE_DIR}/include/dll/"
										)


target_link_libraries(stellar-loader git_version)
target_link_libraries(stellar-injected git_version)
# lua_fnmatch_engine: fnmatch_engine.h (fnme_decode, for code_hook.cpp)
target_link_libraries(stellar-injected lua_fnmatch::static lua_fnmatch_engine lua_sigmatch::static "${luajit_library}")
add_dependencies(stellar-injected stellar_luajit)

target_compile_features(stellar-injected PRIVATE cxx_std_14)
target_compile_features(stellar-loader PRIVATE cxx_std_14)

# version.dll for the game's folder: the loader that runs before the game (src/proxy). In its own
# directory, so that nothing next to the other outputs loads it by mistake.
add_library(stellar-proxy SHARED "src/proxy/version_proxy.cpp" "src/proxy/version.def")
set_target_properties(stellar-proxy PROPERTIES OUTPUT_NAME "version"
	RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/proxy"
	LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/proxy"
	ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/proxy")
target_compile_features(stellar-proxy PRIVATE cxx_std_14)

# The Lua scripts go next to stellar-injected.dll, which runs lua/init.lua, with the Lua modules of
# the submodules (pdxscript: lib/stellar-lua-pdxscript)
add_custom_command(TARGET stellar-injected POST_BUILD
	COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/lua" "$<TARGET_FILE_DIR:stellar-injected>/lua"
	COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_SOURCE_DIR}/lib/stellar-lua-pdxscript/pdxscript.lua" "$<TARGET_FILE_DIR:stellar-injected>/lua/pdxscript.lua"
	COMMENT "Copying the Lua scripts"
)
# install.ps1 (and the .bat files that run it) next to the DLL: they install it, with lua/ and
# proxy/version.dll, into the Stellaris folder, and uninstall it
add_custom_command(TARGET stellar-injected POST_BUILD
	COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_SOURCE_DIR}/install/install.ps1" "${CMAKE_CURRENT_SOURCE_DIR}/install/install.bat" "${CMAKE_CURRENT_SOURCE_DIR}/install/uninstall.bat" "$<TARGET_FILE_DIR:stellar-injected>"
	COMMENT "Copying the install scripts"
)

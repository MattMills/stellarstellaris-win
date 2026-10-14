# Cross-compiles the Windows x64 binaries (stellar-injected.dll, stellar-loader.exe and the proxy
# version.dll) on Linux: clang-cl and lld-link against the Microsoft CRT and Windows SDK that xwin
# splats. MSVC ABI (x86_64-pc-windows-msvc) with the real MS CRT, so the DLL loads into the
# MSVC-built game as the MSVC build does. The flags are CMake's MSVC ones (/EHsc, /MD, the same
# definitions), since CMake drives clang-cl as an MSVC-like compiler.
#
#   cmake -G Ninja -B build-win -DCMAKE_BUILD_TYPE=RelWithDebInfo \
#         -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-clang-cl-xwin.cmake
#
# LLVM_ROOT  an LLVM with clang-cl, lld-link, llvm-lib and llvm-rc in bin/ (llvm-mingw has them;
#            default /opt/llvm-mingw, as in the CI image)
# XWIN_ROOT  the output of `xwin splat` (default /opt/xwin)
# Both can also come from the environment. See docs/ci.md.

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_VERSION 10.0)
set(CMAKE_SYSTEM_PROCESSOR AMD64)

foreach(var LLVM_ROOT XWIN_ROOT)
	if (NOT ${var} AND DEFINED ENV{${var}})
		set(${var} "$ENV{${var}}")
	endif()
endforeach()
if (NOT LLVM_ROOT)
	set(LLVM_ROOT /opt/llvm-mingw)
endif()
if (NOT XWIN_ROOT)
	set(XWIN_ROOT /opt/xwin)
endif()
# try_compile projects read this file again: pass the two on
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES LLVM_ROOT XWIN_ROOT)

set(CMAKE_C_COMPILER "${LLVM_ROOT}/bin/clang-cl")
set(CMAKE_CXX_COMPILER "${LLVM_ROOT}/bin/clang-cl")
set(CMAKE_C_COMPILER_TARGET x86_64-pc-windows-msvc)
set(CMAKE_CXX_COMPILER_TARGET x86_64-pc-windows-msvc)
set(CMAKE_LINKER "${LLVM_ROOT}/bin/lld-link")
set(CMAKE_AR "${LLVM_ROOT}/bin/llvm-lib")
set(CMAKE_RC_COMPILER "${LLVM_ROOT}/bin/llvm-rc")

# The CRT and SDK headers as system headers (/imsvc: after clang's own, as with MSVC's INCLUDE)
set(xwin_includes "")
foreach(dir crt/include sdk/include/ucrt sdk/include/um sdk/include/shared sdk/include/winrt)
	string(APPEND xwin_includes " /imsvc \"${XWIN_ROOT}/${dir}\"")
endforeach()
set(xwin_libpaths "")
foreach(dir crt/lib/x86_64 sdk/lib/um/x86_64 sdk/lib/ucrt/x86_64)
	string(APPEND xwin_libpaths " /libpath:\"${XWIN_ROOT}/${dir}\"")
endforeach()
set(CMAKE_C_FLAGS_INIT "${xwin_includes}")
set(CMAKE_CXX_FLAGS_INIT "${xwin_includes}")
set(CMAKE_RC_FLAGS_INIT "/I \"${XWIN_ROOT}/sdk/include/um\" /I \"${XWIN_ROOT}/sdk/include/shared\"")
# CMake links through `cmake -E vs_link_*`, which embeds the default manifest with mt, and LLVM has
# no mt here: /MANIFEST:NO turns that off, and lld-link embeds the same default manifest itself (the
# last /MANIFEST wins), with the resource IDs mt uses (1 in an exe, 2 in a DLL)
set(CMAKE_EXE_LINKER_FLAGS_INIT "${xwin_libpaths} /MANIFEST:NO /MANIFEST:EMBED,ID=1")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${xwin_libpaths} /MANIFEST:NO /MANIFEST:EMBED,ID=2")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "${xwin_libpaths} /MANIFEST:NO /MANIFEST:EMBED,ID=2")
# The splat has the release CRT only (xwin splat --include-debug-libs adds the debug one, for Debug
# builds): test programs are built in Release
set(CMAKE_TRY_COMPILE_CONFIGURATION Release)

# Find programs on the host, headers and libraries in the splat only
set(CMAKE_FIND_ROOT_PATH "${XWIN_ROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

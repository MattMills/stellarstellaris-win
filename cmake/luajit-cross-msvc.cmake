# msvcbuild.bat's static x64 build (CL=/MD), for a Linux host cross-compiling with clang-cl: the
# build tools (minilua, buildvm) are compiled for the host by HOST_CC, configured for a Windows x64
# target as LuaJIT's Makefile does for its cross builds; then buildvm writes lj_vm.obj (PE/COFF,
# with the x64 unwind data) and the generated headers, and clang-cl compiles the library with
# msvcbuild.bat's flags. Run by CMakeLists.txt (ExternalProject stellar_luajit):
#
#   cmake -DLUAJIT_SRC=<copy of lib/luajit>/src -DHOST_CC=cc -DCLANG_CL=<clang-cl> -DLLVM_LIB=<llvm-lib>
#         "-DTARGET_FLAGS=--target=x86_64-pc-windows-msvc;/imsvc;<dir>;..." -P luajit-cross-msvc.cmake
#
# Output: LUAJIT_SRC/lua51.lib

foreach(var LUAJIT_SRC HOST_CC CLANG_CL LLVM_LIB)
	if (NOT ${var})
		message(FATAL_ERROR "luajit-cross-msvc.cmake: ${var} is not set")
	endif()
endforeach()

function(run)
	execute_process(COMMAND ${ARGN} WORKING_DIRECTORY "${LUAJIT_SRC}" RESULT_VARIABLE result)
	if (NOT result EQUAL 0)
		string(REPLACE ";" " " command "${ARGN}")
		message(FATAL_ERROR "LuaJIT cross build: failed (${result}): ${command}")
	endif()
endfunction()

set(all_lib lib_base.c lib_math.c lib_bit.c lib_string.c lib_table.c lib_io.c lib_os.c
	lib_package.c lib_debug.c lib_jit.c lib_ffi.c lib_buffer.c)

# Host tools. -DLUAJIT_OS/-DLUAJIT_TARGET make buildvm emit the Windows x64 VM (LuaJIT's Makefile
# passes the same when TARGET_SYS=Windows differs from the host).
run(${HOST_CC} -O2 -o minilua host/minilua.c -lm)
# msvcbuild.bat's x64 DASMFLAGS and DASC (GC64, the default)
run(./minilua ../dynasm/dynasm.lua -LN -D WIN -D JIT -D FFI -D P64 -o host/buildvm_arch.h vm_x64.dasc)
file(GLOB buildvm_sources RELATIVE "${LUAJIT_SRC}" "${LUAJIT_SRC}/host/buildvm*.c")
run(${HOST_CC} -O2 -I. -I../dynasm -DLUAJIT_OS=LUAJIT_OS_WINDOWS -DLUAJIT_TARGET=LUAJIT_ARCH_x64
	-o buildvm ${buildvm_sources})

run(./buildvm -m peobj -o lj_vm.obj)
run(./buildvm -m bcdef -o lj_bcdef.h ${all_lib})
run(./buildvm -m ffdef -o lj_ffdef.h ${all_lib})
run(./buildvm -m libdef -o lj_libdef.h ${all_lib})
run(./buildvm -m recdef -o lj_recdef.h ${all_lib})
run(./buildvm -m vmdef -o jit/vmdef.lua ${all_lib})
run(./buildvm -m folddef -o lj_folddef.h lj_opt_fold.c)

# The library: msvcbuild.bat's LJCOMPILE, with /MD as CMakeLists.txt sets through CL for MSVC
file(GLOB sources RELATIVE "${LUAJIT_SRC}" "${LUAJIT_SRC}/lj_*.c" "${LUAJIT_SRC}/lib_*.c")
list(SORT sources)
run(${CLANG_CL} ${TARGET_FLAGS} /nologo /c /O2 /W3 /D_CRT_SECURE_NO_DEPRECATE
	"/D_CRT_STDIO_INLINE=__declspec(dllexport)__inline" /MD -- ${sources})
file(GLOB objects RELATIVE "${LUAJIT_SRC}" "${LUAJIT_SRC}/lj_*.obj" "${LUAJIT_SRC}/lib_*.obj")
list(SORT objects)
run(${LLVM_LIB} /nologo /nodefaultlib /OUT:lua51.lib ${objects})

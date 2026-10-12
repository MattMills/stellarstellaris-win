// version_proxy.cpp : version.dll for the game's folder, the loader that runs before the game.
//
// stellaris.exe imports VERSION.dll, and Windows looks for it in the application's folder first: a
// version.dll there is loaded with the game, before any of the game's code runs. This one forwards
// the 17 functions of the real version.dll (System32) and, in a thread of its own, loads
// stellar-injected.dll and calls its stellar_start. The path of stellar-injected.dll is the first
// line of stellarstellaris.txt next to this file (default: stellar-injected.dll next to it).
//
// Removing version.dll (and stellarstellaris.txt) from the game's folder removes StellarStellaris.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cwchar>

namespace {

HMODULE self = nullptr;

// A function of the real version.dll (loaded on first use).
FARPROC real_function(const char* name) {
	static HMODULE real = [] {
		wchar_t path[MAX_PATH];
		const UINT n = GetSystemDirectoryW(path, MAX_PATH);
		if (n == 0 || n + 13 >= MAX_PATH) {
			return static_cast<HMODULE>(nullptr);
		}
		wcscat_s(path, L"\\version.dll");
		return LoadLibraryW(path);
	}();
	return real != nullptr ? GetProcAddress(real, name) : nullptr;
}

// The functions of version.dll take at most 8 arguments, all integers or pointers. A forwarder
// passes 8 on (the ones the caller did not pass are whatever its stack holds there, and the real
// function does not read them) and returns what the real one returns.
using Forwarded = uintptr_t(WINAPI*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t,
	uintptr_t, uintptr_t);

DWORD WINAPI start_stellar(void*) {
	// the folder of this file
	wchar_t here[MAX_PATH];
	DWORD n = GetModuleFileNameW(self, here, MAX_PATH);
	if (n == 0 || n >= MAX_PATH) {
		return 1;
	}
	wchar_t* slash = wcsrchr(here, L'\\');
	if (slash != nullptr) {
		slash[1] = L'\0';
	}

	// stellarstellaris.txt: the path of stellar-injected.dll (UTF-8, first line)
	wchar_t dll[MAX_PATH];
	swprintf_s(dll, L"%sstellar-injected.dll", here);
	wchar_t config[MAX_PATH];
	swprintf_s(config, L"%sstellarstellaris.txt", here);
	FILE* f = nullptr;
	if (_wfopen_s(&f, config, L"rb") == 0 && f != nullptr) {
		char line[MAX_PATH * 3] = {};
		if (fgets(line, sizeof(line), f) != nullptr) {
			size_t len = strlen(line);
			while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r' || line[len - 1] == ' ')) {
				line[--len] = '\0';
			}
			if (len > 0) {
				MultiByteToWideChar(CP_UTF8, 0, line, -1, dll, MAX_PATH);
			}
		}
		fclose(f);
	}

	const HMODULE module = LoadLibraryW(dll);
	if (module == nullptr) {
		OutputDebugStringW(L"version.dll (StellarStellaris): cannot load stellar-injected.dll\n");
		return 1;
	}
	const auto start = reinterpret_cast<LPTHREAD_START_ROUTINE>(GetProcAddress(module, "stellar_start"));
	if (start == nullptr) {
		OutputDebugStringW(L"version.dll (StellarStellaris): stellar-injected.dll has no stellar_start\n");
		return 1;
	}
	return start(nullptr);
}

} // namespace

#define FORWARD(name)                                                                                  \
	extern "C" uintptr_t WINAPI proxy_##name(uintptr_t a, uintptr_t b, uintptr_t c, uintptr_t d,       \
		uintptr_t e, uintptr_t f, uintptr_t g, uintptr_t h) {                                          \
		static const auto real = reinterpret_cast<Forwarded>(real_function(#name));                    \
		if (real == nullptr) {                                                                         \
			SetLastError(ERROR_PROC_NOT_FOUND);                                                        \
			return 0;                                                                                  \
		}                                                                                              \
		return real(a, b, c, d, e, f, g, h);                                                           \
	}

FORWARD(GetFileVersionInfoA)
FORWARD(GetFileVersionInfoByHandle)
FORWARD(GetFileVersionInfoExA)
FORWARD(GetFileVersionInfoExW)
FORWARD(GetFileVersionInfoSizeA)
FORWARD(GetFileVersionInfoSizeExA)
FORWARD(GetFileVersionInfoSizeExW)
FORWARD(GetFileVersionInfoSizeW)
FORWARD(GetFileVersionInfoW)
FORWARD(VerFindFileA)
FORWARD(VerFindFileW)
FORWARD(VerInstallFileA)
FORWARD(VerInstallFileW)
FORWARD(VerLanguageNameA)
FORWARD(VerLanguageNameW)
FORWARD(VerQueryValueA)
FORWARD(VerQueryValueW)

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
	if (reason == DLL_PROCESS_ATTACH) {
		self = instance;
		DisableThreadLibraryCalls(instance);
		// the thread runs once the loader lock is released, while the game starts
		const HANDLE thread = CreateThread(nullptr, 0, start_stellar, nullptr, 0, nullptr);
		if (thread != nullptr) {
			CloseHandle(thread);
		}
	}
	return TRUE;
}

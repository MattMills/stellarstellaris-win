// dllmain.cpp : stellar-injected, the DLL stellar-loader loads into the game. Everything it does is
// in Lua (src/dll/lua.cpp runs lua/init.lua); this starts it.

#define _CRT_SECURE_NO_WARNINGS

#include "dll/dllmain.h"
#include "dll/lua_runtime.h"
#include "util/logging.h"
#include "git_version.h"

#include <thread>

HANDLE hProcess;
HMODULE hModule;

BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD ul_reason_for_call, LPVOID lpvReserved) {
	if (ul_reason_for_call == DLL_PROCESS_ATTACH) {
		CLog& logger = *getLogger();
		logger << "StellarStellaris initialization git hash - " << kGitHash;
		logger.endl();

		hProcess = OpenProcess(PROCESS_ALL_ACCESS, FALSE, GetCurrentProcessId());
		hModule = GetBaseModuleForProcess(hProcess);
		logger << "Base module: " << hModule;
		logger.endl();
	}
	return true;
}

namespace {

// Runs lua/init.lua, then calls stellar.heartbeat every second.
void init_thread() {
	stellar_lua_start();
	for (uint64_t count = 1;; ++count) {
		stellar_lua_heartbeat(count);
		Sleep(1000);
	}
}

} // namespace

extern "C" __declspec(dllexport) DWORD WINAPI stellar_start(void* parameter) {
	(void)parameter;
	std::thread(init_thread).detach();
	return 0;
}

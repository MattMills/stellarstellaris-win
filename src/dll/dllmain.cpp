// dllmain.cpp : stellar-injected, the DLL stellar-loader loads into the game. Everything it does is
// in Lua (src/dll/lua.cpp runs lua/init.lua); this starts it.

#define _CRT_SECURE_NO_WARNINGS

#include "dll/dllmain.h"
#include "dll/lua_runtime.h"
#include "util/logging.h"
#include "git_version.h"

#include <atomic>
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

// Once per process: a second loader run must not start a second init thread (two heartbeats, and
// Lua hooks installed twice).
extern "C" __declspec(dllexport) DWORD WINAPI stellar_start(void* parameter) {
	(void)parameter;
	static std::atomic<bool> started{false};
	if (started.exchange(true)) {
		std::lock_guard<std::recursive_mutex> guard(stellar_lua_lock());
		CLog& logger = *getLogger();
		logger << "stellar_start: already started in this process, ignored";
		logger.endl();
		return 1;
	}
	std::thread(init_thread).detach();
	return 0;
}

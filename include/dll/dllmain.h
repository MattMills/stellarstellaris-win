#pragma once

#include "hooking/windows.h"

// The game process and its executable module (stellaris.exe), set when the DLL is loaded.
extern HANDLE hProcess;
extern HMODULE hModule;

// Run by stellar-loader in a thread of the game once the DLL is loaded: starts the init thread,
// which runs lua/init.lua and then calls stellar.heartbeat every second.
extern "C" __declspec(dllexport) DWORD WINAPI stellar_start(void* parameter);

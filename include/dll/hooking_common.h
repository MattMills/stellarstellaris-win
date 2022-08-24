#pragma once

using namespace std;
#include "dll/common.h"
#include <stdint.h>
#include <stack>

#ifdef _WIN32
#include "hooking/windows.h"
#endif

CLog* getLogger();
void PushAddress(uint64_t addr);
__declspec(noinline) void PopAddress(uint64_t trampolinePtr);
void* installHook(void* func2hook, void* funcTrampoline, void* funcPayload);

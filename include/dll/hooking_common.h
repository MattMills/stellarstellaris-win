#pragma once


#include "dll/common.h"
#include "dll/address_helper.h"
#include <stdint.h>
#include <stack>

#ifdef _WIN32
#include "hooking/windows.h"
#endif

//using namespace std;

CLog* getLogger();
void PushAddress(uint64_t addr);
__declspec(noinline) void PopAddress(uint64_t trampolinePtr);
void* installHook(void* func2hook, void* funcTrampoline, void* funcPayload);

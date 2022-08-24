#pragma once

#include <string>
#include <iostream>
#include <stdio.h>

#include "lib/luajit/src/lua.hpp"

#include <stack>
#include <vector>

#ifdef _WIN32
#include "hooking/windows.h"
#endif




extern "C" _declspec(dllexport) void PushCApplicationPtr(void** ptr, void** ptr_Base);
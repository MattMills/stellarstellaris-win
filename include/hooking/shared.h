#pragma once

#ifdef _WIN32
#include "hooking/windows_platform.h"
#endif

bool IsProcess64Bit(HANDLE process);
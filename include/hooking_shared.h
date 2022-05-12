#pragma once

#ifdef _WIN32
#include "hooking_windows_platform.h"
#endif

bool IsProcess64Bit(HANDLE process);
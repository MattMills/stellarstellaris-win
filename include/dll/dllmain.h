#pragma once

#include <string>
#include <iostream>
#include <stdio.h>



#include <vector>
#include "dll/ceffect.h"
#include "dll/cevent.h"
#include "dll/crandominlisteffect.h"

#include "dll/hooking_common.h"
#include "dll/common.h"



HANDLE hProcess;
HMODULE hModule;
CApplication* p_CApplication;
void* p_CApplication_Base;
extern enumPlatforms thisPlatform = NULL_ERR;


extern "C" _declspec(dllexport) void PushCApplicationPtr(void** ptr, void** ptr_Base);
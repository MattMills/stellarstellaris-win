#pragma once

#include <string>
#include <iostream>
#include <stdio.h>



#include <vector>
#include "dll/ceffect.h"
#include "dll/cevent.h"
#include "dll/ctrigger.h"
#include "dll/ctoken.h"
#include "dll/crandominlisteffect.h"
#include "dll/ceveryinlisteffect.h"
#include "dll/conactiondatabase.h"
#include "dll/cship.h"
#include "dll/limit_once_in_x_seconds.h"
#include "dll/assembly_patches.h"


#include "dll/hooking_common.h"
#include "dll/common.h"



HANDLE hProcess;
HMODULE hModule;
CApplication* p_CApplication;
void* p_CApplication_Base;
extern enumPlatforms thisPlatform = NULL_ERR;

enumVersions global_current_version = VERSION_NULL;
enumOperatingSystems global_current_os = OS_NULL;
enumPlatforms global_current_platform = NULL_ERR;

extern "C" _declspec(dllexport) void PushCApplicationPtr(void** ptr, void** ptr_Base);
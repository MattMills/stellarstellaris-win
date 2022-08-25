#pragma once

#ifndef DBG_PTR
#define DBG_PTR 0
#endif

#include "util/logging.h"
#include "stellaris/CApplication.h"


enum enumPlatforms {
	NULL_ERR,
	STEAM,
	GOG,
};

extern CLog logger;

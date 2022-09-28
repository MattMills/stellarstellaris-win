#pragma once
#include "dll/hooking_common.h"

intptr_t find_address_from_symbol(const char * symbol);
void init_address_map();
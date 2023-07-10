#include "lib/luajit/src/lua.hpp"
#include <string>
#include <iostream>
#include <stdio.h>
#include <stdlib.h>
#include <ctime>

#include "dll/hooking_common.h"
#include "dll/common.h"

int lua_init() {

	AllocConsole();
	freopen("CONIN$", "r", stdin);
	freopen("CONOUT$", "w", stdout);
	freopen("CONOUT$", "w", stderr);
	TCHAR szConsoleTitle[MAX_PATH];
	StringCchPrintf(szConsoleTitle, MAX_PATH, TEXT("StellarStellaris - Debug console"));
	SetConsoleTitle(szConsoleTitle);

	lua_State* L = luaL_newstate();
	luaL_openlibs(L);

	std::cout << "> ";
	while (1) {
		std::string cmd_input;
		

		while (std::getline(std::cin, cmd_input)) {
			if(cmd_input.length() == 0){
				std::cout << "> ";
				break;
			}


			int r = luaL_dostring(L, cmd_input.c_str());
			if (r == LUA_OK) {
				std::cout << std::endl << "> ";
			}
			else {
				std::string errormsg = lua_tostring(L, -1);
				std::cout << "ERROR: " << errormsg << std::endl << std::endl << "> ";
			}
		}
		
	}
	lua_close(L);
	return 0;
}

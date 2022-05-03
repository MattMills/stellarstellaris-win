// stellar-win.cpp : Defines the entry point for the application.
//

#include "stellar-win.h"
#include <stdio.h>
#include 

using namespace std;

int main()
{
	std::string cmd = "a = 7+11";

	lua_State* L = luaL_newstate();


	int r = luaL_dostring(L, cmd.c_str());
	if (r == LUA_OK) {
		lua_getglobal(L, "a");
		if (lua_isnumber(L, -1)) {
			float a_in_cpp = (float)lua_tonumber(L, -1);

		}
	} else {
		std::string errormsg = lua_tostrong(L, -1);
		std::cout << errormsg << std::endl;
	}
	cout << "Hello CMake." << endl;
	return 0;
}

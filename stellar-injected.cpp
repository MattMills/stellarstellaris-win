using namespace std;


#include "stellar-injected.h"
#include "stellaris-CApplication.h"
#include <fstream>
#include <iostream>


#define DLL_NAME "stellarstellaris.dll"

CApplication * p_CApplication;

BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD ul_reason_for_call, LPVOID lpvReserved) {
	if (ul_reason_for_call == DLL_PROCESS_ATTACH) {
		
	}
	return true;
}

extern "C" _declspec(dllexport) void PushCApplicationPtr(void** ptr) {
	p_CApplication = (CApplication *) malloc(sizeof(void*));
	p_CApplication = static_cast<CApplication *>(*ptr);

	ofstream fh;
	fh.open("Z:\output.txt");
	fh << "Hello world from inside stellarstellaris.dll: ";
	fh << p_CApplication->_Platform._str;
	fh << " ";
	fh << p_CApplication->_Name._str;
	fh << " ";
	fh << p_CApplication->_Product._str;

	fh << std::endl;
	fh.close();
	return;
}



int lua_testing() {
	lua_State* L = luaL_newstate();
	std::string cmd = "print('[LUA] hello world!')";

	int r = luaL_dostring(L, cmd.c_str());
	if (r == LUA_OK) {
		lua_getglobal(L, "a");
		if (lua_isnumber(L, -1)) {
			float a_in_cpp = (float)lua_tonumber(L, -1);

			std::cout << "a = " << a_in_cpp << std::endl;
		}
	}
	else {
		std::string errormsg = lua_tostring(L, -1);
		std::cout << errormsg << std::endl;
	}
	cout << "Hello CMake." << endl;

	lua_close(L);
	return 0;
}

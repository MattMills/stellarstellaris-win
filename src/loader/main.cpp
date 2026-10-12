// stellar-win.cpp : Defines the entry point for the application.
//



//using namespace std;


#include "loader/main.h"
#include<conio.h>

#ifdef _WIN32
#include "hooking/windows.h"
#endif
#include "git_version.h"



int main() {
    std::cout << std::endl;
    std::cout << "-------------------------------------------------------------------------------------" << std::endl;
    std::cout << "|               Stellar Stellaris Windows in-memory game patcher                    |" << std::endl;
    std::cout << "|                             Version GIT: " << kGitHash << " (pre-alpha)                      |" << std::endl;
    std::cout << "-------------------------------------------------------------------------------------" << std::endl;
    std::cout << "                            THIS IS OPEN SOURCE SOFTWARE" << std::endl;
    std::cout << std::endl;
    std::cout << std::endl;
    std::cout << "Disclaimer:" << std::endl;
    std::cout << "-------------------------------------------------------------------------------------" << std::endl;
    std::cout << "This program will patch new code into the currently running version of stellaris" << std::endl;
    std::cout << "It may have unpredictable side effects. It is not tested against multiplayer." << std::endl;
    std::cout << std::endl;
    std::cout << "It may be considered a cheating tool. Use at your own risk!" << std::endl;
    std::cout << std::endl;
    std::cout << "Stellaris is a trademark of Paradox Interactive and they definitely do not have" << std::endl;
    std::cout << "any relationship, sponsorship, endorsement, involvement or approval of this software" << std::endl;
    std::cout << std::endl;
    std::cout << "To 'undo' this software, just exit and re-open Stellaris without running this application." << std::endl << std::endl;
    std::cout << "-------------------------------------------------------------------------------------" << std::endl;
    std::cout << std::endl;


    //Find process ID of running Stellaris Process   
    DWORD processid = 0;

    while (processid == 0) {
        processid = FindPidByName("stellaris.exe");
        if (processid == 0) {
            std::cout << "Stellaris process not found, start it and I will check again in 1s, control+c to cancel" << std::endl;
            Sleep(1000);
        } else {
            std::cout << "Identified running stellaris.exe processID: " << std::dec << processid << std::endl;
        }
    }

    check(processid);


    //Open a handle to the process with ALL_ACCESS privs
    //TODO: Probably use less privs
    HANDLE hProcess = OpenProcess(PROCESS_ALL_ACCESS, FALSE, processid);    
    check(hProcess);


    HMODULE hModule = GetBaseModuleForProcess(hProcess);
    while (hModule == NULL) {
        std::cout << "Error getting base module address for process " << std::dec << processid << " sleeping for 1s, control+c to cancel" << std::endl;
        Sleep(1000);
        hModule = GetBaseModuleForProcess(hProcess);
    }
    std::cout << "Base module: " << hModule << std::endl;

    // once per game: a second injection would start a second copy of everything (restart the game
    // to load a new build)
    if (FindModuleBaseAddress(hProcess, PAYLOAD_DLL_NAME) != NULL) {
        std::cout << PAYLOAD_DLL_NAME << " is already loaded in this game, nothing to do. Restart Stellaris to load it again." << std::endl;
        std::cout << "Press any key to close this window." << std::endl;
        while (!_kbhit()) {
            Sleep(10);
        }
        return 1;
    }

    char fullPath[1024];
    GetPathToPayloadDLL(fullPath);
    InjectPayload(hProcess, fullPath);

    std::cout << "Successfully injected" << std::endl << std::endl << std::endl;
    std::cout << "YOU SHOULD CHECK THE LOG FILE FOR EACH NEW STELLARIS VERSION!" << std::endl;
    std::cout << "Press any key to close this window." << std::endl;
    while (true) {
        if (_kbhit() || IsDebuggerPresent()) {
            exit(0);
        }
        Sleep(10);
    }
    
}

// stellar-win.cpp : Defines the entry point for the application.
//



//using namespace std;


#include "loader/main.h"
#include<conio.h>

#include "stellaris/CApplication.h"

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


    HMODULE hModule = NULL;
    while (hModule == NULL) {
        hModule = GetBaseModuleForProcess(hProcess);
        std::cout << "Error getting base module address for process " << std::dec << processid << " sleeping for 1s, control+c to cancel" << std::endl;
        Sleep(1000);
    }
    std::cout << "Base module: " << hModule << std::endl;

    const char* search_value = "augustus";
    unsigned char* augustus_ptr = 0x0;

    std::cout << "Searching memory for location of CApplication struct" << std::endl;

    
    augustus_ptr = searchMemory(hProcess, search_value, MEM_PRIVATE);

    while (augustus_ptr == NULL) {
        std::cout << "Error: Unable to find search value in memory yet, waiting 1s, control+c to cancel" << std::endl;
        Sleep(1);
        augustus_ptr = searchMemory(hProcess, search_value, MEM_PRIVATE);
    }
    void* p_application = (augustus_ptr)-56;

    std::cout << "CApplication struct suspected location: 0x" << static_cast<void*>(p_application) << std::endl;

    augustus_ptr = searchMemory(hProcess, search_value, MEM_IMAGE);
    void* p_application_base = (augustus_ptr); // Location of string in executable code address space

    std::cout << "CApplication Base struct suspected location: 0x" << static_cast<void*>(p_application_base) << std::endl;
    
    CApplication * buffer = new CApplication;
    SIZE_T bytesRead;
    ReadProcessMemory(hProcess, p_application, buffer, sizeof(CApplication), &bytesRead);
    std::cout << "[DBG] bytesRead: " << bytesRead << std::endl;
    
    // Libra v3.3.4
    // Cepheus v3.4.3
    //Cepheus v3.4.5
    //"Fornax v3.5.2"
    // Orion v3.6.1
    
    std::cout << "[DBG] version string unchecked begin 0x" << static_cast<void*>(buffer->_GameVersion._szName._str._Unchecked_begin()) << std::endl;
    size_t local_distance = abs((long long)(buffer->_GameVersion._szName._str._Unchecked_begin()) - (intptr_t)buffer);
    size_t remote_distance = abs((long long)(buffer->_GameVersion._szName._str._Unchecked_begin()) - (intptr_t)p_application);

    std::cout << "[DBG] version local distance " << local_distance << std::endl;
    std::cout << "[DBG] version remote distance " << remote_distance << std::endl;

    const std::string expected_version_string = "Canis Minor v3.7.4";

    std::string version_string;

    if (local_distance < remote_distance && local_distance < 1024*1024) {
        //should be a local pointer, just access it.
        version_string = buffer->_GameVersion._szName._str;
    }else if( remote_distance < local_distance && remote_distance < (1024*1024*1024)){
        //should be a remote pointer, need to use ReadProcessMemory... 
        size_t version_string_size = buffer->_GameVersion._szName._str._Unchecked_end() - buffer->_GameVersion._szName._str._Unchecked_begin();
        char* version_buf;
        version_buf = (char*) malloc(version_string_size);

        ReadProcessMemory(hProcess, buffer->_GameVersion._szName._str._Unchecked_begin(), version_buf, version_string_size, &bytesRead);
        std::cout << "[DBG] bytesRead: " << bytesRead << std::endl;

        version_string = version_buf;
    }else {
        version_string = "INVALID_NO_SANE_VALUE";
    }


    std::cout << "Detected Stellaris version: " << version_string << std::endl;

    
    char fullPath[1024];
    GetPathToPayloadDLL(fullPath);
    InjectPayload(hProcess, fullPath, &p_application, p_application_base);

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

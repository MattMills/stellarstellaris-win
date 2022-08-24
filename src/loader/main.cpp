// stellar-win.cpp : Defines the entry point for the application.
//



using namespace std;


#include "loader/main.h"

#include "stellaris/CApplication.h"

#ifdef _WIN32
#include "hooking/windows.h"
#endif



int main() {
    std::cout << std::endl;
    std::cout << "-------------------------------------------------------------------------------------" << std::endl;
    std::cout << "|               Stellar Stellaris Windows in-memory game patcher                    |" << std::endl;
    std::cout << "|                             Version 0.TODO (pre-alpha)                            |" << std::endl;
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
        Sleep(1000);
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
    if(buffer->_GameVersion._szName._str == "Cepheus v3.4.5"){ 
        std::cout << "Detected supported Stellaris version: " << buffer->_GameVersion._szName._str << std::endl;
    }else {
        std::cout << "Note: if the version text below this line shows gibberish, or the program crashes after this line, things went really wrongly" << std::endl;
        std::cout << "Detected unsupported Stellaris version: " << buffer->_GameVersion._szName._str<< std::endl;
        exit(-2);
    }
    
    char fullPath[1024];
    GetPathToPayloadDLL(fullPath);
    InjectPayload(hProcess, fullPath, &p_application, p_application_base);

    std::cout << "Successfully injected payload? Probably?" << std::endl;
    
}

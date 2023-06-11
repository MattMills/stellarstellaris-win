#include "dll/assembly_patches.h"


extern CLog logger;
extern HANDLE hProcess;


// Overwrites -  e8 a8 46 c2 ff        CALL       NSpeciesModification::CanCreateTemplateFrom      bool CanCreateTemplateFrom(this_01,pCVar59,false,(CString *)0x0);
void do_patch_calertmanager_update(intptr_t target_address) {
	const uint8_t asmBytes[] = { 0x90, 0x90, 0x90, 0x90, 0x90 }; // NOP NOP NOP NOP NOP!

	DWORD oldProtect;
	bool err = VirtualProtectEx(hProcess, (void *) target_address, 1024, PAGE_EXECUTE_READWRITE, &oldProtect);
	check(err);
	
	memcpy((void*)target_address, &asmBytes, sizeof(asmBytes));
}


/*
* Overwrites COutlinerGroupArmy::UpdateInternal to correct funky memory size calc:
	140e26ad3 41 8b c4        MOV        EAX, R12D
	140e26ad6 41 0f af c4     IMUL       EAX, R12D
*/
void do_patch_coutlinergrouparmy_updateinternal(intptr_t target_address) {
	const uint8_t asmBytes[] = { 
		0x48, 0x33, 0xC0, //xor rax, rax
		0x41, 0x8B, 0xC4, //mov eax, r12d
		0x90 // nop
	}; 

	DWORD oldProtect;
	bool err = VirtualProtectEx(hProcess, (void*)target_address, 1024, PAGE_EXECUTE_READWRITE, &oldProtect);
	check(err);

	memcpy((void*)target_address, &asmBytes, sizeof(asmBytes));
}

void assembly_patches_init(enumPlatforms thisPlatform, intptr_t p_CApplication_Base, intptr_t base_augustus_ptr) {
	CLog& logger = *getLogger();
	intptr_t base_ptr = 0x0;
	intptr_t this_ptr = 0x0;

	base_ptr = find_address_from_symbol("CAlertManager::Update_asm_target_1");
	this_ptr = (intptr_t)p_CApplication_Base + (base_ptr - base_augustus_ptr);

	do_patch_calertmanager_update(this_ptr);

	base_ptr = find_address_from_symbol("COutlinerGroupArmy::UpdateInternal_asm_target_1");
	this_ptr = (intptr_t)p_CApplication_Base + (base_ptr - base_augustus_ptr);
	do_patch_coutlinergrouparmy_updateinternal(this_ptr);

}
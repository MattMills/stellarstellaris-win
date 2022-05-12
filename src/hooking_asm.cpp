
#include "hooking_asm.h"

uint32_t WriteMovToRCX(uint8_t* dst, uint64_t val) {
	check(IsProcess64Bit(GetCurrentProcess()));

	uint8_t movAsmBytes[] =
	{
		0x48, 0xB9, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, //movabs 64 bit value into rcx
	};
	memcpy(&movAsmBytes[2], &val, sizeof(uint64_t));
	memcpy(dst, &movAsmBytes, sizeof(movAsmBytes));

	return sizeof(movAsmBytes);

}

uint32_t WriteSaveArgumentRegisters(uint8_t* dst) {
	uint8_t asmBytes[] =
	{
		0x51, //push rcx
		0x52, //push rdx
		0x41, 0x50, //push r8
		0x41, 0x51, //push r9
		0x48, 0x83, 0xEC, 0x40, //sub rsp, 64 -> space for xmm registers
		0x0F, 0x11, 0x04, 0x24, // movups xmmword ptr [rsp],xmm0
		0x0F, 0x11, 0x4C, 0x24, 0x10, //movups xmmword ptr [rsp+10h],xmm1
		0x0F, 0x11, 0x54, 0x24, 0x20, //movups xmmword ptr [rsp+20h],xmm2
		0x0F, 0x11, 0x5C, 0x24, 0x30 //movups  xmmword ptr [rsp+30h],xmm3
	};

	memcpy(dst, &asmBytes, sizeof(asmBytes));
	return sizeof(asmBytes);
}

uint32_t WriteRestoreArgumentRegisters(uint8_t* dst) {

	uint8_t asmBytes[] =
	{
		0x0F, 0x10, 0x04, 0x24, //movups xmm0,xmmword ptr[rsp]
		0x0F, 0x10, 0x4C, 0x24, 0x10,//movups xmm1,xmmword ptr[rsp + 10h]
		0x0F, 0x10, 0x54, 0x24, 0x20,//movups xmm2,xmmword ptr[rsp + 20h]
		0x0F, 0x10, 0x5C, 0x24, 0x30,//movups xmm3,xmmword ptr[rsp + 30h]
		0x48, 0x83, 0xC4, 0x40,//add rsp,40h
		0x41, 0x59,//pop r9
		0x41, 0x58,//pop r8
		0x5A,//pop rdx
		0x59 //pop rcx
	};

	memcpy(dst, &asmBytes, sizeof(asmBytes));
	return sizeof(asmBytes);
}

uint32_t WriteAddRSP32(uint8_t* dst) {
	uint8_t addAsmBytes[] =
	{
		0x48, 0x83, 0xC4, 0x20
	};
	memcpy(dst, &addAsmBytes, sizeof(addAsmBytes));
	return sizeof(addAsmBytes);
}

uint32_t WriteSubRSP32(uint8_t* dst) {
	uint8_t subAsmBytes[] =
	{
		0x48, 0x83, 0xEC, 0x20
	};
	memcpy(dst, &subAsmBytes, sizeof(subAsmBytes));
	return sizeof(subAsmBytes);
}

uint32_t WriteAbsoluteCall64(uint8_t* dst, void* funcToCall) {
	check(IsProcess64Bit(GetCurrentProcess()));

	uint8_t callAsmBytes[] =
	{
		0x49, 0xBA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, //movabs 64 bit value into r10
		0x41, 0xFF, 0xD2, //call r10
	};
	memcpy(&callAsmBytes[2], &funcToCall, sizeof(void*));
	memcpy(dst, &callAsmBytes, sizeof(callAsmBytes));

	return sizeof(callAsmBytes);
}

uint32_t WriteAbsoluteJump64(void* absJumpMemory, void* addrToJumpTo) {
	check(IsProcess64Bit(GetCurrentProcess()));

	//this writes the absolute jump instructions into the memory allocated near the target
	//the E9 jump installed in the target function (GetNum) will jump to here
	uint8_t absJumpInstructions[] = { 0x49, 0xBA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, //mov 64 bit value into r10
										0x41, 0xFF, 0xE2 }; //jmp r10

	uint64_t addrToJumpTo64 = (uint64_t)addrToJumpTo;
	memcpy(&absJumpInstructions[2], &addrToJumpTo64, sizeof(addrToJumpTo64));
	memcpy(absJumpMemory, absJumpInstructions, sizeof(absJumpInstructions));
	return sizeof(absJumpInstructions);
}

uint32_t WriteAbsoluteJump64(HANDLE process, void* absJumpMemory, void* addrToJumpTo) {
	check(IsProcess64Bit(process));

	//this writes the absolute jump instructions into the memory allocated near the target
	//the E9 jump installed in the target function (GetNum) will jump to here
	uint8_t absJumpInstructions[] = { 0x49, 0xBA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, //mov 64 bit value into r10
											0x41, 0xFF, 0xE2 }; //jmp r10

	uint64_t addrToJumpTo64 = (uint64_t)addrToJumpTo;
	memcpy(&absJumpInstructions[2], &addrToJumpTo64, sizeof(addrToJumpTo64));

	WriteProcessMemory(process, absJumpMemory, absJumpInstructions, sizeof(absJumpInstructions), nullptr);
	return sizeof(absJumpInstructions);
}

uint32_t WriteRelativeJump(void* func2hook, void* jumpTarget) {
	uint8_t jmpInstruction[5] = { 0xE9, 0x0, 0x0, 0x0, 0x0 };

	int64_t relativeToJumpTarget64 = (int64_t)jumpTarget - ((int64_t)func2hook + 5);
	check(relativeToJumpTarget64 < INT32_MAX);

	int32_t relativeToJumpTarget = (int32_t)relativeToJumpTarget64;

	memcpy(jmpInstruction + 1, &relativeToJumpTarget, 4);

	DWORD oldProtect;
	bool err = VirtualProtect(func2hook, 1024, PAGE_EXECUTE_READWRITE, &oldProtect);
	check(err);

	memcpy(func2hook, jmpInstruction, sizeof(jmpInstruction));
	return sizeof(jmpInstruction);

}

uint32_t WriteRelativeJump(void* func2hook, void* jumpTarget, uint8_t numTrailingNOPs) {
	uint8_t jmpInstruction[5] = { 0xE9, 0x0, 0x0, 0x0, 0x0 };

	int64_t relativeToJumpTarget64 = (int64_t)jumpTarget - ((int64_t)func2hook + 5);
	check(relativeToJumpTarget64 < INT32_MAX);

	int32_t relativeToJumpTarget = (int32_t)relativeToJumpTarget64;

	memcpy(jmpInstruction + 1, &relativeToJumpTarget, 4);

	DWORD oldProtect;
	bool err = VirtualProtect(func2hook, 1024, PAGE_EXECUTE_READWRITE, &oldProtect);
	check(err);

	memcpy(func2hook, jmpInstruction, sizeof(jmpInstruction));

	uint8_t* byteFunc2Hook = (uint8_t*)func2hook;
	for (int i = 0; i < numTrailingNOPs; ++i) {
		memset((void*)(byteFunc2Hook + 5 + i), 0x90, 1);
	}

	return sizeof(jmpInstruction) + numTrailingNOPs;
}


uint32_t WriteRelativeJump(HANDLE process, void* func2hook, void* jumpTarget) {
	uint8_t jmpInstruction[5] = { 0xE9, 0x0, 0x0, 0x0, 0x0 };

	int64_t relativeToJumpTarget64 = (int64_t)jumpTarget - ((int64_t)func2hook + 5);
	check(relativeToJumpTarget64 < INT32_MAX);

	int32_t relativeToJumpTarget = (int32_t)relativeToJumpTarget64;

	memcpy(jmpInstruction + 1, &relativeToJumpTarget, 4);

	DWORD oldProtect;
	bool err = VirtualProtectEx(process, func2hook, 1024, PAGE_EXECUTE_READWRITE, &oldProtect);
	check(err);

	err = WriteProcessMemory(process, func2hook, jmpInstruction, sizeof(jmpInstruction), nullptr);
	check(err);

	return sizeof(jmpInstruction);
}


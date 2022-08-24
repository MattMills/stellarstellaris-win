#pragma once

#include <string>
#include <iostream>
#include <stdio.h>


#include "lib/capstone/include/capstone/x86.h"
#include "lib/capstone/include/capstone/capstone.h"
#include <vector>

#ifdef _WIN32
#include "hooking/windows_platform.h"
#endif

#include "hooking/error.h"
#include "hooking/shared.h"

#if _WIN64
typedef uint64_t addr_t;
#else 
typedef uint32_t addr_t;
#endif

struct X64Instructions
{
	cs_insn* instructions;
	uint32_t numInstructions;
	uint32_t numBytes;
};
X64Instructions StealBytes(void* function);
bool IsRelativeJump(cs_insn& inst);
bool IsRelativeCall(cs_insn& inst);
bool IsRIPRelativeInstr(cs_insn& inst);
template<class T> T GetDisplacement(cs_insn* inst, uint8_t offset);
void RelocateInstruction(cs_insn* inst, void* dstLocation);
void RewriteStolenJumpInstruction(cs_insn* instr, uint8_t* instrPtr, uint8_t* absTableEntry);
void RewriteStolenCallInstruction(cs_insn* instr, uint8_t* instrPtr, uint8_t* absTableEntry);
uint32_t AddJmpToAbsTable(cs_insn& jmp, uint8_t* absTableMem);
uint32_t AddCallToAbsTable(cs_insn& call, uint8_t* absTableMem, uint8_t* jumpBackToHookedFunc);
uint32_t BuildTrampoline(void* func2hook, void* dstMemForTrampoline);

uint32_t WriteMovToRCX(uint8_t* dst, uint64_t val);
uint32_t WriteSaveArgumentRegisters(uint8_t* dst);
uint32_t WriteRestoreArgumentRegisters(uint8_t* dst);
uint32_t WriteAddRSP32(uint8_t* dst);
uint32_t WriteSubRSP32(uint8_t* dst);
uint32_t WriteAbsoluteCall64(uint8_t* dst, void* funcToCall);
uint32_t WriteAbsoluteJump64(void* absJumpMemory, void* addrToJumpTo);
uint32_t WriteAbsoluteJump64(HANDLE process, void* absJumpMemory, void* addrToJumpTo);
uint32_t WriteRelativeJump(void* func2hook, void* jumpTarget);
uint32_t WriteRelativeJump(void* func2hook, void* jumpTarget, uint8_t numTrailingNOPs);
uint32_t WriteRelativeJump(HANDLE process, void* func2hook, void* jumpTarget);


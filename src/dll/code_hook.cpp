// code_hook.cpp : function hooks that can be installed while the game runs.
//
// Unlike installHook (hooking_common.cpp), which rewrites the start of the target in several steps
// and needs the other threads suspended, the target changes in one atomic 8-byte store: its first
// 5 bytes become a jmp to a relay next to it, which jumps to the replacement. The instructions the
// jmp covers move unchanged to a trampoline, followed by a jump back to the rest of the target.
//
// A thread that is between two of the moved instructions when the jmp lands would resume in the
// middle of the jmp, so the moved instructions should be one instruction of 5 bytes or more (a
// function prologue like `mov [rsp+0x10], rbx`). Otherwise the hook still works, but only if no
// thread is there at that moment.

#include "dll/code_hook.h"
#include "hooking/asm.h"
#include "hooking/windows.h"

#include <cstdint>
#include <cstring>

namespace {

// Instructions the trampoline cannot run from another address.
bool movable(csh cs, cs_insn& instruction) {
	return !(cs_insn_group(cs, &instruction, CS_GRP_JUMP) || cs_insn_group(cs, &instruction, CS_GRP_CALL)
		|| cs_insn_group(cs, &instruction, CS_GRP_RET) || cs_insn_group(cs, &instruction, CS_GRP_INT)
		|| cs_insn_group(cs, &instruction, CS_GRP_IRET) || cs_insn_group(cs, &instruction, CS_GRP_BRANCH_RELATIVE)
		|| IsRIPRelativeInstr(instruction));
}

// How many bytes of whole instructions at the start of `code` (at `address`) cover 5 bytes, or 0.
size_t bytes_to_move(const uint8_t* code, size_t size, uint64_t address, const char** error) {
	csh cs;
	if (cs_open(CS_ARCH_X86, CS_MODE_64, &cs) != CS_ERR_OK) {
		*error = "capstone: cs_open failed";
		return 0;
	}
	cs_option(cs, CS_OPT_DETAIL, CS_OPT_ON);
	cs_insn* instructions = nullptr;
	const size_t count = cs_disasm(cs, code, size, address, 0, &instructions);
	size_t moved = 0;
	for (size_t i = 0; i < count && moved < 5; ++i) {
		if (!movable(cs, instructions[i])) {
			*error = "the first instructions of the target are relative to RIP or transfer control";
			moved = 0;
			break;
		}
		moved += instructions[i].size;
	}
	if (count > 0) {
		cs_free(instructions, count);
	}
	cs_close(&cs);
	if (moved < 5 && *error == nullptr) {
		*error = "cannot decode the first instructions of the target";
	}
	return moved >= 5 ? moved : 0;
}

} // namespace

bool install_code_hook(void* target_pointer, void* replacement, void** original, const char** error) {
	uint8_t* target = static_cast<uint8_t*>(target_pointer);
	*error = nullptr;

	uint8_t code[32];
	SIZE_T read = 0;
	if (!ReadProcessMemory(GetCurrentProcess(), target, code, sizeof(code), &read) || read != sizeof(code)) {
		*error = "cannot read the target";
		return false;
	}
	if (code[0] == 0xE9 || code[0] == 0xEB) {
		*error = "the target starts with a jmp (hooked already?)";
		return false;
	}
	const size_t moved = bytes_to_move(code, sizeof(code), reinterpret_cast<uint64_t>(target), error);
	if (moved == 0) {
		return false;
	}

	// the 5-byte jmp has to land in one aligned 8-byte word
	uint8_t* word = reinterpret_cast<uint8_t*>(reinterpret_cast<uintptr_t>(target) & ~uintptr_t(7));
	const size_t offset = static_cast<size_t>(target - word);
	if (offset + 5 > 8) {
		*error = "the target is not aligned so that the jmp can be written at once";
		return false;
	}

	// relay at +0, trampoline at +16, in a page within reach of a rel32 jmp
	uint8_t* page = static_cast<uint8_t*>(AllocatePageNearAddress(target));
	if (page == nullptr) {
		*error = "no free page near the target";
		return false;
	}
	const int64_t distance = reinterpret_cast<int64_t>(page) - reinterpret_cast<int64_t>(target + 5);
	if (distance < INT32_MIN || distance > INT32_MAX) {
		VirtualFree(page, 0, MEM_RELEASE);
		*error = "the page near the target is out of reach";
		return false;
	}
	WriteAbsoluteJump64(page, replacement);
	uint8_t* trampoline = page + 16;
	std::memcpy(trampoline, code, moved);
	WriteAbsoluteJump64(trampoline + moved, target + moved);
	DWORD protect = 0;
	VirtualProtect(page, 4096, PAGE_EXECUTE_READ, &protect);
	FlushInstructionCache(GetCurrentProcess(), page, 4096);

	// the jmp; the replacement can run as soon as it is written
	*original = trampoline;
	if (!VirtualProtect(word, 8, PAGE_EXECUTE_READWRITE, &protect)) {
		VirtualFree(page, 0, MEM_RELEASE);
		*original = nullptr;
		*error = "VirtualProtect failed on the target";
		return false;
	}
	const int64_t before = *reinterpret_cast<volatile int64_t*>(word);
	if (std::memcmp(reinterpret_cast<const uint8_t*>(&before) + offset, code, 8 - offset) != 0) {
		DWORD ignored = 0;
		VirtualProtect(word, 8, protect, &ignored);
		VirtualFree(page, 0, MEM_RELEASE);
		*original = nullptr;
		*error = "the target changed while the hook was prepared";
		return false;
	}
	int64_t after = before;
	uint8_t* bytes = reinterpret_cast<uint8_t*>(&after) + offset;
	const int32_t rel32 = static_cast<int32_t>(distance);
	bytes[0] = 0xE9;
	std::memcpy(bytes + 1, &rel32, 4);
	const bool written = InterlockedCompareExchange64(reinterpret_cast<volatile LONG64*>(word), after, before) == before;
	DWORD ignored = 0;
	VirtualProtect(word, 8, protect, &ignored);
	FlushInstructionCache(GetCurrentProcess(), word, 8);
	if (!written) {
		VirtualFree(page, 0, MEM_RELEASE);
		*original = nullptr;
		*error = "the target changed while the hook was installed";
		return false;
	}
	return true;
}

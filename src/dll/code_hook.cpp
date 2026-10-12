// code_hook.cpp : function hooks that can be installed while the game runs.
//
// The target changes in one atomic 8-byte store: its first 5 bytes become a jmp to a relay next to
// it, which jumps to the replacement. The instructions the jmp covers move to a trampoline (those
// relative to RIP with their displacement rewritten), followed by a jump back to the rest of the
// target; the other threads keep running.
//
// A thread that is between two of the moved instructions when the jmp lands would resume in the
// middle of the jmp, so the moved instructions should be one instruction of 5 bytes or more (a
// function prologue like `mov [rsp+0x10], rbx`). Otherwise the hook still works, but only if no
// thread is there at that moment.

#include "dll/code_hook.h"
#include "hooking/windows.h"

#include <fnmatch_engine.h>

#include <cstdint>
#include <cstring>

namespace {

// An instruction moved to the trampoline whose memory operand is relative to RIP: its 32-bit
// displacement is rewritten for the new place
struct Relocation {
	size_t offset;    // of the instruction in the moved bytes
	uint32_t length;
	uint64_t target;  // the address its operand refers to
};

// How many bytes of whole instructions at the start of `code` (at `address`) cover 5 bytes, or 0.
// Instructions that transfer control cannot run from the trampoline; those relative to RIP can,
// once relocated (`relocations`, at most 4).
size_t bytes_to_move(const uint8_t* code, size_t size, uint64_t address, Relocation* relocations, size_t* count,
	const char** error) {
	size_t moved = 0;
	*count = 0;
	while (moved < 5) {
		fnme_instruction instruction{};
		const uint32_t length = fnme_decode(code + moved, size - moved, address + moved, &instruction, nullptr, 0);
		if (length == 0) {
			*error = "cannot decode the first instructions of the target";
			return 0;
		}
		if (instruction.flow != FNME_FLOW_NEXT) {
			*error = "the first instructions of the target transfer control";
			return 0;
		}
		if (instruction.rip_relative) {
			if (*count >= 4) {
				*error = "too many instructions relative to RIP at the start of the target";
				return 0;
			}
			relocations[(*count)++] = Relocation{moved, length, instruction.target};
		}
		moved += length;
	}
	return moved;
}

// Rewrites the displacement of a relocated instruction now at `at` (its bytes as they were at
// `from`). The displacement is the 4 bytes of the instruction that hold target - (from + length);
// the instruction decoded at its new place must refer to the same target.
bool relocate(uint8_t* at, uint64_t from, const Relocation& r, const char** error) {
	const int64_t old_disp = static_cast<int64_t>(r.target) - static_cast<int64_t>(from + r.length);
	const int64_t new_disp = static_cast<int64_t>(r.target) - static_cast<int64_t>(reinterpret_cast<uint64_t>(at) + r.length);
	if (new_disp < INT32_MIN || new_disp > INT32_MAX) {
		*error = "an instruction relative to RIP cannot reach its operand from the trampoline";
		return false;
	}
	const int32_t old32 = static_cast<int32_t>(old_disp), new32 = static_cast<int32_t>(new_disp);
	int found = -1;
	for (int i = static_cast<int>(r.length) - 4; i >= 1; --i) {
		if (std::memcmp(at + i, &old32, 4) == 0) {
			if (found >= 0) {
				*error = "the displacement of an instruction relative to RIP is ambiguous";
				return false;
			}
			found = i;
		}
	}
	if (found < 0) {
		*error = "cannot find the displacement of an instruction relative to RIP";
		return false;
	}
	std::memcpy(at + found, &new32, 4);
	fnme_instruction check{};
	if (fnme_decode(at, r.length, reinterpret_cast<uint64_t>(at), &check, nullptr, 0) != r.length || check.target != r.target) {
		*error = "a relocated instruction does not refer to its operand";
		return false;
	}
	return true;
}

// `jmp [rip+0]` followed by the address: 14 bytes.
void write_absolute_jump(uint8_t* at, const void* to) {
	const uint8_t jmp[] = {0xFF, 0x25, 0x00, 0x00, 0x00, 0x00};
	const uint64_t target = reinterpret_cast<uint64_t>(to);
	std::memcpy(at, jmp, sizeof(jmp));
	std::memcpy(at + sizeof(jmp), &target, sizeof(target));
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
	Relocation relocations[4];
	size_t relocation_count = 0;
	const size_t moved = bytes_to_move(code, sizeof(code), reinterpret_cast<uint64_t>(target), relocations,
		&relocation_count, error);
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
	write_absolute_jump(page, replacement);
	uint8_t* trampoline = page + 16;
	std::memcpy(trampoline, code, moved);
	for (size_t i = 0; i < relocation_count; ++i) {
		const Relocation& r = relocations[i];
		if (!relocate(trampoline + r.offset, reinterpret_cast<uint64_t>(target) + r.offset, r, error)) {
			VirtualFree(page, 0, MEM_RELEASE);
			return false;
		}
	}
	write_absolute_jump(trampoline + moved, target + moved);
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

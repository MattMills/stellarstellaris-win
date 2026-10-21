// code_hook.cpp : function hooks that can be installed while the game runs.
//
// The target changes in one atomic 8-byte store: its first 5 bytes become a jmp to a relay next to
// it, which jumps to the replacement. The instructions the jmp covers move to a trampoline (those
// relative to RIP with their displacement rewritten, a near call made absolute), followed by a
// jump back to the rest of the target; the other threads keep running.
//
// A thread that is between two of the moved instructions when the jmp lands would resume in the
// middle of the jmp, so the moved instructions should be one instruction of 5 bytes or more (a
// function prologue like `mov [rsp+0x10], rbx`). Otherwise the hook still works, but only if no
// thread is there at that moment.
//
// Relays and trampolines share memory: each hook takes a slot of 128 bytes in a 64 KB block within
// reach of a rel32 jmp from its target, so that thousands of hooks (the profiler's) take a few
// blocks. Installing makes no heap allocation: the profiler installs its hooks while every other
// thread is suspended, and one of them may hold the heap's lock.

#include "dll/code_hook.h"
#include "hooking/windows.h"

#include <fnmatch_engine.h>

#include <cstdint>
#include <cstring>
#include <mutex>

namespace {

const size_t kSlotSize = 128;         // the relay (16 bytes), then the trampoline (at most 110)
const size_t kBlockSize = 64 * 1024;  // the allocation granularity of Windows
const size_t kMaxBlocks = 1024;

struct Block {
	uint8_t* base;
	size_t used;
};
Block blocks[kMaxBlocks];
size_t block_count = 0;

std::mutex& slot_lock() {
	static std::mutex lock;
	return lock;
}

// whether a rel32 jmp at `from` (its end) reaches all of [to, to + size)
bool in_reach(const uint8_t* from, const uint8_t* to, size_t size) {
	const int64_t low = reinterpret_cast<int64_t>(to) - reinterpret_cast<int64_t>(from);
	const int64_t high = low + static_cast<int64_t>(size);
	return low >= INT32_MIN && high <= INT32_MAX;
}

// A block with a free slot within reach of the jmp at `target` (a new one if none), or null. The
// slot is block->base + block->used; the caller adds kSlotSize to `used` once the hook is in.
// Holds slot_lock().
Block* block_near(uint8_t* target) {
	for (size_t i = 0; i < block_count; ++i) {
		if (blocks[i].used + kSlotSize <= kBlockSize && in_reach(target + 5, blocks[i].base, kBlockSize)) {
			return &blocks[i];
		}
	}
	if (block_count == kMaxBlocks) {
		return nullptr;
	}
	// the nearest free 64 KB, above or below the target
	const uintptr_t start = reinterpret_cast<uintptr_t>(target) & ~uintptr_t(kBlockSize - 1);
	for (uintptr_t step = kBlockSize; step < 0x7FFF0000u; step += kBlockSize) {
		const uintptr_t candidates[] = {start + step, start > step ? start - step : 0};
		for (uintptr_t candidate : candidates) {
			if (candidate == 0 || !in_reach(target + 5, reinterpret_cast<uint8_t*>(candidate), kBlockSize)) {
				continue;
			}
			void* base = VirtualAlloc(reinterpret_cast<void*>(candidate), kBlockSize, MEM_RESERVE | MEM_COMMIT,
				PAGE_EXECUTE_READ);
			if (base != nullptr) {
				blocks[block_count] = Block{static_cast<uint8_t*>(base), 0};
				return &blocks[block_count++];
			}
		}
	}
	return nullptr;
}

// An instruction moved to the trampoline
struct Relocation {
	size_t offset;      // of the instruction in the moved bytes
	uint32_t length;
	uint64_t target;    // the address its operand refers to, or its call's target
	bool rip_relative;  // its 32-bit displacement is rewritten for the new place
	bool call;          // a near call: made absolute
};

const size_t kMaxMoved = 6;

// How many bytes of whole instructions at the start of `code` (at `address`) cover 5 bytes, or 0;
// the instructions in `moved` (at most kMaxMoved). Those relative to RIP and near calls can run
// from the trampoline once relocated; other transfers of control cannot.
size_t bytes_to_move(const uint8_t* code, size_t size, uint64_t address, Relocation* moved, size_t* count,
	const char** error) {
	size_t bytes = 0;
	*count = 0;
	while (bytes < 5) {
		fnme_instruction instruction{};
		const uint32_t length = fnme_decode(code + bytes, size - bytes, address + bytes, &instruction, nullptr, 0);
		if (length == 0) {
			*error = "cannot decode the first instructions of the target";
			return 0;
		}
		const bool call = instruction.flow == FNME_FLOW_CALL && instruction.target != 0;
		const bool indirect_call = instruction.flow == FNME_FLOW_INDIRECT_CALL;
		if (instruction.flow != FNME_FLOW_NEXT && !call && !indirect_call) {
			*error = "the first instructions of the target transfer control";
			return 0;
		}
		if (*count >= kMaxMoved) {
			*error = "too many instructions at the start of the target";
			return 0;
		}
		moved[(*count)++] = Relocation{bytes, length, instruction.target, instruction.rip_relative != 0, call};
		bytes += length;
	}
	return bytes;
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
	Relocation instructions[kMaxMoved];
	size_t instruction_count = 0;
	const size_t moved = bytes_to_move(code, sizeof(code), reinterpret_cast<uint64_t>(target), instructions,
		&instruction_count, error);
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

	// relay at +0, trampoline at +16, in a slot within reach of a rel32 jmp; the slot is taken (its
	// block's `used` advanced) only once the hook is in
	std::lock_guard<std::mutex> guard(slot_lock());
	Block* block = block_near(target);
	if (block == nullptr) {
		*error = "no free memory near the target";
		return false;
	}
	uint8_t* page = block->base + block->used;
	const int64_t distance = reinterpret_cast<int64_t>(page) - reinterpret_cast<int64_t>(target + 5);
	DWORD protect = 0;
	if (!VirtualProtect(page, kSlotSize, PAGE_EXECUTE_READWRITE, &protect)) {
		*error = "VirtualProtect failed on the hook's slot";
		return false;
	}
	write_absolute_jump(page, replacement);
	uint8_t* trampoline = page + 16;
	uint8_t* p = trampoline;
	for (size_t i = 0; i < instruction_count; ++i) {
		const Relocation& r = instructions[i];
		if (r.call) {
			// call [rip+2]; jmp +8; the target: the call returns into the trampoline
			const uint8_t call[] = {0xFF, 0x15, 0x02, 0x00, 0x00, 0x00, 0xEB, 0x08};
			std::memcpy(p, call, sizeof(call));
			std::memcpy(p + sizeof(call), &r.target, 8);
			p += sizeof(call) + 8;
			continue;
		}
		std::memcpy(p, code + r.offset, r.length);
		if (r.rip_relative && !relocate(p, reinterpret_cast<uint64_t>(target) + r.offset, r, error)) {
			VirtualProtect(page, kSlotSize, PAGE_EXECUTE_READ, &protect);
			return false;
		}
		p += r.length;
	}
	write_absolute_jump(p, target + moved);
	VirtualProtect(page, kSlotSize, PAGE_EXECUTE_READ, &protect);
	FlushInstructionCache(GetCurrentProcess(), page, kSlotSize);

	// the jmp; the replacement can run as soon as it is written
	*original = trampoline;
	if (!VirtualProtect(word, 8, PAGE_EXECUTE_READWRITE, &protect)) {
		*original = nullptr;
		*error = "VirtualProtect failed on the target";
		return false;
	}
	const int64_t before = *reinterpret_cast<volatile int64_t*>(word);
	if (std::memcmp(reinterpret_cast<const uint8_t*>(&before) + offset, code, 8 - offset) != 0) {
		DWORD ignored = 0;
		VirtualProtect(word, 8, protect, &ignored);
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
		*original = nullptr;
		*error = "the target changed while the hook was installed";
		return false;
	}
	block->used += kSlotSize;
	return true;
}

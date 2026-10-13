// headless.c: an LD_PRELOAD library that drives the real Stellaris 4.5.2 Linux build as a
// simulation oracle: load a save, run an exact number of ticks without rendering, write the
// gamestate, exit.
//
// Every address comes from the executable's own symbol table (it is not stripped) plus the load
// base. Nothing is hard-coded but a few field offsets, each read from the game's disassembly and
// named where it is used.
//
// Environment:
//   HEADLESS_SAVE     save to load, a path the game's file system resolves (relative to the user
//                     dir, e.g. "save games/headless/x.sav"; default "save games/headless/save.sav")
//   HEADLESS_TICKS    number of ticks to run (default 10)
//   HEADLESS_OUT      gamestate output path, relative to the game's user dir (VFS write dir)
//                     or absolute (default "headless_out.gamestate")
//   HEADLESS_MODE     "loop" (default): all ticks in one frame, the game's own tick command and
//                     session update, nothing rendered; "frame": one turn (NUM_COMMANDS_PER_TURN
//                     ticks) per frame, the main loop running as in play
//   HEADLESS_DLCS     DLC names (as in .dlc "name" and the save's required_dlcs) separated by
//                     ';'. These are owned, every other is not. Unset: every DLC is owned.
//   HEADLESS_WAIT     frames to wait in game before the first tick (default 5)
//   HEADLESS_TIMEOUT  seconds before the watchdog kills the process (default 1200)
//   HEADLESS_LOG      log file (default: stderr)
//   HEADLESS_RNG_POS  after the load, set the synchronized generator's position to this (the
//                     save's random_count, to undo the draws the load makes)
//   HEADLESS_PROFILE  call-site table (dev/callsites.py): count the generator's draws per site
//   HEADLESS_PROFILE_OUT  where the per-site table is written at the end
#define _GNU_SOURCE
#include <dlfcn.h>
#include <elf.h>
#include <fcntl.h>
#include <link.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// ---------------------------------------------------------------- log

static double g_t0;
static FILE *g_log;

static double now(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void hlog(const char *fmt, ...) {
	FILE *f = g_log ? g_log : stderr;
	va_list ap;
	va_start(ap, fmt);
	fprintf(f, "[headless %9.3f] ", now() - g_t0);
	vfprintf(f, fmt, ap);
	fputc('\n', f);
	fflush(f);
	va_end(ap);
}

static void die(int code, const char *msg) {
	hlog("FATAL: %s", msg);
	_exit(code);
}

// ---------------------------------------------------------------- symbols

static uintptr_t g_base;

static int base_cb(struct dl_phdr_info *info, size_t size, void *data) {
	(void)size;
	if (info->dlpi_name == NULL || info->dlpi_name[0] == 0) {
		*(uintptr_t *)data = info->dlpi_addr;
		return 1;
	}
	return 0;
}

struct symreq {
	const char *name;
	uintptr_t *out;
};

// One pass over the executable's .symtab: each requested (mangled) name gets base + value.
static int resolve(struct symreq *reqs) {
	int fd = open("/proc/self/exe", O_RDONLY);
	if (fd < 0) return -1;
	struct stat st;
	fstat(fd, &st);
	uint8_t *m = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd);
	if (m == MAP_FAILED) return -1;
	Elf64_Ehdr *eh = (Elf64_Ehdr *)m;
	Elf64_Shdr *sh = (Elf64_Shdr *)(m + eh->e_shoff);
	int missing = 0;
	for (int i = 0; i < eh->e_shnum; i++) {
		if (sh[i].sh_type != SHT_SYMTAB) continue;
		Elf64_Sym *syms = (Elf64_Sym *)(m + sh[i].sh_offset);
		size_t n = sh[i].sh_size / sizeof(Elf64_Sym);
		const char *strtab = (const char *)(m + sh[sh[i].sh_link].sh_offset);
		for (size_t k = 0; k < n; k++) {
			if (syms[k].st_value == 0) continue;
			const char *name = strtab + syms[k].st_name;
			for (struct symreq *r = reqs; r->name; r++)
				if (*r->out == 0 && strcmp(name, r->name) == 0) *r->out = g_base + syms[k].st_value;
		}
	}
	for (struct symreq *r = reqs; r->name; r++)
		if (*r->out == 0) {
			hlog("symbol not found: %s", r->name);
			missing++;
		}
	munmap(m, st.st_size);
	return missing;
}

// Overwrites a function's first 12 bytes with `movabs rax, to; jmp rax`. The original is never
// called again (every hook here replaces its function).
static void detour(uintptr_t at, void *to) {
	uint8_t code[12] = {0x48, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xE0};
	memcpy(code + 2, &to, 8);
	uintptr_t page = at & ~(uintptr_t)0xfff;
	size_t len = ((at + sizeof code + 0xfff) & ~(uintptr_t)0xfff) - page;
	if (mprotect((void *)page, len, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) die(2, "mprotect");
	memcpy((void *)at, code, sizeof code);
	mprotect((void *)page, len, PROT_READ | PROT_EXEC);
	__builtin___clear_cache((char *)at, (char *)at + sizeof code);
}

// ---------------------------------------------------------------- the game's functions and data

static uintptr_t a_VerifyAllDLCOwnership;   // CDLCManager::VerifyAllDLCOwnership(bool)
static uintptr_t a_CheckTick;               // CInGameIdler::CheckTick(float)
static uintptr_t a_PostCommandToSession;    // PostCommandToSession(CCommand*, bool)
static uintptr_t a_GameApplicationUpdate;   // CGameApplication::Update()
static uintptr_t a_AccessApplication;       // CApplication::AccessInstance()
static uintptr_t a_GetTotalTicks;           // CGameState::GetTotalTicks() const
static uintptr_t a_SaveGameCheckMakeSave;   // SaveGameCheckMakeSave(CString)
static uintptr_t a_CStringCtor;             // CString::CString(char const*)
static uintptr_t a_vt_TurnTickCommand;      // vtable for CTurnTickCommand
static uintptr_t a_vt_ArrayULL;             // vtable for CPdxArray<unsigned long long, int>
static uintptr_t a_vt_ArrayPlayerTick;      // vtable for CPdxArray<CTurnTickCommand::CPlayerCurrentTick, int>
static uintptr_t a_g_CurrentGameState;      // CGameState*
static uintptr_t a_g_bFrameSmoothing;       // bool
static uintptr_t a_g_AllowGetPlayer;        // bool
static uintptr_t a_g_AllowGlobalGameStateAccess; // bool
static uintptr_t a_g_AllowPostCommandToSession;  // bool
static uintptr_t a_NUM_COMMANDS_PER_TURN;   // NDefines::NGameplay::NUM_COMMANDS_PER_TURN (int)
static uintptr_t a_LaunchSave;              // CFrontEndIdler::LaunchSave(CString const&, bool, CMultiplayerConfiguration const&)
static uintptr_t a_FrontendDlcViewUpdate;   // CFrontendDlcView::Update()
static uintptr_t a_g_CurrentFrontEndIdler;  // CFrontEndIdler*
static uintptr_t a_InGameRenderInternal;   // CInGameIdler::RenderInternal(bool)
static uintptr_t a_Random;                  // CRandom::_Random: CNoiseRandom { uint32 position; uint32 seed }
static uintptr_t a_nRandomCount;            // CSystem::_nRandomCount (the position CSetRandomSeed syncs from)

static struct symreq g_syms[] = {
	{"_ZN11CDLCManager21VerifyAllDLCOwnershipEb", &a_VerifyAllDLCOwnership},
	{"_ZN12CInGameIdler9CheckTickEf", &a_CheckTick},
	{"_Z20PostCommandToSessionP8CCommandb", &a_PostCommandToSession},
	{"_ZN16CGameApplication6UpdateEv", &a_GameApplicationUpdate},
	{"_ZN12CApplication14AccessInstanceEv", &a_AccessApplication},
	{"_ZNK10CGameState13GetTotalTicksEv", &a_GetTotalTicks},
	{"_Z21SaveGameCheckMakeSave7CString", &a_SaveGameCheckMakeSave},
	{"_ZN7CStringC1EPKc", &a_CStringCtor},
	{"_ZTV16CTurnTickCommand", &a_vt_TurnTickCommand},
	{"_ZTV9CPdxArrayIyiE", &a_vt_ArrayULL},
	{"_ZTV9CPdxArrayIN16CTurnTickCommand18CPlayerCurrentTickEiE", &a_vt_ArrayPlayerTick},
	{"g_CurrentGameState", &a_g_CurrentGameState},
	{"g_bFrameSmoothing", &a_g_bFrameSmoothing},
	{"g_AllowGetPlayer", &a_g_AllowGetPlayer},
	{"g_AllowGlobalGameStateAccess", &a_g_AllowGlobalGameStateAccess},
	{"g_AllowPostCommandToSession", &a_g_AllowPostCommandToSession},
	{"_ZN8NDefines9NGameplay21NUM_COMMANDS_PER_TURNE", &a_NUM_COMMANDS_PER_TURN},
	{"_ZN14CFrontEndIdler10LaunchSaveERK7CStringbRK25CMultiplayerConfiguration", &a_LaunchSave},
	{"_ZN16CFrontendDlcView6UpdateEv", &a_FrontendDlcViewUpdate},
	{"g_CurrentFrontEndIdler", &a_g_CurrentFrontEndIdler},
	{"_ZN12CInGameIdler14RenderInternalEb", &a_InGameRenderInternal},
	{"_ZN7CRandom7_RandomE", &a_Random},
	{"_ZN7CSystem13_nRandomCountE", &a_nRandomCount},
	{NULL, NULL},
};

#define U8(a) (*(volatile uint8_t *)(a))
#define I32(a) (*(volatile int32_t *)(a))

static void *game_state(void) { return *(void **)a_g_CurrentGameState; }

static int total_ticks(void *gs) { return ((int (*)(void *))a_GetTotalTicks)(gs); }

// CString (0x30 bytes): +0 int, +8 qword, +0x10 std::string with CPdxCommonStringAllocator
// (+0x10 char*, +0x18 size, +0x20 local buffer).
static const char *cstring_ptr(const void *s, size_t *len) {
	*len = *(const size_t *)((const char *)s + 0x18);
	return *(const char *const *)((const char *)s + 0x10);
}

// ---------------------------------------------------------------- random-draw profiler
//
// HEADLESS_PROFILE=<sites.tsv> (from dev/callsites.py): each listed `call rel32` / `jmp rel32`
// site is redirected to a small stub near the executable (`mov r11d, site; jmp hk_entry`).
// hk_entry records the synchronized generator's position (CRandom::_Random+0), swaps the return
// address for hk_post and jumps to the original target with the stack and argument registers
// untouched (so stack-passed arguments still work); hk_post adds the position delta to the site
// and returns to the real return address. The table (inclusive draws per call site) goes to
// HEADLESS_PROFILE_OUT at the end of the run.

struct site {
	uintptr_t addr, target;
	char *caller, *callee, kind[8];
	uint64_t calls, draws;
};
static struct site *g_sites;
static int g_nsites;
static int g_prof_on;
static int g_site_htt = -1; // the tick: CTurnTickCommand::Execute's tail jump to HandleTurnTick
struct pframe {
	void *ret;
	uint32_t pos;
	int site;
};
static __thread struct pframe t_frames[256];
static __thread int t_depth;

static inline uint32_t rng_pos(void) { return *(volatile uint32_t *)a_Random; }
static inline uint32_t rng_seed(void) { return *(volatile uint32_t *)(a_Random + 4); }

#define HIDDEN __attribute__((visibility("hidden")))
HIDDEN void hk_entry(void);
HIDDEN void hk_post(void);
HIDDEN void *hk_before(long site, void **retslot);
HIDDEN void *hk_after(void);

void *hk_before(long site, void **retslot) {
	if (t_depth >= 256) die(5, "profiler: call depth");
	struct pframe *f = &t_frames[t_depth++];
	f->ret = *retslot;
	f->pos = rng_pos();
	f->site = (int)site;
	*retslot = (void *)hk_post;
	return (void *)g_sites[site].target;
}

void *hk_after(void) {
	struct pframe *f = &t_frames[--t_depth];
	if (g_prof_on) {
		__atomic_add_fetch(&g_sites[f->site].calls, 1, __ATOMIC_RELAXED);
		__atomic_add_fetch(&g_sites[f->site].draws, (uint32_t)(rng_pos() - f->pos), __ATOMIC_RELAXED);
	}
	return f->ret;
}

// Entered by jmp from a site stub with r11 = site and [rsp] = the return address (rsp = 8 mod 16).
__asm__(".text\n"
        ".globl hk_entry\n"
        ".hidden hk_entry\n"
        ".type hk_entry,@function\n"
        "hk_entry:\n"
        "  push %rdi\n  push %rsi\n  push %rdx\n  push %rcx\n"
        "  push %r8\n  push %r9\n  push %rax\n  push %r11\n"
        "  sub $136, %rsp\n"
        "  movdqu %xmm0, 0(%rsp)\n  movdqu %xmm1, 16(%rsp)\n  movdqu %xmm2, 32(%rsp)\n"
        "  movdqu %xmm3, 48(%rsp)\n  movdqu %xmm4, 64(%rsp)\n  movdqu %xmm5, 80(%rsp)\n"
        "  movdqu %xmm6, 96(%rsp)\n  movdqu %xmm7, 112(%rsp)\n"
        "  mov %r11, %rdi\n"
        "  lea 200(%rsp), %rsi\n"
        "  call hk_before\n"
        "  mov %rax, 136(%rsp)\n"
        "  movdqu 0(%rsp), %xmm0\n  movdqu 16(%rsp), %xmm1\n  movdqu 32(%rsp), %xmm2\n"
        "  movdqu 48(%rsp), %xmm3\n  movdqu 64(%rsp), %xmm4\n  movdqu 80(%rsp), %xmm5\n"
        "  movdqu 96(%rsp), %xmm6\n  movdqu 112(%rsp), %xmm7\n"
        "  add $136, %rsp\n"
        "  pop %r11\n  pop %rax\n  pop %r9\n  pop %r8\n"
        "  pop %rcx\n  pop %rdx\n  pop %rsi\n  pop %rdi\n"
        "  jmp *%r11\n"
        ".globl hk_post\n"
        ".hidden hk_post\n"
        ".type hk_post,@function\n"
        "hk_post:\n"
        "  push %rax\n  push %rdx\n"
        "  sub $32, %rsp\n"
        "  movdqu %xmm0, 0(%rsp)\n  movdqu %xmm1, 16(%rsp)\n"
        "  call hk_after\n"
        "  mov %rax, %r11\n"
        "  movdqu 0(%rsp), %xmm0\n  movdqu 16(%rsp), %xmm1\n"
        "  add $32, %rsp\n"
        "  pop %rdx\n  pop %rax\n"
        "  jmp *%r11\n");

static uint8_t *alloc_near(size_t len) {
	for (uintptr_t k = 1; k < 64; k++) {
		uintptr_t hint = (g_base - k * 0x1000000UL) & ~(uintptr_t)0xfff;
		void *p = mmap((void *)hint, len, PROT_READ | PROT_WRITE | PROT_EXEC,
		               MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
		if (p != MAP_FAILED) return p;
	}
	return NULL;
}

static void profile_install(const char *path) {
	FILE *f = fopen(path, "r");
	if (!f) die(2, "HEADLESS_PROFILE: cannot open the site table");
	char line[4096];
	int cap = 4096;
	g_sites = calloc(cap, sizeof *g_sites);
	while (fgets(line, sizeof line, f)) {
		char *fld[5], *s = line;
		int n = 0;
		for (; n < 5; n++) {
			fld[n] = strsep(&s, "\t\n");
			if (!fld[n]) break;
		}
		if (n < 5) continue;
		if (g_nsites == cap) g_sites = realloc(g_sites, (cap *= 2) * sizeof *g_sites);
		struct site *st = &g_sites[g_nsites];
		memset(st, 0, sizeof *st);
		st->addr = g_base + strtoul(fld[0], NULL, 16);
		st->target = g_base + strtoul(fld[1], NULL, 16);
		snprintf(st->kind, sizeof st->kind, "%s", fld[2]);
		st->caller = strdup(fld[3]);
		st->callee = strdup(fld[4]);
		uint8_t op = *(uint8_t *)st->addr;
		int32_t rel = *(int32_t *)(st->addr + 1);
		if ((op != 0xE8 && op != 0xE9) || st->addr + 5 + rel != st->target) {
			hlog("profile: site %s+%#lx does not call %s; skipped", st->caller, (unsigned long)(st->addr - g_base),
			     st->callee);
			continue;
		}
		if (strstr(st->caller, "CTurnTickCommand::Execute") && strstr(st->callee, "HandleTurnTick"))
			g_site_htt = g_nsites;
		g_nsites++;
	}
	fclose(f);
	size_t stub = 32, len = ((size_t)g_nsites * stub + 0xfff) & ~(size_t)0xfff;
	uint8_t *mem = alloc_near(len);
	if (!mem) die(2, "profile: no memory near the executable");
	for (int i = 0; i < g_nsites; i++) {
		uint8_t *p = mem + i * stub;
		void *entry = (void *)hk_entry;
		p[0] = 0x41, p[1] = 0xBB; // mov r11d, imm32
		memcpy(p + 2, &i, 4);
		p[6] = 0xFF, p[7] = 0x25; // jmp [rip+0]
		memset(p + 8, 0, 4);
		memcpy(p + 12, &entry, 8);
		intptr_t rel = (intptr_t)p - (intptr_t)(g_sites[i].addr + 5);
		if (rel != (int32_t)rel) die(2, "profile: stub out of range");
		uintptr_t page = g_sites[i].addr & ~(uintptr_t)0xfff;
		mprotect((void *)page, 0x2000, PROT_READ | PROT_WRITE | PROT_EXEC);
		int32_t r32 = (int32_t)rel;
		memcpy((void *)(g_sites[i].addr + 1), &r32, 4);
		mprotect((void *)page, 0x2000, PROT_READ | PROT_EXEC);
	}
	__builtin___clear_cache((char *)mem, (char *)mem + len);
	hlog("profile: %d call sites instrumented", g_nsites);
}

static void profile_write(const char *path, uint64_t total_draws, int ticks) {
	FILE *f = fopen(path, "w");
	if (!f) return;
	double days = ticks / 10.0;
	uint64_t htt = g_site_htt >= 0 ? g_sites[g_site_htt].draws : 0;
	fprintf(f, "# total draws %llu over %d ticks (%.1f/day); in HandleTurnTick %llu; outside it (commands "
	           "executed between ticks) %llu\n",
	        (unsigned long long)total_draws, ticks, days ? (double)total_draws / days : 0.0,
	        (unsigned long long)htt, (unsigned long long)(total_draws - htt));
	fprintf(f, "site\tcaller\tcallee\tcalls\tdraws\tdraws_per_day\n");
	for (int i = 0; i < g_nsites; i++) {
		struct site *s = &g_sites[i];
		if (!s->calls) continue;
		fprintf(f, "%lx\t%s\t%s\t%llu\t%llu\t%.1f\n", (unsigned long)(s->addr - g_base), s->caller, s->callee,
		        (unsigned long long)s->calls, (unsigned long long)s->draws, days ? (double)s->draws / days : 0.0);
	}
	fclose(f);
}

// ---------------------------------------------------------------- DLC ownership

// Without Steam the store has no items and no DLC is owned. CDLCManager keeps its descriptors in
// a std::map<CString, CDLCDescriptor> (header at +0xd8, leftmost node at +0xe8); a node's
// descriptor is at +0x50 (its name CString at descriptor +8) and the "verified" flag that
// VerifyAllDLCOwnership sets is the node's byte +0x40c (AcceptAllDLC sets the same byte).
static char *g_dlcs; // ";name;name;" or NULL for all

static int dlc_allowed(const char *name, size_t len) {
	if (!g_dlcs) return 1;
	char buf[512];
	if (len + 3 > sizeof buf) return 0;
	buf[0] = ';';
	memcpy(buf + 1, name, len);
	buf[len + 1] = ';';
	buf[len + 2] = 0;
	return strstr(g_dlcs, buf) != NULL;
}

static int my_VerifyAllDLCOwnership(void *mgr, int b) {
	(void)b;
	typedef void *(*inc_fn)(void *);
	inc_fn inc = (inc_fn)dlsym(RTLD_DEFAULT, "_ZSt18_Rb_tree_incrementPSt18_Rb_tree_node_base");
	if (!inc) die(2, "_Rb_tree_increment not found");
	char *header = (char *)mgr + 0xd8;
	int owned = 0, total = 0;
	for (char *node = *(char **)((char *)mgr + 0xe8); node != header; node = inc(node)) {
		size_t len;
		const char *name = cstring_ptr(node + 0x50 + 8, &len);
		int ok = dlc_allowed(name, len);
		U8(node + 0x40c) = (uint8_t)ok;
		total++;
		owned += ok;
		hlog("DLC %-3s %.*s", ok ? "on" : "off", (int)len, name);
	}
	hlog("DLC ownership: %d of %d owned", owned, total);
	return 0;
}

// ---------------------------------------------------------------- loading the save

// Replaces CFrontendDlcView::Update(), which CFrontEndIdler::UpdateInternal calls once a frame on
// the main thread while the main menu is up (the menu's DLC list is not updated). A few frames in,
// it launches the save the way the load-game view does: CFrontEndIdler::LaunchSave(path, cloud =
// false, the front end's CMultiplayerConfiguration at +0x250, as the -continuelastsave path passes).
static const char *g_save = "save games/headless/save.sav";
static int g_menu_frames, g_launched;
static double g_menu_at;

static void my_FrontendDlcViewUpdate(void *view) {
	(void)view;
	if (g_launched) return;
	if (g_menu_frames++ == 0) {
		g_menu_at = now() - g_t0;
		hlog("main menu after %.3f s", g_menu_at);
	}
	if (g_menu_frames < 3) return;
	void *fe = *(void **)a_g_CurrentFrontEndIdler;
	if (!fe) return;
	g_launched = 1;
	_Alignas(16) uint8_t path[0x30];
	((void (*)(void *, const char *))a_CStringCtor)(path, g_save);
	hlog("LaunchSave(\"%s\")", g_save);
	((void (*)(void *, const void *, int, const void *))a_LaunchSave)(fe, path, 0, (char *)fe + 0x250);
	hlog("LaunchSave returned after %.3f s", now() - g_t0 - g_menu_at);
}

// ---------------------------------------------------------------- driving the ticks

enum { ST_WAIT, ST_RUN, ST_DONE };
static int g_state = ST_WAIT;
static int g_ticks = 10;
static int g_wait_frames = 5;
static int g_frames_ready;
static int g_frame_mode;
static int g_start_total;
static int g_posted;
static const char *g_out = "headless_out.gamestate";
static const char *g_profile_out;
static double g_run_t0, g_boot_done;
static long long g_rng_pos_set = -1; // HEADLESS_RNG_POS
static uint32_t g_pos0;

// The tick command, built as CInGameIdler::CheckTick builds it (operator new(0x50), the fields
// set inline), then posted to the session.
static void post_tick(void) {
	void *(*op_new)(size_t) = (void *(*)(size_t))dlsym(RTLD_DEFAULT, "_Znwm");
	uint8_t *p = op_new(0x50);
	memset(p, 0, 0x50);
	*(uint64_t *)(p + 0x08) = 0xffffffffu;
	*(uint16_t *)(p + 0x12) = 0xffff;
	p[0x15] = 0;
	*(uint32_t *)(p + 0x18) = 0;
	*(uintptr_t *)(p + 0x00) = a_vt_TurnTickCommand + 0x10;
	*(uintptr_t *)(p + 0x20) = a_vt_ArrayULL + 0x10;
	*(uintptr_t *)(p + 0x38) = a_vt_ArrayPlayerTick + 0x10;
	((void (*)(void *, int))a_PostCommandToSession)(p, 0);
	g_posted++;
}

// CGameApplication::Update: the frame's session update (ProcessSynchronousCommands with the
// game state's callbacks), run here as the main loop runs it.
static void app_update(void) {
	void *app = ((void *(*)(void))a_AccessApplication)();
	((void (*)(void *))a_GameApplicationUpdate)(app);
}

static int per_turn(void) {
	int n = I32(a_NUM_COMMANDS_PER_TURN);
	if (n > 10) n = 10;
	if (n < 1) n = 1;
	return n;
}

static void write_gamestate_and_exit(void *gs) {
	double t_ticks = now() - g_run_t0;
	int done = total_ticks(gs) - g_start_total;
	g_prof_on = 0;
	uint32_t draws = rng_pos() - g_pos0;
	hlog("ran %d ticks in %.3f s (%.2f ms/day); now tick=%d days=%d date=%d", done, t_ticks,
	     done > 0 ? t_ticks * 1000.0 * 10 / done : 0.0, I32((char *)gs + 8), I32((char *)gs + 0xc4),
	     I32((char *)gs + 0xc0));
	hlog("random: seed %d position %u, %u draws in the run (%.1f a day)", (int)rng_seed(), rng_pos(), draws,
	     done ? draws * 10.0 / done : 0.0);
	if (g_nsites && g_profile_out) {
		profile_write(g_profile_out, draws, done);
		hlog("profile -> %s", g_profile_out);
	}
	// SaveGameCheckMakeSave(CString) writes CWriter::WriteTopLevelList(*g_CurrentGameState) to a
	// CArchiveFile: the game's own gamestate writer, on this thread.
	_Alignas(16) uint8_t path[0x30];
	((void (*)(void *, const char *))a_CStringCtor)(path, g_out);
	double t1 = now();
	U8(a_g_AllowGlobalGameStateAccess) = 1;
	int ok = ((int (*)(void *))a_SaveGameCheckMakeSave)(path) & 1;
	hlog("SaveGameCheckMakeSave(\"%s\") -> %d in %.3f s", g_out, ok, now() - t1);
	hlog("total %.3f s (boot+load %.3f s)", now() - g_t0, g_boot_done);
	fflush(NULL);
	_exit(ok ? 0 : 1);
}

static void no_render(void *idler, int b) {
	(void)idler;
	(void)b;
}

static void start_run(void *gs) {
	g_state = ST_RUN;
	if (g_frame_mode && !getenv("HEADLESS_RENDER")) {
		// The in-game frame is not drawn from here on (llvmpipe takes seconds a frame). Patched
		// from the update, on the main thread that also renders.
		detour(a_InGameRenderInternal, (void *)no_render);
		hlog("in-game rendering off");
	}
	g_boot_done = now() - g_t0;
	g_start_total = total_ticks(gs);
	hlog("in game after %.3f s: tick=%d days=%d date=%d total=%d; running %d ticks (%s mode, %d per turn)",
	     g_boot_done, I32((char *)gs + 8), I32((char *)gs + 0xc4), I32((char *)gs + 0xc0), g_start_total,
	     g_ticks, g_frame_mode ? "frame" : "loop", per_turn());
	U8(a_g_bFrameSmoothing) = 0; // no frames rendered from inside the tick
	hlog("random after load: seed %d position %u", (int)rng_seed(), rng_pos());
	if (g_rng_pos_set >= 0) {
		// The load itself draws (112 for the 2210 saves): put the position back where the save
		// left it, as if the session had gone on instead of reloading.
		*(volatile uint32_t *)a_Random = (uint32_t)g_rng_pos_set;
		*(volatile uint32_t *)a_nRandomCount = (uint32_t)g_rng_pos_set;
		hlog("random position set to %u", rng_pos());
	}
	g_pos0 = rng_pos();
	g_prof_on = 1;
	g_run_t0 = now();
}

static void progress(void *gs) {
	static int last_day = -1;
	int day = I32((char *)gs + 0xc4);
	if (day != last_day && day % 30 == 0) {
		int done = total_ticks(gs) - g_start_total;
		hlog("  day %d: %d ticks, %.3f s", day, done, now() - g_run_t0);
	}
	last_day = day;
}

// Replaces CInGameIdler::CheckTick(float), called once a frame by CInGameIdler::UpdateInternal on
// the main thread: the game's own ticks never start (the game stays paused), these do.
static _Bool my_CheckTick(void *idler, float dt) {
	(void)idler;
	(void)dt;
	void *gs = game_state();
	if (!gs || !U8((char *)gs + 0xa0)) return 0; // no game, or not started
	if (g_state == ST_DONE) return 0;
	if (g_state == ST_WAIT) {
		if (++g_frames_ready < g_wait_frames) return 0;
		start_run(gs);
	}
	int target = g_start_total + g_ticks;
	if (!g_frame_mode) {
		uint8_t s_ggs = U8(a_g_AllowGlobalGameStateAccess), s_gp = U8(a_g_AllowGetPlayer),
		        s_pc = U8(a_g_AllowPostCommandToSession);
		int stalls = 0;
		while (total_ticks(gs) < target) {
			int before = total_ticks(gs);
			int k = per_turn();
			int left = target - g_start_total - g_posted;
			if (k > left) k = left;
			U8(a_g_AllowPostCommandToSession) = 1;
			for (int i = 0; i < k; i++) post_tick();
			app_update();
			progress(gs);
			if (total_ticks(gs) == before && ++stalls > 100) die(4, "ticks do not advance");
		}
		U8(a_g_AllowGlobalGameStateAccess) = s_ggs;
		U8(a_g_AllowGetPlayer) = s_gp;
		U8(a_g_AllowPostCommandToSession) = s_pc;
		g_state = ST_DONE;
		write_gamestate_and_exit(gs);
	} else {
		int cur = total_ticks(gs);
		progress(gs);
		if (cur >= target) {
			g_state = ST_DONE;
			write_gamestate_and_exit(gs);
		}
		int k = per_turn();
		int left = g_ticks - g_posted;
		if (k > left) k = left;
		uint8_t s_pc = U8(a_g_AllowPostCommandToSession);
		U8(a_g_AllowPostCommandToSession) = 1;
		for (int i = 0; i < k; i++) post_tick();
		U8(a_g_AllowPostCommandToSession) = s_pc;
	}
	return 0;
}

// ---------------------------------------------------------------- start

static int g_timeout = 1200;

static void *watchdog(void *arg) {
	(void)arg;
	sleep(g_timeout);
	hlog("watchdog: %d s, state %d, posted %d; exiting", g_timeout, g_state, g_posted);
	_exit(3);
	return NULL;
}

__attribute__((constructor)) static void headless_init(void) {
	// Only the game itself: not xvfb-run, gdb, or other processes the env reaches.
	char exe[512];
	ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
	if (n <= 0) return;
	exe[n] = 0;
	const char *base = strrchr(exe, '/');
	if (!base || strcmp(base + 1, "stellaris") != 0) return;

	g_t0 = now();
	const char *e;
	if ((e = getenv("HEADLESS_LOG"))) g_log = fopen(e, "a");
	if ((e = getenv("HEADLESS_TICKS"))) g_ticks = atoi(e);
	if ((e = getenv("HEADLESS_OUT"))) g_out = e;
	if ((e = getenv("HEADLESS_SAVE"))) g_save = e;
	if ((e = getenv("HEADLESS_RNG_POS")) && *e) g_rng_pos_set = strtoll(e, NULL, 10);
	if ((e = getenv("HEADLESS_PROFILE_OUT"))) g_profile_out = e;
	if ((e = getenv("HEADLESS_WAIT"))) g_wait_frames = atoi(e);
	if ((e = getenv("HEADLESS_TIMEOUT"))) g_timeout = atoi(e);
	if ((e = getenv("HEADLESS_MODE"))) g_frame_mode = strcmp(e, "frame") == 0;
	if ((e = getenv("HEADLESS_DLCS"))) {
		g_dlcs = malloc(strlen(e) + 3);
		sprintf(g_dlcs, ";%s;", e);
	}

	dl_iterate_phdr(base_cb, &g_base);
	if (!g_base) die(2, "no load base");
	if (resolve(g_syms) != 0) die(2, "missing symbols");
	hlog("stellaris at %#lx; %d ticks -> %s", (unsigned long)g_base, g_ticks, g_out);

	detour(a_VerifyAllDLCOwnership, (void *)my_VerifyAllDLCOwnership);
	detour(a_CheckTick, (void *)my_CheckTick);
	detour(a_FrontendDlcViewUpdate, (void *)my_FrontendDlcViewUpdate);
	if ((e = getenv("HEADLESS_PROFILE")) && *e) profile_install(e);

	pthread_t t;
	pthread_create(&t, NULL, watchdog, NULL);
	pthread_detach(t);
}

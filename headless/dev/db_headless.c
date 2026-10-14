// db_headless.c: the headless driver (../headless.c, included unchanged) plus the database
// prototype: Lua (LuaJIT, linked in) builds chosen game databases from the game's files instead of
// the game's own readers (docs/databases.md, "The proof").
//
// Build and run: headless/dev/db_run.sh (it compiles this file with LuaJIT and runs the game the
// way run.sh does). Environment, on top of headless.c's:
//   HEADLESS_DB       "<database>[:<mode>],...": the databases to hook, e.g. "CNamedColorDatabase:lua".
//                     Modes: lua (default; Lua builds the database, the game's Init never runs),
//                     shadow (the game's Init builds a second instance of the database, Lua builds the
//                     live one, and the two are compared object by object), game (the hook calls the
//                     game's own Init: a control run through the same hook).
//   HEADLESS_DB_LUA   the directory of the Lua side (dbbuild.lua; default: next to this file's .so)
//   HEADLESS_DB_PATH  extra Lua package.path entries (the repo's lua/ and lib/stellar-lua-pdxscript)
//   HEADLESS_DB_DUMP  a file: every hooked database's objects, written when the save is launched
//                     (after every database and post-read pass), to compare runs (db_compare.sh)
//   HEADLESS_DB_CENSUS a file: the object count of every TSingleObjectGameDatabase of the table, at
//                     the same time
//
// The C side only does what Lua cannot do by itself: it detours each hooked database's
// TGameDatabase<X>::InitInstance (the function SetupDatabases calls through its table) to a stub
// that calls dbbuild.init(name, mode) in Lua, and gives Lua the executable's symbols
// (hdb_sym(mangled name) -> address). Everything else (reading the files, parsing them with
// pdxscript, making the objects, comparing) is Lua's, through the FFI.
#include "../headless.c"

#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>

// ---------------------------------------------------------------- symbols for Lua

static uint8_t *g_exe_map;
static size_t g_exe_size;
static Elf64_Sym *g_syms_tab;
static size_t g_nsyms;
static const char *g_strtab;
static uint32_t *g_hash; // open addressing: index + 1 into g_syms_tab, 0 = empty
static size_t g_hash_size;

static uint32_t fnv(const char *s) {
	uint32_t h = 2166136261u;
	while (*s) h = (h ^ (uint8_t)*s++) * 16777619u;
	return h;
}

static int sym_index(void) {
	if (g_hash) return 0;
	int fd = open("/proc/self/exe", O_RDONLY);
	if (fd < 0) return -1;
	struct stat st;
	fstat(fd, &st);
	g_exe_map = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd);
	if (g_exe_map == MAP_FAILED) return -1;
	g_exe_size = st.st_size;
	Elf64_Ehdr *eh = (Elf64_Ehdr *)g_exe_map;
	Elf64_Shdr *sh = (Elf64_Shdr *)(g_exe_map + eh->e_shoff);
	for (int i = 0; i < eh->e_shnum; i++) {
		if (sh[i].sh_type != SHT_SYMTAB) continue;
		g_syms_tab = (Elf64_Sym *)(g_exe_map + sh[i].sh_offset);
		g_nsyms = sh[i].sh_size / sizeof(Elf64_Sym);
		g_strtab = (const char *)(g_exe_map + sh[sh[i].sh_link].sh_offset);
	}
	if (!g_syms_tab) return -1;
	g_hash_size = 1;
	while (g_hash_size < g_nsyms * 2) g_hash_size <<= 1;
	g_hash = calloc(g_hash_size, sizeof *g_hash);
	for (size_t k = 0; k < g_nsyms; k++) {
		if (g_syms_tab[k].st_value == 0) continue;
		size_t h = fnv(g_strtab + g_syms_tab[k].st_name) & (g_hash_size - 1);
		while (g_hash[h]) h = (h + 1) & (g_hash_size - 1);
		g_hash[h] = (uint32_t)(k + 1);
	}
	return 0;
}

// hdb_sym(mangled) -> the address of the executable's symbol, or 0. Called by Lua (ffi.C).
__attribute__((visibility("default"))) uintptr_t hdb_sym(const char *name) {
	if (sym_index() != 0) return 0;
	size_t h = fnv(name) & (g_hash_size - 1);
	while (g_hash[h]) {
		Elf64_Sym *s = &g_syms_tab[g_hash[h] - 1];
		if (strcmp(g_strtab + s->st_name, name) == 0) return g_base + s->st_value;
		h = (h + 1) & (g_hash_size - 1);
	}
	return 0;
}

// hdb_sym_size(mangled) -> the symbol's size (a function's length, an object's size), or 0
__attribute__((visibility("default"))) uint64_t hdb_sym_size(const char *name) {
	if (sym_index() != 0) return 0;
	size_t h = fnv(name) & (g_hash_size - 1);
	while (g_hash[h]) {
		Elf64_Sym *s = &g_syms_tab[g_hash[h] - 1];
		if (strcmp(g_strtab + s->st_name, name) == 0) return s->st_size;
		h = (h + 1) & (g_hash_size - 1);
	}
	return 0;
}

// hdb_log(text): a line in the headless log
__attribute__((visibility("default"))) void hdb_log(const char *text) { hlog("db: %s", text); }

// hdb_now() -> seconds (monotonic)
__attribute__((visibility("default"))) double hdb_now(void) { return now(); }

// hdb_call_original(at, saved 12 bytes): put a detoured function's first bytes back (to call it once)
__attribute__((visibility("default"))) void hdb_restore(uintptr_t at, const uint8_t *bytes) {
	uintptr_t page = at & ~(uintptr_t)0xfff;
	size_t len = ((at + 12 + 0xfff) & ~(uintptr_t)0xfff) - page;
	mprotect((void *)page, len, PROT_READ | PROT_WRITE | PROT_EXEC);
	memcpy((void *)at, bytes, 12);
	mprotect((void *)page, len, PROT_READ | PROT_EXEC);
	__builtin___clear_cache((char *)at, (char *)at + 12);
}

// ---------------------------------------------------------------- Lua

static lua_State *L;

static int lua_start(void) {
	if (L) return 0;
	L = luaL_newstate();
	luaL_openlibs(L);
	const char *dir = getenv("HEADLESS_DB_LUA");
	const char *extra = getenv("HEADLESS_DB_PATH");
	char path[4096];
	snprintf(path, sizeof path, "package.path = '%s/?.lua;%s;' .. package.path", dir ? dir : ".", extra ? extra : "");
	if (luaL_dostring(L, path) != 0) {
		hlog("db: lua: %s", lua_tostring(L, -1));
		return -1;
	}
	lua_getglobal(L, "require");
	lua_pushstring(L, "dbbuild");
	if (lua_pcall(L, 1, 1, 0) != 0) {
		hlog("db: require dbbuild: %s", lua_tostring(L, -1));
		lua_close(L);
		L = NULL;
		return -1;
	}
	lua_setglobal(L, "dbbuild");
	return 0;
}

// dbbuild.<fn>(args...) -> 0 if it returned true, -1 (logged) otherwise
static int lua_callf(const char *fn, const char *a, const char *b) {
	if (lua_start() != 0) return -1;
	lua_getglobal(L, "dbbuild");
	lua_getfield(L, -1, fn);
	lua_remove(L, -2);
	lua_pushstring(L, a ? a : "");
	lua_pushstring(L, b ? b : "");
	if (lua_pcall(L, 2, 1, 0) != 0) {
		hlog("db: %s(%s): %s", fn, a ? a : "", lua_tostring(L, -1));
		lua_pop(L, 1);
		return -1;
	}
	int ok = lua_toboolean(L, -1);
	lua_pop(L, 1);
	return ok ? 0 : -1;
}

// ---------------------------------------------------------------- the hooks

#define MAX_DB 64
struct hooked {
	char name[96], mode[16];
	uintptr_t init_instance, instance;
	uint8_t *stub;
};
static struct hooked g_db[MAX_DB];
static int g_ndb;

// Called by the stub of database i in place of its InitInstance (on the thread SetupDatabases runs on).
__attribute__((used)) static long db_init_common(int i) {
	struct hooked *d = &g_db[i];
	double t = now();
	int rc = lua_callf("init", d->name, d->mode);
	if (rc != 0) {
		// Lua failed: the game's own Init (the virtual TSingleObjectGameDatabase::Init, slot 2)
		hlog("db: %s: Lua failed, the game's Init runs", d->name);
		void *inst = *(void **)d->instance;
		void (*init)(void *) = (*(void (***)(void *))inst)[2];
		init(inst);
	}
	hlog("db: %s (%s) done in %.3f s", d->name, d->mode, now() - t);
	return 1;
}

// A stub per database: mov edi, i; movabs rax, db_init_common; jmp rax
static uint8_t *make_stub(int i) {
	static uint8_t *page;
	static int used;
	if (!page) {
		page = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (page == MAP_FAILED) die(2, "stub page");
	}
	uint8_t *s = page + used;
	used += 32;
	s[0] = 0xBF;
	memcpy(s + 1, &i, 4);
	s[5] = 0x48;
	s[6] = 0xB8;
	void *to = (void *)db_init_common;
	memcpy(s + 7, &to, 8);
	s[15] = 0xFF;
	s[16] = 0xE0;
	return s;
}

static uintptr_t mangled_db_fn(const char *db, const char *fn, char *out, size_t n) {
	// TGameDatabase<X>::fn() first, then X::fn()
	snprintf(out, n, "_ZN13TGameDatabaseI%zu%.200sE%zu%.100sEv", strlen(db), db, strlen(fn), fn);
	uintptr_t a = hdb_sym(out);
	if (a) return a;
	snprintf(out, n, "_ZN%zu%.200s%zu%.100sEv", strlen(db), db, strlen(fn), fn);
	return hdb_sym(out);
}

static uintptr_t mangled_instance(const char *db) {
	char buf[512];
	snprintf(buf, sizeof buf, "_ZN13TGameDatabaseI%zu%.200sE10_pInstanceE", strlen(db), db);
	uintptr_t a = hdb_sym(buf);
	if (a) return a;
	snprintf(buf, sizeof buf, "_ZN%zu%.200s10_pInstanceE", strlen(db), db);
	return hdb_sym(buf);
}

// The census and the dump are written when the save is launched: every database and post-read
// pass is done by then. CFrontEndIdler::LaunchSave is detoured, and its first bytes are put back
// before it is called once.
static uintptr_t a_LaunchSave2;
static uint8_t g_launch_saved[12];

static void my_LaunchSave(void *fe, const void *path, int cloud, const void *cfg) {
	const char *census = getenv("HEADLESS_DB_CENSUS");
	const char *dump = getenv("HEADLESS_DB_DUMP");
	if ((census && *census) || (dump && *dump)) lua_callf("after_load", census, dump);
	hdb_restore(a_LaunchSave2, g_launch_saved);
	((void (*)(void *, const void *, int, const void *))a_LaunchSave2)(fe, path, cloud, cfg);
}

__attribute__((constructor)) static void db_init(void) {
	if (!g_base) return; // headless_init did not run (not the game)
	const char *spec = getenv("HEADLESS_DB");
	const char *census = getenv("HEADLESS_DB_CENSUS");
	const char *dump = getenv("HEADLESS_DB_DUMP");
	if (sym_index() != 0) die(2, "db: no symbol table");
	if (spec && *spec) {
		char *s = strdup(spec), *save = NULL;
		for (char *tok = strtok_r(s, ",", &save); tok && g_ndb < MAX_DB; tok = strtok_r(NULL, ",", &save)) {
			struct hooked *d = &g_db[g_ndb];
			char *colon = strchr(tok, ':');
			snprintf(d->mode, sizeof d->mode, "%s", colon ? colon + 1 : "lua");
			if (colon) *colon = 0;
			snprintf(d->name, sizeof d->name, "%s", tok);
			char buf[512];
			d->init_instance = mangled_db_fn(d->name, "InitInstance", buf, sizeof buf);
			d->instance = mangled_instance(d->name);
			if (!d->init_instance || !d->instance) {
				hlog("db: %s: InitInstance or _pInstance not found", d->name);
				continue;
			}
			d->stub = make_stub(g_ndb);
			detour(d->init_instance, d->stub);
			hlog("db: %s hooked (%s): InitInstance %#lx", d->name, d->mode, (unsigned long)(d->init_instance - g_base));
			g_ndb++;
		}
		free(s);
	}
	if ((census && *census) || (dump && *dump)) {
		a_LaunchSave2 = hdb_sym("_ZN14CFrontEndIdler10LaunchSaveERK7CStringbRK25CMultiplayerConfiguration");
		memcpy(g_launch_saved, (void *)a_LaunchSave2, 12);
		detour(a_LaunchSave2, (void *)my_LaunchSave);
	}
}

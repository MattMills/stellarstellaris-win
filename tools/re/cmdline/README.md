# Command line and startup RE helpers

The scripts the command line study (docs/stellaris-command-line-args.md, docs/startup.md) used on
hippo, against the GOG 4.5.2 build with PDB names in /root/fnm_tmp (names452.tsv, data452.tsv,
cg452.tsv, full452.asm, types452.pickle; see tools/re/spider/README.md). They ran from
/root/fnm_tmp/cmdargs, and build on /root/fnm_tmp/annotate.py and pdbtype.py. Their outputs stay
there: they are derived from the game.

- `annos.py <function name | rva | start-end> ...`: annotate.py (disassembly with the PDB names of
  call targets and globals, callers, callees) plus the C strings the code points at, shown as
  `'quoted'` literals. `start-end` disassembles a range, for functions whose call graph bounds are
  too short (`SDL_main`).
- `xrefs.py <va[:len]> ...`: the functions whose code references an address range (rip-relative
  operands), with `r`, `w` or `&` (address taken) and the offset. Globals read through a pointer
  are not seen.
- `callsites.py <rva> ...`: every call or tail jump to the targets, with what `rcx`, `rdx`, `r8`,
  `r9` were loaded with just before (strings, PDB names, immediates). Used on
  `CPdxCommandLine::HasOption` / `GetOptionArgument` / `FindIndexSorted` and the five `AddVariable`
  overloads.
- `strat.py <va or rva> ...`: the C string at an address.
- `optstrings.py <regex>`: the strings of the data sections that match, and the functions that
  reference them; the sweep for `-x`, `--x` and `+x` option names.
- `consolevars.py`: every console variable registered by a static initializer
  (`dynamic initializer for 'CONSOLEVAR_n'`): name, type (from the `AddVariable` overload), variable,
  value in the image, range (`r8`/`r9` or `xmm2`/`xmm3`). `cvtable.py` turns its output into the
  markdown table of the command line document, with `CCheatManager` members named and the ones
  `CCheatManager::ResetAllCheats` overwrites marked.
- `appscan.py <offsets>`: reads `grep -A N "# 0x143144ba0" full452.asm` and follows the register
  loaded with the `CApplication` instance, printing its uses at the given field offsets (how the
  auto client fields were found to be unread). It reads `names452_split.tsv`, names452.tsv with one
  name per line where identical functions were folded:
  `awk -F'\t' '{n=split($2,a," [|] "); for(i=1;i<=n;i++) print $1"\t"a[i]}' names452.tsv`.

Inlined `CPdxCommandLine` lookups build the key in a local `CString` from 8-, 4-, 2- and 1-byte
loads of the literal just before the `FindIndexSorted` call; `annos.py` shows the pieces, `strat.py`
the whole literal.

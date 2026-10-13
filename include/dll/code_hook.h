#pragma once

// Redirects the function at `target` to `replacement` while the game keeps running. *original
// receives a function that runs the original code (it is set before the target changes). The
// first instructions of the target (5 bytes or more) move to a trampoline: they must not transfer
// control; those relative to RIP are relocated. Returns false and sets *error (a static string)
// when the target cannot be hooked.
bool install_code_hook(void* target, void* replacement, void** original, const char** error);

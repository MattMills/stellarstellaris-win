#pragma once

// Redirects the function at `target` to `replacement` while the game keeps running. *original
// receives a function that runs the original code. The first instructions of the target (5 bytes
// or more) move unchanged to a trampoline, so they must not be relative to RIP or transfer
// control. Returns false and sets *error (a static string) when the target cannot be hooked.
bool install_code_hook(void* target, void* replacement, void** original, const char** error);

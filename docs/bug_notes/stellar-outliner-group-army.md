# Disapearing Army Outliner Group

In COutlinerGroupArmy::UpdateInternal there is an cmp and jl that will make the outliner army group dissapear once you have above x number of armies (I think it's around 1700), including defense and assault armies.

This appears like it was implemented because the army outliner was previously causing a CTD at that point. 

Per diagnosis below, it appears to be caused by an incorrect memory size calculation that drastically oversizes the required ram in the scratch space buffer.



# Notes


ebx = number of armies (0x1f38 in this game)
```
00007FF791F67CCD | 41:8BDC                        | mov ebx,r12d                     | outlinermembers.cpp:2260              	- ebx = 0x1f38, r12d = 0x1f38
00007FF791F67CD0 | C1E3 04                        | shl ebx,0x4                      |						- ebx = 0x1f380
00007FF791F67CD3 | 41:8BC4                        | mov eax,r12d                     | outlinermembers.cpp:2262			- eax = 0x1f38, r12d = 0x1f38
00007FF791F67CD6 | 41:0FAFC4                      | imul eax,r12d                    |						- eax*r12d = 0x1f38^2 = 0x3CE9C40 (decimal 63872064)
00007FF791F67CDA | 8D3CC5 00000000                | lea edi,qword ptr ds:[rax*8]     |						- load effective address rax*8 (rax = result of imul above), 0x3CE9C40*8 = 0x1E74E200 (decimal 510976512 or 487 MB)
00007FF791F67CE1 | 8D043B                         | lea eax,qword ptr ds:[rbx+rdi]   | outlinermembers.cpp:2265, rbx+rdi*1	- load effective address rbx+rdi (0x1f380+0x1e74e200) = 0x1E76D580 into EAX
00007FF791F67CE4 | 03C0                           | add eax,eax                      |						- DOUBLE eax 0x1E76D580*2 = 0x3CEDAB00 (decimal 1022208768 or 974.8 MB)
00007FF791F67CE6 | 3981 A0030000                  | cmp dword ptr ds:[rcx+0x3A0],eax | outlinermembers.cpp:2266, rcx+3A0	- compare eax against the scratch buffer size, 32 MB
00007FF791F67CEC | 0F8C 18040000                  | jl stellaris.7FF791F6810A        |						- jump out of function if less than
```
Right below this is a memset to set the scratch buffer space with the length in EAX to 0x0

Patching out mov eax,r12d and imul eax,r12d with xor rax,rax and mov eax,r12d eliminates this bug entirely.


# Manually patching:

Well if you want to manually patch it in Windows you can do this:



(This is simpler than it looks, I just wrote it in as much detail as I could, step by step)



1. Download x64dbg
2. Open stellaris.exe in x64dbg, it will start the executable and "pause" it.
3. click the Symbols tab
4. Double click on stellaris.exe in the left window
5. It will take you back to the CPU tab
6. Right click on the top left window, and go to Search for -> Current Module -> Pattern
7. in the "Hex " box copy paste

```
88 54 24 10 48 89 4c 24 08 53 55 56 57 41 54 41 55 41 56 41 57 48 83 ec 78 4c 8b e9 33 f6 8b ee 89 74 24 24
```

8. Click OK and 1 result will show up in the results, double click on it.
9. You're now at the assembly for the COutlinerGroupArmy::UpdateInternal function.
10. If you look from spot where the search result took you, you should see tthis about 10-20 lines down (the address on on the left most column will be different every time, it's the memory position the executable is loaded into):

```
00007FF6AC5F80BD | 41:8BDC                        | mov ebx,r12d
00007FF6AC5F80C0 | C1E3 04                        | shl ebx,0x4
00007FF6AC5F80C3 | 41:8BC4                        | mov eax,r12d
00007FF6AC5F80C6 | 41:0FAFC4                      | imul eax,r12d 
00007FF6AC5F80CA | 8D3CC5 00000000                | lea edi,qword ptr ds:[rax*8] 
```

11. Click on mov eax, r12d and hit spacebar, this will open the assemble window, allowing you to replace the existing assembly.
12. Make sure "fill with nops" is checked.
12. In the assembly window put xor rax,rax and click OK, the assemble window should go to the next line and show imul eax,r12d
13. replace imul eax,r12d with mov eax,r12d and click OK, then you can close the assembly text box
14. To make the changes permanent, right click the window and select "patches", this will open the patches window
15. You should see stellaris.exe on the left side, and the 6 bytes you've replaced on the right side
16. Click the patch file button to save a modified executable, you'll need to save it as stellaris.patch.exe or something like that, as you already have stellaris.exe open
17. You can close x64dbg (press the square stop button to stop the process you're debugging, then you can easily exit)
18. In file explorer delete stellaris.exe and make a copy of your patched version and rename it to stellaris.exe



FYI, just verify files to undo the change and overwrite the stellaris.exe with the original one, and any time you verify files you will un-fix it and need to copy your patched version back on top. Also, a new version comes with a new executable, so when there is a new version you'll need to make a new patched executable.



Alternatively, my stellarstellaris-win patcher will patch this at runtime (in memory) as well as a bunch of performance problems and a few other bugs once I fix a few more bugs, but it's still definitely "development" quality, I tend to be breaking things in weird ways with it as I work through how things work.





Once you're done, the section above should look like this:

```
00007FF6AC5F80C0 | C1E3 04                        | shl ebx,0x4 
00007FF6AC5F80C3 | 48:33C0                        | xor rax,rax  
00007FF6AC5F80C6 | 41:8BC4                        | mov eax,r12d 
00007FF6AC5F80C9 | 90                             | nop    
00007FF6AC5F80CA | 8D3CC5 00000000                | lea edi,qword ptr ds:[rax*8]   
```



Also, if you mess anything up you can either just start over or if you right click on a line you can do "restore selection" to return it to the original assembly.

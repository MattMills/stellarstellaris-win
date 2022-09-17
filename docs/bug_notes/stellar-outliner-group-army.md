# Disapearing Army Outliner Group

In COutlinerGroupArmy::UpdateInternal there is an cmp and jl that will make the outliner army group dissapear once you have above x number of armies (I think it's around 1700), including defense and assault armies.

This appears like it was implemented because the army outliner was previously causing a CTD at that point. 

Per diagnosis below, it appears to be caused by an incorrect memory size calculation that drastically oversizes the required ram in the scratch space buffer.



# Notes

ebx = number of armies (0x1f38 in this game)

00007FF791F67CCD | 41:8BDC                        | mov ebx,r12d                     | outlinermembers.cpp:2260              	- ebx = 0x1f38, r12d = 0x1f38
00007FF791F67CD0 | C1E3 04                        | shl ebx,0x4                      |						- ebx = 0x1f380
00007FF791F67CD3 | 41:8BC4                        | mov eax,r12d                     | outlinermembers.cpp:2262			- eax = 0x1f38, r12d = 0x1f38
00007FF791F67CD6 | 41:0FAFC4                      | imul eax,r12d                    |						- eax*r12d = 0x1f38^2 = 0x3CE9C40 (decimal 63872064)
00007FF791F67CDA | 8D3CC5 00000000                | lea edi,qword ptr ds:[rax*8]     |						- load effective address rax*8 (rax = result of imul above), 0x3CE9C40*8 = 0x1E74E200 (decimal 510976512 or 487 MB)
00007FF791F67CE1 | 8D043B                         | lea eax,qword ptr ds:[rbx+rdi]   | outlinermembers.cpp:2265, rbx+rdi*1	- load effective address rbx+rdi (0x1f380+0x1e74e200) = 0x1E76D580 into EAX
00007FF791F67CE4 | 03C0                           | add eax,eax                      |						- DOUBLE eax 0x1E76D580*2 = 0x3CEDAB00 (decimal 1022208768 or 974.8 MB)
00007FF791F67CE6 | 3981 A0030000                  | cmp dword ptr ds:[rcx+0x3A0],eax | outlinermembers.cpp:2266, rcx+3A0	- compare eax against the scratch buffer size, 32 MB
00007FF791F67CEC | 0F8C 18040000                  | jl stellaris.7FF791F6810A        |						- jump out of function if less than

Right below this is a memset to set the scratch buffer space with the length in EAX to 0x0

Patching out mov eax,r12d and imul eax,r12d with xor rax,rax and mov eax,r12d eliminates this bug entirely.
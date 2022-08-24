#pragma once


using namespace std;



#include "stellaris/generic.h"





typedef struct CApplication CApplication, *PCApplication;
typedef struct tagWNDCLASSEXA tagWNDCLASSEXA, *PtagWNDCLASSEXA;
typedef struct CClausewitzChecksumProvider CClausewitzChecksumProvider, *PCClausewitzChecksumProvider;

//typedef struct CPdxArray<CString,int> CPdxArray<CString,int>, *PCPdxArray<CString,int>;
//typedef struct CPdxArray<CPdxGameController*, int> CPdxArray<CPdxGameController*, int>, * PCPdxArray<CPdxGameController*, int>;
//typedef struct CPdxArray<SVibration,int> CPdxArray<SVibration,int>, *PCPdxArray<SVibration,int>;
typedef struct CChecksum CChecksum, *PCChecksum;
typedef struct CContextOwner CContextOwner, *PCContextOwner;
typedef struct CIdler CIdler, *PCIdler;
typedef struct CFixedPoint CFixedPoint, *PCFixedPoint;
typedef struct MD5 MD5, *PMD5;
typedef struct AudioContextAUDIO AudioContextAUDIO, *PAudioContextAUDIO;
typedef struct AnimationContextANIM AnimationContextANIM, *PAnimationContextANIM;
typedef enum EMatchmakingInterface {
    MATCHMAKING_INTERFACE_NONE=0,
    MATCHMAKING_INTERFACE_STEAM=1,
    MATCHMAKING_INTERFACE_RAIL=2,
    MATCHMAKING_INTERFACE_NAKAMA=3
} EMatchmakingInterface;
typedef struct MatchmakingContextMATCHMAKING MatchmakingContextMATCHMAKING, *PMatchmakingContextMATCHMAKING;
typedef struct ParticleContextPARTICLE ParticleContextPARTICLE, *PParticleContextPARTICLE;
typedef struct LightContextLIGHT LightContextLIGHT, *PLightContextLIGHT;
typedef struct EntityContextENTITY EntityContextENTITY, *PEntityContextENTITY;
typedef struct AchievementsContextACHIEVEMENTS AchievementsContextACHIEVEMENTS, *PAchievementsContextACHIEVEMENTS;
typedef struct CloudStorageContextCLOUDSTORAGE CloudStorageContextCLOUDSTORAGE, *PCloudStorageContextCLOUDSTORAGE;
typedef struct StoreContextSTORE StoreContextSTORE, *PStoreContextSTORE;
typedef struct UGCContextUGC UGCContextUGC, *PUGCContextUGC;
typedef struct BrowserContextBROWSER BrowserContextBROWSER, *PBrowserContextBROWSER;
typedef struct FontContextFONT FontContextFONT, *PFontContextFONT;
typedef struct ContextPOPS_HANDLE ContextPOPS_HANDLE, *PContextPOPS_HANDLE;
typedef struct CPdxGameControllerGroup CPdxGameControllerGroup, *PCPdxGameControllerGroup;
//typedef struct _Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>>,1> _Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>>,1>, *P_Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>>,1>;

typedef struct fixed_int64 fixed_int64, *Pfixed_int64;
typedef struct GamepadGamepadContext GamepadGamepadContext, *PGamepadGamepadContext;
//typedef struct _String_val<std::_Simple_types<char>> _String_val<std::_Simple_types<char>>, *P_String_val<std::_Simple_types<char>>;
typedef struct CPdxGameController CPdxGameController, *PCPdxGameController;
typedef union _Bxty _Bxty, *P_Bxty;
typedef struct SGamepadState SGamepadState, *PSGamepadState;


typedef struct SVibration SVibration, *PSVibration;

struct ParticleContextPARTICLE {
};

union _Bxty {
    char _Buf[16];
    char * _Ptr;
    char _Alias[16];
};

struct CPdxGameControllerGroup {
    undefined field0_0x0;
    undefined field1_0x1;
    undefined field2_0x2;
    undefined field3_0x3;
    undefined field4_0x4;
    undefined field5_0x5;
    undefined field6_0x6;
    undefined field7_0x7;
    class CPdxArray<CPdxGameController, int> _GameControllers;
    int _nMainController;
    undefined field10_0x24;
    undefined field11_0x25;
    undefined field12_0x26;
    undefined field13_0x27;
    struct GamepadGamepadContext * _ContextHandle;
};

struct MD5 {
    uint state[4];
    uint count[2];
    uchar buffer[64];
    uchar digest[16];
    uchar finalized;
};


struct fixed_int64 {
    __int64 m_nVal;
};

struct CFixedPoint {
    struct fixed_int64 _Value;
};

struct CChecksum {
    struct CFixedPoint _vVersionNumber;
    struct MD5 _Executable;
    struct MD5 _Data;
    struct CString _szName;
    bool _bFinalized;
    struct CString _HexDataDigest;
    struct CString _HexExeDigest;
    struct CString _RawDataDigest;
    struct CString _RawExeDigest;
};

/*struct tagWNDCLASSEXA {
    uint cbSize;
    uint style;
    void * lpfnWndProc;
    int cbClsExtra;
    int cbWndExtra;
    struct HINSTANCE__ * hInstance;
    struct HICON__ * hIcon;
    struct HICON__ * hCursor;
    struct HBRUSH__ * hbrBackground;
    char * lpszMenuName;
    char * lpszClassName;
    struct HICON__ * hIconSm;
};*/


struct CApplication {
    undefined field0_0x0;
    undefined field1_0x1;
    undefined field2_0x2;
    undefined field3_0x3;
    undefined field4_0x4;
    undefined field5_0x5;
    undefined field6_0x6;
    undefined field7_0x7;
    qword _pIdler;
    bool _bHasNewIdler;
    undefined field10_0x11;
    undefined field11_0x12;
    undefined field12_0x13;
    undefined field13_0x14;
    undefined field14_0x15;
    undefined field15_0x16;
    undefined field16_0x17;
    struct CString _Name;
    struct CString _Product;
    struct CString _Platform;
    struct tagWNDCLASSEXA _WindowsClass;
    __uint64 _hWnd;
    qword _pNextIdler;
    qword _pOldIdler;
    bool _bRememberOldIdler;
    bool _bIsFullscreen;
    bool _bIsBorderless;
    bool _bDoQuit;
    bool _bIsInDebugMode;
    bool _bActiveWindow;
    bool _bLoadAssetsAtInit;
    undefined field31_0xe7;
    struct CClausewitzChecksumProvider * _pCheckSumProvider;
    bool _bIsAutoClient;
    undefined field34_0xf1;
    undefined field35_0xf2;
    undefined field36_0xf3;
    undefined field37_0xf4;
    undefined field38_0xf5;
    undefined field39_0xf6;
    undefined field40_0xf7;
    struct CString _AutoClientIPAdress;
    struct CString _AutoClientServerName;
    struct CString _AutoClientPassword;
    struct CString _AutoClientCountryTag;
    struct CString _AutoClientNick;
    int _nNumClients;
    undefined field47_0x19c;
    undefined field48_0x19d;
    undefined field49_0x19e;
    undefined field50_0x19f;
    class CPdxArray<CString,int> _Filter;
    bool _bChecksumCalculated;
    undefined field53_0x1b9;
    undefined field54_0x1ba;
    undefined field55_0x1bb;
    undefined field56_0x1bc;
    undefined field57_0x1bd;
    undefined field58_0x1be;
    undefined field59_0x1bf;
    struct CChecksum _GameVersion;
    struct CString _GameVersionSerialized;
    bool _bHasQuitEvent;
    bool _bCanToggleFullscreen;
    undefined field64_0x36a;
    undefined field65_0x36b;
    undefined field66_0x36c;
    undefined field67_0x36d;
    undefined field68_0x36e;
    undefined field69_0x36f;
    double _vLastUpdateTime;
    double _vLastUpdateTimePostIdle;
    double _vFrameDuration;
    __uint64 _nCurrentFrame;
    bool _bUpdateFrameAnimationController;
    undefined field75_0x391;
    undefined field76_0x392;
    undefined field77_0x393;
    undefined field78_0x394;
    undefined field79_0x395;
    undefined field80_0x396;
    undefined field81_0x397;
    uchar * _pUnsafeScratchBuffer;
    int _nUnsafeScratchBufferSize;
    uint _nPreferredScratchBufferSize;
    struct CContextOwner * _MasterContexts;
};

struct AudioContextAUDIO {
};

struct CIdler {
    undefined field0_0x0;
    undefined field1_0x1;
    undefined field2_0x2;
    undefined field3_0x3;
    undefined field4_0x4;
    undefined field5_0x5;
    undefined field6_0x6;
    undefined field7_0x7;
};


struct BrowserContextBROWSER {
};

struct EntityContextENTITY {
};

struct SVibration {
    float _vSlowStrength;
    float _vFastStrength;
    float _vDuration;
};

struct CloudStorageContextCLOUDSTORAGE {
};

struct CPdxGameController {
    undefined field0_0x0;
    undefined field1_0x1;
    undefined field2_0x2;
    undefined field3_0x3;
    undefined field4_0x4;
    undefined field5_0x5;
    undefined field6_0x6;
    undefined field7_0x7;
    struct GamepadGamepadContext * _Context;
    uint _nIndex;
    undefined field10_0x14;
    undefined field11_0x15;
    undefined field12_0x16;
    undefined field13_0x17;
    struct SGamepadState * _pState;
    class CPdxArray<SVibration, int> _Pattern;
    int _nPatternIndex;
    float _vPatternTime;
};

struct CClausewitzChecksumProvider {
};

struct MatchmakingContextMATCHMAKING {
};

struct CContextOwner {
    struct AudioContextAUDIO * _AudioContext;
    struct AnimationContextANIM * _AnimationContext;
    enum EMatchmakingInterface _MatchmakingInterface;
    struct MatchmakingContextMATCHMAKING * _MatchmakingContext;
    struct ParticleContextPARTICLE * _ParticleContext;
    struct LightContextLIGHT * _LightContext;
    struct EntityContextENTITY * _EntityContext;
    struct AchievementsContextACHIEVEMENTS * _AchievementsContext;
    struct CloudStorageContextCLOUDSTORAGE * _CloudStorageContext;
    struct StoreContextSTORE * _StoreContext;
    struct UGCContextUGC * _UGCContext;
    struct BrowserContextBROWSER * _BrowserContext;
    struct FontContextFONT * _FontContext;
    struct ContextPOPS_HANDLE * _POPSContext;
    struct CPdxGameControllerGroup * _pGameControllerGroup;
};

struct GamepadGamepadContext {
};

struct ContextPOPS_HANDLE {
};

struct UGCContextUGC {
};

struct AchievementsContextACHIEVEMENTS {
};

struct StoreContextSTORE {
};

struct FontContextFONT {
};

struct SGamepadState {
    float _analogs[6];
    bool _analogsInDeadZone[6];
    bool _analogsInDeadZoneChanged[6];
    bool _buttonsDown[14];
    bool _buttonsChanged[14];
    bool _connected;
};

struct LightContextLIGHT {
};


struct AnimationContextANIM {
};


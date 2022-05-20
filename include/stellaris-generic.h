#pragma once

#include <string>
#include <cstring>
#include <vector>
#include <unordered_map>
#include <atomic>
#include <deque>
#include <queue>
#include <map>
#include <mutex>

#include "lib/eigen/Eigen/core"
#include "hooking_windows.h"

/*
#define _AFXDLL
#define _ATL_CSTRING_EXPLICIT_CONSTRUCTORS 
#define _AFX_ALL_WARNINGS

#include <afxwin.h>         // MFC core and standard components
#include <afxext.h>         // MFC extensions
*/
//#define UMDF_USING_NTSTATUS
//#include <atltypes.h>
//#include <atltempl.h>


typedef unsigned int        ImageBaseOffset32;
typedef unsigned char       byte;
typedef char                sbyte;
typedef char                signedchar;
typedef unsigned char       uchar;
typedef unsigned char       unsignedchar;

typedef unsigned int        dword;
typedef unsigned long long  qword;

typedef unsigned short      ushort;
typedef unsigned short      word;

typedef long double         longdouble;
typedef long long           longlong;


typedef unsigned int        uint;
typedef unsigned int        unsignedint;
typedef unsigned long       ulong;
typedef unsigned long long  ulonglong;
typedef unsigned long long  __uint64;

typedef unsigned char       undefined;
typedef unsigned char       undefined1;
typedef unsigned short      undefined2;
typedef unsigned int        undefined4;
typedef unsigned long long  undefined8;

typedef struct CStringconst {
    char val[64]; // ???
} CStringconst;

template <typename T> struct CPdxAtomic {
    struct atomic<T> _Value;
};


template <typename T, uint size, typename T2> struct CPdxHybridArray {
    undefined field0_0x0;
    undefined field1_0x1;
    undefined field2_0x2;
    undefined field3_0x3;
    undefined field4_0x4;
    undefined field5_0x5;
    undefined field6_0x6;
    undefined field7_0x7;
    undefined field8_0x8;
    undefined field9_0x9;
    undefined field10_0xa;
    undefined field11_0xb;
    undefined field12_0xc;
    undefined field13_0xd;
    undefined field14_0xe;
    undefined field15_0xf;
    undefined field16_0x10;
    undefined field17_0x11;
    undefined field18_0x12;
    undefined field19_0x13;
    undefined field20_0x14;
    undefined field21_0x15;
    undefined field22_0x16;
    undefined field23_0x17;
    union _Align_type<double, sizeof(T)> _StaticData[size];
};
//template <typename T> using  CList = CList<T>;



//typedef struct CString CString, * PCString;

struct CString {
    basic_string<char, std::char_traits<char>, std::allocator<char>> _str;
};


//HOW DO TEMPLATES WORK
//SEND HELP!
template <typename T, typename T2> class CPdxArray {
	private:
		qword unk;


	public:
        CPdxArray(T arr[] = new T[1], T2 capacity = 1);

        T* _pData;
		T2 _nCapacity;
		T2 _nSize;
};

template <typename T, typename T2> CPdxArray<T, T2>::CPdxArray(T arr[], T2 capacity) {
	_pData = new T[capacity];
	_nCapacity = capacity;
    _nSize = 0;

	for (T2 i = 0; i < capacity; i++)
		_pData[i] = arr[i];
}



template <typename T> class CVector2 {
	public: 
		T x;
		T y;
};

template <typename T> class CVector3 {
public:
    T x;
    T y;
    T z;
};

template <typename T> class CPoint {
	public:
		T _x;
		T _y;
};

template <typename T> class CList {
	public:
		struct Node* _pHead;
		struct Node* _pTail;
		int _nSize;
		bool _IsLocked;

};



template <typename T, typename T2> struct TVariableValueTuple{
    T _X;
    T _Y;
    T2 _nValueType;
};

struct SAdresspair {
    uint _nAdress;
    ushort _nPort;
};

template <typename T, typename T2> class CValueAssociativeArray {
    
    struct CPair {
        T _Key;
        T2 _Data;
    };

    class CPdxArray<CValueAssociativeArray<T, T2>::CPair, int> _Pairs;
};

template <typename T, int N> class CPdxScopedPtrImpl {
    T* _pPtr;
};

template <typename T> struct CPdxPtr {
    T* _pPtr;
};

template <typename T> struct CPdxRect {
    T _Left;
    T _Top;
    T _Width;
    T _Height;
};

template <typename T> class CRect {
    CPoint<T> _Origin;
    CPoint<T> _Extension;
};

template <typename T> class CScrollbarObserverGlue {
    undefined field0_0x0;
    undefined field1_0x1;
    undefined field2_0x2;
    undefined field3_0x3;
    undefined field4_0x4;
    undefined field5_0x5;
    undefined field6_0x6;
    undefined field7_0x7;
    T* _Obj;
    void* _F;
    undefined field10_0x18;
    undefined field11_0x19;
    undefined field12_0x1a;
    undefined field13_0x1b;
    undefined field14_0x1c;
    undefined field15_0x1d;
    undefined field16_0x1e;
    undefined field17_0x1f;
    void* _pOnValueIncrease;
    undefined field19_0x28;
    undefined field20_0x29;
    undefined field21_0x2a;
    undefined field22_0x2b;
    undefined field23_0x2c;
    undefined field24_0x2d;
    undefined field25_0x2e;
    undefined field26_0x2f;
    void* _pOnValueDecrease;
    undefined field28_0x38;
    undefined field29_0x39;
    undefined field30_0x3a;
    undefined field31_0x3b;
    undefined field32_0x3c;
    undefined field33_0x3d;
    undefined field34_0x3e;
    undefined field35_0x3f;
    void* _pOnValueSet;
    undefined field37_0x48;
    undefined field38_0x49;
    undefined field39_0x4a;
    undefined field40_0x4b;
    undefined field41_0x4c;
    undefined field42_0x4d;
    undefined field43_0x4e;
    undefined field44_0x4f;
    void* _pOnScrollReleased;
    undefined field46_0x58;
    undefined field47_0x59;
    undefined field48_0x5a;
    undefined field49_0x5b;
    undefined field50_0x5c;
    undefined field51_0x5d;
    undefined field52_0x5e;
    undefined field53_0x5f;
};

template <typename T> struct STernaryTrait {
    bool undefined;
};

struct LockData {
    struct CGuiType* _Data;
    struct CString _Key;
    bool _isUsed;
};

template <typename T, typename T2, typename T3> struct CHashTable {
    //<CString, CBitmapFont, ClassicHashKeyTraits<CString, CBitmapFont>>
    uint _nSize;
    uint _nCapacity;
    struct Node** _pArray;
};

template <typename T, typename T2> struct ClassicHashKeyTraits {
    unsigned char _invalid;
};

template <typename T, typename T2> struct NoRefHashKeyTraits {
    unsigned char _invalid;
};

template <typename T, int default_value> struct TPdxDefVal {
    T _Value = static_recast<T>(default_value);
};

template <typename T, typename T2> class CTernary {

    undefined field0_0x0;
    undefined field1_0x1;
    undefined field2_0x2;
    undefined field3_0x3;
    undefined field4_0x4;
    undefined field5_0x5;
    undefined field6_0x6;
    undefined field7_0x7;
    struct Node* _pHead;
    bool _isLocked;
    undefined field10_0x11;
    undefined field11_0x12;
    undefined field12_0x13;
    int _nSize;
    struct LockData** _ppArray;
    CList<typename CTernary<T, T2>::LockData*> _LockList;
    bool _bIsReload;
    undefined field17_0x39;
    undefined field18_0x3a;
    undefined field19_0x3b;
    undefined field20_0x3c;
    undefined field21_0x3d;
    undefined field22_0x3e;
    undefined field23_0x3f;
    class LockData {
        T _Data;
        CString _Key;
        bool _isUsed;
    };
};






template <typename T> class CButtonObserverGlue {
    undefined field0_0x0;
    undefined field1_0x1;
    undefined field2_0x2;
    undefined field3_0x3;
    undefined field4_0x4;
    undefined field5_0x5;
    undefined field6_0x6;
    undefined field7_0x7;
    T* _Obj;
    void* _pOnClick;
    undefined field10_0x18;
    undefined field11_0x19;
    undefined field12_0x1a;
    undefined field13_0x1b;
    undefined field14_0x1c;
    undefined field15_0x1d;
    undefined field16_0x1e;
    undefined field17_0x1f;
    void* _pOnDown;
    undefined field19_0x28;
    undefined field20_0x29;
    undefined field21_0x2a;
    undefined field22_0x2b;
    undefined field23_0x2c;
    undefined field24_0x2d;
    undefined field25_0x2e;
    undefined field26_0x2f;
    void* _pOnUp;
    undefined field28_0x38;
    undefined field29_0x39;
    undefined field30_0x3a;
    undefined field31_0x3b;
    undefined field32_0x3c;
    undefined field33_0x3d;
    undefined field34_0x3e;
    undefined field35_0x3f;
    void* _pOnDrag;
    undefined field37_0x48;
    undefined field38_0x49;
    undefined field39_0x4a;
    undefined field40_0x4b;
    undefined field41_0x4c;
    undefined field42_0x4d;
    undefined field43_0x4e;
    undefined field44_0x4f;
    void* _pOnOver;
    undefined field46_0x58;
    undefined field47_0x59;
    undefined field48_0x5a;
    undefined field49_0x5b;
    undefined field50_0x5c;
    undefined field51_0x5d;
    undefined field52_0x5e;
    undefined field53_0x5f;
    void* _pOnDblClick;
    undefined field55_0x68;
    undefined field56_0x69;
    undefined field57_0x6a;
    undefined field58_0x6b;
    undefined field59_0x6c;
    undefined field60_0x6d;
    undefined field61_0x6e;
    undefined field62_0x6f;
    void* _pOnObjectClick;
    undefined field64_0x78;
    undefined field65_0x79;
    undefined field66_0x7a;
    undefined field67_0x7b;
    undefined field68_0x7c;
    undefined field69_0x7d;
    undefined field70_0x7e;
    undefined field71_0x7f;
    void* _pOnObjectRightClick;
    undefined field73_0x88;
    undefined field74_0x89;
    undefined field75_0x8a;
    undefined field76_0x8b;
    undefined field77_0x8c;
    undefined field78_0x8d;
    undefined field79_0x8e;
    undefined field80_0x8f;
    void* _pOnObjectDblClick;
    undefined field82_0x98;
    undefined field83_0x99;
    undefined field84_0x9a;
    undefined field85_0x9b;
    undefined field86_0x9c;
    undefined field87_0x9d;
    undefined field88_0x9e;
    undefined field89_0x9f;
    void* _pOnObjectLeave;
    undefined field91_0xa8;
    undefined field92_0xa9;
    undefined field93_0xaa;
    undefined field94_0xab;
    undefined field95_0xac;
    undefined field96_0xad;
    undefined field97_0xae;
    undefined field98_0xaf;
    void* _pOnWheel;
    undefined field100_0xb8;
    undefined field101_0xb9;
    undefined field102_0xba;
    undefined field103_0xbb;
    undefined field104_0xbc;
    undefined field105_0xbd;
    undefined field106_0xbe;
    undefined field107_0xbf;
    void* _pOnObjectWheel;
    undefined field109_0xc8;
    undefined field110_0xc9;
    undefined field111_0xca;
    undefined field112_0xcb;
    undefined field113_0xcc;
    undefined field114_0xcd;
    undefined field115_0xce;
    undefined field116_0xcf;
};



template <typename T> struct CButtonObjectGlue {
    undefined field0_0x0;
    undefined field1_0x1;
    undefined field2_0x2;
    undefined field3_0x3;
    undefined field4_0x4;
    undefined field5_0x5;
    undefined field6_0x6;
    undefined field7_0x7;
    T* _Obj;
    void* _pOnDown;
    undefined field10_0x18;
    undefined field11_0x19;
    undefined field12_0x1a;
    undefined field13_0x1b;
    undefined field14_0x1c;
    undefined field15_0x1d;
    undefined field16_0x1e;
    undefined field17_0x1f;
    void* _pOnUp;
    undefined field19_0x28;
    undefined field20_0x29;
    undefined field21_0x2a;
    undefined field22_0x2b;
    undefined field23_0x2c;
    undefined field24_0x2d;
    undefined field25_0x2e;
    undefined field26_0x2f;
    void* _pOnOver;
    undefined field28_0x38;
    undefined field29_0x39;
    undefined field30_0x3a;
    undefined field31_0x3b;
    undefined field32_0x3c;
    undefined field33_0x3d;
    undefined field34_0x3e;
    undefined field35_0x3f;
    void* _pOnObjectClick;
    undefined field37_0x48;
    undefined field38_0x49;
    undefined field39_0x4a;
    undefined field40_0x4b;
    undefined field41_0x4c;
    undefined field42_0x4d;
    undefined field43_0x4e;
    undefined field44_0x4f;
    void* _pOnObjectClickWithParams;
    undefined field46_0x58;
    undefined field47_0x59;
    undefined field48_0x5a;
    undefined field49_0x5b;
    undefined field50_0x5c;
    undefined field51_0x5d;
    undefined field52_0x5e;
    undefined field53_0x5f;
    void* _pOnObjectRightClick;
    undefined field55_0x68;
    undefined field56_0x69;
    undefined field57_0x6a;
    undefined field58_0x6b;
    undefined field59_0x6c;
    undefined field60_0x6d;
    undefined field61_0x6e;
    undefined field62_0x6f;
    void* _pOnObjectDblClick;
    undefined field64_0x78;
    undefined field65_0x79;
    undefined field66_0x7a;
    undefined field67_0x7b;
    undefined field68_0x7c;
    undefined field69_0x7d;
    undefined field70_0x7e;
    undefined field71_0x7f;
    void* _pOnObjectLeave;
    undefined field73_0x88;
    undefined field74_0x89;
    undefined field75_0x8a;
    undefined field76_0x8b;
    undefined field77_0x8c;
    undefined field78_0x8d;
    undefined field79_0x8e;
    undefined field80_0x8f;
    void* _pOnObjectWheel;
    undefined field82_0x98;
    undefined field83_0x99;
    undefined field84_0x9a;
    undefined field85_0x9b;
    undefined field86_0x9c;
    undefined field87_0x9d;
    undefined field88_0x9e;
    undefined field89_0x9f;
    void* _pOnDrag;
    undefined field91_0xa8;
    undefined field92_0xa9;
    undefined field93_0xaa;
    undefined field94_0xab;
    undefined field95_0xac;
    undefined field96_0xad;
    undefined field97_0xae;
    undefined field98_0xaf;
};

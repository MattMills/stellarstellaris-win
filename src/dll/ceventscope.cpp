#include "dll/ceventscope.h"

//TODO: this is stupid
const char* enum_to_string_escopetype(int32_t value) {
    switch (value) {
    case 0:
        return "SCOPE_NO_CHECK";
    case 1:
        return "SCOPE_MEGASTRUCTURE";
    case 2:
        return "SCOPE_PLANET";
    case 4:
        return "SCOPE_COUNTRY";
    case 8:
        return "SCOPE_SHIP";
    case 16:
        return "SCOPE_POP";
    case 32:
        return "SCOPE_FLEET";
    case 64:
        return "SCOPE_GALACTIC_OBJECT";
    case 128:
        return "SCOPE_LEADER";
    case 256:
        return "SCOPE_ARMY";
    case 512:
        return "SCOPE_AMBIENT_OBJECT";
    case 1024:
        return "SCOPE_SPECIES";
    case 4096:
        return "SCOPE_DESIGN";
    case 8192:
        return "SCOPE_POP_FACTION";
    case 16384:
        return "SCOPE_WAR";
    case 32768:
        return "SCOPE_FEDERATION";
    case 65536:
        return "SCOPE_STARBASE";
    case 131072:
        return "SCOPE_DEPOSIT";
    case 262144:
        return "SCOPE_OBSERVER";
    case 524288:
        return "SCOPE_SECTOR";
    case 1048576:
        return "SCOPE_NO_SCOPE";
    case 2097152:
        return "SCOPE_ARCHAEOLOGICAL_SITE";
    case 4194304:
        return "SCOPE_FIRST_CONTACT";
    case 8388608:
        return "SCOPE_SPY_NETWORK";
    case 16777216:
        return "SCOPE_ESPIONAGE_OPERATION";
    case 33554432:
        return "SCOPE_ESPIONAGE_ASSET";
    case 67108864:
        return "SCOPE_DLC_RECOMMENDATION";
    case 268435456:
        return "SCOPE_SITUATION";
    }
    return "SCOPE_ERROR_INVALID";
}
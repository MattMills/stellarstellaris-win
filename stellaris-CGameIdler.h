#pragma once

#include "stellaris-generic.h"
using namespace std;
using namespace Eigen;



typedef enum IdlerType {
    _IDLERTYPE_INGAME_ = 0,
    _IDLERTYPE_FRONTEND_ = 1,
    _IDLERTYPE_COMBAT_DEBUG_ = 2
} IdlerType;

typedef enum FontFormatting {
    _FF_LEFT_ALIGNED_ = 0,
    _FF_RIGHT_ALIGNED_ = 1,
    _FF_CENTRE_ = 2
} FontFormatting;

typedef enum EGuiOrientation {
    UPPER_LEFT = 0,
    UPPER_RIGHT = 1,
    LOWER_LEFT = 2,
    LOWER_RIGHT = 3,
    CENTER = 4,
    CENTER_UP = 5,
    CENTER_DOWN = 6
} EGuiOrientation;

typedef enum ESelectionState {
    SELECTION_STATE_NONE = 0,
    SELECTION_STATE_TRIGGERED = 1
} ESelectionState;

typedef enum EGuiVersion {
    GUI_VERSION_MOUSE = 0,
    GUI_VERSION_GAMEPAD = 1,
    GUI_VERSION_INVALID = 2
} EGuiVersion;

typedef enum MOUSE_CURSOR {
    CURSOR_0 = 0,
    CURSOR_NORMAL = 0,
    CURSOR_1 = 1,
    CURSOR_BUSY = 1,
    CURSOR_2 = 2,
    CURSOR_DONT_CLICK_HERE = 2,
    CURSOR_3 = 3,
    CURSOR_RESIZE = 3,
    CURSOR_4 = 4,
    CURSOR_5 = 5,
    CURSOR_6 = 6,
    CURSOR_7 = 7,
    CURSOR_8 = 8,
    CURSOR_9 = 9,
    CURSOR_10 = 10,
    CURSOR_11 = 11,
    CURSOR_12 = 12,
    CURSOR_13 = 13,
    CURSOR_14 = 14,
    CURSOR_15 = 15,
    CURSOR_16 = 16,
    CURSOR_17 = 17,
    CURSOR_18 = 18,
    CURSOR_19 = 19,
    CURSOR_20 = 20,
    CURSOR_21 = 21,
    CURSOR_22 = 22,
    CURSOR_23 = 23,
    CURSOR_24 = 24,
    CURSOR_25 = 25,
    CURSOR_26 = 26,
    CURSOR_27 = 27,
    NUM_CURSORS = 28
} MOUSE_CURSOR;

typedef enum ECursorMode {
    CURSOR_MODE_SYSTEM = 0,
    CURSOR_MODE_VIRTUAL = 1,
    CURSOR_MODE_DISABLED = 2
} ECursorMode;

typedef enum SCISSOR_BEHAVIOUR {
    _SCISSOR_DEFAULT_ = 0,
    _SCISSOR_PROPAGATE_ = 1,
    _SCISSOR_IGNORE_ = 2
} SCISSOR_BEHAVIOUR;

typedef enum EDragHandler {
    DRAGHANDLER_UNKNOWN = 0,
    DRAGHANDLER_MOUSE = 1,
    DRAGHANDLER_TOUCH = 2
} EDragHandler;

typedef enum checkBoxState {
    CBOX_UP = 0,
    CBOX_DOWN = 1,
    CBOX_OVER = 2
} checkBoxState;

typedef enum EActionNavigationMode {
    ACTION_NAVIGATION_MODE_STEP = 0,
    ACTION_NAVIGATION_MODE_SCROLL_FIRST_ORDER = 1,
    ACTION_NAVIGATION_MODE_SCROLL_SECOND_ORDER = 2
} EActionNavigationMode;

typedef enum EFontVerticalAlignment {
    FONT_TOP_ALIGNED = 0,
    FONT_CENTER_ALIGNED = 1,
    FONT_BOTTOM_ALIGNED = 2
} EFontVerticalAlignment;

typedef enum EFadingState {
    NOFADE = 0,
    FADEIN = 1,
    FADEOUT = 2
} EFadingState;

typedef enum EGameGuiAnimationType {
    ANIMATION_NONE = 0,
    ANIMATION_ACCELERATED = 1,
    ANIMATION_DECELERATED = 2,
    ANIMATION_SMOOTHSTEP = 3,
    ANIMATION_LINEAR = 4
} EGameGuiAnimationType;

typedef enum EAnimationState {
    NONE = 0,
    SHOW = 1,
    HIDE = 2
} EAnimationState;

typedef enum EGameGuiOrientationType {
    ORIENTATION_UPPERLEFT = 0,
    ORIENTATION_UPPERRIGHT = 1,
    ORIENTATION_LOWERLEFT = 2,
    ORIENTATION_LOWERRIGHT = 3,
    ORIENTATION_CENTER = 4,
    ORIENTATION_LEFT = 5,
    ORIENTATION_RIGHT = 6,
    ORIENTATION_CENTERUP = 7,
    ORIENTATION_CENTERDOWN = 8
} EGameGuiOrientationType;

typedef enum EPeekState {
    PEEK_OPEN = 0,
    PEEK_CLOSED = 1,
    PEEK_PEEK = 2
} EPeekState;

typedef enum ESessionState {
    DISCONNECTED = 0,
    CONNECTING = 1,
    RECONNECTING = 2,
    RECONNECTING_FAILED = 3,
    CONNECTED = 4,
    WAITING_FOR_GAMESTATE = 5,
    ASYNCHRONOUSLY_CONNECTED = 6,
    REFUSED = 7,
    KICKED = 8,
    IS_BANNED = 9,
    STATE_NAME_TAKEN = 10,
    STATE_NAME_AVAILABLE = 11,
    HOTJOIN_ASKING_FOR_JOIN = 12,
    HOTJOIN_WAITING_FOR_SAVE = 13,
    HOTJOIN_IN_LOBBY = 14,
    HOTJOIN_REFUSED = 15,
    BAD_VERSION = 16,
    PASSWORD_REQUEST = 17,
    BAD_PASSWORD = 18,
    STATE_JOIN_DISABLED = 19,
    SESSION_STATE_INVALID_PRIVILEGES = 20
} ESessionState;

typedef enum ESessionBasicType {
    CLIENT_SESSION = 0,
    SERVER_SESSION = 1,
    DUMMY_SESSION = 2,
    META_SERVER_SESSION = 3
} ESessionBasicType;

typedef enum ESessionType {
    NO_SESSION = 0,
    DUMMY_SESSION_TYPE = 1,
    DIPLOMACY_NETWORK_CLIENT = 2,
    DIPLOMACY_NETWORK_SERVER = 3,
    CLAUSEWITZ_METASERVER = 4,
    LOCAL_SERVER_SESSION = 5,
    EU3_NETWORK_SERVER = 6,
    EU3_NETWORK_CLIENT = 7,
    EU3_NETWORK_SERVER_RUNNING = 8,
    EU3_NETWORK_SERVER_STARTING = 9
} ESessionType;

typedef enum EHotjoinDeclineReasons {
    HOTJOINREASON_DECLINE = 0,
    HOTJOINREASON_BUSY = 1,
    HOTJOINREASON_NAMECONFLICT = 2,
    HOTJOINREASON_DISABLED = 3,
    HOTJOINREASON_LOADING = 4,
    HOTJOINREASON_GENERATING = 5,
    HOTJOINREASON_HOTJOIN = 6,
    HOTJOINREASON_NUMOF = 7
} EHotjoinDeclineReasons;

typedef enum ENetServerAddressType {
    NET_ADDRESS_TYPE_NULL = 0,
    NET_ADDRESS_TYPE_IP_PORT = 1,
    NET_ADDRESS_TYPE_UINT64 = 2,
    NET_ADDRESS_TYPE_PDX_ID = 3,
    NET_ADDRESS_TYPE_RAIL_ID = 4,
    NET_ADDRESS_TYPE_NAKAMA_MATCH_ID = 5
} ENetServerAddressType;

typedef enum EState {
    Waiting = 0,
    Shapes = 1,
    Blobs = 2,
    Centroids = 3,
    Quads = 4,
    RegeneratingNames = 5,
    Pins = 6
} EState;

typedef enum EAnimationType {
    ACCELERATED = 0,
    DECELERATED = 1,
    SMOOTHSTEP = 2,
    LINEAR = 3
} EAnimationType;

typedef enum LOAD_TYPE {
    ALWAYS = 0,
    FRONTEND = 1,
    BACKEND = 2,
    INGAME = 3
} LOAD_TYPE;

typedef enum EModKey {
    MODKEY_ANY = -1,
    MODKEY_NONE = 0,
    MODKEY_CTRL = 1,
    MODKEY_ALT = 2,
    MODKEY_SHIFT = 4,
    MODKEY_OS = 8
} EModKey;

typedef enum EKeyEventType {
    KEYDOWN = 0,
    KEYUP = 1
} EKeyEventType;

typedef enum EEventType {
    MOUSEEVENT = 0,
    KEYEVENT = 1,
    TEXTINPUTEVENT = 2,
    TEXTEDITEDEVENT = 3,
    TOUCHEVENT = 4,
    GAMEPADEVENT = 5,
    ACTIONEVENT = 6,
    INVALID = 7
} EEventType;

typedef enum EGameStatus {
    INVALID_STATUS = 0,
    LOBBY = 1,
    RUNNING = 2,
    CUSTOM = 3
} EGameStatus;

typedef enum EHotjoinAvailability {
    HOTJOINAVAILABILITY_AVAILABLE = 0,
    HOTJOINAVAILABILITY_GENERATING = 1,
    HOTJOINAVAILABILITY_LOADING = 2,
    HOTJOINAVAILABILITY_HOTJOIN = 3
} EHotjoinAvailability;

typedef enum EGalacticObjectType {
    _GALOBJ_STAR_ = 0
} EGalacticObjectType;

typedef enum EMappingValueType {
    MAPPING_VALUE_TYPE_BUTTON = 0,
    MAPPING_VALUE_TYPE_ANALOG = 1
} EMappingValueType;

typedef enum EFormat {
    FORMAT_CENTER = 0,
    FORMAT_RIGHT = 1,
    FORMAT_LEFT = 2
} EFormat;

typedef enum EMouseEventType {
    INVALID = 0,
    MOVED = 1,
    KEYCHANGE = 2,
    KEYDOWN = 3,
    KEYUP = 4,
    KEYDBLKLICK = 5
} EMouseEventType;

typedef enum EMouseButton {
    NONE = 0,
    LEFT = 1,
    RIGHT = 2,
    MIDDLE = 3,
    SCROLL_WHEEL = 4
} EMouseButton;

typedef enum ETouchType {
    TOUCH_DOWN = 0,
    TOUCH_UP = 1,
    TOUCH_MOVED = 2,
    SHORT_TAP_UP = 3,
    LONG_TAP_UP = 4,
    TOUCH_INVALID = 5
} ETouchType;

typedef enum EGamepadEventType {
    CONNECTED = 1,
    DISCONNECTED = 2,
    BUTTON_DOWN = 4,
    BUTTON_UP = 8,
    BUTTON_HOLD = 16,
    ANALOG_MOVED = 32,
    INVALID = 64
} EGamepadEventType;

typedef enum EGamepadButton {
    BUTTON_A = 0,
    BUTTON_B = 1,
    BUTTON_X = 2,
    BUTTON_Y = 3,
    BUTTON_START = 4,
    BUTTON_BACK = 5,
    BUTTON_LEFTSTICK = 6,
    BUTTON_RIGHTSTICK = 7,
    BUTTON_LEFTSHOULDER = 8,
    BUTTON_RIGHTSHOULDER = 9,
    BUTTON_DPAD_UP = 10,
    BUTTON_DPAD_DOWN = 11,
    BUTTON_DPAD_LEFT = 12,
    BUTTON_DPAD_RIGHT = 13,
    N_CONTROLLERBUTTONS = 14,
    INVALID_GAMEPAD_BUTTON = 15
} EGamepadButton;

typedef enum EGamepadAnalog {
    ANALOG_LEFT_X = 0,
    ANALOG_LEFT_Y = 1,
    ANALOG_RIGHT_X = 2,
    ANALOG_RIGHT_Y = 3,
    ANALOG_LEFT_TRIGGER = 4,
    ANALOG_RIGHT_TRIGGER = 5,
    N_CONTROLLERANALOGS = 6,
    INVALID_GAMEPAD_ANALOG = 7,
    ANALOG_LEFT_STICK = 8,
    ANALOG_RIGHT_STICK = 9
} EGamepadAnalog;

typedef enum EShipGraphicsEntityStateType {
    None = 0,
    Idle = 1,
    Moving = 2,
    MovingLooping = 3,
    Working = 4,
    WorkingLooping = 5,
    Death = 6
} EShipGraphicsEntityStateType;


typedef enum EStarClass {
    _STAR_CLASS_GENERAL_ = 0,
    _STAR_CLASS_B_ = 1,
    _STAR_CLASS_A_ = 2,
    _STAR_CLASS_F_ = 3,
    _STAR_CLASS_G_ = 4,
    _STAR_CLASS_K_ = 5,
    _STAR_CLASS_M_ = 6,
    _STAR_CLASS_BLACK_HOLE_ = 7,
    _STAR_CLASS_NEUTRON_STAR_ = 8,
    _STAR_CLASS_PULSAR_ = 9,
    _STAR_CLASS_PIRATE_ = 10,
    _STAR_CLASS_NONE_ = 11,
    _STAR_CLASS_NUM_OF_ = 11
} EStarClass;


typedef enum EArrowGfxType {
    SYSTEM_MOVE_ARROW = 0,
    SYSTEM_ATTACK_ARROW = 1,
    SYSTEM_TASK_ARROW = 2,
    SYSTEM_INCOMING_TRADE_ARROW = 3,
    SYSTEM_OUTGOING_TRADE_ARROW = 4,
    GALAXY_MOVE_ARROW = 5,
    GALAXY_ATTACK_ARROW = 6,
    GALAXY_TASK_ARROW = 7,
    GALAXY_BYPASS_ARROW = 8,
    GALAXY_INCOMING_TRADE_ARROW = 9,
    GALAXY_OUTGOING_TRADE_ARROW = 10,
    ARROW_GFX_TYPE_numof = 11
} EArrowGfxType;

typedef enum EMiaType {
    MIA_EMERGENCY_FTL = 0,
    MIA_RETURN_HOME = 1,
    MIA_REINFORCE = 2,
    MIA_ESN = 3,
    MIA_SIZE = 4
} EMiaType;


typedef enum EShipClass {
    _SHIPCLASS_MILITARY_ = 0,
    _SHIPCLASS_CONSTRUCTOR_ = 1,
    _SHIPCLASS_COLONIZER_ = 2,
    _SHIPCLASS_SCIENCE_SHIP_ = 3,
    _SHIPCLASS_TRANSPORT_ = 4,
    _SHIPCLASS_MINING_STATION_ = 5,
    _SHIPCLASS_RESEARCH_STATION_ = 6,
    _SHIPCLASS_MILITARY_STATION_ = 7,
    _SHIPCLASS_OBSERVATION_STATION_ = 8,
    _SHIPCLASS_STARBASE_ = 9,
    _SHIPCLASS_MILITARY_SPECIAL_ = 10,
    _NUM_SHIPCLASSES_ = 11,
    _SHIPCLASS_NONE_ = 11
} EShipClass;


typedef enum EBeamState {
    WINDUP = 0,
    STARTING = 1,
    IN_PROGRESS = 2,
    ENDING = 3,
    BEAM_STATES_numof = 4
} EBeamState;

typedef enum EPlanetDestructionGraphicsEntityStateType {
    None = 0,
    Windup = 1,
    Firing = 2,
    Winddown = 3
} EPlanetDestructionGraphicsEntityStateType;


typedef enum EGFXPrimitive {
    PRIMITIVE_POINTLIST = 0,
    PRIMITIVE_LINELIST = 1,
    PRIMITIVE_LINESTRIP = 2,
    PRIMITIVE_TRIANGLELIST = 3,
    PRIMITIVE_TRIANGLESTRIP = 4,
    PRIMITIVE_LINELIST_ADJ = 5,
    PRIMITIVE_LINESTRIP_ADJ = 6,
    PRIMITIVE_TRIANGLELIST_ADJ = 7,
    PRIMITIVE_TRIANGLESTRIP_ADJ = 8,
    PRIMITIVE_COUNT = 9
} EGFXPrimitive;

typedef enum ERangeCacheType {
    WORMHOLE_RANGE = 0,
    FTL_JUMP_RANGE = 1,
    INTEL_LEVEL_HIGH = 2
} ERangeCacheType;

typedef enum EProjectileGfxType {
    PROJECTILE_GFX_BEAM = 0,
    PROJECTILE_GFX_BALLISTIC = 1,
    PROJECTILE_GFX_MISSILE = 2,
    PROJECTILE_GFX_numof = 3
} EProjectileGfxType;

typedef enum EScrollbarSide {
    SCROLLBAR_LEFT = 0,
    SCROLLBAR_RIGHT = 1
} EScrollbarSide;

typedef enum e_state {
    INCCLICKED = 0,
    DECCLICKED = 1,
    INCDOWN = 2,
    DECDOWN = 3,
    INCUP = 4,
    DECUP = 5,
    SLIDECLICKED = 6,
    SLIDEDRAGED = 7,
    TRACKDOWN = 8,
    TRACKCLICKED = 9,
    NONE = 10
} e_state;


typedef enum EFleetStance {
    _FLEETSTANCE_PASSIVE_ = 0,
    _FLEETSTANCE_AGGRESSIVE_ = 1,
    _FLEETSTANCE_EVASIVE_ = 2,
    _NUM_FLEETSTANCES_ = 3
} EFleetStance;

typedef enum EAggressiveStanceRangeMeasureFrom {
    MEASURE_FROM_SELF = 0,
    MEASURE_FROM_RETURN_POINT = 1,
    MEASURE_FROM_NOT_SET = 2
} EAggressiveStanceRangeMeasureFrom;


typedef enum EFleetFlags {
    ToBeKilled = -2147483648,
    None = 0,
    CustomName = 1,
    Civilian = 2,
    Station = 4,
    EventLocked = 8,
    HasWeapon = 16,
    MIA = 32,
    HasInitializedCurrentAction = 64,
    FriendsShouldFollow = 128,
    IsMobile = 512,
    ValidForCombat = 1024,
    OrbitalStation = 2048
} EFleetFlags;


typedef enum EHitEntityPositioning {
    BeamIntersection = 0,
    EntityCenter = 1
} EHitEntityPositioning;


typedef enum ETriggerType {
    TRIGGER_TYPE_GAMEPAD_BUTTON = 0,
    TRIGGER_TYPE_GAMEPAD_ANALOG = 1
} ETriggerType;


typedef enum EGFXFormat {
    GFXFORMAT_FLOAT = 0,
    GFXFORMAT_HALF = 1,
    GFXFORMAT_INT = 2,
    GFXFORMAT_SHORT = 3,
    GFXFORMAT_SBYTE = 4,
    GFXFORMAT_UBYTE = 5,
    GFXFORMAT_COLOR = 6,
    GFXFORMAT_COUNT = 7
} EGFXFormat;

typedef enum EGFXSemantic {
    SEMANTIC_POSITION = 0,
    SEMANTIC_COLOR = 1,
    SEMANTIC_TEXCOORD = 2,
    SEMANTIC_NORMAL = 3,
    SEMANTIC_TANGENT = 4,
    SEMANTIC_BINORMAL = 5,
    SEMANTIC_BLENDINDICES = 6,
    SEMANTIC_BLENDWEIGHT = 7,
    SEMANTIC_COUNT = 8
} EGFXSemantic;

typedef enum EGFXInputType {
    INPUTTYPE_PER_VERTEX = 0,
    INPUTTYPE_PER_INSTANCE = 1,
    INPUTTYPE_COUNT = 2
} EGFXInputType;


typedef enum ENodeType {
    NODE_TYPE_NOT_SET = 0,
    MESH_JOINT_NODE = 1,
    MESH_LOCATOR_NODE = 2,
    ENTITY_LOCATOR_NODE = 3
} ENodeType;


typedef enum EHyperlaneSettingsType {
    None = 0,
    SystemsBridge = 1,
    HiddenInGalaxy = 2,
    HiddenInSystem = 4,
    DebugFixedBridge = 8,
    DebugFixedIsland = 16
} EHyperlaneSettingsType;


typedef enum EShieldImpactSize {
    SHIELD_IMPACT_SMALL = 0,
    SHIELD_IMPACT_MEDIUM = 1,
    SHIELD_IMPACT_BIG = 2,
    SHIELD_IMPACT_numof = 3
} EShieldImpactSize;


typedef enum EPathJumpMethod {
    JUMP_HYPERLANE = 0,
    JUMP_BYPASS = 1,
    JUMP_COUNT = 2
} EPathJumpMethod;


typedef enum EFleetFixedFormationType {
    Wedge = 0,
    Circle = 1
} EFleetFixedFormationType;

typedef enum EFleetAutoMoveType {
    AUTO_MOVE_NONE = 0,
    AUTO_MOVE_TO_PLANET = 1,
    AUTO_ATTACK_FLEET = 2,
    AUTO_FOLLOW_FLEET = 3
} EFleetAutoMoveType;

typedef enum ESpatialObjectType {
    SPATIAL_SHIP = 0,
    SPATIAL_AMBIENT_OBJECT = 1,
    SPATIAL_PLANET = 2,
    SPATIAL_FLEET = 3,
    SPATIAL_GALACTIC_OBJECT = 4,
    SPATIAL_DEBRIS = 5,
    SPATIAL_MEGASTRUCTURE = 6,
    SPATIAL_WORMHOLE = 7,
    SPATIAL_NULL_OBJECT = 8
} ESpatialObjectType;


typedef enum EUnionDataType {
    Button = 0,
    Analog = 1
} EUnionDataType;


typedef enum EGamepadAnalogDirection {
    GAMEPAD_ANALOG_DIRECTION_RIGHT = 0,
    GAMEPAD_ANALOG_DIRECTION_UP = 1,
    GAMEPAD_ANALOG_DIRECTION_LEFT = 2,
    GAMEPAD_ANALOG_DIRECTION_DOWN = 3,
    INVALID_GAMEPAD_ANALOG_DIRECTION = 4,
    GAMEPAD_ANALOG_DIRECTION_HORIZONTAL = 5,
    GAMEPAD_ANALOG_DIRECTION_VERTICAL = 6,
    GAMEPAD_ANALOG_DIRECTION_ANY = 7
} EGamepadAnalogDirection;


typedef enum EEconomicCategorySettingType {
    None = 0,
    Hidden = 1,
    UseForAIBudget = 2,
    HasCostAddModifiers = 4,
    HasTriggeredCostAddModifiers = 8,
    HasProducesAddModifiers = 16,
    HasTriggeredProducesAddModifiers = 32,
    HasUpkeepAddModifiers = 64,
    HasTriggeredUpkeepAddModifiers = 128,
    HasCostMultModifiers = 256,
    HasTriggeredCostMultModifiers = 512,
    HasProducesMultModifiers = 1024,
    HasTriggeredProducesMultModifiers = 2048,
    HasUpkeepMultModifiers = 4096,
    HasTriggeredUpkeepMultModifiers = 8192
} EEconomicCategorySettingType;


typedef enum EScopeType {
    SCOPE_NO_CHECK = 0,
    SCOPE_MEGASTRUCTURE = 1,
    SCOPE_PLANET = 2,
    SCOPE_COUNTRY = 4,
    SCOPE_SHIP = 8,
    SCOPE_POP = 16,
    SCOPE_FLEET = 32,
    SCOPE_GALACTIC_OBJECT = 64,
    SCOPE_LEADER = 128,
    SCOPE_ARMY = 256,
    SCOPE_AMBIENT_OBJECT = 512,
    SCOPE_SPECIES = 1024,
    SCOPE_DESIGN = 4096,
    SCOPE_POP_FACTION = 8192,
    SCOPE_WAR = 16384,
    SCOPE_FEDERATION = 32768,
    SCOPE_STARBASE = 65536,
    SCOPE_DEPOSIT = 131072,
    SCOPE_OBSERVER = 262144,
    SCOPE_SECTOR = 524288,
    SCOPE_NO_SCOPE = 1048576,
    SCOPE_ARCHAEOLOGICAL_SITE = 2097152,
    SCOPE_FIRST_CONTACT = 4194304,
    SCOPE_SPY_NETWORK = 8388608,
    SCOPE_ESPIONAGE_OPERATION = 16777216,
    SCOPE_ESPIONAGE_ASSET = 33554432,
    SCOPE_DLC_RECOMMENDATION = 67108864,
    SCOPE_SITUATION = 268435456
} EScopeType;


typedef enum ELeaderClassCategoryType {
    Admiral = 0,
    General = 1,
    Scientist = 2,
    Governor = 3,
    Ruler = 4,
    Envoy = 5,
    NumCategories = 6
} ELeaderClassCategoryType;


typedef enum ModifierType {
    _MOD_BLANK_MODIFIER_ = 0,
    _MOD_POP_POLITICAL_POWER_ = 1,
    _MOD_POP_HAPPINESS_ = 2,
    _MOD_POP_HOUSING_USAGE_BASE_ = 3,
    _MOD_POP_HOUSING_USAGE_ADD_ = 4,
    _MOD_POP_HOUSING_USAGE_MULT_ = 5,
    _MOD_POP_AMENITIES_USAGE_BASE_ = 6,
    _MOD_POP_AMENITIES_USAGE_ADD_ = 7,
    _MOD_POP_AMENITIES_USAGE_MULT_ = 8,
    _MOD_POP_AMENITIES_USAGE_ORGANIC_MULT_ = 9,
    _MOD_POP_AMENITIES_USAGE_ROBOTIC_MULT_ = 10,
    _MOD_POP_AMENITIES_USAGE_NO_HAPPINESS_BASE_ = 11,
    _MOD_POP_AMENITIES_USAGE_NO_HAPPINESS_ADD_ = 12,
    _MOD_POP_AMENITIES_USAGE_NO_HAPPINESS_MULT_ = 13,
    _MOD_POP_DECLINE_SPEED_ = 14,
    _MOD_POP_PURGE_SPEED_ = 15,
    _MOD_POP_GROWTH_FROM_IMMIGRATION_ = 16,
    _MOD_POP_GROWTH_SPEED_ = 17,
    _MOD_POP_GROWTH_SPEED_REDUCTION_ = 18,
    _MOD_POP_ASSEMBLY_SPEED_ = 19,
    _MOD_POP_ENVIRONMENT_TOLERANCE_ = 20,
    _MOD_POP_GOVERNMENT_ETHIC_ATTRACTION_ = 21,
    _MOD_POP_ETHICS_SHIFT_SPEED_ = 22,
    _MOD_POP_CITIZEN_HAPPINESS_ = 23,
    _MOD_FORCE_DISPARITY_FIRE_RATE_MULT_ = 24,
    _MOD_SHIP_HULL_ADD_ = 25,
    _MOD_SHIP_HULL_MULT_ = 26,
    _MOD_SHIP_HULL_REGEN_ADD_PERC_ = 27,
    _MOD_SHIP_HULL_REGEN_ADD_STATIC_ = 28,
    _MOD_SHIP_HULL_DAMAGE_MULT_ = 29,
    _MOD_SHIP_ARMOR_ADD_ = 30,
    _MOD_SHIP_ARMOR_MULT_ = 31,
    _MOD_SHIP_ARMOR_REDUCTION_ = 32,
    _MOD_SHIP_ARMOR_REGEN_ADD_PERC_ = 33,
    _MOD_SHIP_ARMOR_REGEN_ADD_STATIC_ = 34,
    _MOD_SHIP_ARMOR_DAMAGE_MULT_ = 35,
    _MOD_SHIP_ARMOR_PENETRATION_MULT_ = 36,
    _MOD_SHIP_SHIELD_ADD_ = 37,
    _MOD_SHIP_SHIELD_MULT_ = 38,
    _MOD_SHIP_SHIELD_REDUCTION_ = 39,
    _MOD_SHIP_SHIELD_REGEN_ADD_PERC_ = 40,
    _MOD_SHIP_SHIELD_REGEN_ADD_STATIC_ = 41,
    _MOD_SHIP_SHIELD_DAMAGE_MULT_ = 42,
    _MOD_SHIP_SHIELD_PENETRATION_MULT_ = 43,
    _MOD_SHIP_WEAPON_DAMAGE_ = 44,
    _MOD_SHIP_WEAPON_RANGE_MULT_ = 45,
    _MOD_SHIP_ENGAGEMENT_RANGE_MULT_ = 46,
    _MOD_SHIP_ORBITAL_BOMBARDMENT_MULT_ = 47,
    _MOD_SHIP_FIRE_RATE_MULT_ = 48,
    _MOD_SHIP_HOME_TERRITORY_FIRE_RATE_MULT_ = 49,
    _MOD_SHIP_PIRACY_SUPPRESSION_ADD_ = 50,
    _MOD_SHIP_PIRACY_SUPPRESSION_MULT_ = 51,
    _MOD_SHIP_HYPERLANE_RANGE_ADD_ = 52,
    _MOD_SHIP_FTL_JUMPDRIVE_RANGE_MULT_ = 53,
    _MOD_SHIP_EMERGENCY_FTL_MIN_DAYS_ADD_ = 54,
    _MOD_SHIP_EMERGENCY_FTL_MIN_DAYS_MULT_ = 55,
    _MOD_SHIP_DISENGAGE_CHANCE_MULT_ = 56,
    _MOD_SHIP_DISENGAGE_CHANCE_REDUCTION_ = 57,
    _MOD_SHIP_EVASION_ADD_ = 58,
    _MOD_SHIP_EVASION_MULT_ = 59,
    _MOD_SHIP_ACCURACY_ADD_ = 60,
    _MOD_SHIP_ACCURACY_MULT_ = 61,
    _MOD_SHIP_TRACKING_ADD_ = 62,
    _MOD_SHIP_TRACKING_MULT_ = 63,
    _MOD_SHIP_BASE_SPEED_MULT_ = 64,
    _MOD_SHIP_SPEED_MULT_ = 65,
    _MOD_SHIP_SPEED_REDUCTION_ = 66,
    _MOD_SHIP_LANDING_TIME_MULT_ = 67,
    _MOD_SHIP_ORBIT_UPKEEP_MULT_ = 68,
    _MOD_SHIP_SENSOR_RANGE_ADD_ = 69,
    _MOD_SHIP_WINDUP_MULT_ = 70,
    _MOD_SHIP_WINDDOWN_MULT_ = 71,
    _MOD_SHIP_INTERSTELLAR_SPEED_MULT_ = 72,
    _MOD_SHIP_EMERGENCY_FTL_ = 73,
    _MOD_SHIP_ANOMALY_FAIL_RISK_ = 74,
    _MOD_SHIP_ANOMALY_RESEARCH_SPEED_ = 75,
    _MOD_SHIP_ANOMALY_GENERATION_CHANCE_ = 76,
    _MOD_SHIP_SCIENCE_SURVEY_SPEED_ = 77,
    _MOD_SHIP_STARTING_EXPERIENCE_ADD_ = 78,
    _MOD_SHIP_EXPERIENCE_GAIN_MULT_ = 79,
    _MOD_SHIP_JUMPDRIVE_COOLDOWN_MULT_ = 80,
    _MOD_ARMY_DISENGAGE_CHANCE_MULT_ = 81,
    _MOD_ARMY_STARTING_EXPERIENCE_ADD_ = 82,
    _MOD_ARMY_HEALTH_ = 83,
    _MOD_ARMY_MORALE_ = 84,
    _MOD_ARMY_DAMAGE_MULT_ = 85,
    _MOD_ARMY_COLLATERAL_DAMAGE_MULT_ = 86,
    _MOD_ARMY_MORALE_DAMAGE_MULT_ = 87,
    _MOD_ARMY_DEFENSE_MORALE_MULT_ = 88,
    _MOD_ARMY_DEFENSE_DAMAGE_MULT_ = 89,
    _MOD_ARMY_ATTACK_MORALE_MULT_ = 90,
    _MOD_ARMY_ATTACK_DAMAGE_MULT_ = 91,
    _MOD_ARMY_ATTACK_HEALTH_MULT_ = 92,
    _MOD_ARMY_DEFENSE_HEALTH_MULT_ = 93,
    _MOD_ARMY_EXPERIENCE_GAIN_MULT_ = 94,
    _MOD_PLANET_NON_ARTIFICIAL_MAX_DISTRICTS_ADD_ = 95,
    _MOD_PLANET_MAX_DISTRICTS_ADD_ = 96,
    _MOD_PLANET_MAX_DISTRICTS_MULT_ = 97,
    _MOD_PLANET_MAX_BUILDINGS_ADD_ = 98,
    _MOD_PLANET_MAX_BRANCH_OFFICE_BUILDINGS_ADD_ = 99,
    _MOD_PLANET_POP_ASSEMBLY_ADD_ = 100,
    _MOD_PLANET_POP_ASSEMBLY_MULT_ = 101,
    _MOD_PLANET_POP_ASSEMBLY_REDUCTION_ = 102,
    _MOD_PLANET_POP_ASSEMBLY_ORGANIC_ADD_ = 103,
    _MOD_PLANET_POP_ASSEMBLY_ORGANIC_MULT_ = 104,
    _MOD_PLANET_POP_ASSEMBLY_ORGANIC_REDUCTION_ = 105,
    _MOD_PLANET_AMENITIES_ADD_ = 106,
    _MOD_PLANET_AMENITIES_MULT_ = 107,
    _MOD_PLANET_AMENITIES_NO_HAPPINESS_ADD_ = 108,
    _MOD_PLANET_AMENITIES_NO_HAPPINESS_MULT_ = 109,
    _MOD_PLANET_STABILITY_ADD_ = 110,
    _MOD_PLANET_CRIME_ADD_ = 111,
    _MOD_PLANET_CRIME_MULT_ = 112,
    _MOD_PLANET_CRIME_NO_HAPPINESS_ADD_ = 113,
    _MOD_PLANET_CRIME_NO_HAPPINESS_MULT_ = 114,
    _MOD_PLANET_HOUSING_ADD_ = 115,
    _MOD_PLANET_HOUSING_MULT_ = 116,
    _MOD_PLANET_CARRY_CAP_ADD_ = 117,
    _MOD_PLANET_SENSOR_RANGE_ADD_ = 118,
    _MOD_PLANET_COLONY_DEVELOPMENT_SPEED_MULT_ = 119,
    _MOD_PLANET_BUILDING_TIME_MULT_ = 120,
    _MOD_PLANET_BUILDING_REFUND_MULT_ = 121,
    _MOD_PLANET_BUILDING_BUILD_SPEED_MULT_ = 122,
    _MOD_PLANET_DECISION_ENACT_SPEED_MULT_ = 123,
    _MOD_PLANET_CLEAR_BLOCKER_TIME_MULT_ = 124,
    _MOD_PLANET_CLEAR_BLOCKER_SPEED_MULT_ = 125,
    _MOD_PLANET_MIGRATION_ALL_MULT_ = 126,
    _MOD_PLANET_RESETTLEMENT_UNEMPLOYED_MULT_ = 127,
    _MOD_PLANET_IMMIGRATION_PULL_ADD_ = 128,
    _MOD_PLANET_IMMIGRATION_PULL_MULT_ = 129,
    _MOD_PLANET_EMIGRATION_PUSH_ADD_ = 130,
    _MOD_PLANET_EMIGRATION_PUSH_MULT_ = 131,
    _MOD_PLANET_ARMY_BUILD_SPEED_MULT_ = 132,
    _MOD_PLANET_ARMY_BUILD_TIME_MULT_ = 133,
    _MOD_COUNTRY_POP_ENSLAVED_MULT_ = 134,
    _MOD_COUNTRY_BORDER_FRICTION_MULT_ = 135,
    _MOD_COUNTRY_DEFENSIVE_WAR_INFLUENCE_GAIN_ADD_ = 136,
    _MOD_COUNTRY_ALL_TECH_RESEARCH_SPEED_ = 137,
    _MOD_COUNTRY_PHYSICS_TECH_RESEARCH_SPEED_ = 138,
    _MOD_COUNTRY_SOCIETY_TECH_RESEARCH_SPEED_ = 139,
    _MOD_COUNTRY_ENGINEERING_TECH_RESEARCH_SPEED_ = 140,
    _MOD_COUNTRY_NUM_TECH_ALTERNATIVES_ADD_ = 141,
    _MOD_COUNTRY_EDICT_LENGTH_MULT_ = 142,
    _MOD_COUNTRY_SHIP_UPGRADE_COST_MULT_ = 143,
    _MOD_COUNTRY_LEADER_POOL_SIZE_ = 144,
    _MOD_COUNTRY_INSULT_EFFICIENCY_ = 145,
    _MOD_COUNTRY_TRADE_ATTRACTIVENESS_ = 146,
    _MOD_COLONY_START_NUM_POPS_ADD_ = 147,
    _MOD_COUNTRY_RESOURCE_MAX_ADD_ = 148,
    _MOD_COUNTRY_TERRAFORM_SPEED_MULT_ = 149,
    _MOD_COUNTRY_ELECTION_COST_ = 150,
    _MOD_COUNTRY_TRUST_GROWTH_ = 151,
    _MOD_COUNTRY_TRUST_CAP_ADD_ = 152,
    _MOD_COUNTRY_SYNTHETIC_TRUST_CAP_ADD_ = 153,
    _MOD_COUNTRY_ORGANIC_TRUST_CAP_ADD_ = 154,
    _MOD_COUNTRY_SUBJECT_TRUST_CAP_ADD_ = 155,
    _MOD_COUNTRY_SUBJECT_POWER_PENALTY_ = 156,
    _MOD_COUNTRY_MAX_RIVALRIES_ = 157,
    _MOD_COUNTRY_MAX_EMBASSIES_ = 158,
    _MOD_COUNTRY_ASCENSION_PERKS_ADD_ = 159,
    _MOD_COUNTRY_MODIFY_SPECIES_COST_MULT_ = 160,
    _MOD_COUNTRY_SUBJECT_ACCEPTANCE_ADD_ = 161,
    _MOD_COUNTRY_SUBJECT_INTEGRATION_INFLUENCE_COST_MULT_ = 162,
    _MOD_COUNTRY_SUBJECT_INTEGRATION_SPEED_ADD_ = 163,
    _MOD_COUNTRY_INTEGRATION_COOLDOWN_MULT_ = 164,
    _MOD_COUNTRY_VASSAL_NAVAL_CAPACITY_CONTRIBUTION_MULT_ = 165,
    _MOD_COUNTRY_SUBJECT_TRIBUTE_MULT_ = 166,
    _MOD_COUNTRY_SUBJECT_TECHNOLOGY_SHARING_MULT_ = 167,
    _MOD_LEADER_SPECIES_EXP_GAIN_ = 168,
    _MOD_LEADER_RULER_SKILL_LEVELS_ = 169,
    _MOD_LEADER_SKILL_LEVELS_ = 170,
    _MOD_LEADER_AGE_ = 171,
    _MOD_LEADER_ADMIRAL_SKILL_LEVELS_ = 172,
    _MOD_LEADER_GENERAL_SKILL_LEVELS_ = 173,
    _MOD_LEADER_GOVERNOR_SKILL_LEVELS_ = 174,
    _MOD_LEADER_SCIENTIST_SKILL_LEVELS_ = 175,
    _MOD_COUNTRY_STARBASE_CAPACITY_ADD_ = 176,
    _MOD_COUNTRY_STARBASE_CAPACITY_MULT_ = 177,
    _MOD_COUNTRY_NAVAL_CAP_ADD_ = 178,
    _MOD_COUNTRY_NAVAL_CAP_MULT_ = 179,
    _MOD_COUNTRY_NAVAL_COVERAGE_ADD_ = 180,
    _MOD_COUNTRY_NAVAL_COVERAGE_MULT_ = 181,
    _MOD_COUNTRY_EDICT_FUND_ADD_ = 182,
    _MOD_COUNTRY_EDICT_FUND_MULT_ = 183,
    _MOD_COUNTRY_TERRAFORMING_COST_MULT_ = 184,
    _MOD_COUNTRY_FEDERATION_NAVAL_CAP_CONTRIBUTION_MULT_ = 185,
    _MOD_COUNTRY_COMMAND_LIMIT_ADD_ = 186,
    _MOD_COUNTRY_COMMAND_LIMIT_MULT_ = 187,
    _MOD_PLANET_ORBITAL_BOMBARDMENT_DAMAGE_ = 188,
    _MOD_COUNTRY_RESETTLEMENT_COST_MULT_ = 189,
    _MOD_POP_RESETTLEMENT_COST_MULT_ = 190,
    _MOD_POP_DEFENSE_ARMIES_ADD_ = 191,
    _MOD_POP_DEMOTION_TIME_MULT_ = 192,
    _MOD_FACTION_APPROVAL_ = 193,
    _MOD_COUNTRY_STARBASE_INFLUENCE_COST_MULT_ = 194,
    _MOD_COUNTRY_CLAIM_INFLUENCE_COST_MULT_ = 195,
    _MOD_COUNTRY_HOSTILE_CLAIM_INFLUENCE_COST_MULT_ = 196,
    _MOD_COUNTRY_WAR_EXHAUSTION_MULT_ = 197,
    _MOD_EMPIRE_SIZE_PENALTY_MULT_ = 198,
    _MOD_EMPIRE_SIZE_BRANCH_OFFICE_MULT_ = 199,
    _MOD_TRADITION_COST_EMPIRE_SIZE_MULT_ = 200,
    _MOD_TECH_COST_EMPIRE_SIZE_MULT_ = 201,
    _MOD_LEADER_COST_EMPIRE_SIZE_MULT_ = 202,
    _MOD_LEADER_UPKEEP_EMPIRE_SIZE_MULT_ = 203,
    _MOD_MEGASTRUCTURE_BUILD_SPEED_ADD_ = 204,
    _MOD_MEGASTRUCTURE_BUILD_SPEED_MULT_ = 205,
    _MOD_COUNTRY_GOVERNMENT_CIVIC_POINTS_ADD_ = 206,
    _MOD_COUNTRY_OCCUPATION_ARMIES_ADD_ = 207,
    _MOD_STARBASE_SHIPYARD_CAPACITY_ADD_ = 208,
    _MOD_STARBASE_SHIPYARD_BUILD_COST_MULT_ = 209,
    _MOD_STARBASE_SHIPYARD_BUILD_TIME_MULT_ = 210,
    _MOD_STARBASE_SHIPYARD_BUILD_SPEED_MULT_ = 211,
    _MOD_STARBASE_UPGRADE_COST_MULT_ = 212,
    _MOD_STARBASE_UPGRADE_TIME_MULT_ = 213,
    _MOD_STARBASE_UPGRADE_SPEED_MULT_ = 214,
    _MOD_STARBASE_DEFENSIVE_WAR_SHIP_BUILD_SPEED_MULT_ = 215,
    _MOD_STARBASE_BUILDING_CAPACITY_ADD_ = 216,
    _MOD_STARBASE_BUILDING_BUILD_TIME_MULT_ = 217,
    _MOD_STARBASE_BUILDING_BUILD_SPEED_MULT_ = 218,
    _MOD_STARBASE_MODULE_CAPACITY_ADD_ = 219,
    _MOD_STARBASE_MODULE_BUILD_TIME_MULT_ = 220,
    _MOD_STARBASE_MODULE_BUILD_SPEED_MULT_ = 221,
    _MOD_STARBASE_DEFENSE_PLATFORM_CAPACITY_ADD_ = 222,
    _MOD_STARBASE_DEFENSE_PLATFORM_CAPACITY_MULT_ = 223,
    _MOD_STARBASE_TRADE_COLLECTION_RANGE_ADD_ = 224,
    _MOD_STARBASE_TRADE_PROTECTION_RANGE_ADD_ = 225,
    _MOD_STARBASE_TRADE_PROTECTION_ADD_ = 226,
    _MOD_COUNTRY_LOCAL_TRADE_PROTECTION_ADD_ = 227,
    _MOD_PLANET_HYPERLANE_RANGE_ADD_ = 228,
    _MOD_COUNTRY_TRADE_FEE_ = 229,
    _MOD_TRADE_VALUE_ADD_ = 230,
    _MOD_TRADE_VALUE_MULT_ = 231,
    _MOD_PIRACY_GROWTH_MULT_ = 232,
    _MOD_PIRACY_SUPPRESSION_MULT_ = 233,
    _MOD_MAX_TRADE_PIRACY_ADD_ = 234,
    _MOD_MAX_TRADE_PIRACY_MULT_ = 235,
    _MOD_COUNTRY_ADMIN_CAP_ADD_ = 236,
    _MOD_COUNTRY_ADMIN_CAP_MULT_ = 237,
    _MOD_BRANCH_OFFICE_VALUE_MULT_ = 238,
    _MOD_BRANCH_OFFICE_CRIMINAL_SYNDICATE_VALUE_ADD_ = 239,
    _MOD_COUNTRY_SLAVE_MARKET_COST_MULT_ = 240,
    _MOD_SHIP_ARCHAEOLOGICAL_SITE_EXCAVATION_SPEED_MULT_ = 241,
    _MOD_SHIP_ARCHAEOLOGICAL_SITE_CLUES_ADD_ = 242,
    _MOD_COUNTRY_MEGASTRUCTURE_BUILD_CAP_ADD_ = 243,
    _MOD_DIPLO_WEIGHT_STANCE_MULT_ = 244,
    _MOD_DIPLO_WEIGHT_SPRAWL_MULT_ = 245,
    _MOD_DIPLO_WEIGHT_NAVAL_MULT_ = 246,
    _MOD_DIPLO_WEIGHT_POPS_MULT_ = 247,
    _MOD_DIPLO_WEIGHT_ECONOMY_MULT_ = 248,
    _MOD_DIPLO_WEIGHT_TECHNOLOGY_MULT_ = 249,
    _MOD_DIPLO_WEIGHT_ENVOYS_MULT_ = 250,
    _MOD_DIPLO_WEIGHT_COUNCIL_MULT_ = 251,
    _MOD_DIPLO_WEIGHT_MULT_ = 252,
    _MOD_FEDERATION_COHESION_ADD_ = 253,
    _MOD_FEDERATION_COHESION_ETHICS_PENALTY_MULT_ = 254,
    _MOD_COUNTRY_ENVOYS_ADD_ = 255,
    _MOD_ENVOY_IMPROVE_RELATIONS_MULT_ = 256,
    _MOD_ENVOY_HARM_RELATIONS_MULT_ = 257,
    _MOD_EMPIRE_SIZE_DISTRICTS_MULT_ = 258,
    _MOD_EMPIRE_SIZE_SYSTEMS_MULT_ = 259,
    _MOD_EMPIRE_SIZE_COLONIES_MULT_ = 260,
    _MOD_EMPIRE_SIZE_POPS_MULT_ = 261,
    _MOD_EMPIRE_SIZE_MULT_ = 262,
    _MOD_FEDERATION_FLEET_COUNTRIBUTION_FACTOR_ = 263,
    _MOD_SPECIES_EMPIRE_SIZE_MULT_ = 264,
    _MOD_SHIP_FEDERATION_TERRITORY_SPEED_MULT_ = 265,
    _MOD_VETO_COST_MULT_ = 266,
    _MOD_FEDERATION_JOIN_MALUS_MULT_ = 267,
    _MOD_FEDERATION_LEAVE_MALUS_MULT_ = 268,
    _MOD_FEDERATION_RESEARCH_SHARING_MULT_ = 269,
    _MOD_FEDERATION_LEADER_FLEET_SCALE_MODIFIER_ = 270,
    _MOD_COUNTRY_FEDERATION_FLEET_CONTRIBUTION_DISCOUNT_ = 271,
    _MOD_FEDERATION_DIPLO_WEIGHT_CONTRIBUTION_ADD_ = 272,
    _MOD_FEDERATION_LEADER_DIPLO_WEIGHT_FROM_MEMBERS_MULT_ = 273,
    _MOD_COUNTRY_FEDERATION_FLEET_CONTRIBUTION_NAVAL_CAP_REDUCTION_DISCOUNT_ = 274,
    _MOD_FEDERATION_FLEET_CAP_ADD_ = 275,
    _MOD_POP_PURGE_MULT_ = 276,
    _MOD_ESPIONAGE_OPERATION_DIFFICULTY_ADD_ = 277,
    _MOD_ESPIONAGE_OPERATION_DIFFICULTY_MULT_ = 278,
    _MOD_ESPIONAGE_HOSTILE_OPERATION_DIFFICULTY_ADD_ = 279,
    _MOD_ESPIONAGE_HOSTILE_OPERATION_DIFFICULTY_MULT_ = 280,
    _MOD_ESPIONAGE_OPERATION_SKILL_ADD_ = 281,
    _MOD_ESPIONAGE_OPERATION_SKILL_MULT_ = 282,
    _MOD_ESPIONAGE_OPERATION_COST_ADD_ = 283,
    _MOD_ESPIONAGE_OPERATION_COST_MULT_ = 284,
    _MOD_ESPIONAGE_HOSTILE_OPERATION_COST_ADD_ = 285,
    _MOD_ESPIONAGE_HOSTILE_OPERATION_COST_MULT_ = 286,
    _MOD_ESPIONAGE_OPERATION_SPEED_MULT_ = 287,
    _MOD_INTEL_ENCRYPTION_ADD_ = 288,
    _MOD_INTEL_ENCRYPTION_MULT_ = 289,
    _MOD_INTEL_DECRYPTION_ADD_ = 290,
    _MOD_INTEL_DECRYPTION_MULT_ = 291,
    _MOD_SPY_NETWORK_VALUE_ADD_ = 292,
    _MOD_SPY_NETWORK_VALUE_MULT_ = 293,
    _MOD_SPY_NETWORK_DAILY_VALUE_ADD_ = 294,
    _MOD_SPY_NETWORK_DAILY_VALUE_MULT_ = 295,
    _MOD_SPY_NETWORK_DECAY_ADD_ = 296,
    _MOD_SPY_NETWORK_DECAY_MULT_ = 297,
    _MOD_SPY_NETWORK_LEVELS_ADD_ = 298,
    _MOD_COUNTRY_COUNTER_ESPIONAGE_ADD_ = 299,
    _MOD_COUNTRY_COUNTER_ESPIONAGE_MULT_ = 300,
    _MOD_SPY_POWER_COST_ADD_ = 301,
    _MOD_SPY_POWER_COST_MULT_ = 302,
    _MOD_DAMAGE_VS_PLAYER_CRISIS_MULT_ = 303,
    _MOD_SHIP_COMMUNITY_TERRITORY_SPEED_MULT_ = 304,
    _MOD_VETO_COOLDOWN_MULT_ = 305,
    _MOD_EMERGENCY_MEASURES_COOLDOWN_MULT_ = 306,
    _MOD_COUNTRY_COMMUNITY_GDF_NAVAL_CAPACITY_ADD_ = 307,
    _MOD_FIRST_CONTACT_SPEED_MULT_ = 308,
    _MOD_FIRST_CONTACT_CLUES_ADD_ = 309,
    _MOD_FIRST_CONTACT_DEFENSE_ADD_ = 310,
    _MOD_SHIP_DAMAGE_AGAINST_STARBASES_MULT_ = 311,
    _MOD_COUNTER_INTEL_GAIN_SPEED_ = 312,
    _MOD_ADD_BASE_COUNTRY_INTEL_ = 313,
    _MOD_DIPLO_ACTION_ACCEPTANCE_ADD_ = 314,
    _MODIFIER_NONE_ = 315,
    _NUM_MODIFIERTYPES_ = 315,
    _MAX_MODIFIER_TYPE_ = 2147483647
} ModifierType;


typedef enum ELeaderClassAbilitiesType {
    None = 0,
    CanLeadNavy = 1,
    CanLeadArmy = 2,
    CanResearch = 4,
    CanGovernPlanet = 8,
    CanRuleEmpire = 16,
    CanBeEnvoy = 32,
    CanHaveTraits = 64
} ELeaderClassAbilitiesType;

typedef enum EGender {
    _GENDER_MALE_ = 0,
    _GENDER_FEMALE_ = 1,
    _GENDER_INDETERMINABLE_ = 2,
    _NUM_GENDERS_ = 3
} EGender;


typedef enum ETraitType {
    TRAIT_LEADER = 0,
    TRAIT_PLANET_PREFERENCE = 1,
    TRAIT_NORMAL = 2
} ETraitType;

typedef enum ESpawnType {
    SPAWN_DISALLOWED = 0,
    SPAWN_ALLOWED = 1,
    SPAWN_ALWAYS = 2,
    SPAWN_TYPE_numof = 3
} ESpawnType;

typedef enum ETechArea {
    _TECHAREA_PHYSICS_ = 0,
    _TECHAREA_SOCIETY_ = 1,
    _TECHAREA_ENGINEERING_ = 2,
    _NUM_TECHAREAS_ = 3,
    _TECHAREA_NONE_ = 3
} ETechArea;


typedef enum EAIUpdateShipDesign {
    UPDATE_MILITARY = 0,
    UPDATE_ALL = 1,
    NUM_TYPE_UPDATES = 2
} EAIUpdateShipDesign;

typedef enum EGovernmentRestrictionNodeType {
    And = 0,
    Or = 1
} EGovernmentRestrictionNodeType;

typedef enum EDLCSource {
    NONE = 0,
    STEAM_DLC = 1,
    STEAM_UGC = 2,
    RAIL_DLC = 3,
    RAIL_UGC = 4,
    PSN_DLC = 5,
    PSN_UGC = 6,
    POPS_DLC = 7,
    GOG_DLC = 8,
    MSGR_DLC = 9,
    USER_MOD = 10
} EDLCSource;


typedef enum ETechUnlock {
    _TECH_UNLOCK_SHIP_ = 0,
    _TECH_UNLOCK_PLANET_ = 1,
    _TECH_UNLOCK_ARMY_ = 2,
    _TECH_UNLOCK_EDICT_ = 3,
    _TECH_UNLOCK_TRAIT_ = 4,
    _TECH_UNLOCK_BUILDING_ = 5,
    _TECH_UNLOCK_DISTRICT_ = 6,
    _TECH_UNLOCK_POLICY_OPTION_ = 7,
    _TECH_UNLOCK_POLICY_GROUP_ = 8,
    _TECH_UNLOCK_FEATURE_ = 9,
    _TECH_UNLOCK_DIPLOMATIC_ACTION_ = 10,
    _TECH_UNLOCK_TECH_ = 11,
    _TECH_UNLOCK_COMPONENT_ = 12,
    _TECH_UNLOCK_STRATEGIC_RESOURCE_ = 13,
    _TECH_UNLOCK_DEPOSIT_BLOCKER_ = 14,
    _TECH_UNLOCK_INTEL_ = 15,
    _TECH_UNLOCK_MEGASTRUCTURE_ = 16,
    _TECH_UNLOCK_STARBASE_MODULE_ = 17,
    _TECH_UNLOCK_STARBASE_BUILDING_ = 18,
    _TECH_UNLOCK_DECISION_ = 19,
    _NUM_OF_TECH_UNLOCKS_ = 20,
    _TECH_UNLOCK_NONE_ = 20
} ETechUnlock;

typedef enum EElectionType {
    _ELECTION_NONE_ = 0,
    _ELECTION_OLIGARCHIC_ = 1,
    _ELECTION_DEMOCRATIC_ = 2,
    _ELECTION_TYPE_numof_ = 3
} EElectionType;


typedef enum EComponentTemplateSettingsType {
    None = 0,
    ComponentIsHidden = 1,
    ComponentShoulAIUse = 2,
    WeaponUseShipKillTarget = 4,
    WeaponUsesPrioProjectile = 8,
    WeaponCanDestroyStars = 16,
    UtilityHasFTL = 32,
    UtilityIsFTLMagnet = 64,
    UtilityIsFTLInhibitor = 128,
    StrikeCraftUsesPrioProjectile = 256,
    UtilityIsJumpDrive = 512
} EComponentTemplateSettingsType;

typedef enum EComponentSlotSize {
    _CMPSLOTSIZE_PD_ = 0,
    _CMPSLOTSIZE_SMALL_ = 1,
    _CMPSLOTSIZE_MEDIUM_ = 2,
    _CMPSLOTSIZE_LARGE_ = 3,
    _CMPSLOTSIZE_TORPEDO_ = 4,
    _CMPSLOTSIZE_EXTRA_LARGE_ = 5,
    _CMPSLOTSIZE_TITANIC_ = 6,
    _CMPSLOTSIZE_PLANET_KILLER_ = 7,
    _CMPSLOTSIZE_AUX_ = 8,
    _NUM_CMPSLOTSIZES_ = 9
} EComponentSlotSize;

typedef enum EComponentType {
    _CMPTYPE_WEAPON_ = 0,
    _CMPTYPE_UTILITY_ = 1,
    _CMPTYPE_STRIKE_CRAFT_ = 2,
    _NUM_CMPTYPES_ = 3
} EComponentType;


typedef enum EShipConstructionType {
    NONE = 0,
    STARBASE_DEFENSES = 1,
    STARBASE_SHIPYARD = 2
} EShipConstructionType;


typedef enum EShipSizeSettingsType {
    None = 0,
    IsListed = 1,
    Designable = 2,
    IsSpaceStation = 4,
    IsSpaceObject = 8,
    IsCivilian = 16,
    UseGfxCulture = 32,
    GenerateDefaultDesign = 64,
    AutoUpgrade = 128,
    CanDisable = 256,
    CanHaveFederationDesign = 512,
    ValidTargetAgressiveStance = 1024,
    ComponentsAddToCost = 2048,
    FlipControlOnDisable = 4096,
    GenerateShipBrowserDesign = 8192
} EShipSizeSettingsType;


typedef enum ECountryTypeFlags {
    ShareSurveyData = -2147483648,
    AlwaysValidTargetAggressive = 0,
    CanHaveTheirCommShared = 0,
    CustomDiplomacy = 0,
    CustomOpinion = 0,
    DefaultShips = 0,
    Government = 0,
    HasPopGrowth = 0,
    HideNamesIfNoCommunication = 0,
    MinimalistContactsListProfile = 0,
    None = 0,
    Observable = 0,
    ShouldAttackUnarmedOrbitalStations = 0,
    ShowInContactsList = 0,
    UsesOrigins = 0,
    CanOwnEmptyPlanet = 1,
    Playable = 2,
    HasPulseEvents = 4,
    CanUseInvalidTechnology = 8,
    CanReceiveEnvoys = 16,
    HasPiracyRisk = 32,
    IsTheShroud = 64,
    Relations = 128,
    IsFallenEmpire = 256,
    IsEnclave = 512,
    IsAwakenedFallenEmpire = 1024,
    UsesSpecialBuildables = 2048,
    IsSpaceCritter = 4096,
    BlocksPiracy = 8192,
    CountsForVictory = 16384,
    IsEndGameCrisis = 32768,
    IsMidGameCrisis = 65536,
    DestroysStarbases = 131072,
    HasDifficultyBonuses = 262144,
    RandomizeEthos = 524288,
    ShufflePopEthos = 1048576,
    NeedsSurvey = 2097152,
    HasCompleteSensor = 4194304,
    HasCapital = 8388608,
    EnforcesBorders = 16777216,
    PlanetsBeAttacked = 33554432,
    OrbitalBombardment = 67108864,
    DiplomaticWars = 134217728,
    ShipDisengagement = 268435456,
    ArmyDisengagement = 536870912,
    ShareCommunications = 1073741824
} ECountryTypeFlags;


typedef enum ECountryModuleType {
    COUNTRY_MODULE_EVENT = 0,
    COUNTRY_MODULE_ECONOMY = 1,
    COUNTRY_MODULE_LEADER = 2,
    COUNTRY_MODULE_DIPLOMACY = 3,
    COUNTRY_MODULE_TECHNOLOGY = 4,
    COUNTRY_MODULE_POPFACTIONS = 5,
    COUNTRY_MODULE_EXPANSION = 6,
    COUNTRY_MODULE_SPECIES_RIGHTS = 7,
    COUNTRY_MODULE_TRADE_ROUTES = 8,
    COUNTRY_MODULE_numof = 9
} ECountryModuleType;


typedef enum ECountryAISettingsFlags {
    None = 0,
    Enabled = 1,
    DeclareWars = 2,
    Colonize = 4,
    InternalPolicies = 8,
    DoModification = 16,
    ChangeGovernment = 32,
    Traditions = 64,
    DoConstruction = 128,
    DoLimitedConstruction = 256,
    UpgradeStarbases = 512,
    Diplomacy = 1024,
    Tech = 2048,
    FollowAllies = 4096,
    AvoidEnemies = 8192,
    CanUseMarket = 16384,
    Espionage = 32768,
    AscensionPerks = 65536
} ECountryAISettingsFlags;

typedef enum ETechStatusFlags {
    None = 0,
    AutoResearchPhysics = 1,
    AutoResearchSociety = 2,
    AutoResearchEngineering = 4
} ETechStatusFlags;


typedef enum EAICountryFlags {
    None = 0,
    NeedsBuildings = 1,
    NeedsStations = 2,
    PrepareWar = 4,
    InWar = 8,
    IsDeficitSpending = 16,
    HasCreatedColonizeData = 32,
    NavyDepleted = 64,
    CanBuildRobots = 128,
    NeedStrategicWarData = 256
} EAICountryFlags;


typedef enum ERelationFlags {
    Default = 0,
    None = 0,
    IsHostile = 1,
    ForcedNeutrality = 2,
    ForcedFriendly = 4,
    HasCommunications = 8,
    IsBordering = 16,
    HasDefensivePact = 32,
    HasAlliance = 64,
    HasSubjectRelation = 128,
    HasGuarantee = 256,
    HasSupportIndependence = 512,
    HasNonAggressionPact = 1024,
    HasCommercialPact = 2048,
    HasResearchAgreement = 4096,
    HasMigrationPact = 8192,
    HasRivalry = 16384,
    ClosedBorders = 32768,
    HasContact = 65536,
    AtWar = 131072,
    HasEmbassy = 262144
} ERelationFlags;

typedef enum EType {
    Invalid = 0,
    Tradition = 1,
    AscensionPerk = 2
} EType;


typedef enum EMessageNotificationType {
    _MESSAGE_TYPE_ANOMALY_ = 0,
    _MESSAGE_TYPE_COMBAT_STATS_ = 1,
    _MESSAGE_TYPE_DEBRIS_ = 2,
    _MESSAGE_TYPE_ELECTION_ = 3,
    _MESSAGE_TYPE_FTL_ANALYSIS_ = 4,
    _MESSAGE_TYPE_FTL_DISCOVERED_ = 5,
    _MESSAGE_TYPE_LEADER_LEVEL_UP_ = 6,
    _MESSAGE_TYPE_NEW_LEADER_ = 7,
    _MESSAGE_TYPE_TARGET_COORDINATE_ = 8,
    _MESSAGE_TYPE_TRADE_DEAL_ = 9,
    _MESSAGE_TYPE_WAR_ = 10,
    _MESSAGE_TYPE_EDICT_ = 11,
    _MESSAGE_TYPE_ESN_ARRIVED_ = 12,
    _MESSAGE_TYPE_ESN_ABORTED_ = 13,
    _MESSAGE_TYPE_FOUNDER_SPECIES_PUT_ON_MARKET_ = 14,
    _MESSAGE_TYPE_ARCHAEOLOGY_ = 15,
    _MESSAGE_TYPE_GALACTIC_COMMUNITY_ = 16,
    _MESSAGE_TYPE_GALACTIC_COMMUNITY_SENATE_ = 17,
    _MESSAGE_TYPE_GALACTIC_COUNCIL_ = 18,
    _MESSAGE_TYPE_FEDERATION_ = 19,
    _MESSAGE_TYPE_FIRST_CONTACT_ = 20,
    _MESSAGE_TYPE_SITUATION_ = 21,
    _MESSAGE_TYPE_NONE_ = 22,
    _NUM_MESSAGE_TYPES_ = 22
} EMessageNotificationType;


typedef enum EConnection {
    EAnyOther = 0,
    EOneToOne = 1,
    ScriptedConnection = 2,
    ECount = 3
} EConnection;


typedef enum CLocationType {
    None = 0,
    Sector = 1,
    Planet = 2,
    Fleet = 3,
    Ship = 4,
    Army = 5,
    Tech = 6,
    Empire = 7,
    GalacticCommunity = 8,
    Federation = 9,
    SpyNetwork = 10,
    FirstContactSystem = 11
} CLocationType;

typedef enum EEnvoyAssignment {
    ImproveRelation = 0,
    HarmRelation = 1,
    GalacticCommunityDelegate = 2,
    FederationDelegate = 3,
    FirstContact = 4,
    StrengthenImperialAuthority = 5,
    UndermineImperialAuthority = 6,
    BuildSpyNetwork = 7,
    None = 8,
    Count = 9
} EEnvoyAssignment;


typedef enum EAIPriority {
    PRIORITY_NONE = 0,
    PRIORITY_NEUTRALITY = 1,
    PRIORITY_MAKE_RIVAL = 2,
    PRIORITY_MAKE_FRIEND = 3
} EAIPriority;


typedef enum SelectableType {
    _SELECTABLE_SHIP_ = 0,
    _SELECTABLE_FLEET_ = 1,
    _SELECTABLE_PLANET_ = 2,
    _SELECTABLE_GALACTIC_OBJECT_ = 3,
    _SELECTABLE_DEBRIS_ = 4,
    _SELECTABLE_AMBIENT_OBJECT_ = 5,
    _SELECTABLE_MEGASTRUCTURE_ = 6,
    _SELECTABLE_WORMHOLE_ = 7,
    _SELECTABLE_none_ = 8
} SelectableType;

typedef enum EProjectStatus {
    _PROJECT_STATUS_AVAILABLE_ = 0,
    _PROJECT_STATUS_IN_PROGRESS_ = 1,
    _PROJECT_STATUS_COMPLETED_ = 2,
    _PROJECT_STATUS_ABORTED_ = 3,
    _PROJECT_STATUS_FAILED_ = 4,
    _PROJECT_STATUS_TIMED_OUT_ = 5
} EProjectStatus;

typedef enum CAutoOpenSetting {
    None = 0,
    Player = 1,
    Others = 2,
    All = 3
} CAutoOpenSetting;


typedef enum EBuildingCategory {
    CATEGORY_ALL = 0,
    CATEGORY_POP_ASSEMBLY = 1,
    CATEGORY_GOVERNMENT = 2,
    CATEGORY_RESOURCE = 3,
    CATEGORY_MANUFACTURING = 4,
    CATEGORY_RESEARCH = 5,
    CATEGORY_TRADE = 6,
    CATEGORY_AMENITY = 7,
    CATEGORY_UNITY = 8,
    CATEGORY_ARMY = 9,
    CATEGORY_COUNT = 10
} EBuildingCategory;


typedef enum EVoteResolution {
    Yes = 0,
    No = 1,
    Neutral = 2
} EVoteResolution;

typedef enum ESituationCategory {
    PositiveSituation = 0,
    NegativeSituation = 1,
    NeutralSituation = 2
} ESituationCategory;

typedef enum EBuildingTypeProperties {
    None = 0,
    IsCapital = 1,
    HasFTLInhibitor = 2,
    IsCappedByModifier = 4,
    CanBeRuined = 8,
    CanBeDisabled = 16,
    CanDemolish = 32,
    CanBuild = 64,
    IsForBranchOffice = 128,
    IsEssential = 256
} EBuildingTypeProperties;

typedef enum EAIFleetGroupType {
    AI_FLEET_INVADE = 0,
    AI_FLEET_ATTACK = 1,
    AI_FLEET_DEFENSE = 2,
    AI_FLEET_FOLLOW = 3,
    AI_FLEET_DESTROY = 4,
    AI_NUM_FLEET_TYPES = 5
} EAIFleetGroupType;

typedef enum EPathFindSettings {
    None = 0,
    Evasive = 1,
    CheckAccess = 2,
    IgnoreHyperlaneRange = 4,
    EvasiveAllowContestedNodes = 8
} EPathFindSettings;


typedef enum EIntelInfo {
    RelativeEconomy = -2147483648,
    None = 0,
    RelativeFleet = 0,
    RelativePower = 0,
    RelativeTech = 0,
    RelicsOwned = 0,
    Rivalries = 0,
    Ruler = 0,
    SystemFull = 0,
    SystemHigh = 0,
    SystemLow = 0,
    SystemMedium = 0,
    TechCategoryNum = 0,
    TechCurrentResearch = 0,
    TechResearched = 0,
    TechScientists = 0,
    AscensionPerks = 1,
    Authority = 2,
    CapitalLocation = 4,
    CasusBelli = 8,
    Civics = 16,
    DiplomaticPacts = 32,
    EconomyCivShipsLocations = 64,
    EconomyCivShipsOrders = 128,
    EconomyColoniesFull = 256,
    EconomyColoniesHigh = 512,
    EconomyColoniesLow = 1024,
    EconomyColoniesMed = 2048,
    EmpireSprawl = 4096,
    EnvoyLocations = 8192,
    EnvoyMissions = 16384,
    EnvoyNames = 32768,
    Ethics = 65536,
    Factions = 131072,
    FederationName = 262144,
    Governors = 524288,
    Heir = 1048576,
    MilitaryAdmirals = 2097152,
    MilitaryArmies = 4194304,
    MilitaryFleetDetails = 8388608,
    MilitaryFleetOrders = 16777216,
    MilitaryFleets = 33554432,
    MilitaryGenerals = 67108864,
    MilitaryStarbases = 134217728,
    NumberOfEnvoys = 268435456,
    OpinionBreakdown = 536870912,
    Origin = 1073741824
} EIntelInfo;


typedef enum ESpeciesPurgeType {
    _PURGE_MATRIX_ = 0,
    _PURGE_NORMAL_ = 1,
    _PURGE_NEUTERING_ = 2,
    _PURGE_DISPLACEMENT_ = 3,
    _PURGE_LABOR_CAMPS_ = 4,
    _PURGE_PROCESSING_ = 5,
    _PURGE_NECROPHAGE_ = 6,
    _NUM_OF_PURGE_TYPES_ = 7
} ESpeciesPurgeType;

typedef enum EJobPossiblePreCalc {
    None = 0,
    Drone = 1,
    Worker = 2,
    Specialist = 3,
    Ruler = 4
} EJobPossiblePreCalc;


typedef enum EResolutionFlags {
    None = 0,
    Targeted = 1,
    Sanction = 2,
    Harmful = 4,
    FireAndForget = 8
} EResolutionFlags;


typedef enum EJobTypeSettingsType {
    None = 0,
    IsCappedByModifier = 1,
    CanSetPriority = 2,
    IsPreSapient = 4,
    ContributesToDiploWeight = 8,
    IgnoresSapience = 16,
    IgnoresFavorite = 32
} EJobTypeSettingsType;


typedef struct CTooltipModeHandler CTooltipModeHandler, * PCTooltipModeHandler;
typedef struct CActionInputGenerator CActionInputGenerator, * PCActionInputGenerator;

//template <typename T> using  CList = CList<T>;

struct CTooltipModeHandler {
    enum ESelectionState _eSelectionState;
    bool _bAccessible;
    bool _bActive;
    struct CGuiObject* _pSelectedObject;
    class CPdxArray<CGuiObject *, int> _Objects;
    class Matrix<float, 2, 1, 0, 2, 1> _SelectDirection;
};

struct unnamed_type_Analog {
    enum EGamepadAnalog _Axis;
    enum EGamepadAnalogDirection _Direction;
    float _vLastTriggerValue;
};

union UGamepadVirtualButton {
    enum EGamepadButton _Button;
    struct unnamed_type_Analog _Analog;
};

struct SGamepadButtonTrigger {
    union UGamepadVirtualButton _VirtualButton;
    enum EGamepadEventType _EventType;
    enum EUnionDataType _UnionType;
};

struct SGamepadAnalogTrigger {
    enum EGamepadAnalog _Analog;
    enum EGamepadAnalogDirection _Direction;
};

struct SSpecificTrigger {
    struct SGamepadButtonTrigger _GamepadButton;
    struct SGamepadAnalogTrigger _GamepadAnalog;
};

struct SInputTrigger {
    enum ETriggerType _Type;
    struct SSpecificTrigger _Specifics;
};

struct SActionMapping {
    enum EMappingValueType _ValueType;
    bool _bRepeating;
    float _vRepeatTimer;
    int _nRepeatCount;
    bool _bActive;
    struct CString _Action;
    class CPdxArray<SInputTrigger, int> _Triggers;
};

struct CActionInputGenerator {
    class CPdxArray<SActionMapping, int> _ActionMappings;
};

struct SSoundEffectHandle {
    ushort _nIndex;
    ushort _nId;
};

struct CColor {
    class Matrix<float, 4, 1, 0, 4, 1> _Color;
};

struct CUpdateable {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    uint _nUpdateableId;
    undefined field113_0x74;
    undefined field114_0x75;
    undefined field115_0x76;
    undefined field116_0x77;
};


struct CButtonStandard {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    undefined field112_0x70;
    undefined field113_0x71;
    undefined field114_0x72;
    undefined field115_0x73;
    undefined field116_0x74;
    undefined field117_0x75;
    undefined field118_0x76;
    undefined field119_0x77;
    undefined field120_0x78;
    undefined field121_0x79;
    undefined field122_0x7a;
    undefined field123_0x7b;
    undefined field124_0x7c;
    undefined field125_0x7d;
    undefined field126_0x7e;
    undefined field127_0x7f;
    undefined field128_0x80;
    undefined field129_0x81;
    undefined field130_0x82;
    undefined field131_0x83;
    undefined field132_0x84;
    undefined field133_0x85;
    undefined field134_0x86;
    undefined field135_0x87;
    undefined field136_0x88;
    undefined field137_0x89;
    undefined field138_0x8a;
    undefined field139_0x8b;
    undefined field140_0x8c;
    undefined field141_0x8d;
    undefined field142_0x8e;
    undefined field143_0x8f;
    undefined field144_0x90;
    undefined field145_0x91;
    undefined field146_0x92;
    undefined field147_0x93;
    undefined field148_0x94;
    undefined field149_0x95;
    undefined field150_0x96;
    undefined field151_0x97;
    undefined field152_0x98;
    undefined field153_0x99;
    undefined field154_0x9a;
    undefined field155_0x9b;
    undefined field156_0x9c;
    undefined field157_0x9d;
    undefined field158_0x9e;
    undefined field159_0x9f;
    undefined field160_0xa0;
    undefined field161_0xa1;
    undefined field162_0xa2;
    undefined field163_0xa3;
    undefined field164_0xa4;
    undefined field165_0xa5;
    undefined field166_0xa6;
    undefined field167_0xa7;
    undefined field168_0xa8;
    undefined field169_0xa9;
    undefined field170_0xaa;
    undefined field171_0xab;
    undefined field172_0xac;
    undefined field173_0xad;
    undefined field174_0xae;
    undefined field175_0xaf;
    undefined field176_0xb0;
    undefined field177_0xb1;
    undefined field178_0xb2;
    undefined field179_0xb3;
    undefined field180_0xb4;
    undefined field181_0xb5;
    undefined field182_0xb6;
    undefined field183_0xb7;
    undefined field184_0xb8;
    undefined field185_0xb9;
    undefined field186_0xba;
    undefined field187_0xbb;
    undefined field188_0xbc;
    undefined field189_0xbd;
    undefined field190_0xbe;
    undefined field191_0xbf;
    undefined field192_0xc0;
    undefined field193_0xc1;
    undefined field194_0xc2;
    undefined field195_0xc3;
    undefined field196_0xc4;
    undefined field197_0xc5;
    undefined field198_0xc6;
    undefined field199_0xc7;
    undefined field200_0xc8;
    undefined field201_0xc9;
    undefined field202_0xca;
    undefined field203_0xcb;
    undefined field204_0xcc;
    undefined field205_0xcd;
    undefined field206_0xce;
    undefined field207_0xcf;
    undefined field208_0xd0;
    undefined field209_0xd1;
    undefined field210_0xd2;
    undefined field211_0xd3;
    undefined field212_0xd4;
    undefined field213_0xd5;
    undefined field214_0xd6;
    undefined field215_0xd7;
    undefined field216_0xd8;
    undefined field217_0xd9;
    undefined field218_0xda;
    undefined field219_0xdb;
    undefined field220_0xdc;
    undefined field221_0xdd;
    undefined field222_0xde;
    undefined field223_0xdf;
    undefined field224_0xe0;
    undefined field225_0xe1;
    undefined field226_0xe2;
    undefined field227_0xe3;
    undefined field228_0xe4;
    undefined field229_0xe5;
    undefined field230_0xe6;
    undefined field231_0xe7;
    undefined field232_0xe8;
    undefined field233_0xe9;
    undefined field234_0xea;
    undefined field235_0xeb;
    undefined field236_0xec;
    undefined field237_0xed;
    undefined field238_0xee;
    undefined field239_0xef;
    undefined field240_0xf0;
    undefined field241_0xf1;
    undefined field242_0xf2;
    undefined field243_0xf3;
    undefined field244_0xf4;
    undefined field245_0xf5;
    undefined field246_0xf6;
    undefined field247_0xf7;
    undefined field248_0xf8;
    undefined field249_0xf9;
    undefined field250_0xfa;
    undefined field251_0xfb;
    undefined field252_0xfc;
    undefined field253_0xfd;
    undefined field254_0xfe;
    undefined field255_0xff;
    undefined field256_0x100;
    undefined field257_0x101;
    undefined field258_0x102;
    undefined field259_0x103;
    undefined field260_0x104;
    undefined field261_0x105;
    undefined field262_0x106;
    undefined field263_0x107;
    undefined field264_0x108;
    undefined field265_0x109;
    undefined field266_0x10a;
    undefined field267_0x10b;
    undefined field268_0x10c;
    undefined field269_0x10d;
    undefined field270_0x10e;
    undefined field271_0x10f;
    undefined field272_0x110;
    undefined field273_0x111;
    undefined field274_0x112;
    undefined field275_0x113;
    undefined field276_0x114;
    undefined field277_0x115;
    undefined field278_0x116;
    undefined field279_0x117;
    undefined field280_0x118;
    undefined field281_0x119;
    undefined field282_0x11a;
    undefined field283_0x11b;
    undefined field284_0x11c;
    undefined field285_0x11d;
    undefined field286_0x11e;
    undefined field287_0x11f;
    undefined field288_0x120;
    undefined field289_0x121;
    undefined field290_0x122;
    undefined field291_0x123;
    undefined field292_0x124;
    undefined field293_0x125;
    undefined field294_0x126;
    undefined field295_0x127;
    undefined field296_0x128;
    undefined field297_0x129;
    undefined field298_0x12a;
    undefined field299_0x12b;
    undefined field300_0x12c;
    undefined field301_0x12d;
    undefined field302_0x12e;
    undefined field303_0x12f;
    undefined field304_0x130;
    undefined field305_0x131;
    undefined field306_0x132;
    undefined field307_0x133;
    undefined field308_0x134;
    undefined field309_0x135;
    undefined field310_0x136;
    undefined field311_0x137;
    undefined field312_0x138;
    undefined field313_0x139;
    undefined field314_0x13a;
    undefined field315_0x13b;
    undefined field316_0x13c;
    undefined field317_0x13d;
    undefined field318_0x13e;
    undefined field319_0x13f;
    struct CGuiGraphics* _graphics;
    struct CGraphicalObject* _pSprite;
    struct CButtonType* _pButtonType;
    class CVector2<int> _position;
    class CVector2<int> _originalPosition;
    struct CInstantTextObject* _pTextSprite;
    struct CClock* _pClock;
    struct CTextBox* _pToolTip;
    struct CString _tooltip;
    struct CString _tooltipText;
    struct CString _delayedTooltipText;
    struct CString _ButtonText;
    struct CFont* _pFont;
    struct C2dObject* _WindowOrigo;
    enum EGuiOrientation _Orientation;
    class CVector2<int> _WindowSize;
    undefined field336_0x21c;
    undefined field337_0x21d;
    undefined field338_0x21e;
    undefined field339_0x21f;
    struct SoundEffectAUDIO* _OverSound;
    struct SoundEffectAUDIO* _DownSound;
    struct SoundEffectAUDIO* _UpSound;
    struct SoundEffectAUDIO* _ClickSound;
    struct SSoundEffectHandle _ClickSoundInstance;
    int _nState;
    int _nFrame;
    class CPoint<int> _Size;
    int _CustomValue;
    float _vRotate;
    float _vScale;
    bool _bSpriteIsInstantTextObject;
    bool _bAlwaysTransparent;
    bool _bGamepadSelected;
    undefined field354_0x263;
    undefined field355_0x264;
    undefined field356_0x265;
    undefined field357_0x266;
    undefined field358_0x267;
};

union t_UserData {
    int intPart;
    void* voidPart;
};

struct CGuiObject {
    undefined field0_0x0;
    undefined field1_0x1;
    undefined field2_0x2;
    undefined field3_0x3;
    undefined field4_0x4;
    undefined field5_0x5;
    undefined field6_0x6;
    undefined field7_0x7;
    bool _ToBeKilled;
    bool _bIsShown;
    bool _bWantFocus;
    bool _bLockFocus;
    bool _bMayDeleteOutofTurn;
    bool _bAcceptDragBoxToEnd;
    bool _bAcceptBlockingInput;
    bool _bMouseIsOver;
    bool _bMouseWasOver;
    bool _bAllwaysDisabled;
    bool _bSoundEnable;
    bool _bIsExlusive;
    bool _bCollidable;
    bool _bAcceptDragBoxToStart;
    bool _bAllowMapZoom;
    undefined field23_0x17;
    int _nCollisionStackRange;
    float _priority;
    union t_UserData _UserData;
    struct CTooltipHandler* _pTooltipHandler;
    struct CCursorHandler* _pCursorHandler;
    struct CGuiType* _pType;
    struct CGui* _Owner;
    struct CString _UserDataString;
    struct CString _DynamicHintTag;
    struct CString _Scope;
};


struct CMultiSpriteButton {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    undefined field112_0x70;
    undefined field113_0x71;
    undefined field114_0x72;
    undefined field115_0x73;
    undefined field116_0x74;
    undefined field117_0x75;
    undefined field118_0x76;
    undefined field119_0x77;
    undefined field120_0x78;
    undefined field121_0x79;
    undefined field122_0x7a;
    undefined field123_0x7b;
    undefined field124_0x7c;
    undefined field125_0x7d;
    undefined field126_0x7e;
    undefined field127_0x7f;
    undefined field128_0x80;
    undefined field129_0x81;
    undefined field130_0x82;
    undefined field131_0x83;
    undefined field132_0x84;
    undefined field133_0x85;
    undefined field134_0x86;
    undefined field135_0x87;
    undefined field136_0x88;
    undefined field137_0x89;
    undefined field138_0x8a;
    undefined field139_0x8b;
    undefined field140_0x8c;
    undefined field141_0x8d;
    undefined field142_0x8e;
    undefined field143_0x8f;
    undefined field144_0x90;
    undefined field145_0x91;
    undefined field146_0x92;
    undefined field147_0x93;
    undefined field148_0x94;
    undefined field149_0x95;
    undefined field150_0x96;
    undefined field151_0x97;
    undefined field152_0x98;
    undefined field153_0x99;
    undefined field154_0x9a;
    undefined field155_0x9b;
    undefined field156_0x9c;
    undefined field157_0x9d;
    undefined field158_0x9e;
    undefined field159_0x9f;
    undefined field160_0xa0;
    undefined field161_0xa1;
    undefined field162_0xa2;
    undefined field163_0xa3;
    undefined field164_0xa4;
    undefined field165_0xa5;
    undefined field166_0xa6;
    undefined field167_0xa7;
    undefined field168_0xa8;
    undefined field169_0xa9;
    undefined field170_0xaa;
    undefined field171_0xab;
    undefined field172_0xac;
    undefined field173_0xad;
    undefined field174_0xae;
    undefined field175_0xaf;
    undefined field176_0xb0;
    undefined field177_0xb1;
    undefined field178_0xb2;
    undefined field179_0xb3;
    undefined field180_0xb4;
    undefined field181_0xb5;
    undefined field182_0xb6;
    undefined field183_0xb7;
    undefined field184_0xb8;
    undefined field185_0xb9;
    undefined field186_0xba;
    undefined field187_0xbb;
    undefined field188_0xbc;
    undefined field189_0xbd;
    undefined field190_0xbe;
    undefined field191_0xbf;
    undefined field192_0xc0;
    undefined field193_0xc1;
    undefined field194_0xc2;
    undefined field195_0xc3;
    undefined field196_0xc4;
    undefined field197_0xc5;
    undefined field198_0xc6;
    undefined field199_0xc7;
    undefined field200_0xc8;
    undefined field201_0xc9;
    undefined field202_0xca;
    undefined field203_0xcb;
    undefined field204_0xcc;
    undefined field205_0xcd;
    undefined field206_0xce;
    undefined field207_0xcf;
    undefined field208_0xd0;
    undefined field209_0xd1;
    undefined field210_0xd2;
    undefined field211_0xd3;
    undefined field212_0xd4;
    undefined field213_0xd5;
    undefined field214_0xd6;
    undefined field215_0xd7;
    undefined field216_0xd8;
    undefined field217_0xd9;
    undefined field218_0xda;
    undefined field219_0xdb;
    undefined field220_0xdc;
    undefined field221_0xdd;
    undefined field222_0xde;
    undefined field223_0xdf;
    undefined field224_0xe0;
    undefined field225_0xe1;
    undefined field226_0xe2;
    undefined field227_0xe3;
    undefined field228_0xe4;
    undefined field229_0xe5;
    undefined field230_0xe6;
    undefined field231_0xe7;
    undefined field232_0xe8;
    undefined field233_0xe9;
    undefined field234_0xea;
    undefined field235_0xeb;
    undefined field236_0xec;
    undefined field237_0xed;
    undefined field238_0xee;
    undefined field239_0xef;
    undefined field240_0xf0;
    undefined field241_0xf1;
    undefined field242_0xf2;
    undefined field243_0xf3;
    undefined field244_0xf4;
    undefined field245_0xf5;
    undefined field246_0xf6;
    undefined field247_0xf7;
    undefined field248_0xf8;
    undefined field249_0xf9;
    undefined field250_0xfa;
    undefined field251_0xfb;
    undefined field252_0xfc;
    undefined field253_0xfd;
    undefined field254_0xfe;
    undefined field255_0xff;
    undefined field256_0x100;
    undefined field257_0x101;
    undefined field258_0x102;
    undefined field259_0x103;
    undefined field260_0x104;
    undefined field261_0x105;
    undefined field262_0x106;
    undefined field263_0x107;
    undefined field264_0x108;
    undefined field265_0x109;
    undefined field266_0x10a;
    undefined field267_0x10b;
    undefined field268_0x10c;
    undefined field269_0x10d;
    undefined field270_0x10e;
    undefined field271_0x10f;
    undefined field272_0x110;
    undefined field273_0x111;
    undefined field274_0x112;
    undefined field275_0x113;
    undefined field276_0x114;
    undefined field277_0x115;
    undefined field278_0x116;
    undefined field279_0x117;
    undefined field280_0x118;
    undefined field281_0x119;
    undefined field282_0x11a;
    undefined field283_0x11b;
    undefined field284_0x11c;
    undefined field285_0x11d;
    undefined field286_0x11e;
    undefined field287_0x11f;
    undefined field288_0x120;
    undefined field289_0x121;
    undefined field290_0x122;
    undefined field291_0x123;
    undefined field292_0x124;
    undefined field293_0x125;
    undefined field294_0x126;
    undefined field295_0x127;
    undefined field296_0x128;
    undefined field297_0x129;
    undefined field298_0x12a;
    undefined field299_0x12b;
    undefined field300_0x12c;
    undefined field301_0x12d;
    undefined field302_0x12e;
    undefined field303_0x12f;
    undefined field304_0x130;
    undefined field305_0x131;
    undefined field306_0x132;
    undefined field307_0x133;
    undefined field308_0x134;
    undefined field309_0x135;
    undefined field310_0x136;
    undefined field311_0x137;
    undefined field312_0x138;
    undefined field313_0x139;
    undefined field314_0x13a;
    undefined field315_0x13b;
    undefined field316_0x13c;
    undefined field317_0x13d;
    undefined field318_0x13e;
    undefined field319_0x13f;
    undefined field320_0x140;
    undefined field321_0x141;
    undefined field322_0x142;
    undefined field323_0x143;
    undefined field324_0x144;
    undefined field325_0x145;
    undefined field326_0x146;
    undefined field327_0x147;
    undefined field328_0x148;
    undefined field329_0x149;
    undefined field330_0x14a;
    undefined field331_0x14b;
    undefined field332_0x14c;
    undefined field333_0x14d;
    undefined field334_0x14e;
    undefined field335_0x14f;
    undefined field336_0x150;
    undefined field337_0x151;
    undefined field338_0x152;
    undefined field339_0x153;
    undefined field340_0x154;
    undefined field341_0x155;
    undefined field342_0x156;
    undefined field343_0x157;
    undefined field344_0x158;
    undefined field345_0x159;
    undefined field346_0x15a;
    undefined field347_0x15b;
    undefined field348_0x15c;
    undefined field349_0x15d;
    undefined field350_0x15e;
    undefined field351_0x15f;
    undefined field352_0x160;
    undefined field353_0x161;
    undefined field354_0x162;
    undefined field355_0x163;
    undefined field356_0x164;
    undefined field357_0x165;
    undefined field358_0x166;
    undefined field359_0x167;
    undefined field360_0x168;
    undefined field361_0x169;
    undefined field362_0x16a;
    undefined field363_0x16b;
    undefined field364_0x16c;
    undefined field365_0x16d;
    undefined field366_0x16e;
    undefined field367_0x16f;
    undefined field368_0x170;
    undefined field369_0x171;
    undefined field370_0x172;
    undefined field371_0x173;
    undefined field372_0x174;
    undefined field373_0x175;
    undefined field374_0x176;
    undefined field375_0x177;
    undefined field376_0x178;
    undefined field377_0x179;
    undefined field378_0x17a;
    undefined field379_0x17b;
    undefined field380_0x17c;
    undefined field381_0x17d;
    undefined field382_0x17e;
    undefined field383_0x17f;
    undefined field384_0x180;
    undefined field385_0x181;
    undefined field386_0x182;
    undefined field387_0x183;
    undefined field388_0x184;
    undefined field389_0x185;
    undefined field390_0x186;
    undefined field391_0x187;
    undefined field392_0x188;
    undefined field393_0x189;
    undefined field394_0x18a;
    undefined field395_0x18b;
    undefined field396_0x18c;
    undefined field397_0x18d;
    undefined field398_0x18e;
    undefined field399_0x18f;
    undefined field400_0x190;
    undefined field401_0x191;
    undefined field402_0x192;
    undefined field403_0x193;
    undefined field404_0x194;
    undefined field405_0x195;
    undefined field406_0x196;
    undefined field407_0x197;
    undefined field408_0x198;
    undefined field409_0x199;
    undefined field410_0x19a;
    undefined field411_0x19b;
    undefined field412_0x19c;
    undefined field413_0x19d;
    undefined field414_0x19e;
    undefined field415_0x19f;
    undefined field416_0x1a0;
    undefined field417_0x1a1;
    undefined field418_0x1a2;
    undefined field419_0x1a3;
    undefined field420_0x1a4;
    undefined field421_0x1a5;
    undefined field422_0x1a6;
    undefined field423_0x1a7;
    undefined field424_0x1a8;
    undefined field425_0x1a9;
    undefined field426_0x1aa;
    undefined field427_0x1ab;
    undefined field428_0x1ac;
    undefined field429_0x1ad;
    undefined field430_0x1ae;
    undefined field431_0x1af;
    undefined field432_0x1b0;
    undefined field433_0x1b1;
    undefined field434_0x1b2;
    undefined field435_0x1b3;
    undefined field436_0x1b4;
    undefined field437_0x1b5;
    undefined field438_0x1b6;
    undefined field439_0x1b7;
    undefined field440_0x1b8;
    undefined field441_0x1b9;
    undefined field442_0x1ba;
    undefined field443_0x1bb;
    undefined field444_0x1bc;
    undefined field445_0x1bd;
    undefined field446_0x1be;
    undefined field447_0x1bf;
    undefined field448_0x1c0;
    undefined field449_0x1c1;
    undefined field450_0x1c2;
    undefined field451_0x1c3;
    undefined field452_0x1c4;
    undefined field453_0x1c5;
    undefined field454_0x1c6;
    undefined field455_0x1c7;
    undefined field456_0x1c8;
    undefined field457_0x1c9;
    undefined field458_0x1ca;
    undefined field459_0x1cb;
    undefined field460_0x1cc;
    undefined field461_0x1cd;
    undefined field462_0x1ce;
    undefined field463_0x1cf;
    undefined field464_0x1d0;
    undefined field465_0x1d1;
    undefined field466_0x1d2;
    undefined field467_0x1d3;
    undefined field468_0x1d4;
    undefined field469_0x1d5;
    undefined field470_0x1d6;
    undefined field471_0x1d7;
    undefined field472_0x1d8;
    undefined field473_0x1d9;
    undefined field474_0x1da;
    undefined field475_0x1db;
    undefined field476_0x1dc;
    undefined field477_0x1dd;
    undefined field478_0x1de;
    undefined field479_0x1df;
    undefined field480_0x1e0;
    undefined field481_0x1e1;
    undefined field482_0x1e2;
    undefined field483_0x1e3;
    undefined field484_0x1e4;
    undefined field485_0x1e5;
    undefined field486_0x1e6;
    undefined field487_0x1e7;
    undefined field488_0x1e8;
    undefined field489_0x1e9;
    undefined field490_0x1ea;
    undefined field491_0x1eb;
    undefined field492_0x1ec;
    undefined field493_0x1ed;
    undefined field494_0x1ee;
    undefined field495_0x1ef;
    undefined field496_0x1f0;
    undefined field497_0x1f1;
    undefined field498_0x1f2;
    undefined field499_0x1f3;
    undefined field500_0x1f4;
    undefined field501_0x1f5;
    undefined field502_0x1f6;
    undefined field503_0x1f7;
    undefined field504_0x1f8;
    undefined field505_0x1f9;
    undefined field506_0x1fa;
    undefined field507_0x1fb;
    undefined field508_0x1fc;
    undefined field509_0x1fd;
    undefined field510_0x1fe;
    undefined field511_0x1ff;
    undefined field512_0x200;
    undefined field513_0x201;
    undefined field514_0x202;
    undefined field515_0x203;
    undefined field516_0x204;
    undefined field517_0x205;
    undefined field518_0x206;
    undefined field519_0x207;
    undefined field520_0x208;
    undefined field521_0x209;
    undefined field522_0x20a;
    undefined field523_0x20b;
    undefined field524_0x20c;
    undefined field525_0x20d;
    undefined field526_0x20e;
    undefined field527_0x20f;
    undefined field528_0x210;
    undefined field529_0x211;
    undefined field530_0x212;
    undefined field531_0x213;
    undefined field532_0x214;
    undefined field533_0x215;
    undefined field534_0x216;
    undefined field535_0x217;
    undefined field536_0x218;
    undefined field537_0x219;
    undefined field538_0x21a;
    undefined field539_0x21b;
    undefined field540_0x21c;
    undefined field541_0x21d;
    undefined field542_0x21e;
    undefined field543_0x21f;
    undefined field544_0x220;
    undefined field545_0x221;
    undefined field546_0x222;
    undefined field547_0x223;
    undefined field548_0x224;
    undefined field549_0x225;
    undefined field550_0x226;
    undefined field551_0x227;
    undefined field552_0x228;
    undefined field553_0x229;
    undefined field554_0x22a;
    undefined field555_0x22b;
    undefined field556_0x22c;
    undefined field557_0x22d;
    undefined field558_0x22e;
    undefined field559_0x22f;
    undefined field560_0x230;
    undefined field561_0x231;
    undefined field562_0x232;
    undefined field563_0x233;
    undefined field564_0x234;
    undefined field565_0x235;
    undefined field566_0x236;
    undefined field567_0x237;
    undefined field568_0x238;
    undefined field569_0x239;
    undefined field570_0x23a;
    undefined field571_0x23b;
    undefined field572_0x23c;
    undefined field573_0x23d;
    undefined field574_0x23e;
    undefined field575_0x23f;
    undefined field576_0x240;
    undefined field577_0x241;
    undefined field578_0x242;
    undefined field579_0x243;
    undefined field580_0x244;
    undefined field581_0x245;
    undefined field582_0x246;
    undefined field583_0x247;
    undefined field584_0x248;
    undefined field585_0x249;
    undefined field586_0x24a;
    undefined field587_0x24b;
    undefined field588_0x24c;
    undefined field589_0x24d;
    undefined field590_0x24e;
    undefined field591_0x24f;
    undefined field592_0x250;
    undefined field593_0x251;
    undefined field594_0x252;
    undefined field595_0x253;
    undefined field596_0x254;
    undefined field597_0x255;
    undefined field598_0x256;
    undefined field599_0x257;
    undefined field600_0x258;
    undefined field601_0x259;
    undefined field602_0x25a;
    undefined field603_0x25b;
    undefined field604_0x25c;
    undefined field605_0x25d;
    undefined field606_0x25e;
    undefined field607_0x25f;
    undefined field608_0x260;
    undefined field609_0x261;
    undefined field610_0x262;
    undefined field611_0x263;
    undefined field612_0x264;
    undefined field613_0x265;
    undefined field614_0x266;
    undefined field615_0x267;
    class CPdxArray<CGraphicalObject*, int> _Sprites;
};



struct CIcon {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    undefined field112_0x70;
    undefined field113_0x71;
    undefined field114_0x72;
    undefined field115_0x73;
    undefined field116_0x74;
    undefined field117_0x75;
    undefined field118_0x76;
    undefined field119_0x77;
    undefined field120_0x78;
    undefined field121_0x79;
    undefined field122_0x7a;
    undefined field123_0x7b;
    undefined field124_0x7c;
    undefined field125_0x7d;
    undefined field126_0x7e;
    undefined field127_0x7f;
    undefined field128_0x80;
    undefined field129_0x81;
    undefined field130_0x82;
    undefined field131_0x83;
    undefined field132_0x84;
    undefined field133_0x85;
    undefined field134_0x86;
    undefined field135_0x87;
    undefined field136_0x88;
    undefined field137_0x89;
    undefined field138_0x8a;
    undefined field139_0x8b;
    undefined field140_0x8c;
    undefined field141_0x8d;
    undefined field142_0x8e;
    undefined field143_0x8f;
    undefined field144_0x90;
    undefined field145_0x91;
    undefined field146_0x92;
    undefined field147_0x93;
    undefined field148_0x94;
    undefined field149_0x95;
    undefined field150_0x96;
    undefined field151_0x97;
    undefined field152_0x98;
    undefined field153_0x99;
    undefined field154_0x9a;
    undefined field155_0x9b;
    undefined field156_0x9c;
    undefined field157_0x9d;
    undefined field158_0x9e;
    undefined field159_0x9f;
    undefined field160_0xa0;
    undefined field161_0xa1;
    undefined field162_0xa2;
    undefined field163_0xa3;
    undefined field164_0xa4;
    undefined field165_0xa5;
    undefined field166_0xa6;
    undefined field167_0xa7;
    undefined field168_0xa8;
    undefined field169_0xa9;
    undefined field170_0xaa;
    undefined field171_0xab;
    undefined field172_0xac;
    undefined field173_0xad;
    undefined field174_0xae;
    undefined field175_0xaf;
    undefined field176_0xb0;
    undefined field177_0xb1;
    undefined field178_0xb2;
    undefined field179_0xb3;
    undefined field180_0xb4;
    undefined field181_0xb5;
    undefined field182_0xb6;
    undefined field183_0xb7;
    undefined field184_0xb8;
    undefined field185_0xb9;
    undefined field186_0xba;
    undefined field187_0xbb;
    undefined field188_0xbc;
    undefined field189_0xbd;
    undefined field190_0xbe;
    undefined field191_0xbf;
    undefined field192_0xc0;
    undefined field193_0xc1;
    undefined field194_0xc2;
    undefined field195_0xc3;
    undefined field196_0xc4;
    undefined field197_0xc5;
    undefined field198_0xc6;
    undefined field199_0xc7;
    undefined field200_0xc8;
    undefined field201_0xc9;
    undefined field202_0xca;
    undefined field203_0xcb;
    undefined field204_0xcc;
    undefined field205_0xcd;
    undefined field206_0xce;
    undefined field207_0xcf;
    undefined field208_0xd0;
    undefined field209_0xd1;
    undefined field210_0xd2;
    undefined field211_0xd3;
    undefined field212_0xd4;
    undefined field213_0xd5;
    undefined field214_0xd6;
    undefined field215_0xd7;
    undefined field216_0xd8;
    undefined field217_0xd9;
    undefined field218_0xda;
    undefined field219_0xdb;
    undefined field220_0xdc;
    undefined field221_0xdd;
    undefined field222_0xde;
    undefined field223_0xdf;
    undefined field224_0xe0;
    undefined field225_0xe1;
    undefined field226_0xe2;
    undefined field227_0xe3;
    undefined field228_0xe4;
    undefined field229_0xe5;
    undefined field230_0xe6;
    undefined field231_0xe7;
    undefined field232_0xe8;
    undefined field233_0xe9;
    undefined field234_0xea;
    undefined field235_0xeb;
    undefined field236_0xec;
    undefined field237_0xed;
    undefined field238_0xee;
    undefined field239_0xef;
    undefined field240_0xf0;
    undefined field241_0xf1;
    undefined field242_0xf2;
    undefined field243_0xf3;
    undefined field244_0xf4;
    undefined field245_0xf5;
    undefined field246_0xf6;
    undefined field247_0xf7;
    undefined field248_0xf8;
    undefined field249_0xf9;
    undefined field250_0xfa;
    undefined field251_0xfb;
    undefined field252_0xfc;
    undefined field253_0xfd;
    undefined field254_0xfe;
    undefined field255_0xff;
    undefined field256_0x100;
    undefined field257_0x101;
    undefined field258_0x102;
    undefined field259_0x103;
    undefined field260_0x104;
    undefined field261_0x105;
    undefined field262_0x106;
    undefined field263_0x107;
    undefined field264_0x108;
    undefined field265_0x109;
    undefined field266_0x10a;
    undefined field267_0x10b;
    undefined field268_0x10c;
    undefined field269_0x10d;
    undefined field270_0x10e;
    undefined field271_0x10f;
    undefined field272_0x110;
    undefined field273_0x111;
    undefined field274_0x112;
    undefined field275_0x113;
    undefined field276_0x114;
    undefined field277_0x115;
    undefined field278_0x116;
    undefined field279_0x117;
    undefined field280_0x118;
    undefined field281_0x119;
    undefined field282_0x11a;
    undefined field283_0x11b;
    undefined field284_0x11c;
    undefined field285_0x11d;
    undefined field286_0x11e;
    undefined field287_0x11f;
    undefined field288_0x120;
    undefined field289_0x121;
    undefined field290_0x122;
    undefined field291_0x123;
    undefined field292_0x124;
    undefined field293_0x125;
    undefined field294_0x126;
    undefined field295_0x127;
    undefined field296_0x128;
    undefined field297_0x129;
    undefined field298_0x12a;
    undefined field299_0x12b;
    undefined field300_0x12c;
    undefined field301_0x12d;
    undefined field302_0x12e;
    undefined field303_0x12f;
    undefined field304_0x130;
    undefined field305_0x131;
    undefined field306_0x132;
    undefined field307_0x133;
    undefined field308_0x134;
    undefined field309_0x135;
    undefined field310_0x136;
    undefined field311_0x137;
    undefined field312_0x138;
    undefined field313_0x139;
    undefined field314_0x13a;
    undefined field315_0x13b;
    undefined field316_0x13c;
    undefined field317_0x13d;
    undefined field318_0x13e;
    undefined field319_0x13f;
    struct CGraphicalObject* _pSprite;
    struct C2dObject* _pWindowOrigo;
    struct CGuiGraphics* _Graphics;
    class CVector3<float> _ActualPosition;
    class CVector2<int> _OriginalPosition;
    float _vLastTime;
    class CVector2<int> _Position;
    bool _bIs2d;
    undefined field328_0x179;
    undefined field329_0x17a;
    undefined field330_0x17b;
    float _vScale;
    enum EGuiOrientation _Orientation;
    class CVector2<int> _WindowSize;
    bool _bAdvanceTime;
    bool _bShallBeHighLighted;
    undefined field336_0x18e;
    undefined field337_0x18f;
    struct CColor _ModulateColor;
    bool _bIsHighlighted;
    bool _bHighligth;
    undefined field341_0x1a2;
    undefined field342_0x1a3;
    float _vRotate;
    bool _bAlwaysTransparent;
    bool _bCenterPosition;
    undefined field346_0x1aa;
    undefined field347_0x1ab;
    undefined field348_0x1ac;
    undefined field349_0x1ad;
    undefined field350_0x1ae;
    undefined field351_0x1af;
};


struct CBrowser {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    undefined field112_0x70;
    undefined field113_0x71;
    undefined field114_0x72;
    undefined field115_0x73;
    undefined field116_0x74;
    undefined field117_0x75;
    undefined field118_0x76;
    undefined field119_0x77;
    undefined field120_0x78;
    undefined field121_0x79;
    undefined field122_0x7a;
    undefined field123_0x7b;
    undefined field124_0x7c;
    undefined field125_0x7d;
    undefined field126_0x7e;
    undefined field127_0x7f;
    undefined field128_0x80;
    undefined field129_0x81;
    undefined field130_0x82;
    undefined field131_0x83;
    undefined field132_0x84;
    undefined field133_0x85;
    undefined field134_0x86;
    undefined field135_0x87;
    undefined field136_0x88;
    undefined field137_0x89;
    undefined field138_0x8a;
    undefined field139_0x8b;
    undefined field140_0x8c;
    undefined field141_0x8d;
    undefined field142_0x8e;
    undefined field143_0x8f;
    undefined field144_0x90;
    undefined field145_0x91;
    undefined field146_0x92;
    undefined field147_0x93;
    undefined field148_0x94;
    undefined field149_0x95;
    undefined field150_0x96;
    undefined field151_0x97;
    undefined field152_0x98;
    undefined field153_0x99;
    undefined field154_0x9a;
    undefined field155_0x9b;
    undefined field156_0x9c;
    undefined field157_0x9d;
    undefined field158_0x9e;
    undefined field159_0x9f;
    undefined field160_0xa0;
    undefined field161_0xa1;
    undefined field162_0xa2;
    undefined field163_0xa3;
    undefined field164_0xa4;
    undefined field165_0xa5;
    undefined field166_0xa6;
    undefined field167_0xa7;
    undefined field168_0xa8;
    undefined field169_0xa9;
    undefined field170_0xaa;
    undefined field171_0xab;
    undefined field172_0xac;
    undefined field173_0xad;
    undefined field174_0xae;
    undefined field175_0xaf;
    struct CGuiGraphics* _Graphics;
    struct C2dObject* _pWindowOrigo;
    struct CGraphicalObject* _pSprite;
    struct BrowserInstanceBROWSER* _BrowserInstance;
    struct TextureGFX* _BrowserTexture;
    bool _bHasFocus;
    undefined field182_0xd9;
    undefined field183_0xda;
    undefined field184_0xdb;
    undefined field185_0xdc;
    undefined field186_0xdd;
    undefined field187_0xde;
    undefined field188_0xdf;
};

struct CKeyEvent {
    int _nKeyCode;
    enum EModKey _ModKeys;
    enum EKeyEventType _EventType;
    bool _bIsDownRepeat;
};


struct CUTF8String {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
};


struct CTextInputEvent {
    struct CUTF8String _Text;
    int _nIMECursorPos;
    int _nIMELength;
};

struct CMouseEvent {
    enum EMouseEventType _Type;
    enum EMouseButton _Button;
    int _nWheel;
    class CPoint<int> _Position;
    class CPoint<int> _Movement;
};

struct CTouchEvent {
    int _TouchID;
    enum ETouchType _Type;
    class CPoint<int> _Position;
    class CPoint<int> _Movement;
};

struct CGamepadEvent {
    enum EGamepadEventType _eEventType;
    enum EGamepadButton _eButton;
    enum EGamepadAnalog _eAnalog;
    float _vXAxis;
    float _vYAxis;
    float _vTrigger;
    int _nIndex;
};

struct SCompanionData {
    int IntData;
    class Matrix<float, 3, 1, 0, 3, 1> FloatData;
};

struct SEventCompanionData {
    enum ECompanionDataType _CompanionDataType;
    struct SCompanionData _CompanionData;
};


struct CActionEvent {
    struct CString _Action;
    struct SEventCompanionData _CompanionData;
};

struct CInputEvent {
    struct CKeyEvent _KeyEvent;
    struct CTextInputEvent _TextEvent;
    struct CMouseEvent _MouseEvent;
    struct CTouchEvent _TouchEvent;
    struct CGamepadEvent _GamepadEvent;
    struct CActionEvent _ActionEvent;
    enum EEventType _Type;
    bool _bTaken;
};



struct CCurveGraph {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    undefined field112_0x70;
    undefined field113_0x71;
    undefined field114_0x72;
    undefined field115_0x73;
    undefined field116_0x74;
    undefined field117_0x75;
    undefined field118_0x76;
    undefined field119_0x77;
    undefined field120_0x78;
    undefined field121_0x79;
    undefined field122_0x7a;
    undefined field123_0x7b;
    undefined field124_0x7c;
    undefined field125_0x7d;
    undefined field126_0x7e;
    undefined field127_0x7f;
    undefined field128_0x80;
    undefined field129_0x81;
    undefined field130_0x82;
    undefined field131_0x83;
    undefined field132_0x84;
    undefined field133_0x85;
    undefined field134_0x86;
    undefined field135_0x87;
    undefined field136_0x88;
    undefined field137_0x89;
    undefined field138_0x8a;
    undefined field139_0x8b;
    undefined field140_0x8c;
    undefined field141_0x8d;
    undefined field142_0x8e;
    undefined field143_0x8f;
    undefined field144_0x90;
    undefined field145_0x91;
    undefined field146_0x92;
    undefined field147_0x93;
    undefined field148_0x94;
    undefined field149_0x95;
    undefined field150_0x96;
    undefined field151_0x97;
    undefined field152_0x98;
    undefined field153_0x99;
    undefined field154_0x9a;
    undefined field155_0x9b;
    undefined field156_0x9c;
    undefined field157_0x9d;
    undefined field158_0x9e;
    undefined field159_0x9f;
    undefined field160_0xa0;
    undefined field161_0xa1;
    undefined field162_0xa2;
    undefined field163_0xa3;
    undefined field164_0xa4;
    undefined field165_0xa5;
    undefined field166_0xa6;
    undefined field167_0xa7;
    undefined field168_0xa8;
    undefined field169_0xa9;
    undefined field170_0xaa;
    undefined field171_0xab;
    undefined field172_0xac;
    undefined field173_0xad;
    undefined field174_0xae;
    undefined field175_0xaf;
    int _nPoints;
    float _Points[512];
    int _nCurvePoints;
    float _CurvePoints[512];
    float _ScaleX;
    float _ScaleY;
    struct CGuiGraphics* _Graphics;
    struct C2dObject* _pWindowOrigo;
    struct CGraphicalObject* _pSprite;
    struct C2dLineObject* _pLines;
    struct C2dLineObject* _MoveablePoints[256];
    struct TextureGFX* _GraphTexture;
    bool _bHasFocus;
    bool _bMouseIsOver;
    bool _bWasManipulated;
    undefined field191_0x18eb;
    undefined field192_0x18ec;
    undefined field193_0x18ed;
    undefined field194_0x18ee;
    undefined field195_0x18ef;
    void* _pImageBuffer;
    int _nImageBufferSize;
    int _Width;
    int _Height;
    int _SelectedPoint;
};

struct CGuiPosition {
    struct TVariableValueTuple<int, unsigned char> _Position;
    struct TVariableValueTuple<int, unsigned char> _Min;
    struct TVariableValueTuple<int, unsigned char> _Max;
    struct TVariableValueTuple<int, unsigned char> _Step;
};

struct SScissorRectangle {
    int _nLeft;
    int _nTop;
    int _nRight;
    int _nBottom;
};

struct CDropDownBox {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    undefined field112_0x70;
    undefined field113_0x71;
    undefined field114_0x72;
    undefined field115_0x73;
    undefined field116_0x74;
    undefined field117_0x75;
    undefined field118_0x76;
    undefined field119_0x77;
    undefined field120_0x78;
    undefined field121_0x79;
    undefined field122_0x7a;
    undefined field123_0x7b;
    undefined field124_0x7c;
    undefined field125_0x7d;
    undefined field126_0x7e;
    undefined field127_0x7f;
    undefined field128_0x80;
    undefined field129_0x81;
    undefined field130_0x82;
    undefined field131_0x83;
    undefined field132_0x84;
    undefined field133_0x85;
    undefined field134_0x86;
    undefined field135_0x87;
    undefined field136_0x88;
    undefined field137_0x89;
    undefined field138_0x8a;
    undefined field139_0x8b;
    undefined field140_0x8c;
    undefined field141_0x8d;
    undefined field142_0x8e;
    undefined field143_0x8f;
    undefined field144_0x90;
    undefined field145_0x91;
    undefined field146_0x92;
    undefined field147_0x93;
    undefined field148_0x94;
    undefined field149_0x95;
    undefined field150_0x96;
    undefined field151_0x97;
    undefined field152_0x98;
    undefined field153_0x99;
    undefined field154_0x9a;
    undefined field155_0x9b;
    undefined field156_0x9c;
    undefined field157_0x9d;
    undefined field158_0x9e;
    undefined field159_0x9f;
    undefined field160_0xa0;
    undefined field161_0xa1;
    undefined field162_0xa2;
    undefined field163_0xa3;
    undefined field164_0xa4;
    undefined field165_0xa5;
    undefined field166_0xa6;
    undefined field167_0xa7;
    undefined field168_0xa8;
    undefined field169_0xa9;
    undefined field170_0xaa;
    undefined field171_0xab;
    undefined field172_0xac;
    undefined field173_0xad;
    undefined field174_0xae;
    undefined field175_0xaf;
    struct CButtonObserverGlue<CDropDownBox> _ToggleExpand;
    struct CButtonObserverGlue<CDropDownBox> _ContractOnLeave;
    struct SScissorRectangle _ScissorRect;
    struct CGuiPosition _Position;
    struct CGuiGraphics* _Graphics;
    struct CGui* _Gui;
    struct CDropDownBoxType* _Creator;
    struct C2dObject* _pWindowOrigo;
    struct C2dObject* _pParentOrigo;
    struct CButtonStandard* _pExpandButton;
    struct CContainerWindow* _pExpandedWindow;
    struct CContainerWindow* _pWindow;
    bool _bExpanded;
    bool _bExpandedOnTop;
    bool _bHideHeaderOnExpand;
    bool _bSelected;
    bool _bStayHidden;
    bool _bLocked;
    undefined field194_0x2d6;
    undefined field195_0x2d7;
};


struct CInstantTextBox {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    undefined field112_0x70;
    undefined field113_0x71;
    undefined field114_0x72;
    undefined field115_0x73;
    undefined field116_0x74;
    undefined field117_0x75;
    undefined field118_0x76;
    undefined field119_0x77;
    undefined field120_0x78;
    undefined field121_0x79;
    undefined field122_0x7a;
    undefined field123_0x7b;
    undefined field124_0x7c;
    undefined field125_0x7d;
    undefined field126_0x7e;
    undefined field127_0x7f;
    undefined field128_0x80;
    undefined field129_0x81;
    undefined field130_0x82;
    undefined field131_0x83;
    undefined field132_0x84;
    undefined field133_0x85;
    undefined field134_0x86;
    undefined field135_0x87;
    undefined field136_0x88;
    undefined field137_0x89;
    undefined field138_0x8a;
    undefined field139_0x8b;
    undefined field140_0x8c;
    undefined field141_0x8d;
    undefined field142_0x8e;
    undefined field143_0x8f;
    undefined field144_0x90;
    undefined field145_0x91;
    undefined field146_0x92;
    undefined field147_0x93;
    undefined field148_0x94;
    undefined field149_0x95;
    undefined field150_0x96;
    undefined field151_0x97;
    undefined field152_0x98;
    undefined field153_0x99;
    undefined field154_0x9a;
    undefined field155_0x9b;
    undefined field156_0x9c;
    undefined field157_0x9d;
    undefined field158_0x9e;
    undefined field159_0x9f;
    undefined field160_0xa0;
    undefined field161_0xa1;
    undefined field162_0xa2;
    undefined field163_0xa3;
    undefined field164_0xa4;
    undefined field165_0xa5;
    undefined field166_0xa6;
    undefined field167_0xa7;
    struct C2dObject* _pWindowOrigo;
    class CVector2<int> _WindowSize;
    struct CGuiGraphics* _Graphics;
    struct CString _FontName;
    int _nMaxWidth;
    int _nMaxHeight;
    struct CInstantTextObject* _pObject;
    struct CColor _OriginalColor;
    struct CColor _Color;
    char _DefaultColorCode;
    undefined field178_0x111;
    undefined field179_0x112;
    undefined field180_0x113;
    undefined field181_0x114;
    undefined field182_0x115;
    undefined field183_0x116;
    undefined field184_0x117;
    struct CString _Text;
    struct CInstantTextBoxType* _pMyType;
    bool _bFixedSize;
    bool _bTruncate;
    undefined field189_0x142;
    undefined field190_0x143;
    enum FontFormatting _Format;
    enum EFontVerticalAlignment _VerticalAlignment;
    bool _bStayHidden;
    bool _bAcceptDragBoxToEnd;
    undefined field195_0x14e;
    undefined field196_0x14f;
    struct CScrollbar* _pScrollbar;
    struct CScrollbarObserverGlue<CInstantTextBox> _ScrollbarValueChanged;
    bool _bHideScrollbar;
    undefined field200_0x191;
    undefined field201_0x192;
    undefined field202_0x193;
    int _nMaxScrollHeight;
};


struct COverlappingElementsBox {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    undefined field112_0x70;
    undefined field113_0x71;
    undefined field114_0x72;
    undefined field115_0x73;
    undefined field116_0x74;
    undefined field117_0x75;
    undefined field118_0x76;
    undefined field119_0x77;
    undefined field120_0x78;
    undefined field121_0x79;
    undefined field122_0x7a;
    undefined field123_0x7b;
    undefined field124_0x7c;
    undefined field125_0x7d;
    undefined field126_0x7e;
    undefined field127_0x7f;
    undefined field128_0x80;
    undefined field129_0x81;
    undefined field130_0x82;
    undefined field131_0x83;
    undefined field132_0x84;
    undefined field133_0x85;
    undefined field134_0x86;
    undefined field135_0x87;
    undefined field136_0x88;
    undefined field137_0x89;
    undefined field138_0x8a;
    undefined field139_0x8b;
    undefined field140_0x8c;
    undefined field141_0x8d;
    undefined field142_0x8e;
    undefined field143_0x8f;
    undefined field144_0x90;
    undefined field145_0x91;
    undefined field146_0x92;
    undefined field147_0x93;
    undefined field148_0x94;
    undefined field149_0x95;
    undefined field150_0x96;
    undefined field151_0x97;
    undefined field152_0x98;
    undefined field153_0x99;
    undefined field154_0x9a;
    undefined field155_0x9b;
    undefined field156_0x9c;
    undefined field157_0x9d;
    undefined field158_0x9e;
    undefined field159_0x9f;
    undefined field160_0xa0;
    undefined field161_0xa1;
    undefined field162_0xa2;
    undefined field163_0xa3;
    undefined field164_0xa4;
    undefined field165_0xa5;
    undefined field166_0xa6;
    undefined field167_0xa7;
    undefined field168_0xa8;
    undefined field169_0xa9;
    undefined field170_0xaa;
    undefined field171_0xab;
    undefined field172_0xac;
    undefined field173_0xad;
    undefined field174_0xae;
    undefined field175_0xaf;
    undefined field176_0xb0;
    undefined field177_0xb1;
    undefined field178_0xb2;
    undefined field179_0xb3;
    undefined field180_0xb4;
    undefined field181_0xb5;
    undefined field182_0xb6;
    undefined field183_0xb7;
    undefined field184_0xb8;
    undefined field185_0xb9;
    undefined field186_0xba;
    undefined field187_0xbb;
    undefined field188_0xbc;
    undefined field189_0xbd;
    undefined field190_0xbe;
    undefined field191_0xbf;
    undefined field192_0xc0;
    undefined field193_0xc1;
    undefined field194_0xc2;
    undefined field195_0xc3;
    undefined field196_0xc4;
    undefined field197_0xc5;
    undefined field198_0xc6;
    undefined field199_0xc7;
    undefined field200_0xc8;
    undefined field201_0xc9;
    undefined field202_0xca;
    undefined field203_0xcb;
    undefined field204_0xcc;
    undefined field205_0xcd;
    undefined field206_0xce;
    undefined field207_0xcf;
    undefined field208_0xd0;
    undefined field209_0xd1;
    undefined field210_0xd2;
    undefined field211_0xd3;
    undefined field212_0xd4;
    undefined field213_0xd5;
    undefined field214_0xd6;
    undefined field215_0xd7;
    undefined field216_0xd8;
    undefined field217_0xd9;
    undefined field218_0xda;
    undefined field219_0xdb;
    undefined field220_0xdc;
    undefined field221_0xdd;
    undefined field222_0xde;
    undefined field223_0xdf;
    undefined field224_0xe0;
    undefined field225_0xe1;
    undefined field226_0xe2;
    undefined field227_0xe3;
    undefined field228_0xe4;
    undefined field229_0xe5;
    undefined field230_0xe6;
    undefined field231_0xe7;
    undefined field232_0xe8;
    undefined field233_0xe9;
    undefined field234_0xea;
    undefined field235_0xeb;
    undefined field236_0xec;
    undefined field237_0xed;
    undefined field238_0xee;
    undefined field239_0xef;
    undefined field240_0xf0;
    undefined field241_0xf1;
    undefined field242_0xf2;
    undefined field243_0xf3;
    undefined field244_0xf4;
    undefined field245_0xf5;
    undefined field246_0xf6;
    undefined field247_0xf7;
    undefined field248_0xf8;
    undefined field249_0xf9;
    undefined field250_0xfa;
    undefined field251_0xfb;
    undefined field252_0xfc;
    undefined field253_0xfd;
    undefined field254_0xfe;
    undefined field255_0xff;
    undefined field256_0x100;
    undefined field257_0x101;
    undefined field258_0x102;
    undefined field259_0x103;
    undefined field260_0x104;
    undefined field261_0x105;
    undefined field262_0x106;
    undefined field263_0x107;
    undefined field264_0x108;
    undefined field265_0x109;
    undefined field266_0x10a;
    undefined field267_0x10b;
    undefined field268_0x10c;
    undefined field269_0x10d;
    undefined field270_0x10e;
    undefined field271_0x10f;
    undefined field272_0x110;
    undefined field273_0x111;
    undefined field274_0x112;
    undefined field275_0x113;
    undefined field276_0x114;
    undefined field277_0x115;
    undefined field278_0x116;
    undefined field279_0x117;
    undefined field280_0x118;
    undefined field281_0x119;
    undefined field282_0x11a;
    undefined field283_0x11b;
    undefined field284_0x11c;
    undefined field285_0x11d;
    undefined field286_0x11e;
    undefined field287_0x11f;
    undefined field288_0x120;
    undefined field289_0x121;
    undefined field290_0x122;
    undefined field291_0x123;
    undefined field292_0x124;
    undefined field293_0x125;
    undefined field294_0x126;
    undefined field295_0x127;
    undefined field296_0x128;
    undefined field297_0x129;
    undefined field298_0x12a;
    undefined field299_0x12b;
    undefined field300_0x12c;
    undefined field301_0x12d;
    undefined field302_0x12e;
    undefined field303_0x12f;
    undefined field304_0x130;
    undefined field305_0x131;
    undefined field306_0x132;
    undefined field307_0x133;
    undefined field308_0x134;
    undefined field309_0x135;
    undefined field310_0x136;
    undefined field311_0x137;
    undefined field312_0x138;
    undefined field313_0x139;
    undefined field314_0x13a;
    undefined field315_0x13b;
    undefined field316_0x13c;
    undefined field317_0x13d;
    undefined field318_0x13e;
    undefined field319_0x13f;
    undefined field320_0x140;
    undefined field321_0x141;
    undefined field322_0x142;
    undefined field323_0x143;
    undefined field324_0x144;
    undefined field325_0x145;
    undefined field326_0x146;
    undefined field327_0x147;
    undefined field328_0x148;
    undefined field329_0x149;
    undefined field330_0x14a;
    undefined field331_0x14b;
    undefined field332_0x14c;
    undefined field333_0x14d;
    undefined field334_0x14e;
    undefined field335_0x14f;
    undefined field336_0x150;
    undefined field337_0x151;
    undefined field338_0x152;
    undefined field339_0x153;
    undefined field340_0x154;
    undefined field341_0x155;
    undefined field342_0x156;
    undefined field343_0x157;
    struct C2dObject* _pWindowOrigo;
    struct CGuiGraphics* _Graphics;
    struct CGui* _Gui;
    enum EFormat _Format;
    bool _bFirstOnTop;
    undefined field349_0x175;
    undefined field350_0x176;
    undefined field351_0x177;
    struct CStandardlistboxItem* _pTopObject;
};



struct CUTF32String {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
};


struct CEditBox {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    undefined field112_0x70;
    undefined field113_0x71;
    undefined field114_0x72;
    undefined field115_0x73;
    undefined field116_0x74;
    undefined field117_0x75;
    undefined field118_0x76;
    undefined field119_0x77;
    undefined field120_0x78;
    undefined field121_0x79;
    undefined field122_0x7a;
    undefined field123_0x7b;
    undefined field124_0x7c;
    undefined field125_0x7d;
    undefined field126_0x7e;
    undefined field127_0x7f;
    undefined field128_0x80;
    undefined field129_0x81;
    undefined field130_0x82;
    undefined field131_0x83;
    undefined field132_0x84;
    undefined field133_0x85;
    undefined field134_0x86;
    undefined field135_0x87;
    undefined field136_0x88;
    undefined field137_0x89;
    undefined field138_0x8a;
    undefined field139_0x8b;
    undefined field140_0x8c;
    undefined field141_0x8d;
    undefined field142_0x8e;
    undefined field143_0x8f;
    undefined field144_0x90;
    undefined field145_0x91;
    undefined field146_0x92;
    undefined field147_0x93;
    undefined field148_0x94;
    undefined field149_0x95;
    undefined field150_0x96;
    undefined field151_0x97;
    undefined field152_0x98;
    undefined field153_0x99;
    undefined field154_0x9a;
    undefined field155_0x9b;
    undefined field156_0x9c;
    undefined field157_0x9d;
    undefined field158_0x9e;
    undefined field159_0x9f;
    undefined field160_0xa0;
    undefined field161_0xa1;
    undefined field162_0xa2;
    undefined field163_0xa3;
    undefined field164_0xa4;
    undefined field165_0xa5;
    undefined field166_0xa6;
    undefined field167_0xa7;
    undefined field168_0xa8;
    undefined field169_0xa9;
    undefined field170_0xaa;
    undefined field171_0xab;
    undefined field172_0xac;
    undefined field173_0xad;
    undefined field174_0xae;
    undefined field175_0xaf;
    undefined field176_0xb0;
    undefined field177_0xb1;
    undefined field178_0xb2;
    undefined field179_0xb3;
    undefined field180_0xb4;
    undefined field181_0xb5;
    undefined field182_0xb6;
    undefined field183_0xb7;
    undefined field184_0xb8;
    undefined field185_0xb9;
    undefined field186_0xba;
    undefined field187_0xbb;
    undefined field188_0xbc;
    undefined field189_0xbd;
    undefined field190_0xbe;
    undefined field191_0xbf;
    undefined field192_0xc0;
    undefined field193_0xc1;
    undefined field194_0xc2;
    undefined field195_0xc3;
    undefined field196_0xc4;
    undefined field197_0xc5;
    undefined field198_0xc6;
    undefined field199_0xc7;
    undefined field200_0xc8;
    undefined field201_0xc9;
    undefined field202_0xca;
    undefined field203_0xcb;
    undefined field204_0xcc;
    undefined field205_0xcd;
    undefined field206_0xce;
    undefined field207_0xcf;
    undefined field208_0xd0;
    undefined field209_0xd1;
    undefined field210_0xd2;
    undefined field211_0xd3;
    undefined field212_0xd4;
    undefined field213_0xd5;
    undefined field214_0xd6;
    undefined field215_0xd7;
    undefined field216_0xd8;
    undefined field217_0xd9;
    undefined field218_0xda;
    undefined field219_0xdb;
    undefined field220_0xdc;
    undefined field221_0xdd;
    undefined field222_0xde;
    undefined field223_0xdf;
    undefined field224_0xe0;
    undefined field225_0xe1;
    undefined field226_0xe2;
    undefined field227_0xe3;
    undefined field228_0xe4;
    undefined field229_0xe5;
    undefined field230_0xe6;
    undefined field231_0xe7;
    undefined field232_0xe8;
    undefined field233_0xe9;
    undefined field234_0xea;
    undefined field235_0xeb;
    undefined field236_0xec;
    undefined field237_0xed;
    undefined field238_0xee;
    undefined field239_0xef;
    undefined field240_0xf0;
    undefined field241_0xf1;
    undefined field242_0xf2;
    undefined field243_0xf3;
    undefined field244_0xf4;
    undefined field245_0xf5;
    undefined field246_0xf6;
    undefined field247_0xf7;
    undefined field248_0xf8;
    undefined field249_0xf9;
    undefined field250_0xfa;
    undefined field251_0xfb;
    undefined field252_0xfc;
    undefined field253_0xfd;
    undefined field254_0xfe;
    undefined field255_0xff;
    undefined field256_0x100;
    undefined field257_0x101;
    undefined field258_0x102;
    undefined field259_0x103;
    undefined field260_0x104;
    undefined field261_0x105;
    undefined field262_0x106;
    undefined field263_0x107;
    undefined field264_0x108;
    undefined field265_0x109;
    undefined field266_0x10a;
    undefined field267_0x10b;
    undefined field268_0x10c;
    undefined field269_0x10d;
    undefined field270_0x10e;
    undefined field271_0x10f;
    undefined field272_0x110;
    undefined field273_0x111;
    undefined field274_0x112;
    undefined field275_0x113;
    undefined field276_0x114;
    undefined field277_0x115;
    undefined field278_0x116;
    undefined field279_0x117;
    undefined field280_0x118;
    undefined field281_0x119;
    undefined field282_0x11a;
    undefined field283_0x11b;
    undefined field284_0x11c;
    undefined field285_0x11d;
    undefined field286_0x11e;
    undefined field287_0x11f;
    undefined field288_0x120;
    undefined field289_0x121;
    undefined field290_0x122;
    undefined field291_0x123;
    undefined field292_0x124;
    undefined field293_0x125;
    undefined field294_0x126;
    undefined field295_0x127;
    undefined field296_0x128;
    undefined field297_0x129;
    undefined field298_0x12a;
    undefined field299_0x12b;
    undefined field300_0x12c;
    undefined field301_0x12d;
    undefined field302_0x12e;
    undefined field303_0x12f;
    undefined field304_0x130;
    undefined field305_0x131;
    undefined field306_0x132;
    undefined field307_0x133;
    undefined field308_0x134;
    undefined field309_0x135;
    undefined field310_0x136;
    undefined field311_0x137;
    undefined field312_0x138;
    undefined field313_0x139;
    undefined field314_0x13a;
    undefined field315_0x13b;
    undefined field316_0x13c;
    undefined field317_0x13d;
    undefined field318_0x13e;
    undefined field319_0x13f;
    undefined field320_0x140;
    undefined field321_0x141;
    undefined field322_0x142;
    undefined field323_0x143;
    undefined field324_0x144;
    undefined field325_0x145;
    undefined field326_0x146;
    undefined field327_0x147;
    undefined field328_0x148;
    undefined field329_0x149;
    undefined field330_0x14a;
    undefined field331_0x14b;
    undefined field332_0x14c;
    undefined field333_0x14d;
    undefined field334_0x14e;
    undefined field335_0x14f;
    undefined field336_0x150;
    undefined field337_0x151;
    undefined field338_0x152;
    undefined field339_0x153;
    undefined field340_0x154;
    undefined field341_0x155;
    undefined field342_0x156;
    undefined field343_0x157;
    undefined field344_0x158;
    undefined field345_0x159;
    undefined field346_0x15a;
    undefined field347_0x15b;
    undefined field348_0x15c;
    undefined field349_0x15d;
    undefined field350_0x15e;
    undefined field351_0x15f;
    undefined field352_0x160;
    undefined field353_0x161;
    undefined field354_0x162;
    undefined field355_0x163;
    undefined field356_0x164;
    undefined field357_0x165;
    undefined field358_0x166;
    undefined field359_0x167;
    undefined field360_0x168;
    undefined field361_0x169;
    undefined field362_0x16a;
    undefined field363_0x16b;
    undefined field364_0x16c;
    undefined field365_0x16d;
    undefined field366_0x16e;
    undefined field367_0x16f;
    undefined field368_0x170;
    undefined field369_0x171;
    undefined field370_0x172;
    undefined field371_0x173;
    undefined field372_0x174;
    undefined field373_0x175;
    undefined field374_0x176;
    undefined field375_0x177;
    undefined field376_0x178;
    undefined field377_0x179;
    undefined field378_0x17a;
    undefined field379_0x17b;
    undefined field380_0x17c;
    undefined field381_0x17d;
    undefined field382_0x17e;
    undefined field383_0x17f;
    undefined field384_0x180;
    undefined field385_0x181;
    undefined field386_0x182;
    undefined field387_0x183;
    undefined field388_0x184;
    undefined field389_0x185;
    undefined field390_0x186;
    undefined field391_0x187;
    undefined field392_0x188;
    undefined field393_0x189;
    undefined field394_0x18a;
    undefined field395_0x18b;
    undefined field396_0x18c;
    undefined field397_0x18d;
    undefined field398_0x18e;
    undefined field399_0x18f;
    undefined field400_0x190;
    undefined field401_0x191;
    undefined field402_0x192;
    undefined field403_0x193;
    undefined field404_0x194;
    undefined field405_0x195;
    undefined field406_0x196;
    undefined field407_0x197;
    undefined field408_0x198;
    undefined field409_0x199;
    undefined field410_0x19a;
    undefined field411_0x19b;
    undefined field412_0x19c;
    undefined field413_0x19d;
    undefined field414_0x19e;
    undefined field415_0x19f;
    undefined field416_0x1a0;
    undefined field417_0x1a1;
    undefined field418_0x1a2;
    undefined field419_0x1a3;
    undefined field420_0x1a4;
    undefined field421_0x1a5;
    undefined field422_0x1a6;
    undefined field423_0x1a7;
    undefined field424_0x1a8;
    undefined field425_0x1a9;
    undefined field426_0x1aa;
    undefined field427_0x1ab;
    undefined field428_0x1ac;
    undefined field429_0x1ad;
    undefined field430_0x1ae;
    undefined field431_0x1af;
    undefined field432_0x1b0;
    undefined field433_0x1b1;
    undefined field434_0x1b2;
    undefined field435_0x1b3;
    undefined field436_0x1b4;
    undefined field437_0x1b5;
    undefined field438_0x1b6;
    undefined field439_0x1b7;
    undefined field440_0x1b8;
    undefined field441_0x1b9;
    undefined field442_0x1ba;
    undefined field443_0x1bb;
    undefined field444_0x1bc;
    undefined field445_0x1bd;
    undefined field446_0x1be;
    undefined field447_0x1bf;
    undefined field448_0x1c0;
    undefined field449_0x1c1;
    undefined field450_0x1c2;
    undefined field451_0x1c3;
    undefined field452_0x1c4;
    undefined field453_0x1c5;
    undefined field454_0x1c6;
    undefined field455_0x1c7;
    undefined field456_0x1c8;
    undefined field457_0x1c9;
    undefined field458_0x1ca;
    undefined field459_0x1cb;
    undefined field460_0x1cc;
    undefined field461_0x1cd;
    undefined field462_0x1ce;
    undefined field463_0x1cf;
    struct CGuiGraphics* _graphics;
    struct CGraphicalObject* _pText;
    struct CGraphicalObject* _pCursor;
    struct CCorneredTileSprite* _pTextSelectionBox;
    struct CString _fontName;
    struct CString _backGroundName;
    class CVector2<unsigned int> _borderSize;
    class CVector2<int> _originalPosition;
    class CVector2<int> _position;
    class CVector2<int> _Size;
    bool _bHasFocus;
    bool _bDisabled;
    bool _bShowIME;
    bool _bPassword;
    bool _bWrapText;
    undefined field479_0x255;
    undefined field480_0x256;
    undefined field481_0x257;
    int _nRowOffset;
    undefined field483_0x25c;
    undefined field484_0x25d;
    undefined field485_0x25e;
    undefined field486_0x25f;
    struct CClock* _pClock;
    enum EGuiOrientation _Orientation;
    class CVector2<int> _WindowSize;
    class CVector2<int> _CursorOffset;
    undefined field491_0x27c;
    undefined field492_0x27d;
    undefined field493_0x27e;
    undefined field494_0x27f;
    struct CIME* _pIME;
    struct C2dObject* _pWindowOrigo;
    struct CUTF32String _Exceptions;
    bool _bStayHidden;
    bool _bIgnoreTabNavigation;
    bool _bAllowMultiLine;
    bool _bSelected;
    undefined field502_0x2b4;
    undefined field503_0x2b5;
    undefined field504_0x2b6;
    undefined field505_0x2b7;
    struct CButtonDrag* _pOverlay;
    struct CString _Empty;
    bool _bUseInstantTextBox;
    undefined field509_0x2e1;
    undefined field510_0x2e2;
    undefined field511_0x2e3;
    undefined field512_0x2e4;
    undefined field513_0x2e5;
    undefined field514_0x2e6;
    undefined field515_0x2e7;
};


struct CCheckBox {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    undefined field112_0x70;
    undefined field113_0x71;
    undefined field114_0x72;
    undefined field115_0x73;
    undefined field116_0x74;
    undefined field117_0x75;
    undefined field118_0x76;
    undefined field119_0x77;
    undefined field120_0x78;
    undefined field121_0x79;
    undefined field122_0x7a;
    undefined field123_0x7b;
    undefined field124_0x7c;
    undefined field125_0x7d;
    undefined field126_0x7e;
    undefined field127_0x7f;
    undefined field128_0x80;
    undefined field129_0x81;
    undefined field130_0x82;
    undefined field131_0x83;
    undefined field132_0x84;
    undefined field133_0x85;
    undefined field134_0x86;
    undefined field135_0x87;
    undefined field136_0x88;
    undefined field137_0x89;
    undefined field138_0x8a;
    undefined field139_0x8b;
    undefined field140_0x8c;
    undefined field141_0x8d;
    undefined field142_0x8e;
    undefined field143_0x8f;
    undefined field144_0x90;
    undefined field145_0x91;
    undefined field146_0x92;
    undefined field147_0x93;
    undefined field148_0x94;
    undefined field149_0x95;
    undefined field150_0x96;
    undefined field151_0x97;
    undefined field152_0x98;
    undefined field153_0x99;
    undefined field154_0x9a;
    undefined field155_0x9b;
    undefined field156_0x9c;
    undefined field157_0x9d;
    undefined field158_0x9e;
    undefined field159_0x9f;
    undefined field160_0xa0;
    undefined field161_0xa1;
    undefined field162_0xa2;
    undefined field163_0xa3;
    undefined field164_0xa4;
    undefined field165_0xa5;
    undefined field166_0xa6;
    undefined field167_0xa7;
    undefined field168_0xa8;
    undefined field169_0xa9;
    undefined field170_0xaa;
    undefined field171_0xab;
    undefined field172_0xac;
    undefined field173_0xad;
    undefined field174_0xae;
    undefined field175_0xaf;
    undefined field176_0xb0;
    undefined field177_0xb1;
    undefined field178_0xb2;
    undefined field179_0xb3;
    undefined field180_0xb4;
    undefined field181_0xb5;
    undefined field182_0xb6;
    undefined field183_0xb7;
    undefined field184_0xb8;
    undefined field185_0xb9;
    undefined field186_0xba;
    undefined field187_0xbb;
    undefined field188_0xbc;
    undefined field189_0xbd;
    undefined field190_0xbe;
    undefined field191_0xbf;
    undefined field192_0xc0;
    undefined field193_0xc1;
    undefined field194_0xc2;
    undefined field195_0xc3;
    undefined field196_0xc4;
    undefined field197_0xc5;
    undefined field198_0xc6;
    undefined field199_0xc7;
    undefined field200_0xc8;
    undefined field201_0xc9;
    undefined field202_0xca;
    undefined field203_0xcb;
    undefined field204_0xcc;
    undefined field205_0xcd;
    undefined field206_0xce;
    undefined field207_0xcf;
    undefined field208_0xd0;
    undefined field209_0xd1;
    undefined field210_0xd2;
    undefined field211_0xd3;
    undefined field212_0xd4;
    undefined field213_0xd5;
    undefined field214_0xd6;
    undefined field215_0xd7;
    undefined field216_0xd8;
    undefined field217_0xd9;
    undefined field218_0xda;
    undefined field219_0xdb;
    undefined field220_0xdc;
    undefined field221_0xdd;
    undefined field222_0xde;
    undefined field223_0xdf;
    enum checkBoxState _state;
    undefined field225_0xe4;
    undefined field226_0xe5;
    undefined field227_0xe6;
    undefined field228_0xe7;
    struct CButtonType* _pButtonType;
    struct CGraphicalObject* _pSprite;
    struct CGuiGraphics* _graphics;
    class CVector2<int> _position;
    class CVector2<int> _OriginalPosition;
    class CPoint<long> _oldMousePos;
    struct CClock* _pClock;
    struct CTextBox* _pToolTip;
    struct CString _tooltip;
    struct CString _tooltipText;
    struct CString _delayedTooltipText;
    bool _bIsRadioButton;
    bool _bWasRadioClicked;
    undefined field242_0x18a;
    undefined field243_0x18b;
    struct CKeyEvent _Shortcut;
    undefined field245_0x19c;
    undefined field246_0x19d;
    undefined field247_0x19e;
    undefined field248_0x19f;
    struct CString _ButtonText;
    struct CFont* _pFont;
    enum EGuiOrientation _Orientation;
    class CVector2<int> _WindowSize;
    undefined field253_0x1d4;
    undefined field254_0x1d5;
    undefined field255_0x1d6;
    undefined field256_0x1d7;
    struct C2dObject* _WindowOrigo;
    bool _bEventReceived;
    bool _bAcceptClicks;
    bool _bIsEnabled;
    undefined field261_0x1e3;
    undefined field262_0x1e4;
    undefined field263_0x1e5;
    undefined field264_0x1e6;
    undefined field265_0x1e7;
    struct SoundEffectAUDIO* _OverSound;
    struct SoundEffectAUDIO* _UncheckSound;
    struct SoundEffectAUDIO* _CheckSound;
    bool _bStayHidden;
    bool _bGamepadSelected;
    bool _bOnOver;
    undefined field272_0x203;
    undefined field273_0x204;
    undefined field274_0x205;
    undefined field275_0x206;
    undefined field276_0x207;
};

struct TListboxItem {
    undefined field0_0x0;
    undefined field1_0x1;
    undefined field2_0x2;
    undefined field3_0x3;
    undefined field4_0x4;
    undefined field5_0x5;
    undefined field6_0x6;
    undefined field7_0x7;
};

struct CSmoothListbox {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    undefined field112_0x70;
    undefined field113_0x71;
    undefined field114_0x72;
    undefined field115_0x73;
    undefined field116_0x74;
    undefined field117_0x75;
    undefined field118_0x76;
    undefined field119_0x77;
    undefined field120_0x78;
    undefined field121_0x79;
    undefined field122_0x7a;
    undefined field123_0x7b;
    undefined field124_0x7c;
    undefined field125_0x7d;
    undefined field126_0x7e;
    undefined field127_0x7f;
    undefined field128_0x80;
    undefined field129_0x81;
    undefined field130_0x82;
    undefined field131_0x83;
    undefined field132_0x84;
    undefined field133_0x85;
    undefined field134_0x86;
    undefined field135_0x87;
    undefined field136_0x88;
    undefined field137_0x89;
    undefined field138_0x8a;
    undefined field139_0x8b;
    undefined field140_0x8c;
    undefined field141_0x8d;
    undefined field142_0x8e;
    undefined field143_0x8f;
    undefined field144_0x90;
    undefined field145_0x91;
    undefined field146_0x92;
    undefined field147_0x93;
    undefined field148_0x94;
    undefined field149_0x95;
    undefined field150_0x96;
    undefined field151_0x97;
    undefined field152_0x98;
    undefined field153_0x99;
    undefined field154_0x9a;
    undefined field155_0x9b;
    undefined field156_0x9c;
    undefined field157_0x9d;
    undefined field158_0x9e;
    undefined field159_0x9f;
    undefined field160_0xa0;
    undefined field161_0xa1;
    undefined field162_0xa2;
    undefined field163_0xa3;
    undefined field164_0xa4;
    undefined field165_0xa5;
    undefined field166_0xa6;
    undefined field167_0xa7;
    undefined field168_0xa8;
    undefined field169_0xa9;
    undefined field170_0xaa;
    undefined field171_0xab;
    undefined field172_0xac;
    undefined field173_0xad;
    undefined field174_0xae;
    undefined field175_0xaf;
    undefined field176_0xb0;
    undefined field177_0xb1;
    undefined field178_0xb2;
    undefined field179_0xb3;
    undefined field180_0xb4;
    undefined field181_0xb5;
    undefined field182_0xb6;
    undefined field183_0xb7;
    undefined field184_0xb8;
    undefined field185_0xb9;
    undefined field186_0xba;
    undefined field187_0xbb;
    undefined field188_0xbc;
    undefined field189_0xbd;
    undefined field190_0xbe;
    undefined field191_0xbf;
    undefined field192_0xc0;
    undefined field193_0xc1;
    undefined field194_0xc2;
    undefined field195_0xc3;
    undefined field196_0xc4;
    undefined field197_0xc5;
    undefined field198_0xc6;
    undefined field199_0xc7;
    undefined field200_0xc8;
    undefined field201_0xc9;
    undefined field202_0xca;
    undefined field203_0xcb;
    undefined field204_0xcc;
    undefined field205_0xcd;
    undefined field206_0xce;
    undefined field207_0xcf;
    undefined field208_0xd0;
    undefined field209_0xd1;
    undefined field210_0xd2;
    undefined field211_0xd3;
    undefined field212_0xd4;
    undefined field213_0xd5;
    undefined field214_0xd6;
    undefined field215_0xd7;
    undefined field216_0xd8;
    undefined field217_0xd9;
    undefined field218_0xda;
    undefined field219_0xdb;
    undefined field220_0xdc;
    undefined field221_0xdd;
    undefined field222_0xde;
    undefined field223_0xdf;
    undefined field224_0xe0;
    undefined field225_0xe1;
    undefined field226_0xe2;
    undefined field227_0xe3;
    undefined field228_0xe4;
    undefined field229_0xe5;
    undefined field230_0xe6;
    undefined field231_0xe7;
    undefined field232_0xe8;
    undefined field233_0xe9;
    undefined field234_0xea;
    undefined field235_0xeb;
    undefined field236_0xec;
    undefined field237_0xed;
    undefined field238_0xee;
    undefined field239_0xef;
    undefined field240_0xf0;
    undefined field241_0xf1;
    undefined field242_0xf2;
    undefined field243_0xf3;
    undefined field244_0xf4;
    undefined field245_0xf5;
    undefined field246_0xf6;
    undefined field247_0xf7;
    undefined field248_0xf8;
    undefined field249_0xf9;
    undefined field250_0xfa;
    undefined field251_0xfb;
    undefined field252_0xfc;
    undefined field253_0xfd;
    undefined field254_0xfe;
    undefined field255_0xff;
    undefined field256_0x100;
    undefined field257_0x101;
    undefined field258_0x102;
    undefined field259_0x103;
    undefined field260_0x104;
    undefined field261_0x105;
    undefined field262_0x106;
    undefined field263_0x107;
    undefined field264_0x108;
    undefined field265_0x109;
    undefined field266_0x10a;
    undefined field267_0x10b;
    undefined field268_0x10c;
    undefined field269_0x10d;
    undefined field270_0x10e;
    undefined field271_0x10f;
    undefined field272_0x110;
    undefined field273_0x111;
    undefined field274_0x112;
    undefined field275_0x113;
    undefined field276_0x114;
    undefined field277_0x115;
    undefined field278_0x116;
    undefined field279_0x117;
    undefined field280_0x118;
    undefined field281_0x119;
    undefined field282_0x11a;
    undefined field283_0x11b;
    undefined field284_0x11c;
    undefined field285_0x11d;
    undefined field286_0x11e;
    undefined field287_0x11f;
    undefined field288_0x120;
    undefined field289_0x121;
    undefined field290_0x122;
    undefined field291_0x123;
    undefined field292_0x124;
    undefined field293_0x125;
    undefined field294_0x126;
    undefined field295_0x127;
    undefined field296_0x128;
    undefined field297_0x129;
    undefined field298_0x12a;
    undefined field299_0x12b;
    undefined field300_0x12c;
    undefined field301_0x12d;
    undefined field302_0x12e;
    undefined field303_0x12f;
    undefined field304_0x130;
    undefined field305_0x131;
    undefined field306_0x132;
    undefined field307_0x133;
    undefined field308_0x134;
    undefined field309_0x135;
    undefined field310_0x136;
    undefined field311_0x137;
    undefined field312_0x138;
    undefined field313_0x139;
    undefined field314_0x13a;
    undefined field315_0x13b;
    undefined field316_0x13c;
    undefined field317_0x13d;
    undefined field318_0x13e;
    undefined field319_0x13f;
    undefined field320_0x140;
    undefined field321_0x141;
    undefined field322_0x142;
    undefined field323_0x143;
    undefined field324_0x144;
    undefined field325_0x145;
    undefined field326_0x146;
    undefined field327_0x147;
    undefined field328_0x148;
    undefined field329_0x149;
    undefined field330_0x14a;
    undefined field331_0x14b;
    undefined field332_0x14c;
    undefined field333_0x14d;
    undefined field334_0x14e;
    undefined field335_0x14f;
    undefined field336_0x150;
    undefined field337_0x151;
    undefined field338_0x152;
    undefined field339_0x153;
    undefined field340_0x154;
    undefined field341_0x155;
    undefined field342_0x156;
    undefined field343_0x157;
    undefined field344_0x158;
    undefined field345_0x159;
    undefined field346_0x15a;
    undefined field347_0x15b;
    undefined field348_0x15c;
    undefined field349_0x15d;
    undefined field350_0x15e;
    undefined field351_0x15f;
    undefined field352_0x160;
    undefined field353_0x161;
    undefined field354_0x162;
    undefined field355_0x163;
    undefined field356_0x164;
    undefined field357_0x165;
    undefined field358_0x166;
    undefined field359_0x167;
    struct CScrollbarObserverGlue<CSmoothListbox> _ScrollbarValueChanged;
    class CList<TListboxItem*> _HiddenItemsList;
    struct SScissorRectangle _ScissorRect;
    int _nMaxNumberOfElements;
    undefined field364_0x1f4;
    undefined field365_0x1f5;
    undefined field366_0x1f6;
    undefined field367_0x1f7;
    struct CFixedPoint _vStep;
    struct CListboxType* _pListboxType;
    struct TListboxItem* _pItemAtScroll;
    struct CGui* _Gui;
    struct CGuiGraphics* _Graphics;
    struct C2dObject* _WindowOrigo;
    struct CGraphicalObject* _pBackground;
    struct CScrollbar* _pScrollbar;
    enum EGuiOrientation _Orientation;
    undefined field377_0x23c;
    undefined field378_0x23d;
    undefined field379_0x23e;
    undefined field380_0x23f;
    struct CString _Background;
    class CVector2<int> _WindowSize;
    class CVector2<int> _Position;
    class CVector2<int> _Size;
    class CVector2<int> _ActualPosition;
    float _vPriority;
    float _vSluggishScrollbarValue;
    int _nDragFingerId;
    int _nBorderSize;
    short _nSpacing;
    undefined field391_0x292;
    undefined field392_0x293;
    enum EActionNavigationMode _ActionNavigationMode;
    bool _bStayHidden;
    bool _bHorizontal;
    bool _bOptimize;
    bool _bHideScrollbar;
    bool _bAcceptClicks;
    bool _bAutohideScrollbar;
    undefined field400_0x29e;
    undefined field401_0x29f;
};


struct C2dPositionObject {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    undefined field112_0x70;
    undefined field113_0x71;
    undefined field114_0x72;
    undefined field115_0x73;
    undefined field116_0x74;
    undefined field117_0x75;
    undefined field118_0x76;
    undefined field119_0x77;
    undefined field120_0x78;
    undefined field121_0x79;
    undefined field122_0x7a;
    undefined field123_0x7b;
    undefined field124_0x7c;
    undefined field125_0x7d;
    undefined field126_0x7e;
    undefined field127_0x7f;
    undefined field128_0x80;
    undefined field129_0x81;
    undefined field130_0x82;
    undefined field131_0x83;
    undefined field132_0x84;
    undefined field133_0x85;
    undefined field134_0x86;
    undefined field135_0x87;
    undefined field136_0x88;
    undefined field137_0x89;
    undefined field138_0x8a;
    undefined field139_0x8b;
    undefined field140_0x8c;
    undefined field141_0x8d;
    undefined field142_0x8e;
    undefined field143_0x8f;
    undefined field144_0x90;
    undefined field145_0x91;
    undefined field146_0x92;
    undefined field147_0x93;
    undefined field148_0x94;
    undefined field149_0x95;
    undefined field150_0x96;
    undefined field151_0x97;
    undefined field152_0x98;
    undefined field153_0x99;
    undefined field154_0x9a;
    undefined field155_0x9b;
    undefined field156_0x9c;
    undefined field157_0x9d;
    undefined field158_0x9e;
    undefined field159_0x9f;
    undefined field160_0xa0;
    undefined field161_0xa1;
    undefined field162_0xa2;
    undefined field163_0xa3;
    undefined field164_0xa4;
    undefined field165_0xa5;
    undefined field166_0xa6;
    undefined field167_0xa7;
    undefined field168_0xa8;
    undefined field169_0xa9;
    undefined field170_0xaa;
    undefined field171_0xab;
    undefined field172_0xac;
    undefined field173_0xad;
    undefined field174_0xae;
    undefined field175_0xaf;
    undefined field176_0xb0;
    undefined field177_0xb1;
    undefined field178_0xb2;
    undefined field179_0xb3;
    undefined field180_0xb4;
    undefined field181_0xb5;
    undefined field182_0xb6;
    undefined field183_0xb7;
    undefined field184_0xb8;
    undefined field185_0xb9;
    undefined field186_0xba;
    undefined field187_0xbb;
    undefined field188_0xbc;
    undefined field189_0xbd;
    undefined field190_0xbe;
    undefined field191_0xbf;
    undefined field192_0xc0;
    undefined field193_0xc1;
    undefined field194_0xc2;
    undefined field195_0xc3;
    undefined field196_0xc4;
    undefined field197_0xc5;
    undefined field198_0xc6;
    undefined field199_0xc7;
    undefined field200_0xc8;
    undefined field201_0xc9;
    undefined field202_0xca;
    undefined field203_0xcb;
    undefined field204_0xcc;
    undefined field205_0xcd;
    undefined field206_0xce;
    undefined field207_0xcf;
    undefined field208_0xd0;
    undefined field209_0xd1;
    undefined field210_0xd2;
    undefined field211_0xd3;
    undefined field212_0xd4;
    undefined field213_0xd5;
    undefined field214_0xd6;
    undefined field215_0xd7;
    undefined field216_0xd8;
    undefined field217_0xd9;
    undefined field218_0xda;
    undefined field219_0xdb;
    undefined field220_0xdc;
    undefined field221_0xdd;
    undefined field222_0xde;
    undefined field223_0xdf;
    undefined field224_0xe0;
    undefined field225_0xe1;
    undefined field226_0xe2;
    undefined field227_0xe3;
    undefined field228_0xe4;
    undefined field229_0xe5;
    undefined field230_0xe6;
    undefined field231_0xe7;
    undefined field232_0xe8;
    undefined field233_0xe9;
    undefined field234_0xea;
    undefined field235_0xeb;
    undefined field236_0xec;
    undefined field237_0xed;
    undefined field238_0xee;
    undefined field239_0xef;
    undefined field240_0xf0;
    undefined field241_0xf1;
    undefined field242_0xf2;
    undefined field243_0xf3;
    undefined field244_0xf4;
    undefined field245_0xf5;
    undefined field246_0xf6;
    undefined field247_0xf7;
    undefined field248_0xf8;
    undefined field249_0xf9;
    undefined field250_0xfa;
    undefined field251_0xfb;
    undefined field252_0xfc;
    undefined field253_0xfd;
    undefined field254_0xfe;
    undefined field255_0xff;
};

struct CSpinner {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    undefined field112_0x70;
    undefined field113_0x71;
    undefined field114_0x72;
    undefined field115_0x73;
    undefined field116_0x74;
    undefined field117_0x75;
    undefined field118_0x76;
    undefined field119_0x77;
    undefined field120_0x78;
    undefined field121_0x79;
    undefined field122_0x7a;
    undefined field123_0x7b;
    undefined field124_0x7c;
    undefined field125_0x7d;
    undefined field126_0x7e;
    undefined field127_0x7f;
    undefined field128_0x80;
    undefined field129_0x81;
    undefined field130_0x82;
    undefined field131_0x83;
    undefined field132_0x84;
    undefined field133_0x85;
    undefined field134_0x86;
    undefined field135_0x87;
    undefined field136_0x88;
    undefined field137_0x89;
    undefined field138_0x8a;
    undefined field139_0x8b;
    undefined field140_0x8c;
    undefined field141_0x8d;
    undefined field142_0x8e;
    undefined field143_0x8f;
    undefined field144_0x90;
    undefined field145_0x91;
    undefined field146_0x92;
    undefined field147_0x93;
    undefined field148_0x94;
    undefined field149_0x95;
    undefined field150_0x96;
    undefined field151_0x97;
    undefined field152_0x98;
    undefined field153_0x99;
    undefined field154_0x9a;
    undefined field155_0x9b;
    undefined field156_0x9c;
    undefined field157_0x9d;
    undefined field158_0x9e;
    undefined field159_0x9f;
    undefined field160_0xa0;
    undefined field161_0xa1;
    undefined field162_0xa2;
    undefined field163_0xa3;
    undefined field164_0xa4;
    undefined field165_0xa5;
    undefined field166_0xa6;
    undefined field167_0xa7;
    undefined field168_0xa8;
    undefined field169_0xa9;
    undefined field170_0xaa;
    undefined field171_0xab;
    undefined field172_0xac;
    undefined field173_0xad;
    undefined field174_0xae;
    undefined field175_0xaf;
    undefined field176_0xb0;
    undefined field177_0xb1;
    undefined field178_0xb2;
    undefined field179_0xb3;
    undefined field180_0xb4;
    undefined field181_0xb5;
    undefined field182_0xb6;
    undefined field183_0xb7;
    undefined field184_0xb8;
    undefined field185_0xb9;
    undefined field186_0xba;
    undefined field187_0xbb;
    undefined field188_0xbc;
    undefined field189_0xbd;
    undefined field190_0xbe;
    undefined field191_0xbf;
    undefined field192_0xc0;
    undefined field193_0xc1;
    undefined field194_0xc2;
    undefined field195_0xc3;
    undefined field196_0xc4;
    undefined field197_0xc5;
    undefined field198_0xc6;
    undefined field199_0xc7;
    undefined field200_0xc8;
    undefined field201_0xc9;
    undefined field202_0xca;
    undefined field203_0xcb;
    undefined field204_0xcc;
    undefined field205_0xcd;
    undefined field206_0xce;
    undefined field207_0xcf;
    undefined field208_0xd0;
    undefined field209_0xd1;
    undefined field210_0xd2;
    undefined field211_0xd3;
    undefined field212_0xd4;
    undefined field213_0xd5;
    undefined field214_0xd6;
    undefined field215_0xd7;
    undefined field216_0xd8;
    undefined field217_0xd9;
    undefined field218_0xda;
    undefined field219_0xdb;
    undefined field220_0xdc;
    undefined field221_0xdd;
    undefined field222_0xde;
    undefined field223_0xdf;
    undefined field224_0xe0;
    undefined field225_0xe1;
    undefined field226_0xe2;
    undefined field227_0xe3;
    undefined field228_0xe4;
    undefined field229_0xe5;
    undefined field230_0xe6;
    undefined field231_0xe7;
    struct CGuiGraphics* _graphics;
    struct CSpinnerType* _creator;
    class CVector2<float> _position;
    class CVector2<float> _oldPosition;
    class CVector2<int> _decButtonPosition;
    class CVector2<int> _incButtonPosition;
    struct CButtonStandard* _decButton;
    struct CButtonObserverGlue<CSpinner> _IncClicked;
    struct CButtonStandard* _incButton;
    struct CButtonObserverGlue<CSpinner> _DecClicked;
    int _nValue;
    int _nMaxValue;
    int _nShiftSpeed;
    uint _height;
    uint _width;
    class CVector2<unsigned short> _tileSize;
    float _delayTime;
    float _lastTimeDown;
    ushort _horizontal;
    undefined field251_0x2ea;
    undefined field252_0x2eb;
    class CVector2<int> _size;
    int _nConstrainedValueIndex;
    int counter;
    bool _bLockable;
    bool _bDragable;
    bool _bPermaLock;
    bool _bInvertStep;
    struct C2dPositionObject _SpinnerOrigo;
    bool _bSetOrientation;
    undefined field262_0x401;
    undefined field263_0x402;
    undefined field264_0x403;
    undefined field265_0x404;
    undefined field266_0x405;
    undefined field267_0x406;
    undefined field268_0x407;
    struct CFixedPoint _StartValue;
    bool _bIsEnabled;
    bool _bSelected;
    bool _bGamepadActive;
    undefined field273_0x413;
    undefined field274_0x414;
    undefined field275_0x415;
    undefined field276_0x416;
    undefined field277_0x417;
    struct CButtonDrag* _pOverlay;
    struct CString _Empty;
    struct SScissorRectangle _ScissorRect;
    struct SScissorRectangle* _pParentScissor;
};


struct CStandardlistbox {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    undefined field112_0x70;
    undefined field113_0x71;
    undefined field114_0x72;
    undefined field115_0x73;
    undefined field116_0x74;
    undefined field117_0x75;
    undefined field118_0x76;
    undefined field119_0x77;
    undefined field120_0x78;
    undefined field121_0x79;
    undefined field122_0x7a;
    undefined field123_0x7b;
    undefined field124_0x7c;
    undefined field125_0x7d;
    undefined field126_0x7e;
    undefined field127_0x7f;
    undefined field128_0x80;
    undefined field129_0x81;
    undefined field130_0x82;
    undefined field131_0x83;
    undefined field132_0x84;
    undefined field133_0x85;
    undefined field134_0x86;
    undefined field135_0x87;
    undefined field136_0x88;
    undefined field137_0x89;
    undefined field138_0x8a;
    undefined field139_0x8b;
    undefined field140_0x8c;
    undefined field141_0x8d;
    undefined field142_0x8e;
    undefined field143_0x8f;
    undefined field144_0x90;
    undefined field145_0x91;
    undefined field146_0x92;
    undefined field147_0x93;
    undefined field148_0x94;
    undefined field149_0x95;
    undefined field150_0x96;
    undefined field151_0x97;
    undefined field152_0x98;
    undefined field153_0x99;
    undefined field154_0x9a;
    undefined field155_0x9b;
    undefined field156_0x9c;
    undefined field157_0x9d;
    undefined field158_0x9e;
    undefined field159_0x9f;
    undefined field160_0xa0;
    undefined field161_0xa1;
    undefined field162_0xa2;
    undefined field163_0xa3;
    undefined field164_0xa4;
    undefined field165_0xa5;
    undefined field166_0xa6;
    undefined field167_0xa7;
    undefined field168_0xa8;
    undefined field169_0xa9;
    undefined field170_0xaa;
    undefined field171_0xab;
    undefined field172_0xac;
    undefined field173_0xad;
    undefined field174_0xae;
    undefined field175_0xaf;
    undefined field176_0xb0;
    undefined field177_0xb1;
    undefined field178_0xb2;
    undefined field179_0xb3;
    undefined field180_0xb4;
    undefined field181_0xb5;
    undefined field182_0xb6;
    undefined field183_0xb7;
    undefined field184_0xb8;
    undefined field185_0xb9;
    undefined field186_0xba;
    undefined field187_0xbb;
    undefined field188_0xbc;
    undefined field189_0xbd;
    undefined field190_0xbe;
    undefined field191_0xbf;
    undefined field192_0xc0;
    undefined field193_0xc1;
    undefined field194_0xc2;
    undefined field195_0xc3;
    undefined field196_0xc4;
    undefined field197_0xc5;
    undefined field198_0xc6;
    undefined field199_0xc7;
    undefined field200_0xc8;
    undefined field201_0xc9;
    undefined field202_0xca;
    undefined field203_0xcb;
    undefined field204_0xcc;
    undefined field205_0xcd;
    undefined field206_0xce;
    undefined field207_0xcf;
    undefined field208_0xd0;
    undefined field209_0xd1;
    undefined field210_0xd2;
    undefined field211_0xd3;
    undefined field212_0xd4;
    undefined field213_0xd5;
    undefined field214_0xd6;
    undefined field215_0xd7;
    undefined field216_0xd8;
    undefined field217_0xd9;
    undefined field218_0xda;
    undefined field219_0xdb;
    undefined field220_0xdc;
    undefined field221_0xdd;
    undefined field222_0xde;
    undefined field223_0xdf;
    undefined field224_0xe0;
    undefined field225_0xe1;
    undefined field226_0xe2;
    undefined field227_0xe3;
    undefined field228_0xe4;
    undefined field229_0xe5;
    undefined field230_0xe6;
    undefined field231_0xe7;
    undefined field232_0xe8;
    undefined field233_0xe9;
    undefined field234_0xea;
    undefined field235_0xeb;
    undefined field236_0xec;
    undefined field237_0xed;
    undefined field238_0xee;
    undefined field239_0xef;
    undefined field240_0xf0;
    undefined field241_0xf1;
    undefined field242_0xf2;
    undefined field243_0xf3;
    undefined field244_0xf4;
    undefined field245_0xf5;
    undefined field246_0xf6;
    undefined field247_0xf7;
    undefined field248_0xf8;
    undefined field249_0xf9;
    undefined field250_0xfa;
    undefined field251_0xfb;
    undefined field252_0xfc;
    undefined field253_0xfd;
    undefined field254_0xfe;
    undefined field255_0xff;
    undefined field256_0x100;
    undefined field257_0x101;
    undefined field258_0x102;
    undefined field259_0x103;
    undefined field260_0x104;
    undefined field261_0x105;
    undefined field262_0x106;
    undefined field263_0x107;
    undefined field264_0x108;
    undefined field265_0x109;
    undefined field266_0x10a;
    undefined field267_0x10b;
    undefined field268_0x10c;
    undefined field269_0x10d;
    undefined field270_0x10e;
    undefined field271_0x10f;
    undefined field272_0x110;
    undefined field273_0x111;
    undefined field274_0x112;
    undefined field275_0x113;
    undefined field276_0x114;
    undefined field277_0x115;
    undefined field278_0x116;
    undefined field279_0x117;
    undefined field280_0x118;
    undefined field281_0x119;
    undefined field282_0x11a;
    undefined field283_0x11b;
    undefined field284_0x11c;
    undefined field285_0x11d;
    undefined field286_0x11e;
    undefined field287_0x11f;
    undefined field288_0x120;
    undefined field289_0x121;
    undefined field290_0x122;
    undefined field291_0x123;
    undefined field292_0x124;
    undefined field293_0x125;
    undefined field294_0x126;
    undefined field295_0x127;
    undefined field296_0x128;
    undefined field297_0x129;
    undefined field298_0x12a;
    undefined field299_0x12b;
    undefined field300_0x12c;
    undefined field301_0x12d;
    undefined field302_0x12e;
    undefined field303_0x12f;
    undefined field304_0x130;
    undefined field305_0x131;
    undefined field306_0x132;
    undefined field307_0x133;
    undefined field308_0x134;
    undefined field309_0x135;
    undefined field310_0x136;
    undefined field311_0x137;
    undefined field312_0x138;
    undefined field313_0x139;
    undefined field314_0x13a;
    undefined field315_0x13b;
    undefined field316_0x13c;
    undefined field317_0x13d;
    undefined field318_0x13e;
    undefined field319_0x13f;
    undefined field320_0x140;
    undefined field321_0x141;
    undefined field322_0x142;
    undefined field323_0x143;
    undefined field324_0x144;
    undefined field325_0x145;
    undefined field326_0x146;
    undefined field327_0x147;
    undefined field328_0x148;
    undefined field329_0x149;
    undefined field330_0x14a;
    undefined field331_0x14b;
    undefined field332_0x14c;
    undefined field333_0x14d;
    undefined field334_0x14e;
    undefined field335_0x14f;
    undefined field336_0x150;
    undefined field337_0x151;
    undefined field338_0x152;
    undefined field339_0x153;
    undefined field340_0x154;
    undefined field341_0x155;
    undefined field342_0x156;
    undefined field343_0x157;
    undefined field344_0x158;
    undefined field345_0x159;
    undefined field346_0x15a;
    undefined field347_0x15b;
    undefined field348_0x15c;
    undefined field349_0x15d;
    undefined field350_0x15e;
    undefined field351_0x15f;
    undefined field352_0x160;
    undefined field353_0x161;
    undefined field354_0x162;
    undefined field355_0x163;
    undefined field356_0x164;
    undefined field357_0x165;
    undefined field358_0x166;
    undefined field359_0x167;
    undefined field360_0x168;
    undefined field361_0x169;
    undefined field362_0x16a;
    undefined field363_0x16b;
    undefined field364_0x16c;
    undefined field365_0x16d;
    undefined field366_0x16e;
    undefined field367_0x16f;
    undefined field368_0x170;
    undefined field369_0x171;
    undefined field370_0x172;
    undefined field371_0x173;
    undefined field372_0x174;
    undefined field373_0x175;
    undefined field374_0x176;
    undefined field375_0x177;
    undefined field376_0x178;
    undefined field377_0x179;
    undefined field378_0x17a;
    undefined field379_0x17b;
    undefined field380_0x17c;
    undefined field381_0x17d;
    undefined field382_0x17e;
    undefined field383_0x17f;
    undefined field384_0x180;
    undefined field385_0x181;
    undefined field386_0x182;
    undefined field387_0x183;
    undefined field388_0x184;
    undefined field389_0x185;
    undefined field390_0x186;
    undefined field391_0x187;
    undefined field392_0x188;
    undefined field393_0x189;
    undefined field394_0x18a;
    undefined field395_0x18b;
    undefined field396_0x18c;
    undefined field397_0x18d;
    undefined field398_0x18e;
    undefined field399_0x18f;
    undefined field400_0x190;
    undefined field401_0x191;
    undefined field402_0x192;
    undefined field403_0x193;
    undefined field404_0x194;
    undefined field405_0x195;
    undefined field406_0x196;
    undefined field407_0x197;
    undefined field408_0x198;
    undefined field409_0x199;
    undefined field410_0x19a;
    undefined field411_0x19b;
    undefined field412_0x19c;
    undefined field413_0x19d;
    undefined field414_0x19e;
    undefined field415_0x19f;
    undefined field416_0x1a0;
    undefined field417_0x1a1;
    undefined field418_0x1a2;
    undefined field419_0x1a3;
    undefined field420_0x1a4;
    undefined field421_0x1a5;
    undefined field422_0x1a6;
    undefined field423_0x1a7;
    undefined field424_0x1a8;
    undefined field425_0x1a9;
    undefined field426_0x1aa;
    undefined field427_0x1ab;
    undefined field428_0x1ac;
    undefined field429_0x1ad;
    undefined field430_0x1ae;
    undefined field431_0x1af;
    undefined field432_0x1b0;
    undefined field433_0x1b1;
    undefined field434_0x1b2;
    undefined field435_0x1b3;
    undefined field436_0x1b4;
    undefined field437_0x1b5;
    undefined field438_0x1b6;
    undefined field439_0x1b7;
    undefined field440_0x1b8;
    undefined field441_0x1b9;
    undefined field442_0x1ba;
    undefined field443_0x1bb;
    undefined field444_0x1bc;
    undefined field445_0x1bd;
    undefined field446_0x1be;
    undefined field447_0x1bf;
    undefined field448_0x1c0;
    undefined field449_0x1c1;
    undefined field450_0x1c2;
    undefined field451_0x1c3;
    undefined field452_0x1c4;
    undefined field453_0x1c5;
    undefined field454_0x1c6;
    undefined field455_0x1c7;
    undefined field456_0x1c8;
    undefined field457_0x1c9;
    undefined field458_0x1ca;
    undefined field459_0x1cb;
    undefined field460_0x1cc;
    undefined field461_0x1cd;
    undefined field462_0x1ce;
    undefined field463_0x1cf;
    undefined field464_0x1d0;
    undefined field465_0x1d1;
    undefined field466_0x1d2;
    undefined field467_0x1d3;
    undefined field468_0x1d4;
    undefined field469_0x1d5;
    undefined field470_0x1d6;
    undefined field471_0x1d7;
    undefined field472_0x1d8;
    undefined field473_0x1d9;
    undefined field474_0x1da;
    undefined field475_0x1db;
    undefined field476_0x1dc;
    undefined field477_0x1dd;
    undefined field478_0x1de;
    undefined field479_0x1df;
    undefined field480_0x1e0;
    undefined field481_0x1e1;
    undefined field482_0x1e2;
    undefined field483_0x1e3;
    undefined field484_0x1e4;
    undefined field485_0x1e5;
    undefined field486_0x1e6;
    undefined field487_0x1e7;
    undefined field488_0x1e8;
    undefined field489_0x1e9;
    undefined field490_0x1ea;
    undefined field491_0x1eb;
    undefined field492_0x1ec;
    undefined field493_0x1ed;
    undefined field494_0x1ee;
    undefined field495_0x1ef;
    undefined field496_0x1f0;
    undefined field497_0x1f1;
    undefined field498_0x1f2;
    undefined field499_0x1f3;
    undefined field500_0x1f4;
    undefined field501_0x1f5;
    undefined field502_0x1f6;
    undefined field503_0x1f7;
    undefined field504_0x1f8;
    undefined field505_0x1f9;
    undefined field506_0x1fa;
    undefined field507_0x1fb;
    undefined field508_0x1fc;
    undefined field509_0x1fd;
    undefined field510_0x1fe;
    undefined field511_0x1ff;
    undefined field512_0x200;
    undefined field513_0x201;
    undefined field514_0x202;
    undefined field515_0x203;
    undefined field516_0x204;
    undefined field517_0x205;
    undefined field518_0x206;
    undefined field519_0x207;
    undefined field520_0x208;
    undefined field521_0x209;
    undefined field522_0x20a;
    undefined field523_0x20b;
    undefined field524_0x20c;
    undefined field525_0x20d;
    undefined field526_0x20e;
    undefined field527_0x20f;
    undefined field528_0x210;
    undefined field529_0x211;
    undefined field530_0x212;
    undefined field531_0x213;
    undefined field532_0x214;
    undefined field533_0x215;
    undefined field534_0x216;
    undefined field535_0x217;
    undefined field536_0x218;
    undefined field537_0x219;
    undefined field538_0x21a;
    undefined field539_0x21b;
    undefined field540_0x21c;
    undefined field541_0x21d;
    undefined field542_0x21e;
    undefined field543_0x21f;
    undefined field544_0x220;
    undefined field545_0x221;
    undefined field546_0x222;
    undefined field547_0x223;
    undefined field548_0x224;
    undefined field549_0x225;
    undefined field550_0x226;
    undefined field551_0x227;
    undefined field552_0x228;
    undefined field553_0x229;
    undefined field554_0x22a;
    undefined field555_0x22b;
    undefined field556_0x22c;
    undefined field557_0x22d;
    undefined field558_0x22e;
    undefined field559_0x22f;
    undefined field560_0x230;
    undefined field561_0x231;
    undefined field562_0x232;
    undefined field563_0x233;
    undefined field564_0x234;
    undefined field565_0x235;
    undefined field566_0x236;
    undefined field567_0x237;
    undefined field568_0x238;
    undefined field569_0x239;
    undefined field570_0x23a;
    undefined field571_0x23b;
    undefined field572_0x23c;
    undefined field573_0x23d;
    undefined field574_0x23e;
    undefined field575_0x23f;
    undefined field576_0x240;
    undefined field577_0x241;
    undefined field578_0x242;
    undefined field579_0x243;
    undefined field580_0x244;
    undefined field581_0x245;
    undefined field582_0x246;
    undefined field583_0x247;
    undefined field584_0x248;
    undefined field585_0x249;
    undefined field586_0x24a;
    undefined field587_0x24b;
    undefined field588_0x24c;
    undefined field589_0x24d;
    undefined field590_0x24e;
    undefined field591_0x24f;
    undefined field592_0x250;
    undefined field593_0x251;
    undefined field594_0x252;
    undefined field595_0x253;
    undefined field596_0x254;
    undefined field597_0x255;
    undefined field598_0x256;
    undefined field599_0x257;
    undefined field600_0x258;
    undefined field601_0x259;
    undefined field602_0x25a;
    undefined field603_0x25b;
    undefined field604_0x25c;
    undefined field605_0x25d;
    undefined field606_0x25e;
    undefined field607_0x25f;
    undefined field608_0x260;
    undefined field609_0x261;
    undefined field610_0x262;
    undefined field611_0x263;
    undefined field612_0x264;
    undefined field613_0x265;
    undefined field614_0x266;
    undefined field615_0x267;
    undefined field616_0x268;
    undefined field617_0x269;
    undefined field618_0x26a;
    undefined field619_0x26b;
    undefined field620_0x26c;
    undefined field621_0x26d;
    undefined field622_0x26e;
    undefined field623_0x26f;
    undefined field624_0x270;
    undefined field625_0x271;
    undefined field626_0x272;
    undefined field627_0x273;
    undefined field628_0x274;
    undefined field629_0x275;
    undefined field630_0x276;
    undefined field631_0x277;
    undefined field632_0x278;
    undefined field633_0x279;
    undefined field634_0x27a;
    undefined field635_0x27b;
    undefined field636_0x27c;
    undefined field637_0x27d;
    undefined field638_0x27e;
    undefined field639_0x27f;
    undefined field640_0x280;
    undefined field641_0x281;
    undefined field642_0x282;
    undefined field643_0x283;
    undefined field644_0x284;
    undefined field645_0x285;
    undefined field646_0x286;
    undefined field647_0x287;
    undefined field648_0x288;
    undefined field649_0x289;
    undefined field650_0x28a;
    undefined field651_0x28b;
    undefined field652_0x28c;
    undefined field653_0x28d;
    undefined field654_0x28e;
    undefined field655_0x28f;
    bool _bAcceptClicks;
    undefined field657_0x291;
    undefined field658_0x292;
    undefined field659_0x293;
    undefined field660_0x294;
    undefined field661_0x295;
    undefined field662_0x296;
    undefined field663_0x297;
};


struct CTextBox {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    undefined field112_0x70;
    undefined field113_0x71;
    undefined field114_0x72;
    undefined field115_0x73;
    undefined field116_0x74;
    undefined field117_0x75;
    undefined field118_0x76;
    undefined field119_0x77;
    undefined field120_0x78;
    undefined field121_0x79;
    undefined field122_0x7a;
    undefined field123_0x7b;
    undefined field124_0x7c;
    undefined field125_0x7d;
    undefined field126_0x7e;
    undefined field127_0x7f;
    undefined field128_0x80;
    undefined field129_0x81;
    undefined field130_0x82;
    undefined field131_0x83;
    undefined field132_0x84;
    undefined field133_0x85;
    undefined field134_0x86;
    undefined field135_0x87;
    undefined field136_0x88;
    undefined field137_0x89;
    undefined field138_0x8a;
    undefined field139_0x8b;
    undefined field140_0x8c;
    undefined field141_0x8d;
    undefined field142_0x8e;
    undefined field143_0x8f;
    undefined field144_0x90;
    undefined field145_0x91;
    undefined field146_0x92;
    undefined field147_0x93;
    undefined field148_0x94;
    undefined field149_0x95;
    undefined field150_0x96;
    undefined field151_0x97;
    undefined field152_0x98;
    undefined field153_0x99;
    undefined field154_0x9a;
    undefined field155_0x9b;
    undefined field156_0x9c;
    undefined field157_0x9d;
    undefined field158_0x9e;
    undefined field159_0x9f;
    undefined field160_0xa0;
    undefined field161_0xa1;
    undefined field162_0xa2;
    undefined field163_0xa3;
    undefined field164_0xa4;
    undefined field165_0xa5;
    undefined field166_0xa6;
    undefined field167_0xa7;
    struct CGuiGraphics* _graphics;
    struct CGraphicalObject* _pText;
    struct C2dObject* _WindowOrigo;
    struct CString _name;
    struct CString _fontName;
    struct CString _backGroundName;
    int _maxWidth;
    int _maxHeight;
    class CVector2<unsigned int> _borderSize;
    class CVector2<int> _originalPosition;
    class CVector2<int> _position;
    bool _active;
    undefined field180_0x141;
    undefined field181_0x142;
    undefined field182_0x143;
    enum FontFormatting _format;
    bool _bFixedSize;
    undefined field185_0x149;
    undefined field186_0x14a;
    undefined field187_0x14b;
    enum EGuiOrientation _Orientation;
    class CVector2<int> _WindowSize;
    struct CString _Text;
    struct CColor _OriginalColor;
    struct CColor _Color;
    struct CFont* _pFont;
};

struct CDiscreteRange {
    struct CFixedPoint _min;
    struct CFixedPoint _max;
    struct CFixedPoint _step;
    int _nNumSteps;
};

struct CScrollbar {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    undefined field112_0x70;
    undefined field113_0x71;
    undefined field114_0x72;
    undefined field115_0x73;
    undefined field116_0x74;
    undefined field117_0x75;
    undefined field118_0x76;
    undefined field119_0x77;
    undefined field120_0x78;
    undefined field121_0x79;
    undefined field122_0x7a;
    undefined field123_0x7b;
    undefined field124_0x7c;
    undefined field125_0x7d;
    undefined field126_0x7e;
    undefined field127_0x7f;
    undefined field128_0x80;
    undefined field129_0x81;
    undefined field130_0x82;
    undefined field131_0x83;
    undefined field132_0x84;
    undefined field133_0x85;
    undefined field134_0x86;
    undefined field135_0x87;
    undefined field136_0x88;
    undefined field137_0x89;
    undefined field138_0x8a;
    undefined field139_0x8b;
    undefined field140_0x8c;
    undefined field141_0x8d;
    undefined field142_0x8e;
    undefined field143_0x8f;
    undefined field144_0x90;
    undefined field145_0x91;
    undefined field146_0x92;
    undefined field147_0x93;
    undefined field148_0x94;
    undefined field149_0x95;
    undefined field150_0x96;
    undefined field151_0x97;
    undefined field152_0x98;
    undefined field153_0x99;
    undefined field154_0x9a;
    undefined field155_0x9b;
    undefined field156_0x9c;
    undefined field157_0x9d;
    undefined field158_0x9e;
    undefined field159_0x9f;
    undefined field160_0xa0;
    undefined field161_0xa1;
    undefined field162_0xa2;
    undefined field163_0xa3;
    undefined field164_0xa4;
    undefined field165_0xa5;
    undefined field166_0xa6;
    undefined field167_0xa7;
    undefined field168_0xa8;
    undefined field169_0xa9;
    undefined field170_0xaa;
    undefined field171_0xab;
    undefined field172_0xac;
    undefined field173_0xad;
    undefined field174_0xae;
    undefined field175_0xaf;
    undefined field176_0xb0;
    undefined field177_0xb1;
    undefined field178_0xb2;
    undefined field179_0xb3;
    undefined field180_0xb4;
    undefined field181_0xb5;
    undefined field182_0xb6;
    undefined field183_0xb7;
    undefined field184_0xb8;
    undefined field185_0xb9;
    undefined field186_0xba;
    undefined field187_0xbb;
    undefined field188_0xbc;
    undefined field189_0xbd;
    undefined field190_0xbe;
    undefined field191_0xbf;
    undefined field192_0xc0;
    undefined field193_0xc1;
    undefined field194_0xc2;
    undefined field195_0xc3;
    undefined field196_0xc4;
    undefined field197_0xc5;
    undefined field198_0xc6;
    undefined field199_0xc7;
    undefined field200_0xc8;
    undefined field201_0xc9;
    undefined field202_0xca;
    undefined field203_0xcb;
    undefined field204_0xcc;
    undefined field205_0xcd;
    undefined field206_0xce;
    undefined field207_0xcf;
    undefined field208_0xd0;
    undefined field209_0xd1;
    undefined field210_0xd2;
    undefined field211_0xd3;
    undefined field212_0xd4;
    undefined field213_0xd5;
    undefined field214_0xd6;
    undefined field215_0xd7;
    undefined field216_0xd8;
    undefined field217_0xd9;
    undefined field218_0xda;
    undefined field219_0xdb;
    undefined field220_0xdc;
    undefined field221_0xdd;
    undefined field222_0xde;
    undefined field223_0xdf;
    undefined field224_0xe0;
    undefined field225_0xe1;
    undefined field226_0xe2;
    undefined field227_0xe3;
    undefined field228_0xe4;
    undefined field229_0xe5;
    undefined field230_0xe6;
    undefined field231_0xe7;
    enum e_state;
    bool _bSliderDown;
    undefined field234_0xed;
    undefined field235_0xee;
    undefined field236_0xef;
    struct CGuiGraphics* _graphics;
    struct CScrollbarType* _creator;
    class CVector2<float> _position;
    class CVector2<float> _oldPosition;
    class CVector2<int> _trackPosition;
    class CVector2<int> _decButtonPosition;
    class CVector2<int> _incButtonPosition;
    class CVector2<int> _limitMinPosition;
    class CVector2<int> _limitMaxPosition;
    class CVector2<float> _sliderPos;
    struct CButtonDrag* _slider;
    struct CButtonObjectGlue<CScrollbar> _TrackClicked;
    struct CButtonObserverGlue<CScrollbar> _SliderMoved;
    struct CTrack* _track;
    struct CButtonStandard* _decButton;
    struct CButtonObserverGlue<CScrollbar> _IncClicked;
    struct CButtonStandard* _incButton;
    struct CButtonObserverGlue<CScrollbar> _DecClicked;
    struct CIcon* _pLimitMinIcon;
    struct CIcon* _pLimitMaxIcon;
    struct CClock* _pClock;
    int _nShiftSpeed;
    uint _height;
    uint _width;
    class CVector2<unsigned short> _tileSize;
    float _value;
    float _delayTime;
    float _lastTimeDown;
    undefined field265_0x4b4;
    undefined field266_0x4b5;
    undefined field267_0x4b6;
    undefined field268_0x4b7;
    struct CDiscreteRange _range;
    ushort _horizontal;
    undefined field271_0x4da;
    undefined field272_0x4db;
    class CVector2<int> _size;
    int _nConstrainedValueIndex;
    int _lastSliderPos;
    int counter;
    bool _bLockable;
    bool _bDragable;
    bool _bPermaLock;
    bool _bDisallowJumps;
    undefined field281_0x4f4;
    undefined field282_0x4f5;
    undefined field283_0x4f6;
    undefined field284_0x4f7;
    struct C2dPositionObject _ScrollbarOrigo;
    bool _bSetOrientation;
    undefined field287_0x5f9;
    undefined field288_0x5fa;
    undefined field289_0x5fb;
    undefined field290_0x5fc;
    undefined field291_0x5fd;
    undefined field292_0x5fe;
    undefined field293_0x5ff;
    struct CFixedPoint _StartValue;
    struct CFixedPoint _vLimitMin;
    struct CFixedPoint _vLimitMax;
    bool _bIsRangeLimited;
    undefined field298_0x619;
    undefined field299_0x61a;
    undefined field300_0x61b;
    int _nScrollSpeed;
    bool _bIsEnabled;
    bool _bHideSlider;
    bool _bSelected;
    bool _bGamepadActive;
    undefined field306_0x624;
    undefined field307_0x625;
    undefined field308_0x626;
    undefined field309_0x627;
    struct CButtonDrag* _pOverlay;
    struct CString _Empty;
};



struct CFixedWindow {
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
    undefined field24_0x18;
    undefined field25_0x19;
    undefined field26_0x1a;
    undefined field27_0x1b;
    undefined field28_0x1c;
    undefined field29_0x1d;
    undefined field30_0x1e;
    undefined field31_0x1f;
    undefined field32_0x20;
    undefined field33_0x21;
    undefined field34_0x22;
    undefined field35_0x23;
    undefined field36_0x24;
    undefined field37_0x25;
    undefined field38_0x26;
    undefined field39_0x27;
    undefined field40_0x28;
    undefined field41_0x29;
    undefined field42_0x2a;
    undefined field43_0x2b;
    undefined field44_0x2c;
    undefined field45_0x2d;
    undefined field46_0x2e;
    undefined field47_0x2f;
    undefined field48_0x30;
    undefined field49_0x31;
    undefined field50_0x32;
    undefined field51_0x33;
    undefined field52_0x34;
    undefined field53_0x35;
    undefined field54_0x36;
    undefined field55_0x37;
    undefined field56_0x38;
    undefined field57_0x39;
    undefined field58_0x3a;
    undefined field59_0x3b;
    undefined field60_0x3c;
    undefined field61_0x3d;
    undefined field62_0x3e;
    undefined field63_0x3f;
    undefined field64_0x40;
    undefined field65_0x41;
    undefined field66_0x42;
    undefined field67_0x43;
    undefined field68_0x44;
    undefined field69_0x45;
    undefined field70_0x46;
    undefined field71_0x47;
    undefined field72_0x48;
    undefined field73_0x49;
    undefined field74_0x4a;
    undefined field75_0x4b;
    undefined field76_0x4c;
    undefined field77_0x4d;
    undefined field78_0x4e;
    undefined field79_0x4f;
    undefined field80_0x50;
    undefined field81_0x51;
    undefined field82_0x52;
    undefined field83_0x53;
    undefined field84_0x54;
    undefined field85_0x55;
    undefined field86_0x56;
    undefined field87_0x57;
    undefined field88_0x58;
    undefined field89_0x59;
    undefined field90_0x5a;
    undefined field91_0x5b;
    undefined field92_0x5c;
    undefined field93_0x5d;
    undefined field94_0x5e;
    undefined field95_0x5f;
    undefined field96_0x60;
    undefined field97_0x61;
    undefined field98_0x62;
    undefined field99_0x63;
    undefined field100_0x64;
    undefined field101_0x65;
    undefined field102_0x66;
    undefined field103_0x67;
    undefined field104_0x68;
    undefined field105_0x69;
    undefined field106_0x6a;
    undefined field107_0x6b;
    undefined field108_0x6c;
    undefined field109_0x6d;
    undefined field110_0x6e;
    undefined field111_0x6f;
    undefined field112_0x70;
    undefined field113_0x71;
    undefined field114_0x72;
    undefined field115_0x73;
    undefined field116_0x74;
    undefined field117_0x75;
    undefined field118_0x76;
    undefined field119_0x77;
    undefined field120_0x78;
    undefined field121_0x79;
    undefined field122_0x7a;
    undefined field123_0x7b;
    undefined field124_0x7c;
    undefined field125_0x7d;
    undefined field126_0x7e;
    undefined field127_0x7f;
    undefined field128_0x80;
    undefined field129_0x81;
    undefined field130_0x82;
    undefined field131_0x83;
    undefined field132_0x84;
    undefined field133_0x85;
    undefined field134_0x86;
    undefined field135_0x87;
    undefined field136_0x88;
    undefined field137_0x89;
    undefined field138_0x8a;
    undefined field139_0x8b;
    undefined field140_0x8c;
    undefined field141_0x8d;
    undefined field142_0x8e;
    undefined field143_0x8f;
    undefined field144_0x90;
    undefined field145_0x91;
    undefined field146_0x92;
    undefined field147_0x93;
    undefined field148_0x94;
    undefined field149_0x95;
    undefined field150_0x96;
    undefined field151_0x97;
    undefined field152_0x98;
    undefined field153_0x99;
    undefined field154_0x9a;
    undefined field155_0x9b;
    undefined field156_0x9c;
    undefined field157_0x9d;
    undefined field158_0x9e;
    undefined field159_0x9f;
    undefined field160_0xa0;
    undefined field161_0xa1;
    undefined field162_0xa2;
    undefined field163_0xa3;
    undefined field164_0xa4;
    undefined field165_0xa5;
    undefined field166_0xa6;
    undefined field167_0xa7;
    undefined field168_0xa8;
    undefined field169_0xa9;
    undefined field170_0xaa;
    undefined field171_0xab;
    undefined field172_0xac;
    undefined field173_0xad;
    undefined field174_0xae;
    undefined field175_0xaf;
    undefined field176_0xb0;
    undefined field177_0xb1;
    undefined field178_0xb2;
    undefined field179_0xb3;
    undefined field180_0xb4;
    undefined field181_0xb5;
    undefined field182_0xb6;
    undefined field183_0xb7;
    undefined field184_0xb8;
    undefined field185_0xb9;
    undefined field186_0xba;
    undefined field187_0xbb;
    undefined field188_0xbc;
    undefined field189_0xbd;
    undefined field190_0xbe;
    undefined field191_0xbf;
    undefined field192_0xc0;
    undefined field193_0xc1;
    undefined field194_0xc2;
    undefined field195_0xc3;
    undefined field196_0xc4;
    undefined field197_0xc5;
    undefined field198_0xc6;
    undefined field199_0xc7;
    undefined field200_0xc8;
    undefined field201_0xc9;
    undefined field202_0xca;
    undefined field203_0xcb;
    undefined field204_0xcc;
    undefined field205_0xcd;
    undefined field206_0xce;
    undefined field207_0xcf;
    undefined field208_0xd0;
    undefined field209_0xd1;
    undefined field210_0xd2;
    undefined field211_0xd3;
    undefined field212_0xd4;
    undefined field213_0xd5;
    undefined field214_0xd6;
    undefined field215_0xd7;
    bool _bCatchWheel;
    bool _bAcceptClicks;
    undefined field218_0xda;
    undefined field219_0xdb;
    undefined field220_0xdc;
    undefined field221_0xdd;
    undefined field222_0xde;
    undefined field223_0xdf;
    class CList<CGuiObject*> _PrioList;
    class CList<CGuiObject*> _PrioAttachedList;
    struct CGuiGraphics* _Graphics;
    struct CWindowType* _creator;
    struct CString _background;
    struct CButtonObserverGlue<CFixedWindow> _WindowMoved;
    struct CButtonObserverGlue<CFixedWindow> _WindowDown;
    struct CButtonObserverGlue<CFixedWindow> _MinimizedClicked;
    struct CButtonObserverGlue<CFixedWindow> _HelpClicked;
    struct CButtonObserverGlue<CFixedWindow> _ClickToFront;
    struct CButtonDrag* _backGround;
    bool _bInPosition;
    bool _bHideWhenInPosition;
    bool _bHideOnlyWindowWhenInPosition;
    undefined field238_0x55b;
    class CVector2<int> _showPos;
    class CVector2<int> _hidePos;
    class CVector2<int> _StartPosition;
    class CVector2<int> _GoalPosition;
    class CVector2<float> _movementVector;
    float _vAnimationTime;
    float _vCurrentAnimationTime;
    float _nLengthToMove;
    float _nHeightToMove;
    enum EAnimationState _eAnimationState;
    enum EAnimationType _eAnimationType;
    class CVector2<int> _windowPos;
    class CVector2<int> _windowPosBeforeOrientation;
    class CVector2<int> _okButtonPos;
    bool _bMovable;
    undefined field254_0x5b5;
    short _nDragSlack;
    class CPdxArray<CButtonStandard*, int> _Buttons;
    class CPdxArray<CString, int> _ButtonLookUp;
    class CPdxArray<CMultiSpriteButton*, int> _MultiSpriteButtons;
    class CPdxArray<CString, int> _MultiSpriteButtonLookUp;
    class CPdxArray<CIcon*, int> _Icons;
    class CPdxArray<CString, int> _IconLookUp;
    class CPdxArray<CBrowser*, int> _Browsers;
    class CPdxArray<CString, int> _BrowserLookUp;
    class CPdxArray<CCurveGraph*, int> _CurveGraphs;
    class CPdxArray<CString, int> _CurveGraphsLookUp;
    class CPdxArray<CDropDownBox*, int> _DropDownBoxes;
    class CPdxArray<CString, int> _DropDownBoxesLookUp;
    class CPdxArray<CInstantTextBox*, int> _InstantTextBoxes;
    class CPdxArray<CString, int> _InstantTextBoxesLookUp;
    class CPdxArray<COverlappingElementsBox*, int> _OverlappingElementsBoxes;
    class CPdxArray<CString, int> _OverlappingElementsBoxLookup;
    class CPdxArray<CGuiObject*, int> _AttachedObjects;
    class CPdxArray<CString, int> _AttachedObjectsLookup;
    class CTernary<CTextBox*, STernaryTrait<CTextBox*>> _TextBoxes;
    class CTernary<CEditBox*, STernaryTrait<CEditBox*>> _EditBoxes;
    class CTernary<CCheckBox*, STernaryTrait<CCheckBox*>> _Checkboxes;
    class CTernary<CStandardlistbox*, STernaryTrait<CStandardlistbox*>> _Listboxes;
    class CTernary<CSmoothListbox*, STernaryTrait<CSmoothListbox*>> _SmoothListboxes;
    class CTernary<CScrollbar*, STernaryTrait<CScrollbar*>> _Scrollbars;
    class CTernary<CSpinner*, STernaryTrait<CSpinner*>> _Spinners;
    class CValueAssociativeArray<CString, CFixedWindow*> _SubWindows;
    class CList<CString> _TextBoxList;
    class CList<CString> _MeshedButtonList;
    class CList<CString> _EditBoxList;
    class CList<CString> _CheckboxList;
    class CList<CString> _ListboxeList;
    class CList<CString> _SmoothListboxNames;
    class CList<CString> _ScrollbarList;
    class CList<CString> _SpinnerList;
    struct C2dObject* _pWindowOrigo;
    enum EGuiOrientation _Orientation;
    class CPoint<int> _Size;
    undefined field293_0xa14;
    undefined field294_0xa15;
    undefined field295_0xa16;
    undefined field296_0xa17;
    struct SoundEffectAUDIO* _ShowSound;
    struct SoundEffectAUDIO* _HideSound;
    struct SSoundEffectHandle _ShowSoundInstance;
    struct SSoundEffectHandle _HideSoundInstance;
    struct CString _NewName;
    class CPoint<int> _ParentWindowSize;
};

struct CGameIdler {
    undefined field0_0x0;
    undefined field1_0x1;
    undefined field2_0x2;
    undefined field3_0x3;
    undefined field4_0x4;
    undefined field5_0x5;
    undefined field6_0x6;
    undefined field7_0x7;
    struct CTextBox* _pToolTip;
    struct CString _LastToolTipText;
    float _vLastUpdateTime;
    bool _bIsDeviceOk;
    undefined field12_0x35;
    undefined field13_0x36;
    undefined field14_0x37;
    struct CConsole* _pConsole;
    struct CTooltipModeHandler _TooltipModeHandler;
    float _vLastFrameDuration;
    float _vUncappedFrameDuration;
    struct CGameGraphics* _pGraphics;
    struct CGui* _pGui;
    struct CMouse* _pMouse;
    struct CKeyBoard* _pKeyboard;
    struct CPdxGameControllerGroup* _pControllers;
    struct CClock* _pClock;
    struct CClock* _pTimer;
    class CList<CInputEvent> _InputQueue;
    struct CGameApplication* _Super;
    class CPdxArray<float, int> _LineArray;
    enum IdlerType _eType;
    undefined field30_0xec;
    undefined field31_0xed;
    undefined field32_0xee;
    undefined field33_0xef;
    class CPdxArray<CUpdateable*, int> _Updateables;
    bool _bIsMultiplayer;
    unsigned int _nMostRecentUpdateableID;
    bool _bReload;
    undefined field38_0x10e;
    undefined field39_0x10f;
    void* _pUserData;
    void* _PreRenderSetupOverride;
    struct CGraphicalMap* _pGraphicalMap;
    class CPdxArray<CFixedWindow*, int> _AnimatedWindows;
    struct CStandardlistbox* _pOpenDropdownListbox;
    struct TWindow* _pOpenAutocloseWindow;
    bool _bShouldCloseOpenAutocloseWindow;
    undefined field47_0x151;
    undefined field48_0x152;
    undefined field49_0x153;
    float _vTooltipDelayTimer;
    float _vScreenshotTimer;
    bool _bTakeScreenshot;
    bool _bShouldRenderLoadScreen;
    undefined field54_0x15e;
    undefined field55_0x15f;
    struct CReloadInterfaceDialog* _pReloadInterfaceDialog;
    class CVector2<float> _LastMousePos;
    struct CGuiObject* _pLastGui;
    bool _bUseActionInput;
    undefined field60_0x179;
    undefined field61_0x17a;
    undefined field62_0x17b;
    undefined field63_0x17c;
    undefined field64_0x17d;
    undefined field65_0x17e;
    undefined field66_0x17f;
    struct CActionInputGenerator _ActionInputGenerator;
    struct CGuiView* _pInputFocusView;
    struct SGamepadEventFunctor* _pHandleGamepadInputFunctor;
    struct SActionEventFunctor* _pHandleActionInputFunctor;
};


#include "sourcemod"
#include "sdktools"
#include "dhooks"

#include "glib/addressutils"
#include "glib/assertutils"

#define SNAME "[NoclipSpeed] "

public Plugin myinfo = 
{
    name = "NoclipSpeed",
    author = "GAMMA CASE",
    description = "Let's you change noclip speed.",
    version = "1.1.1",
    url = "http://steamcommunity.com/id/_GAMMACASE_/"
};

#define FLT_EPSILON 1.0e-7

// https://github.com/perilouswithadollarsign/cstrike15_src/blob/29e4c1fda9698d5cebcdaf1a0de4b829fa149bf8/public/const.h#L90
#define	MAX_EDICT_BITS			11
#define	MAX_EDICTS				(1 << MAX_EDICT_BITS)

#define NUM_ENT_ENTRY_BITS		(MAX_EDICT_BITS + 1)
#define NUM_ENT_ENTRIES			(1 << NUM_ENT_ENTRY_BITS)
#define INVALID_EHANDLE_INDEX	0xFFFFFFFF

#define NUM_SERIAL_NUM_BITS		16 // (32 - NUM_ENT_ENTRY_BITS)
#define ENT_ENTRY_MASK_CSGO		(( 1 << NUM_SERIAL_NUM_BITS) - 1)
#define ENT_ENTRY_MASK_CSS		(NUM_ENT_ENTRIES - 1)

enum OSType
{
	OSUnknown = -1,
	OSWindows = 1,
	OSLinux = 2
}

OSType gOSType;

int gCGameMovement_player_offs;
int CBaseEntity_m_RefEHandle_offs;

float gPlayerNoclipSpeed[MAXPLAYERS];

ConVar gMaxAllowedNoclipFactor;

ConVar sv_maxspeed;
ConVar sv_friction;
ConVar sv_noclipspeed;

EngineVersion gEVType;

public void OnPluginStart()
{
	gEVType = GetEngineVersion();
	
	RegConsoleCmd("sm_ns", SM_NoclipSpeed, "Sets noclip speed. Can also be used to set or change speed via argument (Examples: sm_ns 1500 or sm_ns +100)");
	RegConsoleCmd("sm_noclipspeed", SM_NoclipSpeed, "Sets noclip speed. Can also be used to set or change speed via argument (Examples: sm_ns 1500 or sm_ns +100)");
	
	gMaxAllowedNoclipFactor = CreateConVar("noclipspeed_max_factor", "35", "Max allowed factor for noclip (factor * 300 = speed)", .hasMin = true);
	
	AutoExecConfig();
	
	GameData gd = new GameData("noclipspeed.games");
	
	gOSType = view_as<OSType>(gd.GetOffset("OSType"));
	ASSERT_MSG(gOSType != OSUnknown, "Failed to get OS type, only windows and linux are supported.");
	SetupOffs(gd);
	SetupDhooks(gd);
	
	delete gd;
	
	sv_noclipspeed = FindConVar("sv_noclipspeed");
	ASSERT_MSG(sv_noclipspeed, "Failed to find \"sv_noclipspeed\" cvar.");
	sv_maxspeed = FindConVar("sv_maxspeed");
	ASSERT_MSG(sv_maxspeed, "Failed to find \"sv_maxspeed\" convar.");
	sv_friction = FindConVar("sv_friction");
	ASSERT_MSG(sv_friction, "Failed to find \"sv_friction\" convar.");
}

public void OnPluginEnd() { }

void SetupOffs(GameData gd)
{
	//CGameMovement
	char buff[32];
	ASSERT_MSG(gd.GetKeyValue("CGameMovement::player", buff, sizeof(buff)), "Failed to find \"CGameMovement::player\" offset.");
	gCGameMovement_player_offs = StringToInt(buff);
	
	//CBaseEntity
	int ibuff = gd.GetOffset("m_angRotation");
	ASSERT_MSG(ibuff != -1, "Failed to find \"CBaseEntity::m_angRotation\" offset.");
	ASSERT_MSG(gd.GetKeyValue("CBaseEntity::m_RefEHandle", buff, sizeof(buff)), "Failed to find \"CBaseEntity::m_RefEHandle\" offset.");
	CBaseEntity_m_RefEHandle_offs = ibuff + StringToInt(buff);
}

void SetupDhooks(GameData gd)
{
	Handle dhook;
	
	//CGameMovement::FullNoClipMove
	if(gOSType == OSWindows)
	{
		dhook = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_Ignore);
		ASSERT_MSG(DHookSetFromConf(dhook, gd, SDKConf_Signature, "CGameMovement::FullNoClipMove"), "Failed to find \"CGameMovement::FullNoClipMove\" signature.");
		
		DHookAddParam(dhook, HookParamType_Int, .custom_register = DHookRegister_ECX);
		if(gEVType == Engine_CSGO)
		{
			DHookAddParam(dhook, HookParamType_Float, .custom_register = DHookRegister_XMM1);
			DHookAddParam(dhook, HookParamType_Float, .custom_register = DHookRegister_XMM2);
		}
		else
		{
			DHookAddParam(dhook, HookParamType_Float);
			DHookAddParam(dhook, HookParamType_Float);
		}
		
		ASSERT_MSG(DHookEnableDetour(dhook, false, FullNoClipMove_Dhook), "Failed to enable \"CGameMovement::FullNoClipMove\" detour.");
	}
	else if(gOSType == OSLinux)
	{
		dhook = DHookCreateDetour(Address_Null, CallConv_CDECL, ReturnType_Void, ThisPointer_Ignore);
		ASSERT_MSG(DHookSetFromConf(dhook, gd, SDKConf_Signature, "CGameMovement::FullNoClipMove"), "Failed to find \"CGameMovement::FullNoClipMove\" signature.");
		
		DHookAddParam(dhook, HookParamType_Int);
		DHookAddParam(dhook, HookParamType_Float);
		DHookAddParam(dhook, HookParamType_Float);
		
		ASSERT_MSG(DHookEnableDetour(dhook, false, FullNoClipMove_Dhook), "Failed to enable \"CGameMovement::FullNoClipMove\" detour.");
	}
}

public void OnClientPutInServer(int client)
{
	if(IsFakeClient(client))
		return;
	
	gPlayerNoclipSpeed[client] = sv_noclipspeed.FloatValue;
}

public void OnClientDisconnect(int client)
{
	if(IsFakeClient(client))
		return;
	
	gPlayerNoclipSpeed[client] = sv_noclipspeed.FloatValue;
	char buff[32];
	Format(buff, sizeof(buff), "%f", sv_noclipspeed.FloatValue);
	sv_noclipspeed.ReplicateToClient(client, buff);
}

public MRESReturn FullNoClipMove_Dhook(Handle hParams)
{
	Address player = view_as<Address>(LoadFromAddress(DHookGetParam(hParams, 1) + gCGameMovement_player_offs, NumberType_Int32));
	
	int client = EntityToBCompatRef(player);
	
	if(client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return MRES_Ignored;
	
	float factor = DHookGetParam(hParams, 2);
	
	if(CloseEnough(factor, gPlayerNoclipSpeed[client]))
		return MRES_Ignored;
	
	DHookSetParam(hParams, 2, gPlayerNoclipSpeed[client]);
	
	return MRES_ChangedHandled;
}

// https://github.com/alliedmodders/sourcemod/blob/c5619f887d6d13643ad8281e8e7479668226c342/core/HalfLife2.cpp#L1082
int EntityToBCompatRef(Address player)
{
	if(player == Address_Null)
		return INVALID_EHANDLE_INDEX;
	
	int m_RefEHandle = LoadFromAddress(player + CBaseEntity_m_RefEHandle_offs, NumberType_Int32)
	
	if(m_RefEHandle == INVALID_EHANDLE_INDEX)
		return INVALID_EHANDLE_INDEX;
	
	// https://github.com/perilouswithadollarsign/cstrike15_src/blob/29e4c1fda9698d5cebcdaf1a0de4b829fa149bf8/public/basehandle.h#L137
	int entry_idx = gEVType == Engine_CSGO ? m_RefEHandle & ENT_ENTRY_MASK_CSGO : m_RefEHandle & ENT_ENTRY_MASK_CSS;
	
	if(entry_idx >= MAX_EDICTS)
		return m_RefEHandle | (1 << 31);
	
	return entry_idx;
}

public Action SM_NoclipSpeed(int client, int args)
{
	if(!client)
		return Plugin_Handled;
	
	if(args < 1)
	{
		Menu menu = new Menu(NoclipSpeed_Menu, MENU_ACTIONS_DEFAULT | MenuAction_DrawItem | MenuAction_Display);
		
		menu.AddItem("def", "Reset to default\n ");
		
		char buff[128];
		Format(buff, sizeof(buff), "Increase by %.2f", GetCurrentSpeedForFactor());
		menu.AddItem("inc", buff);
		Format(buff, sizeof(buff), "Decrease by %.2f", GetCurrentSpeedForFactor());
		menu.AddItem("dec", buff);
		
		menu.Display(client, MENU_TIME_FOREVER);
	}
	else
	{
		char buff[32];
		GetCmdArg(1, buff, sizeof(buff));
		
		float spd = StringToFloat(buff);
		
		// NaN check in case of an invalid argument
		if(spd == 0.0 || spd != spd)
		{
			PrintToChat(client, SNAME..."Invalid speed value specified, check your arguments!");
			return Plugin_Handled;
		}
		
		gPlayerNoclipSpeed[client] = Clamp(buff[0] == '+' || buff[0] == '-' ? gPlayerNoclipSpeed[client] + NoclipUPSToFactor(spd) : NoclipUPSToFactor(spd), 0.0, gMaxAllowedNoclipFactor.FloatValue);
		Format(buff, sizeof(buff), "%f", gPlayerNoclipSpeed[client]);
		sv_noclipspeed.ReplicateToClient(client, buff);
		
		PrintToChat(client, SNAME..."Changed noclip speed to: %i u/s", RoundToNearest(NoclipFactorToUPS(gPlayerNoclipSpeed[client])));
	}
	
	return Plugin_Handled;
}

public int NoclipSpeed_Menu(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_Display:
		{
			menu.SetTitle("Noclip speed\n \nCurrent speed: %i\n ", RoundToNearest(NoclipFactorToUPS(gPlayerNoclipSpeed[param1])));
		}
		
		case MenuAction_DrawItem:
		{
			char buff[32];
			int style;
			menu.GetItem(param2, buff, sizeof(buff), style);
			
			if(StrEqual(buff, "inc") && gPlayerNoclipSpeed[param1] + 1.0 > gMaxAllowedNoclipFactor.FloatValue)
				return ITEMDRAW_DISABLED;
			else if(StrEqual(buff, "dec") && gPlayerNoclipSpeed[param1] - 1.0 < 0.0)
				return ITEMDRAW_DISABLED;
			
			return style;
		}
		
		case MenuAction_Select:
		{
			char buff[32];
			menu.GetItem(param2, buff, sizeof(buff));
			
			if(StrEqual(buff, "inc"))
				gPlayerNoclipSpeed[param1] += 1.0 + FLT_EPSILON;
			else if(StrEqual(buff, "dec"))
				gPlayerNoclipSpeed[param1] -= 1.0 - FLT_EPSILON;
			else if(StrEqual(buff, "def"))
				gPlayerNoclipSpeed[param1] = sv_noclipspeed.FloatValue;
			
			Format(buff, sizeof(buff), "%f", gPlayerNoclipSpeed[param1]);
			sv_noclipspeed.ReplicateToClient(param1, buff);
			
			menu.Display(param1, MENU_TIME_FOREVER);
		}
		
		case MenuAction_End:
			if(param2 != MenuEnd_Selected)
				delete menu;
	}
	
	return 0;
}

float NoclipUPSToFactor(float spd)
{
	return spd / GetCurrentSpeedForFactor();
}

float NoclipFactorToUPS(float factor)
{
	return factor * GetCurrentSpeedForFactor();
}

float GetCurrentSpeedForFactor()
{
	return sv_maxspeed.FloatValue - (sv_maxspeed.FloatValue * GetTickInterval() * sv_friction.FloatValue);
}

float Clamp(float val, float min, float max)
{
	return (val < min) ? min : (max < val) ? max : val;
}

bool CloseEnough(float a, float b, float eps = FLT_EPSILON)
{
	return FloatAbs(a - b) <= eps;
}

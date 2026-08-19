/**
 * Paint - decal painting plugin for Counter-Strike: Source
 *
 * Features:
 *   - +paint / -paint bindable command (hold to keep painting)
 *   - Colour / size selection menu
 *   - Target-entity override: pick a (possibly nonsolid) entity from a menu,
 *     it flickers via SetTransmit so you can see what you selected
 *   - Brush models are traced with TR_ClipRayToEntity (with a temporary
 *     solidity override so SOLID_NONE brushes can still be hit)
 *   - Studio models are not traced at all: the decal is placed a fixed
 *     distance in front of the eye
 *   - Decals are stored in entity local space and saved per-map, keyed by
 *     hammerid + classname + model, so they can be restored after a map change
 *   - Late joiners get every stored decal re-sent on their first spawn
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION      "1.0.0"

#define FSOLID_NOT_SOLID    0x0004
#define SOLID_BSP           2

/* Colour name, material name */
char g_cPaintColours[][][64] = // Modify this to add/change colours
{
	{ "Random",     "random"         },
	{ "White",      "paint_white"    },
	{ "Black",      "paint_black"    },
	{ "Blue",       "paint_blue"     },
	{ "Light Blue", "paint_lightblue"},
	{ "Brown",      "paint_brown"    },
	{ "Cyan",       "paint_cyan"     },
	{ "Green",      "paint_green"    },
	{ "Dark Green", "paint_darkgreen"},
	{ "Red",        "paint_red"      },
	{ "Orange",     "paint_orange"   },
	{ "Yellow",     "paint_yellow"   },
	{ "Pink",       "paint_pink"     },
	{ "Light Pink", "paint_lightpink"},
	{ "Purple",     "paint_purple"   },
};

/* Size name, size suffix */
char g_cPaintSizes[][][64] = // Modify this to add more sizes
{
	{ "Small",  ""       },
	{ "Medium", "_med"   },
	{ "Large",  "_large" },
};

// [0] of the colour table is reserved for "Random", so sprites start at colour 1
int g_Sprites[sizeof( g_cPaintColours ) - 1][sizeof( g_cPaintSizes )];

enum struct PaintRecord
{
	int   colour;                    // resolved colour index into g_cPaintColours (never 0)
	int   size;                      // index into g_cPaintSizes
	int   hitbox;
	int   hammerid;                  // 0 = world / no hammerid
	int   entref;                    // runtime entity reference, 0 = world
	int   owner;                     // userid of painter, 0 = loaded from disk
	char  classname[64];
	char  model[PLATFORM_MAX_PATH];
	float pos[3];                    // entity local space (world space for world decals)
	float start[3];                  // entity local space (world space for world decals)
}

ArrayList g_hRecords;                // of PaintRecord
ArrayList g_hEnumList;               // scratch list of entity indices along the ray
ArrayList g_hPropList;               // scratch list of static prop indices along the ray

bool  g_bEnumStatic;                 // which list the enumerate callback fills

int   g_iColour[MAXPLAYERS + 1];
int   g_iSize[MAXPLAYERS + 1];
int   g_iTarget[MAXPLAYERS + 1];     // entity reference of the override target, 0 = free aim
int   g_iTargetProp[MAXPLAYERS + 1]; // static prop index of the override target, -1 = none
bool  g_bPainting[MAXPLAYERS + 1];
bool  g_bSynced[MAXPLAYERS + 1];
float g_fLastPaint[MAXPLAYERS + 1];

bool  g_bFlicker;                    // shared flicker state for highlighted entities
float g_fEnumEye[3];                 // eye position used by the enumerate sort

char  g_sMapFile[PLATFORM_MAX_PATH];

ConVar g_cvEnabled;
ConVar g_cvInterval;
ConVar g_cvMaxPlayer;
ConVar g_cvMaxTotal;
ConVar g_cvFlag;
ConVar g_cvAutoSave;
ConVar g_cvAutoLoad;
ConVar g_cvStudioDist;

public Plugin myinfo =
{
	name        = "Paint",
	author      = "you",
	description = "Paint decals on the world and on (nonsolid) entities",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	// patch CStaticProp::InsertPropIntoKDTree
	/*
	void CStaticProp::InsertPropIntoKDTree()
	{
	Assert( m_Partition == PARTITION_INVALID_HANDLE );
	if ( m_nSolidType == SOLID_NONE ) <------------------------------ nop 
		return;
	...
	// add the entity to the KD tree so we will collide against it
	m_Partition = SpatialPartition()->CreateHandle( this, 
	PARTITION_CLIENT_SOLID_EDICTS | PARTITION_CLIENT_STATIC_PROPS | 
	PARTITION_ENGINE_SOLID_EDICTS | PARTITION_ENGINE_STATIC_PROPS, 
	mins, maxs );
	*/
    GameData hGameData = new GameData("paint_claude");
    
    if (hGameData == null)
    {
        PrintToServer("Failed to load gamedata/paint_claude.txt");
    }
    else
	{
		Address addr = hGameData.GetMemSig("CStaticProp::InsertPropIntoKDTree Patch");
		
		if (addr == Address_Null)
		{
			PrintToServer("Failed to find signature 'CStaticProp::InsertPropIntoKDTree Patch'");
		}
		else
		{
			StoreToAddress(addr, 0x90909090, NumberType_Int32);
			StoreToAddress(addr + view_as<Address>(4), 0x9090, NumberType_Int16);
			
			PrintToServer("Patched engine.dll - JZ instruction NOP'd, WINDOWS ONLY!");
		}
		delete hGameData;
	}

	g_hRecords   = new ArrayList( sizeof( PaintRecord ) );
	g_hEnumList  = new ArrayList();
	g_hPropList  = new ArrayList();

	g_cvEnabled    = CreateConVar( "sm_paint_enabled",     "1",   "Enable painting",                                  _, true, 0.0, true, 1.0 );
	g_cvInterval   = CreateConVar( "sm_paint_interval",    "0.15","Seconds between decals while +paint is held",       _, true, 0.05 );
	g_cvMaxPlayer  = CreateConVar( "sm_paint_max_player",  "120", "Max decals a single player may place per map",      _, true, 1.0 );
	g_cvMaxTotal   = CreateConVar( "sm_paint_max_total",   "800", "Max decals tracked per map (client decal limit!)",  _, true, 1.0 );
	g_cvFlag       = CreateConVar( "sm_paint_flag",        "",    "Admin flag required to paint, empty = everyone" );
	g_cvAutoSave   = CreateConVar( "sm_paint_autosave",    "1",   "Save decals to disk on map end",                    _, true, 0.0, true, 1.0 );
	g_cvAutoLoad   = CreateConVar( "sm_paint_autoload",    "1",   "Load decals from disk on map start",                _, true, 0.0, true, 1.0 );
	g_cvStudioDist = CreateConVar( "sm_paint_studio_dist", "20.0","Distance in front of the eye used for studio props",_, true, 1.0 );

	RegConsoleCmd( "+paint",         Command_PaintStart, "Start painting"          );
	RegConsoleCmd( "-paint",         Command_PaintStop,  "Stop painting"           );
	RegConsoleCmd( "sm_paint",       Command_Menu,       "Open the paint menu"     );
	RegConsoleCmd( "sm_paintmenu",   Command_Menu,       "Open the paint menu"     );
	RegConsoleCmd( "sm_painttarget", Command_Target,     "Pick an entity to paint on" );
	RegConsoleCmd( "sm_paintfree",   Command_Free,       "Clear the target entity" );
	RegConsoleCmd( "sm_paintundo",   Command_Undo,       "Forget your last decal"  );
	RegConsoleCmd( "sm_paintclear",  Command_Clear,      "Forget all of your decals" );

	RegAdminCmd( "sm_paintsave", Command_Save, ADMFLAG_GENERIC, "Save this map's decals to disk" );
	RegAdminCmd( "sm_paintload", Command_Load, ADMFLAG_GENERIC, "Reload this map's decals from disk" );
	RegAdminCmd( "sm_paintwipe", Command_Wipe, ADMFLAG_GENERIC, "Forget every decal on this map" );

	HookEvent( "player_spawn", Event_PlayerSpawn );

	CreateTimer( 0.05, Timer_Paint,   _, TIMER_REPEAT);
	CreateTimer( 0.15, Timer_Flicker, _, TIMER_REPEAT);

	AutoExecConfig( true, "paint" );

	for( int i = 1; i <= MaxClients; i++ )
	{
		if( IsClientInGame( i ) )
			OnClientPutInServer( i );
	}
}

/* ------------------------------------------------------------------------- */
/* Precache                                                                   */
/* ------------------------------------------------------------------------- */

public void OnMapStart()
{
	char buffer[PLATFORM_MAX_PATH];

	for( int colour = 1; colour < sizeof( g_cPaintColours ); colour++ )
	{
		for( int size = 0; size < sizeof( g_cPaintSizes ); size++ )
		{
			Format( buffer, sizeof( buffer ), "decals/paint/%s%s.vmt", g_cPaintColours[colour][1], g_cPaintSizes[size][1] );
			g_Sprites[colour - 1][size] = PrecachePaint( buffer );

			if( g_Sprites[colour - 1][size] <= 0 )
				LogError( "Failed to precache decal '%s' - is the material installed?", buffer );
		}
	}

	g_hRecords.Clear();

	char map[PLATFORM_MAX_PATH];
	GetCurrentMap( map, sizeof( map ) );
	ReplaceString( map, sizeof( map ), "/",  "_" );
	ReplaceString( map, sizeof( map ), "\\", "_" );
	BuildPath( Path_SM, g_sMapFile, sizeof( g_sMapFile ), "data/paint/%s.txt", map );
}

public void OnConfigsExecuted()
{
	if( g_cvAutoLoad.BoolValue )
		CreateTimer( 1.0, Timer_AutoLoad, _, TIMER_FLAG_NO_MAPCHANGE );
}

public Action Timer_AutoLoad( Handle timer )
{
	LoadDecals();
	return Plugin_Stop;
}

public void OnMapEnd()
{
	if( g_cvAutoSave.BoolValue )
		SaveDecals();
}

stock int PrecachePaint( const char[] path )
{
	char download[PLATFORM_MAX_PATH];

	Format( download, sizeof( download ), "materials/%s", path );
	if( FileExists( download, true ) )
		AddFileToDownloadsTable( download );

	ReplaceString( download, sizeof( download ), ".vmt", ".vtf" );
	if( FileExists( download, true ) )
		AddFileToDownloadsTable( download );

	return PrecacheDecal( path, true );
}

/* ------------------------------------------------------------------------- */
/* Client state                                                               */
/* ------------------------------------------------------------------------- */

public void OnClientPutInServer( int client )
{
	g_iColour[client]     = 0;
	g_iSize[client]       = 0;
	g_iTarget[client]     = 0;
	g_iTargetProp[client] = -1;
	g_bPainting[client]   = false;
	g_bSynced[client]    = false;
	g_fLastPaint[client] = 0.0;
}

public void OnClientDisconnect( int client )
{
	ClearTarget( client );
	g_bPainting[client] = false;
	g_bSynced[client]   = false;
}

public void Event_PlayerSpawn( Event event, const char[] name, bool dontBroadcast )
{
	int client = GetClientOfUserId( event.GetInt( "userid" ) );

	if( client && !g_bSynced[client] )
	{
		g_bSynced[client] = true;
		CreateTimer( 1.0, Timer_SyncClient, GetClientUserId( client ), TIMER_FLAG_NO_MAPCHANGE );
	}
}

public Action Timer_SyncClient( Handle timer, any userid )
{
	int client = GetClientOfUserId( userid );

	if( client && IsClientInGame( client ) )
		ResendAll( client );

	return Plugin_Stop;
}

public void OnEntityDestroyed( int entity )
{
	if( entity <= 0 )
		return;

	int ref = EntIndexToEntRef( entity );

	for( int i = 1; i <= MaxClients; i++ )
	{
		if( g_iTarget[i] == ref )
			g_iTarget[i] = 0;
	}
}

/* ------------------------------------------------------------------------- */
/* Painting                                                                   */
/* ------------------------------------------------------------------------- */

public Action Command_PaintStart( int client, int args )
{
	if( !client )
		return Plugin_Handled;

	if( !CanPaint( client, true ) )
		return Plugin_Handled;

	g_bPainting[client] = true;
	DoPaint( client );

	return Plugin_Handled;
}

public Action Command_PaintStop( int client, int args )
{
	if( client )
		g_bPainting[client] = false;

	return Plugin_Handled;
}

public Action Timer_Paint( Handle timer )
{
	float now      = GetGameTime();
	float interval = g_cvInterval.FloatValue;

	for( int i = 1; i <= MaxClients; i++ )
	{
		if( !g_bPainting[i] || !IsClientInGame( i ) )
			continue;

		if( now - g_fLastPaint[i] < interval )
			continue;

		if( !CanPaint( i, false ) )
		{
			g_bPainting[i] = false;
			continue;
		}

		DoPaint( i );
	}

	return Plugin_Continue;
}

bool CanPaint( int client, bool notify )
{
	if( !g_cvEnabled.BoolValue )
	{
		if( notify ) PrintToChat( client, "\x04[Paint]\x01 Painting is disabled." );
		return false;
	}

	if( !HasPaintAccess( client ) )
	{
		if( notify ) PrintToChat( client, "\x04[Paint]\x01 You do not have access to painting." );
		return false;
	}

	if( !IsPlayerAlive( client ) )
	{
		if( notify ) PrintToChat( client, "\x04[Paint]\x01 You have to be alive to paint." );
		return false;
	}

	if( g_hRecords.Length >= g_cvMaxTotal.IntValue )
	{
		if( notify ) PrintToChat( client, "\x04[Paint]\x01 The map decal limit has been reached." );
		return false;
	}

	if( CountDecals( client ) >= g_cvMaxPlayer.IntValue )
	{
		if( notify ) PrintToChat( client, "\x04[Paint]\x01 You reached your personal decal limit." );
		return false;
	}

	return true;
}

void DoPaint( int client )
{
	float pos[3], angles[3], origin[3];
	GetClientEyePosition( client, pos );
	GetClientEyeAngles( client, angles );

	int hitEnt = 0;
	int hitbox = 0;
	int prop   = g_iTargetProp[client];
	int target = EntRefToEntIndex( g_iTarget[client] );

	if( prop >= 0 )
	{
		// A static prop is not an entity: the decal is addressed to the world
		// (m_nEntity 0) with the prop index carried in m_nHitbox. Nothing to
		// trace against either, so use the studio placement.
		float fw[3];
		GetAngleVectors( angles, fw, NULL_VECTOR, NULL_VECTOR );
		ScaleVector( fw, g_cvStudioDist.FloatValue );
		AddVectors( pos, fw, origin );

		hitEnt = 0;
		hitbox = prop + 1;
	}
	else if( target > 0 && IsValidEntity( target ) )
	{
		char model[PLATFORM_MAX_PATH];
		GetEntPropString( target, Prop_Data, "m_ModelName", model, sizeof( model ) );

		if( model[0] == '*' )
		{
			// Brush model: clip the ray against this entity only
			if( !TraceBrushEntity( target, pos, angles, origin ) )
			{
				PrintToChat( client, "\x04[Paint]\x01 You are not aiming at the selected brush." );
				return;
			}
		}
		else
		{
			// Studio model: no trace at all, just drop the decal in front of the eye
			float fw[3];
			GetAngleVectors( angles, fw, NULL_VECTOR, NULL_VECTOR );
			ScaleVector( fw, g_cvStudioDist.FloatValue );
			AddVectors( pos, fw, origin );
		}

		hitEnt = target;
	}
	else
	{
		Handle tr = TR_TraceRayFilterEx( pos, angles, MASK_SHOT, RayType_Infinite, TraceFilter_NoPlayers, client );

		if( !TR_DidHit( tr ) )
		{
			delete tr;
			return;
		}

		TR_GetEndPosition( origin, tr );
		hitEnt = TR_GetEntityIndex( tr );
		hitbox = TR_GetHitBoxIndex( tr );
		delete tr;

		if( hitEnt < 0 )
			hitEnt = 0;
	}

	int colour = g_iColour[client];
	if( colour == 0 )
		colour = GetRandomInt( 1, sizeof( g_cPaintColours ) - 1 );

	PaintRecord rec;
	rec.colour   = colour;
	rec.size     = g_iSize[client];
	rec.hitbox   = hitbox;
	rec.owner    = GetClientUserId( client );
	rec.entref   = ( hitEnt > 0 ) ? EntIndexToEntRef( hitEnt ) : 0;

	if( hitEnt > 0 )
	{
		rec.hammerid = GetEntProp( hitEnt, Prop_Data, "m_iHammerID" );
		GetEntityClassname( hitEnt, rec.classname, sizeof( rec.classname ) );
		GetEntPropString( hitEnt, Prop_Data, "m_ModelName", rec.model, sizeof( rec.model ) );
		WorldToLocal( hitEnt, origin, rec.pos );
		WorldToLocal( hitEnt, pos,    rec.start );
	}
	else
	{
		rec.hammerid = 0;
		strcopy( rec.classname, sizeof( rec.classname ), ( prop >= 0 ) ? "staticprop" : "worldspawn" );
		rec.model[0] = '\0';
		rec.pos   = origin;
		rec.start = pos;
	}

	g_hRecords.PushArray( rec );
	g_fLastPaint[client] = GetGameTime();

	SendDecal( g_Sprites[colour - 1][rec.size], origin, pos, hitEnt, hitbox );
}

void SendDecal( int index, const float origin[3], const float start[3], int entity, int hitbox, int client = 0 )
{
	if( index <= 0 )
		return;

	TE_Start( "Entity Decal" );
	TE_WriteVector( "m_vecOrigin", origin );
	TE_WriteVector( "m_vecStart",  start  );
	TE_WriteNum( "m_nEntity", entity );
	TE_WriteNum( "m_nHitbox", hitbox );
	TE_WriteNum( "m_nIndex",  index  );

	if( client )
		TE_SendToClient( client );
	else
		TE_SendToAll();
}

/**
 * Clips a ray against one brush entity. Nonsolid brushes (func_illusionary,
 * disabled func_brush, ...) are made solid for the duration of the trace.
 */
bool TraceBrushEntity( int entity, const float pos[3], const float angles[3], float origin[3] )
{
	int  solidType  = GetEntProp( entity, Prop_Send, "m_nSolidType" );
	int  solidFlags = GetEntProp( entity, Prop_Send, "m_usSolidFlags" );
	bool restore    = false;

	if( solidType == 0 || ( solidFlags & FSOLID_NOT_SOLID ) )
	{
		SetEntProp( entity, Prop_Send, "m_nSolidType",   SOLID_BSP );
		SetEntProp( entity, Prop_Send, "m_usSolidFlags", solidFlags & ~FSOLID_NOT_SOLID );
		restore = true;
	}

	TR_ClipRayToEntity( pos, angles, MASK_SHOT, RayType_Infinite, entity );

	bool hit = TR_DidHit();
	if( hit )
		TR_GetEndPosition( origin );

	if( restore )
	{
		SetEntProp( entity, Prop_Send, "m_nSolidType",   solidType  );
		SetEntProp( entity, Prop_Send, "m_usSolidFlags", solidFlags );
	}

	return hit;
}

public bool TraceFilter_NoPlayers( int entity, int mask, any data )
{
	return ( entity != data && ( entity < 1 || entity > MaxClients ) );
}

/* ------------------------------------------------------------------------- */
/* Menus                                                                      */
/* ------------------------------------------------------------------------- */

public Action Command_Menu( int client, int args )
{
	if( client )
		ShowMainMenu( client );

	return Plugin_Handled;
}

void ShowMainMenu( int client )
{
	char buffer[128];
	Menu menu = new Menu( MenuHandler_Main );
	menu.SetTitle( "Paint" );

	Format( buffer, sizeof( buffer ), "Colour: %s", g_cPaintColours[g_iColour[client]][0] );
	menu.AddItem( "colour", buffer );

	Format( buffer, sizeof( buffer ), "Size: %s", g_cPaintSizes[g_iSize[client]][0] );
	menu.AddItem( "size", buffer );

	int target = EntRefToEntIndex( g_iTarget[client] );
	if( g_iTargetProp[client] >= 0 )
	{
		Format( buffer, sizeof( buffer ), "Target: static prop #%d", g_iTargetProp[client] );
	}
	else if( target > 0 )
	{
		char classname[64];
		GetEntityClassname( target, classname, sizeof( classname ) );
		Format( buffer, sizeof( buffer ), "Target: %s (%d)", classname, target );
	}
	else
	{
		strcopy( buffer, sizeof( buffer ), "Target: free aim" );
	}
	menu.AddItem( "target", buffer );

	menu.AddItem( "free",  "Clear target (free aim)" );
	menu.AddItem( "undo",  "Undo last decal" );
	menu.AddItem( "clear", "Forget all my decals" );

	menu.ExitButton = true;
	menu.Display( client, MENU_TIME_FOREVER );
}

public int MenuHandler_Main( Menu menu, MenuAction action, int client, int param )
{
	if( action == MenuAction_End )
	{
		delete menu;
		return 0;
	}

	if( action != MenuAction_Select )
		return 0;

	char info[16];
	menu.GetItem( param, info, sizeof( info ) );

	if( StrEqual( info, "colour" ) )
		ShowColourMenu( client );
	else if( StrEqual( info, "size" ) )
		ShowSizeMenu( client );
	else if( StrEqual( info, "target" ) )
		ShowTargetMenu( client );
	else if( StrEqual( info, "free" ) )
	{
		ClearTarget( client );
		PrintToChat( client, "\x04[Paint]\x01 Target cleared, painting where you aim." );
		ShowMainMenu( client );
	}
	else if( StrEqual( info, "undo" ) )
	{
		UndoLast( client );
		ShowMainMenu( client );
	}
	else if( StrEqual( info, "clear" ) )
	{
		ClearOwned( client );
		ShowMainMenu( client );
	}

	return 0;
}

void ShowColourMenu( int client )
{
	char info[8];
	Menu menu = new Menu( MenuHandler_Colour );
	menu.SetTitle( "Paint colour" );

	for( int i = 0; i < sizeof( g_cPaintColours ); i++ )
	{
		IntToString( i, info, sizeof( info ) );
		menu.AddItem( info, g_cPaintColours[i][0] );
	}

	menu.ExitBackButton = true;
	menu.Display( client, MENU_TIME_FOREVER );
}

public int MenuHandler_Colour( Menu menu, MenuAction action, int client, int param )
{
	if( action == MenuAction_End )
	{
		delete menu;
	}
	else if( action == MenuAction_Cancel && param == MenuCancel_ExitBack )
	{
		ShowMainMenu( client );
	}
	else if( action == MenuAction_Select )
	{
		char info[8];
		menu.GetItem( param, info, sizeof( info ) );
		g_iColour[client] = StringToInt( info );
		ShowMainMenu( client );
	}

	return 0;
}

void ShowSizeMenu( int client )
{
	char info[8];
	Menu menu = new Menu( MenuHandler_Size );
	menu.SetTitle( "Paint size" );

	for( int i = 0; i < sizeof( g_cPaintSizes ); i++ )
	{
		IntToString( i, info, sizeof( info ) );
		menu.AddItem( info, g_cPaintSizes[i][0] );
	}

	menu.ExitBackButton = true;
	menu.Display( client, MENU_TIME_FOREVER );
}

public int MenuHandler_Size( Menu menu, MenuAction action, int client, int param )
{
	if( action == MenuAction_End )
	{
		delete menu;
	}
	else if( action == MenuAction_Cancel && param == MenuCancel_ExitBack )
	{
		ShowMainMenu( client );
	}
	else if( action == MenuAction_Select )
	{
		char info[8];
		menu.GetItem( param, info, sizeof( info ) );
		g_iSize[client] = StringToInt( info );
		ShowMainMenu( client );
	}

	return 0;
}

/* ------------------------------------------------------------------------- */
/* Target selection                                                           */
/* ------------------------------------------------------------------------- */

public Action Command_Target( int client, int args )
{
	if( client )
		ShowTargetMenu( client );

	return Plugin_Handled;
}

public Action Command_Free( int client, int args )
{
	if( client )
	{
		ClearTarget( client );
		PrintToChat( client, "\x04[Paint]\x01 Target cleared, painting where you aim." );
	}

	return Plugin_Handled;
}

void ShowTargetMenu( int client )
{
	float angles[3];
	GetClientEyePosition( client, g_fEnumEye );
	GetClientEyeAngles( client, angles );

	CollectEntitiesAlongRay( g_fEnumEye, angles );

	// Static props live in their own partition and are not CBaseEntity, so they
	// get their own pass: everything this returns is a static prop index by
	// construction, which is how we sidestep having no way to verify it.
	g_hPropList.Clear();
	g_bEnumStatic = true;
	TR_EnumerateEntities( g_fEnumEye, angles, PARTITION_STATIC_PROPS, RayType_Infinite, EnumCallback_Static );
	g_bEnumStatic = false;

	if( !g_hEnumList.Length && !g_hPropList.Length )
	{
		PrintToChat( client, "\x04[Paint]\x01 Nothing found along your view." );
		return;
	}

	g_hEnumList.SortCustom( SortEnumByDistance );

	char info[16], display[160], classname[64], targetname[64], model[PLATFORM_MAX_PATH];
	Menu menu = new Menu( MenuHandler_Target );
	menu.SetTitle( "Entities along your view" );

	for( int i = 0; i < g_hEnumList.Length; i++ )
	{
		int entity = g_hEnumList.Get( i );

		if( !IsValidEntity( entity ) )
			continue;

		GetEntityClassname( entity, classname, sizeof( classname ) );
		GetEntPropString( entity, Prop_Data, "m_ModelName", model, sizeof( model ) );

		targetname[0] = '\0';
		if( HasEntProp( entity, Prop_Data, "m_iName" ) )
			GetEntPropString( entity, Prop_Data, "m_iName", targetname, sizeof( targetname ) );

		float center[3];
		GetEntityCenter( entity, center );

		Format( display, sizeof( display ), "%s%s%s%s [%s] %.0fu",
			classname,
			targetname[0] ? " \"" : "", targetname[0] ? targetname : "", targetname[0] ? "\"" : "",
			model[0] == '*' ? "brush" : "model",
			GetVectorDistance( g_fEnumEye, center ) );

		Format( info, sizeof( info ), "e%d", EntIndexToEntRef( entity ) );
		menu.AddItem( info, display );
	}

	// No origin or model name available for these without parsing the BSP's
	// sprp game lump, so they are listed in enumeration order.
	for( int i = 0; i < g_hPropList.Length; i++ )
	{
		int index = g_hPropList.Get( i );

		Format( info,    sizeof( info ),    "p%d", index );
		Format( display, sizeof( display ), "static prop #%d", index );
		menu.AddItem( info, display );
	}

	menu.AddItem( "x", "Free aim (no target)" );
	menu.ExitBackButton = true;
	menu.Display( client, MENU_TIME_FOREVER );
}

public bool EnumCallback_Static( int index, any data )
{
	if( g_bEnumStatic && g_hPropList.FindValue( index ) == -1 )
		g_hPropList.Push( index );

	return true;
}

/**
 * TR_EnumerateEntities only reports what the engine put in the spatial
 * partition, and SOLID_NONE entities are usually not in it at all (unless they
 * carry EFL_USE_PARTITION_WHEN_NOT_SOLID). Static props are never reported
 * either - they are not entities. So for the picker we ignore the partition
 * completely and do our own ray/AABB sweep over every entity with a model.
 */
void CollectEntitiesAlongRay( const float start[3], const float angles[3] )
{
	float dir[3], origin[3], mins[3], maxs[3], dist;
	char  model[PLATFORM_MAX_PATH];

	GetAngleVectors( angles, dir, NULL_VECTOR, NULL_VECTOR );
	g_hEnumList.Clear();

	int max = GetMaxEntities();

	for( int entity = MaxClients + 1; entity < max; entity++ )
	{
		if( !IsValidEntity( entity ) )
			continue;

		// No model means nothing to paint on (logic entities, relays, ...)
		GetEntPropString( entity, Prop_Data, "m_ModelName", model, sizeof( model ) );
		if( !model[0] )
			continue;

		if( !HasEntProp( entity, Prop_Send, "m_vecMins" ) )
			continue;

		GetEntPropVector( entity, Prop_Data, "m_vecAbsOrigin", origin );
		GetEntPropVector( entity, Prop_Send,  "m_vecMins",     mins   );
		GetEntPropVector( entity, Prop_Send,  "m_vecMaxs",     maxs   );

		// Axis aligned test, plus a little padding for flat/zero sized bounds
		for( int i = 0; i < 3; i++ )
		{
			mins[i] += origin[i] - 4.0;
			maxs[i] += origin[i] + 4.0;
		}

		if( RayHitsBox( start, dir, mins, maxs, dist ) )
			g_hEnumList.Push( entity );
	}
}

bool RayHitsBox( const float start[3], const float dir[3], const float mins[3], const float maxs[3], float &dist )
{
	float tmin = 0.0;
	float tmax = 1000000.0;

	for( int i = 0; i < 3; i++ )
	{
		if( FloatAbs( dir[i] ) < 0.000001 )
		{
			if( start[i] < mins[i] || start[i] > maxs[i] )
				return false;

			continue;
		}

		float inv = 1.0 / dir[i];
		float t1  = ( mins[i] - start[i] ) * inv;
		float t2  = ( maxs[i] - start[i] ) * inv;

		if( t1 > t2 )
		{
			float swap = t1;
			t1 = t2;
			t2 = swap;
		}

		if( t1 > tmin ) tmin = t1;
		if( t2 < tmax ) tmax = t2;

		if( tmin > tmax )
			return false;
	}

	dist = tmin;
	return true;
}

public int SortEnumByDistance( int index1, int index2, Handle array, Handle hndl )
{
	ArrayList list = view_as<ArrayList>( array );

	float a[3], b[3];
	GetEntityCenter( list.Get( index1 ), a );
	GetEntityCenter( list.Get( index2 ), b );

	float da = GetVectorDistance( g_fEnumEye, a );
	float db = GetVectorDistance( g_fEnumEye, b );

	return ( da > db ) ? 1 : ( ( da < db ) ? -1 : 0 );
}

public int MenuHandler_Target( Menu menu, MenuAction action, int client, int param )
{
	if( action == MenuAction_End )
	{
		delete menu;
		return 0;
	}

	if( action == MenuAction_Cancel && param == MenuCancel_ExitBack )
	{
		ShowMainMenu( client );
		return 0;
	}

	if( action != MenuAction_Select )
		return 0;

	char info[16];
	menu.GetItem( param, info, sizeof( info ) );

	ClearTarget( client );

	if( info[0] == 'p' )
	{
		g_iTargetProp[client] = StringToInt( info[1] );

		// No SetTransmit for something that is not an entity, so no highlight
		PrintToChat( client, "\x04[Paint]\x01 Target set to \x03static prop #%d\x01. Paint lands where you aim, %.0fu out.",
			g_iTargetProp[client], g_cvStudioDist.FloatValue );
	}
	else if( info[0] == 'e' )
	{
		int ref    = StringToInt( info[1] );
		int entity = EntRefToEntIndex( ref );

		if( entity > 0 && IsValidEntity( entity ) )
		{
			g_iTarget[client] = ref;
			SDKHook( entity, SDKHook_SetTransmit, Hook_SetTransmit );

			char classname[64];
			GetEntityClassname( entity, classname, sizeof( classname ) );
			PrintToChat( client, "\x04[Paint]\x01 Target set to \x03%s\x01 (%d). It will flicker for you.", classname, entity );
		}
		else
		{
			PrintToChat( client, "\x04[Paint]\x01 That entity is gone." );
		}
	}
	else
	{
		PrintToChat( client, "\x04[Paint]\x01 Painting where you aim." );
	}

	ShowMainMenu( client );
	return 0;
}

void ClearTarget( int client )
{
	int entity = EntRefToEntIndex( g_iTarget[client] );
	int ref    = g_iTarget[client];

	g_iTarget[client]     = 0;
	g_iTargetProp[client] = -1;

	if( entity <= 0 || !IsValidEntity( entity ) )
		return;

	// Only unhook once nobody else is highlighting this entity
	for( int i = 1; i <= MaxClients; i++ )
	{
		if( g_iTarget[i] == ref )
			return;
	}

	SDKUnhook( entity, SDKHook_SetTransmit, Hook_SetTransmit );
}

public Action Hook_SetTransmit( int entity, int client )
{
	if( !g_bFlicker && g_iTarget[client] == EntIndexToEntRef( entity ) )
		return Plugin_Handled;

	return Plugin_Continue;
}

public Action Timer_Flicker( Handle timer )
{
	g_bFlicker = !g_bFlicker;
	return Plugin_Continue;
}

/* ------------------------------------------------------------------------- */
/* Record management                                                          */
/* ------------------------------------------------------------------------- */

int CountDecals( int client )
{
	int userid = GetClientUserId( client );
	int count  = 0;

	PaintRecord rec;
	for( int i = 0; i < g_hRecords.Length; i++ )
	{
		g_hRecords.GetArray( i, rec );
		if( rec.owner == userid )
			count++;
	}

	return count;
}

public Action Command_Undo( int client, int args )
{
	if( client )
		UndoLast( client );

	return Plugin_Handled;
}

void UndoLast( int client )
{
	int userid = GetClientUserId( client );

	PaintRecord rec;
	for( int i = g_hRecords.Length - 1; i >= 0; i-- )
	{
		g_hRecords.GetArray( i, rec );

		if( rec.owner == userid )
		{
			g_hRecords.Erase( i );
			PrintToChat( client, "\x04[Paint]\x01 Last decal forgotten. Type \x03r_cleardecals\x01 in console to refresh your view." );
			return;
		}
	}

	PrintToChat( client, "\x04[Paint]\x01 You have not painted anything yet." );
}

public Action Command_Clear( int client, int args )
{
	if( client )
		ClearOwned( client );

	return Plugin_Handled;
}

void ClearOwned( int client )
{
	int userid = GetClientUserId( client );
	int count  = 0;

	PaintRecord rec;
	for( int i = g_hRecords.Length - 1; i >= 0; i-- )
	{
		g_hRecords.GetArray( i, rec );

		if( rec.owner == userid )
		{
			g_hRecords.Erase( i );
			count++;
		}
	}

	PrintToChat( client, "\x04[Paint]\x01 Forgot %d decal(s). Type \x03r_cleardecals\x01 in console to refresh your view.", count );
}

public Action Command_Wipe( int client, int args )
{
	g_hRecords.Clear();
	ReplyToCommand( client, "[Paint] All decal records wiped. Clients keep what is already drawn until r_cleardecals." );
	return Plugin_Handled;
}

void ResendAll( int client )
{
	PaintRecord rec;
	float origin[3], start[3];

	for( int i = 0; i < g_hRecords.Length; i++ )
	{
		g_hRecords.GetArray( i, rec );

		int entity = EntRefToEntIndex( rec.entref );

		if( rec.entref && ( entity <= 0 || !IsValidEntity( entity ) ) )
			continue;

		if( entity > 0 )
		{
			LocalToWorld( entity, rec.pos,   origin );
			LocalToWorld( entity, rec.start, start  );
		}
		else
		{
			entity = 0;
			origin = rec.pos;
			start  = rec.start;
		}

		SendDecal( g_Sprites[rec.colour - 1][rec.size], origin, start, entity, rec.hitbox, client );
	}
}

/* ------------------------------------------------------------------------- */
/* Save / load                                                                */
/* ------------------------------------------------------------------------- */

public Action Command_Save( int client, int args )
{
	int count = SaveDecals();
	ReplyToCommand( client, "[Paint] Saved %d decal(s) to %s", count, g_sMapFile );
	return Plugin_Handled;
}

public Action Command_Load( int client, int args )
{
	int count = LoadDecals();
	ReplyToCommand( client, "[Paint] Loaded %d decal(s)", count );
	return Plugin_Handled;
}

int SaveDecals()
{
	char dir[PLATFORM_MAX_PATH];
	BuildPath( Path_SM, dir, sizeof( dir ), "data/paint" );

	if( !DirExists( dir ) )
		CreateDirectory( dir, 511 );

	KeyValues kv = new KeyValues( "paint" );
	PaintRecord rec;
	char key[16], buffer[64];
	int count = 0;

	for( int i = 0; i < g_hRecords.Length; i++ )
	{
		g_hRecords.GetArray( i, rec );

		IntToString( count, key, sizeof( key ) );
		kv.JumpToKey( key, true );

		kv.SetString( "colour",   g_cPaintColours[rec.colour][1] );
		kv.SetString( "size",     g_cPaintSizes[rec.size][1]     );
		kv.SetNum(    "hammerid", rec.hammerid );
		kv.SetNum(    "hitbox",   rec.hitbox   );
		kv.SetString( "class",    rec.classname );
		kv.SetString( "model",    rec.model     );

		Format( buffer, sizeof( buffer ), "%f %f %f", rec.pos[0], rec.pos[1], rec.pos[2] );
		kv.SetString( "pos", buffer );

		Format( buffer, sizeof( buffer ), "%f %f %f", rec.start[0], rec.start[1], rec.start[2] );
		kv.SetString( "start", buffer );

		kv.GoBack();
		count++;
	}

	kv.Rewind();
	kv.ExportToFile( g_sMapFile );
	delete kv;

	return count;
}

int LoadDecals()
{
	if( !FileExists( g_sMapFile ) )
		return 0;

	KeyValues kv = new KeyValues( "paint" );

	if( !kv.ImportFromFile( g_sMapFile ) || !kv.GotoFirstSubKey() )
	{
		delete kv;
		return 0;
	}

	// Drop everything that came from disk before, keep what players painted this map
	PaintRecord tmp;
	for( int i = g_hRecords.Length - 1; i >= 0; i-- )
	{
		g_hRecords.GetArray( i, tmp );
		if( !tmp.owner )
			g_hRecords.Erase( i );
	}

	int count = 0;
	char buffer[PLATFORM_MAX_PATH];

	do
	{
		PaintRecord rec;

		kv.GetString( "colour", buffer, sizeof( buffer ) );
		rec.colour = FindColour( buffer );

		kv.GetString( "size", buffer, sizeof( buffer ) );
		rec.size = FindSize( buffer );

		if( rec.colour < 1 || rec.size < 0 )
			continue;

		rec.hammerid = kv.GetNum( "hammerid" );
		rec.hitbox   = kv.GetNum( "hitbox" );
		rec.owner    = 0;
		kv.GetString( "class", rec.classname, sizeof( rec.classname ) );
		kv.GetString( "model", rec.model,     sizeof( rec.model )     );

		kv.GetString( "pos", buffer, sizeof( buffer ) );
		StringToVector( buffer, rec.pos );

		kv.GetString( "start", buffer, sizeof( buffer ) );
		StringToVector( buffer, rec.start );

		int entity = 0;

		if( rec.hammerid || rec.model[0] )
		{
			entity = FindEntity( rec.hammerid, rec.classname, rec.model );

			if( entity <= 0 )
			{
				LogMessage( "[Paint] Skipping decal: entity '%s' (hammerid %d) not found on this map.", rec.classname, rec.hammerid );
				continue;
			}
		}

		rec.entref = ( entity > 0 ) ? EntIndexToEntRef( entity ) : 0;
		g_hRecords.PushArray( rec );

		float origin[3], start[3];
		if( entity > 0 )
		{
			LocalToWorld( entity, rec.pos,   origin );
			LocalToWorld( entity, rec.start, start  );
		}
		else
		{
			origin = rec.pos;
			start  = rec.start;
		}

		SendDecal( g_Sprites[rec.colour - 1][rec.size], origin, start, entity, rec.hitbox );
		count++;
	}
	while( kv.GotoNextKey() );

	delete kv;
	return count;
}

int FindColour( const char[] material )
{
	for( int i = 1; i < sizeof( g_cPaintColours ); i++ )
	{
		if( StrEqual( g_cPaintColours[i][1], material ) )
			return i;
	}

	return -1;
}

int FindSize( const char[] suffix )
{
	for( int i = 0; i < sizeof( g_cPaintSizes ); i++ )
	{
		if( StrEqual( g_cPaintSizes[i][1], suffix ) )
			return i;
	}

	return -1;
}

/**
 * Matches a saved record back to a live entity. hammerid is the map-compiled
 * id, so it survives recompiles far better than an entity index does; the
 * classname and model are used as a sanity check.
 */
int FindEntity( int hammerid, const char[] classname, const char[] model )
{
	char buffer[PLATFORM_MAX_PATH];

	for( int entity = MaxClients + 1; entity < GetMaxEntities(); entity++ )
	{
		if( !IsValidEntity( entity ) )
			continue;

		if( hammerid && GetEntProp( entity, Prop_Data, "m_iHammerID" ) != hammerid )
			continue;

		GetEntityClassname( entity, buffer, sizeof( buffer ) );
		if( !StrEqual( buffer, classname ) )
			continue;

		if( model[0] )
		{
			GetEntPropString( entity, Prop_Data, "m_ModelName", buffer, sizeof( buffer ) );
			if( !StrEqual( buffer, model ) )
				continue;
		}

		return entity;
	}

	return -1;
}

/* ------------------------------------------------------------------------- */
/* Helpers                                                                    */
/* ------------------------------------------------------------------------- */

void WorldToLocal( int entity, const float world[3], float local[3] )
{
	float entpos[3], entang[3], diff[3], fw[3], right[3], up[3];

	GetEntPropVector( entity, Prop_Data, "m_vecAbsOrigin",    entpos );
	GetEntPropVector( entity, Prop_Data, "m_angAbsRotation",  entang );

	SubtractVectors( world, entpos, diff );
	GetAngleVectors( entang, fw, right, up );

	local[0] = GetVectorDotProduct( diff, fw    );
	local[1] = GetVectorDotProduct( diff, right );
	local[2] = GetVectorDotProduct( diff, up    );
}

void LocalToWorld( int entity, const float local[3], float world[3] )
{
	float entpos[3], entang[3], fw[3], right[3], up[3];

	GetEntPropVector( entity, Prop_Data, "m_vecAbsOrigin",   entpos );
	GetEntPropVector( entity, Prop_Data, "m_angAbsRotation", entang );

	GetAngleVectors( entang, fw, right, up );

	ScaleVector( fw,    local[0] );
	ScaleVector( right, local[1] );
	ScaleVector( up,    local[2] );

	AddVectors( entpos, fw,    world );
	AddVectors( world,  right, world );
	AddVectors( world,  up,    world );
}

void GetEntityCenter( int entity, float center[3] )
{
	float mins[3], maxs[3];

	GetEntPropVector( entity, Prop_Data, "m_vecAbsOrigin", center );

	if( HasEntProp( entity, Prop_Send, "m_vecMins" ) )
	{
		GetEntPropVector( entity, Prop_Send, "m_vecMins", mins );
		GetEntPropVector( entity, Prop_Send, "m_vecMaxs", maxs );

		for( int i = 0; i < 3; i++ )
			center[i] += ( mins[i] + maxs[i] ) * 0.5;
	}
}

void StringToVector( const char[] input, float out[3] )
{
	char parts[3][16];
	ExplodeString( input, " ", parts, sizeof( parts ), sizeof( parts[] ) );

	for( int i = 0; i < 3; i++ )
		out[i] = StringToFloat( parts[i] );
}

bool HasPaintAccess( int client )
{
	char flags[16];
	g_cvFlag.GetString( flags, sizeof( flags ) );

	if( !flags[0] )
		return true;

	AdminFlag flag;
	if( !FindFlagByChar( flags[0], flag ) )
		return true;

	int bits = GetUserFlagBits( client );

	return ( bits & ADMFLAG_ROOT ) != 0 || ( bits & FlagToBit( flag ) ) != 0;
}

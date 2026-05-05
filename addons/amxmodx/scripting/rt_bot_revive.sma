#include <amxmodx>
#include <fakemeta>
#include <reapi>
#include <rt_api>

public stock const PLUGIN[] = "Revive Teammates: Bot Revive";
public stock const CFG_FILE[] = "addons/amxmodx/configs/rt_configs/rt_bot_revive.cfg";

/*
 * rt_bot_revive — automatic revival for CS 1.6 ZBots
 *
 * Each living bot periodically scans for the nearest dead teammate
 * corpse within its search radius and, if found, initiates the revive
 * via rt_activate_corpse().  This goes through the exact same
 * Corpse_Use() code path that a human pressing USE would follow, so
 * all restrictions (rt_restrictions, rt_timer, costs, round checks,
 * etc.) are fully respected.
 *
 * During the revive the bot's var_button is OR-ed with IN_USE every
 * PreThink so that Corpse_Think does not cancel the process.
 */

enum CVARS {
	BOT_ENABLE,
	Float:BOT_THINK_INTERVAL,
	Float:BOT_RADIUS_MULT
};

new g_eCvars[CVARS];

/* True while a bot has an active revive/plant in progress */
new bool:g_bBotReviving[MAX_PLAYERS + 1];

#define TASK_BOT_SCAN 13370

public plugin_precache() {
	CreateCvars();

	server_cmd("exec %s", CFG_FILE);
	server_exec();
}

public plugin_init() {
	register_plugin(PLUGIN, VERSION, AUTHORS);

	register_dictionary("rt_library.txt");

	/* Keep IN_USE held for bots that are actively reviving */
	RegisterHookChain(RG_CBasePlayer_PreThink, "CBasePlayer_PreThink_BotRevive", false);

	/* Clear state between rounds */
	RegisterHookChain(RG_CSGameRules_CleanUpMap, "CSGameRules_CleanUpMap_Post", true);
}

public plugin_cfg() {
	/* Start the repeating scan task with the configured interval.
	   bind_pcvar_float already clamps to the declared minimum (0.1 s). */
	set_task(g_eCvars[BOT_THINK_INTERVAL], "BotReviveScan", TASK_BOT_SCAN, _, _, "b");
}

/* ── forward hooks ──────────────────────────────────────────────────── */

public client_disconnected(const iPlayer) {
	g_bBotReviving[iPlayer] = false;
}

public CSGameRules_CleanUpMap_Post() {
	arrayset(g_bBotReviving, false, sizeof(g_bBotReviving));
}

/**
 * Mark bot as actively reviving once the process successfully starts.
 */
public rt_revive_start_post(const iEnt, const iPlayer, const iActivator, const Modes:eMode) {
	if(is_user_bot(iActivator))
		g_bBotReviving[iActivator] = true;
}

/**
 * Clear reviving flag when the process ends normally.
 */
public rt_revive_end(const iEnt, const iPlayer, const iActivator, const Modes:eMode) {
	if(iActivator != RT_NULLENT)
		g_bBotReviving[iActivator] = false;
}

/**
 * Clear reviving flag when the process is cancelled for any reason.
 */
public rt_revive_cancelled(const iEnt, const iPlayer, const iActivator, const Modes:eMode) {
	if(iActivator != RT_NULLENT)
		g_bBotReviving[iActivator] = false;
}

/* ── PreThink: simulate holding USE for reviving bots ───────────────── */

public CBasePlayer_PreThink_BotRevive(const iPlayer) {
	if(!g_bBotReviving[iPlayer])
		return;

	if(!is_user_alive(iPlayer)) {
		/* Bot died — the revive will be cancelled by Corpse_Think on the
		   next entity tick; just clear our own flag proactively. */
		g_bBotReviving[iPlayer] = false;
		return;
	}

	/* Hold the USE button so Corpse_Think does not cancel the revive */
	set_entvar(iPlayer, var_button, get_entvar(iPlayer, var_button) | IN_USE);
}

/* ── Periodic scan ──────────────────────────────────────────────────── */

/**
 * Scan all living bots that are not already reviving and attempt to
 * start a revive for each one that has a dead teammate corpse nearby.
 */
public BotReviveScan() {
	if(!g_eCvars[BOT_ENABLE])
		return;

	new rgPlayers[MAX_PLAYERS], iCount;
	get_players(rgPlayers, iCount, "a"); /* alive players */

	for(new i = 0; i < iCount; i++) {
		new iBot = rgPlayers[i];

		if(!is_user_bot(iBot))
			continue;

		/* Skip bots already tracked as reviving, or already in a mode
		   as reported by rt_core (e.g., activated via UseEmpty naturally) */
		if(g_bBotReviving[iBot] || rt_get_user_mode(iBot) != MODE_NONE)
			continue;

		new iCorpse = BotFindNearestCorpse(iBot);
		if(!iCorpse)
			continue;

		/* Activates via the identical Corpse_Use() path a human uses */
		rt_activate_corpse(iCorpse, iBot);
	}
}

/* ── Helper: nearest unoccupied dead teammate corpse ────────────────── */

BotFindNearestCorpse(const iBot) {
	new Float:fBotOrigin[3];
	get_entvar(iBot, var_origin, fBotOrigin);

	new TeamName:iBotTeam = TeamName:get_member(iBot, m_iTeam);
	if(iBotTeam != TEAM_TERRORIST && iBotTeam != TEAM_CT)
		return 0;

	new iBest = 0;
	new Float:fBestDist = -1.0;

	new iEnt = RT_NULLENT;
	while((iEnt = rg_find_ent_by_class(iEnt, DEAD_BODY_CLASSNAME)) > 0) {
		/* Skip corpses already being revived by someone */
		if(get_entvar(iEnt, var_iuser1))
			continue;

		/* Team match (corpse stores its owner's team at creation time) */
		if(TeamName:get_entvar(iEnt, var_team) != iBotTeam)
			continue;

		/* Owner must still be connected */
		new iOwner = get_entvar(iEnt, var_owner);
		if(!is_user_connected(iOwner))
			continue;

		/* Distance check using the per-corpse stored search radius,
		   scaled by the multiplier cvar */
		new Float:fRadius = Float:get_entvar(iEnt, var_fuser2) * g_eCvars[BOT_RADIUS_MULT];

		new Float:fEntOrigin[3];
		get_entvar(iEnt, var_vuser4, fEntOrigin);

		new Float:fDist = vector_distance(fBotOrigin, fEntOrigin);

		if(fDist <= fRadius && (fBestDist < 0.0 || fDist < fBestDist)) {
			fBestDist = fDist;
			iBest = iEnt;
		}
	}

	return iBest;
}

/* ── Cvar creation ──────────────────────────────────────────────────── */

public CreateCvars() {
	bind_pcvar_num(create_cvar(
		"rt_bot_enable",
		"1",
		FCVAR_NONE,
		"Enable automatic bot revive behaviour. 0 - disabled, 1 - enabled",
		true,
		0.0,
		true,
		1.0),
		g_eCvars[BOT_ENABLE]
	);
	bind_pcvar_float(create_cvar(
		"rt_bot_think_interval",
		"0.8",
		FCVAR_NONE,
		"How often (in seconds) each living bot scans for a dead teammate to revive",
		true,
		0.1),
		g_eCvars[BOT_THINK_INTERVAL]
	);
	bind_pcvar_float(create_cvar(
		"rt_bot_radius_mult",
		"1.0",
		FCVAR_NONE,
		"Multiplier applied to rt_search_radius when bots scan for corpses. 1.0 = same as human range",
		true,
		0.1),
		g_eCvars[BOT_RADIUS_MULT]
	);
}

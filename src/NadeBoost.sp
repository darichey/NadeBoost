#pragma newdecls required

#include <sourcemod>
#include <sdkhooks.inc>
#include <sdktools_functions>
#include <cstrike.inc>

public Plugin myinfo = {
    name = "NadeBoost",
    author = "Grand Panda",
    description = "Push people around with grenades",
    version = "0.1",
    url = "https://github.com/GrandPanda/NadeBoost"
}

const int EXPLOSION_RADIUS = 384; // https://counterstrike.fandom.com/wiki/HE_Grenade
const int EXPLOSION_RADIUS_SQ = EXPLOSION_RADIUS * EXPLOSION_RADIUS; // squared for optimization

ConVar enabled;
ConVar boostScale;
ConVar grenadeVelocity;
ConVar replenishGrenades;

Handle playerTimers[MAXPLAYERS];

public void OnPluginStart() {
    enabled = CreateConVar("nadeboost_enabled",
                        "1",
                        "Whether grenade boosting is enabled.");

    boostScale = CreateConVar("nadeboost_boost_scale",
                        "2.5",
                        "Scales the velocity a player receives from a grenade.",
                        _,
                        true,
                        0.0);

    grenadeVelocity = CreateConVar("nadeboost_grenade_velocity",
                        "1000",
                        "Scales the velocity of a grenade when it is thrown.",
                        _,
                        true,
                        0.0);

    replenishGrenades = CreateConVar("nadeboost_replenish_grenades",
                        "15",
                        "The time (in seconds) when players should receive another grenade. (\"0\" to disable)",
                        _,
                        true,
                        0.0);

    HookEvent("player_spawn", OnPlayerSpawn);
    HookEvent("weapon_fire", OnWeaponFire);
    HookEvent("round_prestart", OnRoundPreStart);
}

public void OnEntityCreated(int entity, const char[] classname) {
    if (enabled.BoolValue && StrEqual(classname, "hegrenade_projectile")) {
        /*
        Hook when a grenade spawns and when it touches something. We need to
          1. Set its velocity when it spawns
          2. Make it detonate on first impact
        */
        SDKHook(entity, SDKHook_SpawnPost, OnGrenadeSpawn);
        SDKHook(entity, SDKHook_StartTouch, OnGrenadeTouch);
    }
}

Action OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    // Give players a grenade on spawn, if it's enabled.
    if (enabled.BoolValue && replenishGrenades.FloatValue > 0.0) {
        int client = GetClientOfUserId(event.GetInt("userid"));

        // Remove any grenades from the player's inventory and start the initial timer
        SetEntProp(client, Prop_Send, "m_iAmmo", 0, _, 14);
        StartGrenadeTimerForClient(client);
    }

    return Plugin_Continue;
}

Action OnWeaponFire(Event event, const char[] eventName, bool dontBroadcast) {
    // Start a timer to give the player a new grenade if enabled when they throw theirs
    if (enabled.BoolValue && replenishGrenades.FloatValue > 0.0) {
        char name[17];
        event.GetString("weapon", name, 17);
        if (StrEqual(name, "weapon_hegrenade")) {
            StartGrenadeTimerForClient(GetClientOfUserId(event.GetInt("userid")));
        }
    }

    return Plugin_Continue;
}

Action OnRoundPreStart(Event event, const char[] eventName, bool dontBroadcast) {
    // Remove all existing timers so everyone gets a new timer when they spawn
    for (int client = 1; client <= MaxClients; client++) {
        RemoveTimer(client);
    }
}

void OnGrenadeSpawn(int entity) {
    // We need to do our spawn logic on the *next* frame because none of its data is set on the frame that it spawns.
    RequestFrame(FrameOnGrenadeSpawn, EntIndexToEntRef(entity));
}

void FrameOnGrenadeSpawn(int entityRef) {
    int entity = EntRefToEntIndex(entityRef);
    if(entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity))
        return;

    // Make the grenade ignore gravity
    SetEntityMoveType(entity, MOVETYPE_FLY); 

    // Get the direction the thrower is facing and scale to configured length. This is the new velocity of the grenade.
    float velocity[3];
    GetFacingDirection(GetEntPropEnt(entity, Prop_Data, "m_hThrower"), velocity);
    ScaleVector(velocity, grenadeVelocity.FloatValue);

    // Apply the new velocity to the grenade
    TeleportEntity(entity, NULL_VECTOR, NULL_VECTOR, velocity);
}

Action OnGrenadeTouch(int entity, int other) {
    DetonateGrenade(entity);

    // Get the grenade's position
    float grenadePos[3];
    GetEntPropVector(entity, Prop_Data, "m_vecOrigin", grenadePos);

    // For every alive player (including bots)
    for (int client = 1; client <= MaxClients; client++) {
        if (IsClientInGame(client) && IsPlayerAlive(client)) {
            // Get the position of the player
            float playerPos[3];
            GetClientAbsOrigin(client, playerPos);

            // Check if they are within range of the grenade
            float distance = GetVectorDistance(grenadePos, playerPos, true);
            if (distance <= EXPLOSION_RADIUS_SQ) {
                // Get a vector from the grenade to the player
                float grenadeToPlayer[3];
                SubtractVectors(grenadePos, playerPos, grenadeToPlayer);

                // Get a vector of maximum length in that direction. Goes from grenade to edge of the circle
                float grenadeToEdge[3];
                NormalizeVector(grenadeToPlayer, grenadeToEdge);
                ScaleVector(grenadeToEdge, float(EXPLOSION_RADIUS));

                // Get a vector from the player to the edge of the circle
                float playerToEdge[3];
                SubtractVectors(grenadeToPlayer, grenadeToEdge, playerToEdge);

                // Scale according to configuration.
                ScaleVector(playerToEdge, boostScale.FloatValue);

                // Get the players current velocity vector
                float velocity[3];
                GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);

                // Calculate and apply the new velocity of the player
                AddVectors(velocity, playerToEdge, velocity);
                TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, velocity);
            }
        }
    }

    return Plugin_Continue;
}

void GetFacingDirection(int client, float result[3]) {
    GetClientEyeAngles(client, result);
    GetAngleVectors(result, result, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(result, result);
}

void DetonateGrenade(int entity) {
    SetEntProp(entity, Prop_Data, "m_takedamage", 2);
    SetEntProp(entity, Prop_Data, "m_iHealth", 1);
    SDKHooks_TakeDamage(entity, 0, 0, 1.0);
}

void GiveGrenade(int client) {
    // Get the number of grenades the client has. 14 is the offset for HE Grenades. 
    // https://github.com/alliedmodders/sourcemod/issues/665#issuecomment-326084942
    int grenadeCount = GetEntProp(client, Prop_Data, "m_iAmmo", _, 14);
    if (grenadeCount == 0) {
        GivePlayerItem(client, "weapon_hegrenade");
    }
}

void StartGrenadeTimerForClient(int client) {
    if (!HasTimer(client)) {
        // Pass the client ID to the callback
        DataPack pack = CreateDataPack();
        pack.WriteCell(client);
        pack.Reset();
        SetTimer(client, CreateTimer(replenishGrenades.FloatValue, ReplenishGrenades, pack));
    }
}

Action ReplenishGrenades(Handle timer, DataPack pack) {
    int client = pack.ReadCell();

    // They might've died or left since they threw the grenade
    if (IsClientInGame(client) && IsPlayerAlive(client)) {
        GiveGrenade(client);
    }

    // Do this regardless of if they are in game/alive Just for completeness. We don't want extra garbage data in the array.
    // This is *not* the same as RemoveTimer() because SourceMod doesnt provide a way to close an already-closed Handle
    SetTimer(client, INVALID_HANDLE);
    return Plugin_Continue;
}

Handle GetTimer(int client) {
    return playerTimers[client];
}

bool HasTimer(int client) {
    return GetTimer(client) != INVALID_HANDLE;
}

void SetTimer(int client, Handle timer) {
    playerTimers[client] = timer;
}

void RemoveTimer(int client) {
    CloseHandle(GetTimer(client));
    SetTimer(client, INVALID_HANDLE);
}
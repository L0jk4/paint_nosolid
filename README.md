https://github.com/user-attachments/assets/9d245fb5-caf9-4ea1-a460-658b5616cb4a

# Description

A *proof of concept* SourceMod plugin made with Claude based on my findings. It allows players to paint even on non-solid objects such as displacements, triggers, static props, dynamic props, func_brush entities, etc.

## Note
For non-solid static props to be visible to `TR_EnumerateEntities` a patch is required, which is implemented only for x86 Windows Counter-Strike: Source (as all the other patches and signatures). It shouldn't have a significant impact on server performance, since they will still be filtered out rather early in the collision pipeline. If it still bothers somebody, you can detour the whole function and insert such props without solid_edict flag.

 ## Concept

 ### Baseline (free aim mode)
 `+paint` command performs a trace forward and sends an `Entity Decal` temporary entity to the client, which works for pretty much everything visible and solid. Additionally I made it hit non-solid displacements by patching out a few checks for the duration of painting.

 ### Non-solid entities (target mode)

 The plugin utilises `TR_EnumerateEntities` to find entities in front of the client. Then they are presented as a list of selectable targets in a menu.

 After an entity is selected, it flickers via `SetTransmit`, allowing the client to see what they selected (not implemented for static props).

 In target mode, the plugin redirects paint towards the selected entity by overriding `m_nEntity` and `m_nHitbox` in  `Entity Decal`. 
 
 For brush models and world, `m_vecOrigin` requires an exact collision point, because the engine goes through visual valid surfaces and finds the right one to paint on for the corresponding point in space.  `TR_ClipRayToEntity` allows us to get that for entities, as it doesn't have non-solid flags checks.
 
 For studio models decals are projected onto the model's meshes, so `m_vecOrigin` is simply set to a point `g_cvStudioDist` units in front of the player's eyes.

### Non-solid world (light ray mode)
Engine's `R_LightVec` function works similar to collision system's `TraceRay`, but it traverses visual surfaces instead. Just like how decals are applied to brushes. With a little kludge I get a trace's end position and use it for `m_vecOrigin`.

 ### Save/load

 Automatic save and load are implemented by Claude, which I haven't really checked yet. The plugin utilises `m_iHammerID` for entities and `m_nHitbox` (index) for static props, which should be persistent across map loads. 

## TODO
- For static props highlighting make a single dynamic prop to mimic them. When highlighting send dynamic prop's model, origin, size*1.01, color via `sendproxy` to the client and make it flicker via `SetTransmit` or color change. (waiting for Mikusch to publish his `SendProxy`)

## Open questions

- Works for every type of non-solid object?
- Is save/load consistent?

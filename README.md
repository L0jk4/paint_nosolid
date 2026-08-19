https://github.com/user-attachments/assets/9d245fb5-caf9-4ea1-a460-658b5616cb4a

# Description

A *proof of concept* SourceMod plugin made with Claude based on my idea. It allows players to paint even on non-solid objects such as triggers, static props, dynamic props, func_brush entities, etc.

## Note
For non-solid static props to be visible to `TR_EnumerateEntities` a patch is required, which is implemented only for x86 Windows Counter-Strike: Source. It shouldn't have a significant impact on server performance, since they will still be filtered out early on in the collision pipeline.

 ## Concept

 ### Baseline (free aim mode)
 `+paint` command performs a trace forward and sends an `Entity Decal` temporary entity to the client, which works for pretty much everything visible and solid.

 ### Non-solids (target mode)

 The plugin utilises `TR_EnumerateEntities` to find entities in front of the client, then they are presented as a list of selectable targets in a menu.

 After an entity is selected, it flickers via `SetTransmit`, allowing the client to see what they selected (not implemented for static props).

 In target mode, the plugin redirects paint towards the selected entity by overriding `m_nEntity` and `m_nHitbox` in  `Entity Decal`. 
 
 For world and brush models `m_vecOrigin` requires an exact collision point, because the engine finds the surface to paint on by going through the map's BSP tree.  `TR_ClipRayToEntity` allows us to get that, as it doesn't have non-solid flags checks.
 
 For studio models decals are projected onto the model's meshes, so `m_vecOrigin` is simply set to a point `g_cvStudioDist` units in front of the player's eyes.

 ### Save/load

 Automatic save and load are implemented by Claude, which I haven't really checked yet. It should utilise `m_iHammerID` for entities and `m_nHitbox` for static props, which might not be 100% consistent. 

## Open questions

- How to highlight a selected static prop for clients?
- Works for every type of non-solid object?
- Is save/load consistent?





--!nonstrict
-- init.client.luau
-- Client boot. Mirrors the server's two-phase contract so both sides read
-- the same way:
--
--   init()  - build UI, bind remotes. Must not assume any later controller
--             is running yet.
--   start() - connect loops, pull initial state from the server.
--
-- A controller may require any controller listed above it. Adding one means
-- adding a name to ORDER.

local Controllers = script.Controllers

local ORDER = {
	"CameraController",
	"RodViewmodelController",
	"FistsViewmodelController", -- shares the Viewmodel rig module with the rod; which one shows follows the Equipped attributes
	"WeaponViewmodelController", -- same again for a crafted weapon (Equipped == "weapon" and EquippedWeaponId isn't the fists)
	"InventoryController", -- after CameraController: borrows the cursor while open; also shows crafting materials
	"FishingController", -- after RodViewmodelController: reads the rod tip; after CameraController: borrows the cursor while reeling
	-- NOTE: it also requires BossHudController, which is listed BELOW it. The
	-- one-way exception to the rule above, and a safe one: all it calls is
	-- `isEngaged()`, a pure read of a local that is nil until a bar is taken, so
	-- nothing is asked of a controller that has not init()ed yet. BoatController
	-- does the same, for the same refusal feedback.
	"OceanController", -- no dependencies; scrolls the water textures
	"LavaController", -- no dependencies; molten crust + bubbles/bursts on any "*Lava" part under Workspace/World
	"MaelstromVfxController", -- no dependencies; spins the Maelstrom's whirlpool disc + counter-layer (pure local decoration)
	"BrinejawBodyController", -- no dependencies; draws the cove serpent's ~100-part body from its replicated pose attributes
	"KrakenBodyController", -- no dependencies; draws the maelstrom octopus: one head at the arena centre + an arm to each live tentacle
	"NoctyssBodyController", -- no dependencies; draws the Gloomtrench choir (a chain per lantern stalk) and the maw that comes up through the pit
	"RimefangBodyController", -- no dependencies; draws the ice island's killer whale: a short chain of vertebrae plus a head cluster
	"GnashrootBodyController", -- no dependencies; draws the swamp mire-colossus: one body cluster + an arm chain off each shoulder
	"PyreliskBodyController", -- no dependencies; draws the volcano colossus: one body cluster + a jointed arm (not a chain) per shoulder
	"WrackBodyController", -- no dependencies; places the wreck island's careened flagship as ONE static assembly (no rig, no path module - he never moves)
	"CreatureVfxController", -- no dependencies; splashes / drips / puffs driven by creature attributes
	"EquipController", -- no dependencies; 1/2 hotkeys that ask the server to swap hands
	"ToolHoldController", -- after CameraController (reads isThirdPerson): poses every player's arms around the welded rod/weapon so it stops swinging with the walk
	"CombatController", -- after both melee viewmodels: click/tap swings the equipped weapon (and asks the server to resolve the hit)
	"RangedController", -- after WeaponViewmodelController (kick + muzzle): the trigger for any `ranged` weapon row; CombatController stands down for those
	"CrosshairController", -- after CameraController (the mode) + RangedController (the trigger it marks): the crosshair drawn ON the cursor, third person only
	"RangedFxController", -- after WeaponViewmodelController: pooled tracers + muzzle flashes off the ShotFired remote
	"CombatFeedbackController", -- no dependencies; flash / health bar / damage numbers off replicated Health
	"CombatVfxController", -- no dependencies; impact burst + camera kick off the CreatureHit remote
	"ProgressionController", -- no dependencies; level / XP / coins HUD off the Player's replicated attributes
	"PlayerHudController", -- no dependencies; top-right health bar + damage flash off the character Humanoid
	"AdminController", -- after CameraController: P cheat panel (only shown to admins), borrows the cursor while open
	"IslandsController", -- after CameraController: the Islands travel menu (borrows the cursor while open)
	"TrophyController", -- after CameraController: H opens the Trophy Hall (boss hearts off the Heart_* attributes)
	"TrophyShelfController", -- no dependencies; decorates any boat's TrophyShelf mounts with the owner's heart orbs
	"BoatController", -- no dependencies; R summons the boat, drives it while seated at your own helm (client-owned physics)
	"DropController", -- no dependencies; "You found: X!" banner off the ItemDropped remote
	-- A name here with no matching module fails the assert below and kills the
	-- whole client boot (first person, viewmodels, every menu) - so only ever add
	-- one together with its Controllers/<name>.luau file (2026-08-22 incident).
	"BaitController", -- no dependencies; active-bait HUD indicator + Q cycle off GetBait/BaitUpdated + the SelectedBaitId attribute
	"QuestController", -- after CameraController + Progression (pop): the quest log (J) + on-screen tracker off GetQuests/QuestsUpdated/QuestProgress
	"NpcMarkerController", -- after QuestController (reads its snapshot + Changed): the gold "!"/"?" over each Workspace/Npcs body
	"CollectionsController", -- after Progression (toast): the fishing bestiary snapshot + New-species pop; the browse modal arrives with B2
	"MenuButtonsController", -- after Inventory + Admin + Islands + Quest: bottom-left menu buttons, ALT frees the cursor (no Craft tile since 2026-09-12: crafting is the villagers' menu)
	"CreatureEventController", -- after CombatVfx (camera kick) + Progression (coin pop): enemy states off creature attributes, moments off the CreatureEvent remote
	"ProjectileFxController", -- no dependencies; Wrack's bullet hell off the same CreatureEvent channel (its own kinds), pooled and drawn on the render step
	"MusicController", -- before BossHudController (which calls setBoss on track/untrack): the island theme + ambience bed + boss stems, and the thunder/lamp cues WeatherController can't own
	"CharacterSoundController", -- no dependencies; replaces the stock RbxCharacterSounds - footsteps off FloorMaterial for every player, hurt/death for the local one
	"FloeController", -- no dependencies; Rimefang's breaking ice off the FloeEvent remote (crack/sink/refreeze visuals, the Frozen meter, the rod-window banners). FishingController reads its `rodWindow()` from ABOVE this line - the same one-way exception documented under FishingController, and safe for the same reason: a pure read of a local that is nil until the server opens a window
	"BossHudController", -- no dependencies (but see the note under FishingController: it and BoatController read `isEngaged`); the boss health bar off a creature's BossName/Health attributes + rise/down banners off CreatureEvent
	"RaidHudController", -- no dependencies; raid countdown/wave line + cards off the RaidState remote, filtered to the local island
	"WeatherController", -- no dependencies; blizzard fog / event ambience off the WorldEvent remote + own-position checks
	"BossCutsceneController", -- after CombatVfx (the shake rides its kick) + BossHud (whose rise card it stands down) + Weather (the arrival ambience lands under it): the per-boss intro cinematic off the BossIntro remote
	"NpcDialogController", -- after CameraController: the NPC talking window off the NpcDialog remote (borrows the cursor while open)
}

local loaded = {}

for _, name in ORDER do
	local module = Controllers:FindFirstChild(name)
	assert(module, string.format("[Boot] missing controller module %q", name))
	loaded[name] = require(module)
end

for _, phase in { "init", "start" } do
	for _, name in ORDER do
		local method = loaded[name][phase]
		if method then
			local ok, err = pcall(method)
			if not ok then
				error(string.format("[Boot] %s.%s failed: %s", name, phase, tostring(err)), 0)
			end
		end
	end
end

print(string.format("[Boot] %d controller(s) online.", #ORDER))

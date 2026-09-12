--!nonstrict
-- CreatureFamilies.luau
-- Every creature id in Creatures.luau sorted into ONE of fifteen body
-- families. The families are a SOUND grouping, not a taxonomy: they exist so
-- the audio pass can author four cues per family (`<F>Idle`, `<F>Attack`,
-- `<F>Hurt`, `<F>Die` - see assets/audio_gen/CONTRACT.md §3 sfx_families)
-- instead of 488 cues for 122 creatures, and so a new creature is audible the
-- day it lands by naming a family here rather than waiting on a render.
--
-- Membership is decided by what the thing SOUNDS like when it moves and dies,
-- which is mostly its `body.shape`/`species` and its silhouette:
--   smallFish   a palm-sized fish: a flick and a slap, nothing more
--   bigFish     a body with weight behind the same voice
--   spiny       shells and spines: a rattle over the fish
--   crustacean  chitin: clicks, scrapes, a shell snapping shut
--   eel         long and serpentine: a coil, a rush, a bite
--   jelly       soft and pulsing, wet and tuned, no hard transient
--   blob        formless mass: a wet slump
--   wing        it flies or glides: air, membrane, beats
--   burrower    it comes through the ground: grit and displacement
--   mimic       it is furniture until it isn't: a lid, a hinge, a snap
--   undead      the drowned crew: waterlogged voices and dragging
--   elemental   fire/ice/storm made animate: no flesh, only its element
--   mechanical  Wrack's animated ship parts: iron, timber, powder
--   flora       rooted growths: creak, rustle, sap
--   leviathan   the seven bosses: everything at arena scale
--
-- check_content.py enforces both directions: every creature id has a family,
-- and every family named here is one of the fifteen. Adding a creature
-- without adding it here fails the gate rather than silently going mute.

local Creatures = require(script.Parent.Creatures)

local CreatureFamilies = {}

-- The fifteen, in the order the contract lists them. `families` is the
-- allow-list check_content validates the table's values against.
CreatureFamilies.families = {
	"smallFish",
	"bigFish",
	"spiny",
	"crustacean",
	"eel",
	"jelly",
	"blob",
	"wing",
	"burrower",
	"mimic",
	"undead",
	"elemental",
	"mechanical",
	"flora",
	"leviathan",
}

-- creatureId -> family
CreatureFamilies.byId = {
	-- smallFish: a flick of a tail and a wet slap, and that is the whole voice.
	perch = "smallFish",
	trout = "smallFish",
	mackerel = "smallFish",
	emberfin_perch = "smallFish",
	ashgill_minnow = "smallFish",
	magma_guppy = "smallFish",
	peat_darter = "smallFish",
	bog_bream = "smallFish",
	icemelt_smelt = "smallFish",
	frostfin_char = "smallFish",
	snowdrift_sculpin = "smallFish",
	pale_dace = "smallFish",
	blindcave_sardine = "smallFish",
	wreck_herring = "smallFish",
	rustscale_snapper = "smallFish",
	barnacle_blenny = "smallFish",
	squall_sprat = "smallFish",
	rainfin_mackerel = "smallFish",
	foamchaser_mullet = "smallFish",
	hatchling = "smallFish",

	-- bigFish: the same voice with a body behind it - slower, lower, heavier.
	bass = "bigFish",
	cod = "bigFish",
	salmon = "bigFish",
	tuna = "bigFish",
	obsidian_bass = "bigFish",
	basalt_cod = "bigFish",
	pyre_salmon = "bigFish",
	magmafin_tuna = "bigFish",
	rustgill_gar = "bigFish",
	golden_gar = "bigFish",
	rime_herring = "bigFish",
	aurorafin_marlin = "bigFish",
	ghost_carp = "bigFish",
	spectral_sailfish = "bigFish",
	stormking_tuna = "bigFish",
	thunderlance_marlin = "bigFish",
	sunking_coelacanth = "bigFish",
	ghostlight_oarfish = "bigFish",
	sootgill_hagfish = "bigFish",

	-- spiny: armoured and bristling. A rattle of spines sits over the fish.
	pufferfish = "spiny",
	tidebomb_urchin = "spiny",
	obsidian_shardback = "spiny",
	pressure_crab = "spiny",

	-- crustacean: chitin on chitin. Clicks, scrapes, a shell snapping shut.
	snapjaw_crab = "crustacean",
	iceshard_crab = "crustacean",
	frostbite_pup = "crustacean",
	cannonball_crab = "crustacean",
	trench_skitterer = "crustacean",
	pickpocket_hermit = "crustacean",
	plunder_sprite = "crustacean",
	vampire_squid = "crustacean",

	-- eel: long bodies that coil and rush. The bite is the punctuation.
	gullet_cod = "eel",
	gulper_eel = "eel",
	fumarole = "eel",
	croakjaw_toad = "eel",
	fen_serpent = "eel",
	lodestone_eel = "eel",
	phantom_moray = "eel",
	old_ribbonjaw = "eel",
	icevein_pike = "eel",
	riptide_barracuda = "eel",
	tideline_skipper = "eel",
	snagtooth_gator = "eel",
	tollmaw = "eel",
	kraken_tentacle = "eel",
	-- The Maelstrom fight's arms, added while this table was being written:
	-- another limb off the same animal, so the same voice as its tentacles.
	kraken_arm = "eel",
	mire_leech = "eel",

	-- jelly: wet, tuned, pulsing. No hard transient anywhere in the family.
	moonbell_jelly = "jelly",
	aurora_jelly = "jelly",
	ghostfire_jelly = "jelly",
	ember_swarm = "jelly",
	flashbulb_squid = "jelly",
	will_o_wisp = "jelly",

	-- blob: a formless mass moving. A wet slump, and a wetter one when it dies.
	magma_ooze = "blob",
	kraken_spawn = "blob",
	-- Gullet Antibody: a thing the Kraken's insides make to swat you. No
	-- silhouette of its own worth a voice - a wet mass rushing is exactly blob.
	kraken_antibody = "blob",

	-- wing: it leaves the ground. Air over a membrane, and beats.
	voltray = "wing",
	void_ray = "wing",
	cyclone_ray = "wing",
	ashfeather_phoenix = "wing",
	dread_dragonfly = "wing",
	moth_of_the_deep = "wing",
	hailfin_skua = "wing",
	rigging_wraith = "wing",
	bog_gull = "wing",
	stormpetrel = "wing",
	galestreak_flyingfish = "wing",

	-- burrower: it arrives through the ground. Grit, displacement, a surfacing.
	sand_lurker = "burrower",
	catfish = "burrower",
	mudwhisker_catfish = "burrower",
	glacial_lurker = "burrower",
	silt_stalker = "burrower",
	whirlpool_horror = "burrower",

	-- mimic: furniture until it isn't. A lid, a hinge, and a snap.
	pearl_mimic = "mimic",
	sunken_trapper = "mimic",
	cursed_chest = "mimic",
	lanternjaw_angler = "mimic",

	-- undead: the drowned crew. Waterlogged voices, dragging, iron on bone.
	drowned_deckhand = "undead",
	drowned_angler = "undead",
	frozen_mariner = "undead",
	peat_revenant = "undead",
	drowned_boatswain = "undead",
	tempest_revenant = "undead",
	wailing_gunner = "undead",
	wrack_boarder = "undead",

	-- elemental: no flesh. Whatever it is made of is the whole sound.
	cinder_djinn = "elemental",
	blizzard_wraith = "elemental",
	stormcaller_djinn = "elemental",
	slagheart_golem = "elemental",

	-- mechanical: Wrack's ship animated against you. Iron, timber, powder.
	wrack_battery = "mechanical",
	wrack_powder_keg = "mechanical",
	wrack_ghost_brazier = "mechanical",
	wrack_chain_link = "mechanical",
	wrack_figurehead = "mechanical",
	wrack_boom_tackle = "mechanical",

	-- flora: rooted. It creaks and rustles rather than moves.
	brine_polyp = "flora",
	choir_stalk = "flora",
	-- Gullet Polyp: rooted to the Kraken's gullet wall and creaking rather
	-- than moving, which is the whole of what `flora` means here.
	kraken_polyp = "flora",
	-- Refreezing Rift: new ice growing up out of a hole she is misting. Rooted
	-- and creaking, exactly like the two polyps above - it never moves, and the
	-- only thing it does is be broken.
	rime_rift = "flora",

	-- Act 3's six arm rocks and the core at the collar. ELEMENTAL and not
	-- `flora`, which is where `kraken_polyp` sits on the same archetype: a
	-- polyp is a growth on a wall and creaks like one, and these are molten
	-- rock - "fire made animate: no flesh, only its element" is the family's
	-- own words and it is the whole voice of a thing that cracks and runs.
	-- Not `leviathan` either: that is the scale of the body they are stuck to,
	-- and a six-stud bleeder breaking should not sound like a mountain.
	--
	-- A judgement call, and the audio lane owns the final say - it is one line
	-- each to move them.
	-- Act 4's two. The heart is the fire itself - "no flesh, only its element"
	-- is the family's own words and it is the whole voice of a molten mass on a
	-- dais - and a pillar is obsidian, which cracks and shatters rather than
	-- creaking like the `flora` growths `kraken_polyp` sits with on the same
	-- archetype. Not `leviathan`: that is the scale of the colossus these came
	-- out of, and a pillar breaking should not sound like a mountain.
	pyrelisk_heart = "elemental",
	pyrelisk_pillar = "elemental",

	-- leviathan: the seven. Everything at arena scale.
	brinejaw = "leviathan",
	pyrelisk = "leviathan",
	-- Act 2's severed limb, and it is the colossus's OWN body lying on the
	-- path - a hundred and fifty studs of it. Same voice at the same scale,
	-- which is the whole rule: `kraken_arm` is "eel" because a tentacle sounds
	-- like the coil it is, and this one sounds like the mountain it came off.
	pyrelisk_arm = "leviathan",
	old_gnashroot = "leviathan",
	rimefang = "leviathan",
	noctyss = "leviathan",
	admiral_wrack = "leviathan",
	kraken = "leviathan",
	-- ...and act three is NOT a leviathan, which is the point of act three.
	-- `admiral_wrack` above is the SHIP - a first-rate fused to a drowned man,
	-- and it sounds like one. `wrack_admiral` is the man once the ship is off
	-- him: boots on wet sand, a sabre, and a flintlock. "undead" is the family
	-- that carries that voice, and picking "leviathan" for him because his two
	-- earlier acts were one would have given the duel the wreck's throat.
	wrack_admiral = "undead",
}

-- The family for a creature id, or nil if the id is unknown. Callers treat
-- nil as "no family voice" and stay silent rather than guessing a cue name.
function CreatureFamilies.get(creatureId: string?): string?
	if not creatureId then
		return nil
	end
	return CreatureFamilies.byId[creatureId]
end

-- HOW BIG IT SOUNDS. One family shares four cues across a sardine and a
-- marlin, so the size has to come from somewhere else: the client passes this
-- as `opts.pitch` and the same render reads as a different animal.
--
-- `1 / scale^0.5` rather than `1 / scale`: pitch is perceived roughly
-- logarithmically, so the square root keeps a 4x size difference to an octave
-- instead of two, which is the difference between "bigger" and "broken". The
-- clamp is the audible range of a sample transposed without artefacting -
-- past 1.6 everything is a chipmunk and under 0.6 it is mud.
function CreatureFamilies.voicePitch(creatureId: string?): number
	local row = creatureId and Creatures.items[creatureId]
	local scale = row and row.body and row.body.scale
	if type(scale) ~= "number" or scale <= 0 then
		return 1
	end
	return math.clamp(1 / (scale ^ 0.5), 0.6, 1.6)
end

return CreatureFamilies

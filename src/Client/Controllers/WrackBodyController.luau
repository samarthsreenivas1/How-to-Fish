--!nonstrict
-- WrackBodyController.luau
-- Draws Admiral Wrack, the Fleet-Eater: his flagship standing upright and
-- keel-bedded in the shoal, with the drowned admiral on her quarterdeck.
--
-- REDESIGNED 2026-09-08, from the player, and all three notes land in this
-- file as constants: the 48-degree careen is gone (she stands up), the ship
-- is a little over half its old bulk (48 studs bow to stern and 34.4 to the
-- sabre tip, against 87 and 72), and the four floating "batteries" are now
-- four actual cannons built into the hull - `Wrack_CannonBow`,
-- `Wrack_CannonStarboard`, `Wrack_CannonStern`, `Wrack_CannonPort`. The old
-- `Wrack_Battery*` names are GONE from the mesh; anything still addressing
-- them draws nothing.
--
-- THIS IS THE SIMPLEST OF THE SEVEN BODY CONTROLLERS, and deliberately so.
-- Its six siblings all drive a RIG - a chain walked by arc length
-- (Brinejaw, Rimefang, the Kraken's arms, Noctyss's stalks) or a jointed
-- limb set posed from a path module (Gnashroot, Pyrelisk) - because those
-- bosses move. Wrack does not. `Bosses.items.admiral_wrack` carries
-- `speed = 0`: he is a planted gun platform and his fight is a bullet hell
-- that happens in FRONT of him, not a body that swings.
--
-- So there is no path module and no pose attribute here, and neither should be
-- added. All 25 objects in assets/boss_wrack.glb are authored in ONE shared
-- space at their final positions (boss_gen.py's build_wrack: "STATIC. One
-- CFrame for the whole model - he never moves, never turns"), so the entire
-- ship places with a single CFrame and a per-piece offset that is measured
-- once at clone time and never recomputed.
--
-- WHAT IS STILL PER-FRAME, and why this is not a one-shot placement:
--
--   * he rises out of the shoal on spawn (`riseDepth = 22`, `riseTime = 4.2`),
--     and the prowl loop breathes him on a small hop and a +-3 degree sway.
--     Both move the server model's pivot, and the assembly rides it for free.
--     He does NOT slew: `turnRate` is 0, because his four gun decks are
--     authored at four bearings and a hull that turns to face you presents the
--     same two forever;
--   * the hull SPLITS for the melee window - two plates off the keel hinge,
--     eased on one scalar. See "the melee window" below: it is a door opening,
--     not a body being animated;
--   * ...and THE PIECES THEMSELVES ARE POSED, by the channel layer below.
--
-- THAT LAST LINE OVERTURNED WHAT THIS HEADER USED TO SAY, so it is worth
-- saying what did and did not change (2026-09-09, from the player: "more
-- unique attacks... make them more interesting"). The shell scalar used to be
-- described here as the only interpolated thing in the file "and it should
-- stay the only one". THE SHIP still is not animated - no rig, no chain, no
-- limb maths on the hull, and the whole assembly is still one CFrame off the
-- pivot. What is animated is the MAN on the quarterdeck and the BRASS he
-- fires, both of which were always separate objects standing still for no
-- reason. The shell mechanism was not replaced to do it, it was generalised:
-- the melee window is now one row of CHANNELS with byte-identical behaviour.
--
-- THIS FILE HAS ONE PUBLIC ENTRY BEYOND init/start: `WrackBodyController.cue
-- (model, signal, extra)`, the boss intro's contract. The cutscene lane runs a
-- client-side stand-in model carrying `CreatureId = "admiral_wrack"` - which
-- this controller adopts exactly like the server's - drives its pivot itself,
-- and calls `cue` to fire the Admiral's channels on beats of its own choosing
-- with no wire event in sight. `cue` enters at the same point a real event
-- does, so a cued gesture and a fought one are the same code; it cannot adopt
-- a model, only conduct one already adopted. Signals, fields and the
-- attributes a cutscene sets directly instead: see "the cutscene" below.
--
-- Pieces come from ReplicatedStorage/Assets/WrackPack (assets/boss_wrack.glb,
-- see docs/import-checklist.md row 7p). Until that import lands this draws
-- correctly-placed, correctly-sized stand-ins rather than nothing, exactly
-- like every sibling, so the fight is always debuggable.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MeshColors = require(Shared.Config.MeshColors)
-- The client event stream. Subscribed to HERE rather than routed through
-- ProjectileFxController, because `CreatureEvent` is a broadcast every
-- interested controller connects to on its own (that file's own header says
-- so: "which this file subscribes to alongside CreatureEventController; kinds
-- it does not own are ignored in silence"). A second connection costs one
-- table lookup per event and keeps the two lanes from owning each other.
local Remotes = require(Shared.Net.Remotes)

local WrackBodyController = {}

local CREATURES_FOLDER = "Creatures"
local PACK_NAME = "WrackPack"
local PREFIX = "Wrack_"
local FOLDER_NAME = "WrackBody"

-- HOW THIS CONTROLLER FINDS ITS BOSS, and why it is not `Pose`.
--
-- The other six adopt on `model:GetAttribute("Pose")`, which CreatureService
-- writes only for a boss whose Bosses row carries `pose = "<kind>"` (or, for
-- Rimefang, from its own driver). Admiral Wrack carries NO `pose` on
-- purpose, and giving him one would break his fight rather than help it:
-- `wrackScale`'s own note in CreatureService says the patterns' latched
-- firing bearings come from `bossFacing` -> `creature.yaw0`, and yaw0 is
-- written by updateBoss's PROWL branch, "which a `pose`d boss returns before
-- ever reaching". A posed Wrack would aim every volley off a dead bearing.
--
-- So he is adopted on `CreatureId` instead - CreatureService's ATTR_ID, set
-- on every creature model there is. KrakenBodyController already keys its
-- tentacles off the same attribute, and BossHudController finds every boss
-- with it. No server change is needed for this controller to work.
local CREATURE_ID = "admiral_wrack"

-- The authored centre of `Wrack_Base` in boss space, measured off the glb.
-- boss_gen's HANDOFF names Base the anchor - "its centre is the boss origin
-- at sand level (z=0 = the shoal)" - and BossArenaService.placeAuthored
-- anchors every authored ARENA mesh on the same `<model>_Base` convention,
-- so this controller follows it for the boss mesh.
--
-- It is used ONLY to place the stand-ins: the clone path measures each
-- piece's offset from the real `Wrack_Base` it finds in the pack, so a
-- re-export that shifts the ship cannot desync the imported body. This
-- constant only has to keep the stand-in agreeing with the clone.
local AUTHORED_ANCHOR = Vector3.new(-0.1, 0.7, 0.3)

-- Every piece the assembly draws, in build order.
--
-- `Wrack_MuzzleGlow` is the 25th object and is deliberately NOT here. It is
-- a MODULE, not a piece: boss_gen authors it at the origin with +X as the
-- bore and instances it once per live muzzle, so it has no single home to be
-- placed at. See MODULES below, which instances it four times - once per gun -
-- and is the thing the import checklist meant by "whoever draws muzzle flash
-- owns it". Routing it through makePiece() was indeed all it needed to come
-- out Neon.
local PIECES = {
	"Base",
	"Hull",
	"Strakes",
	"Keel",
	"Crust",
	"Ribs",
	"ShellUpper",
	"ShellLower",
	"HeartGlow",
	"HeartCage",
	"CannonBow",
	"CannonStarboard",
	"CannonStern",
	"CannonPort",
	"Mast",
	"Rigging",
	"Sail",
	"Coat",
	"Arm",
	"Sabre",
	"Facings",
	"Skull",
	"EyeGlow",
	"Hat",
}

-- Stand-in geometry, used only until the pack is imported: every piece's
-- authored bounding box and its WR_* palette colour, read straight out of
-- assets/boss_wrack.glb and assets/boss_gen.py. Blocks rather than shapes,
-- but at the authored size AND the authored place, so an un-imported fight
-- shows an upright ship of the right bulk in the right spot (48 studs bow to
-- stern, 26.5 to the masthead, 34.4 to the sabre tip) instead of a grey box.
--
-- REGENERATED, never typed: these are the glb's own per-object bounding
-- boxes, and the export is already in Roblox space (Blender x,y,z -> x,z,-y),
-- so a row here is `at` = bbox centre and `size` = bbox extent, verbatim. The
-- redesign moved every one of them; hand-editing a subset is how a stand-in
-- ship ends up half in the old careen and half in the new one.
local AUTHORED = {
	Base = { at = Vector3.new(-0.1, 0.7, 0.3), size = Vector3.new(53.5, 2.8, 26.8), color = Color3.fromRGB(62, 59, 53) },
	Hull = { at = Vector3.new(-0.5, 7.8, 0.3), size = Vector3.new(41, 13.5, 14.5), color = Color3.fromRGB(30, 35, 41) },
	Strakes = {
		at = Vector3.new(-0.5, 8.2, 0),
		size = Vector3.new(40.3, 14.5, 13.8),
		color = Color3.fromRGB(59, 67, 74),
	},
	Keel = { at = Vector3.new(-0.4, 6.4, 0), size = Vector3.new(45.3, 13.1, 10.3), color = Color3.fromRGB(25, 29, 34) },
	Crust = { at = Vector3.new(-0.5, 4, -0.1), size = Vector3.new(38, 7.6, 15.3), color = Color3.fromRGB(97, 104, 90) },
	Ribs = {
		at = Vector3.new(3, 5.9, -0.1),
		size = Vector3.new(15.2, 10.3, 11.8),
		color = Color3.fromRGB(218, 212, 189),
	},
	ShellUpper = {
		at = Vector3.new(3, 6.6, 3.3),
		size = Vector3.new(12, 11.4, 6.7),
		color = Color3.fromRGB(30, 35, 41),
	},
	ShellLower = { at = Vector3.new(3, 6.6, -2), size = Vector3.new(12, 11.5, 9.2), color = Color3.fromRGB(30, 35, 41) },
	HeartGlow = {
		at = Vector3.new(3, 6.8, 0),
		size = Vector3.new(3.6, 5.4, 3.8),
		color = Color3.fromRGB(255, 199, 107),
	},
	HeartCage = { at = Vector3.new(3, 7.2, 0), size = Vector3.new(5.4, 7, 4), color = Color3.fromRGB(186, 132, 53) },
	CannonBow = {
		at = Vector3.new(17.6, 12.2, 1.1),
		size = Vector3.new(13.7, 6.3, 8.4),
		color = Color3.fromRGB(186, 132, 53),
	},
	CannonStarboard = {
		at = Vector3.new(12.5, 9, -6.2),
		size = Vector3.new(9.8, 7.8, 11.3),
		color = Color3.fromRGB(186, 132, 53),
	},
	CannonStern = {
		at = Vector3.new(-18.9, 9.6, -1),
		size = Vector3.new(11.3, 8.3, 10.4),
		color = Color3.fromRGB(186, 132, 53),
	},
	CannonPort = {
		at = Vector3.new(-11, 9.2, 6.8),
		size = Vector3.new(9.8, 7.8, 11.3),
		color = Color3.fromRGB(186, 132, 53),
	},
	Mast = {
		at = Vector3.new(10.5, 14.5, 1.2),
		size = Vector3.new(37.8, 26.8, 23.5),
		color = Color3.fromRGB(96, 92, 85),
	},
	Rigging = {
		at = Vector3.new(3.5, 13.8, 1.2),
		size = Vector3.new(49.2, 23.8, 23.6),
		color = Color3.fromRGB(79, 73, 61),
	},
	Sail = {
		at = Vector3.new(-6.5, 16, 2.4),
		size = Vector3.new(3.4, 12.6, 21.4),
		color = Color3.fromRGB(150, 156, 163),
	},
	Coat = { at = Vector3.new(-13.9, 18.3, -0.4), size = Vector3.new(6, 13.8, 8.5), color = Color3.fromRGB(30, 37, 62) },
	Arm = { at = Vector3.new(-13.8, 23.1, 0.3), size = Vector3.new(4.6, 11.7, 9.4), color = Color3.fromRGB(30, 37, 62) },
	Sabre = {
		at = Vector3.new(-11.8, 31, -2.5),
		size = Vector3.new(2.2, 6.9, 2.2),
		color = Color3.fromRGB(189, 196, 201),
	},
	Facings = {
		at = Vector3.new(-14, 23.3, 0.6),
		size = Vector3.new(5.1, 12.3, 9),
		color = Color3.fromRGB(201, 177, 102),
	},
	Skull = { at = Vector3.new(-14.5, 26, 1.1), size = Vector3.new(4, 4.6, 3.4), color = Color3.fromRGB(218, 212, 189) },
	EyeGlow = {
		at = Vector3.new(-13.8, 26.6, 1.1),
		size = Vector3.new(1, 0.9, 2.5),
		color = Color3.fromRGB(255, 204, 92),
	},
	Hat = { at = Vector3.new(-14.9, 27.9, 1.1), size = Vector3.new(3.7, 2.1, 7.8), color = Color3.fromRGB(22, 22, 27) },
	-- THE 25TH OBJECT, and the one row here that is not a placement.
	--
	-- `Wrack_MuzzleGlow` is a MODULE: boss_gen authors it at the ORIGIN with +X
	-- as the bore and it is instanced once per muzzle (see MODULES below), so
	-- `at` is not where it goes - it is where its own bounding box sits inside
	-- its own authored space, which is what a clone's CFrame means and what the
	-- stand-in block has to reproduce. FLARE_CENTRE below is this row's `at.X`
	-- and the two must move together.
	--
	-- Measured off assets/boss_wrack.glb by the same per-object bounding box
	-- pass as every row above, not typed: the flare runs from -0.5 to 2.0 along
	-- the bore with five spikes to +-1.2 across it.
	MuzzleGlow = {
		at = Vector3.new(0.78, 0, -0.1),
		size = Vector3.new(2.44, 2.03, 1.93),
		color = Color3.fromRGB(255, 241, 199),
	},
}

-- The pieces that must burn, by the marker boss_gen puts in the OBJECT name
-- (a material name never survives the glTF import - Studio names a MeshPart
-- after its object). Substring, so `Wrack_HeartGlow`, `Wrack_EyeGlow` and
-- `Wrack_MuzzleGlow` all match, and so does anything a re-export adds.
--
-- This mirrors BossArenaService's GLOW_MARKERS exactly, because it is the
-- same contract - but that implementation is honoured for ARENA meshes only,
-- which is the whole reason this line has to exist here. boss_gen's own
-- HANDOFF says so out loud: "the boss path (<Boss>BodyController clones pack
-- parts) has NO Neon-by-name rule, so these three import FLAT unless the
-- Wrack body controller sets Material.Neon on them."
--
-- `Wrack_HeartGlow` is the one that matters. It is the lantern hanging in
-- the hold, and the whole point of the melee punish window is that silencing
-- all four batteries splits the hull and exposes it. Left flat it is a grey
-- lump, and the payoff of the fight's one opening reads as nothing.
local GLOW_MARKER = "Glow"

-- ---------------------------------------------------------- the melee window
--
-- THE HULL OPENS. Silence all four gun decks and the waist splits: the two
-- shell plates swing off the keel and the colossus is visibly broken in half,
-- bow and stern joined only by the keel and a bare ribcage, with the
-- heart-lantern burning in the gap. It reads best from directly above, which
-- is where the fight camera sits.
--
-- THE SIGNAL. `Exposed` - CreatureService's ATTR_EXPOSED - written on the
-- parts-down path since 7258b4c. It is LEVEL-triggered, and that is the whole
-- reason this is drawable: it is a state to read, not an edge to catch. The
-- server sets it in kill() when the last battery falls and clears it in
-- spawnBossParts when the ring regrows, so "is the hull open" is answerable at
-- any instant by anyone who can see the model.
--
-- It is also the same attribute the stagger and maw paths write, so this is
-- one rule for every way a boss opens up rather than a Wrack special case -
-- PyreliskBodyController reads exactly the same attribute for the same reason.
local ATTR_EXPOSED = "Exposed"

-- THE HINGE, in boss space: both plates turn about boss-local X through here.
--
-- Upright, the keel IS the boss-local X axis, so the hinge is simply the keel
-- rabbet on the centreline: boss_gen's WR_KEEL_Z, Blender (0, 0, 1.1). The
-- export maps Blender (x, y, z) -> Roblox (x, z, -y), so here it is
-- (0, 1.1, 0), and boss_gen's HANDOFF now prints BOTH spellings for exactly
-- this reason - the careened version printed only the Blender one and taking
-- it verbatim would have hinged about a point fifteen studs underground.
--
-- Stated in boss space (origin = the boss origin at sand level) and converted
-- to assembly-local at use, because `relative` is measured from Wrack_Base.
local HINGE = Vector3.new(0, 1.1, 0)

-- How far each plate swings at full open, from boss_gen's WR_OPEN_UPPER_DEG /
-- WR_OPEN_LOWER_DEG. Opposite signs about the same axis is what makes it a
-- ribcage splitting rather than a lid lifting.
--
-- Upright these are a PORT plate and a STARBOARD plate, so the two angles are
-- equal and opposite and the hull opens along its own centreline like double
-- doors - which is the read the careened version could not have had, because
-- its low plate swung into the sand. 50 degrees is the sand's number, not a
-- taste call: past ~55 the port rail goes through the shoal.
--
-- The signs are the authored ones and they are load-bearing. Re-derived for
-- this geometry: as authored the plate centres separate from 5.3 studs apart
-- to 11.9, and BOTH retreat from the heart-lantern at (3, 6.4, 0) - upper
-- 3.3 -> 7.7, lower 2.0 -> 6.4. Swung the other way the upper plate closes ON
-- the lantern instead (3.3 -> 2.2) and crosses into its sister, so the punish
-- window would seal the very thing it exists to expose. The lantern is
-- revealed by the geometry moving off it, which is why nothing here touches
-- its transparency or its material.
local SHELL_SWING = {
	ShellUpper = math.rad(50),
	ShellLower = math.rad(-50),
}

-- How fast the swing eases. Deliberately slow: this is thirty studs of hull
-- plate, and PyreliskBodyController's note applies with more force here -
-- something this big that snaps between states reads as a cut, not a swing.
-- (Twelve studs of plate now rather than thirty, but they swing through the
-- same arc in the same time - the rate is about legibility, not mass.)
-- At this rate the hull is ~95% open in 1.2s, comfortably inside the 4.0s of
-- true silence `staggerFor` buys, so the plates finish moving while the guns
-- are still quiet and the opening is legible before the burst window starts.
local OPEN_RATE = 2.6

-- ============================================================================
-- THE CHANNEL LAYER
-- ============================================================================
--
-- The header above says the shell scalar "is the only thing in this file that
-- is interpolated, and it should stay the only one". That held while the ship
-- was the whole boss. It stopped holding the moment the player asked for
-- attacks that read as PERFORMED rather than emitted: the hull is still dead
-- still - no rig, no path module, no per-frame limb maths on the SHIP - but
-- the man on the quarterdeck and the brass he fires are not.
--
-- So the shell mechanism is not replaced, it is GENERALISED, and the shell is
-- now one row in the table below with exactly the behaviour it always had.
--
-- WHAT A CHANNEL IS. A named pose applied to a named set of pieces, computed
-- per frame from one driver, and layered onto whatever the channels before it
-- did. Nothing here uses TweenService: a tween writes CFrames on its own clock
-- and the draw loop writes them on ours, and the two would fight for the same
-- property every frame. Every value in this layer is eased by hand, in the
-- existing RenderStepped pass, from state this file owns.
--
-- HOW A PIECE IS POSED. Each channel supplies a `pivot` (a point in BOSS
-- space) and a `pose` returning a CFrame in that pivot's frame. The layer
-- composes
--
--     offset = offset * (pivotCF * pose * pivotCF:Inverse())
--
-- and finally draws `part.CFrame = base * offset * relative`. The composition
-- is a RIGHT-multiply on purpose: a channel later in the list acts in the
-- frame the earlier ones have already established, so the sabre's wrist flick
-- turns about the wrist WHERE THE SHOULDER JUST PUT IT rather than about the
-- wrist's rest position. That is what makes "body sway, then shoulder, then
-- wrist" work as a chain without this file growing a rig. THE LIST ORDER IS
-- THE LAYERING ORDER, outermost first.
--
-- THE ONE RULE A `pose` MUST OBEY: `pose` at value 0 is the identity. The
-- layer skips channels that have eased to zero, so a pose that did something
-- at rest would flicker on and off at the epsilon.
--
-- THE DRIVERS, and why each is the shape it is:
--
--   level   goal(ctx) -> 0 or 1, eased at `rate`. Model attributes live here.
--           LEVEL-TRIGGERED and POLLED, like `Exposed` and `Weakpoint` above
--           and for the same reason: a client that adopts the boss mid-state
--           has no edge to have missed, and a dropped update costs a frame of
--           easing instead of a stuck pose.
--   hold    a client event opens a window `duration` long (plus `tail`);
--           value is 1 inside it, eased at `rate`. This is how a WINDUP is
--           drawn: the wire already carries how long it lasts.
--   pulse   a client event fires a one-shot envelope: linear to 1 over
--           `attack`, then a squared fall over `release`. Sharp out, slow
--           back - a recoil, a muzzle flash, a sabre stroke.
--   free    always 1; the pose reads the clock itself. Idles.
--
-- ADDING A PIECE, OR A DRIVER, IS A TABLE ENTRY. Three sibling contracts are
-- inbound (a figurehead that flies, a boom that sweeps, deck hatches that
-- pop); their stubs are the last three rows of CHANNELS and each lands in at
-- most two one-line edits - the piece name into PIECES/AUTHORED, and the wire
-- kind into adaptSignal. A channel naming a piece that does not exist yet is
-- DROPPED at adopt rather than erroring, which is what makes an unlanded stub
-- inert instead of dangerous.

-- ------------------------------------------------------------- the guns
--
-- WHERE EACH CANNON ACTUALLY POINTS. Derived from `WR_GUNS` in
-- assets/boss_gen.py - the mesh's single source of truth for the art AND for
-- the Bosses mount handoff - converted from Blender (x, y, z) to Roblox
-- (x, z, -y), which is the same conversion every constant in this file uses:
--
--   Bow        breech (14.5, -1.4, 12.2) muzzle (23.6, -1.4, 12.6)
--   Starboard  breech (12.5,  2.8,  9.0) muzzle (12.5, 11.8,  9.0)
--   Stern      breech (-15.5, 1.3,  9.5) muzzle (-24.4, 1.3,  9.2)
--   Port       breech (-11.0,-3.4,  9.2) muzzle (-11.0,-12.4, 9.2)
--
-- `at` IS THE SPAN CENTROID, and it is not decoration: it is exactly the
-- number boss_gen prints into `Bosses.items.admiral_wrack.parts.mounts`, so it
-- is where the SERVER stands the battery creature this cannon is drawn under.
-- That is what lets a volley's world origin be matched back to a gun, and what
-- lets a live weakpoint model be matched to the brass it belongs to. The bow
-- and stern chasers are laid with a slight rise, so their bores are not
-- axis-aligned and are carried at full precision rather than rounded to +-X -
-- the muzzle flare is placed along this vector and a rounded bore would sit it
-- visibly off the barrel.
local GUNS = {
	CannonBow = {
		at = Vector3.new(19.05, 12.4, 1.4),
		muzzle = Vector3.new(23.6, 12.6, 1.4),
		bore = Vector3.new(0.999, 0.044, 0),
	},
	CannonStarboard = {
		at = Vector3.new(12.5, 9, -7.3),
		muzzle = Vector3.new(12.5, 9, -11.8),
		bore = Vector3.new(0, 0, -1),
	},
	CannonStern = {
		at = Vector3.new(-19.95, 9.35, -1.3),
		muzzle = Vector3.new(-24.4, 9.2, -1.3),
		bore = Vector3.new(-0.999, -0.034, 0),
	},
	CannonPort = {
		at = Vector3.new(-11, 9.2, 7.9),
		muzzle = Vector3.new(-11, 9.2, 12.4),
		bore = Vector3.new(0, 0, 1),
	},
}

-- The instanced modules: one `Wrack_MuzzleGlow` per gun, built by the same
-- makePiece() the 24 placed pieces go through - which the import checklist
-- says is all that module needs ("routing it through makePiece() below is all
-- it needs to come out Neon"). They are pieces in every other respect, so
-- every channel below can name them.
local MODULES = {
	{ name = "MuzzleBow", module = "MuzzleGlow", gun = "CannonBow" },
	{ name = "MuzzleStarboard", module = "MuzzleGlow", gun = "CannonStarboard" },
	{ name = "MuzzleStern", module = "MuzzleGlow", gun = "CannonStern" },
	{ name = "MuzzlePort", module = "MuzzleGlow", gun = "CannonPort" },
}

-- The flare's own bounding-box centre along its bore (AUTHORED.MuzzleGlow.at).
-- A cloned MeshPart's CFrame is its bbox centre, so the part has to stand this
-- far PAST the muzzle for the mesh's authored origin - the end that belongs in
-- the barrel - to land on it.
local FLARE_CENTRE = 0.78

-- HOW A VOLLEY FINDS ITS GUN. `wrackVolley`'s position is CreatureService's
-- `origin`: for an aimed pattern that is the latched battery's own world
-- position lifted 5 studs (`flash = gun + Vector3.new(0, WRACK_MUZZLE_LIFT,
-- 0)`), and for every radial one it is the model pivot lifted the same 5. So
-- the flat distance from the origin to a gun centroid answers "which deck fired
-- this" and "did any single deck fire this" in one number.
--
-- 8 studs is chosen against the geometry rather than by feel: an aimed origin
-- lands ON a centroid (error 0, both numbers come from the same table), the
-- closest two centroids are 10.89 studs apart, and the hull pivot is 13.5
-- studs from the nearest of them (Port, r 13.54).
--
-- The band's lower end is not zero, because the prowl loop breathes him on a
-- +-3 degree sway while the mounts were resolved ONCE against `creature.yaw0`:
-- at the stern chaser's r 20.0 that is 1.05 studs of disagreement between
-- where the battery is and where this file draws its gun. So the two cases are
-- separated by everything in [1.05, 13.5], and 8 sits in the middle of it.
-- 1.05 is also well under half the 10.89 centroid spacing, so nearest-wins can
-- never claim the wrong gun. The comparison is FLAT because the 5-stud muzzle
-- lift and the battery's own half-height are both height, and neither is
-- identity.
local MUZZLE_MATCH = 8

-- Recoil: how far the gun rides back down its own bore, and the shape of it.
-- 1.6 studs on a barrel 9 long is a stroke you read at 60 studs without the
-- gun leaving its port.
local RECOIL_STUDS = 1.6
local RECOIL_ATTACK = 0.035
local RECOIL_RELEASE = 0.55

-- The flash. Short enough that two volleys 0.35s apart (grapeshot's burst gap)
-- read as two flashes and not one glow.
local FLASH_ATTACK = 0.02
local FLASH_RELEASE = 0.18
local FLASH_SCALE = 0.45 -- the flare's size at the instant it is born

-- A silenced deck. `Weakpoint` is present on a battery that is standing and
-- the model is gone when it is not, so 15 degrees of muzzle-down and a few of
-- list is the gun hanging dead in its port until the ring regrows.
local DROOP_ANGLE = math.rad(15)
local DROOP_LIST = math.rad(7)
local DROOP_RATE = 3

-- ---------------------------------------------------------- the Admiral
--
-- HE IS THE ONLY THING ALIVE ON THIS BOSS, and that is the read: a ship that
-- does not move at all, and a man on her quarterdeck who never stops. Every
-- point below is one of boss_gen's admiral-space landmarks pushed through its
-- own seating transform - `WR_ADM` = translate(WR_ADM_AT) * scale(0.5) *
-- translate(-WR_ADM_ROOT) - and then Blender (x, y, z) -> Roblox (x, z, -y).
-- Worked once here so nothing downstream re-derives it:
--
--   plant     WR_ADM_AT           (-14.0,  0.0, 12.4) -> (-14.00, 12.40,  0.00)
--   shoulder  (-25.5, 9.6, 41.5)  right, from build_wr_arm
--                                                     -> (-14.75, 23.65, -1.80)
--   wrist     (-20.5, 11.8, 51.5) from build_wr_sabre -> (-12.25, 28.65, -2.90)
--   tip       WR_SABRE_TIP        (-17.5, 9.0, 63.0)  -> (-10.75, 34.40, -1.50)
--   head      WR_ADM_HEAD         (-25.8, 3.8, 47.2)  -> (-14.90, 26.50,  1.10)
--
-- Two of those are checkable against the measured bounding boxes at the top of
-- this file and both agree: the head lands on Wrack_Skull's centre
-- (-14.54, 26.00, 1.10) and the tip reproduces boss_gen's own printed
-- "34.4 to the sabre tip".
local ADM_PLANT = Vector3.new(-14, 12.4, 0)
local ADM_SHOULDER = Vector3.new(-14.75, 23.65, -1.8)
local ADM_WRIST = Vector3.new(-12.25, 28.65, -2.9)
local ADM_TIP = Vector3.new(-10.75, 34.4, -1.5)
-- The neck, a shade under the skull's bounding box (bottom 23.7) so the head
-- turns in place instead of orbiting.
local ADM_NECK = Vector3.new(-14.6, 24.2, 1)

-- Everything above the deck that is HIM. `Wrack_Coat` is the torso, not a
-- cape - build_wr_coat lofts hips, waist, chest and collar into one object -
-- so there is no separate garment to sway against the body, and the coat tails
-- ride the man. Said out loud because "coat sway" reads as a cloth channel and
-- there is no cloth to give it.
local ADMIRAL = { "Coat", "Arm", "Sabre", "Facings", "Skull", "EyeGlow", "Hat" }

-- The arm's rest bearing, shoulder to sabre tip: (4.00, 10.75, 0.30), which is
-- 69.6 degrees above horizontal - the sabre held high, which is how he is
-- authored and where he returns between attacks.
local ARM_REST = (ADM_TIP - ADM_SHOULDER).Unit

-- The plane a stroke falls in: the vertical plane containing the arm. Derived
-- rather than typed as "about Z", so a re-export that moves his shoulder moves
-- the stroke with it.
local ARM_SWEEP_AXIS = ARM_REST:Cross(Vector3.yAxis).Unit

-- The idle. Two periods that do not divide each other, so the loop never
-- announces itself, and amplitudes measured at the hat rather than at the
-- pivot: 2.4 degrees about a plant 15.5 studs below the bicorne is 0.65 studs
-- of sway up there, which is a man breathing on a ship that is not.
local IDLE_SWAY = math.rad(2.4)
local IDLE_ROLL = math.rad(1.5)
local IDLE_SWAY_PERIOD = 5.9
local IDLE_ROLL_PERIOD = 4.3
local IDLE_BOB = 0.22
local IDLE_BOB_PERIOD = 3.4
-- The bicorne, a beat behind the head that carries it.
local HAT_LAG = 0.35
local HAT_LAG_ANGLE = math.rad(1.8)

-- The windup: the sabre goes a little higher still and shivers there. The
-- quiver is fast and TINY - 1.1 degrees at 6 Hz on a blade 6 studs long is
-- about a tenth of a stud at the tip, which reads as strain rather than as a
-- glitch.
local HIGH_ANGLE = math.rad(11)
local QUIVER_ANGLE = math.rad(1.1)
local QUIVER_RATE = 38
local HIGH_RATE = 10

-- The point: arm and sabre swing onto the attack's bearing. `POINT_RISE` is
-- how far above flat the blade finishes (0.38 -> 21 degrees up), and the turn
-- is clamped because a bearing off his own stern would otherwise fold the arm
-- through the coat.
local POINT_RISE = 0.38
local POINT_MAX = math.rad(78)
local POINT_RATE = 7
local POINT_TAIL = 0.12
local LOOK_MAX = math.rad(52)
local LOOK_RATE = 6
local LOOK_TAIL = 0.5

-- The stroke, when the guns actually go off: the arm falls through the sweep
-- plane and the blade whips a little further on the wrist and trails home.
local SWEEP_ANGLE = math.rad(40)
local SWEEP_ATTACK = 0.05
local SWEEP_RELEASE = 0.6
local FLICK_ANGLE = math.rad(22)
local FLICK_RELEASE = 0.78

-- ------------------------------------------------------------ the signals
--
-- THE ONE PLUG, and deliberately the same shape as ProjectileFxController's
-- `adaptEvent`: every wire field name this file reads lives in the function
-- below and nowhere else, so a contract move is one edit here.
--
-- WHAT THE CLIENT ACTUALLY GETS TODAY, having traced it rather than assumed
-- it (CreatureService's Wrack section, and ProjectileFxController's contract
-- header):
--
--   wrackVolley  fires the instant a volley is emitted, with `position` =
--                `origin` - the muzzle for an aimed pattern, the hull pivot
--                for a radial one. This is the only "the guns just went off"
--                edge on the wire and it is exact.
--   wrackTell    the windup, once per pattern, carrying `duration` (the row's
--                `windup`) and, for shape = "lane", `aim`.
--   telegraph    with one of Wrack's skins: `coneTell` carries `facing`, the
--                ringed ones carry only a radius.
--
-- SO THE BEARING IS AVAILABLE, BUT NOT FOR EVERY ATTACK, and that is a
-- property of the fight rather than a gap to paper over. The aimed patterns
-- (grapeshot, chainshot, anchorsweep - `K.WRACK_AIMED`) announce themselves
-- with a cone or lane tell and those carry the bearing the shot will take. The
-- radial ones (broadside, slewfire, wisps) announce themselves with a RING and
-- carry no bearing, because they do not have one: they fire at every azimuth
-- at once. Pointing on those would be a lie, so the Admiral does not point on
-- those - he holds the sabre high and quivers, which is bearing-free. No wire
-- was invented for this and none is needed.
--
-- No event on this channel names its creature, so a signal is delivered to an
-- adopted body only if it happened near it (SIGNAL_RANGE). Everything Wrack
-- fires originates within ~25 studs of his own hull, and two Wracks cannot be
-- within 220 studs of each other - they are one per island.
local SIGNAL_RANGE = 220

-- Wrack's skins, mirroring ProjectileFxController's WRACK_SKINS: the skin is
-- how a generic `telegraph` is known to be his.
local SIGNAL_SKINS = {
	cannon = true,
	grape = true,
	chain = true,
	wisp = true,
	anchor = true,
	ember = true,
	wreck = true,
}

-- Chainshot's cone arrives as SEVERAL `coneTell` events in one frame, one per
-- wedge, fanned across the arc: taking any single one points him at the edge
-- of his own fan. Tells landing this close together are averaged into one
-- bearing instead.
local WEDGE_COALESCE = 0.15

local function flatAim(value): Vector3?
	if typeof(value) ~= "Vector3" then
		return nil
	end
	local flat = Vector3.new(value.X, 0, value.Z)
	return if flat.Magnitude > 1e-3 then flat.Unit else nil
end

local function adaptSignal(kind: string, position: Vector3, extra): any?
	if kind == "wrackVolley" then
		-- A volley with no shots in it drew nothing and fired nothing; the
		-- brass should not jump for it either.
		local shots = extra.shots
		if type(shots) ~= "table" or #shots == 0 then
			return nil
		end
		return { what = "fire", at = position, now = os.clock() }
	elseif kind == "wrackTell" then
		return {
			what = "windup",
			at = position,
			-- A ring tell carries no aim and must not be given one.
			aim = if tostring(extra.shape) == "ring" then nil else flatAim(extra.aim),
			duration = tonumber(extra.duration) or 0.9,
			now = os.clock(),
		}
	elseif kind == "telegraph" and SIGNAL_SKINS[tostring(extra.skin)] then
		local sub = tostring(extra.kind)
		local aim = if sub == "coneTell" then flatAim(extra.facing) else nil
		if not aim and sub ~= "mark" and sub ~= "ringTell" and sub ~= "slam" then
			return nil
		end
		return {
			what = "windup",
			at = position,
			aim = aim,
			duration = tonumber(extra.duration) or 0.9,
			now = os.clock(),
		}
	end
	return nil
end

-- ------------------------------------ the server's own animation attributes
--
-- Written by CreatureService's Wrack section, LEVEL-TRIGGERED every one of
-- them, and named here exactly as its ATTR table names them (verified against
-- the worktree, 2026-09-09):
--
--   ATTR.WRACK_DIVE     "WrackDive"     on the FIGUREHEAD's own model
--   ATTR.WRACK_BOOM     "WrackBoom"     on the boss model
--   ATTR.WRACK_HATCHES  "WrackHatches"  on the boss model
--
-- ...and two the three-act rewrite has not published yet. Naming them now
-- costs nothing and is how the wreck rows below stay a table entry rather than
-- a merge: an attribute that is never set reads nil, which every driver here
-- already handles as its rest state.
local ATTR_WRACK_DIVE = "WrackDive"
local ATTR_WRACK_BOOM = "WrackBoom"
local ATTR_WRACK_HATCHES = "WrackHatches"
local ATTR_WRACK_WRECK = "WrackWreck"

-- How far the Lady heels into a damaging pass, how far a hatch throws open,
-- and how far the hull lists and the mast falls once she is a wreck. The two
-- wreck numbers are large on purpose: this is the fight's last beat and it has
-- to read from the birdseye camera as a shape change, not as a nudge.
local LADY_BANK = math.rad(38)
local HATCH_ANGLE = math.rad(75)
local WRECK_LIST = math.rad(16)
local WRECK_MAST_FALL = math.rad(64)

-- The boom's authored bearing in BOSS space, as a direction: what `pose` turns
-- off. +X (stowed fore-and-aft along the keel) until the mesh says otherwise,
-- and the one number in this block that a mesh landing must revisit.
local BOOM_REST = Vector3.xAxis

-- EVERY DRAWN PIECE, which is what "the hull lists" has to mean. Built rather
-- than typed, so a piece added to PIECES or MODULES tomorrow lists with the
-- ship instead of hanging in the air where it was.
--
-- The brief for the wreck beat named four pieces (Hull, Mast, Sail, Rigging).
-- Listing those four ALONE would leave the strakes, the keel, the crust, the
-- ribs, the guns and the Admiral standing upright inside a hull that had rolled
-- out from under them - the ship visibly coming apart along the seams of this
-- file's piece list, which is the one seam the player must never see. A list is
-- a rigid-body roll; it takes everything.
local WRECK_PIECES = table.clone(PIECES)
for _, module in MODULES do
	table.insert(WRECK_PIECES, module.name)
end

-- ------------------------------------------------------------- the channels

-- Turns `from` onto `to` by `amount` of the way, both unit. Returns identity
-- when they are already parallel, which is also what makes it safe to call
-- with a degenerate bearing.
local function turnBetween(from: Vector3, to: Vector3, amount: number, maxAngle: number?): CFrame
	local axis = from:Cross(to)
	local length = axis.Magnitude
	if length < 1e-4 then
		return CFrame.identity
	end
	local angle = math.atan2(length, from:Dot(to))
	if maxAngle then
		angle = math.min(angle, maxAngle)
	end
	return CFrame.fromAxisAngle(axis / length, angle * amount)
end

-- The pulse envelope: straight up over `attack`, squared fall over `release`.
local function envelope(age: number, attack: number, release: number): number
	if age < 0 then
		return 0
	elseif age < attack then
		return age / attack
	end
	local t = (age - attack) / release
	if t >= 1 then
		return 0
	end
	return (1 - t) * (1 - t)
end

-- The bearing an aimed windup latched, in BOSS space, or nil for a windup that
-- carried none (every radial pattern).
local function signalAim(ctx): Vector3?
	local sig = ctx.sig
	if not sig or not sig.aim then
		return nil
	end
	return ctx.base:VectorToObjectSpace(sig.aim)
end

-- EVERY ANIMATED THING ON THIS BOSS, in layering order. See the essay at the
-- top of this section for what a row means; a row is the whole of what it
-- takes to bind a piece to a driver.
local CHANNELS = {
	-- ========================================================================
	-- THE WRECK - BOUND, AND INERT UNTIL THE ATTRIBUTE EXISTS
	-- ========================================================================
	-- These two are the other shape of pending: their PIECES all exist today,
	-- so unlike the three above they are built and stepped every frame. What
	-- does not exist yet is `WrackWreck`, which the three-act rewrite will set
	-- when the hull dies (alongside `WrackAct`, 1/2/3, which nothing here reads
	-- - an act number is a state for the fight, not a pose, and inventing one
	-- for it would be exactly the guess the boom stub just had to unlearn).
	--
	-- INERT-SAFE BY CONSTRUCTION, not by a guard: an attribute that never
	-- appears makes `goal` 0, a level driver at 0 makes `value` 0, and the
	-- layer skips a zero-valued pose outright. The cost of carrying them until
	-- the server publishes is one GetAttribute per piece per frame, and the
	-- benefit is that the transition beat is already drawn the day it does.
	{
		name = "wreckList",
		pieces = WRECK_PIECES,
		-- The keel rabbet: she lists about the spine she is bedded on, which is
		-- the same hinge the shell plates swing off.
		pivot = HINGE,
		driver = {
			kind = "level",
			rate = 0.55,
			goal = function(ctx): number
				return if ctx.model:GetAttribute(ATTR_WRACK_WRECK) then 1 else 0
			end,
		},
		pose = function(ctx): CFrame
			return CFrame.Angles(WRECK_LIST * ctx.value, 0, 0)
		end,
	},
	{
		name = "wreckMastFall",
		pieces = { "Mast", "Rigging", "Sail" },
		-- WR_MAST_STEP, Blender (-6.5, 0, WR_KEEL_Z 1.1) -> Roblox: where the
		-- mast is stepped, and the only point it can fall about without the
		-- heel coming out of the deck.
		pivot = Vector3.new(-6.5, 1.1, 0),
		driver = {
			kind = "level",
			-- Slower than the list, so she leans first and the rig comes down
			-- after - a mast that falls with the hull reads as one rigid object
			-- tipping over rather than as a ship breaking up.
			rate = 0.35,
			goal = function(ctx): number
				return if ctx.model:GetAttribute(ATTR_WRACK_WRECK) then 1 else 0
			end,
		},
		pose = function(ctx): CFrame
			-- Positive about boss-local X carries the masthead toward +Z, which
			-- is the side the yard already dips to (WR_YARD runs to -13/+10.5 in
			-- Blender y, so she is heavier to port) - she falls the way she is
			-- already leaning.
			return CFrame.Angles(WRECK_MAST_FALL * ctx.value, 0, 0)
		end,
	},

	-- THE MELEE WINDOW, unchanged in every observable way - same attribute,
	-- same hinge, same rate, same two angles, same adopt-at-state. It is a
	-- channel now only because it was always the pattern the rest copy.
	{
		name = "shellSplit",
		pieces = { "ShellUpper", "ShellLower" },
		pivot = HINGE,
		driver = {
			kind = "level",
			rate = OPEN_RATE,
			goal = function(ctx): number
				return if ctx.model:GetAttribute(ATTR_EXPOSED) then 1 else 0
			end,
		},
		pose = function(ctx): CFrame
			return CFrame.Angles(SHELL_SWING[ctx.piece.name] * ctx.value, 0, 0)
		end,
	},

	-- A SILENCED DECK HANGS. Keyed off the same liveness the outlines are -
	-- `entry.gunLive`, which is built from the very `marks` table the
	-- weakpoint highlights walk - so the gun that stops being shootable and
	-- the gun that stops looking alive are one fact read twice, not two.
	{
		name = "gunDroop",
		pieces = {
			"CannonBow",
			"CannonStarboard",
			"CannonStern",
			"CannonPort",
			"MuzzleBow",
			"MuzzleStarboard",
			"MuzzleStern",
			"MuzzlePort",
		},
		pivot = function(ctx): Vector3
			return GUNS[ctx.piece.gun].at
		end,
		driver = {
			kind = "level",
			rate = DROOP_RATE,
			goal = function(ctx): number
				return if ctx.entry.gunLive[ctx.piece.gun] then 0 else 1
			end,
		},
		pose = function(ctx): CFrame
			local bore = GUNS[ctx.piece.gun].bore
			local side = bore:Cross(Vector3.yAxis)
			if side.Magnitude < 1e-3 then
				return CFrame.identity
			end
			-- Negative about (bore x up) drops the muzzle: for the bow chaser
			-- that axis is +Z and a negative turn about +Z takes +X toward -Y.
			return CFrame.fromAxisAngle(side.Unit, -DROOP_ANGLE * ctx.value)
				* CFrame.fromAxisAngle(bore, DROOP_LIST * ctx.value)
		end,
	},

	-- RECOIL. Straight back down the bore, sharp out and slow home. A pure
	-- translation, so its pivot never matters - stated because the row still
	-- has to name one and a reader will look for the significance.
	{
		name = "gunRecoil",
		pieces = {
			"CannonBow",
			"CannonStarboard",
			"CannonStern",
			"CannonPort",
			"MuzzleBow",
			"MuzzleStarboard",
			"MuzzleStern",
			"MuzzlePort",
		},
		pivot = Vector3.zero,
		driver = {
			kind = "pulse",
			signal = "fire",
			attack = RECOIL_ATTACK,
			release = RECOIL_RELEASE,
			pick = function(sig, piece, entry): boolean
				-- An aimed volley left ONE deck and only that one kicks; a
				-- radial volley left the hull pivot, which is every deck still
				-- standing firing at once.
				if sig.gun then
					return piece.gun == sig.gun
				end
				return entry.gunLive[piece.gun] == true
			end,
		},
		pose = function(ctx): CFrame
			return CFrame.new(GUNS[ctx.piece.gun].bore * -RECOIL_STUDS * ctx.value)
		end,
	},

	-- THE FLASH. `Wrack_MuzzleGlow` instanced at each muzzle, dark until its
	-- gun speaks. It grows from FLASH_SCALE, and the pose walks it back along
	-- the bore by exactly the scaling error that introduces: a MeshPart scales
	-- about its own centre, the flare's centre is FLARE_CENTRE past the muzzle,
	-- so at scale s the mesh's authored origin has crept FLARE_CENTRE * (1 - s)
	-- forward of the barrel unless it is pulled back.
	{
		name = "muzzleFlash",
		pieces = { "MuzzleBow", "MuzzleStarboard", "MuzzleStern", "MuzzlePort" },
		pivot = Vector3.zero,
		driver = {
			kind = "pulse",
			signal = "fire",
			attack = FLASH_ATTACK,
			release = FLASH_RELEASE,
			pick = function(sig, piece, entry): boolean
				if sig.gun then
					return piece.gun == sig.gun
				end
				return entry.gunLive[piece.gun] == true
			end,
		},
		pose = function(ctx): CFrame
			local scale = FLASH_SCALE + (1 - FLASH_SCALE) * ctx.value
			return CFrame.new(GUNS[ctx.piece.gun].bore * (FLARE_CENTRE * (scale - 1)))
		end,
		-- Transparency and size are not CFrames, so they come through the
		-- optional second hook rather than through `pose`. It runs every frame,
		-- including the ones at rest, which is what puts the flare away again.
		paint = function(ctx)
			local value = ctx.value
			local part = ctx.piece.part
			local transparency = 1 - value ^ 0.6
			-- Guarded, because this runs on every frame of a fight that is
			-- mostly not firing, and a property write is not free even when
			-- the value it writes is the one already there.
			if part.Transparency ~= transparency then
				part.Transparency = transparency
				part.Size = ctx.piece.size * (FLASH_SCALE + (1 - FLASH_SCALE) * value)
			end
		end,
	},

	-- THE IDLE. The ship is dead still; he is not. Sway and roll about the
	-- plant where his coat goes into the timber, and a slow bob on top, at
	-- three periods that do not line up.
	{
		name = "admIdle",
		pieces = ADMIRAL,
		pivot = ADM_PLANT,
		driver = { kind = "free" },
		pose = function(ctx): CFrame
			local now = ctx.now
			local sway = math.sin(now * (math.pi * 2 / IDLE_SWAY_PERIOD))
			local roll = math.sin(now * (math.pi * 2 / IDLE_ROLL_PERIOD) + 1.1)
			local bob = math.sin(now * (math.pi * 2 / IDLE_BOB_PERIOD))
			return CFrame.new(0, IDLE_BOB * bob, 0) * CFrame.Angles(IDLE_ROLL * roll, 0, IDLE_SWAY * sway)
		end,
	},

	-- HE LOOKS WHERE HE IS ABOUT TO SHOOT. Held for the windup, then let go
	-- slowly (LOOK_TAIL) so the head is still on the bearing when the shot
	-- leaves rather than snapping back at the tell's last frame.
	{
		name = "admLook",
		pieces = { "Skull", "EyeGlow", "Hat" },
		pivot = ADM_NECK,
		driver = {
			kind = "hold",
			signal = "windup",
			rate = LOOK_RATE,
			tail = LOOK_TAIL,
			accept = function(sig): boolean
				return sig.aim ~= nil
			end,
			merge = true,
		},
		pose = function(ctx): CFrame
			local aim = signalAim(ctx)
			if not aim then
				return CFrame.identity
			end
			return turnBetween(Vector3.xAxis, aim, ctx.value, LOOK_MAX)
		end,
	},

	-- The bicorne, trailing the head by a beat.
	{
		name = "admHatLag",
		pieces = { "Hat" },
		pivot = ADM_NECK,
		driver = { kind = "free" },
		pose = function(ctx): CFrame
			local lag = math.sin((ctx.now - HAT_LAG) * (math.pi * 2 / IDLE_SWAY_PERIOD))
			return CFrame.Angles(0, 0, HAT_LAG_ANGLE * lag)
		end,
	},

	-- THE POINT. Arm and sabre swing onto the bearing an aimed windup latched
	-- - and only an aimed one; see the signals essay above for why the radial
	-- patterns get no bearing and must not be given a pretend one.
	--
	-- WHAT THIS CANNOT TAKE WITH IT: his right CUFF. build_wr_facings welds
	-- lapels, sash, buttons, both epaulettes, both cuffs and the bicorne's lace
	-- into ONE object, so there is no way to move the wrist's gold without
	-- dragging the hat's. The epaulette sits on the pivot and does not care;
	-- the cuff is a ring 0.8 studs across that stays behind. Named rather than
	-- hidden, because the fix is a mesh split and belongs to boss_gen, not to a
	-- clamp here that would cost the gesture to save a ring.
	{
		name = "admPoint",
		pieces = { "Arm", "Sabre" },
		pivot = ADM_SHOULDER,
		driver = {
			kind = "hold",
			signal = "windup",
			rate = POINT_RATE,
			tail = POINT_TAIL,
			accept = function(sig): boolean
				return sig.aim ~= nil
			end,
			merge = true,
		},
		pose = function(ctx): CFrame
			local aim = signalAim(ctx)
			if not aim then
				return CFrame.identity
			end
			return turnBetween(ARM_REST, (aim + Vector3.new(0, POINT_RISE, 0)).Unit, ctx.value, POINT_MAX)
		end,
	},

	-- THE STROKE. The one edge on the wire that means "the guns just went
	-- off", spent on the one gesture the whole silhouette is built around.
	{
		name = "admSweep",
		pieces = { "Arm", "Sabre" },
		pivot = ADM_SHOULDER,
		driver = { kind = "pulse", signal = "fire", attack = SWEEP_ATTACK, release = SWEEP_RELEASE },
		pose = function(ctx): CFrame
			return CFrame.fromAxisAngle(ARM_SWEEP_AXIS, -SWEEP_ANGLE * ctx.value)
		end,
	},

	-- THE SABRE HELD HIGH, through any windup at all - this one is deliberately
	-- bearing-free, so the radial patterns still get a tell on the man.
	{
		name = "admHigh",
		pieces = { "Sabre" },
		pivot = ADM_WRIST,
		driver = { kind = "hold", signal = "windup", rate = HIGH_RATE },
		pose = function(ctx): CFrame
			local quiver = math.sin(ctx.now * QUIVER_RATE)
			return CFrame.fromAxisAngle(ARM_SWEEP_AXIS, (HIGH_ANGLE + QUIVER_ANGLE * quiver) * ctx.value)
		end,
	},

	-- ...and the blade whips past the arm and trails home behind it. On the
	-- WRIST, so the hilt stays in his hand while it does.
	{
		name = "admFlick",
		pieces = { "Sabre" },
		pivot = ADM_WRIST,
		driver = { kind = "pulse", signal = "fire", attack = SWEEP_ATTACK, release = FLICK_RELEASE },
		pose = function(ctx): CFrame
			return CFrame.fromAxisAngle(ARM_SWEEP_AXIS, -FLICK_ANGLE * ctx.value)
		end,
	},

	-- ========================================================================
	-- THE INBOUND CONTRACTS - WIRE BOUND, MESH PENDING
	-- ========================================================================
	-- These three landed their SERVER half on 2026-09-09 and are bound to it
	-- below. Each is now inert for exactly ONE reason: its pieces are not in
	-- PIECES/AUTHORED yet, so buildChannels drops the row at adopt and nothing
	-- runs. Adding the piece name is the whole of what is left.
	--
	-- Do NOT delete one to "clean up": deleting it is how the next lane lands a
	-- mesh piece that draws in its authored pose forever and reads as "the
	-- animation isn't hooked up yet".
	--
	-- ALL THREE ARE LEVEL DRIVERS, and none of them is an event - which is not
	-- a coincidence and is worth stating once, because the first draft of this
	-- block guessed events for all three. A boom has a BEARING, a hatch is OPEN
	-- or SHUT, and a figurehead is either on her stem or somewhere else: those
	-- are states, and a client that adopts the hull mid-move must be able to
	-- read the state it is actually in rather than having missed an edge. The
	-- server lane's own note says it in the same words the melee window's does.

	-- (1) THE LADY BELOW. Her POSITION IS NOT ON THE WIRE, deliberately: she is
	-- a creature model the server PivotTos every frame, so her CFrame
	-- replicates natively, and a per-frame attribute copy of a position the
	-- engine already replicates is "a second, slower, lossier truth about the
	-- same thing" (CreatureService's ATTR.WRACK_DIVE note). So this channel
	-- reads her MODEL, and `WrackDive` carries only what her model cannot say:
	-- 0 while she swings out or re-arms, `n` on the n-th damaging pass, and
	-- gone the instant she re-docks or is shot down.
	--
	-- SHE IS FOUND BY THE ATTRIBUTE ITSELF, not by a creature-row id. Nothing
	-- else in the game carries `WrackDive`, the attribute is the contract the
	-- server lane published, and keying on it means this file never has to
	-- agree with `Bosses` about a row name it cannot see change. `entry.lady`
	-- is the nearest live one, resolved once a frame in drawBody.
	--
	-- WHAT THE POSE DOES: rides her model exactly, easing on and off so the
	-- unshipping and the redock are travelled rather than cut, and banking into
	-- the pass. AN ASSUMPTION IS BURIED HERE AND IS BEING SAID OUT LOUD: this
	-- draws the figurehead ON her hitbox, which leaves the stem bare while she
	-- is out - the "docked piece hides" half of the brief - and assumes her
	-- server prop is either invisible or is meant to BE this mesh. If she turns
	-- out to need her own visible body, the change is to hide the prop the way
	-- hideServerModel hides the boss, not to change this pose.
	--
	-- TO LAND IT: add "Figurehead" to PIECES and AUTHORED. Nothing else.
	{
		name = "figureheadFlight",
		pieces = { "Figurehead" },
		-- The layer conjugates every pose by CFrame.new(pivot - AUTHORED_ANCHOR);
		-- naming the anchor itself makes that the identity, which is what lets
		-- this row place the piece ABSOLUTELY rather than as an offset from
		-- where it is docked. The only row that does; see the pose.
		pivot = AUTHORED_ANCHOR,
		driver = {
			kind = "level",
			rate = 5,
			goal = function(ctx): number
				return if ctx.entry.lady then 1 else 0
			end,
		},
		pose = function(ctx): CFrame
			local lady = ctx.entry.lady
			if not lady then
				return CFrame.identity
			end
			-- Bank hard on a damaging pass (`WrackDive` >= 1) and barely at all
			-- while she is swinging out or re-arming (0), which is the whole
			-- difference the attribute exists to carry.
			local bank = if (ctx.entry.ladyDive or 0) >= 1 then LADY_BANK else LADY_BANK * 0.25
			-- The offset that puts this piece exactly on her model: solve
			-- `base * prior * mine * relative = ladyCF * bank` for `mine`.
			-- `prior` is what the channels ahead of this one have already done
			-- to the piece THIS frame - the wreck roll, today - and dividing it
			-- out is what keeps an absolute placement absolute no matter what
			-- gets layered outside it later. Lerped from the identity, so value
			-- 0 is the authored dock (which the layer requires) and the trip
			-- between is travelled rather than cut.
			local prior = ctx.piece.offset or CFrame.identity
			local onHer = prior:Inverse()
				* ctx.base:Inverse()
				* lady:GetPivot()
				* CFrame.Angles(bank, 0, 0)
				* ctx.piece.relative:Inverse()
			return CFrame.new():Lerp(onHer, ctx.value)
		end,
	},

	-- (2) THE BOOM. `WrackBoom` is the spar's live WORLD bearing in radians in
	-- Fn.wrackAngle's convention - `math.atan2(dir.Z, dir.X)`, so 0 is +X - and
	-- it is nil the instant the boom is stowed OR its tackle is shot away. Nil
	-- is therefore "no boom out", which is a state this has to be able to reach
	-- from a dropped tackle as well as from a finished sweep: hence a level on
	-- the attribute's PRESENCE, with the bearing read fresh inside the pose.
	--
	-- The bearing is turned into a DIRECTION and handed to turnBetween rather
	-- than differenced as an angle. That is deliberate: an angle subtraction
	-- has to get the boss's own yaw, the sign of a Y rotation and the wrap at
	-- +-pi all right at once, and every one of those is a coin flip a reader
	-- cannot check. A direction through VectorToObjectSpace is correct by
	-- construction and uses the same helper the Admiral's point does.
	--
	-- The last bearing is latched in the channel's own scratch so a stowed boom
	-- eases home FROM where it was rather than snapping to the rest bearing on
	-- the frame the attribute clears.
	--
	-- TO LAND IT: add "Boom" to PIECES and AUTHORED, and set `pivot` to the
	-- gooseneck and BOOM_REST to the spar's authored bearing.
	{
		name = "boomSweep",
		pieces = { "Boom" },
		pivot = Vector3.zero, -- REPLACE with the gooseneck
		driver = {
			kind = "level",
			rate = 3.5,
			goal = function(ctx): number
				return if tonumber(ctx.model:GetAttribute(ATTR_WRACK_BOOM)) then 1 else 0
			end,
		},
		pose = function(ctx): CFrame
			local bearing = tonumber(ctx.model:GetAttribute(ATTR_WRACK_BOOM))
			if bearing then
				ctx.state.bearing = bearing
			end
			bearing = ctx.state.bearing
			if not bearing then
				return CFrame.identity
			end
			local world = Vector3.new(math.cos(bearing), 0, math.sin(bearing))
			return turnBetween(BOOM_REST, ctx.base:VectorToObjectSpace(world), ctx.value)
		end,
	},

	-- (3) THE HATCHES. `WrackHatches` is a BITMASK - bit (i-1) set means hatch
	-- `i` of the boss row's `hatches` list is open, in that list's authored
	-- order, the same convention `parts.mounts` lives under - and nil when
	-- every hatch is shut.
	--
	-- LEVEL, NOT PULSE, and this is the correction the server lane asked for:
	-- an open hatch STAYS open, so a pulse would have popped it and let it fall
	-- shut again underneath a mask that still said open. The index comes off
	-- the piece name (`Hatch3` -> 3), parsed once at adopt, so the client never
	-- keeps its own list of which hatch is which - which is the shape of bug
	-- the one-attribute-not-three-booleans decision exists to prevent, and it
	-- would be silly to reintroduce it on this side of the wire.
	--
	-- TO LAND IT: add "Hatch1".."Hatch<n>" to PIECES and AUTHORED - as many as
	-- the boss row's `hatches` list has - and give `pivot` each hatch's hinge.
	{
		name = "hatchPops",
		pieces = { "Hatch1", "Hatch2", "Hatch3", "Hatch4" },
		pivot = Vector3.zero, -- REPLACE with each hatch's hinge (a pivot fn)
		driver = {
			kind = "level",
			rate = 7,
			goal = function(ctx): number
				local mask = tonumber(ctx.model:GetAttribute(ATTR_WRACK_HATCHES))
				local index = ctx.piece.index
				if not mask or not index then
					return 0
				end
				return if bit32.band(mask, bit32.lshift(1, index - 1)) ~= 0 then 1 else 0
			end,
		},
		pose = function(ctx): CFrame
			return CFrame.Angles(HATCH_ANGLE * ctx.value, 0, 0)
		end,
	},
}

-- ------------------------------------------------------------ the weakpoints
--
-- "MAKE SURE THEY ARE VISIBLE AND THE USER ACTUALLY KNOWS WHERE TO SHOOT"
-- (user, live playtest, 2026-09-08). The four gun-deck batteries ARE the
-- fight - Wrack refuses damage while `partsAlive > 0` - and they are cannons
-- built into a dark hull, half-swallowed by the very ship this controller
-- draws over the top of them. A player looking at that hull has no way to
-- tell which brass is the door.
--
-- WHAT IS DRAWN, and why two states rather than one. A live weakpoint carries
-- a permanent OUTLINE - drawn AlwaysOnTop, so the hull this file assembles
-- cannot bury the thing the hull is gated on - with the fill kept nearly
-- clear, because it is a pointer and not a paint job. The one battery winding
-- up a Cannon Overload pulses hot and hard instead: that move is a "shoot THIS
-- one, now" and the fight already tells you so twice on the ground (a disc on
-- the gun and a wedge along the bearing) - this is the third telling, on the
-- gun itself, where the shot has to go.
--
-- IT IS KEYED OFF THE SERVER'S CONTRACT, NOT OFF A LIST OF ROW IDS.
-- CreatureService stamps `Weakpoint` on every part of a `vulnerableWhen =
-- "partsDown"` boss and `WeakpointHot` on the battery currently charging; both
-- are level-triggered, so a client that adopts a model mid-windup reads the
-- true state rather than having missed an edge. That is why this polls the
-- attributes in the draw loop instead of binding to changed signals - the same
-- argument the hull's own `Exposed` chase makes twelve lines up, and for the
-- same payoff: a dropped signal costs a frame, never a stuck outline.
--
-- WHY IT LIVES IN WRACK'S FILE. `Weakpoint` is a general contract - the
-- Kraken's arm ring carries it too - so this is not, strictly, Wrack-only
-- code, and honesty demands the note: it is here because Wrack's fight is what
-- demanded it and because a controller of its own would have to be registered
-- in init.client.luau, which other lanes hold. If a second fight ever wants to
-- style its weakpoints differently, lift this section into its own controller
-- rather than growing a switch here.
local ATTR_WEAKPOINT = "Weakpoint"
local ATTR_WEAKPOINT_HOT = "WeakpointHot"

-- The resting mark: the batteries' own muzzle glow (`Creatures.wrack_battery`
-- body.markColor is 255/190/120), pushed a little hotter so an outline of it
-- separates from the pale shoal sand as well as from the hull.
local MARK_COLOR = Color3.fromRGB(255, 178, 74)
local MARK_FILL = 0.87
local MARK_OUTLINE = 0.1

-- ...and the overload. Red, because nothing else in this fight's palette is,
-- and pulsed rather than merely brighter - a steady colour change is a thing
-- you notice once and a pulse is a thing that keeps asking.
local HOT_COLOR = Color3.fromRGB(255, 88, 56)
local HOT_RATE = 13 -- radians per second: a touch over two pulses a second
local HOT_FILL = 0.6
local HOT_FILL_SWING = 0.3

local warnedMissingPack = false

-- ---------------------------------------------------------------- pieces

local function packPiece(name: string): BasePart?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local pack = assets and assets:FindFirstChild(PACK_NAME)
	local piece = pack and pack:FindFirstChild(PREFIX .. name, true)
	return if piece and piece:IsA("BasePart") then piece else nil
end

-- One drawable piece: the authored mesh if it is imported, else a block of
-- its authored bulk so the ship still reads.
local function makePiece(name: string, parent: Instance): BasePart
	local template = packPiece(name)
	local part
	if template then
		part = template:Clone()
	else
		if not warnedMissingPack then
			warnedMissingPack = true
			warn("[WrackBody] " .. PACK_NAME .. " not imported - drawing stand-ins")
		end
		local authored = AUTHORED[name]
		part = Instance.new("Part")
		part.Size = if authored then authored.size else Vector3.new(10, 10, 10)
		part.Color = if authored then authored.color else Color3.fromRGB(30, 35, 41)
		part.Material = Enum.Material.SmoothPlastic
	end
	-- REPAINT THE IMPORT. Studio's glTF importer does NOT carry colour across:
	-- every cloned pack part arrives at Roblox's default grey, which is why the
	-- first import of the Careenage came up flat, arena and boss alike.
	--
	-- The inversion this fixes is worth stating, because it reads as a broken
	-- import rather than a missing repaint: the stand-in branch above has ALWAYS
	-- tinted from `AUTHORED`, so before this line, importing the real mesh made
	-- Wrack look WORSE than not importing it.
	--
	-- Same placement rule as the Neon assert below and for the same reason -
	-- AFTER the branch, never inside it, so it reaches the cloned pack part and
	-- the stand-in alike. It sits BEFORE the Neon assert so the glow pieces keep
	-- their material: a repaint that ran afterwards would flatten the
	-- heart-lantern back to plastic.
	--
	-- Keyed on the FULL object name, `PREFIX .. name` - `MeshColors` rows are
	-- the Blender object names ("Wrack_Hull"), not the bare piece names this
	-- file indexes `PIECES` and `AUTHORED` by. Not `part.Name`: that is not
	-- assigned until below, so a stand-in would silently miss every lookup.
	local color = MeshColors.get(PREFIX .. name)
	if color then
		part.Color = color
		-- A textured PBR surface overrides Color outright. boss_gen authors one
		-- flat material per object and never a texture, so anything the importer
		-- attached here is noise (BossArenaService drops it on the same grounds).
		local appearance = part:FindFirstChildWhichIsA("SurfaceAppearance")
		if appearance then
			appearance:Destroy()
		end
	end
	-- AFTER the branch, never inside it. A clone keeps whatever the importer
	-- gave it and a stand-in has just been set to SmoothPlastic, so this is
	-- the only place that reaches both - and the cloned mesh is the case that
	-- actually matters. Put in the else branch it would light the stand-in
	-- and leave the real heart-lantern flat, which is the exact failure it
	-- exists to prevent and the one that reads as correct in review.
	if string.find(name, GLOW_MARKER, 1, true) then
		part.Material = Enum.Material.Neon
	end
	part.Name = PREFIX .. name
	part.Anchored = true
	-- The footing and the hitboxes are the SERVER's, never ours: his hit
	-- volume is `hitRadius` math and the four battery creatures, and nothing
	-- about him is walked on (there is no climb route like Pyrelisk's
	-- _WalkArm - you fight him from the Careenage's sand).
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Parent = parent
	return part
end

-- Where the assembly's own origin sits inside the pack, so a piece's offset
-- can be measured from it. Falls back to the authored constant when the pack
-- is missing, which is what keeps the stand-in path and the clone path
-- placing the ship in the same spot.
local function packAnchor(): CFrame
	local base = packPiece("Base")
	return CFrame.new(if base then base.Position else AUTHORED_ANCHOR)
end

-- ---------------------------------------------------------------- lifecycle

local bodies: { [Model]: any } = {}

-- Every weakpoint model we are currently outlining -> its Highlight. The
-- Highlight is parented to the model it marks, so a battery that is destroyed
-- or streams out takes its own outline with it; this table exists so the draw
-- loop has something to walk and so a model that merely STOPS being a
-- weakpoint (the attribute cleared without the model dying) loses the mark
-- too. Both exits go through unmarkWeakpoint.
local marks: { [Model]: Highlight } = {}

-- THE LADY BELOW, by the only thing that identifies her: `WrackDive`. She is a
-- creature model like any other in this folder and nothing about her shape says
-- what she is, so she is tracked by the attribute the server publishes for
-- exactly this purpose - the same argument the weakpoints are tracked by
-- `Weakpoint` rather than by a list of row ids, one section up.
--
-- Membership here means LIVE: the attribute is cleared the instant she re-docks
-- or is shot down (and her model is despawned a beat later), so a row leaving
-- this table is the redock cue as well as the "she's gone" one.
local ladies: { [Model]: boolean } = {}

local function watchLady(model: Model)
	ladies[model] = if model:GetAttribute(ATTR_WRACK_DIVE) ~= nil then true else nil
end

local function unmarkWeakpoint(model: Model)
	local mark = marks[model]
	if not mark then
		return
	end
	marks[model] = nil
	mark:Destroy()
end

local function markWeakpoint(model: Model)
	if marks[model] or model:GetAttribute(ATTR_WEAKPOINT) ~= true then
		return
	end
	local mark = Instance.new("Highlight")
	mark.Name = "WeakpointMark"
	mark.Adornee = model
	-- Through the hull. This controller draws twenty-odd pieces of flagship
	-- over the top of these cannons; an occluded outline would be an outline
	-- that answers the question only when you already know the answer.
	mark.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	mark.FillColor = MARK_COLOR
	mark.FillTransparency = MARK_FILL
	mark.OutlineColor = MARK_COLOR
	mark.OutlineTransparency = MARK_OUTLINE
	mark.Parent = model
	marks[model] = mark
end

-- One frame of every outline. Cheap: four properties on at most a handful of
-- Highlights, and only the hot one changes from frame to frame.
local function drawMarks()
	local pulse = 0.5 + 0.5 * math.sin(os.clock() * HOT_RATE)
	for model, mark in marks do
		if not model.Parent or model:GetAttribute(ATTR_WEAKPOINT) ~= true then
			unmarkWeakpoint(model)
		elseif model:GetAttribute(ATTR_WEAKPOINT_HOT) == true then
			mark.FillColor = HOT_COLOR
			mark.OutlineColor = HOT_COLOR
			mark.FillTransparency = HOT_FILL - HOT_FILL_SWING * pulse
			mark.OutlineTransparency = 0
		else
			mark.FillColor = MARK_COLOR
			mark.OutlineColor = MARK_COLOR
			mark.FillTransparency = MARK_FILL
			mark.OutlineTransparency = MARK_OUTLINE
		end
	end
end

local function destroyBody(model: Model)
	local entry = bodies[model]
	if not entry then
		return
	end
	bodies[model] = nil
	if entry.folder then
		entry.folder:Destroy()
	end
end

-- The visible boss is ours, so the server's model has to stop showing - or
-- there are two Wracks standing in the same sand.
--
-- Every sibling gets this for free from the server: CreatureService's
-- hideColossusModel does it, and every call site is gated on the Bosses row
-- carrying `pose` (Rimefang's driver does the same thing inline). Wrack has
-- no `pose` and must not be given one - see CREATURE_ID above - and there is
-- no Wrack driver in CreatureService, so nothing server-side will ever hide
-- him and the client that draws the replacement is the only place left that
-- can. Doing it here is local to this player, costs the fight nothing, and
-- goes quietly idempotent the day a server-side hide does land.
--
-- Transparency only, exactly like hideColossusModel: the parts stay, because
-- hits and BossHudController read them, and CanCollide is never touched.
local function hideServerModel(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Transparency = 1
			descendant.CastShadow = false
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Transparency = 1
		end
	end
end

-- ----------------------------------------------------- the channel runtime

-- WHICH GUN A WORLD POINT BELONGS TO, or nil for a point that belongs to none.
-- Used for two different questions with the same answer: which deck a volley
-- left, and which cannon a live battery model is standing on. Flat, because
-- the volley's 5-stud muzzle lift and the battery's own half-height are both
-- height and neither is identity.
local function gunAt(entry, at: Vector3): string?
	local point = entry.base:PointToObjectSpace(at)
	local best, bestSq = nil, MUZZLE_MATCH * MUZZLE_MATCH
	for name, gun in GUNS do
		local offset = (gun.at - AUTHORED_ANCHOR) - point
		local sq = offset.X * offset.X + offset.Z * offset.Z
		if sq < bestSq then
			best, bestSq = name, sq
		end
	end
	return best
end

-- WHICH DECKS ARE STILL STANDING, rebuilt each frame from `marks` - the very
-- table the weakpoint outlines are drawn from. One fact, read twice: a gun
-- stops being shootable and stops looking alive at the same instant, because
-- both are the same lookup.
--
-- ABSENCE IS THE ONLY EVIDENCE OF DEATH HERE (the server DESTROYS a destroyed
-- battery model), and absence is also what an un-replicated ring looks like
-- from a client that has just adopted the boss. So nothing droops until this
-- client has seen at least one battery alive: `sawGuns`. Without that latch,
-- every Wrack would arrive with four dead guns and ease them back up, which
-- reads as a bug in the regrow rather than as a missing table.
local function stepGuns(entry)
	local live = entry.gunLive
	local seen = false
	for name in GUNS do
		live[name] = false
	end
	for model in marks do
		if model.Parent then
			local name = gunAt(entry, model:GetPivot().Position)
			if name then
				live[name] = true
				seen = true
			end
		end
	end
	if seen then
		entry.sawGuns = true
	elseif not entry.sawGuns then
		for name in GUNS do
			live[name] = true
		end
	end
end

-- The Lady this hull is currently flying, and which pass she is on. Resolved
-- once a frame rather than inside the channel, so the two things that read her
-- - the driver's goal and the pose - cannot disagree about whether she exists.
--
-- Ranged against the hull for the same reason a signal is: nothing on her model
-- names her boss, and everything Wrack throws stays inside his own shoal.
local function stepLady(entry)
	entry.lady, entry.ladyDive = nil, nil
	for model in ladies do
		if not model.Parent then
			ladies[model] = nil
		elseif (model:GetPivot().Position - entry.base.Position).Magnitude <= SIGNAL_RANGE then
			entry.lady = model
			-- 0 while she swings out or re-arms, n on the n-th damaging pass.
			entry.ladyDive = tonumber(model:GetAttribute(ATTR_WRACK_DIVE))
			return
		end
	end
end

-- One channel's worth of a frame. `entry.adopting` is true only on the very
-- first drawn frame and makes every eased driver arrive AT its goal instead of
-- easing in from rest - the same argument the shell's `open` made when it read
-- `Exposed` at adopt: easing in would animate an event that happened before
-- this client was watching, which is the same lie as missing it.
local function stepChannel(channel, ctx)
	local def = channel.def
	local driver = def.driver
	local kind = driver.kind
	for _, piece in channel.pieces do
		local state = channel.state[piece.name]
		local value
		if kind == "pulse" then
			value = envelope(ctx.now - state.firedAt, driver.attack, driver.release)
		elseif kind == "free" then
			value = 1
		else
			local goal
			if kind == "hold" then
				goal = if ctx.now < state.holdUntil then 1 else 0
			else
				ctx.piece, ctx.value, ctx.sig, ctx.state = piece, state.value, state.sig, state
				goal = driver.goal(ctx)
			end
			if ctx.entry.adopting then
				state.value = goal
			else
				state.value += (goal - state.value) * math.clamp(driver.rate * ctx.dt, 0, 1)
			end
			value = state.value
		end
		ctx.piece, ctx.value, ctx.sig, ctx.state = piece, value, state.sig, state
		-- A pose is identity at zero by contract, so skipping it there is a
		-- true no-op and not a dropped frame of animation.
		if value > 1e-4 or kind == "free" then
			local pivot = def.pivot
			if type(pivot) == "function" then
				pivot = pivot(ctx)
			end
			local pose = def.pose(ctx)
			local at = CFrame.new(pivot - AUTHORED_ANCHOR)
			piece.offset = (piece.offset or CFrame.identity) * at * pose * at:Inverse()
		end
		-- ...but `paint` always runs, because it is what puts a thing away.
		if def.paint then
			def.paint(ctx)
		end
	end
end

-- Apply one normalised signal to one adopted body. Every field the drivers
-- read is set here, so a driver never reaches past its own channel.
--
-- Split from the range gate below because `cue` names its model outright: a
-- caller that has an entry in its hand has already answered "which boss", and
-- re-asking by distance would only give it a way to be wrong.
local function applySignal(entry, sig)
	-- Resolved once per body rather than per channel: two channels ask which
	-- gun fired and they must not be able to disagree.
	sig.gun = if sig.what == "fire" then gunAt(entry, sig.at) else nil
	for _, channel in entry.channels do
		local driver = channel.def.driver
		if driver.signal ~= sig.what then
			continue
		end
		if driver.accept and not driver.accept(sig) then
			continue
		end
		for _, piece in channel.pieces do
			if driver.pick and not driver.pick(sig, piece, entry) then
				continue
			end
			local state = channel.state[piece.name]
			local carried = sig
			if
				driver.merge
				and state.sig
				and sig.aim
				and state.sig.aim
				and sig.now - state.sig.now < WEDGE_COALESCE
			then
				-- One cone, several wedge tells, one frame: average them into
				-- the bearing the fan is actually centred on.
				local count = (state.sig.count or 1) + 1
				local mean = state.sig.aim * (count - 1) + sig.aim
				carried = {
					what = sig.what,
					at = sig.at,
					aim = if mean.Magnitude > 1e-3 then mean.Unit else sig.aim,
					duration = sig.duration,
					now = sig.now,
					count = count,
				}
			end
			state.sig = carried
			if driver.kind == "pulse" then
				state.firedAt = carried.now
			else
				state.holdUntil = carried.now + (carried.duration or 0.8) + (driver.tail or 0)
			end
		end
	end
end

-- ...and the wire's own way in: the same apply, gated on the signal having
-- happened near this hull. Nothing on the CreatureEvent channel names its
-- creature, so distance is the only thing that can answer "whose was that".
local function deliverSignal(entry, sig)
	if (sig.at - entry.base.Position).Magnitude > SIGNAL_RANGE then
		return
	end
	applySignal(entry, sig)
end

-- The channels this body actually has. A row naming a piece the mesh has not
-- got yet contributes nothing and is DROPPED rather than kept with an empty
-- piece list, so an unlanded adapter stub costs zero per frame and cannot
-- half-run.
local function buildChannels(entry)
	local out = {}
	for _, def in CHANNELS do
		local pieces = {}
		for _, name in def.pieces do
			local piece = entry.byName[name]
			if piece then
				table.insert(pieces, piece)
			end
		end
		if #pieces > 0 then
			local state = {}
			for _, piece in pieces do
				state[piece.name] = { value = 0, firedAt = -1e9, holdUntil = 0, sig = nil }
			end
			table.insert(out, { def = def, pieces = pieces, state = state })
		end
	end
	return out
end

local function adoptBoss(model: Model)
	if bodies[model] or model:GetAttribute("CreatureId") ~= CREATURE_ID then
		return
	end

	-- WHERE SAND LEVEL IS, measured once. The ship is authored with y = 0 at
	-- the shoal's surface, but a creature's pivot is its CENTRE: spawn()
	-- hands an `upright` row `uprightOrientation`, whose halfThickness is
	-- exactly pivot-to-box-bottom, and groundedPos then stands the model at
	-- surface + halfThickness. So the server model's bounding-box bottom IS
	-- the sand, and this drop is the same number read back off the geometry.
	--
	-- Measured once rather than per frame because it is a property of the
	-- model's shape, not of where the fight has moved it - which is what lets
	-- the assembly ride the rise and the deck slew for free.
	local pivot = model:GetPivot()
	local boxCFrame, boxSize = model:GetBoundingBox()
	local groundDrop = (boxCFrame.Position.Y - boxSize.Y / 2) - pivot.Position.Y

	hideServerModel(model)

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace

	-- One measurement of the authored layout, taken from the pack itself, so
	-- the 24 pieces keep the exact relationship they were built with. The
	-- whole ship then moves as one CFrame forever after.
	local anchor = packAnchor()
	local pieces = {}
	local byName = {}
	for index, name in PIECES do
		local part = makePiece(name, folder)
		local authored = AUTHORED[name]
		local relative
		if packPiece(name) then
			relative = anchor:Inverse() * part.CFrame
		else
			relative = CFrame.new((if authored then authored.at else Vector3.zero) - AUTHORED_ANCHOR)
		end
		pieces[index] = {
			name = name,
			part = part,
			relative = relative,
			size = part.Size,
			-- A piece whose name ends in a number carries it (`Hatch3` -> 3),
			-- so a channel can address one of a numbered set without keeping
			-- its own list of which is which. Parsed once here rather than in a
			-- driver, because a driver runs every frame. No piece drawn today
			-- ends in a digit, so this is nil for all of them.
			index = tonumber(string.match(name, "%d+$")),
		}
		byName[name] = pieces[index]
	end

	-- THE INSTANCED MODULES, after the placed pieces so they draw over them.
	-- `Wrack_MuzzleGlow` is authored at the origin with +X as the bore, so its
	-- place is BUILT rather than measured: stand the mesh's authored origin on
	-- the gun's muzzle, aim its +X down the bore, and push the part forward by
	-- the flare's own bounding-box centre so the mesh - not the part - is what
	-- lands on the barrel.
	for _, module in MODULES do
		local gun = GUNS[module.gun]
		local part = makePiece(module.module, folder)
		local bore = CFrame.fromMatrix(gun.muzzle - AUTHORED_ANCHOR, gun.bore.Unit, Vector3.yAxis)
		local piece = {
			name = module.name,
			part = part,
			relative = bore * CFrame.new(AUTHORED.MuzzleGlow.at),
			size = part.Size,
			gun = module.gun,
		}
		-- Dark until its gun speaks; the flash channel owns it from here.
		part.Transparency = 1
		table.insert(pieces, piece)
		byName[module.name] = piece
	end

	-- The gun a cannon piece IS, so the recoil and droop channels can pick by
	-- it without re-deriving anything from the name at draw time.
	for name in GUNS do
		local piece = byName[name]
		if piece then
			piece.gun = name
		end
	end

	local entry = {
		folder = folder,
		pieces = pieces,
		byName = byName,
		groundDrop = groundDrop,
		-- Known before the first draw, because a signal can arrive between
		-- adopt and the first RenderStepped and `deliverSignal` measures
		-- against it.
		base = CFrame.new(pivot.Position + Vector3.new(0, groundDrop, 0)) * pivot.Rotation,
		gunLive = {},
		sawGuns = false,
		-- ADOPTED AT THE STATE THE FIGHT IS ALREADY IN, not at rest.
		--
		-- This is the case the level-triggered attributes exist for. A player
		-- who joins mid-window - or whose controller adopts the boss a frame
		-- after the last battery fell, or who walks into streaming range with
		-- the hull already split - has no edge to have missed, so every eased
		-- driver arrives AT its goal on the first drawn frame rather than
		-- easing in from rest. Easing in on adopt would animate an event that
		-- happened before this client was watching, which is the same lie as
		-- missing it.
		adopting = true,
		-- One context table for the life of the body: the draw loop fills it
		-- and hands it to every pose, so a frame of animation allocates
		-- nothing.
		ctx = { model = model },
	}
	entry.channels = buildChannels(entry)
	entry.ctx.entry = entry
	bodies[model] = entry
end

-- ---------------------------------------------------------------- the draw

-- THE SHIP IS STILL ONE CFRAME. The pivot says where the hull is and which way
-- the guns point, and every piece is a fixed offset from it; what the channel
-- layer adds is one more CFrame between the two, and only for the pieces some
-- channel is currently posing.
--
-- No yaw correction is applied and none is needed. The engine's creature
-- convention puts a body's +X along its heading (yawToward swings "the
-- flat-laid long axis (+X)" onto the bearing), and boss_gen authors Wrack
-- "facing +X (bow at +X, stern at -X)". The two already agree.
--
-- Attributes are POLLED here rather than bound to changed-signals, and that is
-- what makes the close as reliable as the open: the hull follows whatever the
-- server currently says, so a missed signal costs a few frames of easing and
-- never a plate stuck open. The drivers that read events cannot poll and so
-- carry their own decay instead - every one of them returns home on its own
-- clock, and none can be left latched by a packet that never arrived.
local function drawBody(model: Model, entry, dt: number)
	local pivot = model:GetPivot()
	local base = CFrame.new(pivot.Position + Vector3.new(0, entry.groundDrop, 0)) * pivot.Rotation
	entry.base = base

	stepGuns(entry)
	stepLady(entry)

	local ctx = entry.ctx
	ctx.now, ctx.dt, ctx.base = os.clock(), dt, base
	for _, piece in entry.pieces do
		piece.offset = nil
	end
	for _, channel in entry.channels do
		stepChannel(channel, ctx)
	end
	entry.adopting = false

	for _, piece in entry.pieces do
		local offset = piece.offset
		piece.part.CFrame = if offset then base * offset * piece.relative else base * piece.relative
	end
end

-- ---------------------------------------------------------------- watching

local function watch(child: Instance)
	if not child:IsA("Model") then
		return
	end
	adoptBoss(child)
	markWeakpoint(child)
	watchLady(child)
	-- CreatureService stamps CreatureId as the model is built, so it is
	-- normally already there; this covers a model that replicates to us a
	-- frame before its attributes do.
	child:GetAttributeChangedSignal("CreatureId"):Connect(function()
		adoptBoss(child)
	end)
	-- Same race for the weakpoint stamp, and the same answer. A REGROWN ring
	-- arrives as fresh models through ChildAdded, so this covers the regrow
	-- too; the destroyed ones lost their outline with themselves.
	child:GetAttributeChangedSignal(ATTR_WEAKPOINT):Connect(function()
		markWeakpoint(child)
	end)
	-- Both edges of the Lady, in one handler because `WrackDive` going nil is
	-- the redock and `WrackDive` appearing is the launch. Polled state would
	-- have done too, but she is one model among a folder of them and this way
	-- the per-frame walk is over the few that are her rather than over all of
	-- them.
	child:GetAttributeChangedSignal(ATTR_WRACK_DIVE):Connect(function()
		watchLady(child)
	end)
	child.AncestryChanged:Connect(function()
		if not child:IsDescendantOf(Workspace) then
			destroyBody(child)
			unmarkWeakpoint(child)
			ladies[child] = nil
		end
	end)
end

-- ------------------------------------------------------------ the cutscene
--
-- FIRE ONE OF THIS BOSS'S ANIMATION CHANNELS WITHOUT A WIRE EVENT, for a
-- caller that owns the model itself - the boss intro, which runs a client-side
-- stand-in carrying `CreatureId = "admiral_wrack"` (which this controller
-- adopts like any other) and drives its pivot by hand.
--
-- It goes in at exactly the point a wire event does, past adaptSignal and into
-- applySignal, so a cued windup and a real one are the same object taking the
-- same path and there is no second behaviour to keep in step. What it does NOT
-- do is bypass adoption: a model this controller has not adopted has no
-- channels to fire and this returns false rather than building any. That is
-- the whole of its safety - the cutscene cannot conjure a body, only conduct
-- one that is already standing.
--
-- THE SIGNALS THAT EXIST TODAY, and every field each honours:
--
--   "windup"  the Admiral's tell. Sabre up and quivering for the duration
--             (admHigh); if an `aim` is given, he and his head also turn onto
--             it (admPoint, admLook).
--             extra = { duration = seconds (default 0.9),
--                       aim = Vector3 (optional, flattened; omit for a
--                             bearing-free tell, which is what the radial
--                             patterns send),
--                       at = Vector3 (optional, unused by these channels) }
--
--   "fire"    the guns speak. Sabre sweeps down and the blade flicks
--             (admSweep, admFlick); the firing deck recoils and flashes
--             (gunRecoil, muzzleFlash).
--             extra = { at = Vector3, the MUZZLE (optional) }
--             With `at` within 8 studs of one gun, that gun alone kicks. With
--             no `at`, the origin defaults to the hull's own base point, which
--             is 13.3 studs from the nearest gun centroid and so matches none -
--             and matching none is precisely how the wire says "a broadside":
--             every live deck fires at once. The default is not a special case,
--             it is the radial case, reached by the same arithmetic.
--
-- THERE IS NO "RUN OUT THE GUNS" SIGNAL and none is invented here. The three
-- state-shaped channels are levels, not events, so a cutscene drives them by
-- setting the attribute on its OWN stand-in model and this function is not
-- involved: `Exposed` splits the hull, `WrackHatches` (a bitmask) opens the
-- hatches, `WrackBoom` (a world bearing in radians) swings the boom, and
-- `WrackWreck` lists her and brings the mast down. That is a feature for a
-- cutscene rather than a gap: an attribute can be held, and a beat that has to
-- stay open for eight seconds of dialogue cannot be an event.
--
-- Returns true if the signal reached a body.
function WrackBodyController.cue(model: Model, signal: string, extra): boolean
	local entry = if typeof(model) == "Instance" then bodies[model] else nil
	if not entry or type(signal) ~= "string" then
		return false
	end
	local fields = if type(extra) == "table" then extra else {}
	local at = if typeof(fields.at) == "Vector3" then fields.at else entry.base.Position
	local sig
	if signal == "fire" then
		sig = { what = "fire", at = at, now = os.clock() }
	elseif signal == "windup" then
		sig = {
			what = "windup",
			at = at,
			aim = flatAim(fields.aim),
			duration = tonumber(fields.duration) or 0.9,
			now = os.clock(),
		}
	else
		return false
	end
	applySignal(entry, sig)
	return true
end

function WrackBodyController.init()
	task.spawn(function()
		local folder = Workspace:WaitForChild(CREATURES_FOLDER, 30)
		if not folder then
			return
		end
		for _, child in folder:GetChildren() do
			watch(child)
		end
		folder.ChildAdded:Connect(watch)
		folder.ChildRemoved:Connect(function(child)
			if child:IsA("Model") then
				destroyBody(child)
				unmarkWeakpoint(child)
				ladies[child] = nil
			end
		end)
	end)
end

function WrackBodyController.start()
	-- The event drivers' one entry point. Kinds this file does not own are
	-- ignored in silence, exactly as ProjectileFxController ignores the ones
	-- it does not - the remote is a broadcast and every listener filters.
	Remotes.CreatureEvent.OnClientEvent:Connect(function(kind, position, extra)
		if type(kind) ~= "string" or typeof(position) ~= "Vector3" then
			return
		end
		local sig = adaptSignal(kind, position, if type(extra) == "table" then extra else {})
		if not sig then
			return
		end
		for _, entry in bodies do
			deliverSignal(entry, sig)
		end
	end)

	RunService.RenderStepped:Connect(function(dt)
		for model, entry in bodies do
			if model.Parent then
				drawBody(model, entry, dt)
			else
				destroyBody(model)
			end
		end
		drawMarks()
	end)
end

return WrackBodyController

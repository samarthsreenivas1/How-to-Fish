--!nonstrict
-- NoctyssBodyController.luau
-- Draws the Gloomtrench fight: seven lantern stalks, and the maw.
--
-- Two bodies, two contracts, one controller:
--
--   A STALK is a `choir_stalk` creature - its own entity with its own health
--   bar - so it carries its own pose on its own model (SocketIndex, TrueLure,
--   Lean, BeamAngle, Douse, PoseCenter). This draws it as a chain: NoctyssPath
--   says what shape it is in, ChainPose walks that shape by arc length, and
--   every frame each vertebra gets one CFrame. Two more attributes on that
--   model belong to the intro cutscene rather than to the fight - `Grow` and
--   `Flare`, both drawing-only; see "the cutscene channel".
--
--   THE MAW is the boss model (Pose = "noctyss"), three numbers wide:
--   MawRise, MawGape, MawYaw. No chain - a skull, and a jaw hinged off it.
--
-- The server stands each stalk's hidden model AT ITS LANTERN, which is what
-- makes shooting the light register. So the thing you aim at and the thing
-- you see are the same point, drawn from the same math on both sides.
--
-- Nothing here is a decision: no timers, no local guesses about what the boss
-- is doing. The attributes step, this eases toward them. The ONE thing this
-- file owns is the light itself - the pulse, and which bulb breathes against
-- it - because that is a look, not a rule (the rule is NoctyssPath.pulse).
--
-- Pieces come from ReplicatedStorage/Assets/NoctyssPack (assets/boss_gen.py)
-- and fall back to plain tinted blocks until that import lands, so the fight
-- is never invisible.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChainPose = require(Shared.Modules.ChainPose)
local MeshColors = require(Shared.Config.MeshColors)
local NoctyssPath = require(Shared.Modules.NoctyssPath)
local Remotes = require(Shared.Net.Remotes)

local Sfx = require(script.Parent.Parent.Modules.Sfx)
local Vfx = require(script.Parent.Parent.Modules.Vfx)

local NoctyssBodyController = {}

local TAU = math.pi * 2

local CREATURES_FOLDER = "Creatures"
local PACK_NAME = "NoctyssPack"
local FOLDER_NAME = "NoctyssBody"

-- Studs between vertebra centres, from the pack's HANDOFF (3.0) with the
-- same slight overlap the staged render uses, so the stalk reads continuous.
-- A FIXED number of links, not a spacing. `each` derives its count from the
-- curve's length, and this curve BREATHES: one ambient sway cycle takes a
-- stalk from 35.5 to 36.9 studs, straddling a segment boundary, so a vertebra
-- blinked in and out at the base of all seven stalks forever - and a lean added
-- two more that popped out of the floor. Brinejaw hit this, named it ("the tip
-- flickered a 3.4-stud hole on and off"), and `eachN` exists because of it.
local STALK_LINKS = 14
-- Each link is drawn slightly longer than its slot so neighbours overlap
-- instead of showing a seam when the curve stretches.
local OVERLAP = 1.18
local FIN_EVERY = 3
-- The hood is authored from its neck joint forward; the chain's t = 0 end IS
-- that joint, so it needs no lead - only the scale the render was judged at.
local HOOD_SCALE = 0.86
local STALK_TAPER = 0.34 -- thick at the root, thin under the hood
-- ChainPose's cost is SAMPLES, not links: its default 160 was being paid seven
-- times a frame - 1,127 curve evaluations before the maw is drawn at all - to
-- resolve a 42-stud quadratic that fourteen parts are then hung on. Measured
-- against a 320-sample walk across all seven sockets, three lean states and two
-- minutes of drift: 48 samples costs 0.004 studs of link position, 0.002 studs
-- of arc length, and 0.63 degrees at the hood (which moves the lantern, hanging
-- 7.3 studs off that frame, by 0.08 studs). That is a hundredth of the smallest
-- part in the chain, for 70% of the work. The fallen already ran at 48 and this
-- is the same curve, so both now name the same number.
local STALK_SAMPLES = 48

-- How fast the drawn pose chases the replicated one.
-- No `fall` rate here on purpose: a collapse is not eased toward a replicated
-- number, it is RUN, at FALL_RATE, from the frame the ChoirDown bit is set (the
-- stalk's own model is already gone by then, so there is nothing left to chase).
-- The `fall = 3.0` that used to sit in this table was read by nothing.
-- `grow` rides with `lean` on purpose: it is the same kind of number (a 0..1
-- the cutscene lane steps and this file chases), and a stalk that grew at its
-- own rate would read as a second animation system.
local EASE = { lean = 6.0, beamAngle = 9.0, douse = 5.0, grow = 6.0, mawRise = 2.2, mawGape = 4.0, mawYaw = 3.0 }

-- ----------------------------------------------------- Grow, and the cutscene
--
-- TWO ATTRIBUTES READ STRAIGHT OFF THE MODEL. Both are eased here; only one of
-- them is drawing-only now.
--
--   Grow  (number, 0..1, nil means 1) - how far out of the collar this stalk
--         has come. Eased at EASE.grow, exactly like Lean. At 1 the stalk is
--         its ordinary REST height; below 1 the whole shape - height, crook,
--         hood, lantern and eye - is scaled about the ROOT, so the eye rises
--         out of the socket rather than fading in over it, and at 0 the stalk
--         is a point at the root (REST.ROOT_Y = 2.2, under the collar's top at
--         4.6) with its light out.
--
--         IT IS A SHARED TERM. This used to be drawing-only, and the comment
--         here used to swear the server must never publish it: the scale lived
--         in this file, the hitbox is NoctyssPath.bulbPosition, and a live-fight
--         stalk drawn at Grow < 1 would have been a lantern you can see low in
--         its collar and can only hit thirty studs above it. The cure was to
--         move the scale into the curve both sides evaluate rather than to keep
--         the growth off the server - see "growing" in NoctyssPath, which
--         `stalkCurve` and `bulbPosition` now both run. So the choir can grow
--         back out of its sockets after a punish window instead of appearing
--         fully formed in one frame, and the eye you watch rise is the eye a
--         shot has to hit. The server writes it during a regrow, and is
--         expected to keep the stalk off targeting and damage while it is under
--         1: a stub in a collar is not a lantern anyone should be trading with.
--
--         The intro cutscene's stand-in stalks still drive the same attribute
--         with no creature server behind them, and that is unchanged and safe -
--         nobody shoots a stand-in, so there is no hitbox for it to desync from.
--
--   Flare (number, a server-time stamp) - when the value CHANGES, this stalk's
--         eye pops the one-shot white lure-flare. The value itself means
--         nothing; it is a change channel, so the cutscene sets it to
--         Workspace:GetServerTimeNow() at each beat. Still drawing-only, and
--         still the cutscene's alone: the fight says this with a `lureFlare`
--         creature event instead.
local GROW_DARK = 1.6 -- how sharply the lantern dies off under the collar
local FLARE = {
	DURATION = 0.42, -- how long the pop takes to ring down
	SIZE = 7.0, -- the white ball Vfx.flash throws, in studs
	BRIGHTNESS = 16.0,
	RANGE = 64.0,
	COLOR = Color3.fromRGB(255, 250, 236),
}

-- HIT REACTIONS. The CreatureHit remote carries a POINT, not a model (it is
-- fired for every creature in the game), so the body that reacts is whichever
-- one the shot landed on. A stalk's own anchor is its lantern - the server
-- literally stands the stalk's model there, so a hit registered on a stalk
-- happened at its bulb - and the maw's is its mouth. Both reaches are
-- generous: this decides who FLINCHES, and the server has already decided who
-- took damage.
local STALK_HIT_REACH = 14.0
local MAW_HIT_REACH = 34.0
local MAW_HIT_RISE = 0.15 -- below this she is still under the shelf; nothing hit her
local HIT_STRENGTH = 1.0
local KILL_STRENGTH = 1.6 -- the blow that takes a lantern out reads harder than the ones before it

-- THE STUTTER. A lantern that has just been shot guts and comes back, fast
-- and short: the light is the only health bar this arena has, so a hit must
-- be legible from across the pit without ever being mistaken for a douse
-- (which is the fight saying something entirely different).
local STUTTER = { DURATION = 0.26, FREQ = 44.0, DEPTH = 0.72 }

-- Filaments trail. A barbel has no muscle in it - it is dragged by whatever
-- it hangs off - so it arrives a beat behind the hood or the jaw. SNAP is the
-- distance past which the thing it hangs off did not move but TELEPORTED (a
-- choir regrowing, the maw dropping back under), and a lag that lerped
-- through that would draw a filament streaking across the arena.
local BARB_LAG = 7.0
local BARB_SNAP = 24.0

local HOOD_PIECES = { "StalkHood", "StalkCage", "StalkBulb", "StalkBarbs" }
local SKULL_PIECES = { "Skull", "SkullBone", "Eyes", "Gullet" }
local JAW_PIECES = { "Jaw", "JawBone", "Barbels" }

-- boss_gen NC_JAW_HINGE, carried into Roblox space: Blender (x, y, z) exports
-- as (x, z, -y). The jaw opens by turning about this, which is the same two
-- lines the staged render uses - a pose this cannot hold is a pose the render
-- must not show.
local JAW_HINGE = Vector3.new(-8.0, -2.2, 0.0)

local HIDE = Color3.fromRGB(44, 38, 58)
local FIN = Color3.fromRGB(70, 58, 92)
local BONE = Color3.fromRGB(204, 199, 179)
local LURE = Color3.fromRGB(255, 226, 130)
local EYE = Color3.fromRGB(255, 184, 66)

-- ---------------------------------------------------------------- the eye
--
-- THE LANTERN IS AN EYE, AND THE EYE IS THE HITBOX. Every earlier version of
-- this fight asked the party to shoot a lantern that was, in practice, a
-- 2.6-stud sphere 35 studs up in a room with no light in it except the thing
-- they were shooting at. Two faults in one:
--
--   * the drawn bulb and the hit sphere were different objects at similar
--     sizes and neither was authoritative, so "did I hit it" had no answer you
--     could read off the screen;
--   * there was no aim point ON the target - a glowing blob has a centre only
--     if you can see its edges, and in the dark you cannot.
--
-- Both are answered by the same object. `StalkEye` is a sphere of radius
-- NoctyssPath.EYE_R drawn AT NoctyssPath.bulbPosition, which is the exact
-- point the server stands the stalk's hidden model on, and the choir_stalk
-- row's scale is solved backwards so its capture sphere is that same radius.
-- Visual and hitbox are one number in one place. `StalkPupil` is a dark disc
-- riding the eye's surface toward whoever is looking at it: the eye watching
-- you is the horror, and the pupil is a literal crosshair sitting on the
-- hitbox's centre.
--
-- DRAWN SOLID, on purpose and against the rest of this file. The chain, the
-- hood and the barbs all carry the flinch and the secondary layer - up to
-- ~1.8 studs of lie, which is what makes the limb look alive. The eye carries
-- neither: it is the one thing in the arena that is exactly where it says it
-- is. The recoil still reads, on the body around it.
local EYE_R = NoctyssPath.EYE_R
local PUPIL_R = EYE_R * 0.42
local PUPIL_RIDE = EYE_R * 0.74 -- how far out on the sphere the pupil sits
local PUPIL_EASE = 9.0 -- how fast the gaze swings to follow the camera
-- The halo and the shaft are the DISTANCE read: seven of these have to be
-- findable from anywhere on a 68-stud shelf in the dark. Both are scaled by
-- the same `glow` the lantern is, and every socket's constants are identical -
-- the true lure is told by RHYTHM and by nothing else, so a visibility pass
-- that made one light bigger or brighter would delete the fight.
local HALO_R = EYE_R * 2.3
local SHAFT_R = EYE_R * 0.3
local SHAFT_H = 26.0
local EYE_LIT = Color3.fromRGB(255, 226, 130)
local EYE_DARK = Color3.fromRGB(74, 58, 34)
local PUPIL_COLOR = Color3.fromRGB(10, 8, 12)
local HALO_COLOR = Color3.fromRGB(255, 196, 108)

-- ------------------------------------------------------------- the telegraphs
--
-- IN A PITCH-BLACK ARENA, CHANGING LIGHT IS THE TELEGRAPH. These are the
-- floor half of it - drawn flat on the stone at the player's feet, where a
-- camera locked in first person is already looking, and always from the
-- descriptor's LATCHED target, so what is drawn is what is tested.
-- THE COLOUR IS NOT DECIDED HERE ANY MORE. This file used to declare six tell
-- colours of its own - TELL_SLAM, TELL_SCYTHE, TELL_JAB, TELL_DOOR, TELL_SNAP
-- and TELL_SNAP_BITE - four of which were within a hue step of the lanterns or
-- of CreatureEventController's ink, and all of which peaked bright enough for
-- Roblox Neon to saturate them to the same white paddle at the exact instant
-- they mattered. Both facts are now impossible to reintroduce: there are three
-- colours, they live in NoctyssPath.TELL, and every alpha in this file comes
-- out of NoctyssPath.tellRamp. See "the telegraphs" in NoctyssPath.
--
-- What this file still owns is the SHAPE, and the shape is the whole verb:
-- a stripe means step off the line, an arc band means step radially out, a
-- disc means leave the point, two bars and a lit centreline mean run the
-- middle, a rim ring means get outside it.
local TELL = NoctyssPath.TELL
local ARC_TILES = 12 -- how many slabs the scythe's arc band is laid out of
local DISC_TILES = 12 -- ...and how many the jab's edge ring is
-- THE SAFE SLOT, DRAWN AS A THING. The portcullis is two violet bars like any
-- other limb; what makes it a door is the walkable lane between them, and a
-- lane implied by a gap is not a lane anyone runs in a black room. Held at one
-- steady Transparency on purpose - it is the only mark in the fight that is
-- not a countdown, because it is the only one that is an invitation.
local DOOR_LANE_T = 0.7

local FALLBACK_COLOR = {
	StalkSeg = HIDE,
	StalkFin = HIDE,
	StalkHood = HIDE,
	StalkCage = BONE,
	StalkBulb = LURE,
	StalkBarbs = FIN,
	StalkRoot = HIDE,
	Skull = HIDE,
	SkullBone = BONE,
	Jaw = HIDE,
	JawBone = BONE,
	Gullet = LURE,
	Eyes = EYE,
	Barbels = FIN,
}

-- Roughly each piece's bulk, from the pack build's bbox lines.
local FALLBACK_SIZE = {
	StalkSeg = Vector3.new(3.0, 3.4, 5.0),
	StalkFin = Vector3.new(3.4, 5.4, 7.4),
	StalkHood = Vector3.new(8.5, 6.2, 10.8),
	StalkCage = Vector3.new(3.4, 6.0, 4.6),
	StalkBulb = Vector3.new(3.2, 5.0, 3.2),
	StalkBarbs = Vector3.new(7.1, 3.6, 9.3),
	StalkRoot = Vector3.new(7.2, 8.8, 9.6),
	Skull = Vector3.new(20.5, 6.5, 11.6),
	SkullBone = Vector3.new(22.5, 11.1, 13.6),
	Jaw = Vector3.new(18.8, 5.7, 11.2),
	JawBone = Vector3.new(17.5, 3.7, 12.2),
	Gullet = Vector3.new(5.2, 6.0, 6.0),
	-- The redesigned Noctyss_Eyes carries the ESCA now, not just a strip of eye
	-- across the skull, and this constant was still the old strip's bbox
	-- (1.2 x 1.4 x 11.0) - a stand-in a tenth of the piece's real bulk, on the
	-- one piece of her face a player looks at. Measured off the accessor bounds
	-- of the Eyes mesh in assets/boss_noctyss.glb, like every other row here.
	Eyes = Vector3.new(11.6, 9.9, 11.4),
	Barbels = Vector3.new(7.7, 7.0, 11.8),
}

-- model -> the live body
local bodies = {}

-- ---------------------------------------------------------------- pieces

local function packPiece(name: string): BasePart?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local pack = assets and assets:FindFirstChild(PACK_NAME)
	local piece = pack and pack:FindFirstChild("Noctyss_" .. name, true)
	return if piece and piece:IsA("BasePart") then piece else nil
end

local function makePiece(name: string, parent: Instance): BasePart
	local template = packPiece(name)
	local part
	if template then
		part = template:Clone()
	else
		part = Instance.new("Part")
		part.Size = FALLBACK_SIZE[name] or Vector3.new(3, 3, 3)
		part.Color = FALLBACK_COLOR[name] or HIDE
		part.Material = Enum.Material.SmoothPlastic
		-- TAGGED, because a stand-in is not the same SHAPE as the piece it
		-- stands in for and one of them has to be drawn differently (see
		-- BULB_SLING). Set on the instance rather than tracked in a table so it
		-- survives being parked, re-adopted, or handed to `drawFallen`, and so
		-- the answer is always on the part being drawn.
		part:SetAttribute("Fallback", true)
	end
	part.Name = "Noctyss_" .. name
	-- STUDIO'S glTF IMPORT DOES NOT CARRY COLOUR. The whole fight came up
	-- grey on the user's first import - arena and boss both - so the authored
	-- colours are re-applied here from the generated table
	-- (tools/gen_mesh_colors.py reads the Blender Principled BSDF, not the
	-- viewport swatch, which lies with a plausible grey for every object).
	--
	-- After the clone/fallback branch on purpose, so the imported piece and
	-- the stand-in block get the same colour and stop diverging; and BEFORE
	-- anything sets a material, so nothing is undone. The two lanterns are
	-- exempt in practice - setLantern rewrites their colour every frame from
	-- the glow, which is the one place colour is state rather than identity.
	local authored = MeshColors.get(part.Name)
	if authored then
		part.Color = authored
		local appearance = part:FindFirstChildWhichIsA("SurfaceAppearance")
		if appearance then
			appearance:Destroy()
		end
	end
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Parent = parent
	return part
end

-- AN AUTHORED PRIMITIVE, not a pack piece. The eye, its pupil, the halo and
-- the floor marks are shapes with exact radii the fight is measured in - an
-- imported mesh at an unknown bbox is the one thing they must not be, because
-- the whole point of the eye is that its drawn radius IS NoctyssPath.EYE_R.
local function makeShape(name: string, parent: Instance, shape, size: Vector3, color: Color3, neon: boolean): BasePart
	local part = Instance.new("Part")
	part.Name = "Noctyss_" .. name
	part.Shape = shape
	part.Size = size
	part.Color = color
	part.Material = if neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.Transparency = 1
	part.Parent = parent
	return part
end

-- A CHAIN LINK: its length comes from the slot it has to fill, its girth from
-- the taper. Separate from `applyPiece` because the hood and the maw genuinely
-- do want uniform scale, and one function cannot mean both.
local function applyLink(part: BasePart, cframe: CFrame, length: number, girth: number)
	local base = part:GetAttribute("BaseSize")
	if not base then
		base = part.Size
		part:SetAttribute("BaseSize", base)
	end
	part.CFrame = cframe
	part.Size = Vector3.new(length, base.Y * girth, base.Z * girth)
end

local function applyPiece(part: BasePart, cframe: CFrame, scale: number)
	local base = part:GetAttribute("BaseSize")
	if not base then
		base = part.Size
		part:SetAttribute("BaseSize", base)
	end
	part.CFrame = cframe
	part.Size = base * scale
end

-- The lantern, which is the only light in this arena and the thing the whole
-- fight is read by. Neon while lit, plastic when doused - so a dead or dark
-- stalk is unmistakably dark, not dimly glowing.
local function makeLantern(bulb: BasePart): PointLight
	local light = Instance.new("PointLight")
	light.Name = "Lantern"
	light.Color = Color3.fromRGB(255, 214, 120)
	light.Range = 44
	light.Brightness = 2.2
	light.Shadows = false
	light.Parent = bulb
	return light
end

local function setLantern(bulb: BasePart, light: PointLight, glow: number)
	if glow <= 0.02 then
		light.Enabled = false
		bulb.Material = Enum.Material.SmoothPlastic
		bulb.Color = Color3.fromRGB(58, 52, 44)
		return
	end
	light.Enabled = true
	-- BRIGHTER AND FURTHER than the fight shipped with (1.1 + 2.2 over a
	-- 30 + 22 range). Seven lanterns are the only light on a 68-stud shelf and
	-- they were reading as embers from across the pit, which made the fight's
	-- central act - pick the one breathing against the others, then shoot it -
	-- a search before it was a test. The range is what changed most: the read
	-- is a rhythm seen at distance, so light that dies at 30 studs is light
	-- that cannot be compared with anything.
	--
	-- Scaled by `glow` exactly as before, and identically for all seven, so
	-- the pulse got LOUDER rather than washed out and the true lure is still
	-- told by its beat and by nothing else.
	light.Brightness = 2.4 + 4.6 * glow
	light.Range = 46 + 34 * glow
	bulb.Material = Enum.Material.Neon
	bulb.Color = LURE:Lerp(Color3.fromRGB(96, 82, 44), 1 - glow)
end

-- How badly this stalk's lantern is guttering, 0 (steady) .. 1 (nearly out).
-- Folded into the glow rather than into `setLantern` itself, so a stutter can
-- never brighten a doused stalk back into the fight's read: it can only ever
-- take light away from whatever the pulse was already showing.
local function stutter(body, now: number): number
	local age = now - (body.hitAt or -math.huge)
	if age < 0 or age >= STUTTER.DURATION then
		return 0
	end
	local fade = 1 - age / STUTTER.DURATION
	return STUTTER.DEPTH * fade * (0.5 + 0.5 * math.sin(age * STUTTER.FREQ))
end

-- A frame that trails `target` - see BARB_LAG. Per-body, keyed, so one body
-- can drag more than one filament without them sharing a memory.
local function lagFrame(body, key: string, target: CFrame, dt: number): CFrame
	local previous = body[key]
	if not previous or (previous.Position - target.Position).Magnitude > BARB_SNAP then
		body[key] = target
		return target
	end
	local frame = previous:Lerp(target, math.clamp(BARB_LAG * dt, 0, 1))
	body[key] = frame
	return frame
end

-- ---------------------------------------------------------------- the breath
--
-- THE CHOIR'S PHASE SPREAD. NoctyssPath.pulse hands every false lure the same
-- phase, which was two faults wearing one coat. The arena's only light pumped
-- between "lit by seven" and "lit by one" every 2.6 seconds - a strobe, in the
-- room whose entire premise is that you read it by lantern-light - and all six
-- `choirPulse` voices peaked on the same frame, six copies of one sample
-- stacking about 15 dB over a single voice.
--
-- Both are the same fact, so both take the same fix, and it belongs on this
-- side: the shared RULE is which lantern breathes against the others, not the
-- instant each of the six hits its top. Shifting the clock this file hands
-- `pulse` buys a per-socket phase without touching shared math.
--
-- Cycles, per socket, and deliberately irregular - an even spread reads as a
-- wave going round the ring, which is just a slower mechanism. Measured over
-- all seven true-lure assignments: the choir's collective swing drops to
-- 52-67% of unison, so the floor never goes fully dark and never blasts, and
-- the six peaks land at least 0.10s - six frames at 60 - apart. The sound
-- stagger falls out of the light rather than being a second system that could
-- come to disagree with it.
local CHOIR_SPREAD = { -0.22, 0.09, -0.13, 0.20, -0.05, 0.15, -0.17 }

-- A BACKSTOP, not the stagger. CHOIR_SPREAD is what keeps the voices apart;
-- this only catches what a fixed spread cannot - a true-lure handoff, or a
-- choir regrowing into sockets whose phases happen to be near neighbours -
-- and it is deliberately shorter than the smallest designed gap so it can
-- never eat a voice the spread had already separated.
local CHOIR_VOICE_GAP = 0.06
local lastChoirVoice = -math.huge

-- ...and THE TRUE LURE KEEPS THE CLEAN BEAT, alone. Its half-cycle offset is
-- NoctyssPath's rule and nothing here may blunt it: with the six smeared across
-- the near half of the cycle and the real one left unshifted at 0.5, it is both
-- the furthest thing from any of them (101 degrees at worst, measured) and the
-- only lantern in the room still arriving at a crisp top. The tell got stronger
-- for being spread against, which is exactly why the spread stops at +-0.22
-- instead of going the whole way round.
--
-- A socket's spread is fixed by INDEX, including the socket currently carrying
-- the lure, so a handoff moves one stalk's phase - which `pulse` already does,
-- by half a cycle, on the same frame. No new class of jump.
-- WHAT EACH SOCKET'S LANTERN IS ACTUALLY SHOWING, this frame, 0..1 - written
-- by `drawStalk` right where it lights the bulb, read by the arena's veins
-- (see VEIN, far below). Not a second copy of the pulse: the whole point is
-- that a vein can only ever repeat what the lantern over it already said, so
-- it takes the finished number - douse, stutter, attack hold and all - rather
-- than the rule it came from. A socket with no stalk standing has no entry and
-- reads 0, which is what `destroyBody` restores when one dies.
local socketGlow: { [number]: number } = {}

local function choirPulse(state, index: number, now: number): number
	if index == state.trueLure then
		return NoctyssPath.pulse(state, index, now)
	end
	return NoctyssPath.pulse(state, index, now - NoctyssPath.PULSE_PERIOD * (CHOIR_SPREAD[index] or 0))
end

-- ONE BREATH, HEARD. The pulse is computed here and nowhere else on the
-- client, so this is the only place that knows when a lantern is at the top
-- of its cycle. Sounding that peak makes the fight's central read - which
-- light breathes against the others - answerable BY EAR, in an arena whose
-- whole premise is that you cannot see much; the true lure's half-cycle
-- offset is already inside NoctyssPath.pulse, so it turns over against the
-- choir on its own and this only has to answer it in the other register the
-- catalogue keeps for it.
--
-- Fired on the TURN, not on a "bright enough" test: a threshold re-fires
-- every frame it is held, sixty times a breath. Comparing this frame's pulse
-- against last frame's finds the peak exactly once per cycle at any frame
-- rate, for two numbers per stalk.
--
-- A doused lantern is silent, and a dead one has no body left to be asked -
-- so the arena goes quieter as the choir is broken, which is the whole point
-- of hunting the douse.
local function soundPulse(body, stalk, pulse: number, now: number)
	local last = body.lastPulse
	body.lastPulse = pulse
	if pulse > (last or 0) then
		body.pulseRising = true
		return
	end
	if not body.pulseRising then
		return
	end
	body.pulseRising = false
	if (stalk.douse or 0) >= 0.5 then
		return
	end
	local isTrue = body.index == body.state.trueLure
	if not isTrue then
		-- The true lure is exempt: it is the one voice this fight is read by,
		-- and a backstop that could silence it would cost more than six voices
		-- landing together ever did.
		if now - lastChoirVoice < CHOIR_VOICE_GAP then
			return
		end
		lastChoirVoice = now
	end
	local name = if isTrue then "choirPulseTrue" else "choirPulse"
	-- At the bulb, not at the socket: the lantern is what is breathing, and
	-- it hangs 35 studs up and 20 studs in from the collar it grew out of.
	Sfx.play(name, body.hood.StalkBulb.Position)
end

-- ------------------------------------------------- the attacks, in the ear
--
-- THE ARENA IS BLACK AND THE CAMERA IS FIRST PERSON, so half the swings in
-- this fight begin outside the player's view and the floor marks that answer
-- them are only visible once you are already looking down the right way.
-- Audio is the other half of every telegraph, and for a limb coming in from
-- behind it is the WHOLE telegraph.
--
-- Driven off the same `attackPhase` the poses and the marks are, and fired on
-- the PHASE CROSSING rather than on the phase - exactly the latch `drawMaw`
-- uses for the rise and the bite, and for the same reason: a test on the
-- current phase is true for every frame of it and would fire a windup sixty
-- times. The key folds in `start`, so two swings of the same kind back to back
-- from one socket are two events and not one held phase.
--
-- WHAT IS NOT DONE HERE: nothing is tested, nothing is damaged, and no sound
-- gates anything. A dropped descriptor costs a cue, never a hit.
-- ------------------------------------------------------------- matched pairs
--
-- TWO LIMBS, ONE MOVE. The portcullis and the herding V are each thrown as two
-- ordinary slam descriptors on the same frame, from two different sockets, and
-- two bodies answering them independently is why the fight's two biggest beats
-- were its quietest: two `slamImpact`s a frame apart from opposite sides of the
-- room are a doubled, phase-cancelled crack that sounds SMALLER than one bar,
-- and nothing in it says the two stripes are one thing.
--
-- So one of the pair speaks and the other is silent.
--
-- The server names the voice with the descriptor's `pair` field (see the
-- descriptor block in NoctyssPath): `true` on the +lateral bar, `false` on its
-- partner. Until it does, `pair` is nil on both and the fallback below picks
-- the first body to ask about a given `start` and keeps it for the life of that
-- move - which is stable, costs two fields, and needs no agreement with the
-- server about which side is which. A herd V's bars are plain `stalkslam`
-- descriptors and are indistinguishable from an ordinary slam without `pair`,
-- so that half of the rule arrives with the server's.
local doorVoice = { start = nil, index = nil }

-- Does this descriptor get a voice? Everything that is not the silent half of
-- a pair does.
local function voiced(attack): boolean
	if attack.pair ~= nil then
		return attack.pair == true
	end
	if attack.kind ~= "portcullis" then
		return true
	end
	if doorVoice.start ~= attack.start then
		doorVoice.start, doorVoice.index = attack.start, attack.index
	end
	return doorVoice.index == attack.index
end

local function stopScytheDrag(body)
	if body.scytheDrag then
		Sfx.stopLoop(body.scytheDrag)
		body.scytheDrag = nil
	end
end

local function soundAttack(body, state, attack, now: number)
	local phase, key
	if attack then
		-- Single assignment: attackPhase returns two values and only the first
		-- is a phase.
		phase = NoctyssPath.attackPhase(attack, now)
		key = tostring(attack.kind) .. "@" .. tostring(attack.start)
	end

	if key ~= body.attackKey or phase ~= body.attackVoice then
		body.attackKey = key
		body.attackVoice = phase
		-- EVERY crossing kills the loop first, whatever it crosses into. That
		-- is the whole leak defence: a drag can only exist inside the one
		-- phase that started it, so a sweep that ends, is interrupted by a
		-- second attack, or simply runs out has nowhere to survive.
		stopScytheDrag(body)

		local bulb = body.hood.StalkBulb.Position
		-- ONE MOVE, ONE VOICE. The bar borrows the slam's whole voice - the
		-- snuff, the crack of it landing, the peel coming off the stone - but
		-- only the half of a matched pair that carries it (see `voiced`). The
		-- silent half still draws its stripe and still hits: what it loses is
		-- the second copy of a sound that was cancelling the first.
		if attack and not voiced(attack) then
			return
		end
		if attack and (attack.kind == "stalkslam" or attack.kind == "portcullis") then
			if phase == "windup" then
				-- At the stalk: the lantern snuffing is the tell, and the tell
				-- comes from where the light just went out.
				Sfx.play("slamSnuff", bulb)
			elseif phase == "strike" then
				Sfx.play("slamImpact", attack.target)
			elseif phase == "recover" then
				Sfx.play("slamPeel", bulb)
			end
		elseif attack and attack.kind == "gloomscythe" then
			if phase == "windup" then
				Sfx.play("scytheCreak", bulb)
			elseif phase == "strike" then
				-- Started at the arc's first point, not at the stalk: the drag
				-- is the eye on the stone, and it is already there.
				body.scytheDrag = Sfx.loop(
					"scytheDrag",
					NoctyssPath.scythePoint(state, body.index, attack, NoctyssPath.scytheTravel(attack, now))
				)
			elseif phase == "recover" then
				-- THE LOOP'S DEATH, HEARD. Every crossing kills the drag (above),
				-- and until now it simply stopped: the one cue in the fight that
				-- follows its own hitbox ended on silence, which reads as the
				-- sweep being cut off rather than as the limb coming off the
				-- floor. `slamPeel` is the catalogue's "limb leaving the stone"
				-- and that is exactly what the lift is; the plan's own name for
				-- this beat is `scytheLift`, and swapping to it is one token
				-- once Sfx carries the id.
				Sfx.play("slamPeel", bulb)
			end
		elseif attack and attack.kind == "feelerstrike" then
			if phase == "windup" then
				Sfx.play("jabCoil", bulb)
			elseif phase == "strike" then
				Sfx.play("jabCrack", attack.target)
			end
		end
	end

	-- The drag follows the eye for as long as it lives - off the same
	-- scythePoint the hit test and the lit band are drawn from, so what you
	-- hear sweeping is what is about to hit you.
	if body.scytheDrag and attack then
		Sfx.moveLoop(
			body.scytheDrag,
			NoctyssPath.scythePoint(state, body.index, attack, NoctyssPath.scytheTravel(attack, now))
		)
	end
end

-- ---------------------------------------------------- secondary motion
--
-- WHAT THE SHARED SHAPE GIVES A STALK is one sine, on one lateral plane, phase
-- `index * 1.7`, about 4.7 studs at the hood. Seven of those are seven
-- pendulums: one frequency, one plane, nothing in-and-out, and the whole ring
-- returns to the same picture every 5.2 seconds forever. It is closer to a
-- metronome than a breath, and no amount of extra amplitude would fix that -
-- a bigger pendulum is still a pendulum.
--
-- Three cheap terms, none of which is more amplitude:
--
--   SURGE - the plane nobody was using. These are angler necks reaching out
--   over the pit and drawing back, which is the axis the anatomy works on;
--   the shared sway only ever moves them sideways along the ring.
--
--   WAVE - a lateral term delayed on its way up the stalk. This is the one
--   that matters: a body whose top arrives after its bottom BENDS, and bending
--   is the whole difference between a rope and a rod. It costs nothing extra,
--   because the delay is just an argument to the same sine.
--
--   DETUNE - one clock rate per socket. Identical periods at different phases
--   still re-form the same tableau on schedule; a few percent of detune means
--   the ring never repeats and no two stalks stay in step for long.
--
-- DRAWN ONLY, AND SMALL ON PURPOSE. The server's hitbox is
-- NoctyssPath.bulbPosition, which cannot see one line of this, so every stud
-- spent here is a stud between the light you shoot and the light you see. The
-- flinch already spends 0.9 of the lantern's ~2.6-stud hitbox on that same lie.
-- This is capped at 0.45 studs in the shape plus 3.5 degrees of hood roll
-- (another ~0.45 at the bulb, which hangs 7.3 studs off that frame), so the
-- worst case with a flinch riding on top is ~1.8 against 2.6 - visible as life,
-- never wide enough to turn a hit into a miss.
local ALIVE = {
	-- Prime against the shared 5.2 and 3.4 so nothing beats back into unison.
	SURGE_PERIOD = 8.3,
	SURGE = 0.45,
	WAVE_PERIOD = 3.1,
	WAVE = 0.30,
	WAVE_LAG = 0.45, -- seconds for the bend to travel collar -> hood
	DETUNE = 0.055,
	ROLL = math.rad(3.5),
	ROLL_PERIOD = 6.1,
}

-- Spread AROUND 1, not always slower, so detuning the ring does not quietly
-- retune the tempo the shape was judged at.
local function detune(index: number): number
	return 1 + ALIVE.DETUNE * (((index * 3) % 7) - 3)
end

-- A stalk holds itself still to aim, and a dead one does not breathe. The same
-- two fades the shared ambient uses, so this layer dies with the rest of the
-- motion rather than twitching on a corpse.
--
-- ...AND A LIMB THAT IS SWINGING DOES NOT DRIFT. NoctyssPath.stalkCurve kills
-- its own sway and breath outright for the life of a pose, and this layer has
-- to die with them: since `lean` is now pinned to 0 for the whole swing (it has
-- to be - see `drawStalk` - or the client solves a different curve than the
-- server), the lean fade below no longer damps anything during an attack, and
-- the surge and the wave would have come back to full amplitude on exactly the
-- frames the shape is supposed to be held still.
local function calmness(state, index: number): number
	local stalk = state.stalks[index]
	if NoctyssPath.attackFor(state, index, state.time) then
		return 0
	end
	return math.clamp((1 - (stalk.fall or 0)) * (1 - 0.7 * (stalk.lean or 0)), 0, 1)
end

-- `p` is the CURVE'S parameter - 0 down in the collar, 1 at the hood - not
-- ChainPose's, which runs the other way. Squared, so the root stays welded into
-- its socket and the whole excursion is spent at the top where it can be seen.
-- `inward` and `lateral` are handed in already computed: this runs 48 times per
-- stalk per frame, and re-deriving a constant bearing's cos and sin inside it
-- would put 672 trig calls a frame back into the loop the sample cut just took
-- them out of.
local function secondary(state, index: number, p: number, inward: Vector3, lateral: Vector3): Vector3
	local calm = calmness(state, index)
	if calm <= 0.01 then
		return Vector3.zero
	end
	local clock = state.time or 0
	local rate = detune(index)
	local reach = p * p * calm
	local surge = math.sin(clock / (ALIVE.SURGE_PERIOD * rate) * TAU + index * 2.3) * ALIVE.SURGE
	-- THE LAG IS THE POINT. Without `- p * WAVE_LAG` this is a second rigid
	-- swing; with it, the same term reaches the hood a beat after the base and
	-- the stalk carries a travelling bend.
	local wave = math.sin((clock - p * ALIVE.WAVE_LAG) / (ALIVE.WAVE_PERIOD * rate) * TAU + index * 0.9) * ALIVE.WAVE
	return inward * (surge * reach) + lateral * (wave * reach)
end

-- THE HEAD IS NOT WELDED TO THE NECK. A few degrees of roll about the stalk's
-- own axis swings the slung lantern through a small arc the chain cannot
-- produce - and the barbels, which already trail the hood, inherit it a beat
-- late and finally hang off something alive instead of being a fourth copy of
-- one frame.
local function hoodRoll(state, index: number): CFrame
	local roll = math.sin((state.time or 0) / (ALIVE.ROLL_PERIOD * detune(index)) * TAU + index * 1.1)
	return CFrame.Angles(roll * ALIVE.ROLL * calmness(state, index), 0, 0)
end

-- THE STAND-IN LANTERN HANGS WHERE THE REAL ONE DOES. The pack's hood mesh
-- carries the bulb slung under its own lip, so an imported StalkBulb is correct
-- on the bare hood frame. The fallback is not: it is a plain block at the
-- hood's origin, while NoctyssPath.bulbPosition - the server's hitbox, the
-- beam's apex, and the point every "shoot the true lure" check measures - sits
-- 6.3 studs away along `forward` and down. So for the whole pre-import life of
-- this fight the glowing block and its PointLight were six studs off the thing
-- a shot has to hit, in the arena's only light.
--
-- The same numbers `bulbPosition` uses, read in the hood's frame: +X is the
-- tangent it calls `forward`, +Y the `realUp` it builds from world up, which is
-- the axis pair ChainPose's alongX lays down. Applied to the STAND-IN ONLY -
-- offsetting the mesh too would double the offset it already bakes in.
local BULB_SLING = CFrame.new(6.6 * HOOD_SCALE, -3.2 * HOOD_SCALE, 0)

local function slung(name: string, part: BasePart, hoodFrame: CFrame): CFrame
	if name ~= "StalkBulb" or not part:GetAttribute("Fallback") then
		return hoodFrame
	end
	return hoodFrame * BULB_SLING
end

-- ---------------------------------------------------------------- growing
--
-- THE SCALE MOVED. `Grow` used to be applied here, by a local that scaled each
-- finished drawn point about the collar - and it had to be, because the server
-- never wrote the attribute and the shared curve therefore could not be allowed
-- to know about it. It does now: NoctyssPath.stalkCurve and
-- NoctyssPath.bulbPosition both carry the scale, so the eye you can see coming
-- out of the socket is the eye the server has stood a hitbox on, and a regrow
-- can be an animation instead of seven stalks appearing in one frame. See
-- "growing" in NoctyssPath for the contract; this file only eases the number
-- (EASE.grow) and keeps the lantern dark under the collar lip (GROW_DARK).

-- ------------------------------------------------------ the choir goes quiet
--
-- HOW FAR EVERY LIVING LANTERN DIMS WHILE THE MOUTH IS COMING UP. The rim ring
-- is drawn by the maw's body and the lanterns by seven others, so the beat is
-- carried here as the snap's start on the shared clock - set when the
-- descriptor arrives (`onChoirAttack`), read by every stalk on the same frame.
-- A module-local rather than a read off the maw's state: the draw order of the
-- eight bodies is a dictionary's, and a tell that arrived a frame late for six
-- stalks and on time for one would be a worse tell than none.
local SNAP_DIM = 0.35
local choirSnapStart: number? = nil

local function snapDim(now: number): number
	local start = choirSnapStart
	if not start then
		return 1
	end
	local phase = NoctyssPath.snapPhase(start, now)
	if phase == "rise" then
		return SNAP_DIM
	end
	if phase == "done" then
		choirSnapStart = nil
	end
	return 1
end

-- ---------------------------------------------------------------- the flare

-- THE LURE FLARE, WITHOUT THE EVENT BEHIND IT. In the fight a false lure
-- breaking fires a `lureFlare` creature event and CreatureEventController draws
-- it (Vfx.flash + a ring + the shared screen wash). The cutscene has no
-- creature to break, so it says the same thing with an attribute - and this
-- draws the half of that visual which belongs on the stalk: the white ball,
-- from the same shared Vfx the event uses, plus a light pop the event gets for
-- free from the lantern it is destroying and this does not.
--
-- One part per body, made once and kept: a flare is a beat in a cutscene, it
-- can happen seven times in a second, and Instance.new on the beat is how a
-- one-shot becomes a hitch.
local function flareLight(body): PointLight
	if body.flareLight then
		return body.flareLight
	end
	local part = makeShape("StalkFlare", body.folder, Enum.PartType.Ball, Vector3.new(1, 1, 1), FLARE.COLOR, true)
	part.CastShadow = false
	local light = Instance.new("PointLight")
	light.Name = "Flare"
	light.Color = FLARE.COLOR
	light.Shadows = false
	light.Enabled = false
	light.Parent = part
	body.flareLight = light
	return light
end

-- Called every frame with wherever the eye ended up: the ball is a one-shot
-- Vfx owns, and this is only the light ringing down after it.
local function drawFlare(body, at: Vector3, now: number)
	local light = body.flareLight
	if not light then
		return
	end
	local age = now - (body.flareAt or -math.huge)
	if age < 0 or age >= FLARE.DURATION then
		light.Enabled = false
		return
	end
	local fade = 1 - age / FLARE.DURATION
	light.Parent.CFrame = CFrame.new(at)
	light.Enabled = true
	light.Brightness = FLARE.BRIGHTNESS * fade * fade
	light.Range = FLARE.RANGE * (0.5 + 0.5 * fade)
end

-- ---------------------------------------------------------------- the eye

-- Built once per stalk, on first draw: four parts, none of which the pack
-- has an opinion about.
local function makeEye(body)
	local eye = {
		globe = makeShape(
			"StalkEye",
			body.folder,
			Enum.PartType.Ball,
			Vector3.new(1, 1, 1) * (EYE_R * 2),
			EYE_LIT,
			true
		),
		pupil = makeShape(
			"StalkPupil",
			body.folder,
			Enum.PartType.Ball,
			Vector3.new(1, 1, 1) * (PUPIL_R * 2),
			PUPIL_COLOR,
			false
		),
		halo = makeShape(
			"StalkHalo",
			body.folder,
			Enum.PartType.Ball,
			Vector3.new(1, 1, 1) * (HALO_R * 2),
			HALO_COLOR,
			true
		),
		shaft = makeShape(
			"StalkShaft",
			body.folder,
			Enum.PartType.Cylinder,
			Vector3.new(SHAFT_H, SHAFT_R * 2, SHAFT_R * 2),
			HALO_COLOR,
			true
		),
		-- Which way it is looking, eased. Seeded pointing up so the first frame
		-- cannot normalise a zero vector.
		gaze = Vector3.new(0, 1, 0),
	}
	body.eye = eye
	return eye
end

-- THE EYE, AT THE HITBOX, LOOKING AT YOU.
--
-- `at` is NoctyssPath.bulbPosition - solid, so this sphere is the server's
-- capture sphere and not an approximation of it. The pupil is placed on the
-- surface toward the CAMERA rather than toward the character: in locked first
-- person they are the same ray, and it is the camera the player is aiming
-- down. Eased, because an eye that snaps is a texture and an eye that swings
-- is an animal.
--
-- The pupil never fades. During a slam's snuff and a scythe's ground-drag the
-- lantern is nearly out, and that is precisely when the player most needs to
-- know which limb is coming - so the ember keeps a dark centre inside it and
-- the thing stays legibly an eye all the way through the attack.
-- `at` is handed in rather than derived: `drawStalk` needs the same point for
-- the flare, and `bulbPosition` walks the curve four times to produce it.
--
-- THE EYE IS THE ANIMAL'S HALF OF THE TELEGRAPH, so a swinging limb overrides
-- where it looks. `look` is a world point the pupil sits toward instead of the
-- camera - the latched target through a slam's windup, the dragging point
-- through a scythe - which is the difference between a limb that happens to be
-- pointed at you and one that has CHOSEN you. `pupil` scales the disc (the jab
-- narrows on the thrust) and `pop` brightens the halo for a frame (the jab's
-- flash is anatomy rather than a floor mark - the one place in this fight where
-- that is true). All three default to the camera-tracking eye this file has
-- always drawn, so a stalk with nothing on it pays three compares.
local function drawEye(body, glow: number, dt: number, at: Vector3, look: Vector3?, pupil: number?, pop: number?)
	local eye = body.eye or makeEye(body)

	local camera = Workspace.CurrentCamera
	local toward
	if look then
		toward = look - at
	else
		toward = if camera then camera.CFrame.Position - at else Vector3.new(0, 1, 0)
	end
	if toward.Magnitude > 1e-3 then
		local blend = eye.gaze:Lerp(toward.Unit, math.clamp(PUPIL_EASE * dt, 0, 1))
		eye.gaze = if blend.Magnitude > 1e-3 then blend.Unit else eye.gaze
	end

	eye.globe.CFrame = CFrame.new(at)
	eye.globe.Color = EYE_LIT:Lerp(EYE_DARK, 1 - glow)
	eye.globe.Material = if glow > 0.02 then Enum.Material.Neon else Enum.Material.SmoothPlastic
	eye.globe.Transparency = 0

	local pupilScale = pupil or 1
	eye.pupil.CFrame = CFrame.new(at + eye.gaze * PUPIL_RIDE)
	eye.pupil.Size = Vector3.new(1, 1, 1) * (PUPIL_R * 2 * pupilScale)
	eye.pupil.Transparency = 0

	-- Both distance reads breathe with the lantern and vanish with it: a halo
	-- left hanging over a doused stalk would answer the one question the douse
	-- is asked to pose.
	local flash = math.clamp(pop or 0, 0, 1)
	eye.halo.CFrame = CFrame.new(at)
	eye.halo.Size = Vector3.new(1, 1, 1) * (HALO_R * 2 * (0.82 + 0.34 * glow + 0.5 * flash))
	eye.halo.Transparency = math.clamp(1 - 0.22 * glow - 0.6 * flash, 0, 1)

	-- A cylinder's length runs along its own X, so the shaft is laid upright by
	-- turning it a quarter turn about Z. It stands ON the eye, not through it.
	eye.shaft.CFrame = CFrame.new(at + Vector3.new(0, SHAFT_H * 0.5, 0)) * CFrame.Angles(0, 0, math.pi * 0.5)
	eye.shaft.Transparency = 1 - 0.14 * glow
end

-- WHERE A SWINGING LIMB IS LOOKING, and what its eye is doing while it does.
-- Returns (world point to stare at or nil, pupil scale, halo pop) - the three
-- overrides `drawEye` takes. One function so the eye's behaviour is stated per
-- ATTACK rather than scattered through the draw loop, and so it is read off
-- the same `tellPhase` the floor marks are.
--
--   SLAM - the pupil tracks the LATCHED TARGET through the windup (not the
--   camera: the limb has already chosen where it is going, and an eye that
--   keeps watching you while the stripe says otherwise is the telegraph lying
--   in the one register a player believes), holds forward through the strike,
--   and goes back to watching the room once the peel is half done.
--
--   SCYTHE - locked down at the stone for the whole bow and sweep, released
--   when the recovery lifts it off the floor (NoctyssPath SCYTHE.LIFT).
--
--   JAB - on the target through the coil; on the thrust the pupil narrows to
--   0.6x and the halo pops. That pop is the fight's only flash that is anatomy
--   rather than a floor mark, which is why the jab can afford to be the one
--   attack with half a second of warning.
local function eyeBehaviour(state, index: number, attack, now: number): (Vector3?, number, number)
	if not attack then
		return nil, 1, 0
	end
	local _, live, since = NoctyssPath.tellPhase(attack, now)
	if attack.kind == "gloomscythe" then
		if not live and since and since >= 0 then
			-- Lifting: let it go as the aim point rises off the stone.
			if since >= NoctyssPath.SCYTHE.RECOVER * NoctyssPath.SCYTHE.LIFT then
				return nil, 1, 0
			end
		end
		return NoctyssPath.scythePoint(state, index, attack, NoctyssPath.scytheTravel(attack, now)), 1, 0
	end
	if attack.kind == "feelerstrike" then
		local pop = if live and (since or 0) < NoctyssPath.TELL.FLASH then 1 else 0
		return attack.target, (if live then 0.6 else 1), pop
	end
	-- The slam and the bar. `since` past the impact hold is the peel getting
	-- properly under way, which is the beat the head can look up again.
	if not live and since and since >= NoctyssPath.SLAM.HOLD + math.max(attack.hold or 0, 0) then
		return nil, 1, 0
	end
	return attack.target, 1, (if live and (since or 0) < NoctyssPath.TELL.FLASH then 0.5 else 0)
end

-- ------------------------------------------------------------- the telegraphs
--
-- EVERY MARK IS AN EDGE AND A FILL, AND THE EDGE IS THE TESTED BOUNDARY.
--
-- A fill-only slab says "danger is roughly here", which in a black arena with
-- three other shapes lit is not information a player can act on. What they are
-- actually asked to do is put their feet on one side of a line, so the line is
-- what gets drawn: a crisp TELL.EDGE_W band centred exactly on the number the
-- server measures against (SLAM.RADIUS, SCYTHE.RADIUS, JAB.RADIUS, PIT_R +
-- SNAP.MARGIN), with the interior held dim behind it so the shape still reads
-- as one thing from across the pit.
--
-- And they are laid on PROBED GROUND. The Choirfloor is not a plane - the
-- socket collars stand on mounds - so a stripe pinned to a flat SHELF_Y spent
-- its first eight studs inside the rock, at the end the limb comes from.
-- `NoctyssPath.markFloor` is the same probe CreatureEventController runs for
-- the beam rungs, and the stripe is laid END TO END across two probes, so it
-- rides down off the mound instead of being drawn at one height and buried.

-- THE CHORD OF ONE TILE of an `n`-tile ring at `radius`, with a touch of
-- overlap so a ring reads as a ring and not as n dashes.
local function ringChord(radius: number, n: number): number
	return 2 * radius * math.sin(math.pi / n) * 1.08
end

local function makeMarks(body)
	local folder = body.folder
	local marks = {
		-- THE SLAM AND THE BAR. One fill the width of the tested capsule, and
		-- the two lines that capsule ends at.
		stripeFill = makeShape("SlamFill", folder, Enum.PartType.Block, Vector3.new(1, 0.12, 1), TELL.LIMB, true),
		stripeEdge = {},
		-- THE JAB. A disc has one boundary and it is a circle, so the edge is
		-- laid out of chord tiles the way the rim ring is.
		discFill = makeShape("JabFill", folder, Enum.PartType.Cylinder, Vector3.new(0.12, 1, 1), TELL.LIMB, true),
		discEdge = {},
		-- THE SCYTHE. The band's two boundaries are circles concentric with the
		-- socket at `reach` +- SCYTHE.RADIUS, which is what makes "step radially
		-- out" a line the player can stand against rather than a feeling.
		tiles = {},
		bandOut = {},
		bandIn = {},
	}
	for i = 1, 2 do
		marks.stripeEdge[i] =
			makeShape("SlamEdge", folder, Enum.PartType.Block, Vector3.new(1, 0.12, 1), TELL.LIMB, true)
	end
	for i = 1, DISC_TILES do
		marks.discEdge[i] = makeShape("JabEdge", folder, Enum.PartType.Block, Vector3.new(1, 0.12, 1), TELL.LIMB, true)
	end
	for i = 1, ARC_TILES do
		marks.tiles[i] = makeShape("ScytheFill", folder, Enum.PartType.Block, Vector3.new(1, 0.12, 1), TELL.LIMB, true)
		marks.bandOut[i] =
			makeShape("ScytheEdge", folder, Enum.PartType.Block, Vector3.new(1, 0.12, 1), TELL.LIMB, true)
		marks.bandIn[i] = makeShape("ScytheEdge", folder, Enum.PartType.Block, Vector3.new(1, 0.12, 1), TELL.LIMB, true)
	end
	body.marks = marks
	return marks
end

-- Hidden, never destroyed: a choir throws attacks for the whole fight, and a
-- socket that has slammed once will slam again. Written out rather than looped
-- over a list of lists because this runs on every stalk on every frame it is
-- not swinging - which is most of them, most of the time - and a table built
-- to be thrown away sixty times a second is a table built sixty times a second.
local function hideList(list)
	for _, part in list do
		part.Transparency = 1
	end
end

local function hideMarks(marks)
	marks.stripeFill.Transparency = 1
	marks.discFill.Transparency = 1
	hideList(marks.stripeEdge)
	hideList(marks.discEdge)
	hideList(marks.tiles)
	hideList(marks.bandOut)
	hideList(marks.bandIn)
end

-- THE IMPACT LINE. From the collar the limb grew out of, through the latched
-- point, at the width the capsule is actually tested at (NoctyssPath.SLAM
-- .RADIUS) - so stepping off the stripe is stepping out of the damage, exactly
-- and not approximately. It brightens on an accelerating ramp through the
-- windup, flashes on the frame the hitbox goes LIVE (not on a phase name: the
-- slam's damage outlasts its travel by 0.15s, and the mark used to start fading
-- inside that), holds while it is live, and is gone 0.3s after it stops.
local function drawSlamMark(marks, state, attack, u: number, live: boolean, since: number?)
	local socket = state.center + NoctyssPath.socketPoint(attack.index)
	local a = NoctyssPath.markFloor(state, socket.X, socket.Z)
	local b = NoctyssPath.markFloor(state, attack.target.X, attack.target.Z)
	local span = b - a
	local length = span.Magnitude
	if length < 1e-3 then
		return
	end
	local edgeT, color, fillT = NoctyssPath.tellRamp(u, live, since, TELL.LIMB)
	local radius = NoctyssPath.SLAM.RADIUS
	-- Laid end to end between the two probes, so the slab tilts down off the
	-- collar's mound rather than being drawn at one height and half buried.
	local frame = CFrame.lookAt(a + span * 0.5, b)
	local fill = marks.stripeFill
	fill.Size = Vector3.new(radius * 2, 0.12, length)
	fill.CFrame = frame
	fill.Color = color
	fill.Transparency = fillT
	for i, edge in marks.stripeEdge do
		edge.Size = Vector3.new(TELL.EDGE_W, 0.12, length)
		edge.CFrame = frame * CFrame.new((if i == 1 then 1 else -1) * radius, 0, 0)
		edge.Color = color
		edge.Transparency = edgeT
	end
end

-- THE APPROACHING POOL. A band of slabs laid on the arc the eye is about to
-- drag along - the whole arc while the limb is still bowing, then only the part
-- still to come. It is drawn at the sweep's own radius and width, off the same
-- NoctyssPath.scythePoint the hit test asks, so the lit ground and the damage
-- are one curve; and its two edges are the circles concentric with the socket
-- that the swept sphere actually ends at.
-- One tile of one of the arc band's two boundaries, `offset` studs off the
-- centreline along `out` (negative for the inner one), on a circle of radius
-- `mean` +- offset about the socket.
local function placeEdge(
	edge,
	frame: CFrame,
	out: Vector3,
	offset: number,
	length: number,
	mean: number,
	color: Color3,
	alpha: number
)
	local scale = if mean > 1e-3 then math.max((mean + offset) / mean, 0.05) else 1
	edge.Size = Vector3.new(TELL.EDGE_W, 0.12, length * 1.1 * scale)
	edge.CFrame = frame + out * offset
	edge.Color = color
	edge.Transparency = alpha
end

local function drawScytheMark(marks, state, attack, now: number, u: number, live: boolean, since: number?)
	-- `u < 1` is the bow: the whole arc is shown. Once the eye is moving, only
	-- the ground it has not reached yet.
	local from = if u < 1 then 0 else NoctyssPath.scytheTravel(attack, now)
	local edgeT, color, fillT = NoctyssPath.tellRamp(u, live, since, TELL.LIMB)
	local root = state.center + NoctyssPath.socketPoint(attack.index)
	local radius = NoctyssPath.SCYTHE.RADIUS
	local step = (1 - from) / ARC_TILES
	local previous = nil
	for i = 1, ARC_TILES do
		local a = previous
		if not a then
			local at = NoctyssPath.scythePoint(state, attack.index, attack, from)
			a = NoctyssPath.markFloor(state, at.X, at.Z)
		end
		local to = NoctyssPath.scythePoint(state, attack.index, attack, from + step * i)
		local b = NoctyssPath.markFloor(state, to.X, to.Z)
		previous = b
		local span = b - a
		if span.Magnitude < 1e-3 then
			marks.tiles[i].Transparency = 1
			marks.bandOut[i].Transparency = 1
			marks.bandIn[i].Transparency = 1
		else
			local mid = a + span * 0.5
			local frame = CFrame.lookAt(mid, b)
			local out = Vector3.new(mid.X - root.X, 0, mid.Z - root.Z)
			out = if out.Magnitude > 1e-3 then out.Unit else Vector3.new(1, 0, 0)
			local tile = marks.tiles[i]
			tile.Size = Vector3.new(radius * 2, 0.12, span.Magnitude * 1.1)
			tile.CFrame = frame
			tile.Color = color
			-- The far end of the FILL is dimmer: the light is arriving, and a
			-- band of one brightness reads as a wall rather than a sweep. The
			-- edges keep one alpha - they are the line to stand behind, and a
			-- line that fades out has a far end that means nothing.
			tile.Transparency = math.min(fillT + 0.3 * ((i - 1) / ARC_TILES), 1)
			-- THE TWO EDGES ARE LONGER AND SHORTER THAN THE TILE THEY FLANK.
			-- Both boundaries are circles concentric with the socket, at
			-- `reach` +- RADIUS, so a tile on the outer one has to span a
			-- proportionally wider chord - up to 1.3x at the default reach.
			-- Cut to the centreline's length they left a visible gap every
			-- tile, which in a band whose whole job is to be a LINE is the one
			-- thing it may not look like.
			local mean = (mid - root)
			mean = Vector3.new(mean.X, 0, mean.Z).Magnitude
			placeEdge(marks.bandOut[i], frame, out, radius, span.Magnitude, mean, color, edgeT)
			placeEdge(marks.bandIn[i], frame, out, -radius, span.Magnitude, mean, color, edgeT)
		end
	end
end

-- The jab's mark is a disc, because the jab is a point: there is nowhere to
-- step ALONG, only off. One probe serves the whole footprint - it is eleven
-- studs across and it is aimed at open floor by construction.
local function drawJabMark(marks, state, attack, u: number, live: boolean, since: number?)
	local edgeT, color, fillT = NoctyssPath.tellRamp(u, live, since, TELL.LIMB)
	local radius = NoctyssPath.JAB.RADIUS
	local at = NoctyssPath.markFloor(state, attack.target.X, attack.target.Z)
	local disc = marks.discFill
	disc.Size = Vector3.new(0.12, radius * 2, radius * 2)
	disc.CFrame = CFrame.new(at) * CFrame.Angles(0, 0, math.pi * 0.5)
	disc.Color = color
	disc.Transparency = fillT
	local chord = ringChord(radius, DISC_TILES)
	for i, edge in marks.discEdge do
		local angle = (i - 0.5) * (TAU / DISC_TILES)
		local on = at + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		edge.Size = Vector3.new(TELL.EDGE_W, 0.12, chord)
		edge.CFrame = CFrame.lookAt(on, on + Vector3.new(-math.sin(angle), 0, math.cos(angle)))
		edge.Color = color
		edge.Transparency = edgeT
	end
end

-- One entry point per stalk per frame. Built lazily and only ever hidden, not
-- destroyed: a choir throws attacks for the whole fight, and a socket that has
-- slammed once will slam again.
--
-- The ramp's three arguments come from NoctyssPath.tellPhase, which derives
-- them from the same `attackLive` the server damages on - so no branch in this
-- file decides when a mark is bright, and none of them can drift off the
-- hitbox by a phase boundary again.
local function drawMarks(body, state, attack, now: number)
	if not attack then
		if body.marks then
			hideMarks(body.marks)
		end
		return
	end
	local marks = body.marks or makeMarks(body)
	local u, live, since = NoctyssPath.tellPhase(attack, now)
	-- The bar draws as a slam because it IS one (NoctyssPath `isSlam`): the same
	-- capsule, from the same socket, to the same kind of latched point, in the
	-- same colour. The door is told by the lane, and by nothing else.
	if attack.kind == "stalkslam" or attack.kind == "portcullis" then
		drawSlamMark(marks, state, attack, u, live, since)
	elseif attack.kind == "gloomscythe" then
		drawScytheMark(marks, state, attack, now, u, live, since)
	elseif attack.kind == "feelerstrike" then
		drawJabMark(marks, state, attack, u, live, since)
	end
end

-- ---------------------------------------------------------------- pose

local function approach(current: number, goal: number, rate: number, dt: number): number
	return current + (goal - current) * math.clamp(rate * dt, 0, 1)
end

-- Angles take the short way round, or a sweep crossing north whips the stalk
-- backwards through the whole arena to arrive at the same bearing.
local function approachAngle(current: number, goal: number, rate: number, dt: number): number
	local delta = (goal - current + math.pi) % (math.pi * 2) - math.pi
	return current + delta * math.clamp(rate * dt, 0, 1)
end

-- ---------------------------------------------------------------- lifecycle

local function destroyBody(model: Model)
	local body = bodies[model]
	if not body then
		return
	end
	bodies[model] = nil
	-- A DEAD STALK'S LIGHT IS OUT, INCLUDING THE PART OF IT IN THE FLOOR. The
	-- veins are drawn off `socketGlow`, which this body is the only writer of;
	-- left behind, the last frame's brightness would burn in that ridge for the
	-- rest of the fight - a lantern still lit under the stone after the one
	-- over it was broken, which is exactly the lie the read cannot survive.
	if body.kind == "stalk" and body.index then
		socketGlow[body.index] = 0
	end
	-- THE LOOP DOES NOT LIVE IN THE FOLDER. Every other sound this file makes
	-- is a one-shot that cleans itself up, and every drawn part goes with the
	-- folder below - but the scythe's drag hangs off Sfx's own carrier, so a
	-- stalk killed mid-sweep (or the whole boss torn down at death) would
	-- leave it running in an empty arena with nothing left holding its handle.
	-- Stopped here because this is the one path every body's end goes through:
	-- death, despawn, and the model leaving the workspace all land in it.
	stopScytheDrag(body)
	if body.folder then
		body.folder:Destroy()
	end
end

local function newFolder(): Folder
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

local function adoptStalk(model: Model)
	local index = model:GetAttribute("SocketIndex")
	if bodies[model] or model:GetAttribute("Pose") ~= "choir_stalk" or not index then
		return
	end

	local folder = newFolder()
	local state = NoctyssPath.newState(model:GetAttribute("PoseCenter") or model:GetPivot().Position)
	state.trueLure = if model:GetAttribute("TrueLure") then index else -1

	-- This socket's two horizontal axes, once and for all: a collar does not
	-- move, so its bearing is not something to re-derive 48 times a frame.
	-- `inward` points over the pit (the plane the shared sway leaves unused),
	-- `lateral` runs along the ring - the same pair NoctyssPath builds.
	local bearing = NoctyssPath.socketAngle(index)
	local inward = Vector3.new(-math.cos(bearing), 0, -math.sin(bearing))
	local lateral = Vector3.new(-inward.Z, 0, inward.X)

	local body = {
		kind = "stalk",
		index = index,
		folder = folder,
		state = state,
		segments = {},
		hood = {},
		-- The chain is walked HOOD-FIRST: ChainPose's tangent points back
		-- toward t = 0, and the pack authors +X running up-stalk toward the
		-- hood, so the hood has to be the chain's head or every piece faces
		-- down its own stalk. (The staged render found this the hard way.)
		chain = ChainPose.new(function(s, t)
			-- ChainPose walks head-first, so ITS t = 0 is the hood; `p` is the
			-- curve's own parameter, which is what NoctyssPath and the secondary
			-- layer are both written against.
			local p = 1 - t
			-- The cutscene's Grow, last: it scales the finished drawn point -
			-- secondary layer and all - about the root, so nothing inside the
			-- shape has to know the stalk is only half out of its collar.
			-- `stalkPoint` already carries the regrow scale (NoctyssPath
			-- "growing"), so only this file's own drawn-only layer has to be
			-- told about it: a stub in a collar should not sway the full
			-- amplitude of a 33-stud stalk.
			return NoctyssPath.stalkPoint(s, index, p)
				+ secondary(s, index, p, inward, lateral) * NoctyssPath.growOf(s, index)
		end, { samples = STALK_SAMPLES }),
	}
	for _, name in HOOD_PIECES do
		body.hood[name] = makePiece(name, folder)
	end
	body.root = makePiece("StalkRoot", folder)
	body.light = makeLantern(body.hood.StalkBulb)

	bodies[model] = body
	model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			destroyBody(model)
		end
	end)
end

local function adoptMaw(model: Model)
	if bodies[model] or model:GetAttribute("Pose") ~= "noctyss" then
		return
	end

	local folder = newFolder()
	local body = {
		kind = "maw",
		folder = folder,
		state = NoctyssPath.newState(model:GetAttribute("PoseCenter") or model:GetPivot().Position),
		pieces = {},
		-- socket -> the wreckage of the stalk that stood there. The boss model
		-- is the only thing in this fight that outlives its own choir, so it
		-- is the only place the fallen can be hung (see `drawFallenChoir`).
		fallen = {},
	}
	for _, name in SKULL_PIECES do
		body.pieces[name] = makePiece(name, folder)
	end
	for _, name in JAW_PIECES do
		body.pieces[name] = makePiece(name, folder)
	end
	body.gulletLight = makeLantern(body.pieces.Gullet)
	body.gulletLight.Range = 60
	-- THE ESCA - the caged lure bulb the illicium dangles over the mouth, and
	-- the one warm piece on the head the pack authors with no light of its own
	-- (boss_gen's noctyss HANDOFF asks for exactly this). It rides in the Eyes
	-- object, so the light hangs off that part and NOTHING IS MOVED: the
	-- Gullet's bbox centre is what its own lamp is aimed by, and this must not
	-- come near it.
	body.escaLight = makeLantern(body.pieces.Eyes)

	bodies[model] = body
	model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			destroyBody(model)
		end
	end)
end

-- ---------------------------------------------------------------- per frame

local function drawStalk(model: Model, body, dt: number, now: number)
	local state, index = body.state, body.index
	local stalk = state.stalks[index]
	state.time = now
	-- TAKEN FIRST, because the two numbers below are conditional on it. A limb
	-- that is mid-swing is posed off the shape it is in, and the shape it is in
	-- must be the shape the SERVER thinks it is in.
	local attack = NoctyssPath.attackFor(state, index, now)
	if attack then
		-- SNAPPED, NOT EASED, AND HELD THERE FOR THE LIFE OF THE POSE. The
		-- server pins `lean` to 0 on the first frame of a swing; this file used
		-- to ease toward it at EASE.lean = 6.0, which takes about three tenths
		-- of a second. The pose solver derives its rest shape through
		-- `stalkCurve(noAttack)`, and `lean` is in that shape's `tip` term - so
		-- for the whole first third of every windup the client was solving a
		-- DIFFERENT curve than the server, and the drawn limb aimed off its own
		-- stripe exactly while the player was reading it. `beamAngle` is frozen
		-- for the same reason and with the same argument: the server does not
		-- move it during a limb swing, so neither may this.
		stalk.lean = 0
	else
		stalk.lean = approach(stalk.lean or 0, model:GetAttribute("Lean") or 0, EASE.lean, dt)
		stalk.beamAngle =
			approachAngle(stalk.beamAngle or 0, model:GetAttribute("BeamAngle") or stalk.beamAngle, EASE.beamAngle, dt)
	end
	stalk.douse = approach(stalk.douse or 0, model:GetAttribute("Douse") or 0, EASE.douse, dt)
	-- GROW, eased exactly like Lean and defaulting to a stalk that is all the
	-- way out - so a stalk that never carries the attribute is drawn by the
	-- same code at grow = 1 and pays one compare for it. Read BEFORE the chain
	-- is updated, because the shared curve is what applies it.
	--
	-- IT IS A SHARED TERM NOW: the scale lives in NoctyssPath.stalkCurve and in
	-- bulbPosition, so the eye the server stands a hitbox on comes out of the
	-- socket with the drawn one. The server writes `Grow` during a regrow (and
	-- is expected to keep the stalk off the targeting and damage lists while it
	-- is under 1); the intro cutscene's stand-in stalks still drive the same
	-- attribute client-only, which is unchanged and safe - nobody shoots them.
	NoctyssPath.setGrow(
		state,
		index,
		approach(NoctyssPath.growOf(state, index), model:GetAttribute("Grow") or 1, EASE.grow, dt)
	)

	local chain = body.chain
	chain:update(state)

	chain:eachN(STALK_LINKS, function(i, cframe, u, spacing)
		local segment = body.segments[i]
		if not segment then
			segment = makePiece(if i % FIN_EVERY == 1 then "StalkFin" else "StalkSeg", body.folder)
			body.segments[i] = segment
		end
		-- u runs 0 at the hood to 1 at the root, so the taper is inverted
		-- against Brinejaw's: a stalk is thickest where it leaves the stone.
		-- TAPER TOUCHES GIRTH ONLY. Scaling length by it too shortened the
		-- upper links below their own spacing and turned the top half of every
		-- stalk into a dotted line - the same bug, and the same fix, as the
		-- serpent's back half.
		applyLink(segment, cframe, math.max(spacing * OVERLAP, 0.2), 1 - STALK_TAPER * (1 - u) ^ 1.1)
	end)

	local hoodFrame = chain:cframeAt(0) * hoodRoll(state, index)
	for _, name in HOOD_PIECES do
		-- The filaments hang off the hood, they are not welded to it: they get
		-- last frame's hood, dragged toward this one. Safe to draw off the
		-- shared shape only because nothing - no beam test, no hitbox, no
		-- bulb - is ever measured against them.
		local frame = if name == "StalkBarbs" then lagFrame(body, "barbFrame", hoodFrame, dt) else hoodFrame
		applyPiece(body.hood[name], slung(name, body.hood[name], frame), HOOD_SCALE)
	end
	applyPiece(body.root, chain:cframeAt(chain.length), 1)

	-- THE TELL. Every lantern breathes on the same clock; the true lure
	-- breathes half a cycle against it (NoctyssPath.pulse owns that rule, so
	-- the server's idea of which light is real and the light you are looking
	-- at can never disagree). A doused stalk is simply out.
	-- A hit guts the light for a quarter-second on top of all that, which is
	-- the whole of this fight's damage feedback: there is no health bar out
	-- over the pit, only whether the lantern flinched.
	--
	-- A LIMB MID-SWING IS NOT A LANTERN BREATHING AT YOU. The pulse is the
	-- fight's one question - which of these is keeping the odd beat - and a
	-- stalk that is currently a weapon must not be asked to answer it: its
	-- light is doing a different job (going out, for a slam; dragging along the
	-- floor, for a scythe), and a rhythm read across it is a rhythm read across
	-- noise. Held wide open instead, and `attackGlow` takes it from there.
	-- NoctyssPath.stalkBusy is the same predicate, for the server to keep the
	-- true lure off a swinging limb.
	local pulse = choirPulse(state, index, now)
	local glow = (if attack then 1 else pulse)
		* (1 - math.clamp(stalk.douse or 0, 0, 1))
		* NoctyssPath.attackGlow(attack, now)
		* (1 - stutter(body, now))
		-- ...and DARK UNDER THE COLLAR. A lantern still burning at full while
		-- its stalk is a stub in the socket would light the whole shelf out of a
		-- hole, which is the opposite of what the growth beat is for. Falls off
		-- faster than the shape rises (GROW_DARK), so the light arrives after the
		-- eye has cleared the collar's lip rather than climbing out with it.
		* NoctyssPath.growOf(state, index) ^ GROW_DARK
		-- ...and THE CHOIR GOES QUIET WHILE THE FLOOR OPENS. Every living
		-- lantern dims to SNAP_DIM through a herding snap's rise. It is the
		-- cheapest legible thing this fight can do: the one light source in the
		-- room drops by two thirds at the same instant a mouth starts coming up
		-- through the middle of it, so the rim ring is read against a darker
		-- arena and the snap is announced to a player who is facing the wrong
		-- way entirely.
		* snapDim(now)
	setLantern(body.hood.StalkBulb, body.light, glow)
	-- The ridge running back to the pit carries this stalk's light, and it is
	-- told here so it can never be told anything else (see `socketGlow`).
	socketGlow[index] = glow
	-- The hitbox point, carrying the regrow scale because the shared curve does
	-- (a no-op at grow = 1, which is every stalk that is not coming back).
	-- Taken once: the eye stands here, and so does a flare thrown at this stalk.
	local at = NoctyssPath.bulbPosition(state, index)
	drawEye(body, glow, dt, at, eyeBehaviour(state, index, attack, now))
	-- THE FLARE, on the CHANGE and not on the value: `Flare` is a server-time
	-- stamp, so any new number is a new beat and the number itself means
	-- nothing. Compared per frame rather than watched with a changed signal, for
	-- the same reason everything else here is: this file has exactly one place
	-- where a stalk's attributes are read, and it is this one.
	local flare = model:GetAttribute("Flare")
	if type(flare) == "number" and flare ~= body.flareSeen then
		body.flareSeen = flare
		body.flareAt = now
		flareLight(body)
		Vfx.flash(at, FLARE.COLOR, FLARE.SIZE, FLARE.DURATION)
		Sfx.play("lureFlare", at)
	end
	drawFlare(body, at, now)
	drawMarks(body, state, attack, now)
	-- After the bulb has been placed this frame, so a cue thrown at the stalk
	-- comes from where the lantern actually is - the same rule `soundPulse`
	-- is under, one line below.
	soundAttack(body, state, attack, now)
	if not attack then
		-- Sounded off the raw pulse, after the bulb has been placed this frame,
		-- so the note comes from where the lantern actually is. Silent mid-
		-- attack for the same reason the pulse is suppressed.
		soundPulse(body, stalk, pulse, now)
	end
end

-- ------------------------------------------------------------ the fallen
--
-- A stalk is an ordinary creature, so the server destroys its model the
-- instant it dies - and with the model goes this controller's body, its
-- chain, and its lantern, all in one frame. Left alone, a lantern the party
-- spent a minute breaking simply stops existing, and by the third cycle the
-- arena has no memory of the fight in it.
--
-- The BOSS model outlives every choir, and it publishes `ChoirDown`: one bit
-- per socket, set while that socket is down. So the maw's body draws the
-- wreckage of stalks it never owned - the same NoctyssPath shape, with `fall`
-- run up to 1, plus a stump left standing in the collar. Nothing is
-- replicated for any of this beyond the one number.

local DOWN_PIECES = { "StalkHood", "StalkCage", "StalkBulb", "StalkBarbs" }

-- THE BEAT BETWEEN THE LIGHT AND THE SHAPE. The lantern going out IS the kill
-- in an arena with no other light, and a shape that drops in the same instant
-- swallows it. So the dark stalk stands for a moment, and only then falls.
local DOUSE_LEAD = 0.3
-- The server runs its own copy of this ramp in updateChoir; the client is
-- handed only the bit, so it runs the same one rather than being told each
-- frame's value. Nothing is aimed at a corpse, so the two need not agree to
-- the frame - only to look like the same collapse.
local FALL_RATE = 1.4

local DEAD_BULB = Color3.fromRGB(40, 35, 30)

local function newFallen(body, index: number)
	local fallen = {
		segments = {},
		hood = {},
		-- The same curve at the same resolution as a living stalk (see
		-- STALK_SAMPLES) - which used to be the exception here, back when the
		-- living ones paid ChainPose's default 160 for no measurable shape. A
		-- wreck needs less than a stalk does, if anything: a fifth the height,
		-- nearly straight, and it stops being redrawn once it has settled.
		chain = ChainPose.new(function(s, t)
			return NoctyssPath.stalkPoint(s, index, 1 - t)
		end, { samples = STALK_SAMPLES }),
	}
	for _, name in DOWN_PIECES do
		fallen.hood[name] = makePiece(name, body.folder)
	end
	-- No PointLight is ever built for a downed socket, rather than one built
	-- and switched off: a lamp that does not exist cannot be relit by a later
	-- frame, and "which lights are still up" is the fight's whole read.
	fallen.hood.StalkBulb.Material = Enum.Material.SmoothPlastic
	fallen.hood.StalkBulb.Color = DEAD_BULB
	fallen.stump = makePiece("StalkRoot", body.folder)
	body.fallen[index] = fallen
	return fallen
end

-- Park rather than destroy: a choir regrows in the same seven sockets, so
-- these pieces are wanted again in about a minute.
local function parkFallen(fallen)
	for _, part in fallen.segments do
		part.CFrame = CFrame.new(0, -5000, 0)
	end
	for _, part in fallen.hood do
		part.CFrame = CFrame.new(0, -5000, 0)
	end
	fallen.stump.CFrame = CFrame.new(0, -5000, 0)
end

local function drawFallen(body, fallen)
	local chain = fallen.chain
	chain:update(body.state)

	-- A collapsing stalk SHORTENS as it goes over - 36 studs to 19 - so a
	-- spacing-driven walk would shed seven links to the parking lot mid-fall,
	-- in full view. A fixed count keeps the same fourteen vertebrae and simply
	-- packs them closer, which is what a collapsing body does anyway.
	chain:eachN(STALK_LINKS, function(i, cframe, u, spacing)
		local segment = fallen.segments[i]
		if not segment then
			segment = makePiece(if i % FIN_EVERY == 1 then "StalkFin" else "StalkSeg", body.folder)
			fallen.segments[i] = segment
		end
		applyLink(segment, cframe, math.max(spacing * OVERLAP, 0.2), 1 - STALK_TAPER * (1 - u) ^ 1.1)
	end)

	local hoodFrame = chain:cframeAt(0)
	for _, name in DOWN_PIECES do
		-- A dead lantern hangs off its hood exactly like a live one; a wreck
		-- whose bulb sat six studs out of its own head would be the same fault,
		-- only harder to catch for having no light left to give it away.
		applyPiece(fallen.hood[name], slung(name, fallen.hood[name], hoodFrame), HOOD_SCALE)
	end
	-- THE STUMP. A fallen curve keeps its root in the collar, so the stump is
	-- just the chain's far end - a broken socket that stays pointable-at for
	-- the rest of the fight, and the reason a regrown choir reads as a choir
	-- growing BACK.
	applyPiece(fallen.stump, chain:cframeAt(chain.length), 1)
end

local function drawFallenChoir(body, mask: number, dt: number, now: number)
	local state = body.state
	for index = 1, NoctyssPath.SOCKETS do
		local stalk = state.stalks[index]
		local fallen = body.fallen[index]
		if bit32.extract(mask, index - 1, 1) == 0 then
			-- Standing, or never down: the socket's own body draws it, and
			-- two controllers drawing one stalk would z-fight the whole arena.
			if fallen and fallen.downAt then
				fallen.downAt = nil
				parkFallen(fallen)
			end
			stalk.alive, stalk.fall, stalk.douse = true, 0, 0
		else
			fallen = fallen or newFallen(body, index)
			if not fallen.downAt then
				fallen.downAt, fallen.settled = now, false
				stalk.fall = 0
				-- The mask gaining a bit IS the instant that lantern died, and
				-- this is the only place that sees the transition: the stalk's
				-- own model is already gone. The one sharp sound in the fight,
				-- and the only one the player causes.
				Sfx.play("lanternBreak", NoctyssPath.bulbPosition(state, index))
			end
			stalk.alive, stalk.douse, stalk.lean = false, 1, 0
			if now - fallen.downAt >= DOUSE_LEAD then
				stalk.fall = math.min((stalk.fall or 0) + dt * FALL_RATE, 1)
			end
			if not fallen.settled then
				drawFallen(body, fallen)
				-- A stalk that has finished falling is perfectly still - every
				-- ambient term in the shape is scaled by (1 - fall) - so a
				-- wreck lying there for the rest of the fight costs nothing
				-- rather than recomputing the same CFrames sixty times a second.
				fallen.settled = (stalk.fall or 0) >= 1
			end
		end
	end
end

-- ---------------------------------------------------------------- the maw

-- Under the shelf she is not parked. A slow drift while she waits, faded out
-- long before she is up far enough to be stood in - so the punish window's
-- floor is exactly where NoctyssPath.mawMouth says it is, and the thing in the
-- pit still reads as something breathing rather than scenery not switched on.
local DRIFT = { PERIOD = 7.4, SWAY = 2.6, HEAVE = 1.4, YAW = math.rad(3.5), GONE_BY = 0.2 }

-- HOW HARD THE BITE RINGS HER OWN HEAD, in the units NoctyssPath.flinch takes
-- (a solid gunshot is 1.0, the blow that breaks a lantern 1.6).
--
-- 2.4 because 1.0 is invisible at this size. SHUDDER's envelope peaks at 0.589
-- of REACH, so strength 1 moves a skull 54 studs long by 0.88 studs - 1.6% of
-- its own body length, which is under the threshold where anything reads as
-- mass at all; it is the jar of a pebble, worn by a colossus. 2.4 puts the peak
-- at 2.1 studs, near 4%, which is where a big animal starts to look heavy, and
-- it still rings out inside half a second.
--
-- It stays under NoctyssPath's clamp of 3, so a scripted slam can still out-hit
-- the bite rather than saturating alongside it. And it is safe HERE in
-- particular: the offset is drawn only - the walkable floor is
-- NoctyssPath.mawMouth, which never sees it - and at the bite the mouth is
-- shutting, so there is nobody left standing on the surface that jars.
local BITE_SHUDDER = 2.4

-- HOW MUCH SMALLER THE ESCA'S LAMP IS THAN A CHOIR LANTERN'S. `setLantern`
-- sizes one thing: a lure 35 studs up that seven players have to compare
-- across a 68-stud shelf, so it ends up brighter and further than anything
-- hanging INSIDE a mouth should be. The esca has one job - lighting the
-- doorway the party is about to walk into during the punish window - and at
-- the choir's numbers it would flood the whole scoop and wash out the gullet,
-- which is the thing in there they are supposed to be looking at. Applied on
-- top of setLantern rather than by a second copy of it, so the material, the
-- colour and the douse rule stay in exactly one place.
local ESCA_LAMP = { BRIGHTNESS = 0.42, RANGE = 0.36 }

local function submergedDrift(state): CFrame
	local hidden = math.clamp(1 - (state.mawRise or 0) / DRIFT.GONE_BY, 0, 1)
	if hidden <= 0 then
		return CFrame.identity
	end
	local phase = (state.time or 0) / DRIFT.PERIOD * math.pi * 2
	-- Skull-local: +X is the nose, so the sway is on Z and the heave on Y.
	return CFrame.new(0, math.sin(phase * 0.7) * DRIFT.HEAVE * hidden, math.sin(phase) * DRIFT.SWAY * hidden)
		* CFrame.Angles(0, math.sin(phase * 0.43) * DRIFT.YAW * hidden, 0)
end

-- ---------------------------------------------------------------- the veins
--
-- ONE ORGANISM. Until now the arena said the opposite: seven stalks stood in
-- seven sockets, a head came up out of a hole, and the nineteen studs of bare
-- stone between them said the two had nothing to do with each other. The arena
-- mesh grows a flesh ridge from the pit's rim out to each socket (another
-- lane's file); this is what is inside those ridges - her blood, lit - and it
-- is the only thing that ever crosses that stone.
--
-- WHAT A VEIN MAY SAY IS BOUNDED BY WHAT THE LANTERN OVER IT ALREADY SAID.
-- Each ridge runs on ITS OWN socket's finished glow (`socketGlow`, written by
-- drawStalk this frame), so the true lure's ridge keeps the true lure's beat
-- and nothing else: the same brightness scale as the other six, dark when its
-- stalk douses, out when its stalk dies. A vein with a phase of its own would
-- be a second answer to the one question this fight asks, and a louder one,
-- because it is at the player's feet.
--
-- And when she comes up, they SURGE - rim outward, ahead of her - so the head
-- arriving in the pit is something the whole floor does rather than something
-- that happens in a hole.
local VEIN = {
	-- Four a ridge x seven sockets = 28 lights, the whole budget this arena has.
	-- It is `#SEATS` and cannot be anything else, so it is not a second number
	-- to keep in step - only the count, named.
	-- WHERE ON THE STRIP EACH LIGHT SITS. NoctyssPath.VEIN_POINTS gives five
	-- crest marks per strip (r 17, 20, 24, 27, 30); these four are the ones the
	-- budget buys, spaced off BOTH ends - a light on the rim would hang over the
	-- hole and light the maw's own hide, and one at the collar would sit inside
	-- it and be read as a stalk's lantern. The middle mark is the one dropped:
	-- it is the strip's straightest stretch, so it is the one a neighbour's
	-- range already covers.
	SEATS = { 1, 2, 4, 5 },
	LIFT = 0.8, -- studs over the crest: the strips are SUNK in a gutter
	BRIGHTNESS = 1.15, -- a lantern's is 2.4-7.0: under the choir, always
	RANGE = 16,
	COLOR = Color3.fromRGB(228, 118, 92), -- blood under skin, not another lure
	-- THE SURGE, in fractions of a ridge: a band travelling rim -> socket
	-- while she rises. WIDTH is the band, so the ring is still lighting up
	-- through the last third of the rise however long the travel is; HOLD is
	-- what stays in them while she is up, fading outward from the pit.
	SURGE = 1.9,
	WIDTH = 0.45,
	HOLD = 0.55,
}

-- Built once per maw body, into the body's own folder - so the one teardown
-- path every body has (destroyBody destroys the folder) takes the lights with
-- it, and nothing here is allocated again for the life of the fight. They do
-- not move: a ridge is stone, and only its brightness is alive.
local function veinLights(body)
	if body.veins then
		return body.veins
	end
	local veins = table.create(NoctyssPath.SOCKETS * #VEIN.SEATS)
	local centre = body.state.center
	local span = NoctyssPath.SOCKET_R - NoctyssPath.PIT_R
	for index = 1, NoctyssPath.SOCKETS do
		-- ON THE RIDGE, NOT ON THE LINE TO IT. These used to be laid on a
		-- straight rim -> socket ray, and the strips in the mesh are not
		-- straight: they sway +-1.7 studs and they climb the mantle's roll. So a
		-- light sat beside its own vein for most of the ridge and hung over the
		-- gutter, lighting stone, for the rest. NoctyssPath.VEIN_POINTS is the
		-- generator's own crest print (see the comment there) - arena-local,
		-- already in the Roblox frame, checked against the socket bearings.
		local strip = NoctyssPath.VEIN_POINTS[index]
		for step, seat in VEIN.SEATS do
			local crest = strip[seat]
			-- `t` is still the fraction of the rim -> socket span the surge is
			-- written against, but it is now MEASURED off the seat rather than
			-- assumed: the crest marks are not evenly spaced in radius, and the
			-- travelling band has to pass a light when it passes the ground the
			-- light is standing on.
			local radius = Vector3.new(crest.X, 0, crest.Z).Magnitude
			local t = math.clamp((radius - NoctyssPath.PIT_R) / span, 0, 1)
			local part = Instance.new("Part")
			part.Name = string.format("Vein%d_%d", index, step)
			part.Size = Vector3.new(0.2, 0.2, 0.2)
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			part.Transparency = 1
			part.CFrame = CFrame.new(centre + crest + Vector3.new(0, VEIN.LIFT, 0))
			local light = Instance.new("PointLight")
			light.Name = "Vein"
			light.Color = VEIN.COLOR
			light.Range = VEIN.RANGE
			light.Brightness = 0
			light.Enabled = false
			light.Shadows = false
			light.Parent = part
			part.Parent = body.folder
			table.insert(veins, { light = light, index = index, t = t })
		end
	end
	body.veins = veins
	return veins
end

local function drawVeins(body)
	local rise = math.clamp(body.state.mawRise or 0, 0, 1)
	-- The front, in ridge fractions: on the rim as she leaves the bottom, past
	-- the sockets by the time she is up.
	local front = rise * (1 + VEIN.WIDTH)
	for _, vein in veinLights(body) do
		local passed = front - vein.t
		local wave = if passed >= 0 and passed <= VEIN.WIDTH then math.sin(passed / VEIN.WIDTH * math.pi) else 0
		local glow = socketGlow[vein.index] or 0
		local surge = wave * VEIN.SURGE + rise * VEIN.HOLD * (1 - 0.45 * vein.t)
		local brightness = VEIN.BRIGHTNESS * (glow + surge)
		if brightness <= 0.02 then
			vein.light.Enabled = false
		else
			vein.light.Enabled = true
			vein.light.Brightness = brightness
			-- The reach opens with the surge and stays close on the pulse, so a
			-- breathing ridge is a line on the floor and a surging one washes
			-- the stone around it.
			vein.light.Range = VEIN.RANGE * (0.8 + 0.3 * math.clamp(surge, 0, 1))
		end
	end
end

-- --------------------------------------------------------- the rim snap
--
-- THE ONE TELL FOR A BITE THAT COMES OUT OF THE FLOOR. The herding snap is the
-- head using the choir: two limbs funnel a player toward the pit, and then she
-- comes up far enough for the lower jaw and the fangs to breach the rim and
-- shuts them on everything inside NoctyssPath.PIT_R + SNAP.MARGIN.
--
-- The body half of that tell is the partial rise itself, and it arrives the
-- ordinary way - the server publishes MawRise, this file eases toward it, the
-- head draws itself. That is deliberately NOT what the timing is read off:
-- EASE.mawRise is 2.2 a second, so the drawn head lags the truth by a couple of
-- tenths, and a player who dodged on the picture would be dodging a stale one.
-- The ring below is driven by `snapStart` on the shared clock instead, so the
-- line you must be outside of appears and flashes on the server's beat.
--
-- DRAWN AT THE TESTED RADIUS, EXACTLY. The band is laid on the circle
-- PIT_R + SNAP.MARGIN - the same number `snapHits` measures against - and it
-- marks the BOUNDARY rather than filling the disc: the inside of that circle is
-- a hole with a head coming up it, and a neon plate over the top would hide the
-- one thing worth looking at. Outside the line is safe; that is the whole rule,
-- and the line is where it says it is.
local SNAP_TILES = 18
local SNAP_BAND = 2.2 -- studs of radial width for the dim fill inside the edge

-- EDGE FIRST, FILL BEHIND IT, like every other mark in the fight. The edge is
-- TELL.EDGE_W wide and sits exactly on PIT_R + SNAP.MARGIN - the number
-- `snapHits` measures against, so a foot placed against the outside of that
-- line is a foot outside the bite. The fill is the old 2.2-stud band, moved
-- INWARD off the boundary and held dim: it gives the ring its body at distance
-- without plating over the hole, which is where the head the player is supposed
-- to be looking at is coming from.
--
-- Probed once, at build: the rim is a fixed circle on stone that does not move
-- for the life of the fight, so eighteen casts are paid once rather than
-- eighteen a frame.
local function snapRing(body)
	if body.snapRing then
		return body.snapRing
	end
	local ring = { edge = table.create(SNAP_TILES), fill = table.create(SNAP_TILES) }
	local state = body.state
	local radius = NoctyssPath.PIT_R + NoctyssPath.SNAP.MARGIN
	local inner = radius - TELL.EDGE_W * 0.5 - SNAP_BAND * 0.5
	local step = TAU / SNAP_TILES
	for i = 1, SNAP_TILES do
		local angle = (i - 0.5) * step
		local cos, sin = math.cos(angle), math.sin(angle)
		local along = Vector3.new(-sin, 0, cos)
		for _, row in { { ring.edge, radius, TELL.EDGE_W }, { ring.fill, inner, SNAP_BAND } } do
			local list, r, width = row[1], row[2], row[3]
			local at = NoctyssPath.markFloor(state, state.center.X + cos * r, state.center.Z + sin * r)
			local tile = makeShape(
				"SnapRing",
				body.folder,
				Enum.PartType.Block,
				Vector3.new(width, 0.12, ringChord(r, SNAP_TILES)),
				TELL.HEAD,
				true
			)
			tile.CFrame = CFrame.lookAt(at, at + along)
			table.insert(list, tile)
		end
	end
	body.snapRing = ring
	return ring
end

-- --------------------------------------------------------- the door's lane
--
-- THE SAFE SLOT, DRAWN AS A THING. Two of the portcullis's bars arrive at once
-- and they are ordinary slams in every respect the server can see (NoctyssPath
-- `isSlam`), so each is drawn by `drawSlamMark` in the same violet as every
-- other limb - a bar is not a new colour. What says "door" is the third part:
-- the 8-stud walkable centreline between the two capsules (DOOR.HALF 11 against
-- SLAM.RADIUS 7), in TELL.LIGHT at one steady Transparency. It is the only mark
-- in this fight that is not a countdown, because it is the only one that is
-- somewhere to GO rather than somewhere to leave - and a safe slot implied by
-- the gap between two bright bars is not a slot anyone finds in a black room
-- with a roof coming down.
--
-- DRAWN BY THE MAW AND NOT BY EITHER BAR. The lane is the door's, and the door
-- is the head's: `doorTargets` is solved off `mawMouth`, which only the maw's
-- body keeps a live pose state for (a stalk's state carries its own socket and
-- nothing else, so a bar asking where the door was would be told the mouth is
-- still under the shelf, facing the first lane). The bars announce it here on
-- arrival and the maw draws one lane, once.
local LANE_LENGTH = 26.0
local choirDoor = nil

local function drawDoorLane(body, now: number)
	local lane = body.doorLane
	if not choirDoor or now - choirDoor.start >= NoctyssPath.attackDuration(choirDoor) then
		choirDoor = nil
		if lane then
			lane.Transparency = 1
		end
		return
	end
	local state = body.state
	if not lane then
		lane = makeShape("DoorLane", body.folder, Enum.PartType.Block, Vector3.new(1, 0.12, 1), TELL.LIGHT, true)
		body.doorLane = lane
	end
	local one, two = NoctyssPath.doorTargets(state)
	local centre = (one + two) * 0.5
	local forward = NoctyssPath.mawFacing(state)
	local half = LANE_LENGTH * 0.5
	local a = NoctyssPath.markFloor(state, centre.X - forward.X * half, centre.Z - forward.Z * half)
	local b = NoctyssPath.markFloor(state, centre.X + forward.X * half, centre.Z + forward.Z * half)
	local span = b - a
	if span.Magnitude < 1e-3 then
		return
	end
	-- The gap the two capsules leave, exactly: what is drawn safe IS what is
	-- untested.
	lane.Size = Vector3.new(math.max((NoctyssPath.DOOR.HALF - NoctyssPath.SLAM.RADIUS) * 2, 0.5), 0.12, span.Magnitude)
	lane.CFrame = CFrame.lookAt(a + span * 0.5, b)
	lane.Transparency = DOOR_LANE_T
end

local function drawSnapRing(body, now: number)
	local snap = NoctyssPath.snapFor(body.state, now)
	if not snap then
		if body.snapRing then
			for _, list in { body.snapRing.edge, body.snapRing.fill } do
				for _, tile in list do
					tile.Transparency = 1
				end
			end
		end
		body.snapVoice = nil
		return
	end
	local ring = snapRing(body)
	-- THE SAME RAMP EVERY OTHER MARK RUNS. The rise is the lead-in, the bite is
	-- the live window, the sink is the fade - so the accelerating countdown that
	-- means "this lands soon" everywhere else in the fight means it here too.
	-- The ring used to own a quickening strobe of its own, which was a second
	-- language for the same fact.
	local u, live, since = NoctyssPath.snapTell(snap.start, now)
	-- TELL.HEAD, and it is the only place in the fight that is not a limb or a
	-- light: bone-white is reserved for her MOUTH, which is the one shape here
	-- you cannot out-walk.
	local edgeT, color, fillT = NoctyssPath.tellRamp(u, live, since, TELL.HEAD)
	for _, tile in ring.edge do
		tile.Transparency = edgeT
		tile.Color = color
	end
	for _, tile in ring.fill do
		tile.Transparency = fillT
		tile.Color = color
	end
	-- On the CROSSING, like every other cue in this file. `mawBite` is the
	-- catalogue's jaw slam and this is a jaw slam; the stamp is what stops
	-- drawMaw's own gape crossing sounding a second one a few frames later,
	-- when the server drives the gape shut on the same bite.
	local phase = NoctyssPath.snapPhase(snap.start, now)
	if phase ~= body.snapVoice then
		body.snapVoice = phase
		if phase == "bite" then
			body.snapBiteAt = now
			Sfx.play("mawBite", NoctyssPath.mawMouth(body.state).Position)
			NoctyssPath.shudder(body.state, BITE_SHUDDER)
		end
	end
end

local function drawMaw(model: Model, body, dt: number, now: number)
	local state = body.state
	-- THE SNAP'S HEAD IS NOT EASED. Everywhere else the server publishes MawRise
	-- and this file chases it, which is right: the punish window has no
	-- frame-accurate beat to hit. A snap does. EASE.mawRise is 2.2 a second
	-- against a partial rise of SNAP.RISE_TO over SNAP.RISE, so the eased head
	-- lagged the truth by about two tenths and the jaws visibly breached the rim
	-- AFTER the ring had already flashed its bite - the ring right, the head
	-- late, and the two reading as two events. Driven off `snapRise` on the
	-- shared clock for the frames a snap is live, which is the same function the
	-- server publishes from, so the rim and the mouth arrive together.
	local snap = NoctyssPath.snapFor(state, now)
	if snap then
		state.mawRise = NoctyssPath.snapRise(snap.start, now)
	else
		state.mawRise = approach(state.mawRise or 0, model:GetAttribute("MawRise") or 0, EASE.mawRise, dt)
	end
	state.mawGape = approach(state.mawGape or 0, model:GetAttribute("MawGape") or 0, EASE.mawGape, dt)
	state.mawYaw = approachAngle(state.mawYaw or 0, model:GetAttribute("MawYaw") or state.mawYaw, EASE.mawYaw, dt)
	state.time = now

	-- Two crossings worth hearing, taken here because this is where the eased
	-- numbers live: she breaks the surface, and the jaw shuts. Latched on the
	-- crossing rather than the value, or a maw sitting at the threshold would
	-- retrigger every frame.
	local mouth = NoctyssPath.mawMouth(state).Position
	if state.mawRise > 0.12 and not body.roared then
		body.roared = true
		Sfx.play("mawRise", mouth)
	elseif state.mawRise < 0.05 and body.roared then
		body.roared = false
	end
	if state.mawGape < 0.12 and body.wasOpen then
		body.wasOpen = false
		-- ...unless the rim snap has just sounded this same bite. That one is
		-- fired off `snapStart` on the shared clock and this one off an eased
		-- attribute, so on a snap they are the same event arriving twice, a few
		-- frames apart - which is audible as a stutter, not as a bigger bite.
		if now - (body.snapBiteAt or -math.huge) > 0.5 then
			Sfx.play("mawBite", mouth)
		end
		-- THE BITE HAS TO LAND. NoctyssPath.shudder is called on the SERVER at
		-- the jaw slam and replicates nothing - `state` is per-machine, and this
		-- client's copy was only ever raised by this file's own hit reactions -
		-- so the one moment the head should ring was the one moment it never
		-- did. Raised on the crossing that already sounds the bite, so the jar
		-- and the note can only ever come from the same test.
		NoctyssPath.shudder(state, BITE_SHUDDER)
	elseif state.mawGape > 0.6 then
		body.wasOpen = true
	end

	local scale = NoctyssPath.MAW.SCALE
	-- BOTH OF THESE ARE DRAWN ONLY, and both are bounded so they stay that
	-- way. The server tests the mouth against NoctyssPath.mawMouth, which sees
	-- neither: the jar peaks at 2.1 studs on the bite (BITE_SHUDDER, and under
	-- a stud for an ordinary hit) and rings down in half a second, by which
	-- point the mouth it belongs to has already shut; and the drift is gone
	-- before she has risen far enough to be stood in. Neither can move the
	-- punish window's floor out from under a player, which is the one thing
	-- this whole file may not do.
	local skull = NoctyssPath.mawCFrame(state)
		* CFrame.new(0, NoctyssPath.shudderOffset(state), 0)
		* submergedDrift(state)
	for _, name in SKULL_PIECES do
		applyPiece(body.pieces[name], skull, scale)
	end
	-- The jaw is the skull's frame turned about the authored hinge. Negative
	-- about Z because Blender's +Y (which the mesh was authored to hinge
	-- about) exports as Roblox's -Z.
	local gape = NoctyssPath.MAW.GAPE * math.clamp(state.mawGape, 0, 1)
	local jaw = skull * CFrame.new(JAW_HINGE * scale) * CFrame.Angles(0, 0, -gape) * CFrame.new(-JAW_HINGE * scale)
	for _, name in JAW_PIECES do
		-- The barbels are dragged by the jaw, not carried by it, so a bite
		-- whips them a beat after the teeth arrive.
		local frame = if name == "Barbels" then lagFrame(body, "barbelFrame", jaw, dt) else jaw
		applyPiece(body.pieces[name], frame, scale)
	end

	-- Her throat-light comes up with her: it is the only thing lighting the
	-- inside of the mouth, and it is what the party is in there to break.
	setLantern(body.pieces.Gullet, body.gulletLight, math.clamp(state.mawRise, 0, 1))

	-- And the esca with it, on the SAME gate: a lure burning over a mouth that
	-- is still under the water would be a light with no animal behind it, and
	-- in this arena an unexplained light is a lie about where the boss is. Up
	-- with her, out with her, and dimmed to the size of the doorway it lights.
	local escaGlow = math.clamp(state.mawRise, 0, 1)
	setLantern(body.pieces.Eyes, body.escaLight, escaGlow)
	if body.escaLight.Enabled then
		body.escaLight.Brightness *= ESCA_LAMP.BRIGHTNESS
		body.escaLight.Range *= ESCA_LAMP.RANGE
	end

	-- The wreckage of every socket this cycle has taken. Defensive about the
	-- attribute: an older server (or the frames before the boss's first pose
	-- update) publishes nothing, and no ChoirDown simply means no fallen.
	local mask = model:GetAttribute("ChoirDown")
	-- Folded down to the seven socket bits before anything reads it: bit32
	-- rejects a value that is not a whole number in range, and one malformed
	-- attribute would otherwise take the entire render loop down with it.
	drawFallenChoir(body, if type(mask) == "number" and mask > 0 then math.floor(mask) % 128 else 0, dt, now)

	-- Last, and off the same eased `mawRise` the head was just drawn from: the
	-- surge in the floor and the head it belongs to cannot disagree about how
	-- far up she is, because they are the same number read once.
	drawVeins(body)
	-- And the rim, if she is snapping at it. Off the shared clock rather than
	-- off any of the eased numbers above - see `drawSnapRing`.
	drawSnapRing(body, now)
	-- ...and the door's lane, if the two bars are down. Same reason it is here
	-- rather than on a stalk: the door is solved off this body's mouth.
	drawDoorLane(body, now)
end

local function watch(child: Instance)
	if not child:IsA("Model") then
		return
	end
	adoptStalk(child)
	adoptMaw(child)
	-- The model replicates before its first server frame sets `Pose`, so one
	-- of these two is always the one that actually fires.
	child:GetAttributeChangedSignal("Pose"):Connect(function()
		adoptStalk(child)
		adoptMaw(child)
	end)
end

function NoctyssBodyController.init()
	task.spawn(function()
		local folder = Workspace:WaitForChild(CREATURES_FOLDER, 30)
		if not folder then
			return
		end
		for _, child in folder:GetChildren() do
			watch(child)
		end
		folder.ChildAdded:Connect(watch)
	end)

	RunService.RenderStepped:Connect(function(dt)
		-- THE SYNCHRONISED CLOCK, NOT os.clock(). Every ambient term in
		-- NoctyssPath - the sway, the breath, the pulse - moves the lantern,
		-- and the lantern IS the server's hitbox (updateChoir stands each
		-- stalk's model at `bulbPosition`). Two machines' os.clock() share no
		-- epoch, so on a local one the bulb you can see sits up to a sway away
		-- from the bulb you can shoot, forever, with nothing in either log to
		-- explain the misses. NoctyssPath.clock() is what the server animates
		-- on, so the two cannot drift. Read once and shared by every body, so
		-- one frame is one instant across the whole arena.
		local now = NoctyssPath.clock()
		for model, body in bodies do
			if model.Parent == nil then
				destroyBody(model)
			elseif body.kind == "stalk" then
				drawStalk(model, body, dt, now)
			else
				drawMaw(model, body, dt, now)
			end
		end
	end)
end

-- ---------------------------------------------------------------- hits
--
-- WHAT IT LOOKS LIKE TO HIT THIS BOSS. Purely local, and deliberately so: the
-- flinch is an impulse inside the shape both sides already evaluate, on the
-- clock both sides already read, so the client can start one the instant it
-- watches a shot land without asking the server's permission or telling it
-- afterwards. Nothing is replicated for a reaction, and nothing waits a round
-- trip - the lantern jerks on the frame the player saw it get hit.
--
-- CreatureHit carries a POINT, not a model (one remote serves every creature
-- in the game), so the body that reacts is the one whose own anchor the shot
-- landed nearest. Distances are compared in units of each body's own reach,
-- so a stalk 12 studs off beats a maw 20 studs off rather than losing to it.
local function onCreatureHit(hitPoint: Vector3, direction: Vector3, killed: boolean)
	if typeof(hitPoint) ~= "Vector3" then
		return
	end
	local shot = if typeof(direction) == "Vector3" then direction else nil

	local best, bestScore = nil, 1.0
	for _, body in bodies do
		local score
		if body.kind == "stalk" then
			-- A stalk's anchor is its LANTERN: the server stands the whole
			-- model there, so a hit on a stalk happened at its bulb and
			-- nowhere else on the shape.
			score = (hitPoint - NoctyssPath.bulbPosition(body.state, body.index)).Magnitude / STALK_HIT_REACH
		elseif (body.state.mawRise or 0) > MAW_HIT_RISE then
			-- Only during the window. Below that she is under the shelf and
			-- untargetable, so anything landing over the pit hit something else.
			score = (hitPoint - NoctyssPath.mawMouth(body.state).Position).Magnitude / MAW_HIT_REACH
		end
		if score and score < bestScore then
			best, bestScore = body, score
		end
	end
	if not best then
		return
	end

	local strength = if killed then KILL_STRENGTH else HIT_STRENGTH
	if best.kind == "stalk" then
		local now = NoctyssPath.clock()
		-- A HIT ON A SWINGING LIMB IS NOT A FLINCH. The impulse is applied to
		-- the rest curve and is then rotated and stretched by the attack pose,
		-- so landing a shot on a stalk mid-slam threw the DRAWN eye over a stud
		-- off the tested one, in a direction rotated into the strike axis - on
		-- the one attack whose whole promise is that it lands on its own
		-- stripe. (NoctyssPath.stalkCurve refuses it too, at the other end; this
		-- is the same rule stated where the reaction is chosen, so the feedback
		-- that replaces it can be chosen with it.) The answer is the stutter and
		-- a flash at the bulb: the shooter still sees the hit register, on the
		-- light rather than on the limb, and nothing they are tracking moves.
		if NoctyssPath.stalkBusy(best.state, best.index, now) then
			Vfx.flash(NoctyssPath.bulbPosition(best.state, best.index), FLARE.COLOR, EYE_R * 1.4, STUTTER.DURATION)
		else
			-- Whipped along the shot's travel, so a lantern shot from the north
			-- rim goes over southward and the recoil points back at the shooter.
			NoctyssPath.flinch(best.state, best.index, strength, shot)
		end
		best.hitAt = now
	else
		NoctyssPath.shudder(best.state, strength)
	end
end

-- ---------------------------------------------------------------- the attacks
--
-- ONE TABLE, ONCE, PER SWING. `Remotes.ChoirAttack` carries the descriptor
-- documented in NoctyssPath ("the tentacles attack") and nothing else: no
-- frames, no progress, no pose. `start` is on the shared clock, so from here
-- the client derives the phase, the whole pose and every telegraph on its own,
-- and arrives at the same shape the server is testing against - the same
-- contract `choirBeam` already runs the lightsweep on.
--
-- Late or lost is safe in the only direction that matters: a client that never
-- receives one draws a limb that does not move, which is a missing animation.
-- It cannot produce damage the server did not, because the client tests
-- nothing.
local function onChoirAttack(attack)
	if type(attack) ~= "table" then
		return
	end
	if type(attack.index) ~= "number" or type(attack.start) ~= "number" or typeof(attack.target) ~= "Vector3" then
		return
	end
	-- THE ONE DESCRIPTOR THAT IS NOT A SOCKET'S. `herdingsnap` is the head
	-- biting its own rim - the second half of the move whose first half is two
	-- ordinary `stalkslam` bars, which arrive here and are routed by index like
	-- anything else. It carries index 0 and the pit's centre only so it passes
	-- the same validation every descriptor does (NoctyssPath.setSnap), and it
	-- goes to the MAW body, which is the one that owns the pit.
	if attack.kind == "herdingsnap" then
		-- ...and the whole choir is told, here, once: every living lantern dims
		-- through the rise (see `snapDim`). Taken off the descriptor rather than
		-- off the maw's state so all eight bodies read the same start on the
		-- same frame.
		choirSnapStart = attack.start
		for _, body in bodies do
			if body.kind == "maw" then
				NoctyssPath.setSnap(body.state, attack)
			end
		end
		return
	end
	for _, body in bodies do
		if body.kind == "stalk" and body.index == attack.index then
			-- LEAN TO ZERO ON THE FRAME THE DESCRIPTOR ARRIVES, not eased down
			-- over the next three tenths of a second. The server pins it to 0 on
			-- the swing's first frame and the pose is SOLVED FROM the shape the
			-- stalk is in, so anything but a snap here is the two machines
			-- posing off two different curves through the whole windup. Before
			-- `setAttack`, so the descriptor's first solve already sees it.
			local stalk = body.state.stalks[attack.index]
			if stalk then
				stalk.lean = 0
			end
			-- THE DOOR IS ANNOUNCED ONCE, to the body that knows where it is.
			-- Whichever bar arrives first names the beat; the second is the
			-- same `start`, so it changes nothing.
			if attack.kind == "portcullis" then
				choirDoor = attack
			end
			-- setAttack fills the scythe's sweep parameters if they are absent,
			-- by the same rules the server filled them with - so a descriptor
			-- that lost a field on the way still describes the same sweep.
			NoctyssPath.setAttack(body.state, attack)
			return
		end
	end
end

-- Connected in start(), not init(): Remotes resolves the instances on first
-- require, and every controller's init has to finish before anything is
-- listening anyway.
function NoctyssBodyController.start()
	Remotes.CreatureHit.OnClientEvent:Connect(onCreatureHit)
	Remotes.ChoirAttack.OnClientEvent:Connect(onChoirAttack)
end

return NoctyssBodyController

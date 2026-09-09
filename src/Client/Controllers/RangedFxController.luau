--!nonstrict
-- RangedFxController.luau
-- Draws every fired shot: a pooled bolt that flies from the muzzle to the
-- server's terminus, plus a muzzle flash. The glob pool's pattern
-- (CreatureEventController) with the direction reversed - the server said
-- exactly where each shot ends (ShotFired carries the termini, one per
-- pellet), the clients just animate the travel at the weapon row's
-- projectileSpeed. Arc weapons (bows) get a lobbed apex; guns fly flat.
--
-- For the LOCAL shooter the bolt starts at the viewmodel's muzzle rather
-- than the replicated origin, so the tracer leaves the gun on screen instead
-- of the camera's nose.
--
-- WHERE A SHOT STARTS IN THIRD PERSON (live playtest, 2026-09-08: "add bullet
-- trails for the guns in 3rd person"). The rule above is a FIRST-PERSON rule
-- and it was the only one there was. In third person the viewmodel is hidden
-- (CameraController.updateMode -> Viewmodel.setHidden) but it is still there,
-- still pinned to the camera - so getMuzzlePosition kept answering, and the
-- answer was a point floating at the camera's nose, several studs behind and
-- above the character's actual gun. Every one of your own tracers left the
-- wrong place, which is most of why they did not read.
--
-- So the origin is now chosen by what is actually DRAWING. Third person means
-- the welded EquippedWeapon model is the only gun on screen (that trade is
-- stated in CameraController.applyWeldedTools), so the muzzle comes off the
-- welded model - its `Weapon_Muzzle` marker if the mesh carries one, else the
-- grip projected up the bore by the row's own grip-to-tip span, the same two
-- steps and the same order WeaponViewmodelController uses on the viewmodel.
-- The same lookup serves OTHER players for free, so every tracer in the world
-- now leaves a real barrel instead of a chest-height origin.
--
-- AND THE TRACER ITSELF IS A BEAM, not just the bolt. The flying bolt is a
-- 0.14-stud neon part crossing 60 studs in a tenth of a second: on a screen
-- it is a couple of pixels for a couple of frames, which is legible from the
-- first-person camera sitting right behind it and invisible from a third-
-- person orbit. So a gun shot also lays a STREAK down the whole muzzle->hit
-- line for ~0.09s: two camera-facing beams, a hot orange halo under a
-- near-white core, so it reads against the pale sand of the wreck shoal and
-- against Wrack's dark hull alike. Bows are exempt - an arrow in flight is
-- already its own read, and a beam would only lie about the arc.
--
-- Every landing also pops an impact tick where the server said the shot ends,
-- which is what turns "something went that way" into "you hit that".
--
-- Pooled and budgeted: a full-auto pair of players is ~16 live bolts, so the
-- pool holds 24 and silently reuses the oldest, exactly like the glob pool.
-- The streak and tick pools are sized off the same number and reused the same
-- way.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Weapons = require(Shared.Data.Weapons)
local Remotes = require(Shared.Net.Remotes)

local CameraController = require(script.Parent.CameraController)
local WeaponViewmodelController = require(script.Parent.WeaponViewmodelController)

local player = Players.LocalPlayer

local RangedFxController = {}

local POOL = 24
local BOLT_SIZE = Vector3.new(0.14, 0.14, 1.6)
local ARROW_SIZE = Vector3.new(0.1, 0.1, 2.2)
local BOLT_COLOR = Color3.fromRGB(255, 224, 150)
local ARROW_COLOR = Color3.fromRGB(214, 190, 140)
local FLASH_TIME = 0.06
local FLASH_SIZE = 0.9
local ARC_APEX_PER_STUD = 0.06 -- a bow shot's lob height per stud of range

-- The streak. Two beams per tracer because ONE never reads on both grounds:
-- a white core alone washes out against the wreck's pale sand, and an orange
-- line alone disappears into Wrack's rust and the dark hull. Layered, the
-- halo carries the shape and the core carries the punch.
local TRACER_POOL = 12
local TRACER_TIME = 0.09
local TRACER_CORE_WIDTH = 0.17
local TRACER_HALO_WIDTH = 0.52
local TRACER_CORE_COLOR = Color3.fromRGB(255, 250, 224)
local TRACER_HALO_COLOR = Color3.fromRGB(255, 146, 38)
local TRACER_HALO_FLOOR = 0.4 -- the halo never goes fully opaque, so it glows

-- The impact tick: a brief bloom where the server said the shot ends. Fired
-- when a bolt finishes its flight, so it lands with the damage rather than
-- with the trigger pull.
local IMPACT_POOL = 10
local IMPACT_TIME = 0.11
local IMPACT_SIZE = 1.15
local IMPACT_COLOR = Color3.fromRGB(255, 226, 168)

local folder: Folder? = nil
local bolts = {}
local boltCursor = 1
local flashes = {}
local flashCursor = 1
local tracers = {}
local tracerCursor = 1
local impacts = {}
local impactCursor = 1

local function ensureFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "RangedFx"
	f.Parent = Workspace
	folder = f
	return f
end

local function makePart(size: Vector3): Part
	local part = Instance.new("Part")
	part.Size = size
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Transparency = 1
	part.Parent = ensureFolder()
	return part
end

-- ---------------------------------------------------------------- the streak
-- One pooled tracer: an invisible anchored host part carrying two Attachments
-- and the two Beams strung between them. Beams are used rather than a long
-- thin part on purpose - `FaceCamera` keeps the streak broadside to whatever
-- camera is looking at it, so a shot fired straight away from a third-person
-- orbit still draws a line instead of vanishing to a point end-on.
local function makeTracer()
	local host = Instance.new("Part")
	host.Size = Vector3.one * 0.05
	host.Anchored = true
	host.CanCollide = false
	host.CanQuery = false
	host.CanTouch = false
	host.CastShadow = false
	host.Transparency = 1
	host.Parent = ensureFolder()

	local a0 = Instance.new("Attachment")
	a0.Parent = host
	local a1 = Instance.new("Attachment")
	a1.Parent = host

	local function beam(color: Color3, width: number): Beam
		local b = Instance.new("Beam")
		b.Attachment0 = a0
		b.Attachment1 = a1
		b.FaceCamera = true
		b.LightInfluence = 0
		b.Segments = 1
		b.Width0 = width
		b.Width1 = width * 0.55 -- tapers toward the impact, so it reads directional
		b.Color = ColorSequence.new(color)
		b.Transparency = NumberSequence.new(1)
		b.Parent = host
		return b
	end

	return {
		host = host,
		a0 = a0,
		a1 = a1,
		halo = beam(TRACER_HALO_COLOR, TRACER_HALO_WIDTH),
		core = beam(TRACER_CORE_COLOR, TRACER_CORE_WIDTH),
		until_ = 0,
	}
end

local function streak(from: Vector3, to: Vector3)
	local span = to - from
	local length = span.Magnitude
	if length < 0.05 then
		return
	end
	local tracer = tracers[tracerCursor]
	tracerCursor = tracerCursor % TRACER_POOL + 1
	-- lookAt puts -Z on the target, so the muzzle end sits at +Z.
	tracer.host.CFrame = CFrame.lookAt(from + span * 0.5, to)
	tracer.a0.Position = Vector3.new(0, 0, length * 0.5)
	tracer.a1.Position = Vector3.new(0, 0, -length * 0.5)
	tracer.until_ = os.clock() + TRACER_TIME
	tracer.halo.Transparency = NumberSequence.new(TRACER_HALO_FLOOR)
	tracer.core.Transparency = NumberSequence.new(0)
end

local function impactTick(at: Vector3)
	local impact = impacts[impactCursor]
	impactCursor = impactCursor % IMPACT_POOL + 1
	impact.part.CFrame = CFrame.new(at)
	impact.startedAt = os.clock()
	impact.until_ = impact.startedAt + IMPACT_TIME
	impact.part.Transparency = 0.1
end

-- ---------------------------------------------------------------- muzzles
-- The welded EquippedWeapon's barrel tip, in world space. WeaponService welds
-- the built model into the right hand with the grip AT the hand's origin, so
-- the two steps here are the same two WeaponViewmodelController takes on the
-- viewmodel: the mesh contract's `Weapon_Muzzle` marker caps the bore exactly
-- and is authoritative, and the grip projected along the weapon frame's +Y by
-- the row's grip-to-tip span is the pre-mesh fallback.
local WELDED_WEAPON = "EquippedWeapon"

local function weldedMuzzle(character: Model?, weaponData): Vector3?
	if not character then
		return nil
	end
	local model = character:FindFirstChild(WELDED_WEAPON)
	if not model then
		return nil
	end
	local marker = model:FindFirstChild("Weapon_Muzzle", true)
	if marker and marker:IsA("BasePart") then
		return marker.Position
	end
	local grip = model:FindFirstChild("Weapon_Grip", true)
	local m = weaponData and weaponData.model
	if grip and grip:IsA("BasePart") and m and m.length and m.grip then
		return grip.CFrame:PointToWorldSpace(Vector3.new(0, m.length - m.grip, 0))
	end
	return nil
end

-- ---------------------------------------------------------------- projectiles
-- A `ranged.projectile` weapon (bow / crossbow / harpooner) flies a REAL
-- arrow, not a tracer: the WeaponPack's own <Variant>_Mag mesh - the very
-- arrow the reload animation nocks - cloned per shot from a small per-variant
-- pool. Before the pack is imported (or for a variant without a _Mag) a
-- procedural arrow stands in, recoloured from the row's accent. Both are
-- authored along the weapon frame's +Y (butt -> tip), so one axis mapping
-- (+Y onto the flight's -Z look direction) orients either.

local PROJECTILE_POOL = 4 -- per variant; these weapons fire 0.45-1.3s apart

local projectilePools: { [string]: { Model } } = {}
local projectileCursors: { [string]: number } = {}

local function stripClone(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
end

-- The stand-in when no mesh is available: a slim shaft, a nose, two crossed
-- fletching plates - one Part each, welded into a Model along +Y.
local function proceduralArrow(accent: Color3): Model
	local model = Instance.new("Model")
	local shaft = Instance.new("Part")
	shaft.Size = Vector3.new(0.08, 2.0, 0.08)
	shaft.Color = Color3.fromRGB(120, 96, 64)
	shaft.Material = Enum.Material.SmoothPlastic
	stripClone(shaft)
	shaft.Parent = model
	local head = Instance.new("Part")
	head.Size = Vector3.new(0.16, 0.3, 0.05)
	head.Color = accent
	head.Material = Enum.Material.SmoothPlastic
	stripClone(head)
	head.CFrame = shaft.CFrame * CFrame.new(0, 1.05, 0)
	head.Parent = model
	for i = 0, 1 do
		local fletch = Instance.new("Part")
		fletch.Size = Vector3.new(0.02, 0.34, 0.22)
		fletch.Color = Color3.fromRGB(226, 222, 210)
		fletch.Material = Enum.Material.SmoothPlastic
		stripClone(fletch)
		fletch.CFrame = shaft.CFrame * CFrame.new(0, -0.85, 0) * CFrame.Angles(0, math.rad(90 * i), 0)
		fletch.Parent = model
	end
	model.PrimaryPart = shaft
	return model
end

-- One pooled projectile: the pack's <Variant>_Mag clone (recoloured to the
-- row's accent, like WeaponModel would) or the procedural arrow, wrapped so
-- the pool only ever handles its primary part's CFrame.
local function makeProjectile(weapon): BasePart
	local m = weapon.model
	local holder: Model? = nil
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local pack = m and m.model and assets and assets:FindFirstChild(m.model)
	local mag = pack and m.variant and pack:FindFirstChild(m.variant .. "_Mag", true)
	if mag and mag:IsA("BasePart") then
		local clone = mag:Clone()
		clone:ClearAllChildren()
		stripClone(clone)
		clone.Color = m.accent
		holder = Instance.new("Model")
		clone.Parent = holder
		holder.PrimaryPart = clone
	else
		holder = proceduralArrow(if m then m.accent else Color3.fromRGB(200, 200, 200))
	end
	for _, part in holder:GetDescendants() do
		if part:IsA("BasePart") then
			part.Transparency = 1
		end
	end
	holder.Parent = ensureFolder()
	return holder
end

-- The next pooled projectile MODEL for this weapon (whole models, moved with
-- PivotTo so multi-part stand-ins travel as one), or nil for a variant-less
-- row.
local function takeProjectile(weapon): Model?
	local variant = weapon.model and weapon.model.variant
	if not variant then
		return nil
	end
	local pool = projectilePools[variant]
	if not pool then
		pool = {}
		for i = 1, PROJECTILE_POOL do
			pool[i] = makeProjectile(weapon)
		end
		projectilePools[variant] = pool
		projectileCursors[variant] = 1
	end
	local cursor = projectileCursors[variant]
	projectileCursors[variant] = cursor % PROJECTILE_POOL + 1
	return pool[cursor]
end

local function setProjectileVisible(model: Model, visible: boolean)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Transparency = if visible then 0 else 1
		end
	end
end

-- Projectiles are authored along the weapon frame's +Y; flight CFrames look
-- down -Z. This maps one onto the other.
local PROJECTILE_ORIENT = CFrame.Angles(-math.rad(90), 0, 0)

function RangedFxController.init()
	ensureFolder()
	for i = 1, POOL do
		bolts[i] = { part = makePart(BOLT_SIZE), active = false }
	end
	for i = 1, 6 do
		flashes[i] = { part = makePart(Vector3.new(FLASH_SIZE, FLASH_SIZE, FLASH_SIZE)), until_ = 0 }
		flashes[i].part.Shape = Enum.PartType.Ball
		flashes[i].part.Color = Color3.fromRGB(255, 214, 120)
	end
	for i = 1, TRACER_POOL do
		tracers[i] = makeTracer()
	end
	for i = 1, IMPACT_POOL do
		impacts[i] = { part = makePart(Vector3.one * IMPACT_SIZE), until_ = 0, startedAt = 0 }
		impacts[i].part.Shape = Enum.PartType.Ball
		impacts[i].part.Color = IMPACT_COLOR
	end
end

local function muzzleFlash(at: Vector3)
	local flash = flashes[flashCursor]
	flashCursor = flashCursor % #flashes + 1
	flash.until_ = os.clock() + FLASH_TIME
	flash.part.CFrame = CFrame.new(at)
	flash.part.Transparency = 0.15
end

local function launchBolt(from: Vector3, to: Vector3, speed: number, arc: boolean, projectile: Model?)
	local bolt = bolts[boltCursor]
	boltCursor = boltCursor % POOL + 1
	bolt.active = true
	bolt.from = from
	bolt.to = to
	bolt.arc = arc
	bolt.start = os.clock()
	bolt.flight = math.max((to - from).Magnitude / math.max(speed, 40), 0.03)
	bolt.apex = if arc then (to - from).Magnitude * ARC_APEX_PER_STUD else 0
	-- Retire whatever model a reused slot still carries.
	if bolt.model then
		setProjectileVisible(bolt.model, false)
	end
	bolt.model = projectile
	if projectile then
		-- The real arrow flies; the neon tracer part stays dark.
		bolt.part.Transparency = 1
		setProjectileVisible(projectile, true)
	else
		bolt.part.Size = if arc then ARROW_SIZE else BOLT_SIZE
		bolt.part.Color = if arc then ARROW_COLOR else BOLT_COLOR
		bolt.part.Transparency = 0
	end
end

local function onShotFired(attackerUserId: number, origin, termini, weaponId)
	if typeof(origin) ~= "Vector3" or type(termini) ~= "table" then
		return
	end
	local weapon = Weapons.items[weaponId]
	local ranged = weapon and weapon.ranged
	if not ranged then
		return
	end

	-- WHICH GUN IS ON SCREEN decides where the shot starts (see the header).
	-- First person: the viewmodel, which is the only weapon the owner can
	-- see. Third person and every other player: the welded model in the hand,
	-- which is the only weapon anyone can see. The server's echoed origin is
	-- the floor under both - a chest-height point, right often enough that a
	-- weapon still streaming in never costs a tracer.
	local shooter = Players:GetPlayerByUserId(attackerUserId)
	local from = origin
	if attackerUserId == player.UserId and not CameraController.isThirdPerson() then
		from = WeaponViewmodelController.getMuzzlePosition() or origin
	else
		from = weldedMuzzle(shooter and shooter.Character, weapon) or origin
	end

	-- A bow doesn't flash; its arrow IS the effect.
	if not ranged.projectile then
		muzzleFlash(from)
	end
	for _, to in termini do
		if typeof(to) == "Vector3" then
			local projectile = if ranged.projectile then takeProjectile(weapon) else nil
			launchBolt(from, to, ranged.projectileSpeed, ranged.arc == true, projectile)
			-- The streak is a GUN read. A bow's arrow flies its own arc and a
			-- straight beam would draw a path it never takes.
			if not ranged.projectile and not ranged.arc then
				streak(from, to)
			end
		end
	end
end

local function update()
	local now = os.clock()
	for _, bolt in bolts do
		if bolt.active then
			local t = (now - bolt.start) / bolt.flight
			if t >= 1 then
				bolt.active = false
				bolt.part.Transparency = 1
				if bolt.model then
					setProjectileVisible(bolt.model, false)
					bolt.model = nil
				end
				-- Landed. The tick goes off HERE rather than at the trigger
				-- pull, so it arrives with the damage the server queued for
				-- the same flight time.
				impactTick(bolt.to)
			else
				local at = bolt.from:Lerp(bolt.to, t)
				if bolt.apex > 0 then
					at += Vector3.new(0, bolt.apex * 4 * t * (1 - t), 0)
				end
				-- Point down the (arced) path: aim at a hair ahead of itself.
				local aheadT = math.min(t + 0.05, 1)
				local ahead = bolt.from:Lerp(bolt.to, aheadT)
				if bolt.apex > 0 then
					ahead += Vector3.new(0, bolt.apex * 4 * aheadT * (1 - aheadT), 0)
				end
				local cf = if (ahead - at).Magnitude > 0.01 then CFrame.lookAt(at, ahead) else CFrame.new(at)
				if bolt.model then
					bolt.model:PivotTo(cf * PROJECTILE_ORIENT)
				else
					bolt.part.CFrame = cf
				end
			end
		end
	end
	for _, flash in flashes do
		if flash.until_ > 0 and now >= flash.until_ then
			flash.until_ = 0
			flash.part.Transparency = 1
		end
	end
	-- The streak fades rather than blinking out: at a tenth of a second a hard
	-- cut reads as a flicker, a fade reads as a round going past.
	for _, tracer in tracers do
		if tracer.until_ > 0 then
			local left = (tracer.until_ - now) / TRACER_TIME
			if left <= 0 then
				tracer.until_ = 0
				tracer.halo.Transparency = NumberSequence.new(1)
				tracer.core.Transparency = NumberSequence.new(1)
			else
				local fade = 1 - left
				tracer.halo.Transparency = NumberSequence.new(TRACER_HALO_FLOOR + (1 - TRACER_HALO_FLOOR) * fade)
				tracer.core.Transparency = NumberSequence.new(fade)
			end
		end
	end
	for _, impact in impacts do
		if impact.until_ > 0 then
			local t = (now - impact.startedAt) / IMPACT_TIME
			if t >= 1 then
				impact.until_ = 0
				impact.part.Transparency = 1
				impact.part.Size = Vector3.one * IMPACT_SIZE
			else
				-- Blooms out as it goes, so the eye is pulled to where it
				-- started - the thing that was hit.
				impact.part.Size = Vector3.one * (IMPACT_SIZE * (0.45 + 0.85 * t))
				impact.part.Transparency = 0.1 + 0.9 * t
			end
		end
	end
end

function RangedFxController.start()
	Remotes.ShotFired.OnClientEvent:Connect(onShotFired)
	RunService.RenderStepped:Connect(update)
end

return RangedFxController

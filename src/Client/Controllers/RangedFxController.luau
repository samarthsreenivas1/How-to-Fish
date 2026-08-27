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
-- of the camera's nose. Other players' shots start at their character's
-- chest height origin the server echoed - close enough for a fast bolt.
--
-- Pooled and budgeted: a full-auto pair of players is ~16 live bolts, so the
-- pool holds 24 and silently reuses the oldest, exactly like the glob pool.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Weapons = require(Shared.Data.Weapons)
local Remotes = require(Shared.Net.Remotes)

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

local folder: Folder? = nil
local bolts = {}
local boltCursor = 1
local flashes = {}
local flashCursor = 1

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

	-- The shooter's own bolt leaves the on-screen gun; everyone else's leaves
	-- the origin the server echoed.
	local from = origin
	if attackerUserId == player.UserId then
		from = WeaponViewmodelController.getMuzzlePosition() or origin
	end

	-- A bow doesn't flash; its arrow IS the effect.
	if not ranged.projectile then
		muzzleFlash(from)
	end
	for _, to in termini do
		if typeof(to) == "Vector3" then
			local projectile = if ranged.projectile then takeProjectile(weapon) else nil
			launchBolt(from, to, ranged.projectileSpeed, ranged.arc == true, projectile)
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
end

function RangedFxController.start()
	Remotes.ShotFired.OnClientEvent:Connect(onShotFired)
	RunService.RenderStepped:Connect(update)
end

return RangedFxController

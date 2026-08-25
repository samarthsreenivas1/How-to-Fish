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

local function launchBolt(from: Vector3, to: Vector3, speed: number, arc: boolean)
	local bolt = bolts[boltCursor]
	boltCursor = boltCursor % POOL + 1
	bolt.active = true
	bolt.from = from
	bolt.to = to
	bolt.arc = arc
	bolt.start = os.clock()
	bolt.flight = math.max((to - from).Magnitude / math.max(speed, 40), 0.03)
	bolt.apex = if arc then (to - from).Magnitude * ARC_APEX_PER_STUD else 0
	bolt.part.Size = if arc then ARROW_SIZE else BOLT_SIZE
	bolt.part.Color = if arc then ARROW_COLOR else BOLT_COLOR
	bolt.part.Transparency = 0
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

	muzzleFlash(from)
	for _, to in termini do
		if typeof(to) == "Vector3" then
			launchBolt(from, to, ranged.projectileSpeed, ranged.arc == true)
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
				if (ahead - at).Magnitude > 0.01 then
					bolt.part.CFrame = CFrame.lookAt(at, ahead)
				else
					bolt.part.CFrame = CFrame.new(at)
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

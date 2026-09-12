--!nonstrict
-- MaelstromVfxController.luau
-- Makes the Maelstrom's whirlpool TURN, entirely client-side (the same idea
-- as OceanController scrolling the sea and LavaController working the lava):
--
--   * the storm disc itself (Maelstrom_Water, WorldService.buildMaelstromSite)
--     spins slowly about its centre, carrying a tinted caustics texture with
--     it, so the water visibly circles the drain;
--   * a second, smaller counter-rotating layer floats just above it, faster
--     and fainter, which is what sells the spiral (two speeds read as flow;
--     one reads as a turntable);
--   * a foam collar of slow ripples at the rim.
--
-- The disc is anchored and the server never moves it, so a local CFrame spin
-- can't fight replication - the same ruling as the tide. Rotation is about
-- the world Y axis through the disc's own position: the cylinder is round,
-- so physics, casts and the fishing surface are untouched. Pure decoration:
-- no server, no remotes, no imports. On a server without the site (it builds
-- at boot; this waits generously) the controller simply idles.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ocean = require(Shared.Config.Ocean)
local World = require(Shared.Config.World)

local Sfx = require(script.Parent.Parent.Modules.Sfx)

local MaelstromVfxController = {}

local SITE_NAME = "Maelstrom"
local WATER_NAME = "Maelstrom_Water"

local SPIN_SPEED = 0.055 -- radians/second, the big disc
local INNER_SPIN_SPEED = -0.14 -- the counter-layer; opposite sign = counter-rotation
local INNER_SCALE = 0.62 -- of the disc's diameter
local INNER_LIFT = 0.06 -- studs above the disc
local TEXTURE_TILE = 26 -- studs per caustics tile on the big disc
local INNER_TILE = 16
local TEXTURE_COLOR = Color3.fromRGB(120, 150, 220) -- storm-lit caustics
local INNER_COLOR = Color3.fromRGB(170, 195, 240)

-- The drain's roar. The whirlpool is a fixed landmark, so its loop sits at one
-- world point and never moves; all that changes is whether it exists at all.
-- ONE handle for the controller: Sfx.loop returns a part that plays until
-- stopLoop is called, and a handle overwritten before it is stopped is a sound
-- nothing can reach again - it plays for the rest of the session. Hence the
-- strict pairing below (start only when the handle is nil, clear it on stop),
-- and the hysteresis: a single threshold makes the loop chatter on and off
-- twice a second for anyone standing exactly on the rim of earshot.
local WHIRL_EARSHOT = 220 -- studs; the Maelstrom is heard from well out at sea
local WHIRL_EARSHOT_OUT = 260
local WHIRL_INTERVAL = 0.5 -- seconds between distance checks

local disc: BasePart? = nil
local inner: BasePart? = nil
local baseCFrame: CFrame? = nil
local angle = 0
local innerAngle = 0
local roar: BasePart? = nil

-- The caustics texture on a face of the spinning part, so the light lines
-- turn with the water instead of sitting still under it.
local function dress(part: BasePart, face: Enum.NormalId, tile: number, color: Color3, transparency: number)
	local texture = Instance.new("Texture")
	texture.Name = "Swirl"
	texture.Texture = "rbxassetid://" .. Ocean.TEXTURE_ID
	texture.Face = face
	texture.StudsPerTileU = tile
	texture.StudsPerTileV = tile
	texture.Color3 = color
	texture.Transparency = transparency
	texture.Parent = part
end

local function build(water: BasePart)
	disc = water
	baseCFrame = water.CFrame
	-- The cylinder stands on its X axis (rotated 90 about Z), so its "top"
	-- circle is the Right face.
	dress(water, Enum.NormalId.Right, TEXTURE_TILE, TEXTURE_COLOR, 0.55)

	-- The counter-layer: a local-only clone of the disc, smaller, higher,
	-- fainter, spinning the other way.
	local layer = Instance.new("Part")
	layer.Name = "Maelstrom_Swirl"
	layer.Shape = Enum.PartType.Cylinder
	layer.Size = Vector3.new(0.2, water.Size.Y * INNER_SCALE, water.Size.Z * INNER_SCALE)
	layer.CFrame = baseCFrame * CFrame.new(INNER_LIFT + water.Size.X / 2, 0, 0)
	layer.Anchored = true
	layer.CanCollide = false
	layer.CanQuery = false -- the aim ray must reach the REAL fishable disc under it
	layer.CanTouch = false
	layer.CastShadow = false
	layer.Color = water.Color
	layer.Material = Enum.Material.SmoothPlastic
	layer.Transparency = 1 -- only its texture shows
	dress(layer, Enum.NormalId.Right, INNER_TILE, INNER_COLOR, 0.45)
	layer.Parent = water.Parent
	inner = layer
end

local function step(dt: number)
	if not (disc and baseCFrame) then
		return
	end
	angle = (angle + SPIN_SPEED * dt) % (math.pi * 2)
	innerAngle = (innerAngle + INNER_SPIN_SPEED * dt) % (math.pi * 2)
	-- World-Y spin about the disc's own position; the cylinder's stand-up
	-- roll lives in baseCFrame, so this only turns the water plane.
	local at = baseCFrame.Position
	disc.CFrame = CFrame.new(at) * CFrame.Angles(0, angle, 0) * (baseCFrame - at)
	if inner then
		local lift = Vector3.new(0, INNER_LIFT + (disc.Size.X / 2), 0)
		inner.CFrame = CFrame.new(at + lift) * CFrame.Angles(0, innerAngle, 0) * (baseCFrame - at)
	end
end

-- Where the local player is, or the camera while they have no character
-- (respawning, spectating) so the drain doesn't cut to silence on death.
local function listenerAt(): Vector3?
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	local cam = Workspace.CurrentCamera
	return cam and cam.CFrame.Position or nil
end

-- Start / stop the one whirlpool loop as the player comes and goes. `at` is
-- the disc's centre, captured once - the disc spins in place and its position
-- never changes, so there is nothing to move the loop to.
local function roarLoop(at: Vector3)
	while true do
		task.wait(WHIRL_INTERVAL)
		-- The site was torn out from under us (world rebuild): drop the loop
		-- and end the thread rather than roaring at an empty patch of sea.
		if not (disc and disc.Parent) then
			Sfx.stopLoop(roar)
			roar = nil
			return
		end
		local ear = listenerAt()
		local distance = if ear then (ear - at).Magnitude else math.huge
		if distance <= WHIRL_EARSHOT then
			if not roar then
				roar = Sfx.loop("whirlpool", at)
			end
		elseif roar and distance > WHIRL_EARSHOT_OUT then
			Sfx.stopLoop(roar)
			roar = nil
		end
	end
end

function MaelstromVfxController.start()
	task.spawn(function()
		local world = Workspace:WaitForChild(World.FOLDER_NAME, 30)
		if not world then
			return
		end
		local site = world:WaitForChild(SITE_NAME, 60)
		if not site then
			return -- no Maelstrom site in this world; nothing to turn
		end
		local water = site:WaitForChild(WATER_NAME, 10)
		if not (water and water:IsA("BasePart")) then
			warn("[MaelstromVfx] site exists but no " .. WATER_NAME .. " part; whirlpool still")
			return
		end
		build(water)
		RunService.RenderStepped:Connect(step)
		-- Its own thread, and the only owner of the whirlpool loop handle.
		task.spawn(roarLoop, water.Position)
	end)
end

return MaelstromVfxController

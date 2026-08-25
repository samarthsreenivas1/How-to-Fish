--!nonstrict
-- ShotAim.luau
-- Where a shot is allowed to come from and what stops it. CastAim's sibling
-- for the ranged weapons (docs/revamp-plan.md Systems §1), shared for the
-- same reason: the client aims along its camera and predicts the tracer's
-- end, the server re-validates the same ray before any damage happens, and
-- both need the identical answer to "what did the world stop this on?".
--
-- Deliberately terrain-only. Creature parts are CanQuery = false (targeting
-- has always been proximity, not raycast - see CreatureService), so the
-- creature half of a shot lives server-side in CreatureService.raycastNearest,
-- which walks the live structs against the ray. This module answers the two
-- questions both sides share: is the claimed origin really this character's
-- camera, and how far does the world let the ray travel.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tuning = require(Shared.Config.Tuning)
local World = require(Shared.Config.World)

local ShotAim = {}

-- Solid world geometry only: the World folder with RespectCanCollide, so a
-- shot stops on sand / rock / dock planks but passes through palm fronds,
-- bushes, the foam rim, and the invisible barriers (CanQuery = false keeps
-- those out regardless). Creatures and characters are never in this folder.
local function worldParams(): RaycastParams?
	local folder = Workspace:FindFirstChild(World.FOLDER_NAME)
	if not folder then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { folder }
	params.RespectCanCollide = true
	return params
end

-- Is `rayOrigin` plausibly this character's camera? The camera floats near
-- the head, so the claim must sit within ORIGIN_SLACK of the root - a hacked
-- client can't originate shots from across the map. Shared so the client can
-- pre-check the same rule it will be held to.
function ShotAim.originOk(character: Model?, rayOrigin: Vector3): boolean
	if typeof(rayOrigin) ~= "Vector3" or rayOrigin ~= rayOrigin then
		return false
	end
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	return (rayOrigin - root.Position).Magnitude <= Tuning.Ranged.ORIGIN_SLACK
end

-- How far the world lets a ray travel from `origin` along `look`, capped at
-- `range`: the distance to the first solid world hit, or `range` clear.
-- Also returns the hit position when something stopped it.
function ShotAim.terrainLimit(origin: Vector3, look: Vector3, range: number): (number, Vector3?)
	local params = worldParams()
	if not params or look.Magnitude < 0.001 then
		return range, nil
	end
	local hit = Workspace:Raycast(origin, look.Unit * range, params)
	if hit then
		return (hit.Position - origin).Magnitude, hit.Position
	end
	return range, nil
end

-- The point a tracer ends at when nothing alive is in the way: the terrain
-- stop, or full range into open air. What the client draws while the server
-- decides what was actually hit.
function ShotAim.terminus(origin: Vector3, look: Vector3, range: number): Vector3
	local dist, hitPos = ShotAim.terrainLimit(origin, look, range)
	if hitPos then
		return hitPos
	end
	return origin + look.Unit * dist
end

return ShotAim

--!nonstrict
-- CastAim.luau
-- Where a cast is allowed to land.
--
-- Shared on purpose: the client aims along the camera and tells the player
-- why a cast can't happen *before* asking the server, and the server
-- re-checks the claimed point before accepting it. Both sides need the same
-- answer to "is that fishable?" and "is that close enough?", so there is
-- one copy of each here rather than one per side drifting apart.
--
-- "Fishable" is any part named in World.FISHABLE_NAMES: the single Ocean
-- part WorldService builds, and the volcano's lava lake (a mesh part high
-- up in the crater, fished from the rim). The island mesh (sand, rocks,
-- dock) sits above the ocean near the shore, so a ray that reaches a
-- fishable part by name is over open water/lava and one that stops on
-- anything else isn't. Both probes only look at the World folder, so the
-- player's own viewmodel, the bobber, and creatures never get in the way;
-- the invisible rim walls are CanQuery=false so they don't either.
--
-- A landing point carries its surface's Y (WATER_Y for the ocean, the
-- hit's height for lava); nothing downstream should assume the waterline.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local Tuning = require(Shared.Config.Tuning)
local World = require(Shared.Config.World)

local CastAim = {}

-- How far the aim ray looks. Longer than any cast reach so "that's water but
-- too far away" can be told apart from "that isn't water at all". The
-- volcano's lake is ~35 studs below the rim and a few hundred across.
local PROBE_LENGTH = 600

-- How far above and below a claimed point the straight-down surface probe
-- spans.
local SURFACE_PROBE_HEIGHT = 10

-- Messages shown to the player. Same strings on both sides so a server
-- rejection reads exactly like the client's own pre-check would have.
CastAim.REASON_NOT_WATER = "Aim at the water."
CastAim.REASON_TOO_FAR = "Get closer to the water."

local function worldParams(): RaycastParams?
	local folder = Workspace:FindFirstChild(World.FOLDER_NAME)
	if not folder then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { folder }
	return params
end

-- Is this part something a bobber can land on?
function CastAim.isFishable(instance: Instance?): boolean
	return instance ~= nil and World.FISHABLE_NAMES[instance.Name] == true
end

-- Parts the aim ray passes through instead of stopping on: the dock under
-- your feet and the world's invisible barriers.
function CastAim.isPassThrough(name: string): boolean
	return World.CAST_PASS_THROUGH_NAMES[name] == true or string.find(name, "Dock", 1, true) ~= nil
end

-- For the "what stopped the ray?" line below, so it prints at most every few
-- seconds rather than on every frame of a failed aim.
local lastBlocker: string? = nil
local lastBlockedAt = 0

-- The height a bobber floats at on a fishable hit: the ocean is always the
-- waterline (its part is a thick slab whose top may be tide-animated); lava
-- is wherever the ray met it.
local function surfaceYOf(hit: RaycastResult): number
	if hit.Instance.Name == World.OCEAN_NAME then
		return World.WATER_Y
	end
	return hit.Position.Y
end

-- How far a given rod can cast from `from`: the base reach times the rod's
-- `castRange` perk (the Abyssal Rod's Deep Line) times the island's own
-- multiplier (the volcano's rim is a cliff over a wide lake, so casts
-- there reach a few times further - Islands.castRangeMult). Both sides call
-- this with the same rod and position, so the client's aim gate and the
-- server's validation agree.
function CastAim.rangeFor(rodData, from: Vector3?): number
	local perk = rodData and rodData.perk
	local island = if from then Islands.castRangeMultAt(from) else 1
	return Tuning.Cast.MAX_DISTANCE * ((perk and perk.castRange) or 1) * island
end

-- Whether `point` is within casting reach of `from` (the character). `slack`
-- is the server's allowance for the client having measured from a slightly
-- different place; `rodData` extends the reach for a long-cast rod.
function CastAim.withinRange(from: Vector3, point: Vector3, slack: number?, rodData): boolean
	return (point - from).Magnitude <= CastAim.rangeFor(rodData, from) + (slack or 0)
end

-- True when a straight-down probe about `point` lands on a fishable surface
-- rather than on the island, the dock, or nothing at all. Also returns that
-- surface's height, so the server can snap a claimed point onto it rather
-- than trust the client's Y, and which WATER it is ("ocean" / "volcano") so
-- the roll can be filtered to the creatures that live there.
function CastAim.isWater(point: Vector3): (boolean, number?, string?)
	local params = worldParams()
	if not params then
		return false, nil, nil
	end
	local origin = Vector3.new(point.X, point.Y + SURFACE_PROBE_HEIGHT, point.Z)
	local hit = Workspace:Raycast(origin, Vector3.new(0, -SURFACE_PROBE_HEIGHT * 2, 0), params)
	if hit and CastAim.isFishable(hit.Instance) then
		return true, surfaceYOf(hit), World.WATERS_BY_PART[hit.Instance.Name] or World.WATERS_OCEAN
	end
	return false, nil, nil
end

-- Aims a cast: a ray from `rayOrigin` (the camera) along `look` has to reach
-- a fishable surface within casting reach of `from` (the character). Returns
-- the landing point on that surface, or nil and the reason to show the player.
function CastAim.aim(from: Vector3, rayOrigin: Vector3, look: Vector3, rodData): (Vector3?, string?)
	local params = worldParams()
	if not params or look.Magnitude < 0.001 then
		return nil, CastAim.REASON_NOT_WATER
	end

	-- Things the aim ray must pass THROUGH rather than stop on:
	--   * the dock you're standing on - on the volcano's pier the lava is ~33
	--     studs below the deck, so a ray at nearby lava crosses the planks and
	--     posts (on the tropical dock the water is 2 studs down and the ray
	--     clears the edge);
	--   * the world's invisible barriers - you must be able to fish from
	--     behind one (user, 2026-08-23: "fishing through barriers is
	--     impossible"). They are built CanQuery = false, which alone should
	--     keep them out of every raycast; they are named here as well so that
	--     stays true even if a barrier is ever made query-able.
	-- A ray that starts inside a part doesn't report it, so each hop restarts
	-- just past what it hit.
	local direction = look.Unit
	local origin = rayOrigin
	local remaining = PROBE_LENGTH
	local hit = nil
	for _ = 1, 8 do
		hit = Workspace:Raycast(origin, direction * remaining, params)
		if not hit or not CastAim.isPassThrough(hit.Instance.Name) then
			break
		end
		local travelled = (hit.Position - origin).Magnitude + 0.5
		origin = hit.Position + direction * 0.5
		remaining -= travelled
		if remaining <= 0 then
			hit = nil
			break
		end
	end
	if not hit or not CastAim.isFishable(hit.Instance) then
		-- Name what actually stopped the ray, throttled: three rounds of this
		-- bug were spent guessing at it from screenshots.
		local blocker = if hit then hit.Instance.Name else "nothing (no surface in range)"
		local now = os.clock()
		if blocker ~= lastBlocker or now - lastBlockedAt > 3 then
			lastBlocker, lastBlockedAt = blocker, now
			print(string.format("[CastAim] cast refused - the aim ray stopped on: %s", blocker))
		end
		return nil, CastAim.REASON_NOT_WATER
	end

	local landing = Vector3.new(hit.Position.X, surfaceYOf(hit), hit.Position.Z)
	if not CastAim.withinRange(from, landing, nil, rodData) then
		return nil, CastAim.REASON_TOO_FAR
	end
	return landing
end

return CastAim

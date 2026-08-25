--!nonstrict
-- Hazards.luau
-- The two server-side "something dangerous happened HERE" primitives, pulled
-- out of CreatureService (docs/revamp-plan.md Systems §4) so raids and island
-- events can hurt players and talk to the client without dragging the whole
-- creature engine in:
--
--   fireEvent(kind, position, extra)  - one line onto the CreatureEvent
--       remote, the generic client-moment channel CreatureEventController
--       renders (globs, rings, telegraphs, explosions...).
--   damagePlayersInRadius(...)        - the telegraphed-AoE damage rule:
--       full damage at the centre falling linearly to edgeFraction at the
--       rim, a height gate so a blast on the beach can't hurt someone on
--       the clifftop, and the player's i-frame bypassed (a stray contact
--       tick a moment earlier must not swallow a whole explosion).
--
-- CreatureService delegates its own copies here, so the semantics stay
-- identical for every existing spitter/bloater/burrower/boss - one rule,
-- three callers (CreatureService, RaidService, WorldEventService).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tuning = require(Shared.Config.Tuning)
local Remotes = require(Shared.Net.Remotes)

local PlayerService = require(script.Parent.Parent.Services.PlayerService)

local Hazards = {}

function Hazards.fireEvent(kind: string, position: Vector3, extra)
	Remotes.CreatureEvent:FireAllClients(kind, position, extra or {})
end

-- Hurts every living player within `radius` (horizontal) of `at`, the damage
-- falling off linearly from full at the centre to `edgeFraction` at the edge.
-- `heightTolerance` defaults to Tuning.Creature.AOE_HEIGHT_TOLERANCE; the
-- boss passes a bigger one because it sits at the waterline while players
-- stand on the arena deck a few studs up.
function Hazards.damagePlayersInRadius(
	at: Vector3,
	radius: number,
	minDmg: number,
	maxDmg: number,
	source,
	edgeFraction: number,
	heightTolerance: number?
)
	local tolerance = heightTolerance or Tuning.Creature.AOE_HEIGHT_TOLERANCE
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			local d = (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(at.X, 0, at.Z)).Magnitude
			if d <= radius and math.abs(root.Position.Y - at.Y) <= tolerance then
				local falloff = 1 - (1 - edgeFraction) * (d / radius)
				PlayerService.damage(
					player,
					math.floor(math.random(minDmg, maxDmg) * falloff + 0.5),
					source,
					{ bypassIframe = true }
				)
			end
		end
	end
end

return Hazards

--!nonstrict
-- Minigames (shared registry)
-- The catalogue of fishing minigames and the rarity-gated per-cast picker.
--
-- Which minigame a cast plays is chosen by the RARITY of the fish being caught
-- (user, 2026-08-22): commons/uncommons get the gentle reel, rares+ get a
-- harder game (mash or tap-targets). The rarity is rolled at cast time in
-- FishingService (before the minigame) precisely so this pick can depend on
-- it. Ties within a rarity's pool are broken from the cast seed, so the server
-- and every client agree without a handshake. The chosen kind rides the
-- existing CastAccepted `config` (config.kind); both FishingService and
-- FishingController dispatch through `get(kind)`.
--
-- Adding a minigame: a module here (shared half) + one in Client/Minigames
-- (client half) + a name in the relevant `byRarity` pools.
--
-- This is the SHARED/authority half (configFor / begin / onEvent / perf /
-- luckFor). The client view+input half lives in Client/Minigames.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rng = require(Shared.Modules.Rng)

local Minigames = {}

local modules = {
	reel = require(script.reel),
	burst = require(script.burst),
	snap = require(script.snap),
}

-- Which minigames each rarity may roll. Rarer fish fight harder. Every name
-- here must exist in `modules`.
Minigames.byRarity = {
	Common = { "reel" },
	Uncommon = { "reel" },
	Rare = { "burst", "snap" },
	Epic = { "burst", "snap" },
	Legendary = { "burst", "snap" },
}

-- Testing knob: set to a kind ("reel" / "burst" / "snap") to force every cast
-- to that minigame regardless of rarity; nil = normal rarity gating.
Minigames.FORCE = nil

-- Salt for breaking ties within a rarity's pool, distinct from the reel's
-- per-round salt so the pick never correlates with a round layout.
local KIND_SALT = 104729

-- The minigame this cast plays, for the caught fish's rarity.
function Minigames.pickForRarity(rarity: string, seed: number): string
	if Minigames.FORCE then
		return Minigames.FORCE
	end
	local pool = Minigames.byRarity[rarity] or { "reel" }
	if #pool == 1 then
		return pool[1]
	end
	local index = Rng.stream(Rng.derive(seed, KIND_SALT)):NextInteger(1, #pool)
	return pool[index]
end

function Minigames.get(kind: string)
	return modules[kind]
end

return Minigames

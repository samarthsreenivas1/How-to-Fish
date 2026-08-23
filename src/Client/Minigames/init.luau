--!nonstrict
-- Minigames (client registry)
-- Maps a cast's minigame kind (config.kind, chosen server-side from the seed -
-- see Shared/Modules/Minigames) to the client view+input module that plays it.
-- FishingController dispatches through `get(kind)` so it never hardcodes the
-- reel; adding a minigame is adding a module here.
--
-- Each client module implements: onAccepted(ctx) / update(ctx) /
-- onResult(ctx, round, kind) / endCast(ctx). See Client/Minigames/reel for the
-- ctx shape.

local Minigames = {}

local modules = {
	reel = require(script.reel),
	burst = require(script.burst),
	snap = require(script.snap),
}

function Minigames.get(kind: string)
	return modules[kind]
end

return Minigames

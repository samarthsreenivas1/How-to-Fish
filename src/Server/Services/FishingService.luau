--!nonstrict
-- FishingService.luau
-- The cast, and the reel minigame it opens into.
--
-- Anti-cheat without cost to feel: the server owns the seed, the client
-- simulates the bar locally from that seed (so clicks feel instant - see
-- FishingController), and the server independently replays the identical
-- layout from ReelMath to check what the client claims it hit. Click times
-- are bounded on both sides - the bar sweeps continuously, so a client free
-- to name any past time could always pick one landing on red.
--
-- Missing a click never fails the cast - a minigame played to the end always
-- lands its catch, just at a worse grade. What DOES forfeit a cast is
-- walking away from it (user decision, 2026-08-22, reversing the earlier
-- "a cast never fails" rule): putting the rod away or swapping rods, losing
-- the character, or sitting idle until the cast times out all CANCEL it -
-- no fish, no materials (cancelCast). Idle players earn nothing.
--
-- A cast has to land in open water within reach of the character. The client
-- aims along its camera and proposes the point; the server re-checks it with
-- the same shared rules (CastAim) and rejects rather than substituting its
-- own point, so the bobber only ever goes where the player was looking.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Equipment = require(Shared.Config.Equipment)
local Bait = require(Shared.Data.Bait)
local Creatures = require(Shared.Data.Creatures)
local Rods = require(Shared.Data.Rods)
local CastAim = require(Shared.Modules.CastAim)
local Minigames = require(Shared.Modules.Minigames)
local Grades = require(Shared.Modules.Grades)
local Remotes = require(Shared.Net.Remotes)
local Tuning = require(Shared.Config.Tuning)
local World = require(Shared.Config.World)

local BaitService = require(script.Parent.BaitService)
local BossService = require(script.Parent.BossService)
local CreatureService = require(script.Parent.CreatureService)
local InventoryService = require(script.Parent.InventoryService)
local MaterialService = require(script.Parent.MaterialService)
local ProgressionService = require(script.Parent.ProgressionService)

local FishingService = {}

local R = Tuning.Reel
local TB = Tuning.Bait

-- Active cast per player: { id, seed, config, round, score, misses, startedAt, landing, rodData }
local casts: { [Player]: any } = {}
local nextCastId = 0

-- Rarity tiers in the order a roll walks them. Only tiers that have at
-- least one creature row take part, so adding a "Rare" weight to Tuning
-- before any Rare creature exists doesn't produce empty rolls.
local RARITY_ORDER = { "Common", "Uncommon", "Rare", "Epic", "Legendary" }

-- How much a rod's `callsArchetype` perk weights its own quarry inside a tier.
local CALLED_ARCHETYPE_WEIGHT = 4

-- Chum Line: consecutive completed casts per player. Grows on every resolve,
-- wiped by a cancel (rod swap / timeout / lost character), so the streak
-- rewards seeing casts through. Read as bonus luck in onRequestCast.
local castStreak: { [Player]: number } = {}

-- The per-cast minigame layout (which minigame + its parameters) is built by
-- the chosen minigame module's configFor and carried in CastAccepted's config;
-- see onRequestCast and Shared/Modules/Minigames.

-- ============================================================ Landing point

-- Where the bobber (and so the catch) lands. The client knows where its
-- camera was pointing, so it proposes a point; the server checks it with the
-- same rules the client aimed by - open water, within reach of the character
-- - and rejects with a reason if it fails. No substitute point: a creature
-- surfacing somewhere the player wasn't looking would feel like a bug. The
-- accepted point is echoed back so both sides agree exactly.
local function validateLanding(character: Model, claimed, rodData): (Vector3?, string?, string?)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or typeof(claimed) ~= "Vector3" or claimed ~= claimed then
		return nil, CastAim.REASON_NOT_WATER
	end

	-- The claim carries the surface's Y (the ocean's waterline, or the lava
	-- lake's height up in the volcano); the probe re-finds that surface near
	-- the claimed point and the landing is snapped onto it, so the client's
	-- Y is only a hint, never trusted.
	-- The probe also says WHICH water it is, which decides the creature pool
	-- (ocean rows in the sea, volcano rows in the lava). Taken from the server's
	-- own probe, never from the claim, for the same reason the height is.
	local fishable, surfaceY, waters = CastAim.isWater(claimed)
	if not fishable then
		return nil, CastAim.REASON_NOT_WATER
	end
	local landing = Vector3.new(claimed.X, surfaceY or World.WATER_Y, claimed.Z)
	if not CastAim.withinRange((root :: BasePart).Position, landing, Tuning.Cast.CLAIM_SLACK, rodData) then
		return nil, CastAim.REASON_TOO_FAR
	end
	return landing, nil, waters or World.WATERS_OCEAN
end

-- ============================================================ Rarity roll

-- The index of a rarity in RARITY_ORDER (1 = Common), or 1 if unknown.
local function rarityIndex(rarity: string?): number
	if rarity then
		for i, name in RARITY_ORDER do
			if name == rarity then
				return i
			end
		end
	end
	return 1
end

-- Picks a creature row for a finished cast. Luck from the reel score and the
-- rod's luck stat multiplies every tier above Common, so good reeling on a
-- good rod shifts the distribution upward without making Common impossible.
--
-- A rod `perk.minRarity` floors the roll: tiers below it are dropped entirely
-- (the Abyssal Rod's "Abyssal Pull" never lands a Common). If the floor
-- leaves nothing rollable, it falls back to the full table so a cast still
-- lands something.
-- The rows in `bucket` this rod is actually allowed to hook. An archetype in
-- Rods.LOCKED_ARCHETYPES is invisible to every rod except one whose perk
-- `callsArchetype` names it - that's what puts the drowned behind the
-- Bonecaster rather than behind luck.
-- The passive catch. Everything else fights back, which is what a "danger"
-- bait asks for and what drops the advanced crafting mats.
local PASSIVE_ARCHETYPE = "flopper"

-- Which water a row belongs to. A row without `waters` is an ocean row, so
-- every creature written before the volcano existed keeps working untouched.
local function watersOf(row): string
	return row.waters or World.WATERS_OCEAN
end

local function allowedRows(bucket, perk, effect, waters: string?)
	local calls = perk and perk.callsArchetype
	local hostileOnly = effect and effect.hostileOnly
	local rows = {}
	for _, row in bucket do
		local locked = Rods.LOCKED_ARCHETYPES[row.archetype] and row.archetype ~= calls
		local wrongKind = hostileOnly and row.archetype == PASSIVE_ARCHETYPE
		-- The pool is per-water: a cast into the lava can only pull up things
		-- that live in lava, and vice versa. Without this every volcano row
		-- would also roll on the ocean island and every fish in the crater.
		local wrongWater = waters ~= nil and watersOf(row) ~= waters
		if not locked and not wrongKind and not wrongWater then
			table.insert(rows, row)
		end
	end
	return rows
end

local function rollCreature(rodData, effect, bonusLuck: number?, waters: string?)
	-- Rarity is rolled at cast time now, before any minigame result exists (so
	-- the minigame can be chosen by it - see onRequestCast). Luck is the rod's
	-- stat times the selected bait's luck multiplier times any streak bonus
	-- (Chum Line); the minigame still decides the grade, not the rarity.
	local luck = rodData.stats.luck * ((effect and effect.luck) or 1) * (1 + (bonusLuck or 0))

	local perk = rodData.perk
	local floor = if perk and perk.minRarity then rarityIndex(perk.minRarity) else 1

	local function buildWeights(fromIndex: number)
		local weights = {}
		local total = 0
		for i = fromIndex, #RARITY_ORDER do
			local rarity = RARITY_ORDER[i]
			local base = Tuning.Rarity.WEIGHTS[rarity]
			local bucket = Creatures.byRarity[rarity]
			-- A tier with nothing this rod + bait can actually hook must not
			-- roll (locked to another rod, or all-passive under danger bait).
			if base and bucket and #allowedRows(bucket, perk, effect, waters) > 0 then
				local weight = if rarity == "Common" then base else base * luck
				table.insert(weights, { rarity = rarity, weight = weight })
				total += weight
			end
		end
		return weights, total
	end

	local weights, total = buildWeights(floor)
	if total <= 0 and floor > 1 then
		-- The floor excluded everything catchable; ignore it this cast.
		weights, total = buildWeights(1)
	end
	if total <= 0 then
		return nil
	end

	local pick = math.random() * total
	local chosen = weights[#weights].rarity
	for _, entry in weights do
		pick -= entry.weight
		if pick <= 0 then
			chosen = entry.rarity
			break
		end
	end

	-- Uniform within the tier, except that a rod which CALLS an archetype
	-- weights its own quarry up, so the Bonecaster mostly pulls drowned.
	local bucket = allowedRows(Creatures.byRarity[chosen], perk, effect, waters)
	if #bucket == 0 then
		return nil
	end

	local calls = perk and perk.callsArchetype
	local function weightOf(row): number
		local w = 1
		if calls and row.archetype == calls then
			w *= CALLED_ARCHETYPE_WEIGHT
		end
		return w
	end

	local total = 0
	for _, row in bucket do
		total += weightOf(row)
	end
	local pick = math.random() * total
	for _, row in bucket do
		pick -= weightOf(row)
		if pick <= 0 then
			return row
		end
	end
	return bucket[#bucket]
end

-- ============================================================ Bait spawns

-- One spare fish for Chum's shoal: a passive Common, so the "extra" is a second
-- thing flopping on the sand and never a surprise second fight. Nil if the
-- Common tier somehow has no passive row.
local function shoalRow(waters: string?)
	local bucket = Creatures.byRarity.Common
	if not bucket then
		return nil
	end
	local rows = {}
	for _, row in bucket do
		-- Same water rule as the main roll: chumming the lava brings up more
		-- lava fish, not a perch.
		if row.archetype == PASSIVE_ARCHETYPE and (waters == nil or watersOf(row) == waters) then
			table.insert(rows, row)
		end
	end
	if #rows == 0 then
		return nil
	end
	return rows[math.random(1, #rows)]
end

-- Bloodbait: the kill draws the next one to the same spot. Each link is rolled
-- with more luck than the last (Tuning.Bait.CHAIN_LUCK_STEP), so the chain
-- escalates in what it produces rather than in a hidden payout multiplier -
-- link three being a rarer creature IS the reward, and it's the part you see.
--
-- Driven off the Killed event rather than tracked per-cast, because by the time
-- the chain matters the cast is long resolved: what carries the state forward
-- is the spawn `extra` bag, which CreatureService copies into Killed's info.
local function onCreatureKilled(_row, _grade: string, killer: Player?, info)
	if type(info) ~= "table" or not killer or killer.Parent ~= Players then
		return
	end
	local left = info.chain
	if type(left) ~= "number" or left <= 0 or typeof(info.position) ~= "Vector3" then
		return
	end

	local link = (if type(info.chainLink) == "number" then info.chainLink else 0) + 1
	local rodData = Rods.items[info.chainRod]
	if not rodData then
		return
	end

	-- Always another hostile, and always from the same water the first one came
	-- out of - a chain started in the crater must not summon sea creatures.
	local next_ = rollCreature(rodData, { hostileOnly = true }, TB.CHAIN_LUCK_STEP * link, info.chainWaters)
	if not next_ then
		return
	end

	local at = info.position
	task.delay(TB.CHAIN_DELAY, function()
		if killer.Parent ~= Players then
			return
		end
		local character = killer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		CreatureService.spawn(next_, at, if root then (root :: BasePart).Position else nil, "Neutral", {
			chain = left - 1,
			chainLink = link,
			chainRod = info.chainRod,
			chainWaters = info.chainWaters,
		})
	end)
end

-- ============================================================ Resolving a catch

-- A cast the player walked away from: torn down with NO catch and NO
-- materials. The client gets the same CastResolved moment (so its line, bar
-- and minigame view come down through the one path) flagged `cancelled`,
-- with `reason` = "abandoned" (rod away / swapped / character lost) or
-- "timeout" (idle until MAX_REEL_DURATION).
local function cancelCast(player: Player, cast, reason: string)
	casts[player] = nil
	castStreak[player] = nil -- walking away breaks a Chum Line streak
	Remotes.CastResolved:FireClient(player, cast.id, { cancelled = true, reason = reason })
end

-- A cast whose minigame was played to the end: lands the catch at the grade
-- the minigame earned, plus the basic materials.
local function resolveCast(player: Player, cast, reason: string?)
	casts[player] = nil
	castStreak[player] = (castStreak[player] or 0) + 1 -- Chum Line: a cast seen through

	-- Every minigame reduces to a normalised perf in [0,1]; the grade path is
	-- shared. (The reel's perf = score/maxScore reproduces its old grade exactly.)
	local grade = Grades.gradeFor(Minigames.get(cast.config.kind).perf(cast))
	local effect = cast.baitEffect

	-- Frenzy Bait: the catch arrives Enraged whatever the minigame said - more
	-- health, faster, hitting harder (Tuning.Grade). The grade is OVERRIDDEN
	-- rather than multiplied, because it is a named tier, not a number.
	if effect and effect.enrage then
		grade = "Enraged"
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local target = if root then (root :: BasePart).Position else nil

	-- Gravelure: a cast that brings up no fish at all, paying a haul of
	-- materials and coins straight out of the water. It still had to be played
	-- to the end, so the grade still scales it.
	if cast.salvage then
		local gradeTuning = Tuning.Grade[grade] or Tuning.Grade.Neutral
		local mult = (gradeTuning.rewardMult or 1) * ((effect and effect.rewardMult) or 1)
		local coins = math.floor(math.random(TB.SALVAGE_COINS[1], TB.SALVAGE_COINS[2]) * mult + 0.5)
		ProgressionService.addCoins(player, coins)
		MaterialService.grantSalvage(player, mult)

		Remotes.CastResolved:FireClient(player, cast.id, {
			grade = grade,
			reason = reason,
			salvage = true,
			coins = coins,
		})
		return
	end

	-- The catch surfaces at the bobber and is thrown at the player, landing
	-- at their feet. The creature was rolled at cast time (to pick the
	-- minigame); the minigame only sets the grade.
	local creature = cast.creature
	if creature then
		-- Bait effects that follow the catch out of the water rather than
		-- changing the roll. All of them ride the spawn `extra` bag, which
		-- CreatureService copies into the Killed event, so the ones that only
		-- matter on death (bounty, chain) survive the fight without anything
		-- having to remember this cast. Nil bait spawns exactly as before.
		local extra = nil
		local function bag()
			extra = extra or {}
			return extra
		end
		if effect then
			if effect.stun then
				bag().stun = effect.stun
			end
			if effect.guaranteedDrop then
				bag().guaranteedDrop = true
			end
			if effect.enrage then
				bag().bounty = TB.ENRAGE_BOUNTY
			end
			if effect.chain and effect.chain > 0 then
				bag().chain = effect.chain
				bag().chainLink = 0
				bag().chainRod = cast.rodData.id
				bag().chainWaters = cast.waters
			end
		end

		CreatureService.spawn(creature, cast.landing, target, grade, extra)

		-- Chum's shoal: spare fish thrown up from a ring around the bobber, so
		-- their arcs spread out instead of stacking into one pile.
		local shoal = effect and effect.shoal
		if shoal and shoal > 0 then
			for i = 1, shoal do
				local row = shoalRow(cast.waters)
				if row then
					local angle = (i / shoal) * math.pi * 2 + math.random() * 0.6
					local at = cast.landing
						+ Vector3.new(math.cos(angle) * TB.SHOAL_SPREAD, 0, math.sin(angle) * TB.SHOAL_SPREAD)
					CreatureService.spawn(row, at, target, TB.SHOAL_GRADE)
				end
			end
		end
	end

	-- Split Roe: the hatchling comes up with the catch and fights alongside the
	-- player until its clock runs out. Spawned even on a cast that landed no
	-- creature, so a bad roll never costs an Epic bait its whole effect.
	local hatchling = effect and effect.hatchling
	if hatchling and hatchling > 0 then
		local row = Creatures.items.hatchling
		if row then
			CreatureService.spawn(row, cast.landing, target, "Neutral", {
				friendly = true,
				owner = player,
				lifetime = hatchling,
			})
		end
	end

	-- Basic crafting mats come up with every catch (the rare ones drop when
	-- the creature is killed - see MaterialService).
	MaterialService.grantCast(player, cast)

	Remotes.CastResolved:FireClient(player, cast.id, {
		grade = grade,
		reason = reason,
		creature = if creature then { id = creature.id, name = creature.name, rarity = creature.rarity } else nil,
	})
end

-- ============================================================ Cast lifecycle

local function onRequestCast(player: Player, claimedLanding)
	if casts[player] then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	if InventoryService.getEquipped(player) ~= Equipment.ROD then
		Remotes.CastRejected:FireClient(player, "Equip your rod to cast.")
		return
	end

	local rodId = InventoryService.getEquippedRod(player)
	local rodData = rodId and Rods.items[rodId]
	if not rodData or not rodData.reel then
		Remotes.CastRejected:FireClient(player, "You need a rod to cast.")
		return
	end

	-- A rod's `castRange` perk (Abyssal's Deep Line) lets it reach water the
	-- others can't. The client gates its own aim by the same number, so this
	-- validates the claim against the rod actually in hand rather than a
	-- fixed distance.
	local landing, reason, waters = validateLanding(character, claimedLanding, rodData)
	if not landing then
		Remotes.CastRejected:FireClient(player, reason)
		return
	end

	-- The capstone bait doesn't fish - it CALLS the island's boss (Leviathan's
	-- Call). Handled here, ahead of the ordinary spend below, because the gate
	-- has to be checked BEFORE the bait is consumed: it costs a signature drop
	-- from every creature in the game, so a refused summon must cost nothing.
	-- The count is checked first too, so the boss can never rise off a bait the
	-- spend then fails to take.
	--
	-- No cast is opened: there's no catch, so there's no minigame to play. The
	-- client is resolved immediately with a `summoned` summary, which clears the
	-- swing it already started and announces the boss instead of a fish.
	local selectedId = BaitService.getSelected(player)
	local selected = selectedId and Bait.items[selectedId]
	local summons = selected and selected.effect and selected.effect.summonsBoss
	if summons then
		if BaitService.getCount(player, selectedId) < 1 then
			Remotes.CastRejected:FireClient(player, "You have none of that bait.")
			return
		end
		local ok, why = BossService.summonFor(player, summons)
		if not ok then
			Remotes.CastRejected:FireClient(player, why or "Nothing answers the call.")
			return
		end
		BaitService.spend(player, { [selectedId] = 1 })
		nextCastId += 1
		Remotes.CastResolved:FireClient(player, nextCastId, { summoned = summons })
		return
	end

	-- Resolve + SPEND the selected bait now (one per cast). Doing it here - past
	-- every rejection path above but before the roll - means a rejected cast
	-- never eats bait, while a committed one can't be reroll-farmed by cancelling
	-- once the minigame reveals the rarity (the bait is already gone). An unowned
	-- / stale / empty selection simply casts baitless. The effect then feeds the
	-- roll, the minigame config, and the resolve payout.
	local baitEffect = nil
	local baitId = BaitService.getSelected(player)
	if baitId and Bait.items[baitId] and BaitService.spend(player, { [baitId] = 1 }) then
		baitEffect = Bait.items[baitId].effect
	end

	nextCastId += 1

	-- Roll which minigame this cast plays from the seed (so client and server
	-- agree without a handshake), build its per-rod config, and stamp the kind
	-- onto the config that rides CastAccepted.
	local seed = math.random(1, 2 ^ 31 - 1)

	-- Roll the catch NOW (before the minigame) so the minigame can be chosen by
	-- its rarity: commons/uncommons get the reel, rares+ get a harder game
	-- (Minigames.byRarity). The perk minRarity floor is applied inside
	-- rollCreature, so a floored rod's rarity - and thus its minigame - is
	-- correct too.
	-- Chum Line: bonus luck from the streak of casts seen through, capped by
	-- the perk so it can't run away.
	local streakBonus = 0
	local rodPerk = rodData.perk
	if rodPerk and rodPerk.streakLuck then
		local streak = castStreak[player] or 0
		streakBonus = math.min(streak * rodPerk.streakLuck, rodPerk.streakMax or math.huge)
	end

	-- Gravelure salvages instead of fishing: there is no catch to roll, so the
	-- minigame falls to the Common tier (the reel). The cast is still played
	-- and still graded - the grade scales the haul.
	local salvage = baitEffect and baitEffect.salvage
	local creature = if salvage then nil else rollCreature(rodData, baitEffect, streakBonus, waters)
	local rarity = if creature then creature.rarity else "Common"
	local kind = Minigames.pickForRarity(rarity, seed)
	local mod = Minigames.get(kind)
	local config = mod.configFor(rodData)
	config.kind = kind

	local cast = {
		salvage = salvage,
		waters = waters, -- which pool this cast drew from; the shoal and chain reuse it
		id = nextCastId,
		seed = seed,
		config = config,
		startedAt = os.clock(),
		landing = landing,
		rodData = rodData,
		creature = creature, -- pre-rolled; spawned at resolve
		baitEffect = baitEffect, -- spent already; kept for the resolve reward multiplier
	}
	cast.mg = mod.begin(cast) or {} -- per-cast authoritative scoring state
	casts[player] = cast

	Remotes.CastAccepted:FireClient(player, cast.id, cast.seed, cast.config, cast.landing)
end

-- A timed input event from the client (a reel click, a burst tap, a snap
-- button press). The generic guards live here; the per-minigame scoring is
-- the module's onEvent, which also owns event ordering. `extra` is an optional
-- trailing arg (e.g. the snap button index) - the RemoteEvent carries it with
-- no Remotes.luau change.
local function onSubmit(player: Player, castId, round, barTime, extra)
	local cast = casts[player]
	if not cast or cast.id ~= castId then
		return
	end
	if type(round) ~= "number" or type(barTime) ~= "number" then
		return
	end

	-- The client reports the time it acted at; the server recomputes from it,
	-- bounded on both sides: too far in the future is impossible, and too far
	-- in the past means the packet didn't follow the input promptly. A
	-- one-sided check would be nearly useless - free to name any past time, a
	-- cheating client could always pick one that scores. Shared by every
	-- minigame; the per-minigame math never sees an unbounded time.
	local elapsed = os.clock() - cast.startedAt
	if barTime ~= barTime or barTime < 0 or math.abs(elapsed - barTime) > R.CLICK_TIME_TOLERANCE then
		barTime = elapsed
	end

	local echo, done = Minigames.get(cast.config.kind).onEvent(cast, round, barTime, extra)
	if echo then
		Remotes.ReelRoundResult:FireClient(player, cast.id, round, echo.kind, echo.score)
	end
	if done then
		resolveCast(player, cast)
	end
end

local function onAbandonCast(player: Player, castId)
	local cast = casts[player]
	if cast and cast.id == castId then
		-- Walking away forfeits the cast: nothing lands, nothing is granted.
		cancelCast(player, cast, "abandoned")
	end
end

-- ============================================================ Lifecycle

function FishingService.init()
	Remotes.RequestCast.OnServerEvent:Connect(onRequestCast)
	Remotes.SubmitReelClick.OnServerEvent:Connect(onSubmit)
	Remotes.AbandonCast.OnServerEvent:Connect(onAbandonCast)
	-- Bloodbait's chain lives past the cast that started it; the Killed event
	-- is what carries it forward.
	CreatureService.Killed.Event:Connect(onCreatureKilled)

	Players.PlayerRemoving:Connect(function(player)
		casts[player] = nil
	end)

	-- Any loadout change mid-cast CANCELS the cast: putting the rod away, or
	-- swapping to a different rod (the reel config is per-rod, so the old
	-- cast can't keep playing under a new rod). No fish, no materials - you
	-- can't bank a catch by switching to your weapon early.
	InventoryService.onEquipChanged(function(player: Player, _kind: string)
		local cast = casts[player]
		if cast then
			cancelCast(player, cast, "abandoned")
		end
	end)
end

function FishingService.start()
	-- Sweep idle casts. A player who stops playing the minigame gets nothing
	-- - the cast is cancelled, not resolved - so AFK casting can't farm; and
	-- a cast left open forever would block them from ever casting again.
	task.spawn(function()
		while true do
			task.wait(1)
			local now = os.clock()
			for player, cast in casts do
				if now - cast.startedAt > R.MAX_REEL_DURATION then
					cancelCast(player, cast, "timeout")
				end
			end
		end
	end)
end

return FishingService

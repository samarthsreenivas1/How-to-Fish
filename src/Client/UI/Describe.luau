--!nonstrict
-- Describe.luau
-- Turns content rows into what the menus SHOW: pips instead of multipliers,
-- one coloured token + one plain line per effect, an ability card for a
-- rod's or weapon's power-up. The rule from the 2026-08-23 UI overhaul is
-- "less text and numbers, and it must be clear what each power-up does" -
-- so numbers only appear where a player genuinely needs them (a recipe's
-- have/need, a stun's seconds).
--
-- Two sources of truth, kept honest:
--   - Rod / weapon perks carry their own `name` + `description` (written by
--     the gear slice); those are shown verbatim. This file only picks the
--     token and colour from the perk's keys.
--   - Bait effects are structural flags; every one described here is read
--     by FishingService / MaterialService / CreatureService (luck,
--     rewardMult, stun, hostileOnly, guaranteedDrop, summonsBoss, and the
--     bait rebuild's shoal / chain / salvage / enrage / hatchling - 2f,
--     2026-08-23). A flag the game doesn't act on must not get a chip.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bosses = require(Shared.Data.Bosses)

local Theme = require(script.Parent.Theme)

local Describe = {}

local C = Theme.Color

-- Effect colours, shared by chips and ability tiles so the same idea is
-- always the same colour.
Describe.Color = {
	luck = C.gold,
	reward = C.gold,
	range = C.accent,
	rarity = C.violet,
	call = Color3.fromRGB(120, 255, 214),
	forgive = C.green,
	damage = C.red,
	poison = Color3.fromRGB(150, 230, 110),
	blast = C.ember,
	knock = C.sand,
	stun = Color3.fromRGB(190, 210, 255),
	boss = Color3.fromRGB(255, 90, 70),
	drop = C.green,
	leech = Color3.fromRGB(240, 110, 150),
}

-- Creature archetype -> the plain name of what a rod "calls".
local ARCHETYPE_NAMES = {
	shambler = "the drowned",
	rusher = "the crabs",
	charger = "skippers",
	spitter = "gullet cod",
	bloater = "urchins",
	drifter = "jellies",
	burrower = "lurkers",
	mimic = "mimics",
	thief = "hermits",
	pulser = "voltrays",
}

-- ============================================================ perks

-- The token + colour for a rod / weapon perk, from its keys. The first key
-- that matches wins, so a multi-effect perk (Abyssal Pull: range + rarity
-- floor) gets one strong identity; the description carries the rest.
local PERK_TOKENS = {
	{ key = "lifesteal", token = "LEECH", color = Describe.Color.leech },
	{ key = "execute", token = "FINISH", color = Describe.Color.damage },
	{ key = "cleave", token = "BLAST", color = Describe.Color.blast },
	{ key = "poison", token = "ROT", color = Describe.Color.poison },
	{ key = "uproot", token = "HURL", color = Describe.Color.knock },
	{ key = "frenzy", token = "CHAIN", color = Describe.Color.damage },
	{ key = "callsArchetype", token = "CALL", color = Describe.Color.call },
	{ key = "castRange", token = "FAR", color = Describe.Color.range },
	{ key = "minRarity", token = "RARE+", color = Describe.Color.rarity },
	{ key = "noShrink", token = "HOLD", color = Describe.Color.forgive },
	{ key = "freeMisses", token = "SLIP", color = Describe.Color.forgive },
	{ key = "streakLuck", token = "CHUM", color = Describe.Color.luck },
	-- Hermit-saga rods (2026-08-29): the same two effects the baits already
	-- have chips for, so the card language matches wherever it comes from.
	{ key = "stun", token = "DAZE", color = Describe.Color.stun },
	{ key = "guaranteedDrop", token = "DROP", color = Describe.Color.drop },
}

-- What an ability card shows for a perk: { token, color, name, text }.
function Describe.perk(perk)
	if not perk then
		return nil
	end
	local token, color = "POWER", C.accent
	for _, entry in PERK_TOKENS do
		if perk[entry.key] ~= nil then
			token, color = entry.token, entry.color
			break
		end
	end
	return {
		token = token,
		color = color,
		name = perk.name or "Ability",
		text = perk.description or "",
	}
end

-- The short facts worth a chip under the ability card: the bits a player
-- compares between items. Kept to essentials.
function Describe.perkFacts(perk): { { token: string, text: string, color: Color3 } }
	local facts = {}
	if not perk then
		return facts
	end
	if perk.castRange then
		table.insert(facts, {
			token = "FAR",
			color = Describe.Color.range,
			text = string.format("Casts %.1fx further", perk.castRange),
		})
	end
	if perk.minRarity then
		table.insert(facts, {
			token = "RARE+",
			color = Describe.Color.rarity,
			text = string.format("Never hooks below %s", perk.minRarity),
		})
	end
	if perk.callsArchetype then
		table.insert(facts, {
			token = "CALL",
			color = Describe.Color.call,
			text = "The only rod that hooks " .. (ARCHETYPE_NAMES[perk.callsArchetype] or perk.callsArchetype),
		})
	end
	if perk.freeMisses then
		table.insert(facts, {
			token = "SLIP",
			color = Describe.Color.forgive,
			text = if perk.freeMisses == 1
				then "First miss each cast is free"
				else string.format("%d misses per cast are free", perk.freeMisses),
		})
	end
	if perk.noShrink then
		table.insert(facts, { token = "HOLD", color = Describe.Color.forgive, text = "Misses never shrink the target" })
	end
	if perk.streakLuck then
		table.insert(facts, {
			token = "CHUM",
			color = Describe.Color.luck,
			text = string.format(
				"Luck grows each cast in a row, up to +%d%%",
				math.floor((perk.streakMax or 0) * 100 + 0.5)
			),
		})
	end
	if perk.stun then
		table.insert(facts, {
			token = "DAZE",
			color = Describe.Color.stun,
			text = string.format("The catch lands stunned for %ds", perk.stun),
		})
	end
	if perk.guaranteedDrop then
		table.insert(
			facts,
			{ token = "DROP", color = Describe.Color.drop, text = "Every catch gives up its full materials" }
		)
	end
	if perk.frenzy then
		table.insert(facts, { token = "CHAIN", color = Describe.Color.damage, text = "Hits in a chain cut deeper" })
	end
	if perk.uproot then
		table.insert(facts, { token = "HURL", color = Describe.Color.knock, text = "Launches even braced creatures" })
	end
	if perk.poison then
		table.insert(facts, {
			token = "ROT",
			color = Describe.Color.poison,
			text = string.format("Wounds keep burning for %ds", perk.poison.duration or 0),
		})
	end
	if perk.cleave then
		table.insert(facts, { token = "BLAST", color = Describe.Color.blast, text = "Every creature in reach is hit" })
	end
	if perk.execute then
		table.insert(facts, { token = "FINISH", color = Describe.Color.damage, text = "Double damage to wounded prey" })
	end
	if perk.lifesteal then
		table.insert(facts, { token = "LEECH", color = Describe.Color.leech, text = "Damage dealt heals you" })
	end
	return facts
end

-- ============================================================ bait effects

-- One chip per WIRED effect (see the header). `effect` is Bait.items[id].effect.
function Describe.baitEffects(effect): { { token: string, text: string, color: Color3 } }
	local chips = {}
	if type(effect) ~= "table" then
		return chips
	end
	if effect.luck and effect.luck > 1 then
		local strength = if effect.luck >= 1.35 then "Much rarer catches" else "Rarer catches"
		table.insert(chips, { token = "LUCK", color = Describe.Color.luck, text = strength })
	end
	if effect.rewardMult and effect.rewardMult > 1 then
		local strength = if effect.rewardMult >= 1.4 then "Far more coins and XP" else "More coins and XP"
		table.insert(chips, { token = "$", color = Describe.Color.reward, text = strength })
	end
	if effect.stun then
		table.insert(chips, {
			token = "DAZE",
			color = Describe.Color.stun,
			text = string.format("The catch lands stunned for %ds", effect.stun),
		})
	end
	if effect.hostileOnly then
		table.insert(
			chips,
			{ token = "FANG", color = Describe.Color.damage, text = "Always hooks something that fights" }
		)
	end
	if effect.guaranteedDrop then
		table.insert(chips, { token = "DROP", color = Describe.Color.drop, text = "Its rare material is guaranteed" })
	end
	if effect.summonsBoss then
		local boss = Bosses.items[effect.summonsBoss]
		table.insert(chips, {
			token = "BOSS",
			color = Describe.Color.boss,
			text = "Summons " .. (boss and boss.shortName or "the boss") .. " when cast",
		})
		table.insert(chips, { token = "1x", color = Describe.Color.boss, text = "Used up on the summon" })
	end
	-- The bait rebuild's visible mechanics (2f, 2026-08-23).
	if effect.shoal then
		table.insert(chips, {
			token = "SHOAL",
			color = Describe.Color.range,
			text = if effect.shoal == 1
				then "An extra fish surfaces with the catch"
				else string.format("%d extra fish surface with the catch", effect.shoal),
		})
	end
	if effect.chain then
		table.insert(chips, {
			token = "CHAIN",
			color = Describe.Color.damage,
			text = string.format("Each kill calls another fighter - up to %d", effect.chain),
		})
	end
	if effect.salvage then
		table.insert(
			chips,
			{ token = "HAUL", color = Describe.Color.reward, text = "No fish: drags up materials and coins" }
		)
	end
	if effect.enrage then
		table.insert(
			chips,
			{ token = "RAGE", color = Describe.Color.boss, text = "The catch arrives enraged - and pays double" }
		)
	end
	if effect.hatchling then
		table.insert(chips, {
			token = "PET",
			color = Describe.Color.call,
			text = string.format("A hatchling fights beside you for %ds", effect.hatchling),
		})
	end
	return chips
end

-- ============================================================ stat pips

-- Rod stats as 0..1 pip values, scaled across the rods that exist
-- (luck 1.0-1.9, power 1.0-1.5, control 1.0-1.35).
function Describe.rodPips(rod): { { label: string, value: number, color: Color3 } }
	local stats = rod.stats or {}
	local function scale(v: number?, lo: number, hi: number): number
		return math.clamp(((v or lo) - lo) / (hi - lo), 0, 1) * 0.8 + 0.2
	end
	return {
		{ label = "Luck", value = scale(stats.luck, 1.0, 1.9), color = Describe.Color.luck },
		{ label = "Power", value = scale(stats.power, 1.0, 1.5), color = Describe.Color.damage },
		{ label = "Control", value = scale(stats.control, 1.0, 1.35), color = Describe.Color.range },
	}
end

-- Weapon stats as pips: damage per swing, speed, reach, knockback.
function Describe.weaponPips(weapon): { { label: string, value: number, color: Color3 } }
	local avg = ((weapon.damage and (weapon.damage[1] + weapon.damage[2]) / 2) or 10)
	local speed = 1 / math.max(weapon.cooldown or 0.5, 0.05)
	return {
		{ label = "Damage", value = math.clamp(avg / 50, 0.15, 1), color = Describe.Color.damage },
		{ label = "Speed", value = math.clamp(speed / 5, 0.15, 1), color = Describe.Color.range },
		{ label = "Reach", value = math.clamp((weapon.reach or 10) / 18, 0.15, 1), color = Describe.Color.forgive },
		{ label = "Knockback", value = math.clamp((weapon.knockback or 0) / 36, 0.1, 1), color = Describe.Color.knock },
	}
end

return Describe

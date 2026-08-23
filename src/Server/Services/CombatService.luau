--!nonstrict
-- CombatService.luau
-- The one way to hurt a catch: a melee swing with whatever weapon is in
-- hand - bare fists or a crafted weapon.
--
-- Deliberately small. It validates the attack (a weapon equipped, off that
-- weapon's cooldown, a creature within that weapon's reach), rolls the row's
-- damage, and routes the hit through CreatureService.damage, which already
-- owns health and replicates it as an attribute. Every number comes off the
-- equipped Weapons row (fists included - their row references
-- Tuning.Combat), so a new weapon is a data row, not a code path here. The
-- CreatureHit remote carries only the impact moment for the VFX; clients
-- see the damage itself as the Health attribute dropping.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Equipment = require(Shared.Config.Equipment)
local Tuning = require(Shared.Config.Tuning)
local Weapons = require(Shared.Data.Weapons)
local Remotes = require(Shared.Net.Remotes)

local CreatureService = require(script.Parent.CreatureService)
local InventoryService = require(script.Parent.InventoryService)
local PlayerService = require(script.Parent.PlayerService)

local CombatService = {}

-- Last swing time per player, for the server-side cooldown. The client also
-- gates input, but the server is the authority - a client firing the remote
-- in a loop still only lands a hit every `cooldown` of its weapon.
local lastAttackAt: { [Player]: number } = {}

-- Frenzy (Scaleblade): the unbroken chain of LANDED hits per player, and when
-- the last one landed. Missing entirely, or pausing longer than the window,
-- drops the chain - so the ramp rewards staying on a target rather than
-- swinging at nothing.
local frenzy: { [Player]: { hits: number, lastAt: number } } = {}

-- The frenzy damage multiplier for this swing, and the chain advanced.
local function frenzyMultiplier(player: Player, now: number): number
	local P = Tuning.Perks
	local chain = frenzy[player]
	if chain and now - chain.lastAt <= P.FRENZY_WINDOW then
		chain.hits += 1
	else
		chain = { hits = 0 }
		frenzy[player] = chain
	end
	chain.lastAt = now
	return 1 + math.min(chain.hits * P.FRENZY_STEP, P.FRENZY_MAX)
end

-- The Weapons row in the player's hands, or nil when the rod is out (the
-- rod isn't a weapon). An unknown equipped id falls back to the fists so a
-- stale attribute can never make a player unable to fight.
local function equippedWeapon(player: Player)
	if InventoryService.getEquipped(player) ~= Equipment.WEAPON then
		return nil
	end
	local weaponId = InventoryService.getEquippedWeapon(player)
	return (weaponId and Weapons.items[weaponId]) or Weapons.items[Weapons.STARTER_WEAPON_ID]
end

local function onRequestAttack(player: Player)
	local weapon = equippedWeapon(player)
	if not weapon then
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local now = os.clock()
	if now - (lastAttackAt[player] or 0) < weapon.cooldown then
		return
	end
	lastAttackAt[player] = now

	-- Nearest creature within reach takes the hit. inRange is nearest-first.
	local from = (root :: BasePart).Position
	local inReach = CreatureService.inRange(from, weapon.reach)
	local target = inReach[1]
	if not target then
		return
	end

	-- Where the punch connected: the point on the body's box nearest the
	-- player, for the impact VFX. Read before damage - a killing blow
	-- destroys the model.
	local body = target.model.PrimaryPart
	local hitPoint = target.model:GetPivot().Position
	if body then
		local localPoint = body.CFrame:PointToObjectSpace(from)
		local half = body.Size / 2
		hitPoint = body.CFrame:PointToWorldSpace(
			Vector3.new(
				math.clamp(localPoint.X, -half.X, half.X),
				math.clamp(localPoint.Y, -half.Y, half.Y),
				math.clamp(localPoint.Z, -half.Z, half.Z)
			)
		)
	end
	local direction = hitPoint - from
	direction = if direction.Magnitude > 0.01 then direction.Unit else Vector3.zAxis

	-- What this creature does with a hit right now: the charger's exposed
	-- back takes double; the Voltray mid-charge shocks the attacker back.
	-- `from` matters to the thornback: armoured at the front, soft behind.
	local damageMult, shock = CreatureService.hitModifiers(target, from)
	local perk = weapon.perk

	-- Frenzy ramps this swing off the unbroken chain of landed hits.
	if perk and perk.frenzy then
		damageMult *= frenzyMultiplier(player, now)
	end

	-- Overload: a wounded target takes far more. Read before the hit, off the
	-- creature's own health fraction, so it scales with anything.
	if perk and perk.execute and target.maxHealth > 0 then
		if target.health / target.maxHealth <= Tuning.Perks.EXECUTE_BELOW then
			damageMult *= Tuning.Perks.EXECUTE_MULT
		end
	end

	local amount = math.floor(math.random(weapon.damage[1], weapon.damage[2]) * damageMult + 0.5)
	local remaining = CreatureService.damage(target, amount, player)
	if shock > 0 then
		PlayerService.damage(player, shock, target)
	end

	-- Devour: heal off what the blow actually dealt.
	if perk and perk.lifesteal and remaining ~= nil then
		PlayerService.heal(player, amount * Tuning.Perks.LIFESTEAL)
	end

	-- Blast Radius: the same swing catches everything else in reach at a
	-- fraction of the damage. Splash targets get no knockback and no on-hit
	-- perk - only the creature you actually swung at - so a cleave can't
	-- juggle a crowd or stack poison on five things at once.
	if perk and perk.cleave then
		local splash = math.max(1, math.floor(amount * Tuning.Perks.CLEAVE_FALLOFF + 0.5))
		for i = 2, #inReach do
			CreatureService.damage(inReach[i], splash, player)
		end
	end

	-- Brine Rot: a stack of damage-over-time on top of the hit. Applied even
	-- if the blow killed it (the stack simply dies with it), so there's no
	-- ordering subtlety to get wrong.
	if perk and perk.poison then
		CreatureService.poison(target, perk.poison.damage, perk.poison.duration, player)
	end

	-- Shove it away from the blow AND pop it into the air, unless that blow
	-- just killed it. The lift is what makes juggling work: hit it again
	-- before it lands and it goes straight back up. A weapon row may carry its
	-- own `launch` to juggle harder or softer than the default.
	if remaining and remaining > 0 then
		local lift = weapon.launch or Tuning.Combat.LAUNCH_SPEED
		CreatureService.applyKnockback(
			target,
			target.model:GetPivot().Position - from,
			weapon.knockback,
			lift,
			perk ~= nil and perk.uproot == true -- Uproot ignores an archetype's ground pin
		)
	end

	Remotes.CreatureHit:FireAllClients(hitPoint, direction, not CreatureService.isAlive(target), player.UserId)
end

function CombatService.init()
	Remotes.RequestAttack.OnServerEvent:Connect(onRequestAttack)
	Players.PlayerRemoving:Connect(function(player)
		lastAttackAt[player] = nil
		frenzy[player] = nil
	end)
end

function CombatService.start() end

return CombatService

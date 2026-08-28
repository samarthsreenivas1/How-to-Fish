--!nonstrict
-- CombatService.luau
-- The one way to hurt a catch: a melee swing OR a ranged shot with whatever
-- weapon is in hand - bare fists, a crafted melee weapon, or (revamp Session
-- 2, docs/revamp-plan.md Systems §1) a row with a `ranged` block.
--
-- Melee validates the attack (a weapon equipped, off that weapon's cooldown,
-- a creature within that weapon's reach), rolls the row's damage, and routes
-- the hit through CreatureService.damage. Ranged is server-authoritative
-- hitscan with a cosmetic flight delay: the client proposes a camera ray
-- (the CastAim trust model), the server re-validates the origin (ShotAim),
-- resolves what the ray hit AT FIRE TIME (terrain via ShotAim, creatures via
-- CreatureService.raycastNearest), and applies the damage after
-- distance / projectileSpeed on a Heartbeat queue - the same "queue with a
-- landAt clock" shape as a boss's globs. Arc weapons (bows) re-check a small
-- sphere at the landing instead, so a dodged arrow misses; guns apply the
-- fire-time hit verbatim. Rate limiting is a per-player token bucket plus
-- the server-tracked magazine/reload, so a spamming client lands exactly
-- 1/cooldown shots a second.
--
-- Both paths land through the one landHit below - modifiers, perks, damage,
-- knockback, the CreatureHit moment - so every piece of impact feedback the
-- game has fires for a bullet exactly as it does for a punch. Cleave and
-- uproot stay melee-only; poison / execute / lifesteal / frenzy work ranged
-- (the frenzy chain is shared across both paths).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Equipment = require(Shared.Config.Equipment)
local Tuning = require(Shared.Config.Tuning)
local Trinkets = require(Shared.Data.Trinkets)
local Weapons = require(Shared.Data.Weapons)
local Remotes = require(Shared.Net.Remotes)
local ShotAim = require(Shared.Modules.ShotAim)

local CreatureService = require(script.Parent.CreatureService)
local InventoryService = require(script.Parent.InventoryService)
local PlayerService = require(script.Parent.PlayerService)

local CombatService = {}

local RT = Tuning.Ranged

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

-- Lands one resolved hit on `target` with `weapon`'s numbers - modifiers,
-- the shared perks, the damage, the shove, the CreatureHit moment - so a
-- bullet fires every piece of impact feedback a punch does. Shared by the
-- melee swing and the ranged shot queue. `from` is where the blow came from
-- (the player's root for melee, the shot's origin for ranged) - it matters
-- to the thornback's armoured front and sets the knockback direction.
-- `opts.ranged` skips the melee-only pieces: the juggle launch, and uproot
-- (cleave is handled by the melee caller, which has the in-reach list).
-- Returns the rolled amount, so the melee caller can size its cleave splash.
local function landHit(player: Player, weapon, target, from: Vector3, opts): number?
	-- A target that died OR went untargetable while the shot flew (a boss
	-- starting its dive, a lurker burying, a mimic snapping shut) blocks the
	-- whole hit - no damage, but also no poison stack, no frenzy advance and
	-- no impact moment. Being unhittable is the point of those phases.
	if not CreatureService.isAlive(target) or target.untargetable then
		return nil
	end
	local now = os.clock()
	local ranged = opts and opts.ranged

	-- Where the blow connected: the point on the body's box nearest `from`,
	-- for the impact VFX. Read before damage - a killing blow destroys the
	-- model.
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
	local damageMult, shock = CreatureService.hitModifiers(target, from)
	local perk = weapon.perk

	-- Frenzy ramps this hit off the unbroken chain of landed hits. One chain
	-- per player, shared across melee and ranged on purpose.
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

	-- The worn trinket's damageBonus (Trinkets.luau) - THE one consumer;
	-- landHit is shared by melee and ranged, so both benefit.
	damageMult *= 1 + (Trinkets.wornPerk(player, "damageBonus") or 0)
	local amount = math.floor(math.random(weapon.damage[1], weapon.damage[2]) * damageMult + 0.5)
	local remaining = CreatureService.damage(target, amount, player)
	if shock > 0 then
		PlayerService.damage(player, shock, target)
	end

	-- Devour: heal off what the blow actually dealt.
	if perk and perk.lifesteal and remaining ~= nil then
		PlayerService.heal(player, amount * Tuning.Perks.LIFESTEAL)
	end

	-- Brine Rot: a stack of damage-over-time on top of the hit. Applied even
	-- if the blow killed it (the stack simply dies with it), so there's no
	-- ordering subtlety to get wrong.
	if perk and perk.poison then
		CreatureService.poison(target, perk.poison.damage, perk.poison.duration, player)
	end

	-- Shove it away from the blow - and, melee only, pop it into the air (the
	-- juggle). A ranged row's knockback is a nudge (0-4) and never lifts:
	-- juggling something from across the water would trivialise it.
	if remaining and remaining > 0 then
		local lift = if ranged then 0 else (weapon.launch or Tuning.Combat.LAUNCH_SPEED)
		CreatureService.applyKnockback(
			target,
			target.model:GetPivot().Position - from,
			weapon.knockback,
			lift,
			not ranged and perk ~= nil and perk.uproot == true -- Uproot ignores an archetype's ground pin
		)
	end

	Remotes.CreatureHit:FireAllClients(hitPoint, direction, not CreatureService.isAlive(target), player.UserId)
	return amount
end

local function onRequestAttack(player: Player)
	local weapon = equippedWeapon(player)
	if not weapon or weapon.ranged then
		return -- a gun doesn't swing; its clicks go through RequestShoot
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
	-- skipRangedOnly: a melee swing reaches past a rangedOnly boss head (the
	-- Kraken's) to the tentacles - guns are how the head is hurt.
	local from = (root :: BasePart).Position
	local inReach = CreatureService.inRange(from, weapon.reach, { skipRangedOnly = true })
	local target = inReach[1]
	if not target then
		return
	end

	local amount = landHit(player, weapon, target, from, nil)

	-- Blast Radius: the same swing catches everything else in reach at a
	-- fraction of the damage. Splash targets get no knockback and no on-hit
	-- perk - only the creature you actually swung at - so a cleave can't
	-- juggle a crowd or stack poison on five things at once.
	local perk = weapon.perk
	if amount and perk and perk.cleave then
		local splash = math.max(1, math.floor(amount * Tuning.Perks.CLEAVE_FALLOFF + 0.5))
		for i = 2, #inReach do
			CreatureService.damage(inReach[i], splash, player)
		end
	end
end

-- ============================================================ ranged shots

-- Per-player, PER-WEAPON gun state: the server-tracked magazine, the reload
-- clock, and the token bucket. Keyed by weapon id and kept across swaps, so
-- alternating between two owned guns can't refill a magazine, skip a reload
-- or mint fresh bucket tokens (review find, 2026-08-25) - each weapon's
-- state is exactly where its owner left it.
local rangedState: { [Player]: { [string]: any } } = {}

-- Shots in flight: fired (and, for guns, already resolved) but their damage
-- lands after the cosmetic flight delay, on the Heartbeat queue below.
local pendingShots = {}

-- A pellet's direction: `look` deflected by up to `angle` radians in a random
-- direction. Zero/absent angle is the ray itself.
local function spreadDir(look: Vector3, angle: number?): Vector3
	if not angle or angle <= 0 then
		return look.Unit
	end
	local up = if math.abs(look.Unit.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	local frame = CFrame.lookAt(Vector3.zero, look.Unit, up)
	local deflect = angle * math.sqrt(math.random()) -- uniform over the cone's disc
	local roll = math.random() * 2 * math.pi
	return (frame * CFrame.Angles(math.cos(roll) * deflect, math.sin(roll) * deflect, 0)).LookVector
end

local function onRequestShoot(player: Player, rayOrigin, look)
	local weapon = equippedWeapon(player)
	local ranged = weapon and weapon.ranged
	if not ranged then
		return
	end
	if typeof(rayOrigin) ~= "Vector3" or typeof(look) ~= "Vector3" then
		return
	end
	if look ~= look or look.Magnitude < 0.001 then
		return
	end

	local character = player.Character
	if not character or not ShotAim.originOk(character, rayOrigin) then
		return
	end
	-- The dead don't shoot: a downed player keeps their character (and root)
	-- through the respawn window, so the root check alone isn't enough.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local now = os.clock()
	local byWeapon = rangedState[player]
	if not byWeapon then
		byWeapon = {}
		rangedState[player] = byWeapon
	end
	local state = byWeapon[weapon.id]
	if not state then
		-- First time this gun has ever been raised: full magazine, one token.
		state = { shotsInMag = ranged.magazine, reloadUntil = 0, bucket = 1, lastRefillAt = now }
		byWeapon[weapon.id] = state
	end

	-- Token bucket: refills at one shot per cooldown, capped so at most one
	-- extra shot of jitter queues. The refill clock advances on EVERY request
	-- - accepted or refused - so the same elapsed interval can never be
	-- credited twice by spamming the remote (review find, 2026-08-25).
	state.bucket = math.min(RT.BUCKET_CAP, state.bucket + (now - state.lastRefillAt) / weapon.cooldown)
	state.lastRefillAt = now
	if state.bucket < 1 then
		return
	end

	-- Reload gate: an empty magazine refills only once the reload clock has
	-- run. reloadTime 0 (bows) refills immediately - the cooldown IS the
	-- draw.
	if state.shotsInMag <= 0 then
		if now < state.reloadUntil then
			return
		end
		state.shotsInMag = ranged.magazine
	end

	state.bucket -= 1

	state.shotsInMag -= 1
	if state.shotsInMag <= 0 and ranged.reloadTime > 0 then
		state.reloadUntil = now + ranged.reloadTime
	end

	-- Resolve every pellet AT FIRE TIME: the world caps the ray, then the
	-- nearest live creature on it takes the hit - queued to land after the
	-- flight delay. Arc weapons queue the LANDING instead and re-check it.
	local termini = {}
	for _ = 1, ranged.pellets or 1 do
		local dir = spreadDir(look, ranged.spread)
		local maxDist = ShotAim.terrainLimit(rayOrigin, dir, ranged.range)
		local target, hitT = CreatureService.raycastNearest(rayOrigin, dir, maxDist)
		local terminus = rayOrigin + dir * (hitT or maxDist)
		table.insert(termini, terminus)

		local flight = math.min((terminus - rayOrigin).Magnitude / ranged.projectileSpeed, RT.MAX_FLIGHT)
		table.insert(pendingShots, {
			player = player,
			weapon = weapon,
			at = now + flight,
			-- Guns hold their fire-time target; a bow holds only the landing
			-- and re-picks there, so a dodged arrow misses.
			target = if ranged.arc then nil else target,
			landing = terminus,
			arc = ranged.arc == true,
			from = rayOrigin,
		})
	end

	Remotes.ShotFired:FireAllClients(player.UserId, rayOrigin, termini, weapon.id)
end

-- Land every shot whose flight has run. Guns hit their fire-time target
-- verbatim (dead/gone targets simply fizzle); arc shots re-test a small
-- sphere at the predicted impact against whatever is live there NOW.
local function updateShots()
	local now = os.clock()
	for i = #pendingShots, 1, -1 do
		local shot = pendingShots[i]
		if now >= shot.at then
			table.remove(pendingShots, i)
			if shot.player.Parent == Players then
				local target = shot.target
				if shot.arc then
					target = CreatureService.inRange(shot.landing, RT.ARC_RECHECK_RADIUS)[1]
				end
				if target then
					landHit(shot.player, shot.weapon, target, shot.from, { ranged = true })
				end
			end
		end
	end
end

function CombatService.init()
	Remotes.RequestAttack.OnServerEvent:Connect(onRequestAttack)
	Remotes.RequestShoot.OnServerEvent:Connect(onRequestShoot)
	Players.PlayerRemoving:Connect(function(player)
		lastAttackAt[player] = nil
		frenzy[player] = nil
		rangedState[player] = nil
	end)
end

function CombatService.start()
	-- The shot queue: fired shots land after their flight delay, whatever
	-- else is happening (the boss-glob clock pattern).
	RunService.Heartbeat:Connect(updateShots)
end

return CombatService

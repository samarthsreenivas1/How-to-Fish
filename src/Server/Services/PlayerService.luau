--!nonstrict
-- PlayerService.luau
-- The player's own health, and the one authoritative way to hurt them.
--
-- Damage sources (the pufferfish's rush today, more later) call
-- PlayerService.damage(player, amount, source); nothing pokes a Humanoid
-- directly. Health itself rides on the character's Humanoid - it already
-- owns death, respawn and the replicated Health/MaxHealth the client HUD
-- reads (PlayerHudController) - so this service only sets the max on spawn,
-- gates incoming damage with a brief invulnerability window, and slowly
-- regenerates health once the player has been left alone for a moment.
--
-- Kept deliberately small and Humanoid-backed: the plan's "no Humanoid" rule
-- is about creatures, not the player, and leaning on the real Humanoid means
-- dying and respawning just work.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tuning = require(Shared.Config.Tuning)

local PlayerService = {}

local P = Tuning.Player

-- player -> os.clock() of the last damage taken. Drives both the i-frame
-- (no two hits closer than IFRAME) and the regen delay (no healing until
-- REGEN_DELAY after the last hit).
local lastDamaged: { [Player]: number } = {}
-- When the last BYPASSING burst landed, tracked separately from lastDamaged:
-- a burst must ignore the ordinary contact window (that's what bypass is
-- for) but bursts still have to gate EACH OTHER, or three overlapping AoEs
-- on the volcano apron land their full sum in one beat (review find,
-- 2026-08-25 - the function's own contract always promised they couldn't).
local lastBurst: { [Player]: number } = {}

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

-- Applies `amount` damage to `player`, unless they're still inside the
-- invulnerability window from a recent hit. `source` is informational (which
-- creature struck) - kept in the signature for future armour / resistances.
-- `opts.bypassIframe` lets a telegraphed burst (an explosion, a shockwave, a
-- mimic's bite) land even inside the window, so a stray contact tick a
-- moment earlier can't swallow it; it still starts a fresh window, so two
-- bursts can't stack. Returns true if the hit actually landed.
function PlayerService.damage(player: Player, amount: number, _source: any?, opts: { bypassIframe: boolean? }?): boolean
	if amount <= 0 then
		return false
	end
	local humanoid = humanoidOf(player)
	if not humanoid then
		return false
	end

	local now = os.clock()
	local bypass = opts ~= nil and opts.bypassIframe == true
	if bypass then
		-- A burst ignores the contact window but not the previous BURST's:
		-- overlapping telegraphed AoEs (eruption bomb + fumarole splash +
		-- djinn puff) land once per window, exactly like contact hits do.
		if now - (lastBurst[player] or -math.huge) < P.IFRAME then
			return false
		end
		lastBurst[player] = now
	elseif now - (lastDamaged[player] or -math.huge) < P.IFRAME then
		return false
	end
	lastDamaged[player] = now

	humanoid:TakeDamage(amount)
	return true
end

-- Heals `player` by `amount`, never past their maximum. Used by the
-- Heartrender's Devour lifesteal; deliberately does NOT touch the
-- damage/regen timer, so drinking health in a fight doesn't also restart the
-- out-of-combat regen clock.
function PlayerService.heal(player: Player, amount: number): boolean
	if amount <= 0 then
		return false
	end
	local humanoid = humanoidOf(player)
	if not humanoid then
		return false
	end
	humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + amount)
	return true
end

local function onCharacterAdded(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.MaxHealth = P.MAX_HEALTH
		humanoid.Health = P.MAX_HEALTH
	end
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		onCharacterAdded(player.Character)
	end
end

-- Slow out-of-combat regen: once REGEN_DELAY has passed since the last hit,
-- heal REGEN_RATE per second up to the max.
local function regen(dt: number)
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local humanoid = humanoidOf(player)
		if humanoid and humanoid.Health < humanoid.MaxHealth then
			if now - (lastDamaged[player] or -math.huge) >= P.REGEN_DELAY then
				humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + P.REGEN_RATE * dt)
			end
		end
	end
end

function PlayerService.init() end

function PlayerService.start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player)
		lastDamaged[player] = nil
		lastBurst[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	RunService.Heartbeat:Connect(regen)
end

return PlayerService

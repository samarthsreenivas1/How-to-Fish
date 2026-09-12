--!nonstrict
-- CombatController.luau
-- Melee input. Left click (or a tap) swings whatever weapon is out - bare
-- fists or a crafted weapon.
--
-- Two halves, kept in step by the clip: the matching viewmodel controller
-- plays the swing on the click (FistsViewmodelController's punch clips for
-- the fists, WeaponViewmodelController's swing clip for a weapon with one),
-- and at that clip's HIT_TIME - full extension / the bottom of the arc -
-- this asks the server to resolve the hit (RequestAttack). CombatService
-- reads the same equipped row for reach and damage; nothing comes back
-- through a remote, the hit shows up as the creature's replicated Health
-- attribute dropping, which CombatFeedbackController renders as the flash /
-- bar / number.
--
-- The client gates on the weapon row's cooldown so the swings it shows are
-- the ones the server will accept; the server re-checks regardless.
--
-- The click is bound only while a weapon is equipped (following the
-- Player's `Equipped` attribute), so left click stays free for the reel bar
-- when the rod is out. ContextActionService for the same reason as every
-- other input here (see context.md).

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Equipment = require(Shared.Config.Equipment)
local Weapons = require(Shared.Data.Weapons)
local Remotes = require(Shared.Net.Remotes)

local FistsViewmodelController = require(script.Parent.FistsViewmodelController)
local WeaponViewmodelController = require(script.Parent.WeaponViewmodelController)
local Sfx = require(script.Parent.Parent.Modules.Sfx)

local player = Players.LocalPlayer

local CombatController = {}

local ATTACK_ACTION = "Attack"

local bound = false
local lastAttackAt = 0

local function weaponOut(): boolean
	return player:GetAttribute(Equipment.ATTRIBUTE) == Equipment.WEAPON
end

-- The Weapons row the server says is in hand; fists if the attribute hasn't
-- arrived or names something unknown (mirrors CombatService's fallback).
local function currentWeapon()
	local weaponId = player:GetAttribute(Equipment.WEAPON_ATTRIBUTE)
	return (weaponId and Weapons.items[weaponId]) or Weapons.items[Weapons.STARTER_WEAPON_ID]
end

local function tryAttack()
	local weapon = currentWeapon()
	local now = os.clock()
	if now - lastAttackAt < weapon.cooldown then
		return
	end

	-- The viewmodel can refuse (no rig yet, or the last swing hasn't played
	-- far enough to chain). No swing, no hit.
	local hitTime
	if weapon.swing then
		hitTime = WeaponViewmodelController.swing(weapon.swing)
	else
		hitTime = FistsViewmodelController.punch()
	end
	if not hitTime then
		-- The viewmodel REFUSED: no rig yet, or the previous swing has not
		-- played far enough to chain into. Nothing at all happens on this
		-- click otherwise, and a click that does nothing reads as the game
		-- having dropped the input.
		--
		-- The cooldown return above is deliberately left silent even though it
		-- is also a refusal. It is the ordinary rhythm of holding down a fast
		-- weapon - the state the player is in for most of a fight - and a cue
		-- there would fire many times a second under the swings themselves.
		-- This branch is the exceptional one, so this is the one that speaks.
		Sfx.play("swingRefused")
		return
	end
	lastAttackAt = now
	Sfx.play(if weapon.swing then "weaponSwing" else "punchSwing")

	-- The hit lands when the weapon is out, not when the button goes down.
	task.delay(hitTime, function()
		if weaponOut() then
			Remotes.RequestAttack:FireServer()
		end
	end)
end

local function bindAttack()
	if bound then
		return
	end
	bound = true
	ContextActionService:BindActionAtPriority(ATTACK_ACTION, function(_, state)
		if state == Enum.UserInputState.Begin then
			tryAttack()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.UserInputType.MouseButton1, Enum.UserInputType.Touch)
end

local function unbindAttack()
	if not bound then
		return
	end
	bound = false
	ContextActionService:UnbindAction(ATTACK_ACTION)
end

local function refresh()
	-- A ranged row's clicks belong to RangedController (hold-to-fire, zoom,
	-- reload) - binding both would fire a shot AND a phantom swing.
	if weaponOut() and not currentWeapon().ranged then
		bindAttack()
	else
		unbindAttack()
	end
end

function CombatController.init() end

function CombatController.start()
	-- No uiEquip echo here: three controllers watch this same attribute, so the
	-- equip cue lives in FishingController alone rather than triple-playing.
	player:GetAttributeChangedSignal(Equipment.ATTRIBUTE):Connect(refresh)
	-- Swapping between a melee weapon and a gun changes who owns the click
	-- without `Equipped` ever changing.
	player:GetAttributeChangedSignal(Equipment.WEAPON_ATTRIBUTE):Connect(refresh)
	refresh()
end

return CombatController

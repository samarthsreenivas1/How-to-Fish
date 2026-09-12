--!nonstrict
-- _Example.luau
-- The shape of a boss intro script, and the reason this folder is not empty:
-- rojo emits nothing at all for a directory with no files in it (verified
-- against the built place - `Cutscenes` simply did not exist), and git does not
-- track empty directories either, so the folder BossCutsceneController requires
-- out of would vanish between the checkout and the build. One file holds it
-- open.
--
-- NOTHING REQUIRES THIS. A script is only loaded when a BossCutscenes row names
-- it (`script = "BrinejawIntro"`), and no row names this one - the leading
-- underscore says so. Copy it, do not extend it.
--
-- A cutscene script is called ONCE, at the top of the run, with a kit bound to
-- that run (src/Client/Modules/CutsceneKit.luau has the full API). It registers
-- and returns; the controller steps the kit every frame afterwards.

return function(kit)
	-- Where things are. `kit.center` is the arena centre at the arena's own
	-- floor datum (what the server measured), and bearings are Roblox-convention
	-- radians - an authored degree off an arena_gen.py HANDOFF line goes through
	-- `kit.authored(deg)`.
	local seaward = kit.polar(220, kit.authored(0), kit.floorY(220, kit.authored(0)) + 40)

	-- The stand-in the body controllers adopt while the real rig does not exist
	-- yet. Its last pose has to equal the real rise's first frame, and it must be
	-- destroyed the moment the real one lands.
	local stand = kit.actor({ pose = kit.boss.pose, attrs = {} })
	kit.onRealBoss(function()
		stand:destroy()
	end)

	-- The camera. A shot's `u` runs 0..1 across its own window; a gap between
	-- shots holds the last frame.
	kit.shot({
		t0 = 0,
		t1 = kit.raiseAt,
		pos = kit.orbit(kit.center, 260, 60, kit.authored(0), kit.authored(120)),
		look = kit.center,
		fov = 65,
		blendIn = 0,
	})
	kit.shot({ t0 = kit.raiseAt, t1 = kit.duration, pos = seaward, look = kit.center, blendIn = 1.2 })

	-- The beat the whole framework is built around: the real rise plays out
	-- under the last shot, and the title card lands on the roar the client's own
	-- bossRise handler fires at 0.85 * riseTime.
	kit.at(kit.raiseAt + 0.85 * kit.riseTime, function()
		kit.card(kit.boss.shortName, "answers the call")
		kit.shake(0.06, 1.1)
	end)
end

--!nonstrict
-- BossCutscenes.luau
-- Which bosses open their fight with an intro cinematic, how long it runs,
-- and which client script draws it. Read by BOTH sides, which is why it lives
-- in Shared rather than beside the controller: the server needs `duration` to
-- know how long to hold the real rise back (BossService schedules the raise at
-- `duration - riseTime`, so the boss surfacing IS the cutscene's last beat),
-- and the client needs `script` to know which module under
-- src/Client/Cutscenes/ to require.
--
-- A boss with NO row here is untouched, on both sides: BossService raises it
-- the instant it is summoned exactly as it always did, and the client shows
-- BossHudController's "rises from the deep" card. That is the honest fallback
-- and the thing to reach for when a cinematic misbehaves - delete the row.
--
-- `duration` is the WHOLE cinematic including the real rise, not the part
-- before it. The handoff is fixed by the boss's own `riseTime` (Bosses.luau):
-- the last `riseTime` seconds of every row below are the genuine rise playing
-- out under the camera, so a row's duration must always exceed its boss's
-- riseTime by enough to have told a story first. The per-boss script author
-- owns their own row's number - it is the one field here they are expected to
-- change - but they cannot change riseTime, which is fight tuning.
--
-- `script` is a module NAME, not a path: BossCutsceneController requires
-- `Cutscenes[script]` lazily and warns (never errors) when it is missing, so
-- a row can be added before its script exists without taking the client's
-- boot down with it.

local BossCutscenes = {}

export type Cutscene = {
	duration: number, -- seconds, total, including the boss's own riseTime at the end
	script: string, -- module name under src/Client/Cutscenes/
}

BossCutscenes.items = {
	brinejaw = { duration = 22, script = "BrinejawIntro" },
	old_gnashroot = { duration = 22, script = "GnashrootIntro" },
	rimefang = { duration = 20, script = "RimefangIntro" },
	pyrelisk = { duration = 26, script = "PyreliskIntro" },
	noctyss = { duration = 22, script = "NoctyssIntro" },
	admiral_wrack = { duration = 22, script = "WrackIntro" },
	kraken = { duration = 24, script = "KrakenIntro" },
}

-- How long this boss's intro runs, or nil when it has none. The server's one
-- question, and the only branch between "cinematic" and "today's behaviour".
function BossCutscenes.durationFor(bossId: string): number?
	local row = BossCutscenes.items[bossId]
	return row and row.duration or nil
end

return BossCutscenes

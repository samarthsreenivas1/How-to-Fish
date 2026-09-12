--!nonstrict
-- BossHudThemes.luau
-- ONE BAR PER BOSS. The boss health bar used to be a single generic teal
-- strip with the boss's name over it, and seven fights shared it; this is the
-- look half of that bar, keyed by the Bosses row id, so the thing across the
-- top of the screen belongs to the monster in front of you.
--
-- DATA ONLY. Nothing here builds an instance, nothing here requires a client
-- module (this is Shared, the client's Theme is not reachable and must not
-- be), and nothing here duplicates a string the Bosses row already carries -
-- the NAME and the EPITHET are SPLIT out of `Bosses.items.*.name` at draw
-- time by `Themes.split`, so renaming a boss renames its bar and a stale row
-- name (Rimefang is a killer whale now, its row still says "Glacier Serpent")
-- stays the data's business, not this file's.
--
-- BossHudController is the only reader. It renders `ornament` PROCEDURALLY -
-- Frames, UICorner, UIGradient, UIStroke, rotations - because the HUD may not
-- cost an asset upload; every key below is therefore a hint the controller
-- knows how to draw, not an image id.
--
-- THE SHAPE (every theme carries all of it; the controller still guards, so a
-- half-filled theme degrades instead of erroring):
--
--   palette = {
--     track, trackEdge  - the plate the bar sits in and its gradient far end
--     mottle, mottleFade- an overlay tint + its transparency (texture)
--     fill = { Color3 } - the fill's gradient stops, left (empty end) to right
--     stroke, glow      - the track's outline, and the glow bloomed off the fill
--     text, epithet     - the two type colours
--     tick, chip        - phase boundary marks; the pale trailing "chip" fill
--     ornament, ornamentAlt - the procedural decoration's two colours
--     enraged = { fill, stroke, glow, track, text, tick, ornament }
--   }
--   typography = { name, epithet - Enum.Font; nameSize, epithetSize; spacing
--                  - letters are spaced by inserting this many spaces between
--                  them (Roblox TextLabels have no letter-spacing property);
--                  epithetCase = "upper" | "lower" | nil (as written) }
--   ornament = "scales" | "embers" | "roots" | "icicles" | "lantern"
--            | "brass" | "whirlpool" | "none"
--   frame    = { corner, stroke, height, width (scale of screen), endCap =
--                "round" | "square" | "point", gap }
--   motion   = { pulse, drift, rotate, sway, shake, chipHold, chipFall }
--             - pulse: fill brightness breaths / second (0 = still)
--             - drift: ornament travel, fraction of the bar per second
--             - rotate: fill gradient degrees / second
--             - sway:  ornament rocking, degrees
--             - shake: multiplier on the big-hit bar shake
--             - chipHold / chipFall: the chip trail's linger and its fall
--   enrage   = { tint, pulse, glow, ornament } - what ENRAGE does to this
--              boss specifically: a tint mixed into the fill, a faster breath,
--              a wider glow, and an ornament mode ("flare", "crack", "hot",
--              "churn", "rot", "boil", "gale") the controller reads.
--   seam     = { track, fill, full } - the flank stagger meters' palette, for
--              the two bosses that publish SeamMeter attributes.
--
-- A boss with no entry here (or a model with no CreatureId at all) gets
-- `Themes.default`, which is the bar exactly as it looked before this file.

local Themes = {}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- ---------------------------------------------------------------- default

-- The old bar, preserved: the lure's glow on a dark plate, in the house face.
-- Anything without a theme lands here, so this has to be a bar that is fine
-- for ANY boss rather than one that is right for a particular one.
Themes.default = {
	palette = {
		track = rgb(14, 18, 24),
		trackEdge = rgb(20, 26, 34),
		mottle = rgb(40, 60, 70),
		mottleFade = 0.9,
		fill = { rgb(90, 220, 190), rgb(120, 255, 214) },
		stroke = rgb(38, 84, 132),
		glow = rgb(120, 255, 214),
		text = rgb(255, 255, 255),
		epithet = rgb(190, 226, 220),
		tick = rgb(220, 255, 245),
		chip = rgb(200, 255, 236),
		ornament = rgb(120, 255, 214),
		ornamentAlt = rgb(90, 200, 180),
		enraged = {
			fill = { rgb(230, 70, 50), rgb(255, 110, 80) },
			stroke = rgb(255, 120, 90),
			glow = rgb(255, 80, 60),
			track = rgb(22, 12, 12),
			text = rgb(255, 150, 130),
			tick = rgb(255, 200, 180),
			ornament = rgb(255, 120, 90),
		},
	},
	typography = {
		name = Enum.Font.FredokaOne,
		epithet = Enum.Font.GothamMedium,
		nameSize = 20,
		epithetSize = 11,
		spacing = 1,
		epithetCase = "lower",
	},
	ornament = "none",
	frame = { corner = 4, stroke = 1.5, height = 16, width = 0.46, endCap = "round", gap = 6 },
	motion = { pulse = 0, drift = 0, rotate = 0, sway = 0, shake = 1, chipHold = 0.35, chipFall = 0.5 },
	enrage = { tint = rgb(255, 80, 60), pulse = 1.6, glow = 0.35, ornament = "hot" },
	seam = { track = rgb(14, 18, 24), fill = rgb(255, 140, 60), full = rgb(255, 196, 64) },
}

Themes.items = {}

-- ---------------------------------------------------------------- brinejaw
-- "Brinejaw, the Drowned Leviathan" - a brine serpent on a drowned tower.
-- Sea-green over black water, a scale row along the top edge, a wave crest
-- that rolls along the fill and foam ticks breaking off it.
Themes.items.brinejaw = {
	palette = {
		track = rgb(8, 26, 30),
		trackEdge = rgb(12, 40, 44),
		mottle = rgb(24, 86, 84),
		mottleFade = 0.82,
		fill = { rgb(24, 140, 132), rgb(74, 214, 186), rgb(150, 255, 226) },
		stroke = rgb(64, 168, 152),
		glow = rgb(120, 255, 214),
		text = rgb(238, 255, 250),
		epithet = rgb(150, 226, 212),
		tick = rgb(214, 255, 244),
		chip = rgb(196, 252, 234),
		ornament = rgb(120, 226, 200),
		ornamentAlt = rgb(236, 255, 252),
		enraged = {
			fill = { rgb(198, 40, 56), rgb(255, 108, 88), rgb(255, 176, 120) },
			stroke = rgb(255, 128, 104),
			glow = rgb(255, 88, 72),
			track = rgb(28, 10, 14),
			text = rgb(255, 214, 202),
			tick = rgb(255, 226, 210),
			ornament = rgb(255, 140, 110),
		},
	},
	typography = {
		name = Enum.Font.LuckiestGuy,
		epithet = Enum.Font.GothamMedium,
		nameSize = 21,
		epithetSize = 11,
		spacing = 1,
		epithetCase = "lower",
	},
	ornament = "scales",
	frame = { corner = 5, stroke = 1.5, height = 16, width = 0.46, endCap = "round", gap = 6 },
	motion = { pulse = 0.5, drift = 0.14, rotate = 0, sway = 3, shake = 1, chipHold = 0.35, chipFall = 0.55 },
	enrage = { tint = rgb(255, 74, 60), pulse = 2, glow = 0.3, ornament = "churn" },
	seam = { track = rgb(8, 26, 30), fill = rgb(74, 214, 186), full = rgb(150, 255, 226) },
}

-- ---------------------------------------------------------------- pyrelisk
-- "Pyrelisk, the Ashfall Colossus" - obsidian track, a lava-crack fill that
-- breathes orange into yellow, embers drifting up off it, an ash-grey frame.
-- Its two flank seam meters (SeamMeterL / R) ride the same palette.
Themes.items.pyrelisk = {
	palette = {
		track = rgb(18, 14, 16),
		trackEdge = rgb(34, 26, 24),
		mottle = rgb(70, 54, 48),
		mottleFade = 0.8,
		fill = { rgb(196, 42, 12), rgb(255, 124, 24), rgb(255, 226, 110) },
		stroke = rgb(150, 146, 140),
		glow = rgb(255, 146, 54),
		text = rgb(255, 244, 230),
		epithet = rgb(206, 196, 186),
		tick = rgb(255, 210, 140),
		chip = rgb(255, 200, 150),
		ornament = rgb(255, 158, 66),
		ornamentAlt = rgb(158, 150, 142),
		enraged = {
			fill = { rgb(255, 58, 8), rgb(255, 156, 20), rgb(255, 255, 206) },
			stroke = rgb(255, 196, 120),
			glow = rgb(255, 120, 30),
			track = rgb(28, 12, 10),
			text = rgb(255, 226, 186),
			tick = rgb(255, 240, 200),
			ornament = rgb(255, 220, 130),
		},
	},
	typography = {
		name = Enum.Font.GothamBlack,
		epithet = Enum.Font.GothamBold,
		nameSize = 20,
		epithetSize = 10,
		spacing = 2,
		epithetCase = "upper",
	},
	ornament = "embers",
	frame = { corner = 2, stroke = 2, height = 17, width = 0.46, endCap = "square", gap = 6 },
	motion = { pulse = 0.35, drift = 0.5, rotate = 0, sway = 0, shake = 1.15, chipHold = 0.3, chipFall = 0.5 },
	enrage = { tint = rgb(255, 90, 20), pulse = 1.8, glow = 0.45, ornament = "flare" },
	seam = { track = rgb(18, 14, 16), fill = rgb(255, 140, 60), full = rgb(255, 196, 64) },
}

-- ---------------------------------------------------------- old_gnashroot
-- "Old Gnashroot, the Drowned Mire" - peat-dark track under layered mottling,
-- an olive fill, root tendrils curling off both ends. Enrage turns it the
-- sickly bright green of something fermenting.
Themes.items.old_gnashroot = {
	palette = {
		track = rgb(26, 24, 14),
		trackEdge = rgb(40, 38, 22),
		mottle = rgb(72, 66, 34),
		mottleFade = 0.62,
		fill = { rgb(74, 84, 34), rgb(124, 142, 58), rgb(168, 180, 92) },
		stroke = rgb(92, 74, 44),
		glow = rgb(132, 158, 74),
		text = rgb(244, 240, 216),
		epithet = rgb(184, 180, 140),
		tick = rgb(214, 212, 160),
		chip = rgb(198, 204, 148),
		ornament = rgb(96, 76, 48),
		ornamentAlt = rgb(140, 158, 74),
		enraged = {
			fill = { rgb(96, 190, 54), rgb(158, 240, 88), rgb(206, 255, 140) },
			stroke = rgb(150, 220, 110),
			glow = rgb(150, 255, 110),
			track = rgb(18, 26, 14),
			text = rgb(224, 255, 200),
			tick = rgb(236, 255, 208),
			ornament = rgb(150, 230, 100),
		},
	},
	typography = {
		name = Enum.Font.GrenzeGotisch,
		epithet = Enum.Font.Merriweather,
		nameSize = 22,
		epithetSize = 11,
		spacing = 1,
		epithetCase = "lower",
	},
	ornament = "roots",
	frame = { corner = 3, stroke = 2, height = 17, width = 0.46, endCap = "square", gap = 6 },
	motion = { pulse = 0.25, drift = 0.05, rotate = 0, sway = 5, shake = 0.9, chipHold = 0.45, chipFall = 0.7 },
	enrage = { tint = rgb(150, 255, 110), pulse = 1.4, glow = 0.4, ornament = "rot" },
	seam = { track = rgb(26, 24, 14), fill = rgb(124, 142, 58), full = rgb(168, 180, 92) },
}

-- ---------------------------------------------------------------- rimefang
-- The killer whale under the ice (the ROW still says "Glacier Serpent" and
-- that is the row's business - the label reads `name`, so the bar says
-- whatever the data says). Ice-blue frame, frost crystals on the plate, the
-- fill reading as dark sea seen through it, icicle teeth hung off the
-- underside. Its phase ticks (the row's 0.5 and 0.2) draw as cracks; enrage
-- takes the ice storm-grey and lights the eyes red-orange.
Themes.items.rimefang = {
	palette = {
		track = rgb(16, 32, 46),
		trackEdge = rgb(26, 52, 70),
		mottle = rgb(120, 180, 220),
		mottleFade = 0.86,
		fill = { rgb(38, 108, 156), rgb(126, 202, 234), rgb(226, 246, 255) },
		stroke = rgb(196, 232, 252),
		glow = rgb(176, 224, 255),
		text = rgb(246, 252, 255),
		epithet = rgb(174, 210, 232),
		tick = rgb(238, 250, 255),
		chip = rgb(255, 255, 255),
		ornament = rgb(222, 244, 255),
		ornamentAlt = rgb(150, 206, 238),
		enraged = {
			fill = { rgb(74, 82, 92), rgb(132, 142, 154), rgb(186, 194, 204) },
			stroke = rgb(206, 212, 220),
			glow = rgb(255, 108, 48),
			track = rgb(24, 26, 30),
			text = rgb(255, 226, 210),
			tick = rgb(255, 150, 90),
			ornament = rgb(255, 122, 56),
		},
	},
	typography = {
		name = Enum.Font.Michroma,
		epithet = Enum.Font.GothamMedium,
		nameSize = 19,
		epithetSize = 10,
		spacing = 2,
		epithetCase = "upper",
	},
	ornament = "icicles",
	frame = { corner = 2, stroke = 2, height = 16, width = 0.46, endCap = "point", gap = 7 },
	motion = { pulse = 0.2, drift = 0.03, rotate = 0, sway = 2, shake = 1.1, chipHold = 0.28, chipFall = 0.45 },
	enrage = { tint = rgb(255, 96, 40), pulse = 1.2, glow = 0.5, ornament = "crack" },
	seam = { track = rgb(16, 32, 46), fill = rgb(126, 202, 234), full = rgb(226, 246, 255) },
}

-- ---------------------------------------------------------------- noctyss
-- "Noctyss, the Trench Mother" - the gloom angler. Near-black plate, the fill
-- a faint glowing thread rather than a slab of colour, lantern motes hanging
-- in the dark around it. Enrage takes the lure hot magenta.
Themes.items.noctyss = {
	palette = {
		track = rgb(6, 6, 12),
		trackEdge = rgb(12, 10, 24),
		mottle = rgb(60, 40, 110),
		mottleFade = 0.88,
		fill = { rgb(46, 24, 104), rgb(148, 82, 246), rgb(92, 232, 255) },
		stroke = rgb(70, 58, 112),
		glow = rgb(170, 110, 255),
		text = rgb(226, 232, 255),
		epithet = rgb(148, 156, 216),
		tick = rgb(120, 224, 255),
		chip = rgb(112, 92, 182),
		ornament = rgb(146, 228, 255),
		ornamentAlt = rgb(176, 116, 255),
		enraged = {
			fill = { rgb(122, 10, 92), rgb(255, 48, 176), rgb(255, 138, 226) },
			stroke = rgb(206, 64, 156),
			glow = rgb(255, 60, 190),
			track = rgb(14, 4, 12),
			text = rgb(255, 216, 244),
			tick = rgb(255, 160, 226),
			ornament = rgb(255, 92, 206),
		},
	},
	typography = {
		name = Enum.Font.Creepster,
		epithet = Enum.Font.GothamMedium,
		nameSize = 23,
		epithetSize = 11,
		spacing = 2,
		epithetCase = "lower",
	},
	ornament = "lantern",
	frame = { corner = 8, stroke = 1.5, height = 15, width = 0.46, endCap = "round", gap = 7 },
	motion = { pulse = 0.45, drift = 0.04, rotate = 0, sway = 4, shake = 0.85, chipHold = 0.5, chipFall = 0.8 },
	enrage = { tint = rgb(255, 60, 190), pulse = 2.4, glow = 0.5, ornament = "hot" },
	seam = { track = rgb(6, 6, 12), fill = rgb(148, 82, 246), full = rgb(92, 232, 255) },
}

-- ------------------------------------------------------------ admiral_wrack
-- "Admiral Wrack, the Fleet-Eater" - tarred-wood track in a brass-riveted
-- frame, a red-white-red ensign stripe for a fill, rope whipped round both
-- ends. He publishes the flank seam meters, so they get the brass too.
Themes.items.admiral_wrack = {
	palette = {
		track = rgb(34, 26, 20),
		trackEdge = rgb(52, 40, 30),
		mottle = rgb(84, 62, 42),
		mottleFade = 0.68,
		fill = { rgb(204, 44, 44), rgb(246, 240, 230), rgb(204, 44, 44) },
		stroke = rgb(206, 160, 92),
		glow = rgb(255, 208, 130),
		text = rgb(255, 244, 224),
		epithet = rgb(214, 186, 146),
		tick = rgb(255, 226, 170),
		chip = rgb(250, 222, 190),
		ornament = rgb(206, 160, 92),
		ornamentAlt = rgb(222, 190, 140),
		enraged = {
			fill = { rgb(170, 16, 16), rgb(255, 118, 70), rgb(170, 16, 16) },
			stroke = rgb(255, 196, 96),
			glow = rgb(255, 128, 60),
			track = rgb(30, 16, 12),
			text = rgb(255, 226, 196),
			tick = rgb(255, 236, 190),
			ornament = rgb(255, 186, 100),
		},
	},
	typography = {
		name = Enum.Font.Antique,
		epithet = Enum.Font.SpecialElite,
		nameSize = 21,
		epithetSize = 11,
		spacing = 2,
		epithetCase = "upper",
	},
	ornament = "brass",
	frame = { corner = 2, stroke = 2.5, height = 18, width = 0.46, endCap = "square", gap = 6 },
	motion = { pulse = 0.2, drift = 0.08, rotate = 0, sway = 2, shake = 1.2, chipHold = 0.35, chipFall = 0.5 },
	enrage = { tint = rgb(255, 110, 50), pulse = 1.6, glow = 0.4, ornament = "boil" },
	seam = { track = rgb(34, 26, 20), fill = rgb(206, 160, 92), full = rgb(255, 226, 170) },
}

-- ------------------------------------------------------------- wrack_duel
-- The same Admiral, one blade instead of a fleet: the same brass and ensign,
-- slimmer everywhere - a shorter bar, smaller type, fewer rivets - because a
-- duel should not wear the same width across the screen as his flagship.
Themes.items.wrack_duel = {
	palette = Themes.items.admiral_wrack.palette,
	typography = {
		name = Enum.Font.Antique,
		epithet = Enum.Font.SpecialElite,
		nameSize = 19,
		epithetSize = 10,
		spacing = 2,
		epithetCase = "upper",
	},
	ornament = "brass",
	frame = { corner = 2, stroke = 2, height = 13, width = 0.34, endCap = "square", gap = 5 },
	motion = { pulse = 0.25, drift = 0.08, rotate = 0, sway = 2, shake = 1.3, chipHold = 0.3, chipFall = 0.45 },
	enrage = { tint = rgb(255, 110, 50), pulse = 1.9, glow = 0.35, ornament = "boil" },
	seam = { track = rgb(34, 26, 20), fill = rgb(206, 160, 92), full = rgb(255, 226, 170) },
}

-- ---------------------------------------------------------------- kraken
-- "The Kraken, Maw of the Maelstrom" - deep indigo, a fill whose gradient
-- turns like water going down a drain, tentacle curls at both ends and storm
-- foam flecking past. (Its `phases` advance on the fight's own machine, not
-- on health - every row after the first is `below = 0.0` - so this bar
-- honestly draws no phase ticks; see the controller's tick rule.)
Themes.items.kraken = {
	palette = {
		track = rgb(10, 12, 40),
		trackEdge = rgb(18, 22, 64),
		mottle = rgb(52, 74, 160),
		mottleFade = 0.78,
		fill = { rgb(30, 48, 148), rgb(84, 120, 230), rgb(156, 214, 255) },
		stroke = rgb(118, 138, 220),
		glow = rgb(122, 180, 255),
		text = rgb(238, 244, 255),
		epithet = rgb(158, 176, 226),
		tick = rgb(232, 244, 255),
		chip = rgb(178, 200, 255),
		ornament = rgb(96, 128, 232),
		ornamentAlt = rgb(226, 240, 255),
		enraged = {
			fill = { rgb(110, 28, 188), rgb(70, 96, 226), rgb(212, 84, 198) },
			stroke = rgb(198, 128, 255),
			glow = rgb(206, 120, 255),
			track = rgb(16, 8, 34),
			text = rgb(246, 226, 255),
			tick = rgb(255, 226, 255),
			ornament = rgb(196, 118, 255),
		},
	},
	typography = {
		name = Enum.Font.Bangers,
		epithet = Enum.Font.GothamBold,
		nameSize = 23,
		epithetSize = 10,
		spacing = 2,
		epithetCase = "upper",
	},
	ornament = "whirlpool",
	frame = { corner = 6, stroke = 2, height = 18, width = 0.48, endCap = "round", gap = 7 },
	motion = { pulse = 0.3, drift = 0.22, rotate = 26, sway = 6, shake = 1.25, chipHold = 0.4, chipFall = 0.6 },
	enrage = { tint = rgb(190, 80, 255), pulse = 1.7, glow = 0.5, ornament = "gale" },
	seam = { track = rgb(10, 12, 40), fill = rgb(84, 120, 230), full = rgb(156, 214, 255) },
}

-- ---------------------------------------------------------------- readers

-- The theme for a Bosses row id, or the default for an id with no theme (and
-- for a boss model that arrived without a CreatureId at all).
function Themes.get(id: any)
	if type(id) == "string" then
		local theme = Themes.items[id]
		if theme then
			return theme
		end
	end
	return Themes.default
end

-- The row's `name` split at its FIRST comma into the big NAME and the small
-- EPITHET - "Brinejaw, the Drowned Leviathan" -> "Brinejaw" / "the Drowned
-- Leviathan". A name with no comma ("Admiral Wrack") is all name and no
-- epithet, and that is a legal bar: the controller just hides the second line.
function Themes.split(fullName: any): (string, string)
	local text = if type(fullName) == "string" then fullName else tostring(fullName or "")
	local head, tail = string.match(text, "^([^,]+),%s*(.+)$")
	if head then
		return head, tail
	end
	return text, ""
end

-- Letter-spacing, the only way a TextLabel has one: put `count` spaces
-- between the characters. Used on the epithet, which is small and wide.
function Themes.spaced(text: string, count: number?): string
	local n = math.floor(count or 0)
	if n <= 0 or text == "" then
		return text
	end
	local gap = string.rep(" ", n)
	local out = {}
	for i = 1, #text do
		table.insert(out, string.sub(text, i, i))
	end
	return table.concat(out, gap)
end

return Themes

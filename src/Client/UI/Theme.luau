--!nonstrict
-- Theme.luau
-- The one look every screen shares: a palette, fonts, radii and the minimum
-- touch target. The 2026-08-24 "sticker" pass (user reference: bright
-- pet-sim style UI) moved the kit from moody deep-water navy to a sunny
-- cartoon read: bright lagoon blues for the chrome, warm paper for content
-- areas, and a dark INK outline around everything - windows, buttons, text
-- glyphs - so every element sits on screen like a die-cut sticker. Every
-- menu is built from Client/UI/Kit.luau on top of these tokens, so a colour
-- change here restyles the whole game.
--
-- Keys that other files already read (accent / text / textDim / green / red
-- / panel / panelLight / border / background, Font.header / Font.body,
-- MIN_TAP) are kept under the same names; new ones are additive.

local Theme = {}

-- Minimum touch target size in pixels, per the plan's touch invariant.
Theme.MIN_TAP = 64

Theme.Color = {
	-- Chrome surfaces: bright lagoon blues, light to dark.
	background = Color3.fromRGB(24, 96, 156),
	panel = Color3.fromRGB(84, 178, 232),
	panelLight = Color3.fromRGB(118, 200, 244),
	panelHover = Color3.fromRGB(146, 214, 250),
	border = Color3.fromRGB(38, 84, 132),
	borderLight = Color3.fromRGB(170, 226, 250),

	-- The sticker sheet: warm paper for content areas, and the ink outline
	-- that goes around everything (frames AND text glyphs).
	paper = Color3.fromRGB(255, 240, 221),
	paperDark = Color3.fromRGB(247, 220, 193),
	ink = Color3.fromRGB(35, 49, 78),

	-- Interactive blue (buttons, selected things, links).
	accent = Color3.fromRGB(56, 170, 240),
	accentDark = Color3.fromRGB(20, 110, 184),

	-- Warmth: cartoon driftwood, sand, coin gold.
	wood = Color3.fromRGB(224, 158, 92),
	woodDark = Color3.fromRGB(176, 116, 62),
	sand = Color3.fromRGB(255, 226, 160),
	gold = Color3.fromRGB(255, 196, 64),

	-- Display text is white with an ink outline (Kit adds the outline);
	-- textDim is body copy on paper / white surfaces.
	text = Color3.fromRGB(255, 255, 255),
	textDim = Color3.fromRGB(96, 116, 148),
	textOnAccent = Color3.fromRGB(255, 255, 255),

	-- Feedback. green / red are also the reel bar's zones.
	green = Color3.fromRGB(92, 216, 110),
	red = Color3.fromRGB(240, 88, 74),
	ember = Color3.fromRGB(255, 140, 60),
	violet = Color3.fromRGB(190, 120, 240),

	-- Tackle: hemp rope, brass fittings, foam white and the classic
	-- red-over-white float. Kit's bobber motif reads from these.
	hemp = Color3.fromRGB(222, 190, 140),
	hempDark = Color3.fromRGB(181, 144, 96),
	brass = Color3.fromRGB(206, 160, 92),
	foam = Color3.fromRGB(255, 255, 255),
	bobberRed = Color3.fromRGB(238, 76, 60),
}

Theme.Font = {
	-- Rounded, chunky display face for titles, tabs, buttons and numbers.
	header = Enum.Font.FredokaOne,
	-- Clean body face for descriptions and lists.
	body = Enum.Font.GothamMedium,
	bodyBold = Enum.Font.GothamBold,
}

Theme.Radius = {
	window = 20,
	panel = 16,
	card = 14,
	button = 12,
	tile = 10,
	chip = 999,
}

-- Text sizes, so every screen's hierarchy matches.
Theme.Size = {
	title = 26,
	subtitle = 14,
	section = 12,
	name = 20,
	body = 14,
	small = 12,
	button = 17,
}

return Theme

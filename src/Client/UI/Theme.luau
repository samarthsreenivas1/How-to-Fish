--!nonstrict
-- Theme.luau
-- The one look every screen shares: a palette, fonts, radii and the minimum
-- touch target. The 2026-08-23 overhaul (user: "more on theme and detailed,
-- less text and numbers, better font") moved it from a neutral grey kit to
-- the game's own world - deep-water navy panels, a sea-foam accent, sand and
-- driftwood warmth for headers, gold for coin - and a rounded display font
-- for titles and buttons. Every menu is built from Client/UI/Kit.luau on top
-- of these tokens, so a colour change here restyles the whole game.
--
-- Keys that other files already read (accent / text / textDim / green / red
-- / panel / panelLight / border / background, Font.header / Font.body,
-- MIN_TAP) are kept under the same names; new ones are additive.

local Theme = {}

-- Minimum touch target size in pixels, per the plan's touch invariant.
Theme.MIN_TAP = 64

Theme.Color = {
	-- Surfaces, dark to light: the sea at depth up to the shallows.
	background = Color3.fromRGB(12, 24, 34),
	panel = Color3.fromRGB(19, 38, 53),
	panelLight = Color3.fromRGB(28, 54, 74),
	panelHover = Color3.fromRGB(36, 68, 92),
	border = Color3.fromRGB(52, 88, 112),
	borderLight = Color3.fromRGB(84, 128, 156),

	-- Sea-foam: the interactive colour (selected tab, primary button, links).
	accent = Color3.fromRGB(92, 214, 226),
	accentDark = Color3.fromRGB(30, 118, 136),

	-- Warmth: driftwood headers, sand highlights, coin gold.
	wood = Color3.fromRGB(128, 88, 54),
	woodDark = Color3.fromRGB(78, 52, 32),
	sand = Color3.fromRGB(236, 217, 166),
	gold = Color3.fromRGB(255, 204, 92),

	text = Color3.fromRGB(242, 247, 250),
	textDim = Color3.fromRGB(152, 180, 198),
	textOnAccent = Color3.fromRGB(10, 30, 38),

	-- Feedback. green / red are also the reel bar's zones.
	green = Color3.fromRGB(96, 214, 130),
	red = Color3.fromRGB(232, 96, 88),
	ember = Color3.fromRGB(255, 140, 60),
	violet = Color3.fromRGB(190, 120, 240),
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

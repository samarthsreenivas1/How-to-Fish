--!nonstrict
-- Npcs.luau
-- The islands' named characters, as data. An NPC is a stationary friendly
-- body with a nameplate and a ProximityPrompt; walking up and pressing E
-- opens the dialog (NpcService pushes NpcDialog, NpcDialogController draws
-- it on the Kit).
--
-- The body is BUILT, not cloned from a creature pack: `look` is a small
-- palette + silhouette description (skin/shirt/sleeves/pants/hair, a hat
-- kind, height and width scales) that NpcService turns into a blocky Roblox
-- figure. Every field of `look` is optional and has a code default, so a row
-- with no `look` at all still builds a person. The old
-- `body = { model = "CreaturePack", ... }` field is GONE: it indexed a pack
-- that is not loaded at NPC-build time and crashed NpcService.start.
--
-- Placement: `spawnOffset` is relative to the ISLAND'S SPAWN POINT
-- (Islands.items[island].spawn, world coords) - spawns sit on reviewed,
-- walkable ground on every island, so an NPC a few studs from one does too.
-- The Y is probed against the real terrain at build time.
--
-- Talking: `greeting` is the full introduction, shown the first time you
-- talk to them in a session; `hello` is the short returning-visit line pool
-- after that. `voice` is the character's whole dialog vocabulary - every
-- generic line the quest and shop panes need, written in THEIR voice so the
-- code never has to fall back to a neutral string. Format slots are fixed by
-- contract: `locked` takes the quest name then the required level ("%s" then
-- "%d"), `busy`/`done` take a quest name, `lockedPrereq` takes the PREREQ
-- quest's name, and `shopBought` MUST begin with "There you go" (the client's
-- buy chime keys off that prefix).
--
-- `quests` lists Quests.luau ids in offer order; `shop` names a Shops.luau
-- stock. Per-quest accept/progress/complete lines live on the quest row
-- (Quests.items.<id>.lines) and override `voice.accept` where present.
--
-- CRAFTING IS THEIRS NOW (2026-09-12). The old `C` window is gone: a recipe is
-- worked at a villager's bench, so `crafts = true` is what puts the third tab
-- (Craft) in that NPC's menu - NpcService fills it from the recipe rows and
-- CraftingService still owns every check. It is on the nine who keep a bench
-- or a fire of their own: Maren, Morra, Halvard, Brakk, Lumen, Hollow, Odd,
-- Vess and the Lampwright (the three hermits craft their own quest rods).
--
-- CONVERSATIONS (2026-09-12, FLAT). `greeting`/`hello` are the old one-shot
-- lines and stay as the menu's remark pool; the talk itself is `dialogue`. It
-- was a branching tree for a day and it was too much to follow, so it is flat
-- now: EXACTLY FIVE nodes per row, one HUB of four choices, and every choice
-- label says plainly what it does.
--   dialogue.first = "open"  - the FIRST-ever meeting (black screen, the name
--     fading in, the lines typing themselves out): 2-3 short pages that say who
--     they are, what this place is, and what they want from you.
--   dialogue.again = "hi"    - every later meeting: one returning-greeting line.
--   nodes.hub                - one short "What would you like to do?" line.
--     It is the re-entry point for the code (a player sent back into the talk
--     from the menu lands here); no choice names it, by design.
--   nodes.about              - 1-2 pages: the island and its open secret.
--   nodes.who                - 1 page: the character's own wound, said plainly.
-- THE HUB SET. open, hub, about, who and hi all carry the SAME four choices in
-- the SAME order, so the player learns the menu once and never has to read it
-- again. The four do the same four things in every row, in the same words:
--     open the work (and wares, where the row has a shop)  -> menu
--     ask about the island                                 -> about
--     ask about the character                              -> who
--     say goodbye                                          -> end
-- The wording is the same in every row, plainly: "Show me your jobs and shop."
-- (shopless rows say "Show me your jobs."), "Tell me about this island.",
-- "Tell me about yourself." and "Goodbye."
-- So nothing is ever more than one reply from the work, and `about`/`who` loop
-- back to the same four choices rather than leading anywhere new. Cycles are
-- therefore EXPECTED here (the old no-cycle rule is gone); what must hold is
-- that every node's choices are exactly the hub set, `next` is always a node in
-- this row or menu/end, no string contains a brace (tools/check_content.py
-- brace-walks these rows), pages stay under 130 characters and replies under
-- 45, so the typewriter renders one page without wrapping off the pane.
-- THE WRITING (user, 2026-09-12: "make the dialogue less complex in the actual
-- writing"). Plain, direct English. Every line states something the player
-- needs: who this is, what they do, what the island is, what the danger is,
-- what is on offer. No idioms, no dialect, no folksy sayings, no voice tics;
-- personality comes from the facts (a smith talks forge, a bookkeeper ledger)
-- plus at most one plain quirk per NPC. Sentences stay under 18 words.
--
-- `pose` is where the body stands and whether NpcService builds a seat under
-- it: a shopkeeper behind a counter STANDS (Maren, Brakk, Hollow, the
-- Ferryman, the Lampwright at his bench, Vess at the gutting stone, Cinder on
-- the hot apron), a hermit by a fire SITS on a stool/crate/bench/log. The
-- stand point does not move - the seat is built at the point
-- check_npc_placement verified, facing `facing` - and `seatColor` is taken
-- from that hut's own palette (the `*_Hut_*` MESH_COLOR rows in WorldService),
-- so the furniture reads as built out of the same wood as the shack.

local Npcs = {}

export type Look = {
	skin: Color3?,
	shirt: Color3?,
	sleeves: Color3?,
	pants: Color3?,
	hair: Color3?,
	hat: string?, -- "none" | "brim" | "hood" | "scarf" | "cap" | "tricorn" | "furhat" | "mask"
	hatColor: Color3?,
	height: number?, -- HumanoidDescription.HeightScale, 0.9 .. 1.15
	width: number?, -- WidthScale + DepthScale, 0.85 .. 1.2
}

export type Voice = {
	accept: string,
	done: string, -- "%s" = quest name
	notYet: string,
	missingGoods: string,
	busy: string, -- "%s" = quest name
	nothing: string,
	locked: string, -- "%s" = quest name, then "%d" = required level
	lockedPrereq: string, -- "%s" = the prereq quest's name
	shopOpen: string,
	shopBought: string, -- MUST begin with "There you go"
	shopShort: string,
	shopOwned: string,
	farewell: string, -- the farewell button's label, 2-4 words
}

export type Pose = {
	kind: string?, -- "sit" | "stand" (default "stand")
	seat: string?, -- "stool" | "crate" | "bench" | "log" | "none"
	seatColor: Color3?, -- the hut's own wood/stone, so the seat belongs there
}

-- One beat of a conversation: the NPC's pages, then the same four replies.
-- Choice text must SAY what it does - the player should never have to guess.
export type DialogueChoice = {
	text: string, -- a full sentence the player says, never a number
	next: string, -- a node id in this row's `nodes`, or "menu", or "end"
}

export type DialogueNode = {
	say: { string }, -- typewriter pages, in order
	choices: { DialogueChoice }?, -- the hub set: 4 replies, same order everywhere
}

export type Dialogue = {
	first: string, -- entry node for the first-ever meeting, always "open"
	again: string, -- entry node for every later meeting, always "hi"
	nodes: { [string]: DialogueNode }, -- exactly five: open, hub, about, who, hi
}

export type Npc = {
	id: string,
	name: string, -- nameplate + dialog title
	title: string, -- the line under the name ("Cove Fishwife")
	island: string, -- Islands.items key
	spawnOffset: Vector3, -- relative to the island's spawn point (Y ignored, probed)
	facing: number, -- yaw, degrees, world frame
	look: Look?, -- how the built figure is coloured and shaped
	greeting: { string }, -- paragraphs shown on the first talk of a session
	hello: { string }?, -- returning-visit lines, one picked at random
	voice: Voice?, -- the character's generic dialog vocabulary
	pose: Pose?, -- sit or stand, and the seat NpcService builds under them
	dialogue: Dialogue?, -- the flat five-node talk that runs before the menu opens
	quests: { string }?, -- Quests.luau ids, in offer order
	crafts: boolean?, -- true = this villager's menu carries the Craft tab (NpcService builds it)
	shop: string?, -- Shops.luau id
}

Npcs.items = {} :: { [string]: Npc }

-- Old Maren, the cove fishwife: the first voice in the game. She stands a
-- few steps from where every new player wakes up on the starter beach.
Npcs.items.old_maren = {
	id = "old_maren",
	name = "Old Maren",
	title = "Cove Fishwife",
	island = "tropical",
	-- The generator's own stand: island_gen.py prints "counter stand X=20.6
	-- Z=-55.0; Npcs.old_maren spawnOffset suggestion Vector3.new(21, 0, -5)
	-- facing 162" for the stilt shack (floor Y=5.6). She belongs BEHIND her
	-- counter, under the porch roof, facing out at the plaza she watches.
	-- That point used to put her on the roof 18 studs up, because
	-- NpcService.probeGroundY took the first hit of a ray from y=120 and the
	-- roof is the first thing over the counter. The probe now walks the whole
	-- column and stands her on the LOWEST standable floor with headroom, so it
	-- finds the porch deck at Y=5.56 under the fronds.
	--
	-- 2.1 studs along the porch from the generator's mark, not on it: at rel
	-- X=21 the shack's own front wall (Island_Hut_Walls, solid at runtime) runs
	-- through the body from the deck to Y=15 - check_npc_placement (c). Here the
	-- only thing the body touches is the counter itself (Island_Hut_Props, which
	-- WorldService makes pass-through), and she is 2.6 studs behind it, leaning
	-- over it at the plaza.
	spawnOffset = Vector3.new(18.6, 0, -5.5),
	facing = 162, -- behind the counter, shack at her back, angled at the spawn plaza she watches
	-- Sun-cured and salt-stained: faded red headscarf, linen sleeves rolled
	-- past the elbow, short and broad from forty years of hauling.
	look = {
		skin = Color3.fromRGB(206, 168, 132),
		shirt = Color3.fromRGB(168, 96, 72),
		sleeves = Color3.fromRGB(198, 184, 160),
		pants = Color3.fromRGB(86, 72, 58),
		hair = Color3.fromRGB(176, 170, 160),
		hat = "scarf",
		hatColor = Color3.fromRGB(196, 74, 66),
		height = 0.95,
		width = 1.05,
	},
	greeting = {
		"Hi, I'm Maren. I clean and sell fish here on Archway Cove.",
		"Every fish you catch will fight you. Hit it until it stops.",
		"I have jobs for you, and I sell gear at my stall.",
	},
	hello = {
		"Welcome back. What do you need?",
		"Good to see you. I have work if you want it.",
		"My stall is open. Have a look.",
	},
	voice = {
		accept = "Thanks. Come back when it's done.",
		done = "%s is done. Here's your reward.",
		notYet = "You haven't finished that job yet.",
		missingGoods = "You don't have the items I asked for.",
		busy = "You're still working on %s. Finish that first.",
		nothing = "I have no jobs for you right now.",
		locked = "%s needs level %d. Come back later.",
		lockedPrereq = "Finish %s first.",
		shopOpen = "Here is what I sell at the stall.",
		shopBought = "There you go.",
		shopShort = "You don't have enough coins.",
		shopOwned = "You already own that.",
		farewell = "See you.",
	},
	pose = {
		kind = "stand",
		seat = "none",
		seatColor = Color3.fromRGB(176, 125, 74), -- M_Plank, the counter she leans on - she works standing behind it
	},
	dialogue = {
		first = "open",
		again = "hi",
		nodes = {
			open = {
				say = {
					"Hi, I'm Maren. I clean and sell fish here on Archway Cove.",
					"Every fish here fights back when you reel it in. Hit it until it stops.",
					"If you want work, I have jobs for you. I also sell gear.",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hub = {
				say = {
					"What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			about = {
				say = {
					"Archway Cove is the first island, named for the stone arch on the beach. The water is warm and shallow and the fish are small.",
					"A big one called Brinejaw lives past the reef. You need bait to bring it up.",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			who = {
				say = {
					"I've worked this beach for forty years. I sell fish and I pay people to catch them.",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hi = {
				say = {
					"Welcome back. What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
		},
	},
	crafts = true, -- the Craft tab: this villager works a bench
	quests = { "marens_wager", "teeth_of_the_cove", "the_wider_water", "the_daily_haul" },
	shop = "marens_stall", -- Shops.luau id: the Browse-wares pane
}

-- Morra, the fen's bog-witch: quests in the murk.
Npcs.items.morra = {
	id = "morra",
	name = "Morra",
	title = "Bog-Witch of the Fen",
	island = "swamp",
	spawnOffset = Vector3.new(-20, 0, 2),
	facing = 258, -- in her dooryard where the plank path meets the hut
	-- Peat-dyed layers, a deep hood, and skin the colour of standing water.
	look = {
		skin = Color3.fromRGB(150, 166, 132),
		shirt = Color3.fromRGB(58, 74, 52),
		sleeves = Color3.fromRGB(46, 58, 44),
		pants = Color3.fromRGB(44, 50, 40),
		hat = "hood",
		hatColor = Color3.fromRGB(66, 84, 58),
		height = 0.98,
		width = 0.95,
	},
	greeting = {
		"Hi, I'm Morra. I make leather and charms here in Blackmire Fen.",
		"Stay on the plank paths. The mud is deep and it pulls you under.",
	},
	hello = {
		"Welcome back. What do you need?",
		"Good, the mud didn't get you. What do you want?",
		"Stay on the planks. Tell me what you need.",
	},
	voice = {
		accept = "Thanks. Come back when it's done.",
		done = "%s is done. Here's your reward.",
		notYet = "You haven't finished that job yet.",
		missingGoods = "You don't have the items I asked for.",
		busy = "You're still working on %s. Finish that first.",
		nothing = "I have no jobs for you right now.",
		locked = "%s needs level %d. Come back later.",
		lockedPrereq = "Finish %s first.",
		shopOpen = "Here is what I sell.",
		shopBought = "There you go.",
		shopShort = "You don't have enough coins.",
		shopOwned = "You already own that.",
		farewell = "See you.",
	},
	pose = {
		kind = "sit",
		seat = "stool",
		seatColor = Color3.fromRGB(66, 53, 40), -- M_RootWood, the hut's own stilts and floor - a root stool at the cauldron pit
	},
	dialogue = {
		first = "open",
		again = "hi",
		nodes = {
			open = {
				say = {
					"Hi, I'm Morra. I make leather and charms here in Blackmire Fen.",
					"Stay on the plank paths. The mud is deep and it pulls you under.",
					"If you want work, I have jobs for you.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hub = {
				say = {
					"What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			about = {
				say = {
					"Blackmire Fen is a swamp. You can fish the pools here for leeches, gators and swamp fish.",
					"A big one called Old Gnashroot sleeps under the mere. You need bait to wake it.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			who = {
				say = {
					"I live here and I cut hides. My sister drowned in this swamp, so I warn people about the mud.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hi = {
				say = {
					"Welcome back. What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
		},
	},
	crafts = true, -- the Craft tab: this villager works a bench
	quests = { "leech_tithe", "murk_harvest", "a_skin_for_the_mire" },
}

-- Halvard, the frost hermit of the Reach.
Npcs.items.halvard = {
	id = "halvard",
	name = "Halvard",
	title = "Frost Hermit",
	island = "ice",
	spawnOffset = Vector3.new(18, 0, -4),
	facing = 102, -- at the hull's door, out of the wind
	-- Bundled to twice his width, wind-bleached pale, under a shaggy fur hat.
	look = {
		skin = Color3.fromRGB(222, 206, 196),
		shirt = Color3.fromRGB(72, 84, 102),
		sleeves = Color3.fromRGB(96, 106, 120),
		pants = Color3.fromRGB(58, 62, 74),
		hat = "furhat",
		hatColor = Color3.fromRGB(108, 96, 84),
		height = 1.02,
		width = 1.15,
	},
	greeting = {
		"Hi, I'm Halvard. I fish through holes in the ice on Frostmaw Reach.",
		"Close the door behind you. The heat in here is all I have.",
	},
	hello = {
		"Welcome back. What do you need?",
		"Close the door. Then tell me what you want.",
		"My cache is open if you need supplies.",
	},
	voice = {
		accept = "Thanks. Come back when it's done.",
		done = "%s is done. Here's your reward.",
		notYet = "You haven't finished that job yet.",
		missingGoods = "You don't have the items I asked for.",
		busy = "You're still working on %s. Finish that first.",
		nothing = "I have no jobs for you right now.",
		locked = "%s needs level %d. Come back later.",
		lockedPrereq = "Finish %s first.",
		shopOpen = "Here is what I sell out of the cache.",
		shopBought = "There you go.",
		shopShort = "You don't have enough coins.",
		shopOwned = "You already own that.",
		farewell = "See you.",
	},
	pose = {
		kind = "sit",
		seat = "crate",
		seatColor = Color3.fromRGB(83, 62, 50), -- M_HutHull, the upturned boat he lives under - a crate by the firebox
	},
	dialogue = {
		first = "open",
		again = "hi",
		nodes = {
			open = {
				say = {
					"Hi, I'm Halvard. I fish through holes in the ice here on Frostmaw Reach.",
					"The ice is thin in places. Walk where I have already walked.",
					"If you want work, I have jobs for you. I also sell supplies.",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hub = {
				say = {
					"What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			about = {
				say = {
					"Frostmaw Reach is a sheet of ice over deep water. You fish it through holes you cut.",
					"A big one called Rimefang swims under the ice to the east. You need bait to bring it up.",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			who = {
				say = {
					"I came north with my brother. He went through the ice, so I stayed and kept the holes open.",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hi = {
				say = {
					"Welcome back. What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
		},
	},
	crafts = true, -- the Craft tab: this villager works a bench
	quests = { "pups_and_lines", "under_the_sheet" },
	shop = "halvards_cache",
}

-- Brakk, the ash-smith at the volcano's foot.
Npcs.items.brakk = {
	id = "brakk",
	name = "Brakk",
	title = "Cinder-Smith",
	island = "volcano",
	spawnOffset = Vector3.new(87, 0, -20),
	facing = 190, -- at the anvil counter on the forge's open face
	-- Soot to the elbows, a scorched leather mask pushed up on the brow,
	-- built like the anvil he stands behind.
	look = {
		skin = Color3.fromRGB(128, 96, 84),
		shirt = Color3.fromRGB(52, 44, 42),
		sleeves = Color3.fromRGB(86, 52, 38),
		pants = Color3.fromRGB(48, 42, 40),
		hat = "mask",
		hatColor = Color3.fromRGB(40, 36, 36),
		height = 0.9,
		width = 1.2,
	},
	greeting = {
		"Hi, I'm Brakk. I run the forge here in Ashfall Caldera.",
		"Stand back from the bellows. Everything on this rock is hot.",
	},
	hello = {
		"Welcome back. What do you need?",
		"The forge is hot. Tell me what you want.",
		"I have stock for sale if you need it.",
	},
	voice = {
		accept = "Thanks. Come back when it's done.",
		done = "%s is done. Here's your reward.",
		notYet = "You haven't finished that job yet.",
		missingGoods = "You don't have the items I asked for.",
		busy = "You're still working on %s. Finish that first.",
		nothing = "I have no jobs for you right now.",
		locked = "%s needs level %d. Come back later.",
		lockedPrereq = "Finish %s first.",
		shopOpen = "Here is what I sell from the forge.",
		shopBought = "There you go.",
		shopShort = "You don't have enough coins.",
		shopOwned = "You already own that.",
		farewell = "See you.",
	},
	pose = {
		kind = "stand",
		seat = "none",
		seatColor = Color3.fromRGB(68, 69, 74), -- M_ForgeIron, the anvil and racks - he works standing at the counter
	},
	dialogue = {
		first = "open",
		again = "hi",
		nodes = {
			open = {
				say = {
					"Hi, I'm Brakk. I run the forge here in Ashfall Caldera.",
					"Stand back from the bellows. Everything on this rock is hot enough to burn you.",
					"If you want work, I have jobs for you. I also sell forge stock.",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hub = {
				say = {
					"What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			about = {
				say = {
					"Ashfall Caldera is a volcano. The ponds are hot melt water and the fish come up cooked.",
					"A big one called Pyrelisk drinks the ponds dry. You need bait to call it out.",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			who = {
				say = {
					"I was a shop smith on the cove. I armed a crew that never came back, so I moved out here.",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hi = {
				say = {
					"Welcome back. What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
		},
	},
	crafts = true, -- the Craft tab: this villager works a bench
	quests = { "the_sulfur_toll", "lake_of_fire" },
	shop = "brakks_forge",
}

-- Keeper Lumen, the trench's half-mad lightkeeper.
Npcs.items.lumen = {
	id = "lumen",
	name = "Keeper Lumen",
	title = "Lightkeeper of the Trench",
	island = "gloom",
	spawnOffset = Vector3.new(-10, 0, 6),
	facing = 270, -- at the lighthouse door under his own light
	-- Thin as a wick, lamp-pale, keeper's cap, everything trimmed in the
	-- pale cyan of the light he will not let go out.
	look = {
		skin = Color3.fromRGB(214, 204, 196),
		shirt = Color3.fromRGB(48, 64, 74),
		sleeves = Color3.fromRGB(120, 196, 204),
		pants = Color3.fromRGB(40, 48, 58),
		hair = Color3.fromRGB(190, 186, 178),
		hat = "cap",
		hatColor = Color3.fromRGB(44, 74, 84),
		height = 1.1,
		width = 0.85,
	},
	greeting = {
		"Hi, I'm Lumen. I keep the lamp burning here at Gloomtrench.",
		"Stand beside the light, not in front of it. I need to see the water.",
	},
	hello = {
		"Welcome back. What do you need?",
		"The lamp is steady. Tell me what you want.",
		"I write down everything that lives out here. What do you need?",
	},
	voice = {
		accept = "Thanks. Come back when it's done.",
		done = "%s is done. I've written it down. Here's your reward.",
		notYet = "You haven't finished that job yet.",
		missingGoods = "You don't have the items I asked for.",
		busy = "You're still working on %s. Finish that first.",
		nothing = "I have no jobs for you right now.",
		locked = "%s needs level %d. Come back later.",
		lockedPrereq = "Finish %s first.",
		shopOpen = "Here is what I sell.",
		shopBought = "There you go.",
		shopShort = "You don't have enough coins.",
		shopOwned = "You already own that.",
		farewell = "See you.",
	},
	pose = {
		kind = "sit",
		seat = "stool",
		seatColor = Color3.fromRGB(59, 62, 76), -- M_GloomStalk, the desk and cot inside the tower - a stool at the log desk
	},
	dialogue = {
		first = "open",
		again = "hi",
		nodes = {
			open = {
				say = {
					"Hi, I'm Lumen. I keep the lamp burning here at Gloomtrench.",
					"The water goes dark nine feet down. You can't see what is below that.",
					"If you want work, I have jobs for you.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hub = {
				say = {
					"What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			about = {
				say = {
					"Gloomtrench is a deep trench with no light in it. Gulper eels circle my lamp at slack tide.",
					"A big one called Noctyss lives under the eels. You need bait to bring her up.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			who = {
				say = {
					"I keep the lamp and I count what lives out here. The last keeper gave me the job and left.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hi = {
				say = {
					"Welcome back. What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
		},
	},
	crafts = true, -- the Craft tab: this villager works a bench
	quests = { "what_the_dark_eats", "gullet_census", "a_veil_against_the_dark" },
}

-- Quartermaster Hollow, the ghost fleet's bookkeeper.
Npcs.items.hollow = {
	id = "hollow",
	name = "Quartermaster Hollow",
	title = "Of the Drowned Fleet",
	island = "wreck",
	-- island_gen.py, wreckwater: "counter X=-38 Z=164 top Y~5.2; suggested
	-- hollow spawnOffset Vector3.new(-39, 0, -1) facing 316 (island spawn X=0
	-- Z=167)". He stands behind the ledger desk, UNDER the sterncastle awning -
	-- the same cover that used to strand him on top of it, back when the
	-- placement probe took the first downward hit. It takes the lowest standable
	-- floor with headroom now, and finds the sand at Y=2.05 under the canvas.
	--
	-- The offset is NOT the -1 the line suggests: that line quotes an island
	-- spawn of rel Z=167, and Islands.luau has since moved the wreck landing to
	-- rel Z=178 (Z=167 stood the arriving player on Wreckwater_Bay). The stand
	-- the generator authored is rel Z=166, so the offset that reaches it is -12,
	-- and -1 now drops him 11 studs out onto the Wreckwater_Hulks. Backed off
	-- one more stud (rel X=-40 Z=167) because the counter plank lives in
	-- Wreckwater_Hut_Roof, which stays SOLID at runtime: at the authored stand it
	-- runs through his chest.
	spawnOffset = Vector3.new(-40, 0, -11),
	facing = 316, -- behind the ledger desk, ship at his back, facing over the counter at the breach
	-- Grey-green and long drowned, still in the coat and the tricorn he was
	-- issued, still holding the book.
	look = {
		skin = Color3.fromRGB(128, 150, 132),
		shirt = Color3.fromRGB(54, 52, 66),
		sleeves = Color3.fromRGB(44, 42, 54),
		pants = Color3.fromRGB(40, 40, 50),
		hat = "tricorn",
		hatColor = Color3.fromRGB(36, 34, 44),
		height = 1.05,
		width = 1.0,
	},
	greeting = {
		"Hi, I'm Hollow. I was quartermaster of the Sixth Fleet, here at Wreckwater.",
		"I keep the ledger and the supply locker. Both are open to you.",
	},
	hello = {
		"Welcome back. What do you need?",
		"The book is open. Tell me what you want.",
		"The locker is open if you need supplies.",
	},
	voice = {
		accept = "Thanks. I've entered it in the book. Come back when it's done.",
		done = "%s is done. I've struck it from the book. Here's your reward.",
		notYet = "You haven't finished that job yet.",
		missingGoods = "You don't have the items I asked for.",
		busy = "You're still working on %s. Finish that first.",
		nothing = "I have no jobs for you right now.",
		locked = "%s needs level %d. Come back later.",
		lockedPrereq = "Finish %s first.",
		shopOpen = "Here is what I sell from the locker.",
		shopBought = "There you go.",
		shopShort = "You don't have enough coins.",
		shopOwned = "You already own that.",
		farewell = "See you.",
	},
	pose = {
		kind = "stand",
		seat = "none",
		seatColor = Color3.fromRGB(84, 69, 52), -- M_WreckPost, the ledger desk and crates - he stands at the counter, as issued
	},
	dialogue = {
		first = "open",
		again = "hi",
		nodes = {
			open = {
				say = {
					"Hi, I'm Hollow. I was quartermaster of the Sixth Fleet, here at Wreckwater.",
					"Forty-one wrecked ships sit in this bay. Crabs are eating the stores in them.",
					"If you want work, I have jobs for you. I also sell from the locker.",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hub = {
				say = {
					"What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			about = {
				say = {
					"Wreckwater is a bay full of wrecked ships. You can fish it and salvage from the hulls.",
					"Admiral Wrack is on the flagship at the far end of the bay. He fights anyone who boards.",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			who = {
				say = {
					"I kept the fleet's books. The fleet sank and I did not, so I still keep them.",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hi = {
				say = {
					"Welcome back. What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
		},
	},
	shop = "hollows_locker", -- Shops.luau id: the fleet's salvage, armor included
	crafts = true, -- the Craft tab: this villager works a bench
	quests = { "ledger_of_teeth", "salvage_rights" },
}

-- ============================================================ the islet folk
-- One resident per islet. They are the only people out here, and every one of
-- them lives off the water: the story's moral is carried by what they DO, and
-- none of them ever says it. Their `spawnOffset` is a SMALL step (2-3 studs)
-- off the islet's `spawn`, not zero: `spawn` is both the flat pad the builder
-- measured AND the point WorldService.islandLanding drops the arriving player
-- on, so a zero offset materialised every visitor inside the resident. The
-- step is under 3 studs (so the row still stands on the measured pad) and is
-- taken OPPOSITE `facing`, so the islander is looking at whoever arrives.

Npcs.items.nettle = {
	id = "nettle",
	name = "Nettle",
	title = "Of the Bell Rock",
	island = "bellbuoy",
	spawnOffset = Vector3.new(-2, 0, -0.5),
	facing = 250, -- back to the bell, watching the water it drives things out of
	-- Small, wiry, brass-yellow oilskin the colour of the bell she lives
	-- under, rust-red hair the wind has given up on.
	look = {
		skin = Color3.fromRGB(198, 164, 128),
		shirt = Color3.fromRGB(188, 170, 86),
		sleeves = Color3.fromRGB(120, 110, 96),
		pants = Color3.fromRGB(72, 68, 60),
		hair = Color3.fromRGB(156, 84, 52),
		hat = "none",
		height = 0.9,
		width = 0.9,
	},
	greeting = {
		"Hi, I'm Nettle. I live on this rock under the bell.",
		"The swell rings the bell all day. You get used to the noise.",
	},
	hello = {
		"Welcome back. What do you need?",
		"Still loud out here. Tell me what you want.",
		"Not many people stop here. What do you need?",
	},
	voice = {
		accept = "Thanks. Come back when it's done.",
		done = "%s is done. Here's your reward.",
		notYet = "You haven't finished that job yet.",
		missingGoods = "You don't have the items I asked for.",
		busy = "You're still working on %s. Finish that first.",
		nothing = "I have no jobs for you right now.",
		locked = "%s needs level %d. Come back later.",
		lockedPrereq = "Finish %s first.",
		shopOpen = "Here is what I sell.",
		shopBought = "There you go.",
		shopShort = "You don't have enough coins.",
		shopOwned = "You already own that.",
		farewell = "See you.",
	},
	pose = {
		kind = "sit",
		seat = "crate",
		seatColor = Color3.fromRGB(102, 83, 60), -- M_BellPlank, the dinghy and salvage on her bench - a plank crate under the bell
	},
	dialogue = {
		first = "open",
		again = "hi",
		nodes = {
			open = {
				say = {
					"Hi, I'm Nettle. I live on this rock under the bell.",
					"The swell rings the bell all day. The noise draws things up out of the water.",
					"If you want work, I have jobs for you.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hub = {
				say = {
					"What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			about = {
				say = {
					"The Bellbuoy is a small rock with a large bell on it. The swell rings it day and night.",
					"Drowned deckhands come ashore to hear the bell. They attack anyone on the rock.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			who = {
				say = {
					"I watch this rock and keep the bell clear. My father's boat wrecked near here.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hi = {
				say = {
					"Welcome back. What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
		},
	},
	quests = { "what_the_bell_brings" },
}

Npcs.items.bellkeeper_odd = {
	id = "bellkeeper_odd",
	name = "Bellkeeper Odd",
	title = "Of the Drowned Chapel",
	island = "chapel",
	spawnOffset = Vector3.new(-0.5, 0, 2),
	facing = 300, -- facing the tower he climbs, back to the open water
	-- Grey wool gone green at the hem from the climb, a hood he never puts
	-- down, a face the colour of the stone he lives in.
	look = {
		skin = Color3.fromRGB(162, 166, 150),
		shirt = Color3.fromRGB(66, 62, 58),
		sleeves = Color3.fromRGB(54, 50, 48),
		pants = Color3.fromRGB(48, 46, 44),
		hat = "hood",
		hatColor = Color3.fromRGB(72, 68, 62),
		height = 1.05,
		width = 0.95,
	},
	greeting = {
		"Hi, I'm Odd. I ring the bell here at the Drowned Chapel.",
		"Mind the hole in the roof. It is the only way in and out.",
	},
	hello = {
		"Welcome back. What do you need?",
		"It isn't the hour yet. Tell me what you want.",
		"Mind the hole in the roof. What do you need?",
	},
	voice = {
		accept = "Thanks. Come back when it's done.",
		done = "%s is done. Here's your reward.",
		notYet = "You haven't finished that job yet.",
		missingGoods = "You don't have the items I asked for.",
		busy = "You're still working on %s. Finish that first.",
		nothing = "I have no jobs for you right now.",
		locked = "%s needs level %d. Come back later.",
		lockedPrereq = "Finish %s first.",
		shopOpen = "Here is what I sell.",
		shopBought = "There you go.",
		shopShort = "You don't have enough coins.",
		shopOwned = "You already own that.",
		farewell = "See you.",
	},
	pose = {
		kind = "sit",
		seat = "bench",
		seatColor = Color3.fromRGB(103, 74, 47), -- M_ChapTimber, his lean-to and the bell frame - a pew bench off the drowned nave
	},
	dialogue = {
		first = "open",
		again = "hi",
		nodes = {
			open = {
				say = {
					"Hi, I'm Odd. I ring the bell here at the Drowned Chapel.",
					"Mind the hole in the roof. It is the only way in and out.",
					"If you want work, I have jobs for you.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hub = {
				say = {
					"What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			about = {
				say = {
					"The Drowned Chapel is a sunken village. Only the chapel roof is still above water.",
					"A fish called the Tollmaw swallowed my bell clapper. It still swims below the nave.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			who = {
				say = {
					"I ring the bell on the hour for the village that drowned here. Nobody else is left.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hi = {
				say = {
					"Welcome back. What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
		},
	},
	crafts = true, -- the Craft tab: this villager works a bench
	quests = { "odds_toll", "the_tollmaw_hunt", "the_bellringer" },
}

Npcs.items.pip = {
	id = "pip",
	name = "Pip",
	title = "Egg-Picker",
	island = "rookery",
	spawnOffset = Vector3.new(-0.5, 0, -2),
	facing = 180,
	-- Young, quick, in a guano-white smock nothing will ever get clean and a
	-- flat cap kept on for the obvious reason.
	look = {
		skin = Color3.fromRGB(216, 178, 140),
		shirt = Color3.fromRGB(222, 216, 204),
		sleeves = Color3.fromRGB(140, 150, 158),
		pants = Color3.fromRGB(78, 84, 70),
		hair = Color3.fromRGB(208, 170, 92),
		hat = "cap",
		hatColor = Color3.fromRGB(168, 158, 140),
		height = 0.9,
		width = 0.9,
	},
	greeting = {
		"Hi, I'm Pip. I pick gull eggs off the ledges here.",
		"Keep your cap on. The gulls dive at anyone who looks up.",
	},
	hello = {
		"Welcome back. What do you need?",
		"Cap on, please. Then tell me what you want.",
		"The ledges are noisy today. What do you need?",
	},
	voice = {
		accept = "Thanks. Come back when it's done.",
		done = "%s is done. Here's your reward.",
		notYet = "You haven't finished that job yet.",
		missingGoods = "You don't have the items I asked for.",
		busy = "You're still working on %s. Finish that first.",
		nothing = "I have no jobs for you right now.",
		locked = "%s needs level %d. Come back later.",
		lockedPrereq = "Finish %s first.",
		shopOpen = "Here is what I sell.",
		shopBought = "There you go.",
		shopShort = "You don't have enough coins.",
		shopOwned = "You already own that.",
		farewell = "See you.",
	},
	pose = {
		kind = "sit",
		seat = "crate",
		seatColor = Color3.fromRGB(81, 66, 49), -- M_RookBeam, the eyrie's stilts and beams - he perches on an egg crate
	},
	dialogue = {
		first = "open",
		again = "hi",
		nodes = {
			open = {
				say = {
					"Hi, I'm Pip. I pick gull eggs off the ledges on the Rookery Stack.",
					"Keep your cap on. The gulls dive at anyone who looks up at them.",
					"If you want work, I have jobs for you.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hub = {
				say = {
					"What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			about = {
				say = {
					"The Rookery Stack is two rock stacks joined by an arch. Thousands of gulls nest on it.",
					"The loud gulls at the top set off the whole ledge. They attack people on the rocks.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			who = {
				say = {
					"I climb the ledges and crate the eggs. A boat picks the crates up every few weeks.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hi = {
				say = {
					"Welcome back. What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
		},
	},
	quests = { "the_parliament" },
}

Npcs.items.cinder = {
	id = "cinder",
	name = "Cinder",
	title = "Of the Boiling Shoal",
	island = "boilshoal",
	spawnOffset = Vector3.new(0, 0, -2),
	facing = 180, -- looking back over the vents
	-- Obsidian-black wrap, ember-orange sleeves, a wide brim against the
	-- steam, and skin scorched to a hard red-brown.
	look = {
		skin = Color3.fromRGB(166, 112, 86),
		shirt = Color3.fromRGB(44, 38, 44),
		sleeves = Color3.fromRGB(188, 88, 44),
		pants = Color3.fromRGB(40, 36, 40),
		hat = "brim",
		hatColor = Color3.fromRGB(58, 48, 44),
		height = 1.0,
		width = 1.0,
	},
	greeting = {
		"Hi, I'm Cinder. I fish the hot water here on the Boiling Shoal.",
		"Stay on my side of that line. The crust is thin over boiling water.",
	},
	hello = {
		"Welcome back. What do you need?",
		"Stay on the hot side with me. What do you want?",
		"The steam is up today. Tell me what you need.",
	},
	voice = {
		accept = "Thanks. Come back when it's done.",
		done = "%s is done. Here's your reward.",
		notYet = "You haven't finished that job yet.",
		missingGoods = "You don't have the items I asked for.",
		busy = "You're still working on %s. Finish that first.",
		nothing = "I have no jobs for you right now.",
		locked = "%s needs level %d. Come back later.",
		lockedPrereq = "Finish %s first.",
		shopOpen = "Here is what I sell.",
		shopBought = "There you go.",
		shopShort = "You don't have enough coins.",
		shopOwned = "You already own that.",
		farewell = "See you.",
	},
	pose = {
		kind = "stand",
		seat = "none",
		seatColor = Color3.fromRGB(77, 62, 52), -- M_ShoalTimber, the bath-house frame - she works standing on the hot apron
	},
	dialogue = {
		first = "open",
		again = "hi",
		nodes = {
			open = {
				say = {
					"Hi, I'm Cinder. I fish the hot water here on the Boiling Shoal.",
					"That line at your boot is thin crust over boiling water. Don't step past it.",
					"If you want work, I have jobs for you.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hub = {
				say = {
					"What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			about = {
				say = {
					"The Boiling Shoal is black glass around a hot lagoon. The best fish live in the hot water.",
					"The fish here come up hot and angry. The cold water holds almost nothing.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			who = {
				say = {
					"I ran a bath house on the cove and it burned down. Now I warn people where the hot line is.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hi = {
				say = {
					"Welcome back. What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
		},
	},
	quests = { "what_bites_in_boiling_water" },
}

Npcs.items.lampwright = {
	id = "lampwright",
	name = "The Lampwright",
	title = "Who Made the Trench Lamp",
	island = "lampwork",
	spawnOffset = Vector3.new(2.5, 0, 1.5),
	facing = 90, -- at his bench, the open forge side toward the water
	-- Brass-sleeved work coat, a bench brim to keep the sparks out of his
	-- eyes, hair gone the grey of cold solder.
	look = {
		skin = Color3.fromRGB(200, 164, 128),
		shirt = Color3.fromRGB(92, 74, 56),
		sleeves = Color3.fromRGB(154, 124, 72),
		pants = Color3.fromRGB(62, 54, 46),
		hair = Color3.fromRGB(128, 120, 110),
		hat = "brim",
		hatColor = Color3.fromRGB(76, 62, 48),
		height = 1.0,
		width = 1.05,
	},
	greeting = {
		"Hi, they call me the Lampwright. I build lamps here in my workshop.",
		"Eighteen lamps stand in the yard. I don't light any of them now.",
	},
	hello = {
		"Welcome back. What do you need?",
		"The bench is busy. Tell me what you want.",
		"The shutters stay closed. What do you need?",
	},
	voice = {
		accept = "Thanks. Come back when it's done.",
		done = "%s is done. Here's your reward.",
		notYet = "You haven't finished that job yet.",
		missingGoods = "You don't have the items I asked for.",
		busy = "You're still working on %s. Finish that first.",
		nothing = "I have no jobs for you right now.",
		locked = "%s needs level %d. Come back later.",
		lockedPrereq = "Finish %s first.",
		shopOpen = "Here is what I sell.",
		shopBought = "There you go.",
		shopShort = "You don't have enough coins.",
		shopOwned = "You already own that.",
		farewell = "See you.",
	},
	pose = {
		kind = "stand",
		seat = "none",
		seatColor = Color3.fromRGB(83, 66, 52), -- M_LampTimber, the workshop's beams - he stands at the bench, working
	},
	dialogue = {
		first = "open",
		again = "hi",
		nodes = {
			open = {
				say = {
					"Hi, they call me the Lampwright. I build lamps here in my workshop.",
					"Eighteen lamps stand in the yard and I don't light them. Light draws things up.",
					"If you want work, I have jobs for you.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hub = {
				say = {
					"What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			about = {
				say = {
					"The workshop sits on a shelf of rock above the trench. The drop starts nine feet out.",
					"A fish called the Moth of the Deep circles this shelf. It came up for the lamp I built.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			who = {
				say = {
					"I made the lamp on the trench tower. I stopped lighting lamps after I saw what they draw.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hi = {
				say = {
					"Welcome back. What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
		},
	},
	crafts = true, -- the Craft tab: this villager works a bench
	quests = { "every_lamp_dark", "the_moth_hunt", "the_lampwrights_line" },
}

Npcs.items.coil = {
	id = "coil",
	name = "Coil",
	title = "Salvor",
	island = "anchorage",
	spawnOffset = Vector3.new(-1.2, 0, -1.8),
	facing = 210,
	-- Rope-coloured canvas, rust to the elbows, a flat cap flattened further
	-- by a life of ducking under chain.
	look = {
		skin = Color3.fromRGB(176, 150, 124),
		shirt = Color3.fromRGB(96, 88, 76),
		sleeves = Color3.fromRGB(128, 84, 52),
		pants = Color3.fromRGB(60, 58, 54),
		hat = "cap",
		hatColor = Color3.fromRGB(84, 78, 68),
		height = 1.05,
		width = 1.0,
	},
	greeting = {
		"Hi, I'm Coil. I salvage what I can find here in the Anchor Garden.",
		"Watch your shins. Two dozen old anchors stand in this sand.",
	},
	hello = {
		"Welcome back. What do you need?",
		"Watch the anchors. Tell me what you want.",
		"I'm still counting chains. What do you need?",
	},
	voice = {
		accept = "Thanks. Come back when it's done.",
		done = "%s is done. Here's your reward.",
		notYet = "You haven't finished that job yet.",
		missingGoods = "You don't have the items I asked for.",
		busy = "You're still working on %s. Finish that first.",
		nothing = "I have no jobs for you right now.",
		locked = "%s needs level %d. Come back later.",
		lockedPrereq = "Finish %s first.",
		shopOpen = "Here is what I sell.",
		shopBought = "There you go.",
		shopShort = "You don't have enough coins.",
		shopOwned = "You already own that.",
		farewell = "See you.",
	},
	pose = {
		kind = "sit",
		seat = "crate",
		seatColor = Color3.fromRGB(152, 118, 79), -- M_AnchPlank, the salvage shack's planking - a crate in the shade of the stock
	},
	dialogue = {
		first = "open",
		again = "hi",
		nodes = {
			open = {
				say = {
					"Hi, I'm Coil. I salvage what I can find here in the Anchor Garden.",
					"Two dozen old anchors stand in the sand. Twenty-three of the chains hang slack.",
					"If you want work, I have jobs for you.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hub = {
				say = {
					"What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			about = {
				say = {
					"The Anchor Garden is a shallow sand flat full of old anchors. You can wade out and fish the reef.",
					"One chain has been taut for four years. Something is holding it and I won't pull on it.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			who = {
				say = {
					"I salvage wrecks and count what is left here. I touched that taut chain once and it moved.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hi = {
				say = {
					"Welcome back. What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
		},
	},
	quests = { "the_taut_chain" },
}

Npcs.items.saltmother_vess = {
	id = "saltmother_vess",
	name = "Saltmother Vess",
	title = "Of the Whale Fall",
	island = "whalefall",
	spawnOffset = Vector3.new(-1.5, 0, -1.4),
	facing = 200, -- at the carcass, working
	-- Bone-pale gutting apron over oilskin, hair salt-white, a scarf tied
	-- against the smell she says isn't on her.
	look = {
		skin = Color3.fromRGB(188, 158, 130),
		shirt = Color3.fromRGB(176, 168, 150),
		sleeves = Color3.fromRGB(94, 78, 64),
		pants = Color3.fromRGB(58, 52, 46),
		hair = Color3.fromRGB(150, 146, 140),
		hat = "scarf",
		hatColor = Color3.fromRGB(110, 100, 88),
		height = 1.0,
		width = 1.05,
	},
	greeting = {
		"Hi, I'm Vess. I gut and clean fish here at the Whale Fall.",
		"Watch your feet. The sand is packed with whale ribs.",
	},
	hello = {
		"Welcome back. What do you need?",
		"The stone is wet. Tell me what you want.",
		"Watch your feet on the ribs. What do you need?",
	},
	voice = {
		accept = "Thanks. Come back when it's done.",
		done = "%s is done. Here's your reward.",
		notYet = "You haven't finished that job yet.",
		missingGoods = "You don't have the items I asked for.",
		busy = "You're still working on %s. Finish that first.",
		nothing = "I have no jobs for you right now.",
		locked = "%s needs level %d. Come back later.",
		lockedPrereq = "Finish %s first.",
		shopOpen = "Here is what I sell.",
		shopBought = "There you go.",
		shopShort = "You don't have enough coins.",
		shopOwned = "You already own that.",
		farewell = "See you.",
	},
	pose = {
		kind = "stand",
		seat = "none",
		seatColor = Color3.fromRGB(109, 101, 88), -- M_WhaleDrift, the camp's driftwood - she works standing at the gutting stone
	},
	dialogue = {
		first = "open",
		again = "hi",
		nodes = {
			open = {
				say = {
					"Hi, I'm Vess. I gut and clean fish here at the Whale Fall.",
					"Watch your feet. The sand is packed with whale ribs and it is slick.",
					"If you want work, I have jobs for you.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hub = {
				say = {
					"What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			about = {
				say = {
					"The Whale Fall is a sandbar around a whale skeleton. The bones draw fish, so it fishes well.",
					"A fish called Old Ribbonjaw works my stone at night. It stole the whetstone out of it.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			who = {
				say = {
					"I clean fish on this stone and waste nothing. The whale brought the best fishing I have had.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hi = {
				say = {
					"Welcome back. What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
		},
	},
	crafts = true, -- the Craft tab: this villager works a bench
	quests = { "the_gutting_stone", "the_ribbonjaw_hunt", "the_ribboncutter" },
}

Npcs.items.ferryman = {
	id = "ferryman",
	name = "The Ferryman",
	title = "Of No Harbour",
	island = "ferryraft",
	spawnOffset = Vector3.new(-2.5, 0, -7),
	facing = 250, -- behind his counter, facing whoever ties up (270 put his nose 2.5 studs into the cabin)
	-- A deep-violet hooded coat kept far too well for a man living on a
	-- raft, because the coat is part of the pitch.
	look = {
		skin = Color3.fromRGB(192, 152, 116),
		shirt = Color3.fromRGB(74, 64, 96),
		sleeves = Color3.fromRGB(60, 52, 80),
		pants = Color3.fromRGB(48, 44, 60),
		hat = "hood",
		hatColor = Color3.fromRGB(66, 58, 86),
		height = 1.05,
		width = 1.0,
	},
	greeting = {
		"Hi, they call me the Ferryman. I sell supplies from this raft.",
		"The nearest land is three thousand studs away. I am the only stop out here.",
	},
	hello = {
		"Welcome back. What do you need?",
		"Tied up again. The counter is open.",
		"I have stock for sale. Have a look.",
	},
	voice = {
		accept = "Thanks. Come back when it's done.",
		done = "%s is done. Here's your reward.",
		notYet = "You haven't finished that job yet.",
		missingGoods = "You don't have the items I asked for.",
		busy = "You're still working on %s. Finish that first.",
		nothing = "I have no jobs for you right now.",
		locked = "%s needs level %d. Come back later.",
		lockedPrereq = "Finish %s first.",
		shopOpen = "Here is what I sell off the raft.",
		shopBought = "There you go.",
		shopShort = "You don't have enough coins.",
		shopOwned = "You already own that.",
		farewell = "Goodbye for now.",
	},
	pose = {
		kind = "stand",
		seat = "none",
		seatColor = Color3.fromRGB(121, 101, 75), -- M_RaftPlank, the counter and bridges - the pitch does not work sitting down
	},
	dialogue = {
		first = "open",
		again = "hi",
		nodes = {
			open = {
				say = {
					"Hi, they call me the Ferryman. I sell supplies from this raft.",
					"The nearest land is three thousand studs away. I am the only stop out here.",
					"I have one job for you, and I sell supplies.",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hub = {
				say = {
					"What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			about = {
				say = {
					"The raft sits in the middle of the longest crossing. Ice is north and the swamp is south.",
					"There is no island here, just my raft and open water. Every boat passes close by.",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			who = {
				say = {
					"I ran a shop in a busy harbour and left. Out here I have no competition at all.",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hi = {
				say = {
					"Welcome back. What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs and shop.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
		},
	},
	quests = { "the_long_way_round" },
	shop = "ferrymans_stock", -- Shops.luau id: what "my counter is open" pays out
}

Npcs.items.ansel = {
	id = "ansel",
	name = "Ansel",
	title = "Struck Twice",
	island = "loadstone",
	spawnOffset = Vector3.new(-2.5, 0, 0.5),
	facing = 270, -- back to the spire, which he does not look at
	-- Storm-lilac wool with every buckle cut off it, hair permanently on
	-- end, nothing metal anywhere about him.
	look = {
		skin = Color3.fromRGB(214, 186, 150),
		shirt = Color3.fromRGB(156, 150, 196),
		sleeves = Color3.fromRGB(120, 116, 152),
		pants = Color3.fromRGB(56, 54, 66),
		hair = Color3.fromRGB(224, 220, 208),
		hat = "none",
		height = 1.0,
		width = 0.9,
	},
	greeting = {
		"Hi, I'm Ansel. I live on this rock under the Loadstone Spire.",
		"Please don't bring metal near me. Lightning has hit me twice.",
	},
	hello = {
		"Welcome back. What do you need?",
		"Please keep metal away from me. What do you want?",
		"No lightning today. Tell me what you need.",
	},
	voice = {
		accept = "Thanks. Come back when it's done.",
		done = "%s is done. Here's your reward.",
		notYet = "You haven't finished that job yet.",
		missingGoods = "You don't have the items I asked for.",
		busy = "You're still working on %s. Finish that first.",
		nothing = "I have no jobs for you right now.",
		locked = "%s needs level %d. Come back later.",
		lockedPrereq = "Finish %s first.",
		shopOpen = "Here is what I sell.",
		shopBought = "There you go.",
		shopShort = "You don't have enough coins.",
		shopOwned = "You already own that.",
		farewell = "See you.",
	},
	pose = {
		kind = "sit",
		seat = "stool",
		seatColor = Color3.fromRGB(109, 88, 64), -- M_LoadPlank, his shack's planking - a plank stool, nothing metal in it
	},
	dialogue = {
		first = "open",
		again = "hi",
		nodes = {
			open = {
				say = {
					"Hi, I'm Ansel. I live on this rock under the Loadstone Spire.",
					"Please don't bring metal near me. Lightning has hit me twice on this rock.",
					"If you want work, I have jobs for you.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hub = {
				say = {
					"What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			about = {
				say = {
					"The Loadstone Spire is eight glass needles that pull the storm down. Your compass fails here.",
					"Lightning only ever hits the spire. Stay off it and the rest of the rock is safe.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			who = {
				say = {
					"I fish this rock and warn people about the storm. Lightning hit me here twice.",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
			hi = {
				say = {
					"Welcome back. What would you like to do?",
				},
				choices = {
					{ text = "Show me your jobs.", next = "menu" },
					{ text = "Tell me about this island.", next = "about" },
					{ text = "Tell me about yourself.", next = "who" },
					{ text = "Goodbye.", next = "end" },
				},
			},
		},
	},
	quests = { "struck_twice" },
}

return Npcs

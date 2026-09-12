"""cues.py - the SFX registry. Every cue name in the game lives here.

WHY THE NAMES ARE DECLARED BEFORE THEY ARE IMPLEMENTED. The cue name is a
contract between four places: CONTRACT.md, this registry, the generated
`SoundSprites.luau`, and the `Sfx.play("...")` call sites. A name that
exists in three of them and not the fourth fails SILENTLY - the sound just
does not play, and nobody notices until someone happens to fish at night on
the ice island. So every name from CONTRACT.md §3 is DECLARED here up
front with `render=None`; `build.py --check` then reports exactly which
declared cues have no render function yet, and a category module written by
another agent implements against a name that is already fixed rather than
one it invented.

Adding a sound is therefore never "add a name" - the name is already here.
It is: write the render function in `sfx_<sheet>.py` and decorate it.

    from cues import cue
    import synth as S

    @cue("bobberPlop", "fishing")
    def bobber_plop(r):
        return S.splash(0.30, r, low=900, high=9000)

RULES FOR A RENDER FUNCTION
* signature `fn(rng) -> mono float array`, or `fn(rng, index)` if the cue
  has variants (index is 0-based).
* use ONLY the `rng` you are handed. It is seeded from the cue name, so
  your cue renders identically no matter what ran before it.
* do not normalise or fade - `build.py` limits, peak-normalises to -1 dBFS
  and applies 3 ms edge fades to every cue on its way into the sheet.
* keep it tight: most SFX 0.1-1.5 s, stingers up to 3 s. A sheet is one
  OGG the client seeks into; every extra second is download for everyone.

VARIANTS vs VOICES - two different things that look alike.
* `variants=4` on `stepSand` registers `stepSand1..stepSand4`, four
  separate cues; the client picks one at random so a footstep does not
  machine-gun.
* `bossSlam__pyrelisk` is a VOICE variant: an ordinary cue, registered on
  that boss's own sheet, that the client substitutes for `bossSlam` while
  the Pyrelisk voice is active. Missing voice -> the base cue plays. They
  live on the boss's sheet, not on boss_shared, so a fight loads one sheet.
"""

import inspect

__all__ = ["Cue", "cue", "declare", "all", "by_sheet", "sheets", "missing",
           "implemented", "get", "SHEETS", "BOSS_VOICES"]

# Sheet order fixes the order of the OGG files and of the manifest; it is
# stable so that a sheet's cue offsets only move when that sheet changes.
SHEETS = [
    "fishing", "boat", "character", "combat", "ui", "progression", "world",
    "creatures", "families", "boss_shared", "boss_brinejaw", "boss_gnashroot",
    "boss_rimefang", "boss_pyrelisk", "boss_noctyss", "boss_wrack",
    "boss_kraken",
]

# voice suffix -> the sheet its variants live on.
BOSS_VOICES = {
    "brinejaw": "boss_brinejaw",
    "old_gnashroot": "boss_gnashroot",
    "rimefang": "boss_rimefang",
    "pyrelisk": "boss_pyrelisk",
    "noctyss": "boss_noctyss",
    "admiral_wrack": "boss_wrack",
    "kraken": "boss_kraken",
}

# The boss cues that get a per-voice variant (CONTRACT §3 sfx_boss_shared).
VOICED_BOSS_CUES = ["bossTell", "bossRise", "bossRoar", "bossSnap", "bossSlam",
                    "bossDown", "bossStagger"]

FAMILIES = ["smallFish", "bigFish", "spiny", "crustacean", "eel", "jelly",
            "blob", "wing", "burrower", "mimic", "undead", "elemental",
            "mechanical", "flora"]


class Cue(object):
    """One registered cue. `render` is None until a module implements it."""

    __slots__ = ("name", "sheet", "loop", "desc", "spatial", "render",
                 "variant_of", "variant_index", "order", "module")

    def __init__(self, name, sheet, loop=False, desc="", spatial="2D",
                 variant_of=None, variant_index=0, order=0):
        self.name = name
        self.sheet = sheet
        self.loop = bool(loop)
        self.desc = desc
        self.spatial = spatial
        self.render = None
        # The module that implemented it - build.py keys its cache on that
        # module's source hash, so editing one category re-renders only it.
        self.module = None
        self.variant_of = variant_of
        self.variant_index = variant_index
        self.order = order

    def __repr__(self):
        return "<Cue %s sheet=%s%s%s>" % (
            self.name, self.sheet, " loop" if self.loop else "",
            "" if self.render else " UNIMPLEMENTED")


_REGISTRY = {}
_ORDER = [0]


def _register(name, sheet, loop=False, desc="", spatial="2D",
              variant_of=None, variant_index=0):
    if sheet not in SHEETS:
        raise ValueError("cue %r: unknown sheet %r" % (name, sheet))
    if name in _REGISTRY:
        return _REGISTRY[name]
    _ORDER[0] += 1
    c = Cue(name, sheet, loop, desc, spatial, variant_of, variant_index, _ORDER[0])
    _REGISTRY[name] = c
    return c


def declare(name, sheet, loop=False, variants=1, desc="", spatial="2D"):
    """Declare a cue (or a variant family) with no render function yet."""
    if variants > 1:
        made = []
        for i in range(int(variants)):
            made.append(_register("%s%d" % (name, i + 1), sheet, loop, desc,
                                  spatial, variant_of=name, variant_index=i))
        return made
    return _register(name, sheet, loop, desc, spatial)


def cue(name, sheet=None, loop=None, variants=1, desc="", spatial=None):
    """Decorator: attach a render function to a (usually already declared) cue.

    Anything left as None inherits from the declaration, so a category
    module does not have to restate the loop flag or the 2D/3D intent and
    cannot silently contradict CONTRACT.md by getting one wrong.
    """
    def wrap(fn):
        takes_index = len(inspect.signature(fn).parameters) >= 2
        names = ["%s%d" % (name, i + 1) for i in range(variants)] if variants > 1 else [name]
        for i, cue_name in enumerate(names):
            existing = _REGISTRY.get(cue_name)
            if existing is None:
                if sheet is None:
                    raise ValueError(
                        "cue %r is not declared and @cue gave no sheet - add it "
                        "to CONTRACT.md and to the declarations in cues.py first"
                        % cue_name)
                existing = _register(cue_name, sheet, bool(loop), desc, spatial or "2D",
                                     variant_of=name if variants > 1 else None,
                                     variant_index=i)
            if sheet is not None and existing.sheet != sheet:
                raise ValueError("cue %r declared on sheet %r but @cue says %r"
                                 % (cue_name, existing.sheet, sheet))
            if loop is not None:
                existing.loop = bool(loop)
            if spatial is not None:
                existing.spatial = spatial
            if desc:
                existing.desc = desc
            existing.render = (lambda f=fn, idx=i: (lambda r: f(r, idx)))() if takes_index else fn
            existing.module = fn.__module__
        return fn
    return wrap


# -- queries -----------------------------------------------------------------

def all():  # noqa: A001 - the name reads right at the call site (`cues.all()`)
    """Every cue, in registration order."""
    return sorted(_REGISTRY.values(), key=lambda c: c.order)


def get(name):
    return _REGISTRY.get(name)


def by_sheet(sheet):
    """Every cue on `sheet`, in registration order - this IS the sheet layout."""
    return [c for c in all() if c.sheet == sheet]


def sheets():
    """Sheets that actually have cues, in SHEETS order."""
    return [s for s in SHEETS if by_sheet(s)]


def missing():
    """Declared but not implemented. What `build.py --check` reports."""
    return [c for c in all() if c.render is None]


def implemented():
    return [c for c in all() if c.render is not None]


# ===========================================================================
# DECLARATIONS - every name in CONTRACT.md §3. Keep this in the contract's
# order so a diff between the two files is readable.
# ===========================================================================

def _d(sheet, spec):
    """Compact declarations: 'name', 'name[loop]', 'name*4', 'name[3D]' ...

    Suffixes on a name: `[loop]` loop-safe, `[3D]` positional (default 2D),
    `*N` N baked variants. Text after `:` is the description.
    """
    for item in spec:
        text = item.strip()
        desc = ""
        if ":" in text:
            text, desc = text.split(":", 1)
            text, desc = text.strip(), desc.strip()
        loop = "[loop]" in text
        spatial = "3D" if "[3D]" in text else "2D"
        text = text.replace("[loop]", "").replace("[3D]", "").replace("[2D]", "").strip()
        variants = 1
        if "*" in text:
            text, count = text.split("*")
            variants = int(count)
            text = text.strip()
        declare(text, sheet, loop=loop, variants=variants, desc=desc, spatial=spatial)


_d("fishing", [
    "castSwing: rod whip through air",
    "lineWhizz: line paying out, short rising zip",
    "bobberPlop[3D]: bobber hits water - bloop plus small spray",
    "bobberBob[3D][loop]: gentle lapping at a floating bobber",
    "tug[3D]: a fish pulls, sharp water tug",
    "reelOpen: the reel bar appears, mechanical click-whirr",
    "reelTension[loop]: line under strain, creaking ratchet; client scales pitch by tension",
    "reelMiss: dull thunk",
    "reelZoneShrink: tight descending tick",
    "burstOpen: the tap minigame opens",
    "burstTap: one tap lands",
    "burstFill: the bar fills",
    "burstFail: the tap minigame is lost",
    "snapAppear: the snap target appears",
    "snapHit: the snap lands",
    "snapMiss: the snap is missed",
    "catchCommon: reveal stinger, a two-note plink",
    "catchUncommon: reveal stinger, brighter three-note",
    "catchRare: reveal stinger, chord plus sparkle",
    "catchEpic: reveal stinger, rising figure and shimmer",
    "catchLegendary: full 2 s fanfare with shimmer",
    "catchBoss: the summon answers the call, low ominous swell",
    "salvageHaul: wet crate thud plus coins",
    "castRefused: soft negative",
    "castCancel: line reeled back in quickly",
    "fishSurface[3D]: a fish breaks the surface",
    "flopWater[3D]: a fish slapping the water",
    "landGround[3D]: fish lands on dock or sand",
    "flopGround[3D]: wet flop on planks",
])

_d("boat", [
    "boatSummon: the boat is called",
    "boatArrive[3D]: hull settling into water",
    "boatBoard: step onto planks plus creak",
    "boatLeave: stepping off",
    "boatEngine[3D][loop]: outboard putter; client pitches with throttle",
    "boatWash[3D][loop]: bow wash; client volumes with speed",
    "boatCreak[3D]: rudder or hull creak on turn",
    "boatHit[3D]: hull thud",
    "boatWarn: hull damage alarm bell",
    "boatSink: the boat goes under",
    "boatUpgrade: hammer and rope",
])

_d("character", [
    "stepSand*4[3D]", "stepStone*4[3D]", "stepWood*4[3D]", "stepGrass*4[3D]",
    "stepSnow*4[3D]", "stepMetal*4[3D]", "stepMud*4[3D]", "stepShallow*4[3D]",
    "jump[3D]", "land[3D]", "swimStroke[3D]", "waterEnter[3D]", "waterExit[3D]",
    "hurt", "hurtHeavy",
    "lowHealth[loop]: slow heartbeat",
    "death", "respawn",
    "chilled: frost crackle, slow applied",
    "knockback: whump",
])

# EQUIPPING, added 2026-09-12. The rod/fist switch used to play `uiEquip` -
# a UI clack, the same sound as a button. Taking a rod out of a rack and
# taking a blade off a belt are two different physical events and neither
# is a click, so each gets its own cue and the tool slot gets a draw and a
# stow rather than one shared noise. ADDITIVE: `uiEquip` is untouched and
# still what the inventory grid plays.
_d("character", [
    "rodDraw: the rod comes out - unfold, whip-flex and the reel clicking over",
    "rodStow: the rod goes back - flex settling, one seat click",
    "weaponDraw: a blade pulled from a belt - leather slide into a metal ring",
    "weaponStow: the sheath taking it back, leather closing over",
    "fistReady: knuckles cracking and a cloth shift - no tool at all",
])

_d("combat", [
    "punchSwing", "weaponSwing", "swingRefused",
    "hitCrack[3D]: landed hit, the crack layer",
    "hitThump[3D]: landed hit, the body layer",
    "killCrack[3D]", "killThump[3D]",
    "gunFire: the player's own shot", "bowFire: the player's own release",
    "gunFireRemote[3D]: someone else's shot", "bowFireRemote[3D]",
    "gunReload", "gunReady: click", "dryFire", "renock",
    "zoomIn", "zoomOut",
    "bulletImpact[3D]", "bulletWhiz[3D]: near miss",
])

# BAKED VARIANTS, added 2026-09-12. A sprite plays back identically every
# time, so seeded jitter inside a renderer buys variety between BUILDS, not
# between swings - and the punch and the flop are the two cues a player
# triggers dozens of times a minute, which is most of why they read as
# "choppy". The client's resolver already fans a bare name out to numbered
# variants, so `Sfx.play("punchSwing")` picks among these with no Luau
# change. ADDITIVE: the base cues keep their own renders and remain the
# fallback for anything that asks for them directly.
_d("combat", [
    "punchSwing*3: the fist swing, three baked takes",
    "hitCrack*3[3D]: the crack layer, three baked takes",
    "hitThump*3[3D]: the body layer, three baked takes",
])
_d("fishing", [
    "flopGround*3[3D]: wet flop on planks, three baked takes",
])

_d("ui", [
    "uiClick", "uiHover", "uiOpen", "uiClose", "uiTab", "uiSelect", "uiEquip",
    "uiError", "craftSuccess", "craftFail", "shopBuy", "shopFail", "baitCycle",
    "cursorFree", "cursorLock", "notify",
    "dialogOpen", "dialogBlip", "dialogChoice", "dialogClose",
])

_d("progression", [
    "coinGain", "xpGain",
    "levelUp: 2 s fanfare",
    "materialGain", "baitGain",
    "itemDrop: rare drop sparkle",
    "newSpecies: bestiary page turn plus chime",
    "collectionComplete",
    "questTick", "questReady", "questAccept", "questComplete",
    "islandUnlock: big chord plus heart pulse",
    "heartsAll",
    "travelGo", "travelArrive", "travelRefused",
    "raidStart", "raidWave", "raidClear", "raidFail",
])

_d("world", [
    "thunder*3", "lampOn", "lampOff",
    "lavaBurst[3D]", "lavaBubble[3D][loop]", "whirlpool[3D][loop]",
    "bellToll[3D]: the Bellbuoy's sea-bell",
    "iceCreak[3D]", "gullCry*3[3D]",
    "windGust: a gust across the deck",
])

_d("creatures", [
    "dashWhoosh", "dazed", "spitLaunch", "spitSplashWater", "spitSplashGround",
    "explodeCrack", "explodeBoom", "burrow", "sandShift[loop]", "emerge",
    "shellCreak", "shellSnap", "coinSteal", "crackle", "pulseZap", "pulseThump",
    "gasHiss[loop]", "inkBlast", "splashRing", "spineStick", "chillTick",
    "rebornRise", "phantomOut", "phantomIn", "snareSnap", "chainRattle",
    "decoyPop", "beamHum[loop]", "poolSpawn",
])

# One voice set per body family - Idle / Attack / Hurt / Die, all 3D. The
# client pitches these from `body.scale`, so author them at a neutral size.
for _fam in FAMILIES:
    _d("families", [
        "%sIdle[3D]: an occasional call" % _fam,
        "%sAttack[3D]" % _fam,
        "%sHurt[3D]" % _fam,
        "%sDie[3D]" % _fam,
    ])

_d("boss_shared", [
    "bossTell[3D]: the wind-up a player reads", "bossRise[3D]", "bossRoar[3D]",
    "bossSnap[3D]", "bossSweep[3D]", "bossSlam[3D]", "bossDown[3D]",
    "bossStagger[3D]", "bossStance[3D]", "bossCollapse[3D]", "reefShatter[3D]",
    "bossSpit[3D]", "bossSpine[3D]", "bossSpineHit[3D]", "bossGlobThud[3D]",
])

# Voice variants. Ordinary cues, on the sheet of their boss.
for _voice, _sheet in BOSS_VOICES.items():
    for _base in VOICED_BOSS_CUES:
        declare("%s__%s" % (_base, _voice), _sheet, spatial="3D",
                desc="%s in the %s voice" % (_base, _voice))

_d("boss_brinejaw", [
    "serpentSweepLow[3D]", "serpentSweepHigh[3D]", "serpentSlam[3D]",
    "serpentWave[3D]", "serpentRain[3D]", "serpentRings[3D]", "serpentSurge[3D]",
    "serpentPolyps[3D]", "polypBurst[3D]", "polypHeal[3D]", "serpentGeysers[3D]",
    "serpentSpines[3D]", "serpentCoilslam[3D]", "serpentBite[3D]", "belltoll[3D]",
    "lungeRoar[3D]", "undertowPull[3D]", "spiralWind[3D]", "comboWarn",
])

_d("boss_gnashroot", [
    "gnashBite[3D]", "gnashWallow[3D]", "gnashDisgorge[3D]", "gnashHeave[3D]",
    "gnashMire[3D]", "gnashHammerfall[3D]", "gnashRootCreak[3D]",
    "gnashGurgle[3D]", "gnashDeath[3D]",
])

_d("boss_rimefang", [
    "rimeSpout[3D]", "rimeWash[3D]", "rimeBreachLaunch[3D]", "rimeBreachCrash[3D]",
    "rimeFloeCrack[3D]", "rimeThrash[3D]", "rimeFlukeSlam[3D]", "rimeSpyHop[3D]",
    "rimeWhiteout[3D][loop]", "rimeDeath[3D]",
    # Final names from lane 81 (2026-09-09), replacing the provisional set.
    "rimeCrackWeb[3D]: a web of cracks racing across the ice",
    "rimeCrackLock[3D]: the web locks, the mark is set",
    "rimeIceBurst[3D]: the sheet erupts",
    "rimeSkyLaunch[3D]: the whale leaves the water for a sky-fall",
    "rimeSkyImpact[3D]: it lands",
    "rimeShock[3D]: the shockwave ring",
    "rimeQuake[3D]: the whole floe quakes, long and low",
    "rimeShatter[3D]: one long structural crack-and-collapse, the sheet failing under the boss (phase-2 opener)",
    "rimeEnrage[3D]: the roar on the 50% transition frame, higher and angrier than rimeThrash",
    "rimeRiftAmbient[3D][loop]: low water-slap loop at an open hole in the ice",
])

_d("boss_pyrelisk", [
    "pyreHandfall[3D]", "pyreRimsweep[3D]", "pyreVentbreath[3D][loop]",
    "pyreAshfall[3D]", "pyreShardhurl[3D]", "pyreShardHit[3D]", "pyreStep[3D]",
    "pyreRoar[3D]", "pyreCrustCrack[3D]", "pyreDeath[3D]",
])

_d("boss_noctyss", [
    "choirPulse[3D]", "choirPulseTrue[3D]", "choirBeam[3D]", "lanternBreak[3D]",
    "lureFlare[3D]", "choirDouse[3D]", "mawRise[3D]", "mawBite[3D]",
    "slamSnuff[3D]", "slamImpact[3D]", "slamPeel[3D]", "scytheCreak[3D]",
    "scytheDrag[3D][loop]", "jabCoil[3D]", "jabCrack[3D]",
])

_d("boss_wrack", [
    "wrackGrapeshot[3D]", "wrackBroadside[3D]", "wrackAnchorsweep[3D]",
    "wrackWisps[3D]", "wrackPowderrun[3D]", "wrackKegFuse[3D][loop]",
    "wrackKegBlast[3D]", "wrackBrazier[3D]", "wrackCannonoverload[3D]",
    "wrackAnchorline[3D]", "wrackLongboat[3D]", "wrackLadybelow[3D]",
    "wrackBoomsweep[3D]", "wrackBilgeblow[3D]", "wrackShots[3D]",
    "wrackBulletWhiz[3D]", "wrackBell[3D]", "wrackHullGroan[3D]",
    "wrackDeath[3D]",
])

_d("boss_kraken", [
    "krakenRingwave[3D]", "krakenClosingfist[3D]", "krakenInkspit[3D]",
    "krakenTentaclelash[3D]", "krakenWreckhurl[3D]", "krakenStormcall[3D]",
    "krakenInknova[3D]", "krakenUndertow[3D]", "krakenRoar[3D]",
    "krakenTentacleRise[3D]", "krakenDeath[3D]",
])

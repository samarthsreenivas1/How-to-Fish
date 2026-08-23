# Running this project on a Mac

Everything the game needs is in this repo, including `assets/Assets.rbxm`
(the Studio-imported meshes). There is no saved place file to copy: Rojo
builds the game from `src/` every time you connect.

Times below are for a first-ever setup. Steps 1-5 are once per machine;
step 6 is what you do every session.

---

## 1. Command line tools (gives you `git`)

```bash
xcode-select --install
```

A dialog appears; accept it. If it says the tools are already installed,
you're done. Check:

```bash
git --version
```

## 2. Clone the repo

```bash
cd ~/Developer          # or wherever you keep projects; mkdir it if needed
git clone https://github.com/samarthsreenivas1/How-to-Fish.git
cd How-to-Fish
```

The folder name has no spaces, unlike the Windows copy - so no quoting
needed in any command below.

## 3. Install Aftman (the toolchain manager)

`aftman.toml` pins the exact versions of the three tools this project uses -
**rojo 7.7.0**, **StyLua 2.5.2**, **selene 0.31.0** - so both machines run
identical tooling.

1. Open <https://github.com/LPGhatguy/aftman/releases> and download the
   macOS build for your chip:
   - Apple Silicon (M1/M2/M3/M4): `aftman-<version>-macos-aarch64.zip`
   - Intel: `aftman-<version>-macos-x86_64.zip`
2. Unzip it (double-click), then in Terminal, from wherever it unzipped:

```bash
cd ~/Downloads
./aftman self-install
```

3. Add Aftman's binaries to your PATH, then reload the shell:

```bash
echo 'export PATH="$HOME/.aftman/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

**If macOS blocks it** ("cannot be opened because the developer cannot be
verified"): System Settings -> Privacy & Security -> scroll down -> **Open
Anyway**, then re-run the command.

## 4. Install the pinned tools

From the repo folder:

```bash
aftman install
```

It will ask you to trust each tool the first time - answer yes. Then check
all three work:

```bash
rojo --version      # 7.7.0
stylua --version    # 2.5.2
selene --version    # 0.31.0
```

## 5. Two things Studio needs

**a) Roblox Studio** - download from <https://create.roblox.com>, install,
and **sign in with the same Roblox account you use on Windows**. This
matters: `Assets.rbxm` references mesh ids uploaded by that account. On a
different account the islands, rods, weapons and creatures come through as
missing meshes (the code falls back to plain parts, so the game still runs -
it just looks wrong).

**b) The Rojo Studio plugin** - install it from the command line:

```bash
rojo plugin install
```

Restart Studio afterwards; a **Rojo** button appears on the **Plugins** tab.

**c) The linter's Roblox type data** - this file is deliberately not
committed (it is generated, and large), so generate it once:

```bash
selene generate-roblox-std
```

Without it `selene src` fails with an error about a missing standard
library.

---

## 5b. VS Code

Install VS Code from <https://code.visualstudio.com>, then open the repo
folder (`File -> Open Folder...`, pick `How-to-Fish`).

VS Code will show **"This workspace has extension recommendations"** -
click **Install All**. That is the whole setup; `.vscode/extensions.json`
and `.vscode/settings.json` are committed, so the editor configures itself:

| Extension | What it does here |
|---|---|
| **Luau LSP** | types, autocomplete, go-to-definition, inline errors |
| **StyLua** | formats on save, using the project's pinned 2.5.2 |
| **Selene** | the project's linter, inline as you type |
| **Rojo** | start/stop `rojo serve` from the command palette |
| **Claude Code** | Claude in the editor |

Two things worth knowing:

- **Let it generate `sourcemap.json`.** The Luau server needs it to know
  that `src/Shared/Data/Rods.luau` is `ReplicatedStorage.Shared.Data.Rods`;
  without it every `require` looks unresolved and you lose autocomplete. The
  settings turn on autogeneration, so it just happens - the file is
  gitignored deliberately.
- **StyLua must come from PATH**, which the settings already specify. If VS
  Code downloads its own copy instead, it will be a different version from
  `aftman.toml`'s and the two will reformat each other's files forever. This
  only works if `~/.aftman/bin` is on your PATH (step 3).

If the Rojo extension is easier than a terminal: `Cmd+Shift+P` ->
**Rojo: Start Server**. It is the same `rojo serve`, so either is fine.

## 6. Every session: play the game

Two things run at once - a server in Terminal, and Studio.

**Terminal**, from the repo folder:

```bash
rojo serve
```

Leave it running. It prints `Rojo server listening: localhost:34872`.

**Studio**:

1. Open Studio and create a **new Baseplate place** (or open the one you
   made last time - the sync overwrites the scripts either way).
2. **Plugins** tab -> **Rojo** -> **Connect** (address `localhost`, port
   `34872`).
3. Press **Play**.

You should see: the island, the ocean, a first-person view with a rod, and
in **Output**, `[Boot] 15 service(s) online.` and `[Boot] 23 controller(s)
online.`

When you change a file in `src/`, Rojo syncs it live - but **the server only
runs its startup code once**, so after changing anything under `src/Server`,
stop and re-press Play.

### If the Rojo plugin won't connect

Studio may be running a stale copy from an earlier session. Disconnect,
reconnect, then stop and re-press Play. If that fails, build a place file
directly and open it - no plugin involved:

```bash
rojo build --output build/How-to-Fish.rbxl
open build/How-to-Fish.rbxl
```

---

## 7. Before you commit anything

Run all three, exactly as on Windows. They must all be clean:

```bash
stylua src      # formats in place
selene src      # must report 0 errors, 0 warnings, 0 parse errors
rojo build --output /tmp/check.rbxlx    # must succeed
```

**A clean lint is not proof the game boots.** A file saved with a UTF-8 BOM
passes all three and still makes Luau refuse to parse it, which takes the
whole game down (this happened on 2026-08-23 - see `context.md`, Gotchas).
On macOS this is much less likely than on Windows PowerShell, but if the
game ever boots to a black screen with `got Unicode character U+feff` in
Output, that is what it is:

```bash
# find any Luau file that starts with a BOM
grep -rl $'\xEF\xBB\xBF' src --include='*.luau'
```

---

## 8. Optional: regenerating the 3D assets

Only needed if you change one of the `assets/*_gen.py` generators. Install
Blender 4.5+ from <https://www.blender.org/download/>, then instead of the
Windows path in `assets/README.md`, use:

```bash
/Applications/Blender.app/Contents/MacOS/Blender \
  --background --python-exit-code 1 \
  --python assets/creatures_gen.py -- assets/creatures.glb preview
```

Same pattern for `island_gen.py`, `fish_gen.py`, `rod_gen.py`,
`weapon_gen.py`. After regenerating, the `.glb` must be **re-imported into
Studio and `assets/Assets.rbxm` re-exported** - `assets/README.md` has that
walkthrough. Nothing on the Mac side changes about it.

---

## Where to read next

- **`context.md`** - the handoff document: what is built, the design
  decisions that are binding, and the gotchas. Read this before changing
  anything.
- **`assets/README.md`** - the Blender -> Studio asset pipeline.
- **`docs/`** - per-feature specs.

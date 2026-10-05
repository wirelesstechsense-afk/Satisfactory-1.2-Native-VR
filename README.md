# NativeVR: native VR for Satisfactory 1.2

NativeVR is a VR mod for Satisfactory 1.2 that runs Epic's own OpenXR plugins inside the game. There's no UEVR and no injector: it's an SML 3.12 mod, built in the SML starter project on Coffee Stain's Unreal Engine 5.6.1 (the CSS engine).

## Where it stands (October 2026)

- **In the editor:** Epic's VR Template runs in VR Preview inside `FactoryGame.uproject`, so headset tracking, the hands and the controllers work. This was tested with a Quest through Virtual Desktop (VDXR). Map Check is clean, and the NativeVR game feature loads.
- **In the game:** an earlier build (September 30) reached the game's main menu in VR through Virtual Desktop. Loading a save with VR on then crashed inside the game's Sentry plugin. That isn't solved yet.
- **Next:** NativeVR loading in the real game with VR on, packaged with Alpakit. After that:
  - VR options in SML's Mods menu, including fixes for common VR rendering problems;
  - full-body VR (VRIK-style);
  - physical hands (HIGGS-style);
  - everything Dortamur's UEVR Enhancements does, without UEVR.

## What's in this repo

| Path | What it is |
|---|---|
| `Setup-NativeVR.ps1` | Sets up a starter project for NativeVR. It fetches Epic's XR plugins and the VR Template from the CSS engine source, places them as mods, makes the fixes FactoryGame needs, and builds the editor. It's safe to run again. |
| `Mods/NativeVRCore/` | NativeVR's C++ mod. It loads early (PostConfigInit) and does two things. First, it hands Epic's OpenXR plugin its loader DLL, because OpenXR only looks in the engine folder, which the CSS install and the game don't have. Second, in the shipped game, it takes XRBase's `FDisplayMappingPS` off the engine's global shader check. |
| `Mods/GameFeatures/NativeVR/` | The NativeVR content mod (a 1.2 Game Feature mod), with its `FGGameFeatureData`. NativeVR's own assets go here. |
| `CLAUDE.md` | The project guide: the ground rules, where everything is, and every known fact found so far. Claude Code reads it automatically. It's also the best single page for a person to read. |

## What isn't in this repo, and why

The XR plugins and the VR Template content are Epic's code and art:
- OpenXR
- XRBase
- OpenXRHandTracking
- OpenXREyeTracker
- LiveLink

Epic's license doesn't allow posting engine source publicly, so none of it is committed here. Instead, `Setup-NativeVR.ps1` downloads it from the CSS engine source on GitHub. You can read that source once your GitHub account is linked to Epic, which is the same access the CSS engine installer needs. Build output (`Binaries`, `Intermediate`) isn't committed either.

## Setting up

You need:
- **The Satisfactory 1.2 modding setup from the SML docs:**
  - the CSS engine (UE 5.6.1-CSS) installed;
  - the SML 3.12 starter project with the game's assets generated;
  - Visual Studio, set up the way the docs describe.
- **Git and GitHub:** Git for Windows 2.27 or newer, and a GitHub account linked to your Epic account and to ficsit.app (the same steps as for the CSS engine).
- **A PC VR runtime to test with:** Virtual Desktop (VDXR), SteamVR or Quest Link.

Close the editor. Then run this in PowerShell, with the two paths changed to yours:

```powershell
$repo = "C:\path\to\Satisfactory-1.2-Native-VR"   # this repo
$proj = "C:\SatisfactoryModLoader"                 # your SML starter project
robocopy "$repo\Mods" "$proj\Mods" /E
Copy-Item "$repo\Setup-NativeVR.ps1" $proj -Force
powershell -ExecutionPolicy Bypass -File "$proj\Setup-NativeVR.ps1"
```

The first run does the following:
1. Downloads only the parts of the engine source it needs, into `C:\NativeVR-Source`. Change that with `-CacheDir`.
2. Places Epic's plugins in `Mods` and the VR Template in `Content`.
3. Builds the editor. The first build takes a while.
4. Runs the editor once without a window to save two fixes.

It writes a report to `Saved\NativeVR-Setup\report.md`, and a `CLAUDE.md` with your machine's paths.

Then:
1. Open `FactoryGame.uproject`.
2. Open `Content > VRTemplate > Maps > VRTemplateMap`.
3. Start your PC VR link.
4. Choose Play > VR Preview.

## How it works

Everything here follows two rules. Nothing is changed in the CSS engine install. And Epic's plugin code isn't edited: when something is missing, the missing piece gets pulled in. What the setup script does:

- **Plugins as mods.** Each XR plugin the template needs goes into `Mods` as its own mod, with Epic's code unchanged. Only its `.uplugin` gets SML fields.
  - The CSS install keeps OpenXRHandTracking, OpenXREyeTracker and LiveLink as source only, with nothing compiled. Their mods get a higher `Version`, so the editor loads the mod and not the engine's uncompiled copy.
- **Missing pieces pulled in.** The CSS install leaves out some modules the plugins need. They're copied unchanged into the mod that uses them:
  - the engine modules `AugmentedReality` (into XRBase), and `LiveLinkAnimationCore` and `LiveLinkMessageBusFramework` (into LiveLink);
  - the OpenXR SDK, meaning Khronos' headers and loader (into OpenXR). Its build rules are pointed at the mod's folder.
- **The template.** The template's content and its shared packs (LevelPrototyping, Weapons, VRSpectator) go into `Content`. Only `.uasset` and `.umap` files are copied: Epic's packs also hold FBX source files, and the editor's auto reimport would offer to import them over the meshes.
- **Input contexts.** The template's input mapping contexts are added to `Config\DefaultInput.ini`. OpenXR only binds controller buttons for the contexts it knows when the VR session starts.
- **Fixes for FactoryGame:**
  - FactoryGame turns baked lighting off (`r.AllowStaticLighting=False`), so the template map's baked lights are switched to Movable: the campfire light, a fill light and the sky light.
  - The grid material is saved with "Used with Nanite". The LevelPrototyping meshes use Nanite, and FactoryGame has Nanite on.
  - NativeVR gets its `FGGameFeatureData`.

`-FreshTemplate` replaces the template content with a clean, fixed copy. `-ExtraPlugins A,B` brings in more of Epic's plugins. `-Fresh` starts over; old copies go to `_NativeVR_Backup` and nothing is deleted.

## Known issues and gotchas

`CLAUDE.md` has the full list. The ones you'll hit first:

- **Teleport:** teleport in the template map probably finds no valid spot. FactoryGame builds its navmesh only around navigation invokers. NativeVR's own movement won't rely on it.
- **Trace channel 1:** FactoryGame uses trace channel 1 for "Projectile", and the template uses it for its menu laser. NativeVR's own pointers must not use channel 1.
- **Packaging hand tracking:** the game ships neither LiveLink nor Takes. Before hand tracking is packaged for the game, LiveLink's editor-only dependencies may need `"TargetAllowList": ["Editor"]`.
- **The game build:** in the shipped game, HDR output must stay off in VR, and Epic's XR plugins need `WITH_MGPU=0` when built for the game.

## Keeping this repo up to date (for Thanatos)

Work happens in the project (`C:\SatisfactoryModLoader`). To copy the current state into this repo folder, run this, then commit and push in GitHub Desktop:

```powershell
$proj = 'C:\SatisfactoryModLoader'
$repo = 'C:\Documents\github project\Satisfactory-1.2-VR\Satisfactory-1.2-Native-VR'
robocopy "$proj\Mods\NativeVRCore" "$repo\Mods\NativeVRCore" /MIR /XD Binaries Intermediate Saved /NFL /NDL /NJH /NJS /NP
robocopy "$proj\Mods\GameFeatures\NativeVR" "$repo\Mods\GameFeatures\NativeVR" /MIR /XD Binaries Intermediate Saved /NFL /NDL /NJH /NJS /NP
Copy-Item "$proj\Setup-NativeVR.ps1", "$proj\CLAUDE.md" $repo -Force
```

## Credits

- NativeVR is made by Thanatos.
- The XR plugins and the VR Template are Epic Games'. They're fetched from the CSS engine source, not redistributed here.
- The modding framework and starter project come from the Satisfactory Modding team (SML).
- Dortamur's UEVR Enhancements set the bar for what NativeVR should do.

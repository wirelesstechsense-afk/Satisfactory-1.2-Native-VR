# NativeVR - project guide for Claude Code

NativeVR is a native VR mod for Satisfactory 1.2, built in this SML starter project by Thanatos.
Read this whole file first. Then read `Saved\NativeVR-Setup\report.md`: the latest setup run, which plugins were brought in, gaps found in the engine install, the editor steps still to do, and the last build result.

## Where things are
- Project: `C:\SatisfactoryModLoader`
- CSS engine install (UE 5.6.1, Coffee Stain fork): `C:\Program Files\Unreal Engine - CSS` - READ ONLY
- Engine source, partial download for reference: `C:\NativeVR-Source\UnrealEngine` - READ ONLY. Only the folders NativeVR needs were fetched, from https://github.com/satisfactorymodding/UnrealEngine.git, branch 5.6.1-CSS, commit 5271227f.
- NativeVR mod (content, a Game Feature mod): `Mods\GameFeatures\NativeVR`
- NativeVRCore mod (C++ that has to load before the engine sets up VR): `Mods\NativeVRCore`. It hands OpenXR its loader, and in the shipped game it takes XRBase's FDisplayMappingPS off the engine's global shader check.
- Epic's XR plugins as mods: `Mods\OpenXR` (plus the vendored `Source\ThirdParty\OpenXR` module: the OpenXR SDK, which the CSS install leaves out), `Mods\XRBase` (plus the vendored `Source\AugmentedReality` module), `Mods\OpenXRHandTracking`, `Mods\OpenXREyeTracker`, and `Mods\LiveLink` (plus the vendored engine modules `Source\LiveLinkAnimationCore` and `Source\LiveLinkMessageBusFramework`, listed in `LiveLink.uplugin`). The setup script brings all of these in.
- Epic's VR Template content stays in `Content` as the test bed: `VRTemplate`, `Characters\MannequinsXR`, and the shared packs `LevelPrototyping`, `Weapons`, `VRSpectator`, asset files only (no FBX). NativeVR's own assets go in the mod.
- Setup script: `Setup-NativeVR.ps1` in the project root (a copy is kept in `Saved\NativeVR-Setup`). Re-running it only adds what is missing. `-ExtraPlugins Name1,Name2` brings in more Epic plugins from source; `-FreshTemplate` replaces the template content with a clean, fixed copy; `-Fresh` starts over (old copies go to `_NativeVR_Backup`). When you run it yourself, add `-NoPause`. The fixes only the editor can make are in `Saved\NativeVR-Setup\NativeVR-EditorFixes.py`; the script runs them with the editor's command-line version, or in the editor: Output Log, Cmd, `py "<that file>"`.
- GitHub repo: https://github.com/wirelesstechsense-afk/Satisfactory-1.2-Native-VR (public), local copy in `C:\Documents\github project\Satisfactory-1.2-VR\Satisfactory-1.2-Native-VR`. It holds only NativeVR's own files: `Mods\NativeVRCore`, `Mods\GameFeatures\NativeVR`, `Setup-NativeVR.ps1`, this file and README.md. Epic's plugins and the template content are never committed there (Epic's license doesn't allow posting engine source publicly); the setup script fetches them. README.md has the PowerShell that copies the project's current files into the repo folder.
- Logs: `Saved\NativeVR-Setup\` (setup, build, report) and the editor log at `Saved\Logs\FactoryGame.log`.
- Game: Satisfactory 1.2 on Steam at `C:\Program Files (x86)\Steam\steamapps\common\Satisfactory` (game DLLs use the `FactoryGameSteam-` prefix), SML 3.12. Game log: `%LOCALAPPDATA%\FactoryGame\Saved\Logs\FactoryGame.log`.
- Headset: a Quest through Virtual Desktop (VDXR OpenXR runtime). SteamVR is installed too.

## Ground rules from Thanatos (never break these)
1. Never modify the CSS engine install, and never rebuild the engine from source. All work lives in this project.
2. Never remove code from Epic's plugins. When something is missing, pull the missing dependency in (vendor it into a mod) instead of cutting the code that needs it. Editing a .uplugin descriptor is fine.
3. Build the editor only with:
   `& "C:\Program Files\Unreal Engine - CSS\Engine\Build\BatchFiles\Build.bat" FactoryEditor Win64 Development -Project="C:\SatisfactoryModLoader\FactoryGame.uproject" -WaitMutex -FromMsBuild`
   Not "Build Solution" in Visual Studio. Never delete engine Binaries folders.
4. Close the editor before building C++. After every code change, build, read the log yourself, and only then say it works.
5. In 1.2, content mods are Game Feature mods: they need an `FGGameFeatureData` data asset named exactly after the mod (`NativeVR`) in the mod's content root, with Initial State set to Active.
6. Add components to the game's actors with SML Actor Mixins, not SCS hooks. Log with SML's logging, not Print String (hidden in Shipping builds).
7. C++ must use `TObjectPtr<>` for UObject members and full include paths (for example `Hologram/FGHologram.h`).
8. VR stays on Epic's own plugins. No third-party VR frameworks (VRExpansionPlugin is excluded).

## How to work with Thanatos
- He knows Unreal modding well but is new to C++. Explain every code change in plain language, without jargon.
- Explain the root cause before the fix.
- Give paste-ready PowerShell for anything he runs, and say exactly what you need from him (a log, a click in the editor, a test in the headset).
- Keep deliverables to the fewest files possible.
- On big features, propose the approach first and wait for his OK before writing large amounts of code.

## Current milestone: Epic's VR Template running in VR Preview inside FactoryGame.uproject
In place: Epic's XR plugins (with hand and eye tracking and LiveLink) in Mods, the template content and its shared packs in Content, the template's input mapping contexts in `Config\DefaultInput.ini`, and NativeVRCore. VR Preview works (hands show, controllers work). Left: check the template map in VR Preview (the campfire light, grabbing, the pistol, the menu); any editor steps still to do are in the report.
If the build fails, the report's "Gaps" section lists engine modules the CSS install lacks that the script couldn't place itself; their source is already downloaded for reference. Pull them in following rule 2, explaining the plan to Thanatos first.
Next milestone: NativeVR loading in the real game with VR on (packaged with Alpakit).

## Known facts (check here before investigating again)
- OpenXR looks for openxr_loader.dll only in `Engine\Binaries\ThirdParty\OpenXR\win64`, which neither the CSS install nor the game has. NativeVRCore hands it the copy the OpenXR mod's build puts in `Mods\OpenXR\Binaries\Win64`, through IOpenXRExtensionPlugin::GetCustomLoader. Good log line: "InitInstance found and will use CustomLoader from plugin NativeVRCore".
- OpenXRInput only creates controller actions for Enhanced Input mapping contexts it knows when the XR session starts: Enhanced Input's Default Mapping Contexts (the setup script adds the template's to `Config\DefaultInput.ini`, which only affects the editor), or contexts attached through IMotionController::AttachInputMappingContexts or UOpenXRInputFunctionLibrary::BeginXRSession. In the game, NativeVR must attach its own contexts before turning VR on.
- FactoryGame defines ECC_GameTraceChannel1 as "Projectile" (blocks by default). The VR Template uses that channel as "3DWidget" for its menu laser, so in this project the template's laser can hit other objects. NativeVR's pointers must not use channel 1.
- What the September builds (the old NativeVR, before this setup) found in the shipped game. XRBase's FDisplayMappingPS isn't in the game's shader library: the game stops at startup with "Missing global shader FDisplayMappingPS" (NativeVRCore's shader fix handles it, and HDR output must stay off in VR). The modding headers have WITH_MGPU=1 but the game was built with 0, so Epic's XR plugins need WITH_MGPU=0 when built for the game. That build reached the main menu in VR through Virtual Desktop. Loading a save with VR on crashed inside the game's Sentry plugin (unsolved).
- The game ships HeadMountedDisplay, EyeTracker, the D3D11/D3D12/Vulkan/OpenGL RHIs, MRMesh, EnhancedInput and ControlRig. It doesn't ship XRBase, AugmentedReality, OpenXR or LiveLinkAnimationCore.
- The CSS install keeps some of Epic's plugins as source only, with nothing compiled (OpenXRHandTracking, OpenXREyeTracker, LiveLink), and some engine modules too (LiveLinkAnimationCore, LiveLinkMessageBusFramework). The build tools prefer a mod over an engine plugin of the same name, but the editor keeps the engine's copy when the two have the same "Version", so the mods made from these carry a higher "Version" in their .uplugin (the setup script sets it). An engine module the install lacks goes, unchanged, into the mod that uses it, listed in that mod's .uplugin.
- The VR Template's B_AssetGuideline (Asset User Data on the VRPawn camera) asks for OpenXR, OpenXREyeTracker and OpenXRHandTracking. When those mods are missing the editor shows "Missing Plugins": Dismiss it. Enable Missing switches on the engine's uncompiled copies and the editor won't start; Remove Guideline edits the template's VRPawn.
- Git (sparse download) deletes downloaded folders outside its folder list that hold only ignored files whenever the list changes; the engine's .gitignore ignores all the art. The setup script adds every folder to the list before downloading into it (the template's shared packs were lost this way once).
- The game ships neither LiveLink nor Takes. LiveLink's .uplugin depends on Takes and ContentBrowserAssetDataSource (editor tools), so before packaging hand tracking for the game, check that the game build accepts it (those two dependencies may need "TargetAllowList": ["Editor"]).
- Teleport in the template map probably finds no valid spot: FactoryGame's navigation settings build the navmesh only around navigation invokers (the creatures) and only after the game releases its initial build lock. NativeVR's own movement won't rely on the template's navmesh teleport.
- The editor splash is `Content\Splash\EdSplash.png`. Regenerating Content with the asset generator drops it; the starter project's original is in `Content_PreGenerate\Splash` (restored on 2026-10-04).
- FactoryGame turns baked lighting off (`r.AllowStaticLighting=False`): lights set to Static never show and baked lightmaps are ignored. The template map baked its campfire light (PointLight4), a fill light (PointLight5) and the sky light, so the setup script switches those to Movable. NativeVR's own lights must be Movable (or Stationary).
- Don't put source art (FBX and the like) into Content next to assets; the splash PNGs in `Content\Splash` are the one deliberate exception. With this project's Auto Reimport settings (Editor Preferences > Loading & Saving) the editor offers to import new source files and re-imports the assets made from them; on 2026-10-04 that replaced nine LevelPrototyping meshes with damaged copies, and `-FreshTemplate` restored them. If that prompt appears for template folders, click Don't Import. The editor remembers the source files it has seen in `Intermediate\ReimportCache`; with the editor closed, deleting that file makes it take a fresh snapshot without prompts.
- The template's purple cubes and ball are Epic's design: they use `MI_VRColorway` (base colour 0.30, 0.06, 1.0).
- The template map already sets VRGameMode as its GameMode Override.
- LevelPrototyping's meshes use Nanite (FactoryGame has Nanite on and deferred shading; the template was made for forward shading without Nanite). Materials on them need "Used with Nanite"; of the template's own, only M_GridRotation lacked it, and the setup script saves it with the flag.
- NativeVR's data asset `/NativeVR/NativeVR` (FGGameFeatureData) starts empty. When NativeVR adds user settings, narrative messages, an icon library or child input mapping contexts, add matching "Primary Asset Types to Scan" entries to it (ExampleMod's data asset shows the pattern: FGUserSetting, FGMessage, FGIconLibrary, FGChildInputMappingContext).
- Normal noise in this project's editor log, not caused by NativeVR: FactoryGame/SML "StructProperty ... is not initialized properly" errors, Wwise "Current platform Windows not found" (no generated soundbanks), "Short type name" warnings, and OpenXR's warnings that the template's input actions have empty descriptions.

## The vision (the bar: Half-Life: Alyx, Skyrim VR with VRIK and HIGGS, the Titanfall 2 VR mod, Into the Radius 2, Bonelab)
1. Native-feeling VR: menus work in both eyes, switch between VR and flat from settings at any time, and options for common VR rendering fixes in SML's Mods menu (main menu and in game).
2. Full body (VRIK-style): very smooth animation, ALS-style movement blending, real and motion-driven leaning that look great to other players in multiplayer.
3. Hands (HIGGS-style): physical grabbing, Alyx-style gravity pull of items to the hand, highlights on anything that can be grabbed or used.
4. Body inventory: a tool belt to take tools from, and a bag you drop items into over your shoulder to put them in the inventory.
5. Vehicles: physical driving controls, and interior buttons and controls pressed by hand wherever possible.
6. Everything Dortamur's UEVR Enhancements mod does, without needing UEVR.
7. Later: an iPad companion screen with factory stats and touch controls.
Target PC: a minimum-spec VR laptop (i7-10750H, RTX 2060 mobile, 16 GB RAM). Keep CPU cost low, especially per-player costs in multiplayer.
// NativeVR Core - build rules. Only engine modules and Epic's XR plugins (the OpenXR and XRBase mods).

using UnrealBuildTool;

public class NativeVRCore : ModuleRules
{
	public NativeVRCore(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

		PrivateDependencyModuleNames.AddRange(new string[]
		{
			"Core",
			"CoreUObject",
			"Engine",
			"Projects",           // finds the OpenXR mod's folder
			"RHI",
			"RenderCore",         // the engine's list of shader types
			"HeadMountedDisplay",
			"AugmentedReality",   // OpenXR's extension interface uses its types (in the XRBase mod)
			"XRBase",
			"OpenXRHMD",          // IOpenXRExtensionPlugin, Epic's hook for handing OpenXR a loader
			"OpenXR",             // OpenXR's headers (the third-party module inside the OpenXR mod)
		});
	}
}

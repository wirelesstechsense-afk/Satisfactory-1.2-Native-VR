// NativeVR Core - the small part of NativeVR that has to run before the engine sets up VR.
//
// 1. The OpenXR loader (editor and game).
//    Epic's OpenXR plugin looks for the Khronos loader (openxr_loader.dll) in one place only: the engine's own
//    Engine\Binaries\ThirdParty\OpenXR\win64 folder. Neither the CSS editor nor the shipped game has it there, so
//    OpenXR gave up with "Failed to find OpenXR runtime loader". The OpenXR mod already carries the loader in its
//    own Binaries folder; this module loads that copy and hands it to OpenXR through GetCustomLoader, the hook
//    Epic provides for exactly this. Epic's plugin code is not changed.
//
// 2. The shader check (shipped game only; does nothing in the editor).
//    XRBase adds a shader (FDisplayMappingPS) that converts the headset picture for HDR monitors. Satisfactory's
//    shader library was made without XRBase, and at startup the game stops with "Missing global shader
//    FDisplayMappingPS" when a shader on the engine's list isn't in the library. This takes shaders that come
//    from mods off that list, just before the engine checks it. It's the fix from the Sept 30 build that got the
//    game to the main menu in VR. XRBase only uses FDisplayMappingPS while HDR output is on, so HDR output must
//    stay off in VR.

#include "CoreMinimal.h"
#include "HAL/PlatformProcess.h"
#include "HAL/PlatformProperties.h"
#include "Interfaces/IPluginManager.h"
#include "IOpenXRExtensionPlugin.h"
#include "Misc/CString.h"
#include "Misc/DelayedAutoRegister.h"
#include "Misc/Paths.h"
#include "Modules/ModuleManager.h"
#include "Shader.h"
#if PLATFORM_WINDOWS
#include "Windows/WindowsHWrapper.h"
#endif

DEFINE_LOG_CATEGORY_STATIC(LogNativeVR, Log, All);

namespace NativeVRShaderFix
{
	// The DLL a piece of memory belongs to (full path), or empty if that can't be found out.
	static FString DllHolding(const void* Address)
	{
#if PLATFORM_WINDOWS
		::HMODULE Module = nullptr;
		if (::GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
				reinterpret_cast<const TCHAR*>(Address), &Module) && Module != nullptr)
		{
			TCHAR Path[1024] = {};
			if (::GetModuleFileNameW(Module, Path, 1024) > 0)
			{
				return FString(Path);
			}
		}
#endif
		return FString();
	}

	// Mods' DLLs are in <game>\FactoryGame\Mods\<mod>\Binaries\Win64. All of the game's global shaders were made when
	// the game itself was built, so a global shader that comes from a mod's DLL can't be in the game's shader library.
	static bool IsModDll(const FString& Dll)
	{
		return Dll.Replace(TEXT("\\"), TEXT("/")).Contains(TEXT("/Mods/"), ESearchCase::IgnoreCase);
	}

	static void TakeMissingShadersOffTheList()
	{
		int32 GlobalTypes = 0;
		int32 Taken = 0;
		for (TLinkedList<FShaderType*>* Link = FShaderType::GetTypeList(); Link != nullptr; )
		{
			TLinkedList<FShaderType*>* Next = Link->GetNextLink();
			FShaderType* Type = **Link;
			if (Type != nullptr && Type->GetGlobalShaderType() != nullptr)
			{
				++GlobalTypes;
				const FString Dll = DllHolding(Type);
				const bool bDisplayMapping = FCString::Strcmp(Type->GetName(), TEXT("FDisplayMappingPS")) == 0;
				if (bDisplayMapping || IsModDll(Dll))
				{
					Link->Unlink();
					++Taken;
					const FString From = Dll.IsEmpty() ? FString(TEXT("a mod")) : FPaths::GetCleanFilename(Dll);
					UE_LOG(LogNativeVR, Log, TEXT("took %s off the engine's shader check (it comes from %s; the game's shader library doesn't have it)"),
						Type->GetName(), *From);
				}
			}
			Link = Next;
		}
		if (Taken > 0)
		{
			UE_LOG(LogNativeVR, Log, TEXT("shader list ready: %d global shader types, %d taken off the check. HDR output must stay off in VR, the only time XRBase needs FDisplayMappingPS."),
				GlobalTypes, Taken);
		}
		else
		{
			UE_LOG(LogNativeVR, Warning, TEXT("shader list ready (%d global shader types), but XRBase's shaders weren't on it; if the game stops with 'Missing global shader', this is why"),
				GlobalTypes);
		}
	}

	// Unreal makes its list of shader types late in startup (InitializeShaderTypes), then runs whatever was
	// registered for "shader types ready", and only after that checks the game's shaders (CompileGlobalShaderMap).
	// This module starts much earlier, while the list is still empty, so it registers for "shader types ready".
	static void SetUp()
	{
		// Only the shipped game: the editor compiles the shaders itself.
		if (!FPlatformProperties::RequiresCookedData())
		{
			return;
		}
		// XRBase's shader types only get on the list if XRBase is loaded before the engine makes the list.
		if (FModuleManager::Get().LoadModule(TEXT("XRBase")) == nullptr)
		{
			UE_LOG(LogNativeVR, Warning, TEXT("XRBase couldn't be loaded yet, so its shaders may not be on the list"));
		}
		static FDelayedAutoRegisterHelper WhenShaderTypesAreReady(EDelayedRegisterRunPhase::ShaderTypesReady, []()
		{
			TakeMissingShadersOffTheList();
		});
		UE_LOG(LogNativeVR, Log, TEXT("shader fix set up: it runs once the engine has made its list of shader types, just before the engine checks them"));
	}
}

class FNativeVRCoreModule : public IModuleInterface, public IOpenXRExtensionPlugin
{
public:
	virtual void StartupModule() override
	{
		// OpenXR asks every registered extension plugin for a loader when it starts, right after this loading phase.
		RegisterOpenXRExtensionModularFeature();
		UE_LOG(LogNativeVR, Log, TEXT("NativeVRCore started: OpenXR will get its loader from the OpenXR mod's folder."));
		NativeVRShaderFix::SetUp();
	}

	virtual void ShutdownModule() override
	{
		UnregisterOpenXRExtensionModularFeature();
		// The loader DLL is left loaded on purpose: OpenXR can still call into it while it shuts down after this.
	}

	virtual FString GetDisplayName() override
	{
		return FString(TEXT("NativeVRCore"));
	}

	virtual bool GetCustomLoader(PFN_xrGetInstanceProcAddr* OutGetProcAddr) override
	{
#if PLATFORM_WINDOWS
		if (LoaderHandle == nullptr)
		{
			// An engine that has its own loader doesn't need this one; let Epic's normal code use it.
			const FString EngineLoader = FPaths::ConvertRelativePathToFull(FPaths::EngineDir() / TEXT("Binaries/ThirdParty/OpenXR/win64/openxr_loader.dll"));
			if (FPaths::FileExists(EngineLoader))
			{
				return false;
			}

			// The OpenXR mod gets the loader copied into its Binaries folder when it's built. NativeVRCore's own
			// Binaries folder is the second place to look.
			static const TCHAR* const PluginsToSearch[] = { TEXT("OpenXR"), TEXT("NativeVRCore") };
			for (const TCHAR* PluginName : PluginsToSearch)
			{
				const TSharedPtr<IPlugin> FoundPlugin = IPluginManager::Get().FindPlugin(PluginName);
				if (!FoundPlugin.IsValid())
				{
					continue;
				}
				const FString Dir = FPaths::ConvertRelativePathToFull(FoundPlugin->GetBaseDir() / TEXT("Binaries") / FPlatformProcess::GetBinariesSubdirectory());
				const FString DllPath = Dir / TEXT("openxr_loader.dll");
				if (!FPaths::FileExists(DllPath))
				{
					continue;
				}
				FPlatformProcess::PushDllDirectory(*Dir);
				LoaderHandle = FPlatformProcess::GetDllHandle(*DllPath);
				FPlatformProcess::PopDllDirectory(*Dir);
				if (LoaderHandle != nullptr)
				{
					UE_LOG(LogNativeVR, Log, TEXT("loaded the OpenXR loader %s"), *DllPath);
					break;
				}
				UE_LOG(LogNativeVR, Warning, TEXT("couldn't load %s"), *DllPath);
			}

			if (LoaderHandle == nullptr)
			{
				UE_LOG(LogNativeVR, Warning, TEXT("no openxr_loader.dll found in the OpenXR or NativeVRCore mod's Binaries\\Win64 folder. Rebuild the OpenXR mod; its build copies the loader there."));
				return false;
			}
		}

		*OutGetProcAddr = reinterpret_cast<PFN_xrGetInstanceProcAddr>(FPlatformProcess::GetDllExport(LoaderHandle, TEXT("xrGetInstanceProcAddr")));
		return *OutGetProcAddr != nullptr;
#else
		return false;
#endif
	}

private:
	void* LoaderHandle = nullptr;
};

IMPLEMENT_MODULE(FNativeVRCoreModule, NativeVRCore)

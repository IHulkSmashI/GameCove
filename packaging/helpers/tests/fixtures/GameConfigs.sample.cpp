#include "pch.h"
#include "GameConfigs.h"

#include "State.h"
#include "Config.h"
#include "Logger.h"

// HOW TO ADD A GAME
// -----------------
// Add an entry to gameConfigs below:
//
//   // Game name
//   // Why the game needs these settings
//   {
//       .exes = { "game.exe", "game_dx12.exe" }, // lowercase exe names
//       .ueExes = { "project" },                 // UE games, matches project-win64-shipping.exe & -wingdk-shipping.exe
//       .defaults = { DxgiSpoofing = false, FGAllowedFrameAhead = 2 },
//       .quirks = { ForceUnrealEngine },
//   },
//
// Every field is optional, but they have to stay in the order shown above.
//
// .defaults - Config options changed for this game, written as "Setting = value".
//             Setting names are the same as in Config.h, values in OptiScaler.ini always take priority.
//             If a setting you need is missing, add it to the GAME_SETTING list below.
//             Wrap a setting to only apply it in some cases:
//                 OnNvidia(...), OnNonNvidia(...)  - only on Nvidia / only on AMD & Intel GPUs
//                 WithUpscalerFGInput(...)         - only when FG Input is set to Upscaler
//                 WithXeFG(...)                    - only when XeFG is used as the FG Output
//
// .quirks   - Game specific hacks from Quirks.h, these need code changes to add new ones.

namespace
{
template <auto Member> struct Setting
{
    using ValueType = typename std::remove_reference_t<decltype(std::declval<Config&>().*Member)>::value_type;

    const char* name;

    // Allows writing "Setting = value" in the table
    template <class V> ConfigDefault operator=(V value) const
    {
        const auto typedValue = static_cast<ValueType>(value);

        return { std::format("{} = {}", name, typedValue), [typedValue]
                 {
                     auto& option = Config::Instance()->*Member;

                     if (option.has_value())
                         return false;

                     option.set_volatile_value(typedValue);
                     return true;
                 } };
    }
};

#define GAME_SETTING(member)                                                                                           \
    const Setting<&Config::member> member { #member }

GAME_SETTING(AutoExposure);
GAME_SETTING(BuildPipelines);
GAME_SETTING(ColorResourceBarrier);
GAME_SETTING(CreateHeaps);
GAME_SETTING(DisableOTA);
GAME_SETTING(DisableReactiveMask);
GAME_SETTING(DontUseNTShared);
GAME_SETTING(DxgiSpoofing);
GAME_SETTING(EnableFfxInputs);
GAME_SETTING(EnableFsr2Inputs);
GAME_SETTING(EnableFsr3Inputs);
GAME_SETTING(ExtendedStateRestore);
GAME_SETTING(FGAllowedFrameAhead);
GAME_SETTING(FGAlwaysCaptureFSRFGSwapchain);
GAME_SETTING(FGDisableHUDFix);
GAME_SETTING(FGPreserveSwapChain);
GAME_SETTING(FGSkipResizeBuffers);
GAME_SETTING(FGXeFGForceBorderless);
GAME_SETTING(FGXeFGIgnoreInitChecks);
GAME_SETTING(Fsr2Pattern);
GAME_SETTING(Fsr4DoNotLoadAmdxc64);
GAME_SETTING(FsrUseFsrInputValues);
GAME_SETTING(MVResourceBarrier);
GAME_SETTING(OverlayMenu);
GAME_SETTING(OverrideVsync);
GAME_SETTING(RestoreComputeSignature);
GAME_SETTING(SkipFirstFrames);
GAME_SETTING(SpoofRegistry);
GAME_SETTING(UseFakenvapi);
GAME_SETTING(UseFsr2Dx11Inputs);
GAME_SETTING(UseFsr2VulkanInputs);
GAME_SETTING(UseNtdllHooks);
GAME_SETTING(VulkanExtensionSpoofing);
GAME_SETTING(VulkanSpoofing);
GAME_SETTING(ReprojectionDepthCutoff);
GAME_SETTING(SimulateWaitableObject);

#undef GAME_SETTING

ConfigDefault When(bool (*condition)(const GameConfigContext&), ConfigDefault setting)
{
    setting.condition = condition;
    return setting;
}

ConfigDefault OnNvidia(ConfigDefault setting)
{
    return When([](const GameConfigContext& context) { return context.isNvidia; }, std::move(setting));
}

ConfigDefault OnNonNvidia(ConfigDefault setting)
{
    return When([](const GameConfigContext& context) { return !context.isNvidia; }, std::move(setting));
}

ConfigDefault WithUpscalerFGInput(ConfigDefault setting)
{
    return When([](const GameConfigContext&)
                { return Config::Instance()->FGInput.value_or_default() == FGInput::Upscaler; }, std::move(setting));
}

ConfigDefault WithXeFG(ConfigDefault setting)
{
    return When(
        [](const GameConfigContext&)
        {
            auto& state = State::Instance();
            return state.activeFgOutput == FGOutput::XeFG && state.activeFgInput != FGInput::NoFG &&
                   state.activeFgInput != FGInput::NvngxFG;
        },
        std::move(setting));
}

using enum GameQuirk;

const std::vector<GameConfig> gameConfigs = {

    // BeamNG
    // Spoofing not required for DLSS inputs for both Dx12 and Vk
    {
        .exes = { "beamng.drive.x64.exe" },
        .defaults = { DxgiSpoofing = false },
        .quirks = { HideFsr4 },
    },

    // Red Dead Redemption 2
    // Spoofing causes FSR2 inputs crash, DLSS inputs need OptiPatcher to avoid artifacts/crashes anyway
    {
        .exes = { "rdr2.exe", "playrdr2.exe" },
        .defaults = { EnableFsr3Inputs = false, DxgiSpoofing = false },
    },

    // Red Dead Redemption
    // Preserving the FG swapchain causes crashes with DLSSG via SL
    {
        .exes = { "rdr.exe", "playrdr.exe" },
        .defaults = { DxgiSpoofing = false, FGPreserveSwapChain = false },
        .quirks = { SkipFsr3Method, NoFSRFGFirstSwapchain },
    },

};

bool MatchesExe(const GameConfig& game, const std::string& exeName)
{
    if (std::ranges::find(game.exes, exeName) != game.exes.end())
        return true;

    for (const auto& name : game.ueExes)
    {
        if (exeName == name + "-win64-shipping.exe" || exeName == name + "-wingdk-shipping.exe")
            return true;
    }

    return false;
}
} // namespace

flag_set<GameQuirk> ApplyGameConfigs(std::string exeName, const GameConfigContext& context)
{
    to_lower_in_place(exeName);
    flag_set<GameQuirk> quirks;

    for (const auto& game : gameConfigs)
    {
        if (!MatchesExe(game, exeName))
            continue;

        for (auto quirk : game.quirks)
            quirks |= quirk;

        for (const auto& setting : game.defaults)
        {
            if (setting.condition != nullptr && !setting.condition(context))
                continue;

            // User's config takes priority
            if (!setting.apply())
                continue;

            LOG_INFO("Game default: {}", setting.text);
            State::Instance().detectedQuirks.push_back(setting.text);
        }
    }

    return quirks;
}

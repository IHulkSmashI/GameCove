extends RefCounted
## Words for the power.* controls: [title, one-line help] per id, then the reasons shown when a
## control can't be used here. Plain, short; no maker names unless the setting is the maker's.

const T := {
	"power.tdp": ["TDP", "How much power the chip may use. Lower lasts longer; higher runs games faster."],
	"power.profile": ["Power profile", "Battery, Balanced or Performance watts for this handheld."],
	"power.boost": ["Boost", "Extra watts for short bursts above the TDP. 0 keeps power flat."],
	"power.boost_on": ["TDP boost", "Lets the chip burst above the TDP for a moment (Handheld Daemon)."],
	"power.sppt": ["Short boost limit (SPPT)", "Watts the chip may hold for a few seconds above the TDP."],
	"power.fppt": ["Peak boost limit (FPPT)", "Watts for very short peaks. Never below the short boost limit."],
	"power.power_mode": ["Power mode", "The system's power mode: also sets CPU energy and firmware mode."],
	"power.platform_profile": ["Firmware mode", "The maker's own power and fan mode for this handheld."],
	"power.cpu_boost": ["CPU boost", "Lets the CPU clock above its base speed. Off is cooler and quieter."],
	"power.smt": ["SMT", "Two threads per CPU core. Off can save power in older or lighter games."],
	"power.cpu_cores": ["CPU cores", "How many CPU threads stay on. Fewer saves power in light games."],
	"power.epp": ["CPU energy mode", "How eagerly the CPU clocks up: performance reacts fastest, power saves most."],
	"power.governor": ["CPU governor", "How the kernel picks CPU speeds."],
	"power.cpu_max": ["CPU speed limit", "Caps CPU clocks to leave more of the TDP to the GPU."],
	"power.gpu_level": ["GPU performance level", "Auto lets the GPU pick its clock; low and high pin it; manual uses the clock below."],
	"power.gpu_clock": ["GPU clock", "Fixed GPU clock in manual mode."],
	"power.gpu_min": ["GPU minimum clock", "Keeps the GPU from dropping below this; smoother, uses more power."],
	"power.gpu_max": ["GPU maximum clock", "Caps the GPU clock; cooler, leaves power to the CPU."],
	"power.gpu_profile": ["GPU efficiency mode", "The GPU prefers its most efficient clock and ramps up slower."],
	"power.thermal_limit": ["Temperature limit", "The chip slows down at this temperature. Lower is cooler and quieter."],
	"power.charge_limit": ["Charge limit", "Stops charging at this level to keep the battery healthy. 100 = no limit."],
	"power.battery_long_life": ["Battery care (80 %)", "Stops charging at 80 % (the battery's own Long Life mode)."],
	"power.fan_mode": ["Fan", "Auto lets the firmware run the fan; Quiet and Max are presets."],
	"power.fan_curve": ["Fan curve", "Your own fan speed per temperature point. Never quieter than Quiet."],
	"power.battery_saver": ["Battery saver", "Lowest power settings this handheld allows, until you turn it off or plug in."],
	"power.battery_saver_at": ["Battery saver at", "Turns battery saver on by itself at this battery level. 0 = never."],
	"power.sleep_mode": ["Sleep mode", "s2idle wakes fastest; deep uses less battery while asleep where the firmware supports it."],
	"power.mcu_powersave": ["Controller power saving in sleep", "Less battery used while asleep. Turn off if the device won't wake from a button."],
	"power.autotune_target": ["Auto TDP target", "Off finds the most frames at your TDP; a number holds that frame rate with the fewest watts."],
	"power.autotune_auto_fps": ["Auto FPS", "When the target is out of reach, hold the closest frame rate the TDP gives."],
	"power.autotune_keep": ["Auto TDP keeps", "Frames Auto TDP may give up to save watts, in percent of the most."],
	"power.autotune_floor": ["Auto TDP lowest", "The lowest TDP Auto TDP may use."],
	"power.autotune_plugged": ["Auto TDP when plugged in", "Auto TDP normally runs on battery only."],
}

const NO_TDP := "No TDP service on this system (PowerStation, steamos-manager or Handheld Daemon)"
const NO_HELPER := "Needs GameCove's root helper (install GameCove's system part)"
const HHD_OWNS := "Handheld Daemon manages this"
const FW_IGNORED := "This handheld's firmware ignores these limits; the TDP above is the real one"
const NOT_HERE := "Not available on this handheld"
const NO_SMT := "This CPU has no SMT"
const NO_FAN := "No fan control on this kernel"
const NO_CURVE := "This fan has no curve to set"
const NO_CHARGE := "This battery has no charge limit"
const NO_GPU_CLOCKS := "No GPU clock control here"
const AMD_ONLY := "An AMD GPU setting"
const XE_ONLY := "Needs an Intel Arc (xe) GPU or steamos-manager"
const NO_PPD := "No power-profiles-daemon or tuned-ppd running"
const PPD_OWNS := "Set by Power mode (power-profiles-daemon)"
const NO_THERMAL := "PowerStation can't set a temperature limit here (AMD with ryzenadj only)"
const ONE_SLEEP := "This firmware offers only one sleep mode"
const NO_BATTERY := "No battery"


static func title(id: String) -> String:
	return T.get(id, [id, ""])[0]


static func help(id: String) -> String:
	return T.get(id, ["", ""])[1]

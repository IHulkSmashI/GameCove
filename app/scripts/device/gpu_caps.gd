extends RefCounted
## What this handheld's graphics chip can run for upscaling and frame
## generation: one record, worked out once from the device row and what the
## system reports. Pure: callers pass the facts in, tests pass fixtures.
##
## The same table lives in the upscaling helper (packaging/helpers/
## gamecove_upscale/chips.py); app/tests/fixtures/gpu_tiers.json keeps the two
## in step (test_gpu_caps.gd here, test_best.py there). Why each row is what it
## is: docs/UPSCALING.md.
##
##   tier         chips                                          FSR 4               frame generation
##   intel_xmx    Arc with XMX (Xe2, Xe3, Arrow Lake-H)          4.1.2 on XMX        XeSS 2x 3x 4x
##   intel        Arc without XMX (Meteor Lake)                  no                  XeSS 2x
##   amd_rdna4    RX 9000                                        default             FSR 2x, XeSS 2x
##   amd_halo     Ryzen AI Max, RX 7000 cards                    default             FSR 2x, XeSS 2x
##   amd_rdna35   880M / 890M (AI 9 HX, Z2 Extreme)              default (Lite)      FSR 2x, XeSS 2x
##   amd_rdna3    780M class (Z1, Z1 Extreme, Z2, 7840U, 8840U)  default (INT8)      FSR 2x, XeSS 2x
##   amd_z2a      Ryzen Z2 A                                     offered             FSR 2x
##   amd_rdna2    Steam Deck, Z2 Go, 6800U                       offered             FSR 2x
##   amd_old      Vega and older                                 no                  none
##   nvidia       GeForce                                        game's own DLSS     game's own
##   other        unknown                                        no                  none

const TIERS := ["intel_xmx", "intel", "amd_rdna4", "amd_halo", "amd_rdna35", "amd_rdna3", "amd_z2a", "amd_rdna2",
	"amd_old", "nvidia", "other"]
const FSR4 := {"amd_rdna4": "default", "amd_halo": "default", "amd_rdna35": "default", "amd_rdna3": "default",
	"amd_z2a": "optin", "amd_rdna2": "optin", "intel_xmx": "xmx"}
const FSR4_MODEL := {"amd_rdna4": "FP8", "amd_halo": "INT8", "amd_rdna35": "INT8 Lite", "amd_rdna3": "INT8",
	"amd_z2a": "INT8 Lite", "amd_rdna2": "INT8"}
const FSR4_LISTED := ["amd_rdna4", "amd_halo", "amd_rdna35", "amd_z2a"]
const PROTON_FSR4 := ["amd_rdna4", "amd_halo", "amd_rdna35", "amd_rdna3"]
const XEFG_ON_AMD := ["amd_rdna4", "amd_halo", "amd_rdna35", "amd_rdna3"]
## Oldest versions the routes need (sources in docs/UPSCALING.md): FSR 4 under
## Proton wants Mesa 25.2; the XeSS XMX driver brings its own Mesa and needs the
## xe or i915 kernel driver.
const MESA_FSR4 := [25, 2]
const NVIDIA_PCI := "10DE"


## The facts the helper gets (--gpu): vendor, family, arch, xmx, chip, gpu, tier.
## profile: the devices.json row; gpu_dev: Device.gpu_info() ({"vendor", "driver", "pci_id"}).
static func gpu(profile: Dictionary, gpu_dev: Dictionary = {}) -> Dictionary:
	var fam := str(profile.get("gpu_family", ""))
	var vendor := "intel" if fam.begins_with("intel") else ("amd" if fam.begins_with("amd") else "")
	var dev_vendor := str(gpu_dev.get("vendor", ""))
	if vendor == "" and dev_vendor in ["intel", "amd", "nvidia"]:
		vendor = dev_vendor
	if vendor == "":
		vendor = "nvidia" if fam.begins_with("nvidia") else "other"
	var g := {"vendor": vendor, "family": fam, "arch": str(profile.get("gpu_arch", "")),
		"xmx": vendor == "intel" and bool(profile.get("xmx", fam in ["intel-xe2", "intel-xe3"])),
		"chip": str(profile.get("chip", "")), "gpu": str(profile.get("gpu", ""))}
	g["tier"] = tier(g)
	return g


static func _desktop_series(text: String) -> String:
	var m := RegEx.create_from_string("(?i)\\brx ?(\\d)\\d{3}").search(text)
	return m.get_string(1) if m != null else ""


static func tier(g: Dictionary) -> String:
	var t := str(g.get("tier", ""))
	if t in TIERS:
		return t
	var vendor := str(g.get("vendor", ""))
	var arch := str(g.get("arch", ""))
	var chip := "%s %s" % [g.get("chip", ""), g.get("gpu", "")]
	var low := chip.to_lower()
	match vendor:
		"intel":
			return "intel_xmx" if bool(g.get("xmx", false)) else "intel"
		"nvidia":
			return "nvidia"
		"amd":
			var series := _desktop_series(chip)
			if arch == "RDNA4" or series == "9":
				return "amd_rdna4"
			if "ai max" in low or "8050s" in low or "8060s" in low or series == "7":
				return "amd_halo"
			if arch == "RDNA3.5":
				return "amd_rdna35"
			if arch == "RDNA3":
				return "amd_rdna3"
			if arch == "RDNA2":
				return "amd_z2a" if RegEx.create_from_string("(?i)\\bz2 a\\b").search(chip) != null else "amd_rdna2"
			return "amd_old"
	return "other"


static func upscalers(g: Dictionary) -> Array:
	var t := tier(g)
	if t == "intel_xmx":
		return ["own", "xess", "fsr4_xmx", "fsr4_xmx_lite"]
	if t == "intel":
		return ["own", "xess"]
	if FSR4.has(t):
		return ["own", "fsr31", "fsr4_amd"]
	return ["own"]


static func frame_gens(g: Dictionary) -> Array:
	var t := tier(g)
	if t == "intel_xmx":
		return [0, 2, 3, 4]
	if t == "intel" or (t.begins_with("amd_") and t != "amd_old"):
		return [0, 2]
	return [0]


## Frame generators OptiScaler can put out here, the best first.
static func generators(g: Dictionary) -> Array:
	var t := tier(g)
	if t in ["intel_xmx", "intel"]:
		return ["xefg"]
	if t in XEFG_ON_AMD:
		return ["fsrfg", "xefg"]
	if t in ["amd_z2a", "amd_rdna2"]:
		return ["fsrfg"]
	return []


## "xell", "antilag2", "reflex" or "": what keeps input lag down next to
## frame generation. XeSS frame generation always brings XeLL.
static func latency(g: Dictionary, generator := "") -> String:
	if generator == "xefg":
		return "xell"
	var t := tier(g)
	if t in ["intel_xmx", "intel"]:
		return "xell"
	if t == "nvidia":
		return "reflex"
	if t in ["other", "amd_old"]:
		return ""
	return "antilag2"


static func _version(text: String) -> Array:
	var m := RegEx.create_from_string("(\\d+)\\.(\\d+)").search(text)
	return [m.get_string(1).to_int(), m.get_string(2).to_int()] if m != null else []


static func _at_least(have: Array, want: Array) -> bool:
	if have.size() < 2:
		return true          # unknown: don't claim a problem we can't see
	return have[0] > want[0] or (have[0] == want[0] and have[1] >= want[1])


## The whole record. sys: {"gpu_dev": Device.gpu_info(), "mesa": "26.2.4",
## "kernel": "7.2.3-…", "memory": Device.memory_info() ({"total_mb", "vram_mb", …}),
## "xess_xmx": bool (the XMX driver is installed)}.
## Returns the gpu() facts plus: upscalers, frame_gens, generators, latency,
## fsr4 ("default" | "optin" | "xmx" | ""), fsr4_model, fsr4_listed, proton_fsr4,
## vram_mb, shared_mb, mesa, kernel, driver, pci_id, xmx_ready, and "needs":
## [{"what", "have", "want", "ok", "line"}] for anything a route here depends on.
static func record(profile: Dictionary, sys: Dictionary = {}) -> Dictionary:
	var dev: Dictionary = sys.get("gpu_dev", {}) if sys.get("gpu_dev") is Dictionary else {}
	var g := gpu(profile, dev)
	var t: String = g["tier"]
	var mem: Dictionary = sys.get("memory", {}) if sys.get("memory") is Dictionary else {}
	var mesa := str(sys.get("mesa", ""))
	var kernel := str(sys.get("kernel", ""))
	var driver := str(dev.get("driver", ""))
	var needs: Array = []
	if FSR4.has(t) and t != "intel_xmx":
		var ok := _at_least(_version(mesa), MESA_FSR4)
		needs.append({"what": "mesa", "have": mesa, "want": "25.2", "ok": ok,
			"line": "" if ok else "FSR 4 needs Mesa 25.2 or newer; this system has %s. Update the system, FSR 3.1 is used until then." % mesa})
	if t == "intel_xmx":
		var ok_drv := driver in ["", "xe", "i915"]
		needs.append({"what": "kernel driver", "have": driver, "want": "xe or i915", "ok": ok_drv,
			"line": "" if ok_drv else "The XMX cores need the xe or i915 kernel driver."})
		var ready := bool(sys.get("xess_xmx", false))
		needs.append({"what": "XeSS XMX driver", "have": "installed" if ready else "", "want": "installed", "ok": ready,
			"line": "" if ready else "The XeSS XMX driver isn't installed yet: XeSS runs slower and frame generation stops at 2x until it is."})
	var rec := g.duplicate()
	rec.merge({
		"upscalers": upscalers(g), "frame_gens": frame_gens(g), "generators": generators(g), "latency": latency(g),
		"fsr4": str(FSR4.get(t, "")), "fsr4_model": str(FSR4_MODEL.get(t, "")), "fsr4_listed": t in FSR4_LISTED,
		"proton_fsr4": t in PROTON_FSR4, "max_fg": int(frame_gens(g).max()),
		"vram_mb": int(mem.get("vram_mb", 0)), "shared_mb": int(mem.get("total_mb", 0)),
		"mesa": mesa, "kernel": kernel, "driver": driver, "pci_id": str(dev.get("pci_id", "")),
		"xmx_ready": t == "intel_xmx" and bool(sys.get("xess_xmx", false)), "needs": needs,
	})
	return rec


## One plain line for the Upscaling card: what this chip gets.
static func summary(rec: Dictionary) -> String:
	match str(rec.get("tier", "other")):
		"intel_xmx":
			return "Intel Arc with XMX: FSR 4.1.2 and XeSS 2 on the XMX cores, XeSS frame generation up to 4x, XeLL low latency."
		"intel":
			return "Intel Arc: XeSS 2 and XeSS frame generation 2x. This chip has no XMX cores."
		"amd_rdna4", "amd_halo", "amd_rdna35", "amd_rdna3":
			return "AMD Radeon: FSR 4.1.2 (%s model), FSR or XeSS frame generation 2x, Anti-Lag 2." % rec.get("fsr4_model", "INT8")
		"amd_z2a", "amd_rdna2":
			return "AMD Radeon: FSR 3.1 by default, FSR 4.1.2 if you want it (it costs frames here), FSR frame generation 2x."
		"amd_old":
			return "This graphics chip is too old for newer upscalers: games use their own."
		"nvidia":
			return "NVIDIA: games keep their own DLSS, frame generation and Reflex. Lossless frame generation works for the rest."
	return "Unknown graphics chip: games use their own settings."

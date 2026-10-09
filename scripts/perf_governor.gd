extends Node

# Adaptive performance governor (autoload: PerfGovernor).
#
# Two layers of defense, both driven by the REAL frame time (the _process
# delta — honest here because the project ships with vsync off):
#
# 1) CONTINUOUS `quality_scale` in [MIN_SCALE, 1.0] — unchanged contract from
#    v1. The expensive VFX budgets (violence.gd blast caps, gpu_debris pools,
#    casing cap, gibs, blood splats) multiply their counts by it, so a machine
#    that sags sheds the priciest effects first and eases back with headroom.
#
# 2) REASON-AWARE shedding — when fps stays below the targets we don't just
#    dim everything, we look at WHY the frame is slow:
#      - CPU work  = script process + physics (Performance monitors)
#      - GPU work  = measured render time on the root viewport
#    GPU-bound   → step the 3D render scale down a ladder (fill-rate is the
#                  dominant GPU cost here: smoke/fire overdraw; resolution is
#                  ~quadratic, so 0.7x scale ≈ half the pixels). HUD stays
#                  native-res; only the 3D buffer shrinks.
#    Sustained low fps (either axis) → discrete cosmetic sheds, cheapest
#    visual loss first:
#      L1: brass casings stop spawning (active rigid bodies are the top
#          frame-hitch driver) + gpu_debris snapshot rasters budgeted 1/frame.
#      L2: full blasts downgrade to cheap flares (kills the smoke/distortion
#          stack — the worst GPU fill AND a chunk of CPU spawn cost).
#    The discrete sheds are deliberately classification-INDEPENDENT (they help
#    both axes and cost little when wrong); only the expensive lever — render
#    resolution — is gated on the CPU/GPU verdict.
#
# Everything shed here is cosmetic and local-only: bullets, damage, and RPCs
# are untouched, so peers at different tiers stay consistent.
#
# All v2 behavior is disabled under BenchFlags.active — benches A/B fixed
# workloads and a governor moving render scale mid-run would corrupt them.

# --- continuous quality curve (v1 contract, unchanged) ---
# At/above this measured fps, run everything at full quality (scale = 1.0).
const FULL_QUALITY_FPS := 200.0
# At/below this fps, clamp to MIN_SCALE — framerate-survival mode.
const MIN_QUALITY_FPS := 90.0
# Floor for the scale: even under heavy load explosions never fully vanish.
const MIN_SCALE := 0.34
# EMA weight for the frame-time average. Small = smoother (a lone hitch won't
# yank quality); ~0.1 tracks roughly the last couple dozen frames.
const FRAME_EMA := 0.1
# Asymmetric response: drop quality fast when frames slow (protect fps), recover
# slowly so effects don't visibly pop in/out (hysteresis against oscillation).
const FALL_LERP := 0.25
const RISE_LERP := 0.03
# Ignore frame-time spikes above this (loading stalls, alt-tab) so a single huge
# delta doesn't read as ~0 fps and slam quality to the floor.
const MAX_FRAME_MS := 100.0

# --- discrete shed tiers (engage below, release above; gap = hysteresis) ---
const SHED1_ENGAGE_FPS := 72.0   # casings off, debris raster 1/frame
const SHED1_RELEASE_FPS := 88.0
const SHED2_ENGAGE_FPS := 55.0   # cheap explosions only
const SHED2_RELEASE_FPS := 72.0
# Sustained-time gates so a 2-second firefight spike doesn't flap features.
const SHED_ENGAGE_SEC := 1.5
const SHED_RELEASE_SEC := 4.0

# --- dynamic 3D render scale (GPU-bound only) ---
const RENDER_SCALES: Array[float] = [1.0, 0.85, 0.7, 0.55]
const RSCALE_ENGAGE_FPS := 80.0   # gpu-bound below this → step down
const RSCALE_RELEASE_FPS := 100.0 # comfortable above this → step back up
const RSCALE_DWELL_SEC := 4.0     # min seconds between any two scale changes
# A frame is "GPU-bound" when measured GPU time dominates the frame budget and
# clearly exceeds the CPU-side work.
const GPU_BOUND_FRAME_FRAC := 0.7
const GPU_OVER_CPU_FACTOR := 1.2

var quality_scale: float = 1.0
# Discrete shed state — consumers read these directly (they're the API):
var casings_enabled: bool = true          # procedural_gun.eject_casing
var full_blasts_allowed: bool = true      # violence.gd blast claim
var debris_jobs_per_flush: int = 99       # gpu_debris.flush_pending budget
var shed_level: int = 0                   # 0 = none, 1, 2

var _avg_frame_ms: float = 1000.0 / 240.0
var _avg_cpu_ms: float = 2.0     # script process + physics, EMA
var _avg_gpu_ms: float = 2.0     # measured root-viewport render time, EMA
var _avg_rcpu_ms: float = 0.0    # measured render-thread CPU (draw submission), EMA
var _gpu_time_supported: bool = false
var _rscale_idx: int = 0
var _rscale_cooldown: float = 0.0
var _below_sec: Array[float] = [0.0, 0.0]  # sustained-below timers per tier
var _above_sec: Array[float] = [0.0, 0.0]  # sustained-above timers per tier
var _headless: bool = false


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	_probe_on = OS.has_environment("GG_PERF_PROBE")
	if _probe_on:
		print("[perf-probe] enabled — cycling %s every 6s" % str(_PROBE_STATES))
	if not _headless:
		# Ask the renderer to time the root viewport so we can tell CPU-bound
		# from GPU-bound frames. Costs a couple of timestamp queries per frame.
		RenderingServer.viewport_set_measure_render_time(
			get_viewport().get_viewport_rid(), true)


func _process(delta: float) -> void:
	var frame_ms: float = minf(delta * 1000.0, MAX_FRAME_MS)
	_avg_frame_ms = lerpf(_avg_frame_ms, frame_ms, FRAME_EMA)
	var fps: float = 1000.0 / maxf(_avg_frame_ms, 0.001)

	# v1 continuous curve.
	var t: float = clampf(inverse_lerp(MIN_QUALITY_FPS, FULL_QUALITY_FPS, fps), 0.0, 1.0)
	var target: float = lerpf(MIN_SCALE, 1.0, t)
	var rate: float = FALL_LERP if target < quality_scale else RISE_LERP
	quality_scale = lerpf(quality_scale, target, rate)

	if BenchFlags.active or _headless:
		return

	_measure_cpu_gpu()
	_update_shed_tiers(fps, delta)
	if _probe_on:
		_probe_tick(delta)  # probe owns render scale while active
	else:
		_update_render_scale(fps, delta)


func _measure_cpu_gpu() -> void:
	var cpu_ms := (
		Performance.get_monitor(Performance.TIME_PROCESS)
		+ Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	) * 1000.0
	_avg_cpu_ms = lerpf(_avg_cpu_ms, minf(cpu_ms, MAX_FRAME_MS), FRAME_EMA)
	var gpu_ms := 0.0
	var rcpu_ms := 0.0
	for vp: Viewport in _rendering_viewports():
		var rid := vp.get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(rid, true)
		gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		rcpu_ms += RenderingServer.viewport_get_measured_render_time_cpu(rid)
	if gpu_ms > 0.01:
		_gpu_time_supported = true
	if _gpu_time_supported:
		_avg_gpu_ms = lerpf(_avg_gpu_ms, minf(gpu_ms, MAX_FRAME_MS), FRAME_EMA)
	_avg_rcpu_ms = lerpf(_avg_rcpu_ms, minf(rcpu_ms, MAX_FRAME_MS), FRAME_EMA)


func is_gpu_bound() -> bool:
	if _gpu_time_supported:
		return (
			_avg_gpu_ms > _avg_frame_ms * GPU_BOUND_FRAME_FRAC
			and _avg_gpu_ms > _avg_cpu_ms * GPU_OVER_CPU_FACTOR
		)
	# No GPU timestamps on this driver: if script+physics only accounts for a
	# minority of the frame, the rest is render/present — treat as GPU-bound.
	return _avg_cpu_ms < _avg_frame_ms * 0.5


func _update_shed_tiers(fps: float, delta: float) -> void:
	var engage: Array[float] = [SHED1_ENGAGE_FPS, SHED2_ENGAGE_FPS]
	var release: Array[float] = [SHED1_RELEASE_FPS, SHED2_RELEASE_FPS]
	for i: int in 2:
		var tier := i + 1
		if fps < engage[i]:
			_below_sec[i] += delta
			_above_sec[i] = 0.0
			if shed_level < tier and _below_sec[i] >= SHED_ENGAGE_SEC:
				shed_level = tier
		elif fps > release[i]:
			_above_sec[i] += delta
			_below_sec[i] = 0.0
			if shed_level >= tier and _above_sec[i] >= SHED_RELEASE_SEC:
				shed_level = tier - 1
				_above_sec[i] = 0.0
		else:
			_below_sec[i] = 0.0
			_above_sec[i] = 0.0
	casings_enabled = shed_level < 1
	debris_jobs_per_flush = 1 if shed_level >= 1 else 99
	full_blasts_allowed = shed_level < 2


func _update_render_scale(fps: float, delta: float) -> void:
	_rscale_cooldown = maxf(_rscale_cooldown - delta, 0.0)
	if _rscale_cooldown > 0.0:
		return
	if fps < RSCALE_ENGAGE_FPS and is_gpu_bound() and _rscale_idx < RENDER_SCALES.size() - 1:
		_rscale_idx += 1
	elif fps > RSCALE_RELEASE_FPS and _rscale_idx > 0:
		_rscale_idx -= 1
	else:
		return
	for vp: Viewport in _rendering_viewports():
		vp.scaling_3d_scale = RENDER_SCALES[_rscale_idx]
	_rscale_cooldown = RSCALE_DWELL_SEC


# Where the 3D actually gets drawn: in a match that is each player's view
# (RenderPlayer SubViewports), in the menus the window itself.
func _rendering_viewports() -> Array[Viewport]:
	var out: Array[Viewport] = []
	for node in get_tree().get_nodes_in_group(&"player_views"):
		out.append(node as Viewport)
	if out.is_empty():
		out.append(get_viewport())
	return out


# --- In-game bottleneck probe (GG_PERF_PROBE=1, debug diagnostics only) ----
# The lab can't reproduce the carved-late-round frame cost, so this cycles
# the suspects LIVE during a real match, 6s per state, and prints each
# switch. Read the [trace] 1s lines per state: whichever toggle moves
# avg frame time names the bottleneck (draws/shadows vs fill vs neither).
const _PROBE_STATES: Array[String] = ["normal", "no-shadows", "rscale-0.5", "normal2"]
var _probe_on: bool = false
var _probe_i: int = -1
var _probe_t: float = 0.0


func _probe_tick(delta: float) -> void:
	_probe_t -= delta
	if _probe_t > 0.0:
		return
	_probe_t = 6.0
	_probe_i = (_probe_i + 1) % _PROBE_STATES.size()
	var state := _PROBE_STATES[_probe_i]
	var suns: Array[Node] = []
	var scene := get_tree().current_scene
	if scene:
		suns = scene.find_children("", "DirectionalLight3D", true, false)
	for s in suns:
		(s as DirectionalLight3D).shadow_enabled = state != "no-shadows"
	get_viewport().scaling_3d_scale = 0.5 if state == "rscale-0.5" else 1.0
	print("[perf-probe] state=%s (frame avg follows in trace 1s lines)" % state)


# Smoothed fps estimate — handy for HUD/debug readouts.
func smoothed_fps() -> float:
	return 1000.0 / maxf(_avg_frame_ms, 0.001)


func render_scale() -> float:
	return RENDER_SCALES[_rscale_idx]


func bound_label() -> String:
	if smoothed_fps() >= SHED1_RELEASE_FPS and _rscale_idx == 0:
		return "ok"
	return "gpu" if is_gpu_bound() else "cpu"


# One-line state dump for trace lines / debugging.
func debug_state() -> String:
	return "fps=%.0f cpu=%.1f rcpu=%.1f gpu=%s bnd=%s qs=%.2f rs=%.2f shed=%d" % [
		smoothed_fps(), _avg_cpu_ms, _avg_rcpu_ms,
		("%.1f" % _avg_gpu_ms) if _gpu_time_supported else "n/a",
		bound_label(), quality_scale, render_scale(), shed_level,
	]

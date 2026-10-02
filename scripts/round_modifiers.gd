class_name RoundModifiers
extends RefCounted

# Server picks one ID per round; Game.current_round_modifier holds the active
# choice on every peer (synced via _set_round_modifier.rpc).

const IDS: PackedStringArray = [
	"low_gravity",
	"fog",
	"supply_storm",
	"sudden_death",
	"headshots_only",
	"boom_boom",
	"brrrrt",
	"gun_swap",
	"sniper_fight",
	"air_strikes",
	"ion_cannon",
	"blackout",
]

const GRAVITY_MULT := 0.6          # −40% gravity
const BULLET_DROP_MULT := 0.6      # −40% bullet drop
const BODY_DAMAGE_MULT := 0.25     # headshots_only body hits
const PICKUP_SPAWN_MULT := 3.0     # supply_storm
const SNIPER_ARENA_SIZE_MIN := 110.0
const SNIPER_ARENA_SIZE_MAX := 120.0
const FOG_DEPTH_BEGIN := 8.0
const FOG_DEPTH_END := 28.0
const FOG_DENSITY := 0.92
const MODIFIER_CHANCE := 0.3       # fraction of rounds that roll a modifier


static func pick_for_round(chance: float = MODIFIER_CHANCE) -> String:
	if randf() >= clampf(chance, 0.0, 1.0):
		return ""
	return IDS[randi() % IDS.size()]


static func pick_random() -> String:
	return IDS[randi() % IDS.size()]


static func display_info(mod_id: String) -> Dictionary:
	match mod_id:
		"low_gravity":
			return {
				"title": "LOW GRAVITY",
				"subtitle": "Floatier jumps & bullets",
				"color": Color(0.55, 0.85, 1.0),
			}
		"fog":
			return {
				"title": "FOG",
				"subtitle": "Short view distance",
				"color": Color(0.72, 0.78, 0.88),
			}
		"supply_storm":
			return {
				"title": "SUPPLY STORM",
				"subtitle": "Sky drops spawn 3× faster",
				"color": Color(0.45, 1.0, 0.65),
			}
		"sudden_death":
			return {
				"title": "SUDDEN DEATH",
				"subtitle": "Lava rises immediately",
				"color": Color(1.0, 0.42, 0.18),
			}
		"headshots_only":
			return {
				"title": "HEADSHOTS ONLY",
				"subtitle": "Body damage ×¼",
				"color": Color(1.0, 0.55, 0.55),
			}
		"boom_boom":
			return {
				"title": "BOOM BOOM",
				"subtitle": "Explosive rounds for everyone",
				"color": Color(1.0, 0.62, 0.15),
			}
		"brrrrt":
			return {
				"title": "BRRRRT",
				"subtitle": "10× fire rate & ammo for everyone",
				"color": Color(1.0, 0.78, 0.35),
			}
		"gun_swap":
			return {
				"title": "GUN SWAP",
				"subtitle": "You spawn with someone else's loadout",
				"color": Color(0.82, 0.48, 1.0),
			}
		"sniper_fight":
			return {
				"title": "SNIPER FIGHT",
				"subtitle": "RMB zoom · 10× precision · 10× bullet speed",
				"color": Color(0.55, 0.88, 1.0),
			}
		"air_strikes":
			return {
				"title": "AIR STRIKES",
				"subtitle": "Random rockets from the sky",
				"color": Color(1.0, 0.28, 0.12),
			}
		"ion_cannon":
			return {
				"title": "ION CANNON",
				"subtitle": "Orbital beams from above",
				"color": Color(0.35, 0.72, 1.0),
			}
		"blackout":
			return {
				"title": "BLACKOUT",
				"subtitle": "Lights out — use your flashlight",
				"color": Color(0.3, 0.32, 0.45),
			}
		_:
			return {"title": "", "subtitle": "", "color": Color.WHITE}


static func announce(mod_id: String) -> String:
	var info: Dictionary = display_info(mod_id)
	return str(info.title)


static func gravity_mult(mod_id: String) -> float:
	return GRAVITY_MULT if mod_id == "low_gravity" else 1.0


static func bullet_drop_mult(mod_id: String) -> float:
	return BULLET_DROP_MULT if mod_id == "low_gravity" else 1.0


static func body_damage_mult(mod_id: String) -> float:
	return BODY_DAMAGE_MULT if mod_id == "headshots_only" else 1.0


static func pickup_spawn_mult(mod_id: String) -> float:
	return PICKUP_SPAWN_MULT if mod_id == "supply_storm" else 1.0


static func spawn_starting_pickup(mod_id: String) -> bool:
	return mod_id == "supply_storm"


static func needs_air_strikes(mod_id: String) -> bool:
	return mod_id == "air_strikes"


static func needs_ion_cannon(mod_id: String) -> bool:
	return mod_id == "ion_cannon"


static func apply_fog_environment(env: Environment) -> void:
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_depth_begin = FOG_DEPTH_BEGIN
	env.fog_depth_end = FOG_DEPTH_END
	env.fog_depth_curve = 1.0
	# Depth fog uses density as max opacity — palette values (~0.012) are
	# fine for exponential haze but are invisible in depth mode.
	env.fog_density = FOG_DENSITY
	env.fog_aerial_perspective = 0.35


static func lava_immediate(mod_id: String) -> bool:
	return mod_id == "sudden_death"


static func applies_weapon(mod_id: String) -> bool:
	return mod_id == "boom_boom" or mod_id == "brrrrt" or mod_id == "sniper_fight"


static func needs_gun_swap(mod_id: String) -> bool:
	return mod_id == "gun_swap"


static func arena_size_range(mod_id: String) -> Vector2:
	if mod_id == "sniper_fight":
		return Vector2(SNIPER_ARENA_SIZE_MIN, SNIPER_ARENA_SIZE_MAX)
	return Vector2(-1.0, -1.0)


static func apply_weapon(w: Weapon, mod_id: String) -> void:
	match mod_id:
		"boom_boom":
			if w.explosive_radius <= 0.0:
				w.explosive_radius += 4.0
			else:
				w.explosive_radius += 2.5
			w.explosive_damage += 25.0
			w.bullet_color = w.bullet_color.lerp(Color(1.0, 0.45, 0.08), 0.45)
		"brrrrt":
			var mag_before: int = w.get_mag_size()
			w.fire_rate_mult *= 10.0
			w.mag_size_bonus += max(0, mag_before * 9)
		"sniper_fight":
			w.special = Weapon.SPECIAL_ZOOM
			w.spread *= 0.1
			w.bullet_speed_mult *= 10.0
			w.bullet_color = w.bullet_color.lerp(Color(0.55, 0.85, 1.0), 0.35)
		_:
			pass

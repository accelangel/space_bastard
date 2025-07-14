# Scripts/Systems/PIDTuningObserver.gd - Observes combat events during PID tuning
extends Node
class_name PIDTuningObserver

# Cycle tracking
var current_cycle_events: Array = []
var cycle_start_time: float = 0.0
var torpedoes_fired: int = 0
var torpedoes_hit: int = 0
var torpedoes_missed: int = 0
var miss_reasons: Dictionary = {}

func _ready():
	add_to_group("battle_observers")
	GameMode.mode_changed.connect(_on_mode_changed)
	set_process(false)

func _on_mode_changed(new_mode: GameMode.Mode):
	set_process(new_mode == GameMode.Mode.PID_TUNING)
	if new_mode == GameMode.Mode.PID_TUNING:
		reset_cycle_data()

func reset_cycle_data():
	current_cycle_events.clear()
	cycle_start_time = Time.get_ticks_msec() / 1000.0
	torpedoes_fired = 0
	torpedoes_hit = 0
	torpedoes_missed = 0
	miss_reasons.clear()

func on_entity_spawned(entity: Node2D, entity_type: String):
	if not GameMode.is_pid_tuning_mode():
		return
	
	if entity_type == "torpedo":
		torpedoes_fired += 1
		var event = {
			"type": "torpedo_fired",
			"torpedo_id": entity.get("torpedo_id"),
			"timestamp": Time.get_ticks_msec() / 1000.0
		}
		current_cycle_events.append(event)

func on_entity_dying(entity: Node2D, reason: String):
	if not GameMode.is_pid_tuning_mode():
		return
	
	if entity.is_in_group("torpedoes"):
		var event = {
			"type": "torpedo_destroyed",
			"torpedo_id": entity.get("torpedo_id"),
			"reason": reason,
			"timestamp": Time.get_ticks_msec() / 1000.0,
			"position": entity.global_position
		}
		
		# Track hits vs misses
		if reason == "ship_impact":
			torpedoes_hit += 1
		else:
			torpedoes_missed += 1
			if not miss_reasons.has(reason):
				miss_reasons[reason] = 0
			miss_reasons[reason] += 1
			
			# Get closest approach distance if available
			if "closest_approach_distance" in entity:
				event["closest_approach"] = entity.closest_approach_distance
		
		current_cycle_events.append(event)

func get_cycle_results() -> Dictionary:
	return {
		"total_fired": torpedoes_fired,
		"hits": torpedoes_hit,
		"misses": torpedoes_missed,
		"hit_rate": float(torpedoes_hit) / float(torpedoes_fired) if torpedoes_fired > 0 else 0.0,
		"miss_reasons": miss_reasons,
		"cycle_duration": (Time.get_ticks_msec() / 1000.0) - cycle_start_time,
		"events": current_cycle_events
	}

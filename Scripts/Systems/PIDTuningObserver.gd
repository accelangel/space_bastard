# Scripts/Systems/PIDTuningObserver.gd - Frame-rate independent observer
extends Node
class_name PIDTuningObserver

# Cycle tracking
var current_cycle_events: Array = []
var cycle_start_time: float = 0.0
var torpedoes_fired: int = 0
var torpedoes_hit: int = 0
var torpedoes_missed: int = 0
var miss_reasons: Dictionary = {}

# Quality tracking
var orientation_errors: Array = []
var oscillation_scores: Array = []
var closest_approaches: Array = []

# Timer-based sampling (not frame-based)
var sample_timer: float = 0.0
var sample_interval: float = 0.1  # Sample every 0.1 seconds

func _ready():
	add_to_group("battle_observers")
	GameMode.mode_changed.connect(_on_mode_changed)
	set_process(false)

func _on_mode_changed(new_mode: GameMode.Mode):
	set_process(new_mode == GameMode.Mode.PID_TUNING)
	if new_mode == GameMode.Mode.PID_TUNING:
		reset_cycle_data()

func _process(delta):
	if not GameMode.is_pid_tuning_mode():
		return
	
	# Timer-based sampling instead of frame counting
	sample_timer += delta
	if sample_timer >= sample_interval:
		sample_timer = 0.0
		sample_torpedo_quality()

func sample_torpedo_quality():
	"""Sample torpedo quality metrics for gradient descent"""
	var torpedoes = get_tree().get_nodes_in_group("torpedoes")
	
	for torpedo in torpedoes:
		if not is_instance_valid(torpedo) or torpedo.get("marked_for_death"):
			continue
		
		# Get velocity and orientation
		var velocity = torpedo.get("velocity_mps")
		var orientation = torpedo.get("orientation")
		
		if velocity and velocity.length() > 10.0:  # Only measure if moving
			# Orientation quality: how well aligned is orientation with velocity
			var velocity_angle = velocity.angle()
			var orientation_error = abs(_angle_difference(orientation, velocity_angle))
			orientation_errors.append(orientation_error)
			
			# Oscillation detection (would need previous orientation stored)
			if torpedo.has_meta("prev_orientation"):
				var prev_orientation = torpedo.get_meta("prev_orientation")
				var orientation_change = abs(_angle_difference(orientation, prev_orientation))
				oscillation_scores.append(orientation_change / sample_interval)
			torpedo.set_meta("prev_orientation", orientation)

func reset_cycle_data():
	current_cycle_events.clear()
	cycle_start_time = Time.get_ticks_msec() / 1000.0
	torpedoes_fired = 0
	torpedoes_hit = 0
	torpedoes_missed = 0
	miss_reasons.clear()
	orientation_errors.clear()
	oscillation_scores.clear()
	closest_approaches.clear()
	sample_timer = 0.0

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
				closest_approaches.append(entity.closest_approach_distance)
		
		current_cycle_events.append(event)

func get_cycle_results() -> Dictionary:
	# Calculate quality metrics
	var avg_orientation_error = 0.0
	var avg_orientation_quality = 1.0
	if orientation_errors.size() > 0:
		for error in orientation_errors:
			avg_orientation_error += error
		avg_orientation_error /= orientation_errors.size()
		# Convert to quality score (1.0 = perfect alignment, 0.0 = 90° off)
		avg_orientation_quality = cos(avg_orientation_error)
	
	var avg_oscillation = 0.0
	if oscillation_scores.size() > 0:
		for score in oscillation_scores:
			avg_oscillation += score
		avg_oscillation /= oscillation_scores.size()
		# Normalize to 0-1 range (0 = no oscillation, 1 = extreme)
		avg_oscillation = clamp(avg_oscillation / (2 * PI), 0.0, 1.0)
	
	var avg_closest = 0.0
	if closest_approaches.size() > 0:
		for dist in closest_approaches:
			avg_closest += dist
		avg_closest /= closest_approaches.size()
	
	return {
		"total_fired": torpedoes_fired,
		"hits": torpedoes_hit,
		"misses": torpedoes_missed,
		"hit_rate": float(torpedoes_hit) / float(torpedoes_fired) if torpedoes_fired > 0 else 0.0,
		"miss_reasons": miss_reasons,
		"cycle_duration": (Time.get_ticks_msec() / 1000.0) - cycle_start_time,
		"events": current_cycle_events,
		"avg_orientation_error": avg_orientation_error,
		"avg_orientation_quality": avg_orientation_quality,
		"avg_oscillation_score": avg_oscillation,
		"avg_closest_approach": avg_closest
	}

func _angle_difference(from: float, to: float) -> float:
	var diff = to - from
	while diff > PI:
		diff -= TAU
	while diff < -PI:
		diff += TAU
	return diff

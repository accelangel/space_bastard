# Scripts/Systems/MPCTuningObserver.gd - MPC Performance Tracking
extends Node
class_name MPCTuningObserver

# Cycle tracking
var current_cycle_events: Array = []
var cycle_start_time: float = 0.0
var torpedoes_fired: int = 0
var torpedoes_hit: int = 0
var torpedoes_missed: int = 0
var miss_reasons: Dictionary = {}

# Torpedo outcome tracking
var torpedo_outcomes: Array = []

# Quality metrics
var trajectory_smoothness_samples: Array = []
var alignment_errors: Array = []
var control_effort_samples: Array = []
var computation_times: Array = []

# Type-specific metrics
var multi_angle_separations: Array = []
var simultaneous_impact_times: Array = []
var simultaneous_approach_angles: Array = []

# Current trajectory type being tested
var current_trajectory_type: String = ""

# Timer-based sampling
var sample_timer: float = 0.0
var sample_interval: float = 0.1  # Sample every 0.1 seconds

func _ready():
	add_to_group("battle_observers")
	add_to_group("mpc_observers")
	GameMode.mode_changed.connect(_on_mode_changed)
	set_process(false)

func _on_mode_changed(new_mode: GameMode.Mode):
	set_process(new_mode == GameMode.Mode.MPC_TUNING)
	if new_mode == GameMode.Mode.MPC_TUNING:
		reset_cycle_data()

func _process(delta):
	if not GameMode.is_mpc_tuning_mode():
		return
	
	sample_timer += delta
	if sample_timer >= sample_interval:
		sample_timer = 0.0
		sample_torpedo_performance()

func sample_torpedo_performance():
	"""Sample MPC-specific performance metrics"""
	var torpedoes = get_tree().get_nodes_in_group("torpedoes")
	
	for torpedo in torpedoes:
		if not is_instance_valid(torpedo) or torpedo.get("marked_for_death"):
			continue
		
		# Sample trajectory smoothness (if torpedo has MPC controller)
		if torpedo.has_method("get_trajectory_smoothness"):
			var smoothness = torpedo.get_trajectory_smoothness()
			trajectory_smoothness_samples.append(smoothness)
		
		# Sample alignment quality
		var velocity = torpedo.get("velocity_mps")
		var orientation = torpedo.get("orientation")
		
		if velocity and velocity.length() > 10.0:
			var velocity_angle = velocity.angle()
			var alignment_error = abs(_angle_difference(orientation, velocity_angle))
			alignment_errors.append(alignment_error)
		
		# Sample computation time if available
		if torpedo.has_method("get_last_mpc_compute_time"):
			var compute_time = torpedo.get_last_mpc_compute_time()
			if compute_time > 0:
				computation_times.append(compute_time)

func reset_cycle_data():
	current_cycle_events.clear()
	cycle_start_time = Time.get_ticks_msec() / 1000.0
	torpedoes_fired = 0
	torpedoes_hit = 0
	torpedoes_missed = 0
	miss_reasons.clear()
	torpedo_outcomes.clear()
	trajectory_smoothness_samples.clear()
	alignment_errors.clear()
	control_effort_samples.clear()
	computation_times.clear()
	multi_angle_separations.clear()
	simultaneous_impact_times.clear()
	simultaneous_approach_angles.clear()
	sample_timer = 0.0

func set_trajectory_type(type: String):
	current_trajectory_type = type

func on_entity_spawned(entity: Node2D, entity_type: String):
	if not GameMode.is_mpc_tuning_mode():
		return
	
	if entity_type == "torpedo":
		torpedoes_fired += 1
		
		# Track torpedo data
		var torpedo_data = {
			"torpedo_id": entity.get("torpedo_id"),
			"launch_time": Time.get_ticks_msec() / 1000.0,
			"launch_side": entity.get("launch_side"),
			"template": entity.get_meta("mpc_template") if entity.has_meta("mpc_template") else null,
			"hit": false,
			"miss_reason": "",
			"impact_time": 0.0,
			"closest_approach": INF,
			"trajectory_smoothness": 0.0,
			"avg_alignment_error": 0.0,
			"impact_alignment_error": 0.0,
			"total_control_effort": 0.0
		}
		
		torpedo_outcomes.append(torpedo_data)

func on_entity_dying(entity: Node2D, reason: String):
	if not GameMode.is_mpc_tuning_mode():
		return
	
	if entity.is_in_group("torpedoes"):
		var torpedo_id = entity.get("torpedo_id")
		var impact_time = Time.get_ticks_msec() / 1000.0
		
		# Find torpedo data
		var torpedo_data = null
		for data in torpedo_outcomes:
			if data.torpedo_id == torpedo_id:
				torpedo_data = data
				break
		
		if not torpedo_data:
			return
		
		# Update outcome
		torpedo_data.impact_time = impact_time
		
		if reason == "ship_impact":
			torpedoes_hit += 1
			torpedo_data.hit = true
			
			# Track impact metrics
			var velocity = entity.get("velocity_mps")
			var orientation = entity.get("orientation")
			
			if velocity and velocity.length() > 10.0:
				var velocity_angle = velocity.angle()
				var alignment_error = abs(_angle_difference(orientation, velocity_angle))
				torpedo_data.impact_alignment_error = rad_to_deg(alignment_error)
			
			# Track position for type-specific analysis
			if current_trajectory_type == "multi_angle":
				track_multi_angle_impact(entity)
			elif current_trajectory_type == "simultaneous":
				track_simultaneous_impact(entity, impact_time)
			
		else:
			torpedoes_missed += 1
			torpedo_data.miss_reason = reason
			
			if not miss_reasons.has(reason):
				miss_reasons[reason] = 0
			miss_reasons[reason] += 1
			
			# Get closest approach if available
			if "closest_approach_distance" in entity:
				torpedo_data.closest_approach = entity.closest_approach_distance
		
		# Get final trajectory metrics if available
		if entity.has_method("get_trajectory_smoothness"):
			torpedo_data.trajectory_smoothness = entity.get_trajectory_smoothness()
		
		# Store event
		var event = {
			"type": "torpedo_destroyed",
			"torpedo_id": torpedo_id,
			"reason": reason,
			"timestamp": impact_time,
			"position": entity.global_position
		}
		current_cycle_events.append(event)

func on_torpedo_miss(miss_data: Dictionary):
	"""Called by MPC torpedoes when they miss"""
	if not GameMode.is_mpc_tuning_mode():
		return
	
	# Update torpedo outcome data
	for data in torpedo_outcomes:
		if data.torpedo_id == miss_data.get("torpedo_id"):
			data.closest_approach = miss_data.get("closest_approach", INF)
			data.trajectory_smoothness = miss_data.get("trajectory_smoothness", 0.0)
			break

func on_torpedo_hit(hit_data: Dictionary):
	"""Called by MPC torpedoes when they hit"""
	if not GameMode.is_mpc_tuning_mode():
		return
	
	# Update torpedo outcome data
	for data in torpedo_outcomes:
		if data.torpedo_id == hit_data.get("torpedo_id"):
			data.trajectory_smoothness = hit_data.get("trajectory_smoothness", 0.0)
			break

func track_multi_angle_impact(torpedo: Node2D):
	"""Track impact angles for multi-angle analysis"""
	var velocity = torpedo.get("velocity_mps")
	if velocity and velocity.length() > 10.0:
		var impact_angle = velocity.angle()
		var launch_side = torpedo.get("launch_side")
		
		multi_angle_separations.append({
			"angle": impact_angle,
			"side": launch_side,
			"position": torpedo.global_position
		})

func track_simultaneous_impact(torpedo: Node2D, impact_time: float):
	"""Track impact timing and angles for simultaneous analysis"""
	simultaneous_impact_times.append(impact_time)
	
	var velocity = torpedo.get("velocity_mps")
	if velocity and velocity.length() > 10.0:
		var approach_angle = velocity.angle()
		simultaneous_approach_angles.append(approach_angle)

func analyze_type_specific_performance() -> Dictionary:
	"""Analyze performance specific to trajectory type"""
	var metrics = {}
	
	match current_trajectory_type:
		"multi_angle":
			if multi_angle_separations.size() >= 2:
				# Group by side and calculate average angles
				var port_angles = []
				var starboard_angles = []
				
				for data in multi_angle_separations:
					if data.side == -1:
						port_angles.append(data.angle)
					else:
						starboard_angles.append(data.angle)
				
				if port_angles.size() > 0 and starboard_angles.size() > 0:
					var port_avg = _calculate_average_angle(port_angles)
					var starboard_avg = _calculate_average_angle(starboard_angles)
					var separation = abs(_angle_difference(port_avg, starboard_avg))
					
					metrics["angle_separation"] = rad_to_deg(separation)
					metrics["separation_error"] = rad_to_deg(abs(separation - PI/2))
					metrics["port_count"] = port_angles.size()
					metrics["starboard_count"] = starboard_angles.size()
		
		"simultaneous":
			if simultaneous_impact_times.size() >= 2:
				# Calculate time spread
				var min_time = simultaneous_impact_times[0]
				var max_time = simultaneous_impact_times[0]
				
				for time in simultaneous_impact_times:
					min_time = min(min_time, time)
					max_time = max(max_time, time)
				
				var time_spread = max_time - min_time
				metrics["impact_time_spread"] = time_spread
				
				# Calculate angle spread
				if simultaneous_approach_angles.size() >= 2:
					var angle_spread = _calculate_angle_spread(simultaneous_approach_angles)
					metrics["approach_angle_spread"] = rad_to_deg(angle_spread)
	
	return metrics

func get_cycle_results() -> Dictionary:
	# Calculate averages
	var avg_smoothness = 0.0
	if trajectory_smoothness_samples.size() > 0:
		for sample in trajectory_smoothness_samples:
			avg_smoothness += sample
		avg_smoothness /= trajectory_smoothness_samples.size()
	
	var avg_alignment_error = 0.0
	if alignment_errors.size() > 0:
		for error in alignment_errors:
			avg_alignment_error += error
		avg_alignment_error /= alignment_errors.size()
	
	var avg_compute_time = 0.0
	if computation_times.size() > 0:
		for time in computation_times:
			avg_compute_time += time
		avg_compute_time /= computation_times.size()
	
	# Get type-specific metrics
	var type_metrics = analyze_type_specific_performance()
	
	var results = {
		"total_fired": torpedoes_fired,
		"hits": torpedoes_hit,
		"misses": torpedoes_missed,
		"hit_rate": float(torpedoes_hit) / float(torpedoes_fired) if torpedoes_fired > 0 else 0.0,
		"miss_reasons": miss_reasons,
		"cycle_duration": (Time.get_ticks_msec() / 1000.0) - cycle_start_time,
		"torpedo_outcomes": torpedo_outcomes,
		"avg_smoothness": avg_smoothness,
		"avg_alignment_error": avg_alignment_error,
		"avg_compute_time_ms": avg_compute_time * 1000.0,
		"type_specific_metrics": type_metrics
	}
	
	return results

func _angle_difference(from: float, to: float) -> float:
	var diff = to - from
	while diff > PI:
		diff -= TAU
	while diff < -PI:
		diff += TAU
	return diff

func _calculate_average_angle(angles: Array) -> float:
	"""Calculate average of angles (circular mean)"""
	var sum_sin = 0.0
	var sum_cos = 0.0
	
	for angle in angles:
		sum_sin += sin(angle)
		sum_cos += cos(angle)
	
	return atan2(sum_sin / angles.size(), sum_cos / angles.size())

func _calculate_angle_spread(angles: Array) -> float:
	"""Calculate the spread of angles"""
	if angles.size() < 2:
		return 0.0
	
	var min_angle = angles[0]
	var max_angle = angles[0]
	
	# Find the arc that contains all angles
	for i in range(angles.size()):
		for j in range(i + 1, angles.size()):
			var diff = abs(_angle_difference(angles[i], angles[j]))
			if diff > abs(_angle_difference(min_angle, max_angle)):
				min_angle = angles[i]
				max_angle = angles[j]
	
	return abs(_angle_difference(min_angle, max_angle))

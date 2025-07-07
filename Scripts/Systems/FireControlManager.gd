# Scripts/Systems/FireControlManager.gd - FIXED TARGET ASSIGNMENT
extends Node2D
class_name FireControlManager

@export var debug_enabled: bool = false
@export var engagement_range_meters: float = 15000.0
@export var min_intercept_distance_meters: float = 5.0
@export var max_simultaneous_engagements: int = 10

# Target assessment thresholds - MADE MORE AGGRESSIVE
@export var critical_time_threshold: float = 3.0  # Increased from 2.0
@export var short_time_threshold: float = 8.0     # Increased from 5.0
@export var medium_time_threshold: float = 20.0   # Increased from 15.0

# Multi-PDC coordination - MADE MORE GENEROUS
@export var difficult_intercept_threshold: float = 0.2  # Reduced from 0.3
@export var multi_pdc_assignment_bonus: float = 1.5

# PDC Registry
var registered_pdcs: Dictionary = {}
var pdc_assignments: Dictionary = {}
var target_assignments: Dictionary = {}

# Target tracking
var tracked_targets: Dictionary = {}
var target_priorities: Array = []

# System state
var parent_ship: Node2D
var sensor_system: SensorSystem
var ship_faction: String = "friendly"
var ship_forward_direction: Vector2 = Vector2.UP

# Performance optimization
var update_interval: float = 0.05
var update_timer: float = 0.0

# Enhanced target data structure
class TargetData:
	var target_id: String
	var node_ref: Node2D
	var last_position: Vector2
	var last_velocity: Vector2
	var time_to_impact: float
	var intercept_point: Vector2
	var feasibility_score: float
	var priority_score: float
	var assigned_pdcs: Array = []
	var engagement_start_time: float
	var is_critical: bool = false
	var distance_meters: float = 0.0
	var first_detected_time: float = 0.0
	var initial_distance: float = 0.0
	var closest_approach_distance: float = INF

# Battle statistics
var battle_stats: Dictionary = {
	"battle_start_time": 0.0,
	"total_torpedoes_detected": 0,
	"total_torpedoes_intercepted": 0,
	"total_torpedoes_missed": 0,
	"total_rounds_fired": 0,
	"battle_active": false,
	"intercept_rate": 0.0,
	"closest_miss_distance": INF
}

var torpedo_tracking: Dictionary = {}
var intercept_log: Array = []
var battle_summary_printed: bool = false
var successful_intercepts: int = 0

func _ready():
	parent_ship = get_parent()
	
	if parent_ship:
		sensor_system = parent_ship.get_node_or_null("SensorSystem")
		if "faction" in parent_ship:
			ship_faction = parent_ship.faction
		discover_pdcs()
	
	start_battle_session()
	print("FireControlManager initialized with %d PDCs" % registered_pdcs.size())

func start_battle_session():
	battle_stats.battle_start_time = Time.get_ticks_msec() / 1000.0
	battle_stats.battle_active = true
	battle_stats.total_torpedoes_detected = 0
	battle_stats.total_torpedoes_intercepted = 0
	battle_stats.total_torpedoes_missed = 0
	battle_stats.total_rounds_fired = 0
	battle_stats.closest_miss_distance = INF
	battle_summary_printed = false
	
	torpedo_tracking.clear()
	intercept_log.clear()
	
	for pdc in registered_pdcs.values():
		if pdc.has_method("reset_battle_stats"):
			pdc.reset_battle_stats()

func discover_pdcs():
	for child in parent_ship.get_children():
		if child.has_method("get_capabilities"):
			register_pdc(child)

func register_pdc(pdc_node: Node2D):
	var pdc_id = pdc_node.pdc_id
	registered_pdcs[pdc_id] = pdc_node
	pdc_assignments[pdc_id] = ""
	pdc_node.set_fire_control_manager(self)

func _physics_process(delta):
	if not sensor_system:
		return
	
	ship_forward_direction = Vector2.UP.rotated(parent_ship.rotation)
	
	update_timer += delta
	if update_timer < update_interval:
		return
	update_timer = 0.0
	
	# Main fire control loop
	update_target_tracking()
	assess_all_threats()
	optimize_pdc_assignments()
	execute_fire_missions()
	update_battle_stats()
	check_battle_end()

func update_target_tracking():
	var current_torpedoes = sensor_system.get_all_enemy_torpedoes()
	
	# Remove torpedoes that EntityManager says no longer exist
	var targets_to_remove = []
	for target_id in tracked_targets:
		var target_data = tracked_targets[target_id]
		
		if not is_instance_valid(target_data.node_ref) or not target_data.node_ref in current_torpedoes:
			targets_to_remove.append(target_id)
			continue
		
		update_target_data(target_data)
	
	# Process destroyed torpedoes
	for target_id in targets_to_remove:
		remove_target(target_id)
	
	# Add new targets
	for torpedo in current_torpedoes:
		var torpedo_id = get_torpedo_id(torpedo)
		if not tracked_targets.has(torpedo_id):
			add_new_target(torpedo)

func add_new_target(torpedo: Node2D):
	var target_data = TargetData.new()
	target_data.target_id = get_torpedo_id(torpedo)
	target_data.node_ref = torpedo
	target_data.engagement_start_time = Time.get_ticks_msec() / 1000.0
	target_data.first_detected_time = target_data.engagement_start_time
	
	var initial_distance_pixels = torpedo.global_position.distance_to(parent_ship.global_position)
	target_data.initial_distance = initial_distance_pixels * WorldSettings.meters_per_pixel
	target_data.closest_approach_distance = target_data.initial_distance
	
	update_target_data(target_data)
	tracked_targets[target_data.target_id] = target_data
	
	battle_stats.total_torpedoes_detected += 1
	torpedo_tracking[target_data.target_id] = {
		"detected_time": target_data.first_detected_time,
		"initial_distance_km": target_data.initial_distance / 1000.0,
		"status": "tracking",
		"assigned_pdcs": [],
		"outcome": "unknown",
		"closest_approach_km": target_data.initial_distance / 1000.0
	}

func update_target_data(target_data: TargetData):
	var torpedo = target_data.node_ref
	target_data.last_position = torpedo.global_position
	target_data.last_velocity = get_torpedo_velocity(torpedo)
	
	var ship_pos = parent_ship.global_position
	var relative_pos = target_data.last_position - ship_pos
	var relative_vel = target_data.last_velocity - get_ship_velocity()
	target_data.distance_meters = relative_pos.length() * WorldSettings.meters_per_pixel
	
	# Track closest approach
	if target_data.distance_meters < target_data.closest_approach_distance:
		target_data.closest_approach_distance = target_data.distance_meters
		
		if torpedo_tracking.has(target_data.target_id):
			torpedo_tracking[target_data.target_id].closest_approach_km = target_data.distance_meters / 1000.0
	
	var closing_speed = -relative_vel.dot(relative_pos.normalized())
	if closing_speed > 0:
		target_data.time_to_impact = target_data.distance_meters / closing_speed
	else:
		target_data.time_to_impact = 999.0
	
	target_data.intercept_point = calculate_intercept_point(torpedo)
	
	if target_data.distance_meters <= engagement_range_meters:
		target_data.feasibility_score = calculate_intercept_feasibility(target_data)
	else:
		target_data.feasibility_score = 0.0
	
	target_data.is_critical = target_data.time_to_impact < critical_time_threshold and target_data.distance_meters <= engagement_range_meters

func calculate_intercept_point(torpedo: Node2D) -> Vector2:
	var torpedo_pos = torpedo.global_position
	var torpedo_vel = get_torpedo_velocity(torpedo) / WorldSettings.meters_per_pixel
	
	var avg_pdc_pos = get_average_pdc_position()
	var distance = avg_pdc_pos.distance_to(torpedo_pos)
	var bullet_time = distance * WorldSettings.meters_per_pixel / 800.0
	
	return torpedo_pos + torpedo_vel * bullet_time

func calculate_intercept_feasibility(target_data: TargetData) -> float:
	# FIXED: More aggressive feasibility scoring
	if target_data.distance_meters > engagement_range_meters:
		return 0.0
	
	var ship_to_target = target_data.last_position - parent_ship.global_position
	var closing_velocity = -target_data.last_velocity.dot(ship_to_target.normalized())
	
	if closing_velocity <= 0:
		return 0.0
	
	if target_data.distance_meters < min_intercept_distance_meters:
		return 0.0
	
	# IMPROVED: More optimistic PDC feasibility calculation
	var best_feasibility = 0.0
	var feasible_pdc_count = 0
	
	for pdc_id in registered_pdcs:
		var pdc = registered_pdcs[pdc_id]
		var pdc_feasibility = calculate_pdc_target_feasibility_improved(pdc, target_data)
		best_feasibility = max(best_feasibility, pdc_feasibility)
		if pdc_feasibility > 0.1:
			feasible_pdc_count += 1
	
	# BONUS: If multiple PDCs can engage, increase feasibility
	if feasible_pdc_count > 1:
		best_feasibility *= 1.3
	
	return best_feasibility

func calculate_pdc_target_feasibility_improved(pdc: Node2D, target_data: TargetData) -> float:
	var pdc_pos = pdc.get_muzzle_world_position()
	var to_intercept = target_data.intercept_point - pdc_pos
	var world_angle = to_intercept.angle()
	var required_angle = world_angle - parent_ship.rotation
	
	# Normalize the required angle to [-PI, PI]
	while required_angle > PI:
		required_angle -= TAU
	while required_angle < -PI:
		required_angle += TAU
	
	var current_angle = pdc.current_rotation
	var rotation_needed = abs(angle_difference(current_angle, required_angle))
	var rotation_time = rotation_needed / deg_to_rad(pdc.turret_rotation_speed)
	
	# IMPROVED: More generous time margin (was 0.7, now 0.85)
	if rotation_time > target_data.time_to_impact * 0.85:
		return 0.0
	
	# IMPROVED: Better scoring curve
	var time_margin = target_data.time_to_impact - rotation_time
	var feasibility = clamp(time_margin / 2.0, 0.1, 1.0)  # Changed from 3.0 to 2.0
	
	# BONUS: Small angles get preference
	if rotation_needed < deg_to_rad(45):
		feasibility *= 1.2
	
	return feasibility

func assess_all_threats():
	target_priorities.clear()
	
	for target_id in tracked_targets:
		var target_data = tracked_targets[target_id]
		
		# IMPROVED: Lower threshold for engagement (was 0.0, now allows very low scores)
		if target_data.feasibility_score <= 0.05:
			continue
		
		calculate_target_priority_improved(target_data)
		
		var inserted = false
		for i in range(target_priorities.size()):
			var other_data = tracked_targets[target_priorities[i]]
			if target_data.priority_score > other_data.priority_score:
				target_priorities.insert(i, target_id)
				inserted = true
				break
		
		if not inserted:
			target_priorities.append(target_id)

func calculate_target_priority_improved(target_data: TargetData):
	var base_priority = 0.0
	
	# IMPROVED: More aggressive priority scaling
	if target_data.time_to_impact < critical_time_threshold:
		base_priority = 200.0  # Increased from 100.0
	elif target_data.time_to_impact < short_time_threshold:
		base_priority = 80.0   # Increased from 50.0
	elif target_data.time_to_impact < medium_time_threshold:
		base_priority = 40.0   # Increased from 25.0
	else:
		base_priority = 15.0   # Increased from 10.0
	
	var time_factor = 1.0 / max(target_data.time_to_impact, 0.1)
	base_priority *= time_factor
	base_priority *= target_data.feasibility_score
	
	# IMPROVED: Less aggressive PDC availability penalty
	var available_pdcs = get_available_pdc_count()
	var total_pdcs = registered_pdcs.size()
	if available_pdcs < total_pdcs * 0.5:  # Changed from 0.3 to 0.5
		base_priority *= 1.3  # Reduced from 1.5
	
	target_data.priority_score = base_priority

func optimize_pdc_assignments():
	# Clear all assignments first
	for pdc_id in pdc_assignments:
		pdc_assignments[pdc_id] = ""
	target_assignments.clear()
	
	for target_id in target_priorities:
		var target_data = tracked_targets[target_id]
		
		if target_data.feasibility_score <= 0.05:
			continue
		
		# IMPROVED: More aggressive PDC assignment
		var pdcs_needed = 1
		if target_data.is_critical:
			pdcs_needed = 2
		elif target_data.feasibility_score < difficult_intercept_threshold:
			pdcs_needed = 2
		elif target_data.time_to_impact < short_time_threshold:
			pdcs_needed = 2  # NEW: Assign 2 PDCs to all short-time targets
		
		var assigned_pdcs = assign_pdcs_to_target_improved(target_data, pdcs_needed)
		
		if assigned_pdcs.size() > 0:
			target_assignments[target_id] = assigned_pdcs
			target_data.assigned_pdcs = assigned_pdcs
			
			if torpedo_tracking.has(target_id):
				torpedo_tracking[target_id].assigned_pdcs = assigned_pdcs
				torpedo_tracking[target_id].status = "engaged"

func assign_pdcs_to_target_improved(target_data: TargetData, pdcs_needed: int) -> Array:
	var available_pdcs = []
	var assigned = []
	
	# Find all available PDCs and score them for this target
	for pdc_id in registered_pdcs:
		if pdc_assignments[pdc_id] == "":
			var pdc = registered_pdcs[pdc_id]
			var score = score_pdc_for_target_improved(pdc, target_data)
			
			if score > 0.0:
				available_pdcs.append({
					"pdc_id": pdc_id,
					"score": score
				})
	
	# Sort by best score first
	available_pdcs.sort_custom(func(a, b): return a.score > b.score)
	
	# Assign the best PDCs up to the needed count
	for i in range(min(pdcs_needed, available_pdcs.size())):
		var pdc_id = available_pdcs[i].pdc_id
		pdc_assignments[pdc_id] = target_data.target_id
		assigned.append(pdc_id)
	
	return assigned

func score_pdc_for_target_improved(pdc: Node2D, target_data: TargetData) -> float:
	var pdc_pos = pdc.get_muzzle_world_position()
	var to_intercept = target_data.intercept_point - pdc_pos
	var required_angle = to_intercept.angle()
	
	var current_angle = pdc.current_rotation
	var rotation_needed = abs(angle_difference(current_angle, required_angle))
	var rotation_time = rotation_needed / deg_to_rad(pdc.turret_rotation_speed)
	
	# IMPROVED: More lenient time requirement (was 0.7, now 0.9)
	if rotation_time > target_data.time_to_impact * 0.9:
		return 0.0
	
	var rotation_score = 1.0 - (rotation_time / target_data.time_to_impact)
	
	# IMPROVED: Bonus for already-aimed PDCs
	if rotation_needed < deg_to_rad(30):
		rotation_score *= 1.5
	
	return rotation_score * target_data.feasibility_score

func execute_fire_missions():
	for target_id in target_assignments:
		if not tracked_targets.has(target_id):
			continue
			
		var target_data = tracked_targets[target_id]
		var assigned_pdcs = target_assignments[target_id]
		
		if target_data.distance_meters > engagement_range_meters:
			continue
		
		for pdc_id in assigned_pdcs:
			var pdc = registered_pdcs[pdc_id]
			
			var firing_angle = calculate_firing_solution_fixed(pdc, target_data)
			
			var is_emergency = target_data.is_critical
			pdc.set_target(target_id, firing_angle, is_emergency)
			
			if pdc.is_aimed():
				pdc.authorize_firing()

func calculate_firing_solution_fixed(pdc: Node2D, target_data: TargetData) -> float:
	var pdc_pos = pdc.get_muzzle_world_position()
	var target_pos = target_data.last_position
	var target_vel = target_data.last_velocity
	
	var to_target = target_pos - pdc_pos
	var distance = to_target.length()
	var distance_meters = distance * WorldSettings.meters_per_pixel
	
	# IMPROVED: More accurate bullet time calculation
	var bullet_time = distance_meters / pdc.bullet_velocity_mps
	
	var target_vel_pixels = target_vel / WorldSettings.meters_per_pixel
	var predicted_pos = target_pos + target_vel_pixels * bullet_time
	
	var to_intercept = predicted_pos - pdc_pos
	var world_angle = to_intercept.angle()
	
	# FIXED: Return ship-relative angle directly
	var ship_angle = parent_ship.rotation
	var relative_angle = world_angle - ship_angle
	
	# Normalize angle
	while relative_angle > PI:
		relative_angle -= TAU
	while relative_angle < -PI:
		relative_angle += TAU
	
	return relative_angle

func remove_target(target_id: String):
	if not tracked_targets.has(target_id):
		return
	
	var target_data = tracked_targets[target_id]
	var distance_to_ship = target_data.last_position.distance_to(parent_ship.global_position)
	var distance_meters = distance_to_ship * WorldSettings.meters_per_pixel
	var engagement_duration = (Time.get_ticks_msec() / 1000.0) - target_data.engagement_start_time
	
	var was_successful_intercept = (target_data.assigned_pdcs.size() > 0)
	var outcome_reason = ""
	
	if was_successful_intercept:
		outcome_reason = "PDC_INTERCEPT"
		successful_intercepts += 1
		battle_stats.total_torpedoes_intercepted += 1
	else:
		outcome_reason = "TORPEDO_HIT"
		battle_stats.total_torpedoes_missed += 1
		
		if target_data.closest_approach_distance < battle_stats.closest_miss_distance:
			battle_stats.closest_miss_distance = target_data.closest_approach_distance
		
		print("🚨 Torpedo %s: HIT SHIP at %.2f km" % [
			target_id.substr(8, 7), distance_meters / 1000.0
		])
	
	var log_entry = {
		"target_id": target_id,
		"outcome": "intercepted" if was_successful_intercept else "hit_ship",
		"intercept_distance_km": distance_meters / 1000.0,
		"closest_approach_km": target_data.closest_approach_distance / 1000.0,
		"initial_distance_km": target_data.initial_distance / 1000.0,
		"assigned_pdcs": target_data.assigned_pdcs.duplicate(),
		"engagement_duration": engagement_duration,
		"removal_reason": outcome_reason,
		"entity_manager_confirmed": true
	}
	intercept_log.append(log_entry)
	
	if torpedo_tracking.has(target_id):
		torpedo_tracking[target_id].outcome = "intercepted" if was_successful_intercept else "hit_ship"
		torpedo_tracking[target_id].intercept_distance_km = distance_meters / 1000.0
		torpedo_tracking[target_id].engagement_duration = engagement_duration
	
	# Stop all PDCs assigned to this target
	for pdc_id in target_data.assigned_pdcs:
		if registered_pdcs.has(pdc_id):
			var pdc = registered_pdcs[pdc_id]
			pdc.stop_firing()
			pdc_assignments[pdc_id] = ""
	
	# Clean up tracking
	tracked_targets.erase(target_id)
	if target_assignments.has(target_id):
		target_assignments.erase(target_id)
	
	var index = target_priorities.find(target_id)
	if index >= 0:
		target_priorities.remove_at(index)

func update_battle_stats():
	var total_rounds = 0
	for pdc in registered_pdcs.values():
		if pdc.has_method("get_battle_stats"):
			var pdc_stats = pdc.get_battle_stats()
			total_rounds += pdc_stats.rounds_fired
	
	battle_stats.total_rounds_fired = total_rounds
	
	var total_resolved = battle_stats.total_torpedoes_intercepted + battle_stats.total_torpedoes_missed
	if total_resolved > 0:
		battle_stats.intercept_rate = (float(battle_stats.total_torpedoes_intercepted) / float(total_resolved)) * 100.0

func report_successful_intercept(pdc_id: String, target_id: String):
	battle_stats.successful_intercepts += 1
	
	# Track PDC-specific performance for detailed analysis
	if registered_pdcs.has(pdc_id):
		var pdc = registered_pdcs[pdc_id]
		if pdc.has_method("get_battle_stats"):
			# The PDC already tracks its own hits, but we can use this for 
			# cross-referencing or additional logging if needed
			if debug_enabled:
				print("PDC %s confirmed hit on target %s" % [
					pdc_id.substr(4, 8), target_id.substr(8, 7)
				])

func check_battle_end():
	var current_torpedoes = sensor_system.get_all_enemy_torpedoes()
	
	if current_torpedoes.size() == 0 and tracked_targets.size() == 0:
		if battle_stats.battle_active and battle_stats.total_torpedoes_detected > 0 and not battle_summary_printed:
			end_battle_session()

func end_battle_session():
	if battle_summary_printed:
		return
	
	battle_stats.battle_active = false
	battle_summary_printed = true
	
	# Emergency stop all PDCs
	for pdc_id in registered_pdcs:
		var pdc = registered_pdcs[pdc_id]
		if pdc.has_method("emergency_stop"):
			pdc.emergency_stop()
		pdc_assignments[pdc_id] = ""
	
	target_assignments.clear()
	print_comprehensive_battle_summary()

func print_comprehensive_battle_summary():
	print("\n" + "=".repeat(60))
	print("                 BATTLE REPORT")
	print("=".repeat(60))
	
	var battle_duration = (Time.get_ticks_msec() / 1000.0) - battle_stats.battle_start_time
	print("Battle Duration: %.1f seconds" % battle_duration)
	print("Ship: %s (%s faction)" % [parent_ship.name, ship_faction])
	print("")
	
	print("ENGAGEMENT SUMMARY:")
	print("  Torpedoes Detected: %d" % battle_stats.total_torpedoes_detected)
	print("  Torpedoes Intercepted: %d" % battle_stats.total_torpedoes_intercepted)
	print("  Torpedoes Hit Ship: %d" % battle_stats.total_torpedoes_missed)
	print("  Intercept Success Rate: %.1f%%" % battle_stats.intercept_rate)
	print("  Total Rounds Fired: %d" % battle_stats.total_rounds_fired)
	
	if battle_stats.total_rounds_fired > 0 and battle_stats.total_torpedoes_intercepted > 0:
		var rounds_per_kill = float(battle_stats.total_rounds_fired) / float(battle_stats.total_torpedoes_intercepted)
		print("  Rounds per Intercept: %.1f" % rounds_per_kill)
	
	if battle_stats.closest_miss_distance < INF:
		print("  Closest Ship Hit Distance: %.2f km" % (battle_stats.closest_miss_distance / 1000.0))
	
	print("")
	
	print("PDC PERFORMANCE:")
	for pdc_id in registered_pdcs:
		var pdc = registered_pdcs[pdc_id]
		if pdc.has_method("get_battle_stats"):
			var stats = pdc.get_battle_stats()
			var hit_rate = 0.0
			if stats.rounds_fired > 0:
				hit_rate = stats.hit_rate
			
			print("  %s: %d rounds, %d hits (%.1f%% accuracy)" % [
				pdc_id.substr(4, 8), stats.rounds_fired, stats.targets_hit, hit_rate
			])
	
	print("")
	
	if intercept_log.size() > 0:
		print("INDIVIDUAL TORPEDO RESULTS:")
		var display_count = min(5, intercept_log.size())
		
		for i in range(display_count):
			var log_entry = intercept_log[i]
			var torpedo_num = i + 1
			var status_icon = "✓" if log_entry.outcome == "intercepted" else "✗"
			
			print("  %s Torpedo %d: %s at %.2f km (approached to %.2f km)" % [
				status_icon, torpedo_num, log_entry.outcome.to_upper(), 
				log_entry.intercept_distance_km, log_entry.closest_approach_km
			])
			
			if log_entry.assigned_pdcs.size() > 0:
				var pdc_names = []
				for pdc_id in log_entry.assigned_pdcs:
					pdc_names.append(pdc_id.substr(4, 8))
				print("    - Engaged by %d PDCs (%s) for %.1f seconds" % [
					log_entry.assigned_pdcs.size(), ", ".join(pdc_names), log_entry.engagement_duration
				])
		
		var hit_count = 0
		for log_entry in intercept_log:
			if log_entry.outcome == "hit_ship":
				hit_count += 1
		
		if hit_count > 0:
			print("  SHIP HIT DETAILS:")
			var hit_num = 0
			for log_entry in intercept_log:
				if log_entry.outcome == "hit_ship":
					hit_num += 1
					var reason = log_entry.get("removal_reason", "UNKNOWN")
					var confirmed = log_entry.get("entity_manager_confirmed", false)
					var confirmation_text = " (EntityManager confirmed)" if confirmed else ""
					print("    Hit %d: %s at %.2f km (closest: %.2f km)%s" % [
						hit_num, reason, 
						log_entry.intercept_distance_km, log_entry.closest_approach_km,
						confirmation_text
					])
		
		if intercept_log.size() > 5:
			print("  ... and %d more torpedoes (with mixed results)" % [intercept_log.size() - 5])
	
	print("")
	
	print("THREAT ASSESSMENT:")
	if battle_stats.intercept_rate >= 94.0:
		print("  EXCELLENT DEFENSE - %.1f%% intercept rate" % battle_stats.intercept_rate)
	elif battle_stats.intercept_rate >= 80.0:
		print("  GOOD DEFENSE - %.1f%% intercept rate" % battle_stats.intercept_rate)
	else:
		print("  NEEDS IMPROVEMENT - %.1f%% intercept rate" % battle_stats.intercept_rate)
	
	print("")
	print("TACTICAL ANALYSIS:")
	
	var working_pdcs = 0
	var non_contributing_pdcs = 0
	for pdc_id in registered_pdcs:
		var pdc = registered_pdcs[pdc_id]
		if pdc.has_method("get_battle_stats"):
			var stats = pdc.get_battle_stats()
			if stats.targets_hit > 0:
				working_pdcs += 1
			elif stats.rounds_fired > 50:
				non_contributing_pdcs += 1
	
	# Report PDC utilization - this was the intended purpose
	print("  - %d of %d PDCs contributed to intercepts (%.1f%% utilization)" % [
		working_pdcs, registered_pdcs.size(), 
		(float(working_pdcs) / float(registered_pdcs.size())) * 100.0
	])
	
	if working_pdcs < registered_pdcs.size() / 2.0:
		print("  - Low PDC utilization detected - review target allocation algorithm")
	
	if non_contributing_pdcs > 0:
		print("  - %d PDCs fired rounds but scored no hits - check firing solutions" % non_contributing_pdcs)
	
	if battle_stats.total_rounds_fired > 0 and battle_stats.total_torpedoes_intercepted > 0:
		var rounds_per_kill = float(battle_stats.total_rounds_fired) / float(battle_stats.total_torpedoes_intercepted)
		if rounds_per_kill < 10.0:
			print("  - Excellent ammunition efficiency (%.1f rounds/kill)" % rounds_per_kill)
		else:
			print("  - Moderate ammunition efficiency (%.1f rounds/kill)" % rounds_per_kill)
	
	if battle_stats.intercept_rate > 90.0:
		print("  - Excellent defensive performance with minor room for improvement")
	else:
		print("  - Defensive system requires optimization for improved performance")
	
	print("=".repeat(60))

# Utility functions
func get_available_pdc_count() -> int:
	var count = 0
	for pdc_id in pdc_assignments:
		if pdc_assignments[pdc_id] == "":
			count += 1
	return count

func get_average_pdc_position() -> Vector2:
	var sum = Vector2.ZERO
	var count = 0
	
	for pdc_id in registered_pdcs:
		var pdc = registered_pdcs[pdc_id]
		sum += pdc.global_position
		count += 1
	
	return sum / count if count > 0 else parent_ship.global_position

func get_torpedo_id(torpedo: Node2D) -> String:
	return "torpedo_" + str(torpedo.get_instance_id())

func get_torpedo_velocity(torpedo: Node2D) -> Vector2:
	if torpedo.has_method("get_velocity_mps"):
		return torpedo.get_velocity_mps()
	elif "velocity_mps" in torpedo:
		return torpedo.velocity_mps
	return Vector2.ZERO

func get_ship_velocity() -> Vector2:
	if parent_ship and parent_ship.has_method("get_velocity_mps"):
		return parent_ship.get_velocity_mps()
	return Vector2.ZERO

func angle_difference(from: float, to: float) -> float:
	var diff = fmod(to - from, TAU)
	if diff > PI:
		diff -= TAU
	elif diff < -PI:
		diff += TAU
	return diff

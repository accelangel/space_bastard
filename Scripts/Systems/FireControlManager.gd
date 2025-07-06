# Scripts/Systems/FireControlManager.gd - FIXED VERSION
extends Node2D
class_name FireControlManager

# DEBUG CONTROL
@export var debug_enabled: bool = true
@export var debug_verbose: bool = false
@export var debug_interval: float = 3.0  # Less frequent debug output
var debug_timer: float = 0.0
var last_target_count: int = 0

# System configuration
@export var engagement_range_meters: float = 2500.0  # Reduced from 8000
@export var min_intercept_distance_meters: float = 50.0  # Increased minimum
@export var max_simultaneous_engagements: int = 6  # Match PDC count

# Target assessment thresholds
@export var critical_time_threshold: float = 8.0     # Increased from 2.0
@export var short_time_threshold: float = 15.0      # Increased from 5.0
@export var medium_time_threshold: float = 30.0     # Increased from 15.0

# Multi-PDC coordination
@export var difficult_intercept_threshold: float = 0.3
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
var update_interval: float = 0.1  # 10Hz update rate (slower)
var update_timer: float = 0.0

# Statistics
var total_engagements: int = 0
var successful_intercepts: int = 0

# Target data structure
class TargetData:
	var target_id: String
	var node_ref: Node2D
	var last_position: Vector2
	var last_velocity: Vector2
	var time_to_impact: float
	var distance_to_ship: float
	var intercept_point: Vector2
	var feasibility_score: float
	var priority_score: float
	var assigned_pdcs: Array = []
	var engagement_start_time: float
	var is_critical: bool = false
	var is_in_range: bool = false

func _ready():
	parent_ship = get_parent()
	
	if parent_ship:
		sensor_system = parent_ship.get_node_or_null("SensorSystem")
		if "faction" in parent_ship:
			ship_faction = parent_ship.faction
		
		discover_pdcs()
	
	print("FireControlManager initialized with ", registered_pdcs.size(), " PDCs")

func discover_pdcs():
	print("FCM: Discovering PDCs on ship...")
	for child in parent_ship.get_children():
		if child.has_method("get_capabilities"):
			register_pdc(child)
			print("FCM: Found PDC: ", child.name)
	
	if registered_pdcs.size() == 0:
		print("FCM WARNING: No PDCs found!")

func register_pdc(pdc_node: Node2D):
	var pdc_id = pdc_node.pdc_id
	registered_pdcs[pdc_id] = pdc_node
	pdc_assignments[pdc_id] = ""
	
	pdc_node.set_fire_control_manager(self)
	print("Registered PDC: ", pdc_id)

func _physics_process(delta):
	if not sensor_system:
		return
	
	ship_forward_direction = Vector2.UP.rotated(parent_ship.rotation)
	
	# Debug timer
	if debug_enabled:
		debug_timer += delta
		if debug_timer >= debug_interval:
			debug_timer = 0.0
			print_debug_summary()
	
	# Throttle updates
	update_timer += delta
	if update_timer < update_interval:
		return
	update_timer = 0.0
	
	# Main fire control loop
	update_target_tracking()
	assess_all_threats()
	optimize_pdc_assignments()
	execute_fire_missions()

func print_debug_summary():
	var active_targets = tracked_targets.size()
	var engaged_pdcs = get_busy_pdc_count()
	var critical_count = 0
	var in_range_count = 0
	
	for target_data in tracked_targets.values():
		if target_data.is_critical:
			critical_count += 1
		if target_data.is_in_range:
			in_range_count += 1
	
	print("\n=== FCM STATUS ===")
	print("Targets: %d tracked (%d critical, %d in range)" % [active_targets, critical_count, in_range_count])
	print("PDCs: %d/%d engaged" % [engaged_pdcs, registered_pdcs.size()])
	
	# Show only engaged PDCs
	for pdc_id in registered_pdcs:
		var target_id = pdc_assignments[pdc_id]
		if target_id != "":
			var pdc = registered_pdcs[pdc_id]
			var status = pdc.get_status()
			print("  %s -> %s (rot: %.1f°, error: %.1f°, range: %.0fm)" % [
				pdc_id, 
				target_id.substr(0, 15),
				rad_to_deg(status.current_rotation),
				rad_to_deg(status.tracking_error),
				status.target_range
			])
	
	# Show top threats that are in range
	if target_priorities.size() > 0:
		print("Top threats:")
		var shown = 0
		for target_id in target_priorities:
			if shown >= 3:
				break
			var data = tracked_targets[target_id]
			if data.is_in_range:
				print("  %s: %.1fs TTI, %.0fm, score: %.2f" % [
					target_id.substr(0, 15),
					data.time_to_impact,
					data.distance_to_ship,
					data.priority_score
				])
				shown += 1
	print("==================\n")

func update_target_tracking():
	var current_torpedoes = sensor_system.get_all_enemy_torpedoes()
	
	# Log significant changes
	if debug_enabled and current_torpedoes.size() != last_target_count:
		if current_torpedoes.size() > last_target_count:
			print("FCM: Detected %d enemy torpedoes!" % current_torpedoes.size())
		last_target_count = current_torpedoes.size()
	
	# Update existing targets
	var targets_to_remove = []
	for target_id in tracked_targets:
		var target_data = tracked_targets[target_id]
		
		if not is_instance_valid(target_data.node_ref) or not target_data.node_ref in current_torpedoes:
			targets_to_remove.append(target_id)
			continue
		
		update_target_data(target_data)
	
	# Remove dead targets
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
	
	update_target_data(target_data)
	tracked_targets[target_data.target_id] = target_data
	
	total_engagements += 1
	
	if debug_verbose:
		print("FCM: Added new target: %s at %.0fm" % [
			target_data.target_id.substr(0, 15),
			target_data.distance_to_ship
		])

func update_target_data(target_data: TargetData):
	var torpedo = target_data.node_ref
	target_data.last_position = torpedo.global_position
	target_data.last_velocity = get_torpedo_velocity(torpedo)
	
	# Calculate distance to ship
	var ship_pos = parent_ship.global_position
	var relative_pos = target_data.last_position - ship_pos
	target_data.distance_to_ship = relative_pos.length() * WorldSettings.meters_per_pixel
	
	# Check if target is in engagement range
	target_data.is_in_range = target_data.distance_to_ship <= engagement_range_meters and target_data.distance_to_ship >= min_intercept_distance_meters
	
	# Calculate time to impact
	var relative_vel = target_data.last_velocity - get_ship_velocity()
	var closing_speed = -relative_vel.dot(relative_pos.normalized())
	
	if closing_speed > 0:
		target_data.time_to_impact = target_data.distance_to_ship / closing_speed
	else:
		target_data.time_to_impact = 999.0
	
	# Calculate intercept point
	target_data.intercept_point = calculate_intercept_point(torpedo)
	
	# Calculate feasibility
	target_data.feasibility_score = calculate_intercept_feasibility(target_data)
	
	# Determine if critical
	target_data.is_critical = target_data.time_to_impact < critical_time_threshold and target_data.is_in_range

func calculate_intercept_point(torpedo: Node2D) -> Vector2:
	var torpedo_pos = torpedo.global_position
	var torpedo_vel = get_torpedo_velocity(torpedo) / WorldSettings.meters_per_pixel
	
	# Find the closest PDC to estimate intercept time
	var closest_pdc_distance = 999999.0
	for pdc_id in registered_pdcs:
		var pdc = registered_pdcs[pdc_id]
		var distance = pdc.global_position.distance_to(torpedo_pos)
		closest_pdc_distance = min(closest_pdc_distance, distance)
	
	# Estimate bullet travel time
	var bullet_time = (closest_pdc_distance * WorldSettings.meters_per_pixel) / 800.0
	
	# Predict where torpedo will be
	return torpedo_pos + torpedo_vel * bullet_time

func calculate_intercept_feasibility(target_data: TargetData) -> float:
	# Only engage targets that are:
	# 1. In range
	# 2. Moving toward the ship
	# 3. Can be reached by at least one PDC
	
	if not target_data.is_in_range:
		return 0.0
	
	var ship_to_target = target_data.last_position - parent_ship.global_position
	var closing_velocity = -target_data.last_velocity.dot(ship_to_target.normalized())
	
	if closing_velocity <= 0:
		return 0.0  # Target moving away
	
	# Check if any PDC can engage
	var best_feasibility = 0.0
	for pdc_id in registered_pdcs:
		var pdc = registered_pdcs[pdc_id]
		var pdc_feasibility = calculate_pdc_target_feasibility(pdc, target_data)
		best_feasibility = max(best_feasibility, pdc_feasibility)
	
	return best_feasibility

func calculate_pdc_target_feasibility(pdc: Node2D, target_data: TargetData) -> float:
	# Calculate required angle
	var pdc_pos = pdc.get_muzzle_world_position()
	var to_intercept = target_data.intercept_point - pdc_pos
	var world_angle = to_intercept.angle()
	var required_angle = world_angle - parent_ship.rotation
	
	# Normalize angle
	while required_angle > PI:
		required_angle -= TAU
	while required_angle < -PI:
		required_angle += TAU
	
	# Calculate rotation time
	var current_angle = pdc.current_rotation
	var rotation_needed = abs(angle_difference(current_angle, required_angle))
	var rotation_time = rotation_needed / deg_to_rad(pdc.turret_rotation_speed)
	
	# Add aiming buffer
	rotation_time += 0.5
	
	# Can we rotate in time?
	if rotation_time > target_data.time_to_impact:
		return 0.1
	
	# Good feasibility based on time margin
	var time_margin = target_data.time_to_impact - rotation_time
	return clamp(time_margin / 5.0, 0.1, 1.0)

func assess_all_threats():
	target_priorities.clear()
	
	for target_id in tracked_targets:
		var target_data = tracked_targets[target_id]
		
		# Only consider targets that are in range and feasible
		if target_data.feasibility_score <= 0.0 or not target_data.is_in_range:
			continue
		
		calculate_target_priority(target_data)
		
		# Insert into sorted priority list
		var inserted = false
		for i in range(target_priorities.size()):
			var other_data = tracked_targets[target_priorities[i]]
			if target_data.priority_score > other_data.priority_score:
				target_priorities.insert(i, target_id)
				inserted = true
				break
		
		if not inserted:
			target_priorities.append(target_id)

func calculate_target_priority(target_data: TargetData):
	var base_priority = 0.0
	
	# Time-based priority
	if target_data.time_to_impact < critical_time_threshold:
		base_priority = 100.0
	elif target_data.time_to_impact < short_time_threshold:
		base_priority = 50.0
	elif target_data.time_to_impact < medium_time_threshold:
		base_priority = 25.0
	else:
		base_priority = 10.0
	
	# Distance factor (closer = higher priority)
	var distance_factor = 1.0 - (target_data.distance_to_ship / engagement_range_meters)
	base_priority *= (1.0 + distance_factor)
	
	# Scale by inverse time
	var time_factor = 1.0 / max(target_data.time_to_impact, 0.1)
	base_priority *= time_factor
	
	# Factor in feasibility
	base_priority *= target_data.feasibility_score
	
	target_data.priority_score = base_priority

func optimize_pdc_assignments():
	# Clear current assignments
	for pdc_id in pdc_assignments:
		pdc_assignments[pdc_id] = ""
	target_assignments.clear()
	
	# Assign PDCs to targets in priority order
	for target_id in target_priorities:
		var target_data = tracked_targets[target_id]
		
		if target_data.feasibility_score <= 0.0 or not target_data.is_in_range:
			continue
		
		# Determine PDCs needed
		var pdcs_needed = 1
		if target_data.is_critical:
			pdcs_needed = 2
		elif target_data.feasibility_score < difficult_intercept_threshold:
			pdcs_needed = 2
		
		# Assign PDCs
		var assigned_pdcs = assign_pdcs_to_target(target_data, pdcs_needed)
		
		if assigned_pdcs.size() > 0:
			target_assignments[target_id] = assigned_pdcs
			target_data.assigned_pdcs = assigned_pdcs
	
	# Stop unassigned PDCs
	for pdc_id in registered_pdcs:
		if pdc_assignments[pdc_id] == "":
			var pdc = registered_pdcs[pdc_id]
			if pdc.current_status != "IDLE":
				pdc.stop_firing()

func assign_pdcs_to_target(target_data: TargetData, pdcs_needed: int) -> Array:
	var available_pdcs = []
	var assigned = []
	
	# Score available PDCs
	for pdc_id in registered_pdcs:
		if pdc_assignments[pdc_id] == "":
			var pdc = registered_pdcs[pdc_id]
			var score = score_pdc_for_target(pdc, target_data)
			if score > 0.0:
				available_pdcs.append({"pdc_id": pdc_id, "score": score})
	
	# Sort by score
	available_pdcs.sort_custom(func(a, b): return a.score > b.score)
	
	# Assign best PDCs
	for i in range(min(pdcs_needed, available_pdcs.size())):
		var pdc_id = available_pdcs[i].pdc_id
		pdc_assignments[pdc_id] = target_data.target_id
		assigned.append(pdc_id)
	
	return assigned

func score_pdc_for_target(pdc: Node2D, target_data: TargetData) -> float:
	var pdc_pos = pdc.get_muzzle_world_position()
	var to_intercept = target_data.intercept_point - pdc_pos
	var required_angle = to_intercept.angle() - parent_ship.rotation
	
	# Normalize angle
	while required_angle > PI:
		required_angle -= TAU
	while required_angle < -PI:
		required_angle += TAU
	
	# Calculate rotation time
	var current_angle = pdc.current_rotation
	var rotation_needed = abs(angle_difference(current_angle, required_angle))
	var rotation_time = rotation_needed / deg_to_rad(pdc.turret_rotation_speed)
	
	# Can't engage if takes too long
	if rotation_time > target_data.time_to_impact * 0.7:
		return 0.0
	
	# Score based on engagement speed
	var rotation_score = 1.0 - (rotation_time / target_data.time_to_impact)
	
	# Bonus for already aimed PDCs
	if rotation_needed < deg_to_rad(30):
		rotation_score *= 1.5
	
	return rotation_score * target_data.feasibility_score

# FIXED: Continuous target tracking and firing solution updates
func execute_fire_missions():
	for target_id in target_assignments:
		if not tracked_targets.has(target_id):
			continue
			
		var target_data = tracked_targets[target_id]
		var assigned_pdcs = target_assignments[target_id]
		
		for pdc_id in assigned_pdcs:
			var pdc = registered_pdcs[pdc_id]
			
			# CRITICAL: Continuously update firing solution
			var firing_angle = calculate_firing_solution(pdc, target_data)
			
			# Command PDC with updated angle
			var is_emergency = target_data.is_critical
			pdc.set_target(target_id, firing_angle, is_emergency)
			
			# Start firing if PDC reports ready
			if pdc.is_aimed():
				if not pdc.is_firing:
					pdc.start_firing()

# FIXED: Proper angle calculation
func calculate_firing_solution(pdc: Node2D, target_data: TargetData) -> float:
	# Get positions
	var pdc_pos = pdc.get_muzzle_world_position()
	var target_pos = target_data.last_position
	var target_vel = target_data.last_velocity
	
	# Calculate intercept point with proper lead
	var to_target = target_pos - pdc_pos
	var distance = to_target.length()
	var distance_meters = distance * WorldSettings.meters_per_pixel
	
	# Time for bullet to reach target
	var bullet_time = distance_meters / 800.0  # bullet velocity
	
	# Predict where target will be
	var target_vel_pixels = target_vel / WorldSettings.meters_per_pixel
	var predicted_pos = target_pos + target_vel_pixels * bullet_time
	
	# Calculate angle to predicted position IN WORLD SPACE
	var to_intercept = predicted_pos - pdc_pos
	var world_angle = to_intercept.angle()
	
	# CRITICAL FIX: The ship's "up" in Godot is actually -Y (negative Y)
	# So we need to account for the fact that rotation 0 means pointing up (-Y)
	# The world angle is measured from +X axis, so we need to adjust
	var ship_angle = parent_ship.rotation
	var relative_angle = world_angle - ship_angle
	
	# Normalize to -PI to PI range
	while relative_angle > PI:
		relative_angle -= TAU
	while relative_angle < -PI:
		relative_angle += TAU
	
	# DEBUG: Only log for critical targets to reduce spam
	if debug_verbose and target_data.is_critical:
		print("FCM Firing Solution for %s:" % target_data.target_id.substr(0, 15))
		print("  Target at: %.1f°" % rad_to_deg(world_angle))
		print("  Ship facing: %.1f°" % rad_to_deg(ship_angle))
		print("  Relative angle: %.1f°" % rad_to_deg(relative_angle))
		print("  Lead time: %.2f s" % bullet_time)
	
	return relative_angle

func pdc_ready_to_fire(pdc_id: String):
	# Called by PDC when it's aimed and ready
	if pdc_assignments.has(pdc_id) and pdc_assignments[pdc_id] != "":
		var pdc = registered_pdcs[pdc_id]
		pdc.start_firing()

# IMPROVED: Better target removal with debug info
func remove_target(target_id: String):
	# Clean up target
	if tracked_targets.has(target_id):
		var target_data = tracked_targets[target_id]
		
		if debug_verbose:
			print("FCM: Removing target %s (TTI was %.1f)" % [
				target_id.substr(0, 15), 
				target_data.time_to_impact
			])
		
		# Stop all PDCs assigned to this target
		for pdc_id in target_data.assigned_pdcs:
			if registered_pdcs.has(pdc_id):
				registered_pdcs[pdc_id].stop_firing()
				pdc_assignments[pdc_id] = ""
		
		tracked_targets.erase(target_id)
		
		# Check if this was a successful intercept
		if target_data.time_to_impact > 0.5:  # Destroyed before getting too close
			successful_intercepts += 1

# Utility functions
func get_available_pdc_count() -> int:
	var count = 0
	for pdc_id in pdc_assignments:
		if pdc_assignments[pdc_id] == "":
			count += 1
	return count

func get_busy_pdc_count() -> int:
	var count = 0
	for pdc_id in pdc_assignments:
		if pdc_assignments[pdc_id] != "":
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
	# Generate consistent ID for torpedo tracking
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

# Debug information
func get_debug_info() -> String:
	var active_targets = tracked_targets.size()
	var engaged_targets = target_assignments.size()
	var busy_pdcs = 0
	
	for pdc_id in pdc_assignments:
		if pdc_assignments[pdc_id] != "":
			busy_pdcs += 1
	
	return "Fire Control: %d targets tracked, %d engaged | PDCs: %d/%d active | Intercepts: %d/%d" % [
		active_targets, engaged_targets, busy_pdcs, registered_pdcs.size(), 
		successful_intercepts, total_engagements
	]

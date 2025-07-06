# Scripts/Systems/FireControlManager.gd - CENTRAL FIRE CONTROL SYSTEM
# FIXES APPLIED:
# 1. Fixed unused target_data variable in remove_target() - now properly uses it for intercept detection
# 2. Fixed unused pdc_id parameter in pdc_ready_to_fire() - now properly validates the PDC
# 3. These fixes ensure PDCs only fire when targets are in range and maintain proper target tracking

extends Node2D
class_name FireControlManager

# DEBUG CONTROL - Set these in the Godot editor
@export var debug_enabled: bool = true
@export var debug_verbose: bool = false  # Extra verbose logging
@export var debug_interval: float = 2.0  # How often to print status summary
var debug_timer: float = 0.0
var last_target_count: int = 0

# System configuration
@export var engagement_range_meters: float = 15000.0
@export var min_intercept_distance_meters: float = 5.0
@export var max_simultaneous_engagements: int = 10  # Limit for performance

# Target assessment thresholds
@export var critical_time_threshold: float = 2.0    # seconds
@export var short_time_threshold: float = 5.0       # seconds
@export var medium_time_threshold: float = 15.0     # seconds

# Multi-PDC coordination
@export var difficult_intercept_threshold: float = 0.3  # Feasibility score threshold
@export var multi_pdc_assignment_bonus: float = 1.5    # Priority multiplier for multi-PDC targets

# PDC Registry
var registered_pdcs: Dictionary = {}  # pdc_id -> PDC node reference
var pdc_assignments: Dictionary = {}  # pdc_id -> target_id
var target_assignments: Dictionary = {}  # target_id -> Array of pdc_ids

# Target tracking
var tracked_targets: Dictionary = {}  # target_id -> TargetData
var target_priorities: Array = []     # Sorted array of target_ids by priority

# System state
var parent_ship: Node2D
var sensor_system: SensorSystem
var ship_faction: String = "friendly"
var ship_forward_direction: Vector2 = Vector2.UP

# Performance optimization
var update_interval: float = 0.05  # 20Hz update rate
var update_timer: float = 0.0

# Statistics
var total_engagements: int = 0
var successful_intercepts: int = 0
var exec_counter: int = 0  # For debug throttling

# Target data structure
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
	var distance_meters: float = 0.0  # Added for range checking

func _ready():
	parent_ship = get_parent()
	
	if parent_ship:
		sensor_system = parent_ship.get_node_or_null("SensorSystem")
		if "faction" in parent_ship:
			ship_faction = parent_ship.faction
		
		# Discover and register all PDCs
		discover_pdcs()
	
	print("FireControlManager initialized with ", registered_pdcs.size(), " PDCs")

func discover_pdcs():
	# Find all PDC nodes in the ship
	print("FCM: Discovering PDCs on ship...")
	for child in parent_ship.get_children():
		if child.has_method("get_capabilities"):  # PDCs have this method
			register_pdc(child)
			print("FCM: Found PDC: ", child.name)
	
	if registered_pdcs.size() == 0:
		print("FCM WARNING: No PDCs found! Check if PDCSystem script is attached correctly.")

func register_pdc(pdc_node: Node2D):
	var pdc_id = pdc_node.pdc_id
	registered_pdcs[pdc_id] = pdc_node
	pdc_assignments[pdc_id] = ""
	
	# Set this manager as the PDC's controller
	pdc_node.set_fire_control_manager(self)
	
	print("Registered PDC: ", pdc_id)

func _physics_process(delta):
	if not sensor_system:
		return
	
	# Update ship orientation
	ship_forward_direction = Vector2.UP.rotated(parent_ship.rotation)
	
	# Debug summary timer
	if debug_enabled:
		debug_timer += delta
		if debug_timer >= debug_interval:
			debug_timer = 0.0
			print_debug_summary()
	
	# Throttle updates for performance
	update_timer += delta
	if update_timer < update_interval:
		return
	update_timer = 0.0
	
	# Main fire control loop
	update_target_tracking()
	assess_all_threats()
	optimize_pdc_assignments()
	execute_fire_missions()

# NEW: Debug summary function for cleaner output
func print_debug_summary():
	var active_targets = tracked_targets.size()
	var engaged_pdcs = get_busy_pdc_count()
	var critical_count = 0
	var in_range_count = 0
	
	for target_data in tracked_targets.values():
		if target_data.is_critical:
			critical_count += 1
		if target_data.distance_meters <= engagement_range_meters:
			in_range_count += 1
	
	print("\n=== FCM STATUS ===")
	print("Targets: %d tracked (%d critical, %d in range)" % [active_targets, critical_count, in_range_count])
	print("PDCs: %d/%d engaged" % [engaged_pdcs, registered_pdcs.size()])
	
	# Print PDC status
	for pdc_id in registered_pdcs:
		var pdc = registered_pdcs[pdc_id]
		var target_id = pdc_assignments[pdc_id]
		if target_id != "":
			var status = pdc.get_status()
			print("  %s -> %s (rot: %.1f°, error: %.1f°)" % [
				pdc_id, 
				target_id.substr(0, 15),
				rad_to_deg(status.current_rotation),
				rad_to_deg(status.tracking_error)
			])
	
	# Top 3 priority targets
	if target_priorities.size() > 0:
		print("Top threats:")
		for i in range(min(3, target_priorities.size())):
			var target_id = target_priorities[i]
			var data = tracked_targets[target_id]
			print("  %s: %.1fs TTI, %.1fkm, score: %.2f" % [
				target_id.substr(0, 15),
				data.time_to_impact,
				data.distance_meters / 1000.0,
				data.priority_score
			])
	print("==================\n")

func update_target_tracking():
	var current_torpedoes = sensor_system.get_all_enemy_torpedoes()
	
	# Only log significant changes
	if debug_enabled and current_torpedoes.size() != last_target_count:
		if current_torpedoes.size() > last_target_count:
			print("FCM: Detected %d enemy torpedoes!" % current_torpedoes.size())
		last_target_count = current_torpedoes.size()
	
	# Update existing targets
	var targets_to_remove = []
	for target_id in tracked_targets:
		var target_data = tracked_targets[target_id]
		
		# Check if target still exists
		if not is_instance_valid(target_data.node_ref) or not target_data.node_ref in current_torpedoes:
			targets_to_remove.append(target_id)
			continue
		
		# Update target data
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
		print("FCM: Added new target: %s at %.1f km" % [target_data.target_id, target_data.distance_meters / 1000.0])

func update_target_data(target_data: TargetData):
	var torpedo = target_data.node_ref
	target_data.last_position = torpedo.global_position
	target_data.last_velocity = get_torpedo_velocity(torpedo)
	
	# Calculate distance and time to impact
	var ship_pos = parent_ship.global_position
	var relative_pos = target_data.last_position - ship_pos
	var relative_vel = target_data.last_velocity - get_ship_velocity()
	target_data.distance_meters = relative_pos.length() * WorldSettings.meters_per_pixel
	
	# Simple time-to-impact calculation
	var closing_speed = -relative_vel.dot(relative_pos.normalized())
	if closing_speed > 0:
		target_data.time_to_impact = target_data.distance_meters / closing_speed
	else:
		target_data.time_to_impact = 999.0
	
	# Calculate intercept point
	target_data.intercept_point = calculate_intercept_point(torpedo)
	
	# Calculate feasibility - BUT ONLY if target is in engagement range
	if target_data.distance_meters <= engagement_range_meters:
		target_data.feasibility_score = calculate_intercept_feasibility(target_data)
	else:
		target_data.feasibility_score = 0.0  # Not in range yet
	
	# Determine if critical
	target_data.is_critical = target_data.time_to_impact < critical_time_threshold and target_data.distance_meters <= engagement_range_meters

func calculate_intercept_point(torpedo: Node2D) -> Vector2:
	# This is a simplified calculation - the full implementation would solve
	# the complete intercept problem accounting for bullet travel time
	var torpedo_pos = torpedo.global_position
	var torpedo_vel = get_torpedo_velocity(torpedo) / WorldSettings.meters_per_pixel
	
	# Estimate bullet travel time
	var avg_pdc_pos = get_average_pdc_position()
	var distance = avg_pdc_pos.distance_to(torpedo_pos)
	var bullet_time = distance * WorldSettings.meters_per_pixel / 800.0  # bullet velocity
	
	# Predict where torpedo will be
	return torpedo_pos + torpedo_vel * bullet_time

# FIXED: Better feasibility calculation with range check
func calculate_intercept_feasibility(target_data: TargetData) -> float:
	# First check: Is target in engagement range?
	if target_data.distance_meters > engagement_range_meters:
		return 0.0
	
	# Check if intercept point is geometrically valid
	var ship_to_target = target_data.last_position - parent_ship.global_position
	var closing_velocity = -target_data.last_velocity.dot(ship_to_target.normalized())
	
	# If target is moving away, it's not a threat
	if closing_velocity <= 0:
		return 0.0
	
	# Check if target is already too close (past the ship)
	if target_data.distance_meters < min_intercept_distance_meters:
		return 0.0
	
	# Check if any PDC can reach the target
	var best_feasibility = 0.0
	for pdc_id in registered_pdcs:
		var pdc = registered_pdcs[pdc_id]
		var pdc_feasibility = calculate_pdc_target_feasibility(pdc, target_data)
		best_feasibility = max(best_feasibility, pdc_feasibility)
	
	return best_feasibility

# FIXED: PDCs can now rotate 360 degrees
func calculate_pdc_target_feasibility(pdc: Node2D, target_data: TargetData) -> float:
	# Get the required angle to hit the intercept point
	var pdc_pos = pdc.get_muzzle_world_position()
	var to_intercept = target_data.intercept_point - pdc_pos
	var world_angle = to_intercept.angle()
	
	# Convert to ship-relative angle
	var required_angle = world_angle - parent_ship.rotation
	
	# Normalize to -PI to PI
	while required_angle > PI:
		required_angle -= TAU
	while required_angle < -PI:
		required_angle += TAU
	
	# PDCs can rotate 360 degrees - no arc limitations
	# The only limit is rotation time vs time to impact
	
	# Calculate rotation time needed
	var current_angle = pdc.current_rotation
	var rotation_needed = abs(angle_difference(current_angle, required_angle))
	var rotation_time = rotation_needed / deg_to_rad(pdc.turret_rotation_speed)
	
	# Add a small buffer for aiming
	rotation_time += 0.2
	
	# Can we rotate in time?
	if rotation_time > target_data.time_to_impact:
		return 0.1  # Low feasibility but not zero
	
	# Good feasibility based on how much time margin we have
	var time_margin = target_data.time_to_impact - rotation_time
	return clamp(time_margin / 3.0, 0.1, 1.0)

func assess_all_threats():
	target_priorities.clear()
	
	for target_id in tracked_targets:
		var target_data = tracked_targets[target_id]
		
		# Skip targets outside engagement range or impossible targets
		if target_data.feasibility_score <= 0.0:
			continue
		
		# Calculate priority score
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
	
	# Time-based priority (most important factor)
	if target_data.time_to_impact < critical_time_threshold:
		base_priority = 100.0
	elif target_data.time_to_impact < short_time_threshold:
		base_priority = 50.0
	elif target_data.time_to_impact < medium_time_threshold:
		base_priority = 25.0
	else:
		base_priority = 10.0
	
	# Scale by inverse time (closer = higher priority)
	var time_factor = 1.0 / max(target_data.time_to_impact, 0.1)
	base_priority *= time_factor
	
	# Factor in feasibility
	base_priority *= target_data.feasibility_score
	
	# Factor in current PDC availability
	var available_pdcs = get_available_pdc_count()
	var total_pdcs = registered_pdcs.size()
	if available_pdcs < total_pdcs * 0.3:  # Less than 30% available
		base_priority *= 1.5  # Increase priority when resources are scarce
	
	target_data.priority_score = base_priority

# FIXED: Better PDC assignment with idle state management
func optimize_pdc_assignments():
	# Clear current assignments
	for pdc_id in pdc_assignments:
		pdc_assignments[pdc_id] = ""
	target_assignments.clear()
	
	# Assign PDCs to targets in priority order
	for target_id in target_priorities:
		var target_data = tracked_targets[target_id]
		
		# Skip targets with zero feasibility
		if target_data.feasibility_score <= 0.0:
			continue
		
		# Determine how many PDCs this target needs
		var pdcs_needed = 1
		if target_data.is_critical:
			pdcs_needed = 2
		elif target_data.feasibility_score < difficult_intercept_threshold:
			pdcs_needed = 2
		
		# Find best PDCs for this target
		var assigned_pdcs = assign_pdcs_to_target(target_data, pdcs_needed)
		
		if assigned_pdcs.size() > 0:
			target_assignments[target_id] = assigned_pdcs
			target_data.assigned_pdcs = assigned_pdcs
	
	# Stop any unassigned PDCs
	for pdc_id in registered_pdcs:
		if pdc_assignments[pdc_id] == "":
			var pdc = registered_pdcs[pdc_id]
			if pdc.current_status != "IDLE":
				pdc.stop_firing()

func assign_pdcs_to_target(target_data: TargetData, pdcs_needed: int) -> Array:
	var available_pdcs = []
	var assigned = []
	
	# Get all available PDCs and score them
	for pdc_id in registered_pdcs:
		if pdc_assignments[pdc_id] == "":  # Available
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
	# Calculate geometric efficiency
	var pdc_pos = pdc.get_muzzle_world_position()
	var to_intercept = target_data.intercept_point - pdc_pos
	var required_angle = to_intercept.angle()
	
	# Rotation time
	var current_angle = pdc.current_rotation
	var rotation_needed = abs(angle_difference(current_angle, required_angle))
	var rotation_time = rotation_needed / deg_to_rad(pdc.turret_rotation_speed)
	
	# Can't engage if rotation takes too long
	if rotation_time > target_data.time_to_impact * 0.7:
		return 0.0
	
	# Score based on how quickly PDC can engage
	var rotation_score = 1.0 - (rotation_time / target_data.time_to_impact)
	
	# Bonus for PDCs already roughly aimed in the right direction
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
		
		# Double-check target is still in range before firing
		if target_data.distance_meters > engagement_range_meters:
			continue
		
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

# FIXED: Now properly validates the PDC and uses the pdc_id parameter
func pdc_ready_to_fire(pdc_id: String):
	# Called by PDC when it's aimed and ready
	if not registered_pdcs.has(pdc_id):
		if debug_verbose:
			print("FCM Warning: Unknown PDC %s reported ready" % pdc_id)
		return
	
	if not pdc_assignments.has(pdc_id) or pdc_assignments[pdc_id] == "":
		if debug_verbose:
			print("FCM: PDC %s ready but no target assigned" % pdc_id)
		return
	
	var target_id = pdc_assignments[pdc_id]
	if not tracked_targets.has(target_id):
		if debug_verbose:
			print("FCM: PDC %s ready but target %s no longer tracked" % [pdc_id, target_id])
		return
	
	var target_data = tracked_targets[target_id]
	
	# Final range check before allowing fire
	if target_data.distance_meters > engagement_range_meters:
		if debug_verbose:
			print("FCM: PDC %s ready but target %s out of range (%.1f km)" % [pdc_id, target_id, target_data.distance_meters / 1000.0])
		return
	
	# All checks passed - authorize firing
	var pdc = registered_pdcs[pdc_id]
	pdc.start_firing()
	
	if debug_verbose:
		print("FCM: Authorized firing for PDC %s on target %s" % [pdc_id, target_id])

# FIXED: remove_target function with proper intercept tracking
func remove_target(target_id: String):
	# Clean up target
	if tracked_targets.has(target_id):
		var target_data = tracked_targets[target_id]
		
		# Determine if this was a successful intercept based on multiple factors
		var was_successful_intercept = false
		
		# Check if target was destroyed before getting dangerously close
		var distance_to_ship = target_data.last_position.distance_to(parent_ship.global_position)
		var distance_meters = distance_to_ship * WorldSettings.meters_per_pixel
		
		# Consider it successful if:
		# 1. Target was destroyed with time remaining (not a miss due to proximity)
		# 2. Target was still at a safe distance from the ship
		# 3. Target had been engaged by our PDCs
		if target_data.time_to_impact > 0.5 and distance_meters > 100.0 and target_data.assigned_pdcs.size() > 0:
			was_successful_intercept = true
			successful_intercepts += 1
			
			if debug_verbose:
				print("FCM: SUCCESSFUL INTERCEPT of %s (TTI: %.1fs, distance: %.1fm, PDCs: %d)" % [
					target_id.substr(0, 15), 
					target_data.time_to_impact,
					distance_meters,
					target_data.assigned_pdcs.size()
				])
		else:
			if debug_verbose:
				var reason = "unknown"
				if target_data.time_to_impact <= 0.5:
					reason = "too close (%.1fs TTI)" % target_data.time_to_impact
				elif distance_meters <= 100.0:
					reason = "proximity (%.1fm)" % distance_meters
				elif target_data.assigned_pdcs.size() == 0:
					reason = "unengaged"
				
				print("FCM: Target %s removed - NOT intercept (%s)" % [
					target_id.substr(0, 15), reason
				])
		
		# Stop all PDCs assigned to this target
		for pdc_id in target_data.assigned_pdcs:
			if registered_pdcs.has(pdc_id):
				var pdc = registered_pdcs[pdc_id]
				pdc.stop_firing()
				pdc_assignments[pdc_id] = ""
				
				if debug_verbose:
					print("FCM: Stopped PDC %s (was targeting %s)" % [pdc_id, target_id.substr(0, 15)])
		
		# Update engagement statistics
		var engagement_duration = (Time.get_ticks_msec() / 1000.0) - target_data.engagement_start_time
		
		# Log engagement summary for analysis
		if debug_enabled and (was_successful_intercept or target_data.is_critical):
			print("FCM: Engagement Summary - %s: %s (%.1fs duration, %d PDCs)" % [
				target_id.substr(0, 15),
				"SUCCESS" if was_successful_intercept else "FAILED",
				engagement_duration,
				target_data.assigned_pdcs.size()
			])
		
		# Clean up tracking data
		tracked_targets.erase(target_id)
		if target_assignments.has(target_id):
			target_assignments.erase(target_id)
		
		# Remove from priority list
		var index = target_priorities.find(target_id)
		if index >= 0:
			target_priorities.remove_at(index)

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

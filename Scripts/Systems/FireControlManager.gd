# Scripts/Systems/FireControlManager.gd - CENTRAL FIRE CONTROL SYSTEM
extends Node2D
class_name FireControlManager

# DEBUG CONTROL
@export var debug_enabled: bool = true

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

func update_target_tracking():
	var current_torpedoes = sensor_system.get_all_enemy_torpedoes()
	
	# DEBUG: Log torpedo detection
	if current_torpedoes.size() > 0 and tracked_targets.size() == 0:
		print("FCM: Detected %d enemy torpedoes!" % current_torpedoes.size())
	
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
			print("FCM: Added new target: ", torpedo_id)

func add_new_target(torpedo: Node2D):
	var target_data = TargetData.new()
	target_data.target_id = get_torpedo_id(torpedo)
	target_data.node_ref = torpedo
	target_data.engagement_start_time = Time.get_ticks_msec() / 1000.0
	
	update_target_data(target_data)
	tracked_targets[target_data.target_id] = target_data
	
	total_engagements += 1

func update_target_data(target_data: TargetData):
	var torpedo = target_data.node_ref
	target_data.last_position = torpedo.global_position
	target_data.last_velocity = get_torpedo_velocity(torpedo)
	
	# Calculate time to impact
	var ship_pos = parent_ship.global_position
	var relative_pos = target_data.last_position - ship_pos
	var relative_vel = target_data.last_velocity - get_ship_velocity()
	var distance_meters = relative_pos.length() * WorldSettings.meters_per_pixel
	
	# Simple time-to-impact calculation
	var closing_speed = -relative_vel.dot(relative_pos.normalized())
	if closing_speed > 0:
		target_data.time_to_impact = distance_meters / closing_speed
	else:
		target_data.time_to_impact = 999.0
	
	# Calculate intercept point
	target_data.intercept_point = calculate_intercept_point(torpedo)
	
	# Calculate feasibility
	target_data.feasibility_score = calculate_intercept_feasibility(target_data)
	
	# Determine if critical
	target_data.is_critical = target_data.time_to_impact < critical_time_threshold

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

func calculate_intercept_feasibility(target_data: TargetData) -> float:
	# Check if intercept point is geometrically valid
	var intercept_local = parent_ship.to_local(target_data.intercept_point)
	
	# Never engage targets whose intercept is behind the ship
	if intercept_local.y > 0:  # Behind ship (assuming ship faces up)
		return 0.0
	
	# Check if any PDC can reach the target
	var best_feasibility = 0.0
	for pdc_id in registered_pdcs:
		var pdc = registered_pdcs[pdc_id]
		var pdc_feasibility = calculate_pdc_target_feasibility(pdc, target_data)
		best_feasibility = max(best_feasibility, pdc_feasibility)
	
	return best_feasibility

func calculate_pdc_target_feasibility(pdc: Node2D, target_data: TargetData) -> float:
	var pdc_pos = pdc.get_muzzle_world_position()
	var to_intercept = target_data.intercept_point - pdc_pos
	var required_angle = to_intercept.angle()
	
	# Check if within firing arc (simplified - assumes forward arc)
	var pdc_forward = ship_forward_direction
	var angle_diff = abs(pdc_forward.angle_to(to_intercept.normalized()))
	
	if rad_to_deg(angle_diff) > 80.0:  # Outside 160° forward arc
		return 0.0
	
	# Calculate rotation time needed
	var current_angle = pdc.current_rotation
	var rotation_needed = abs(angle_difference(current_angle, required_angle))
	var rotation_time = rotation_needed / deg_to_rad(pdc.turret_rotation_speed)
	
	# Can we rotate in time?
	if rotation_time > target_data.time_to_impact * 0.8:  # 80% margin
		return 0.1  # Low feasibility
	
	# Good feasibility based on how much time margin we have
	var time_margin = target_data.time_to_impact - rotation_time
	return clamp(time_margin / 5.0, 0.0, 1.0)

func assess_all_threats():
	target_priorities.clear()
	
	for target_id in tracked_targets:
		var target_data = tracked_targets[target_id]
		
		# Skip impossible targets
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

func optimize_pdc_assignments():
	# Clear current assignments
	for pdc_id in pdc_assignments:
		pdc_assignments[pdc_id] = ""
	target_assignments.clear()
	
	# Assign PDCs to targets in priority order
	for target_id in target_priorities:
		var target_data = tracked_targets[target_id]
		
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

func execute_fire_missions():
	# DEBUG: Log execution status
	if target_assignments.size() > 0:
		print("FCM: Executing fire missions for %d targets" % target_assignments.size())
	
	for target_id in target_assignments:
		if not tracked_targets.has(target_id):
			print("FCM ERROR: Target assignment for non-existent target!")
			continue
			
		var target_data = tracked_targets[target_id]
		var assigned_pdcs = target_assignments[target_id]
		
		# DEBUG: Log PDC assignments
		print("FCM: Target %s assigned to %d PDCs" % [target_id, assigned_pdcs.size()])
		
		for pdc_id in assigned_pdcs:
			var pdc = registered_pdcs[pdc_id]
			
			# Calculate firing solution
			var firing_angle = calculate_firing_solution(pdc, target_data)
			
			# DEBUG: Log firing solution
			var current_angle_deg = rad_to_deg(pdc.current_rotation)
			var target_angle_deg = rad_to_deg(firing_angle)
			print("FCM: PDC %s - Current: %.1f°, Target: %.1f°" % [pdc_id, current_angle_deg, target_angle_deg])
			
			# Command PDC
			var is_emergency = target_data.is_critical
			pdc.set_target(target_id, firing_angle, is_emergency)
			
			# Start firing if PDC reports ready
			if pdc.is_aimed():
				pdc.start_firing()
				print("FCM: PDC %s started firing!" % pdc_id)

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
	
	# Calculate angle to predicted position
	var to_intercept = predicted_pos - pdc_pos
	var firing_angle = to_intercept.angle()
	
	# DEBUG: Log calculation details
	if debug_enabled:
		print("FCM Firing Solution:")
		print("  Target at: ", target_pos)
		print("  Target velocity: ", target_vel, " m/s")
		print("  Bullet flight time: %.2f s" % bullet_time)
		print("  Predicted intercept: ", predicted_pos)
		print("  Firing angle: %.1f°" % rad_to_deg(firing_angle))
	
	return firing_angle

func pdc_ready_to_fire(pdc_id: String):
	# Called by PDC when it's aimed and ready
	if pdc_assignments.has(pdc_id) and pdc_assignments[pdc_id] != "":
		var pdc = registered_pdcs[pdc_id]
		pdc.start_firing()

func remove_target(target_id: String):
	# Clean up target
	if tracked_targets.has(target_id):
		var target_data = tracked_targets[target_id]
		
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

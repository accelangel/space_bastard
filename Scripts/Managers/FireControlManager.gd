# Scripts/Managers/FireControlManager.gd - Mode-Aware Version
extends Node2D
class_name FireControlManager

# PDC Registry (these are stable)
var registered_pdcs: Dictionary = {}  # pdc_id -> PDC node

# System configuration
@export var engagement_range_meters: float = 15000.0
@export var min_intercept_distance_meters: float = 5.0

# Target assessment thresholds  
@export var critical_time_threshold: float = 2.0
@export var short_time_threshold: float = 5.0
@export var medium_time_threshold: float = 15.0

# System state
var parent_ship: Node2D
var sensor_system: SensorSystem
var ship_faction: String = "friendly"

# Performance optimization
var update_interval: float = 0.05
var update_timer: float = 0.0

# Debug control - set to false for minimal output
@export var debug_enabled: bool = false

func _ready():
	# Subscribe to mode changes
	GameMode.mode_changed.connect(_on_mode_changed)
	
	# Start with physics disabled
	set_physics_process(false)
	
	parent_ship = get_parent()
	
	if parent_ship:
		sensor_system = parent_ship.get_node_or_null("SensorSystem")
		if "faction" in parent_ship:
			ship_faction = parent_ship.faction
		# Defer PDC discovery to ensure they're initialized
		call_deferred("discover_pdcs")
	
	# Add to groups
	add_to_group("fire_control_systems")
	
	print("FireControlManager initialized on %s - waiting for mode selection" % parent_ship.name)

func _on_mode_changed(new_mode: GameMode.Mode):
	var should_process = (new_mode == GameMode.Mode.BATTLE)
	set_physics_process(should_process)
	
	if not should_process:
		# Emergency stop all PDCs
		emergency_stop_all()
		print("FireControlManager disabled on %s" % parent_ship.name)
	else:
		print("FireControlManager enabled on %s" % parent_ship.name)

func discover_pdcs():
	for child in parent_ship.get_children():
		if child.has_method("get_capabilities") and child.has_method("set_target"):
			register_pdc(child)
	
	if debug_enabled:
		print("FireControlManager initialized with %d PDCs" % registered_pdcs.size())

func register_pdc(pdc_node: Node2D):
	# Make sure PDC has an ID
	if not ("pdc_id" in pdc_node) or pdc_node.pdc_id == "":
		if debug_enabled:
			print("WARNING: PDC has no ID, skipping registration")
		return
		
	var pdc_id = pdc_node.pdc_id
	registered_pdcs[pdc_id] = pdc_node
	pdc_node.set_fire_control_manager(self)
	if debug_enabled:
		print("Registered PDC: %s" % pdc_id)

func _physics_process(delta):
	# Extra safety check
	if not GameMode.is_battle_mode():
		set_physics_process(false)
		return
	
	if not sensor_system:
		return
	
	update_timer += delta
	if update_timer < update_interval:
		return
	update_timer = 0.0
	
	# Get current torpedo snapshot
	var torpedoes = get_valid_torpedoes()
	
	# Assign PDCs based on current state
	assign_pdcs_immediate(torpedoes)

func get_valid_torpedoes() -> Array:
	var valid_torpedoes = []
	
	# Query scene tree for current torpedoes
	var all_torpedoes = get_tree().get_nodes_in_group("torpedoes")
	
	for torpedo in all_torpedoes:
		if is_valid_combat_entity(torpedo):
			# Calculate current threat data
			var threat_data = assess_threat_immediate(torpedo)
			if threat_data.is_engageable:
				valid_torpedoes.append({
					"node": torpedo,
					"threat_data": threat_data
				})
	
	# Sort by priority
	valid_torpedoes.sort_custom(func(a, b): 
		return a.threat_data.priority > b.threat_data.priority
	)
	
	return valid_torpedoes

func is_valid_combat_entity(entity: Node2D) -> bool:
	if not entity:
		return false
	# CRITICAL: Check instance validity FIRST before accessing ANY properties
	if not is_instance_valid(entity):
		return false
	if not entity.is_inside_tree():
		return false
	# Now safe to check properties - use get() instead of has()
	if entity.get("marked_for_death"):
		return false
	if entity.get("faction") == ship_faction:
		return false
	return true

func assess_threat_immediate(torpedo: Node2D) -> Dictionary:
	# Validate torpedo is still valid before accessing properties
	if not is_instance_valid(torpedo):
		return {
			"is_engageable": false,
			"time_to_impact": INF,
			"distance": INF,
			"distance_meters": INF,
			"closing_velocity": 0.0,
			"priority": 0.0
		}
	
	var ship_pos = parent_ship.global_position
	var torpedo_pos = torpedo.global_position
	var torpedo_vel = torpedo.get("velocity_mps") if torpedo.has("velocity_mps") else Vector2.ZERO
	
	# Calculate everything fresh
	var distance = ship_pos.distance_to(torpedo_pos)
	var distance_meters = distance * WorldSettings.meters_per_pixel
	
	# Get relative velocity
	var to_ship = (ship_pos - torpedo_pos).normalized()
	var closing_velocity = torpedo_vel.dot(to_ship) if torpedo_vel else 0.0
	
	# Check if torpedo is behind ship and moving away
	var ship_forward = Vector2.UP.rotated(parent_ship.rotation)
	var to_torpedo = (torpedo_pos - ship_pos).normalized()
	var is_behind = ship_forward.dot(to_torpedo) < -0.5  # More than 90 degrees behind
	
	# If torpedo is behind ship and not approaching, it's not a threat
	if is_behind and closing_velocity <= 0:
		return {
			"is_engageable": false,
			"time_to_impact": INF,
			"distance": distance,
			"distance_meters": distance_meters,
			"closing_velocity": closing_velocity,
			"priority": 0.0
		}
	
	var time_to_impact = INF
	if closing_velocity > 0:
		time_to_impact = distance_meters / closing_velocity
	
	# Check if within engagement envelope
	var is_engageable = (
		distance_meters <= engagement_range_meters and
		time_to_impact < 30.0 and
		closing_velocity > 0 and
		not is_behind  # Don't engage torpedoes behind us
	)
	
	# Calculate priority
	var priority = 0.0
	if is_engageable:
		if time_to_impact < critical_time_threshold:
			priority = 100.0
		elif time_to_impact < short_time_threshold:
			priority = 50.0
		elif time_to_impact < medium_time_threshold:
			priority = 25.0
		else:
			priority = 10.0
		
		# Factor in distance
		priority *= (1.0 - (distance_meters / engagement_range_meters))
	
	return {
		"is_engageable": is_engageable,
		"time_to_impact": time_to_impact,
		"distance": distance,
		"distance_meters": distance_meters,
		"closing_velocity": closing_velocity,
		"priority": priority
	}

func assign_pdcs_immediate(torpedo_list: Array):
	# Clear all PDC targets first - with proper validation
	for pdc in registered_pdcs.values():
		if is_instance_valid(pdc) and pdc.has_method("is_valid_target"):
			# Check if target is valid before passing to function
			if pdc.get("current_target") != null:
				if not is_instance_valid(pdc.current_target):
					# Target was freed, clear it directly
					pdc.current_target = null
					if pdc.has_method("stop_firing"):
						pdc.stop_firing()
				elif not pdc.is_valid_target(pdc.current_target):
					# Target is invalid for other reasons
					pdc.set_target(null)
	
	# Track which PDCs are assigned this frame
	var assigned_pdcs = {}
	
	# Assign based on current snapshot
	for torpedo_data in torpedo_list:
		var torpedo = torpedo_data.node
		# Extra validation before assignment
		if not is_instance_valid(torpedo):
			continue
			
		var threat = torpedo_data.threat_data
		
		# Skip if all PDCs are busy
		if assigned_pdcs.size() >= registered_pdcs.size():
			break
		
		# Find best available PDC
		var best_pdc = find_best_pdc_for_target(torpedo, assigned_pdcs)
		
		if best_pdc and is_instance_valid(best_pdc):
			best_pdc.set_target(torpedo)
			assigned_pdcs[best_pdc.pdc_id] = torpedo
			
			# Assign second PDC for critical targets
			if threat.time_to_impact < critical_time_threshold:
				var second_pdc = find_best_pdc_for_target(torpedo, assigned_pdcs)
				if second_pdc and is_instance_valid(second_pdc):
					second_pdc.set_target(torpedo)
					assigned_pdcs[second_pdc.pdc_id] = torpedo

func find_best_pdc_for_target(torpedo: Node2D, already_assigned: Dictionary) -> Node2D:
	var best_pdc = null
	var best_score = -INF
	
	# Extra validation
	if not is_instance_valid(torpedo):
		return null
	
	for pdc_id in registered_pdcs:
		# Skip if already assigned
		if already_assigned.has(pdc_id):
			continue
		
		var pdc = registered_pdcs[pdc_id]
		
		# Validate PDC is still valid
		if not is_instance_valid(pdc):
			continue
		
		# Skip if PDC is already engaged with a valid target
		if pdc.has("current_target") and pdc.current_target:
			# Check instance validity before calling is_valid_target
			if is_instance_valid(pdc.current_target):
				if pdc.has_method("is_valid_target") and pdc.is_valid_target(pdc.current_target):
					continue
			else:
				# Target was freed, clear it
				pdc.current_target = null
		
		var score = calculate_pdc_efficiency(pdc, torpedo)
		if score > best_score:
			best_score = score
			best_pdc = pdc
	
	return best_pdc

func calculate_pdc_efficiency(pdc: Node2D, torpedo: Node2D) -> float:
	# Validate both objects
	if not is_instance_valid(pdc) or not is_instance_valid(torpedo):
		return -1000.0
	
	# Safe property access
	var torpedo_vel = torpedo.get("velocity_mps") if "velocity_mps" in torpedo else Vector2.ZERO
	
	# Calculate angle to intercept point
	var intercept_point = calculate_intercept_point(pdc.get_muzzle_world_position(), torpedo.global_position, torpedo_vel)
	
	# Check if intercept point is behind ship
	var ship_pos = parent_ship.global_position
	var ship_forward = Vector2.UP.rotated(parent_ship.rotation)
	var to_intercept = intercept_point - ship_pos
	
	# If intercept point is behind ship, return very low score
	if ship_forward.dot(to_intercept) < 0:
		return -1000.0  # Effectively never choose this
	
	var to_intercept_from_pdc = intercept_point - pdc.get_muzzle_world_position()
	var required_world_angle = to_intercept_from_pdc.angle()
	
	# Convert to ship-relative angle (matching PDC's coordinate system)
	var required_ship_angle = required_world_angle - parent_ship.rotation + PI/2
	
	# Normalize angle
	while required_ship_angle > PI:
		required_ship_angle -= TAU
	while required_ship_angle < -PI:
		required_ship_angle += TAU
	
	# Calculate rotation needed
	var current_angle = pdc.get("current_rotation") if pdc.has("current_rotation") else 0.0
	var rotation_needed = abs(pdc.angle_difference(current_angle, required_ship_angle))
	
	# Factor in rotation time
	var rotation_speed = pdc.get("turret_rotation_speed") if pdc.has("turret_rotation_speed") else 360.0
	var rotation_time = rotation_needed / deg_to_rad(rotation_speed)
	
	# Score based on how quickly PDC can engage
	var score = 1.0 / (rotation_time + 0.1)
	
	# Bonus for PDCs already roughly aimed
	if rotation_needed < deg_to_rad(30):
		score *= 2.0
	
	# Penalty for extreme angles
	if rotation_needed > deg_to_rad(120):
		score *= 0.5
	
	return score

func calculate_intercept_point(shooter_pos: Vector2, target_pos: Vector2, target_vel: Vector2) -> Vector2:
	# Simple linear intercept calculation
	var to_target = target_pos - shooter_pos
	var distance = to_target.length()
	var distance_meters = distance * WorldSettings.meters_per_pixel
	
	# Bullet flight time
	var bullet_time = distance_meters / 1100.0  # PDC bullet velocity
	
	# Predict position
	var target_vel_pixels = target_vel / WorldSettings.meters_per_pixel
	return target_pos + target_vel_pixels * bullet_time

func emergency_stop_all():
	"""Emergency stop all PDCs"""
	if debug_enabled:
		print("FireControl: EMERGENCY STOP ALL")
	for pdc in registered_pdcs.values():
		if is_instance_valid(pdc) and pdc.has_method("emergency_stop"):
			pdc.emergency_stop()

func get_debug_info() -> String:
	var active_pdcs = 0
	for pdc in registered_pdcs.values():
		if is_instance_valid(pdc) and pdc.has("current_target") and pdc.current_target:
			# Check if target is still valid before counting
			if is_instance_valid(pdc.current_target):
				active_pdcs += 1
	
	return "PDCs: %d/%d active" % [active_pdcs, registered_pdcs.size()]

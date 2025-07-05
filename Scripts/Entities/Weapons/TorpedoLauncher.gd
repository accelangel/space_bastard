# Enhanced TorpedoLauncher.gd - UPDATED to use SensorSystem with DEBUG
extends Node2D
class_name TorpedoLauncher

@export var torpedo_scene: PackedScene
@export var launch_cooldown: float = 0.05  # Seconds between launches
@export var max_torpedoes: int = 100       # Max active torpedoes

var active_torpedoes: Array[Torpedo] = []
var last_launch_time: float = 0.0
var parent_ship: Node2D

# Ship's sensor system reference
var ship_sensor_system: SensorSystem = null

# ALTERNATING LAUNCH SYSTEM
var current_launch_side: int = 1  # 1 for right, -1 for left
var torpedoes_launched: int = 0   # Track total launched for alternating

# Auto-launch settings for testing
@export var auto_launch_enabled: bool = true
@export var auto_launch_interval: float = 3.0  # Seconds between auto launches
var auto_launch_timer: float = 0.0

# TEMPORARY: Fallback to old system if no sensors work
@export var use_fallback_targeting: bool = true  # Enable this for testing

# Get meters_per_pixel directly from WorldSettings singleton
var meters_per_pixel: float:
	get:
		return WorldSettings.meters_per_pixel

func _ready():
	parent_ship = get_parent()
	
	if parent_ship:
		print("TorpedoLauncher initialized on ship: ", parent_ship.name)
		
		# Find the ship's sensor system
		ship_sensor_system = parent_ship.get_node_or_null("SensorSystem")
		if ship_sensor_system:
			print("TorpedoLauncher found ship sensor system: ", ship_sensor_system.name)
		else:
			print("WARNING: TorpedoLauncher could not find ship sensor system!")
	else:
		print("ERROR: TorpedoLauncher has no parent ship!")
	
	# Load torpedo scene if not assigned
	if not torpedo_scene:
		torpedo_scene = preload("res://Scenes/Torpedo.tscn")
		if torpedo_scene:
			print("TorpedoLauncher: Loaded torpedo scene from default path")
		else:
			print("ERROR: TorpedoLauncher: Could not load torpedo scene!")

func _process(delta):
	# Clean up destroyed torpedoes
	active_torpedoes = active_torpedoes.filter(func(torpedo): return is_instance_valid(torpedo))
	
	# Auto-launch logic (for testing)
	if auto_launch_enabled:
		auto_launch_timer += delta
		if auto_launch_timer >= auto_launch_interval:
			auto_launch_at_best_target()
			auto_launch_timer = 0.0
	
	# Manual launch for testing - ADD DEBUG PRINTS
	if Input.is_action_just_pressed("launch_torpedo"):
		print("=== SPACEBAR PRESSED! ===")
		print("Attempting to launch torpedo...")
		var result = launch_at_best_target()
		if result:
			print("SUCCESS: Torpedo launched!")
		else:
			print("FAILED: No torpedo launched")
		print("========================")

# NEW: Launch torpedo at best target from sensor system
func launch_at_best_target() -> Torpedo:
	print("launch_at_best_target() called")
	
	var target_node = get_best_target_from_sensors()
	if target_node:
		print("Found sensor target: ", target_node.name)
		return launch_torpedo(target_node)
	else:
		print("No sensor targets found")
		
		# FALLBACK: Try old-style target finding
		if use_fallback_targeting:
			print("Trying fallback targeting...")
			var fallback_target = get_fallback_target()
			if fallback_target:
				print("Found fallback target: ", fallback_target.name)
				return launch_torpedo(fallback_target)
			else:
				print("No fallback targets found either")
		
		print("TorpedoLauncher: No valid targets detected")
		return null

# TEMPORARY: Old-style target finding for debugging
func get_fallback_target() -> Node2D:
	print("Searching for fallback targets...")
	
	# Find enemy ships the old way
	var enemy_ships = get_tree().get_nodes_in_group("enemy_ships")
	print("Found ", enemy_ships.size(), " enemy ships in group")
	
	if enemy_ships.size() > 0:
		# Return the first one for now
		return enemy_ships[0]
	
	# Try to find any EnemyShip nodes
	var all_nodes = get_tree().get_nodes_in_group("enemies")
	print("Found ", all_nodes.size(), " nodes in 'enemies' group")
	
	if all_nodes.size() > 0:
		return all_nodes[0]
	
	# Last resort: search the entire tree for EnemyShip
	print("Searching entire tree for EnemyShip nodes...")
	var root = get_tree().root
	return find_enemy_ship_recursive(root)

func find_enemy_ship_recursive(node: Node) -> Node2D:
	# Check if this node is an enemy ship
	if node.has_method("get_ship_type") and "Enemy" in node.get_ship_type():
		print("Found EnemyShip by recursive search: ", node.name)
		return node as Node2D
	
	# Check children
	for child in node.get_children():
		var result = find_enemy_ship_recursive(child)
		if result:
			return result
	
	return null

# NEW: Auto-launch version with less spam
func auto_launch_at_best_target() -> Torpedo:
	var target_node = get_best_target_from_sensors()
	if target_node:
		print("TorpedoLauncher: Auto-launching at target: ", target_node.name)
		return launch_torpedo(target_node)
	elif use_fallback_targeting:
		var fallback_target = get_fallback_target()
		if fallback_target:
			print("TorpedoLauncher: Auto-launching at fallback target: ", fallback_target.name)
			return launch_torpedo(fallback_target)
	return null

# NEW: Get best target from ship's sensor system
func get_best_target_from_sensors() -> Node2D:
	if not ship_sensor_system:
		print("TorpedoLauncher: No sensor system available")
		return null
	
	# Get enemy targets from sensors
	var enemy_targets = ship_sensor_system.get_detected_enemies()
	print("Sensor system detected ", enemy_targets.size(), " enemies")
	
	if enemy_targets.is_empty():
		return null
	
	# Filter for ships only (not projectiles)
	var ship_targets = []
	for detected in enemy_targets:
		if detected.entity_type in [
			EntityManager.EntityType.PLAYER_SHIP,
			EntityManager.EntityType.ENEMY_SHIP,
			EntityManager.EntityType.NEUTRAL_SHIP
		]:
			ship_targets.append(detected)
	
	print("Found ", ship_targets.size(), " enemy ships in sensor data")
	
	if ship_targets.is_empty():
		return null
	
	# Find closest enemy ship
	var best_target = null
	var closest_distance_sq = INF
	
	for detected in ship_targets:
		var distance_sq = parent_ship.global_position.distance_squared_to(detected.position)
		if distance_sq < closest_distance_sq:
			closest_distance_sq = distance_sq
			best_target = detected
	
	if best_target:
		print("Best sensor target found: ", best_target.entity_id)
		# Try to get the actual node reference
		var entity_manager = get_node_or_null("/root/EntityManager")
		if entity_manager:
			var entity_data = entity_manager.get_entity(best_target.entity_id)
			if entity_data and entity_data.node_ref:
				print("Got node reference for target: ", entity_data.node_ref.name)
				return entity_data.node_ref
			else:
				print("No node reference available for entity: ", best_target.entity_id)
		else:
			print("No EntityManager found")
	
	return null

func launch_torpedo(target: Node2D) -> Torpedo:
	var target_name = "null"
	if target:
		target_name = target.name
	print("launch_torpedo() called with target: ", target_name)
	
	if not can_launch():
		print("Cannot launch: cooldown or torpedo limit")
		return null
	
	if not torpedo_scene:
		print("ERROR: No torpedo scene assigned to launcher!")
		return null
	
	if not target or not is_instance_valid(target):
		print("ERROR: Invalid target provided to launch_torpedo")
		return null
	
	# Create torpedo instance
	var torpedo = torpedo_scene.instantiate() as Torpedo
	if not torpedo:
		print("ERROR: Torpedo scene must have Torpedo script!")
		return null
	
	# ALTERNATING LAUNCH SIDE LOGIC
	# Alternate sides with each launch to prevent collisions
	var launch_side = current_launch_side
	current_launch_side *= -1  # Flip for next launch
	
	# Set up the torpedo BEFORE adding to scene tree
	torpedo.global_position = global_position
	torpedo.set_launcher(parent_ship)
	torpedo.set_target(target)  # Use existing function name
	torpedo.set_meters_per_pixel(meters_per_pixel)
	torpedo.set_launch_side(launch_side)  # Set which side to launch toward
	
	torpedoes_launched += 1
	
	# Add to scene tree (triggers _ready())
	get_tree().root.add_child(torpedo)
	
	# Track the torpedo
	active_torpedoes.append(torpedo)
	last_launch_time = get_current_time()
	
	print("SUCCESS: Launched torpedo #", torpedoes_launched, " at ", target.name, " (side: ", launch_side, ")")
	
	return torpedo

func can_launch() -> bool:
	var current_time = get_current_time()
	var time_since_last = current_time - last_launch_time
	
	var can_launch_result = (active_torpedoes.size() < max_torpedoes and 
			time_since_last >= launch_cooldown)
	
	if not can_launch_result:
		print("Cannot launch: active_torpedoes=", active_torpedoes.size(), "/", max_torpedoes, 
			  " time_since_last=", time_since_last, " (need ", launch_cooldown, ")")
	
	return can_launch_result

func get_active_torpedo_count() -> int:
	return active_torpedoes.size()

func get_current_time() -> float:
	return Time.get_ticks_msec() / 1000.0

# Optional: Reset alternating pattern (useful for testing)
func reset_launch_pattern():
	current_launch_side = 1
	torpedoes_launched = 0

# Debug information
func get_debug_info() -> String:
	var sensor_status = "NO SENSORS"
	var target_count = 0
	
	if ship_sensor_system:
		sensor_status = "ACTIVE"
		var enemies = ship_sensor_system.get_detected_enemies()
		target_count = enemies.size()
	
	return "Launcher: %d/%d torps | Sensors: %s (%d targets) | Fallback: %s" % [
		active_torpedoes.size(), max_torpedoes, sensor_status, target_count, 
		"ON" if use_fallback_targeting else "OFF"
	]

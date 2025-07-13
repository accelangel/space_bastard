# Scripts/Entities/Ships/PlayerShip.gd - FIXED WITH UI INTEGRATION
extends Area2D
class_name PlayerShip

# Ship properties
@export var acceleration_gs: float = 0.05
@export var rotation_speed: float = 2.0
@export var faction: String = "friendly"

# Torpedo configuration
@export var use_multi_angle_torpedoes: bool = true
@export var use_simultaneous_impact: bool = false

# Movement
var acceleration_mps2: float
var velocity_mps: Vector2 = Vector2.ZERO
var movement_direction: Vector2 = Vector2.ZERO

# NEW: Movement control flag
var movement_enabled: bool = false

# Identity
var entity_id: String = ""
var ship_name: String = "Player Ship"
var is_alive: bool = true
var marked_for_death: bool = false

# Child nodes
@onready var sensor_system: SensorSystem = $SensorSystem
@onready var torpedo_launcher: Node2D = $TorpedoLauncher
@onready var fire_control_manager = $FireControlManager

# Test movement
var test_acceleration: bool = true
var test_direction: Vector2 = Vector2(1, -1).normalized()
var test_gs: float = 1.0

# Auto battle system
var auto_battle_started: bool = false
var battle_start_delay: float = 2.0
var battle_timer: float = 0.0
var battle_timer_enabled: bool = false  # NEW: Control for battle timer

# PID Tuner reference - FIXED
var pid_tuner: Node = null

# DEBUG CONTROL
@export var debug_enabled: bool = false

func _ready():
	acceleration_mps2 = acceleration_gs * 9.81
	
	# Generate unique ID
	entity_id = "player_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	
	# FIXED: Proper autoload access
	pid_tuner = TunerSystem
	
	# Configure torpedo launcher for trajectory type
	if torpedo_launcher:
		update_torpedo_launcher_settings()
		print("Player ship configured for %s torpedoes" % get_torpedo_mode_name())
	
	# Self-identify
	add_to_group("ships")
	add_to_group("player_ships")
	add_to_group("combat_entities")
	
	# Store identity as metadata
	set_meta("entity_id", entity_id)
	set_meta("faction", faction)
	set_meta("entity_type", "player_ship")
	
	# Notify observers of spawn
	get_tree().call_group("battle_observers", "on_entity_spawned", self, "player_ship")
	
	# NEW: Don't start test acceleration until mode selected
	if debug_enabled:
		print("PlayerShip spawned - waiting for mode selection")
	
	print("Player ship spawned: %s" % entity_id)

func update_torpedo_launcher_settings():
	"""Update torpedo launcher based on current settings"""
	if not torpedo_launcher:
		return
		
	if use_simultaneous_impact:
		torpedo_launcher.use_straight_trajectory = false
		torpedo_launcher.use_multi_angle_trajectory = false
		torpedo_launcher.use_simultaneous_impact = true
	elif use_multi_angle_torpedoes:
		torpedo_launcher.use_straight_trajectory = false
		torpedo_launcher.use_multi_angle_trajectory = true
		torpedo_launcher.use_simultaneous_impact = false
	else:
		torpedo_launcher.use_straight_trajectory = true
		torpedo_launcher.use_multi_angle_trajectory = false
		torpedo_launcher.use_simultaneous_impact = false

func get_torpedo_mode_name() -> String:
	"""Get current torpedo mode name for display"""
	if use_simultaneous_impact:
		return "Simultaneous Impact"
	elif use_multi_angle_torpedoes:
		return "Multi-Angle"
	else:
		return "Straight"

func _physics_process(delta):
	if marked_for_death or not is_alive:
		return
	
	# NEW: Only move if movement enabled
	if movement_enabled:
		# Update movement
		var acceleration_vector = movement_direction * acceleration_mps2
		velocity_mps += acceleration_vector * delta
		var velocity_pixels_per_second = velocity_mps / WorldSettings.meters_per_pixel
		global_position += velocity_pixels_per_second * delta
	
	# NEW: Only run battle timer if enabled
	if battle_timer_enabled and not auto_battle_started:
		battle_timer += delta
		if battle_timer >= battle_start_delay:
			start_auto_battle()
	
	# Notify sensor systems of our position for immediate state
	get_tree().call_group("sensor_systems", "report_entity_position", self, global_position, "player_ship", faction)

# NEW: Called by ModeSelector when battle mode chosen
func start_battle_timer():
	battle_timer_enabled = true
	battle_timer = 0.0
	print("Battle timer started - will fire in %.1f seconds" % battle_start_delay)

# NEW: Enable movement when mode selected
func enable_movement():
	movement_enabled = true
	if test_acceleration:
		set_acceleration(test_gs)
		set_movement_direction(test_direction)
		if debug_enabled:
			print("PlayerShip movement enabled at %.1fG" % test_gs)

func start_auto_battle():
	"""Automatically fire torpedoes to start the battle"""
	if auto_battle_started:
		return
		
	auto_battle_started = true
	print("Auto-starting battle - firing %s torpedoes" % get_torpedo_mode_name())
	fire_torpedoes_at_enemy()

func _input(event):
	if marked_for_death or not is_alive:
		return
	
	# NEW: Only allow manual actions if movement is enabled
	if not movement_enabled:
		return
	
	# SPACE key - manual torpedo fire only
	if event.is_action_pressed("ui_accept"):
		# Only allow manual torpedo fire if not in any mode
		if not battle_timer_enabled and (!pid_tuner or !pid_tuner.is_tuning_active()):
			print("Manual torpedo launch triggered")
			fire_torpedoes_at_enemy()
	
	# Toggle torpedo type on T key
	if event.is_action_pressed("ui_text_completion_query"):  # T key
		cycle_torpedo_mode()
	
	# Test simultaneous impact on S key
	if event.is_action_pressed("ui_page_down"):  # S key
		use_simultaneous_impact = true
		use_multi_angle_torpedoes = false
		update_torpedo_launcher_settings()
		print("Switched to Simultaneous Impact mode")
		# Only fire if appropriate
		if not battle_timer_enabled and (!pid_tuner or !pid_tuner.is_tuning_active()):
			fire_torpedoes_at_enemy()

func cycle_torpedo_mode():
	"""Cycle through torpedo modes: Straight -> Multi-Angle -> Simultaneous -> Straight"""
	if use_simultaneous_impact:
		# Switch to Straight
		use_simultaneous_impact = false
		use_multi_angle_torpedoes = false
	elif use_multi_angle_torpedoes:
		# Switch to Simultaneous
		use_simultaneous_impact = true
		use_multi_angle_torpedoes = false
	else:
		# Switch to Multi-Angle
		use_simultaneous_impact = false
		use_multi_angle_torpedoes = true
	
	update_torpedo_launcher_settings()
	print("Switched to %s torpedoes" % get_torpedo_mode_name())

func fire_torpedoes_at_enemy():
	if not torpedo_launcher:
		print("No torpedo launcher!")
		return
	
	# Don't fire during tuning
	if pid_tuner and pid_tuner.is_tuning_active():
		print("Cannot fire manually during PID tuning")
		return
		
	# Find closest enemy ship
	var enemy_ships = get_tree().get_nodes_in_group("enemy_ships")
	var closest_enemy = null
	var closest_distance = INF
	
	for ship in enemy_ships:
		if ship.get("is_alive") and ship.is_alive:
			var distance = global_position.distance_to(ship.global_position)
			if distance < closest_distance:
				closest_distance = distance
				closest_enemy = ship
	
	if closest_enemy:
		print("Player firing %s torpedoes at enemy ship" % get_torpedo_mode_name())
		torpedo_launcher.fire_torpedo(closest_enemy)
	else:
		print("No enemy ships found to target")

func set_movement_direction(new_direction: Vector2):
	movement_direction = new_direction.normalized()

func set_acceleration(gs: float):
	acceleration_gs = gs
	acceleration_mps2 = acceleration_gs * 9.81

func get_velocity_mps() -> Vector2:
	return velocity_mps

func toggle_test_acceleration():
	test_acceleration = !test_acceleration
	if test_acceleration:
		set_movement_direction(test_direction)
	else:
		set_movement_direction(Vector2.ZERO)

# NEW: Reset function for PID tuning
func reset_for_pid_cycle():
	global_position = Vector2(-64000, 35500)
	rotation = 0.785398  # 45 degrees
	velocity_mps = Vector2.ZERO
	movement_direction = test_direction
	if movement_enabled and test_acceleration:
		set_acceleration(test_gs)

func mark_for_destruction(reason: String):
	if marked_for_death:
		return
	
	marked_for_death = true
	is_alive = false
	
	# Disable physics
	set_physics_process(false)
	set_process_input(false)
	
	var collision = get_node_or_null("CollisionShape2D")
	if collision:
		collision.disabled = true
	
	# Notify observers
	get_tree().call_group("battle_observers", "on_entity_dying", self, reason)
	
	print("Player ship destroyed!")

func get_faction() -> String:
	return faction

func get_entity_id() -> String:
	return entity_id

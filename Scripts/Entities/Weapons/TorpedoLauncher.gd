# Scripts/Entities/Weapons/TorpedoLauncher.gd - UPDATED FOR BATTLE REFACTOR
extends Node2D
class_name TorpedoLauncher

@export var torpedo_scene: PackedScene
@export var launch_cooldown: float = 0.05
@export var max_torpedoes: int = 100

var active_torpedoes: Array[Torpedo] = []
var last_launch_time: float = 0.0
var parent_ship: Node2D
var sensor_system: SensorSystem

# Alternating launch system
var current_launch_side: int = 1
var torpedoes_launched: int = 0

# NEW: BattleManager interface - controlled externally now
@export var auto_launch_enabled: bool = false  # Changed default to false
@export var auto_launch_interval: float = 0.025
var auto_launch_timer: float = 0.0

# Volley control - simplified
@export var continuous_fire: bool = true  # Changed default to continuous
var volley_fired: bool = false

# DEBUG CONTROL
@export var debug_enabled: bool = false

func _ready():
	parent_ship = get_parent()
	
	if parent_ship:
		sensor_system = parent_ship.get_node_or_null("SensorSystem")
		if debug_enabled:
			print("TorpedoLauncher initialized on ship: ", parent_ship.name)
	
	# Load torpedo scene if not assigned
	if not torpedo_scene:
		torpedo_scene = preload("res://Scenes/Torpedo.tscn")

func _process(delta):
	# Clean up destroyed torpedoes
	active_torpedoes = active_torpedoes.filter(func(torpedo): return is_instance_valid(torpedo))
	
	# Auto-launch logic - now controlled by BattleManager
	if auto_launch_enabled:
		if not continuous_fire and volley_fired:
			return
		
		auto_launch_timer += delta
		if auto_launch_timer >= auto_launch_interval:
			launch_at_best_target()
			auto_launch_timer = 0.0
	
	# Manual launch
	if Input.is_action_just_pressed("ui_accept"):
		launch_at_best_target()

# NEW: BattleManager interface functions
func start_battle_firing():
	"""Called by BattleManager to start torpedo barrage"""
	auto_launch_enabled = true
	volley_fired = false
	if debug_enabled:
		print("TorpedoLauncher: Battle firing started")

func stop_battle_firing():
	"""Called by BattleManager to stop torpedo barrage"""
	auto_launch_enabled = false
	if debug_enabled:
		print("TorpedoLauncher: Battle firing stopped")

func is_battle_active() -> bool:
	"""Check if we're currently in battle firing mode"""
	return auto_launch_enabled

func launch_at_best_target() -> Torpedo:
	if not sensor_system:
		return null
	
	var target = sensor_system.get_closest_enemy_ship()
	if target:
		return launch_torpedo(target)
	
	return null

func launch_torpedo(target: Node2D) -> Torpedo:
	if not can_launch():
		return null
	
	if not torpedo_scene:
		return null
		
	if not target or not is_instance_valid(target):
		return null
	
	# Create torpedo
	var torpedo = torpedo_scene.instantiate() as Torpedo
	if not torpedo:
		return null
	
	# Alternate launch sides
	var launch_side = current_launch_side
	current_launch_side *= -1
	
	# Set up torpedo
	torpedo.global_position = global_position
	torpedo.set_launcher(parent_ship)
	torpedo.set_target(target)
	torpedo.set_launch_side(launch_side)
	
	torpedoes_launched += 1
	
	# Add to scene
	get_tree().root.add_child(torpedo)
	
	# Track torpedo
	active_torpedoes.append(torpedo)
	last_launch_time = Time.get_ticks_msec() / 1000.0
	
	# Check if we've fired our max volley for single-volley mode
	if not continuous_fire and active_torpedoes.size() >= max_torpedoes:
		volley_fired = true
		if debug_enabled:
			print("Single volley complete - %d torpedoes fired" % active_torpedoes.size())
	
	return torpedo

func can_launch() -> bool:
	var current_time = Time.get_ticks_msec() / 1000.0
	var time_since_last = current_time - last_launch_time
	
	return (active_torpedoes.size() < max_torpedoes and 
			time_since_last >= launch_cooldown)

func reset_volley():
	volley_fired = false
	if debug_enabled:
		print("Volley system reset - can fire again")

func get_debug_info() -> String:
	var mode_text = "Continuous" if continuous_fire else "Single Volley"
	var battle_status = "ACTIVE" if auto_launch_enabled else "INACTIVE"
	var status_text = ""
	if not continuous_fire:
		status_text = " (Fired: %s)" % str(volley_fired)
	return "Torpedoes: %d/%d active, Mode: %s%s, Battle: %s" % [
		active_torpedoes.size(), max_torpedoes, mode_text, status_text, battle_status
	]

# NEW: Additional interface for BattleManager
func get_active_torpedo_count() -> int:
	return active_torpedoes.size()

func get_max_torpedo_count() -> int:
	return max_torpedoes

func set_launch_rate(new_interval: float):
	auto_launch_interval = new_interval

func force_stop_all():
	"""Emergency stop all torpedo launching"""
	auto_launch_enabled = false
	volley_fired = true

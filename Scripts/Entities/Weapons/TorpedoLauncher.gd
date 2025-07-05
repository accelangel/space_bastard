# Scripts/Entities/Weapons/TorpedoLauncher.gd - SIMPLIFIED VERSION
extends Node2D
class_name TorpedoLauncher

@export var torpedo_scene: PackedScene
@export var launch_cooldown: float = 0.05  # Seconds between launches
@export var max_torpedoes: int = 100       # Max active torpedoes

var active_torpedoes: Array[Torpedo] = []
var last_launch_time: float = 0.0
var parent_ship: Node2D
var sensor_system: SensorSystem

# Alternating launch system
var current_launch_side: int = 1  # 1 for right, -1 for left
var torpedoes_launched: int = 0

# Auto-launch for testing
@export var auto_launch_enabled: bool = true
@export var auto_launch_interval: float = 3.0
var auto_launch_timer: float = 0.0

func _ready():
	parent_ship = get_parent()
	
	if parent_ship:
		sensor_system = parent_ship.get_node_or_null("SensorSystem")
		print("TorpedoLauncher initialized on ship: ", parent_ship.name)
	
	# Load torpedo scene if not assigned
	if not torpedo_scene:
		torpedo_scene = preload("res://Scenes/Torpedo.tscn")

func _process(delta):
	# Clean up destroyed torpedoes
	active_torpedoes = active_torpedoes.filter(func(torpedo): return is_instance_valid(torpedo))
	
	# Auto-launch logic
	if auto_launch_enabled:
		auto_launch_timer += delta
		if auto_launch_timer >= auto_launch_interval:
			launch_at_best_target()
			auto_launch_timer = 0.0
	
	# Manual launch
	if Input.is_action_just_pressed("launch_torpedo"):
		launch_at_best_target()

func launch_at_best_target() -> Torpedo:
	if not sensor_system:
		print("TorpedoLauncher: No sensor system available")
		return null
	
	var target = sensor_system.get_closest_enemy_ship()
	if target:
		return launch_torpedo(target)
	
	return null

func launch_torpedo(target: Node2D) -> Torpedo:
	if not can_launch():
		return null
	
	if not torpedo_scene or not target or not is_instance_valid(target):
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
	
	print("Launched torpedo #", torpedoes_launched, " at ", target.name)
	
	return torpedo

func can_launch() -> bool:
	var current_time = Time.get_ticks_msec() / 1000.0
	var time_since_last = current_time - last_launch_time
	
	return (active_torpedoes.size() < max_torpedoes and 
			time_since_last >= launch_cooldown)

func get_debug_info() -> String:
	return "Torpedoes: %d/%d active" % [active_torpedoes.size(), max_torpedoes]

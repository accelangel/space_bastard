# Enhanced TorpedoLauncher.gd with alternating launch sides
extends Node2D
class_name TorpedoLauncher

@export var torpedo_scene: PackedScene
@export var launch_cooldown: float = 0.05  # Seconds between launches
@export var max_torpedoes: int = 100       # Max active torpedoes

var active_torpedoes: Array[Torpedo] = []
var last_launch_time: float = 0.0
var parent_ship: Node2D

# ALTERNATING LAUNCH SYSTEM
var current_launch_side: int = 1  # 1 for right, -1 for left
var torpedoes_launched: int = 0   # Track total launched for alternating

# Get meters_per_pixel directly from WorldSettings singleton
var meters_per_pixel: float:
	get:
		return WorldSettings.meters_per_pixel

func _ready():
	parent_ship = get_parent()
	print("TorpedoLauncher initialized with scale: ", meters_per_pixel, " m/px from WorldSettings")
	print("  Launch system: Alternating lateral launches")

func _process(_delta):
	# Clean up destroyed torpedoes
	active_torpedoes = active_torpedoes.filter(func(torpedo): return is_instance_valid(torpedo))
	
	# Auto-launch for testing (remove this for player control)
	if Input.is_action_just_pressed("launch_torpedo"):
		var targets = get_tree().get_nodes_in_group("enemy_ships")
		if targets.size() > 0:
			launch_torpedo(targets[0])

func launch_torpedo(target: Node2D) -> Torpedo:
	if not can_launch():
		print("Cannot launch: cooldown or max torpedoes reached")
		return null
	
	if not torpedo_scene:
		push_error("No torpedo scene assigned to launcher!")
		return null
	
	# Create torpedo instance
	var torpedo = torpedo_scene.instantiate() as Torpedo
	if not torpedo:
		push_error("Torpedo scene must have Torpedo script!")
		return null
	
	# ALTERNATING LAUNCH SIDE LOGIC
	# Alternate sides with each launch to prevent collisions
	var launch_side = current_launch_side
	current_launch_side *= -1  # Flip for next launch
	
	var side_name = "RIGHT" if launch_side > 0 else "LEFT"
	
	# Set up the torpedo BEFORE adding to scene tree
	torpedo.global_position = global_position
	torpedo.set_launcher(parent_ship)
	torpedo.set_target(target)
	torpedo.set_meters_per_pixel(meters_per_pixel)
	torpedo.set_launch_side(launch_side)  # NEW: Set which side to launch toward
	
	var parent_name: String = "None"
	if parent_ship != null:
		parent_name = parent_ship.name
	
	var target_name: String = "None"
	if target != null:
		target_name = target.name
	
	torpedoes_launched += 1
	
	print("=== LAUNCHING TORPEDO #", torpedoes_launched, " ===")
	print("  Launcher position: ", global_position)
	print("  Parent ship: ", parent_name)
	print("  Target: ", target_name)
	print("  Launch side: ", side_name)
	print("  World scale: ", meters_per_pixel, " m/pixel")
	print("  Distance to target: ", global_position.distance_to(target.global_position) * meters_per_pixel, " meters")
	print("  Next torpedo will launch: ", "LEFT" if current_launch_side < 0 else "RIGHT")
	print("==================================")
	
	# Add to scene tree (triggers _ready())
	get_tree().root.add_child(torpedo)
	
	# Track the torpedo
	active_torpedoes.append(torpedo)
	last_launch_time = get_current_time()
	
	print("Torpedo launched! Active: ", active_torpedoes.size(), "/", max_torpedoes)
	return torpedo

func can_launch() -> bool:
	var current_time = get_current_time()
	var time_since_last = current_time - last_launch_time
	
	return (active_torpedoes.size() < max_torpedoes and 
			time_since_last >= launch_cooldown)

func get_active_torpedo_count() -> int:
	return active_torpedoes.size()

func get_current_time() -> float:
	return Time.get_ticks_msec() / 1000.0

# Optional: Reset alternating pattern (useful for testing)
func reset_launch_pattern():
	current_launch_side = 1
	torpedoes_launched = 0
	print("Launch pattern reset - next torpedo will launch RIGHT")

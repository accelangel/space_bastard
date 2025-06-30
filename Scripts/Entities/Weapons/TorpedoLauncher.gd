extends Node2D
class_name TorpedoLauncher

@export var torpedo_scene: PackedScene
@export var launch_cooldown: float = 0.05  # Seconds between launches
@export var max_torpedoes: int = 100       # Max active torpedoes

var active_torpedoes: Array[Torpedo] = []
var last_launch_time: float = 0.0
var parent_ship: Node2D

# Get meters_per_pixel directly from WorldSettings singleton
var meters_per_pixel: float:
	get:
		return WorldSettings.meters_per_pixel

func _ready():
	parent_ship = get_parent()
	print("TorpedoLauncher initialized with scale: ", meters_per_pixel, " m/px from WorldSettings")

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
	
	# Set up the torpedo BEFORE adding to scene tree
	# This ensures _ready() is called with correct data
	torpedo.global_position = global_position
	torpedo.set_launcher(parent_ship)
	torpedo.set_target(target)
	torpedo.set_meters_per_pixel(meters_per_pixel)  # Pass current WorldSettings value
	
	print("=== LAUNCHING TORPEDO ===")
	print("  Launcher position: ", global_position)
	print("  Parent ship: ", parent_ship.name if parent_ship != null else "None")
	print("  Target: ", target.name if target != null else "None")
	print("  World scale: ", meters_per_pixel, " m/pixel")
	print("  Distance to target: ", global_position.distance_to(target.global_position) * meters_per_pixel, " meters")
	print("========================")
	
	# NOW add to scene tree (this triggers _ready())
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

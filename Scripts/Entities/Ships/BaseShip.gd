# Scripts/Entities/Ships/BaseShip.gd
extends Node2D
class_name BaseShip

# Common ship properties
@export var acceleration_gs: float = 0.35

var acceleration_mps2: float
var velocity_mps: Vector2 = Vector2.ZERO
var ship_id: String

# Movement direction (can be overridden by subclasses)
var movement_direction: Vector2 = Vector2(0, 1)

# Get meters_per_pixel from WorldSettings singleton
var meters_per_pixel: float:
	get:
		return WorldSettings.meters_per_pixel

func _ready():
	# Generate unique ship ID
	ship_id = name + "_" + str(get_instance_id())
	
	# Convert Gs to m/s²
	acceleration_mps2 = acceleration_gs * 9.81
	
	# Register with ShipManager
	if has_node("/root/ShipManager"):
		get_node("/root/ShipManager").register_ship(self)
	
	print("BaseShip initialized: ", ship_id)
	print("  Using meters_per_pixel from WorldSettings: ", meters_per_pixel)

# Override in subclasses for specific ship behavior
func get_ship_type() -> String:
	return "BaseShip"

# Common method to get current velocity
func get_velocity_mps() -> Vector2:
	return velocity_mps

# Common method to set movement parameters
func set_movement_direction(new_direction: Vector2):
	movement_direction = new_direction.normalized()

func set_acceleration(gs: float):
	acceleration_gs = gs
	acceleration_mps2 = acceleration_gs * 9.81

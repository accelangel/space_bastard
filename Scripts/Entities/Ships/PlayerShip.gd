# Scripts/Entities/Ships/PlayerShip.gd
extends BaseShip
class_name PlayerShip

# Player-specific properties
@export var rotation_speed: float = 2.0

func _ready():
	# Call parent _ready() first
	super._ready()
	
	# Player ships don't move automatically
	movement_direction = Vector2.ZERO
	
	print("=== PLAYER SHIP INITIALIZED ===")
	print("  Ship ID: ", ship_id)
	print("  Position: ", global_position)
	print("===============================")

func _physics_process(delta):
	# Player ships will be controlled differently
	# For now, just stay stationary
	pass

# Override the base class method
func get_ship_type() -> String:
	return "PlayerShip"

# Scripts/Systems/WorldSettings.gd - CLEANED VERSION
extends Node

var meters_per_pixel := 0.25
var map_size_pixels := Vector2(131072, 73728)
var map_size_meters := meters_per_pixel * map_size_pixels

# DEBUG CONTROL
@export var debug_enabled: bool = false

func _ready():
	if debug_enabled:
		print("WorldSettings initialized:")
		print("  Meters per pixel: ", meters_per_pixel)
		print("  Map size (pixels): ", map_size_pixels)
		print("  Map size (meters): ", map_size_meters)
	else:
		print("WorldSettings initialized")

# Scripts/Systems/Worl Settings.gd
extends Node

var meters_per_pixel := 0.25  # Fixed to match your design document
var map_size_pixels := Vector2(131072, 73728)
var map_size_meters := meters_per_pixel * map_size_pixels

func _ready():
	print("WorldSettings initialized:")
	print("  Meters per pixel: ", meters_per_pixel)
	print("  Map size (pixels): ", map_size_pixels)
	print("  Map size (meters): ", map_size_meters)

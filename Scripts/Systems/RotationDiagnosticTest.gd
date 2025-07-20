# Scripts/Systems/RotationDiagnosticTest.gd
# Add this to a Node in your scene to test the rotation fix
extends Node

func _ready():
	print("\n" + "=".repeat(60))
	print("=== ROTATION VALUE DIAGNOSTIC TEST ===")
	print("=".repeat(60))
	
	# The suspicious value we've been seeing
	var suspicious_value = 59.22
	
	# Known max_rotation_rate from torpedo
	var max_rotation_deg = 1080.0
	var max_rotation_rad = deg_to_rad(max_rotation_deg)
	
	print("\nKNOWN VALUES:")
	print("  Suspicious rotation: %.2f rad/s (%.1f°/s)" % [suspicious_value, rad_to_deg(suspicious_value)])
	print("  Max rotation rate: %.2f rad/s (%.1f°/s)" % [max_rotation_rad, max_rotation_deg])
	print("  PI: %.6f" % PI)
	
	# Check various relationships
	print("\nRELATIONSHIPS:")
	print("  59.22 / PI = %.2f" % (suspicious_value / PI))
	print("  59.22 / max_rotation = %.2f" % (suspicious_value / max_rotation_rad))
	print("  59.22 / (PI * PI) = %.2f" % (suspicious_value / (PI * PI)))
	
	# Check if it's a multiple of common values
	print("\nCHECKING MULTIPLICATIONS:")
	print("  PI * max_rotation = %.2f" % (PI * max_rotation_rad))
	print("  max_rotation * PI = %.2f" % (max_rotation_rad * PI))
	
	# The smoking gun
	print("\n!!! DIAGNOSIS !!!")
	print("The shader is clamping rotation to ±PI (±3.14159 rad)")
	print("Then the result is being multiplied by max_rotation (18.85 rad/s)")
	print("3.14159 * 18.85 = %.2f" % (PI * max_rotation_rad))
	print("This matches our suspicious value of 59.22!")
	
	print("\nTHE PROBLEM:")
	print("In the shader, rotation is clamped to ±PI but then stored as:")
	print("  rotation_rate * max_rotation")
	print("When it should just be stored as:")
	print("  rotation_rate (already in rad/s)")
	
	print("\nEXPECTED BEHAVIOR AFTER FIX:")
	print("- Rotation values should be between -%.2f and %.2f rad/s" % [max_rotation_rad, max_rotation_rad])
	print("- This is between -%.1f°/s and %.1f°/s" % [max_rotation_deg, max_rotation_deg])
	print("- No more 59.22 values!")
	
	print("=".repeat(60))
	print("\n")
	
	# Wait a bit then fire a test torpedo
	await get_tree().create_timer(2.0).timeout
	print("Firing test torpedo in 3 seconds...")
	await get_tree().create_timer(3.0).timeout
	fire_test_torpedo()

func fire_test_torpedo():
	print("\n=== FIRING TEST TORPEDO ===")
	
	# Find player ship and enemy ship
	var player_ships = get_tree().get_nodes_in_group("player_ships")
	var enemy_ships = get_tree().get_nodes_in_group("enemy_ships")
	
	if player_ships.is_empty() or enemy_ships.is_empty():
		print("ERROR: Cannot find ships for test!")
		return
	
	var player = player_ships[0]
	var enemy = enemy_ships[0]
	
	# Get torpedo launcher
	var launcher = player.get_node_or_null("TorpedoLauncher")
	if not launcher:
		print("ERROR: No torpedo launcher found!")
		return
	
	# Fire single torpedo
	print("Firing straight torpedo at enemy...")
	launcher.use_straight_trajectory = true
	launcher.use_multi_angle_trajectory = false
	launcher.use_simultaneous_impact = false
	launcher.fire_torpedo(enemy, 1)
	
	print("Watch the console for [TORPEDO CONTROL] messages.")
	print("After fix, rotation should be ≤18.85 rad/s, not 59.22!")
	print("===================================\n")

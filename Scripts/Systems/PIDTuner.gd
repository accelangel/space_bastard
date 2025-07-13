# Scripts/Systems/PIDTuner.gd - Automated PID Tuning System
extends Node
# Don't use class_name to avoid collision with autoload singleton name
# Register this as an autoload with the name "TunerSystem"

# Tuning state
enum TuningPhase {
	IDLE,
	TUNING_STRAIGHT,
	TUNING_MULTI_ANGLE,
	TUNING_SIMULTANEOUS,
	COMPLETE
}

var current_phase: TuningPhase = TuningPhase.IDLE
var tuning_active: bool = false

# Ship references and positions
var player_ship: Node2D
var enemy_ship: Node2D
const PLAYER_START_POS = Vector2(-64000, 35500)
const PLAYER_START_ROT = 0.785398  # 45 degrees
const ENEMY_START_POS = Vector2(55000, -28000)
const ENEMY_START_ROT = -2.35619  # -135 degrees

# Cycle management
var current_cycle: int = 0
var consecutive_perfect_cycles: int = 0
const REQUIRED_PERFECT_CYCLES: int = 50
var cycle_start_time: float = 0.0
var tuning_start_time: float = 0.0

# Torpedo tracking
var active_torpedoes: Array = []
var cycle_hits: int = 0
var cycle_misses: int = 0
var cycle_miss_distances: Array = []

# Current PID gains being tested
var current_gains: Dictionary = {
	"straight": {"kp": 5.0, "ki": 0.5, "kd": 2.0},
	"multi_angle": {"kp": 5.0, "ki": 0.5, "kd": 2.0},
	"simultaneous": {"kp": 5.0, "ki": 0.5, "kd": 2.0}
}

# Gradient descent parameters
var learning_rate: float = 0.05
var gradient_epsilon: float = 0.01  # 1% perturbation
var best_cost: float = INF
var gradient_history: Array = []

# System references
var battle_manager: BattleManager
var torpedo_launcher: Node2D

# Timing
var state_timer: float = 0.0
var next_cycle_delay: float = 2.0

# State machine
enum CycleState {
	WAITING,
	RESETTING,
	FIRING,
	TRACKING,
	ANALYZING
}
var cycle_state: CycleState = CycleState.WAITING

func _ready():
	set_process(false)
	print("PIDTuner singleton ready - Press SPACE to start tuning")

func _process(delta):
	if not tuning_active:
		return
	
	# Debug print every second
	if Engine.get_physics_frames() % 60 == 0:  # Print once per second
		var state_name = "UNKNOWN"
		match cycle_state:
			CycleState.WAITING: state_name = "WAITING"
			CycleState.RESETTING: state_name = "RESETTING"
			CycleState.FIRING: state_name = "FIRING"
			CycleState.TRACKING: state_name = "TRACKING"
			CycleState.ANALYZING: state_name = "ANALYZING"
		
		print("[PIDTuner] _process running, state: %s, timer: %.1f" % [state_name, state_timer])
	
	state_timer += delta
	
	match cycle_state:
		CycleState.WAITING:
			if state_timer >= next_cycle_delay:
				start_new_cycle()
		
		CycleState.RESETTING:
			# Give physics a frame to settle
			if state_timer >= 0.1:
				fire_torpedo_volley()
		
		CycleState.FIRING:
			# Wait for launcher to process
			if state_timer >= 0.2:
				cycle_state = CycleState.TRACKING
				state_timer = 0.0
		
		CycleState.TRACKING:
			# Check if all torpedoes have resolved
			if active_torpedoes.is_empty():
				analyze_cycle_results()
		
		CycleState.ANALYZING:
			# Analysis complete, wait for next cycle
			cycle_state = CycleState.WAITING
			state_timer = 0.0

func start_tuning():
	print("\n[PIDTuner] start_tuning() called!")
	
	if tuning_active:
		print("[PIDTuner] Already tuning, returning")
		return
	
	print("\n" + "=".repeat(40))
	print("    PID AUTO-TUNING ACTIVE")
	print("    Phase 1/3: STRAIGHT TRAJECTORY")
	print("    Press SPACE to stop")
	print("=".repeat(40))
	
	tuning_active = true
	current_phase = TuningPhase.TUNING_STRAIGHT
	current_cycle = 0
	consecutive_perfect_cycles = 0
	tuning_start_time = Time.get_ticks_msec() / 1000.0
	
	print("[PIDTuner] Finding game objects...")
	# Find game objects
	find_game_objects()
	
	print("[PIDTuner] Disabling game systems...")
	# Disable interfering systems
	disable_game_systems()
	
	print("[PIDTuner] Starting processing...")
	# Start processing
	set_process(true)
	
	print("[PIDTuner] Starting first cycle...")
	# Start first cycle
	start_new_cycle()

func stop_tuning():
	print("[PIDTuner] stop_tuning() called!")
	if not tuning_active:
		print("[PIDTuner] Not currently tuning, returning")
		return
	
	print("\n" + "=".repeat(40))
	print("    PID TUNING STOPPED BY USER")
	print("=".repeat(40))
	
	tuning_active = false
	current_phase = TuningPhase.IDLE
	set_process(false)
	
	print("[PIDTuner] Re-enabling game systems...")
	# Re-enable game systems
	enable_game_systems()
	
	print("[PIDTuner] Cleaning up field...")
	# Clean up any remaining torpedoes
	cleanup_field()
	
	print("[PIDTuner] Tuning stopped")

func find_game_objects():
	print("[PIDTuner] Looking for ships...")
	
	# Find ships
	var player_ships = get_tree().get_nodes_in_group("player_ships")
	print("[PIDTuner] Found %d player ships" % player_ships.size())
	if player_ships.size() > 0:
		player_ship = player_ships[0]
		print("[PIDTuner] Player ship: %s" % player_ship.name)
		torpedo_launcher = player_ship.get_node_or_null("TorpedoLauncher")
		if torpedo_launcher:
			print("[PIDTuner] Found torpedo launcher")
		else:
			print("[PIDTuner] ERROR: No torpedo launcher on player ship!")
	else:
		print("[PIDTuner] ERROR: No player ships found!")
	
	var enemy_ships = get_tree().get_nodes_in_group("enemy_ships")
	print("[PIDTuner] Found %d enemy ships" % enemy_ships.size())
	if enemy_ships.size() > 0:
		enemy_ship = enemy_ships[0]
		print("[PIDTuner] Enemy ship: %s" % enemy_ship.name)
	else:
		print("[PIDTuner] ERROR: No enemy ships found!")
	
	# Find battle manager
	var managers = get_tree().get_nodes_in_group("battle_managers")
	print("[PIDTuner] Found %d battle managers" % managers.size())
	if managers.size() > 0:
		battle_manager = managers[0]
		print("[PIDTuner] Battle manager found")
	else:
		print("[PIDTuner] WARNING: No battle manager found")
	
	if not player_ship or not enemy_ship or not torpedo_launcher:
		print("[PIDTuner] ERROR: Cannot find required game objects for tuning")
		print("  player_ship: %s" % ("Found" if player_ship else "MISSING"))
		print("  enemy_ship: %s" % ("Found" if enemy_ship else "MISSING"))
		print("  torpedo_launcher: %s" % ("Found" if torpedo_launcher else "MISSING"))
		stop_tuning()
		return
		
	print("[PIDTuner] All required objects found!")

func disable_game_systems():
	print("[PIDTuner] Disabling PDCs...")
	# Disable all PDCs
	var pdcs = get_tree().get_nodes_in_group("pdcs")
	print("[PIDTuner] Found %d PDCs to disable" % pdcs.size())
	for pdc in pdcs:
		if "enabled" in pdc:
			pdc.enabled = false
			print("[PIDTuner] Disabled PDC: %s" % (pdc.pdc_id if "pdc_id" in pdc else "unknown"))
	
	# Disable battle reports
	if battle_manager and "reports_enabled" in battle_manager:
		battle_manager.reports_enabled = false
		print("[PIDTuner] Disabled battle reports")
	
	print("[PIDTuner] Game systems disabled for tuning")

func enable_game_systems():
	# Re-enable PDCs
	var pdcs = get_tree().get_nodes_in_group("pdcs")
	for pdc in pdcs:
		if "enabled" in pdc:
			pdc.enabled = true
	
	# Re-enable battle reports
	if battle_manager and "reports_enabled" in battle_manager:
		battle_manager.reports_enabled = true

func start_new_cycle():
	print("\n[PIDTuner] Starting new cycle...")
	current_cycle += 1
	cycle_start_time = Time.get_ticks_msec() / 1000.0
	
	# Reset tracking
	active_torpedoes.clear()
	cycle_hits = 0
	cycle_misses = 0
	cycle_miss_distances.clear()
	
	# Get current trajectory type
	var trajectory_name = get_current_trajectory_name()
	
	print("\nCycle %d | Gains: Kp=%.3f, Ki=%.3f, Kd=%.3f" % [
		current_cycle,
		current_gains[trajectory_name].kp,
		current_gains[trajectory_name].ki,
		current_gains[trajectory_name].kd
	])
	
	print("Resetting positions... Firing volley...")
	reset_battle_positions()
	
	cycle_state = CycleState.RESETTING
	state_timer = 0.0

# Update the reset_battle_positions() function in PIDTuner.gd:

func reset_battle_positions():
	print("[PIDTuner] Resetting battle positions...")
	# Clean up any remaining torpedoes
	cleanup_field()
	
	# Reset player ship
	if player_ship:
		print("[PIDTuner] Resetting player ship position")
		player_ship.global_position = PLAYER_START_POS
		player_ship.rotation = PLAYER_START_ROT
		if "velocity_mps" in player_ship:
			player_ship.velocity_mps = Vector2.ZERO
		# Call ship's reset function if it has one
		if player_ship.has_method("reset_for_pid_cycle"):
			player_ship.reset_for_pid_cycle()
		print("  Position: %s, Rotation: %.2f" % [player_ship.global_position, player_ship.rotation])
	else:
		print("[PIDTuner] ERROR: No player ship to reset!")
	
	# Reset enemy ship
	if enemy_ship:
		print("[PIDTuner] Resetting enemy ship position")
		enemy_ship.global_position = ENEMY_START_POS
		enemy_ship.rotation = ENEMY_START_ROT
		if "velocity_mps" in enemy_ship:
			enemy_ship.velocity_mps = Vector2.ZERO
		# Call ship's reset function if it has one
		if enemy_ship.has_method("reset_for_pid_cycle"):
			enemy_ship.reset_for_pid_cycle()
		print("  Position: %s, Rotation: %.2f" % [enemy_ship.global_position, enemy_ship.rotation])
	else:
		print("[PIDTuner] ERROR: No enemy ship to reset!")

func cleanup_field():
	print("[PIDTuner] Cleaning up field...")
	# Remove all torpedoes
	var torpedoes = get_tree().get_nodes_in_group("torpedoes")
	print("[PIDTuner] Found %d torpedoes to remove" % torpedoes.size())
	for torpedo in torpedoes:
		if is_instance_valid(torpedo):
			torpedo.queue_free()
	
	# Remove all bullets (shouldn't be any, but just in case)
	var bullets = get_tree().get_nodes_in_group("bullets")
	print("[PIDTuner] Found %d bullets to remove" % bullets.size())
	for bullet in bullets:
		if is_instance_valid(bullet):
			bullet.queue_free()

func fire_torpedo_volley():
	print("[PIDTuner] fire_torpedo_volley() called")
	print("Firing volley...")
	
	if not torpedo_launcher or not enemy_ship:
		print("[PIDTuner] ERROR: Missing launcher (%s) or target (%s)" % [
			"Found" if torpedo_launcher else "MISSING",
			"Found" if enemy_ship else "MISSING"
		])
		return
	
	# Set the correct trajectory type on the launcher
	match current_phase:
		TuningPhase.TUNING_STRAIGHT:
			torpedo_launcher.use_straight_trajectory = true
			torpedo_launcher.use_multi_angle_trajectory = false
			torpedo_launcher.use_simultaneous_impact = false
		
		TuningPhase.TUNING_MULTI_ANGLE:
			torpedo_launcher.use_straight_trajectory = false
			torpedo_launcher.use_multi_angle_trajectory = true
			torpedo_launcher.use_simultaneous_impact = false
		
		TuningPhase.TUNING_SIMULTANEOUS:
			torpedo_launcher.use_straight_trajectory = false
			torpedo_launcher.use_multi_angle_trajectory = false
			torpedo_launcher.use_simultaneous_impact = true
	
	# Update torpedo launcher settings
	if torpedo_launcher.has_method("update_torpedo_launcher_settings"):
		torpedo_launcher.update_torpedo_launcher_settings()
	
	# Fire the volley
	torpedo_launcher.fire_torpedo(enemy_ship, 8)
	
	# Track the fired torpedoes
	await get_tree().create_timer(0.1).timeout
	var torpedoes = get_tree().get_nodes_in_group("torpedoes")
	for torpedo in torpedoes:
		if is_instance_valid(torpedo) and not torpedo in active_torpedoes:
			active_torpedoes.append(torpedo)
			# Update torpedo PID gains
			var trajectory_name = get_current_trajectory_name()
			if torpedo.has_method("update_pid_gains"):
				torpedo.update_pid_gains(current_gains[trajectory_name])
	
	cycle_state = CycleState.FIRING
	state_timer = 0.0

func get_current_trajectory_name() -> String:
	match current_phase:
		TuningPhase.TUNING_STRAIGHT:
			return "straight"
		TuningPhase.TUNING_MULTI_ANGLE:
			return "multi_angle"
		TuningPhase.TUNING_SIMULTANEOUS:
			return "simultaneous"
		_:
			return "straight"

# Called by torpedoes when they hit
func report_torpedo_hit(hit_data: Dictionary):
	if not tuning_active:
		return
	
	cycle_hits += 1
	
	# Remove from active list
	for i in range(active_torpedoes.size() - 1, -1, -1):
		if active_torpedoes[i].torpedo_id == hit_data.torpedo_id:
			active_torpedoes.remove_at(i)
			break

# Called by torpedoes when they miss
func report_torpedo_miss(miss_data: Dictionary):
	if not tuning_active:
		return
	
	cycle_misses += 1
	cycle_miss_distances.append(miss_data.closest_approach)
	
	# Remove from active list
	for i in range(active_torpedoes.size() - 1, -1, -1):
		if active_torpedoes[i].torpedo_id == miss_data.torpedo_id:
			active_torpedoes.remove_at(i)
			break

func analyze_cycle_results():
	var total_fired = cycle_hits + cycle_misses
	var hit_rate = float(cycle_hits) / float(total_fired) if total_fired > 0 else 0.0
	
	var result_str = "Result: %d/%d hits" % [cycle_hits, total_fired]
	
	# Check if perfect volley
	if cycle_hits == 8 and cycle_misses == 0:
		consecutive_perfect_cycles += 1
		result_str += " | Consecutive: %d/%d" % [consecutive_perfect_cycles, REQUIRED_PERFECT_CYCLES]
		print(result_str)
		
		# Check if phase complete
		if consecutive_perfect_cycles >= REQUIRED_PERFECT_CYCLES:
			complete_current_phase()
			return
	else:
		# Reset consecutive count
		consecutive_perfect_cycles = 0
		if cycle_misses > 0:
			var avg_miss_distance = 0.0
			for dist in cycle_miss_distances:
				avg_miss_distance += dist
			avg_miss_distance /= cycle_miss_distances.size()
			result_str += " | %d miss%s (avg: %.1fm)" % [
				cycle_misses,
				"es" if cycle_misses > 1 else "",
				avg_miss_distance
			]
		print(result_str)
		print("IMPERFECT VOLLEY - Resetting consecutive count to 0")
	
	# Apply gradient descent if not perfect
	if hit_rate < 1.0:
		apply_gradient_descent(hit_rate, cycle_miss_distances)
	
	print("Next cycle in %.0fs..." % next_cycle_delay)
	
	cycle_state = CycleState.ANALYZING
	state_timer = 0.0

func apply_gradient_descent(hit_rate: float, miss_distances: Array):
	var trajectory_name = get_current_trajectory_name()
	var gains = current_gains[trajectory_name]
	
	# Calculate cost (lower is better)
	var avg_miss_distance = 0.0
	if miss_distances.size() > 0:
		for dist in miss_distances:
			avg_miss_distance += dist
		avg_miss_distance /= miss_distances.size()
	
	var cost = (1.0 - hit_rate) * 100.0 + avg_miss_distance * 0.001
	
	# Store best cost for comparison
	if cost < best_cost:
		best_cost = cost
		print("New best cost: %.3f (hit_rate: %.1f%%, avg_miss: %.1fm)" % [
			cost, hit_rate * 100.0, avg_miss_distance
		])
	
	# Estimate gradient by perturbation
	var gradient = {"kp": 0.0, "ki": 0.0, "kd": 0.0}
	
	# This is simplified - in a real implementation, we'd test each perturbation
	# For now, use heuristics based on miss patterns
	if avg_miss_distance > 0:
		if avg_miss_distance > 100:  # Overshooting
			gradient.kp = -0.1
			gradient.kd = 0.05
		else:  # Close misses
			gradient.kp = 0.05
			gradient.ki = 0.01
	
	# Adaptive learning rate based on performance
	var adaptive_lr = learning_rate
	if hit_rate < 0.5:  # Poor performance, larger steps
		adaptive_lr *= 2.0
	elif hit_rate > 0.9:  # Good performance, smaller steps
		adaptive_lr *= 0.5
	
	# Update gains
	gains.kp += gradient.kp * adaptive_lr
	gains.ki += gradient.ki * adaptive_lr
	gains.kd += gradient.kd * adaptive_lr
	
	# Clamp to reasonable ranges
	gains.kp = clamp(gains.kp, 0.1, 10.0)
	gains.ki = clamp(gains.ki, 0.01, 2.0)
	gains.kd = clamp(gains.kd, 0.01, 5.0)
	
	print("Gradient: ∇[%.3f, %.3f, %.3f] | LR: %.2f | Cost: %.3f" % [
		gradient.kp, gradient.ki, gradient.kd, adaptive_lr, cost
	])

func complete_current_phase():
	var trajectory_name = get_current_trajectory_name()
	print("\n" + "=".repeat(40))
	print("    PHASE COMPLETE: %s" % trajectory_name.to_upper())
	print("    Final gains: Kp=%.3f, Ki=%.3f, Kd=%.3f" % [
		current_gains[trajectory_name].kp,
		current_gains[trajectory_name].ki,
		current_gains[trajectory_name].kd
	])
	print("=".repeat(40))
	
	# Move to next phase
	match current_phase:
		TuningPhase.TUNING_STRAIGHT:
			current_phase = TuningPhase.TUNING_MULTI_ANGLE
			print("\n    Phase 2/3: MULTI-ANGLE TRAJECTORY")
		
		TuningPhase.TUNING_MULTI_ANGLE:
			current_phase = TuningPhase.TUNING_SIMULTANEOUS
			print("\n    Phase 3/3: SIMULTANEOUS IMPACT")
		
		TuningPhase.TUNING_SIMULTANEOUS:
			complete_tuning()
			return
	
	# Reset for next phase
	current_cycle = 0
	consecutive_perfect_cycles = 0
	
	# Continue with next phase
	cycle_state = CycleState.WAITING
	state_timer = 0.0

func complete_tuning():
	tuning_active = false
	current_phase = TuningPhase.COMPLETE
	set_process(false)
	
	var total_time = (Time.get_ticks_msec() / 1000.0) - tuning_start_time
	var minutes = int(total_time / 60.0)
	var seconds = int(total_time) % 60
	
	print("\n" + "=".repeat(40))
	print("    PID TUNING COMPLETE")
	print("=".repeat(40))
	print("Add these values to Torpedo.gd:\n")
	print("const PID_VALUES = {")
	print('    "straight": {"kp": %.3f, "ki": %.3f, "kd": %.3f},' % [
		current_gains.straight.kp, current_gains.straight.ki, current_gains.straight.kd
	])
	print('    "multi_angle": {"kp": %.3f, "ki": %.3f, "kd": %.3f},' % [
		current_gains.multi_angle.kp, current_gains.multi_angle.ki, current_gains.multi_angle.kd
	])
	print('    "simultaneous": {"kp": %.3f, "ki": %.3f, "kd": %.3f}' % [
		current_gains.simultaneous.kp, current_gains.simultaneous.ki, current_gains.simultaneous.kd
	])
	print("}\n")
	print("Total cycles: %d" % current_cycle)
	print("Total time: %dm %ds" % [minutes, seconds])
	print("Perfect streak achieved: %d consecutive volleys per mode" % REQUIRED_PERFECT_CYCLES)
	print("=".repeat(40))
	
	# Re-enable game systems
	enable_game_systems()

# Public interface for external queries
func get_pid_gains(trajectory_type: String) -> Dictionary:
	if trajectory_type in current_gains:
		return current_gains[trajectory_type]
	return {}

func is_tuning_active() -> bool:
	return tuning_active

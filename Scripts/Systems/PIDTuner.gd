# Scripts/Systems/PIDTuner.gd - Refactored with Immediate State
extends Node
# Register this as an autoload with the name "TunerSystem"

# Tuning state
enum TuningPhase {
	IDLE,
	TUNING_STRAIGHT,
	TUNING_MULTI_ANGLE,
	TUNING_SIMULTANEOUS,
	COMPLETE
}

# Simplified state machine
enum TuningState {
	IDLE,
	WAITING_BETWEEN_CYCLES,
	PREPARING_CYCLE,
	TORPEDOES_ACTIVE,
	ANALYZING_RESULTS
}

var current_phase: TuningPhase = TuningPhase.IDLE
var tuning_active: bool = false
var tuning_state: TuningState = TuningState.IDLE
var state_timer: float = 0.0

# Ship references and positions
var player_ship: Node2D
var enemy_ship: Node2D
var torpedo_launcher: Node2D

const PLAYER_START_POS = Vector2(-64000, 35500)
const PLAYER_START_ROT = 0.785398  # 45 degrees
const ENEMY_START_POS = Vector2(60000, -33000)  # Actual enemy position from scene
const ENEMY_START_ROT = -2.35619  # -135 degrees

# Cycle management
var current_cycle: int = 0
var consecutive_perfect_cycles: int = 0
const REQUIRED_PERFECT_CYCLES: int = 50
var cycle_start_time: float = 0.0
var tuning_start_time: float = 0.0
var next_cycle_delay: float = 2.0

# Current PID gains being tested
var current_gains: Dictionary = {
	"straight": {"kp": 5.0, "ki": 0.5, "kd": 2.0},
	"multi_angle": {"kp": 5.0, "ki": 0.5, "kd": 2.0},
	"simultaneous": {"kp": 5.0, "ki": 0.5, "kd": 2.0}
}

# Gradient descent parameters
var learning_rate: float = 0.05
var best_cost: float = INF

# PID Observer
var pid_observer: PIDTuningObserver

# Debug
@export var debug_enabled: bool = false

func _ready():
	set_process(false)
	
	# Subscribe to mode changes
	GameMode.mode_changed.connect(_on_mode_changed)
	
	# Create observer
	pid_observer = PIDTuningObserver.new()
	pid_observer.name = "PIDTuningObserver"
	add_child(pid_observer)
	
	print("PIDTuner singleton ready")

func _on_mode_changed(new_mode: GameMode.Mode):
	if new_mode == GameMode.Mode.PID_TUNING:
		start_tuning()
	else:
		stop_tuning()

func start_tuning():
	if tuning_active:
		return
	
	print("\n" + "=".repeat(40))
	print("    PID AUTO-TUNING ACTIVE")
	print("    Phase 1/3: STRAIGHT TRAJECTORY")
	print("    Press SPACE to stop")
	print("=".repeat(40))
	
	tuning_active = true
	tuning_state = TuningState.WAITING_BETWEEN_CYCLES
	current_phase = TuningPhase.TUNING_STRAIGHT
	current_cycle = 0
	consecutive_perfect_cycles = 0
	tuning_start_time = Time.get_ticks_msec() / 1000.0
	state_timer = 0.0
	
	# Find game objects
	find_game_objects()
	
	# Start processing
	set_process(true)

func stop_tuning():
	if not tuning_active:
		return
	
	print("\n" + "=".repeat(40))
	print("    PID TUNING STOPPED")
	print("=".repeat(40))
	
	tuning_active = false
	current_phase = TuningPhase.IDLE
	tuning_state = TuningState.IDLE
	set_process(false)
	
	# Clean up any remaining torpedoes
	cleanup_field()

func emergency_stop():
	"""Called by GameMode when cleaning up PID tuning mode"""
	stop_tuning()

func find_game_objects():
	# Find ships
	var player_ships = get_tree().get_nodes_in_group("player_ships")
	if player_ships.size() > 0:
		player_ship = player_ships[0]
		torpedo_launcher = player_ship.get_node_or_null("TorpedoLauncher")
		if torpedo_launcher:
			print("Found torpedo launcher on player ship")
		else:
			print("ERROR: No torpedo launcher on player ship!")
	else:
		print("ERROR: No player ships found!")
	
	var enemy_ships = get_tree().get_nodes_in_group("enemy_ships")
	if enemy_ships.size() > 0:
		enemy_ship = enemy_ships[0]
		print("Found enemy ship")
	else:
		print("ERROR: No enemy ships found!")
	
	if not player_ship or not enemy_ship or not torpedo_launcher:
		print("ERROR: Cannot find required game objects for tuning")
		stop_tuning()
		return

func _process(delta):
	if not tuning_active:
		return
	
	state_timer += delta
	
	match tuning_state:
		TuningState.WAITING_BETWEEN_CYCLES:
			if state_timer >= next_cycle_delay:
				prepare_new_cycle()
		
		TuningState.PREPARING_CYCLE:
			# Give physics a moment to settle
			if state_timer >= 0.5:
				fire_torpedo_volley()
				tuning_state = TuningState.TORPEDOES_ACTIVE
				state_timer = 0.0
		
		TuningState.TORPEDOES_ACTIVE:
			# Use immediate state query instead of tracking
			var active_torpedo_count = 0
			var torpedoes = get_tree().get_nodes_in_group("torpedoes")
			
			for torpedo in torpedoes:
				if is_instance_valid(torpedo) and not torpedo.get("marked_for_death"):
					active_torpedo_count += 1
			
			# All torpedoes resolved
			if active_torpedo_count == 0 and state_timer > 1.0:  # Min 1 second
				analyze_cycle_results()
		
		TuningState.ANALYZING_RESULTS:
			# Analysis complete, wait for next cycle
			tuning_state = TuningState.WAITING_BETWEEN_CYCLES
			state_timer = 0.0

func prepare_new_cycle():
	current_cycle += 1
	cycle_start_time = Time.get_ticks_msec() / 1000.0
	
	# Get current trajectory type
	var trajectory_name = get_current_trajectory_name()
	
	print("\nCycle %d | Gains: Kp=%.3f, Ki=%.3f, Kd=%.3f" % [
		current_cycle,
		current_gains[trajectory_name].kp,
		current_gains[trajectory_name].ki,
		current_gains[trajectory_name].kd
	])
	
	print("Resetting positions... Firing volley...")
	
	# Reset observer
	pid_observer.reset_cycle_data()
	
	# Clean field and reset positions
	cleanup_field()
	reset_battle_positions()
	
	tuning_state = TuningState.PREPARING_CYCLE
	state_timer = 0.0

func reset_battle_positions():
	# Force reset ship positions
	if player_ship:
		player_ship.set_deferred("global_position", PLAYER_START_POS)
		player_ship.set_deferred("rotation", PLAYER_START_ROT)
		if player_ship.has_method("force_reset_physics"):
			player_ship.call_deferred("force_reset_physics")
	
	if enemy_ship:
		enemy_ship.set_deferred("global_position", ENEMY_START_POS)
		enemy_ship.set_deferred("rotation", ENEMY_START_ROT)
		if enemy_ship.has_method("force_reset_physics"):
			enemy_ship.call_deferred("force_reset_physics")
	
	# Reset torpedo tubes
	if torpedo_launcher and torpedo_launcher.has_method("reset_all_tubes"):
		torpedo_launcher.reset_all_tubes()

func cleanup_field():
	# Remove all torpedoes
	var torpedoes = get_tree().get_nodes_in_group("torpedoes")
	for torpedo in torpedoes:
		if is_instance_valid(torpedo):
			torpedo.queue_free()
	
	# Remove all bullets (shouldn't be any, but just in case)
	var bullets = get_tree().get_nodes_in_group("bullets")
	for bullet in bullets:
		if is_instance_valid(bullet):
			bullet.queue_free()

func fire_torpedo_volley():
	if not torpedo_launcher or not enemy_ship:
		print("ERROR: Missing launcher or target")
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
	
	# Fire the volley
	torpedo_launcher.fire_torpedo(enemy_ship, 8)
	
	# Update torpedo PID gains after a short delay to ensure they're spawned
	await get_tree().create_timer(0.1).timeout
	var torpedoes = get_tree().get_nodes_in_group("torpedoes")
	var trajectory_name = get_current_trajectory_name()
	for torpedo in torpedoes:
		if is_instance_valid(torpedo) and torpedo.has_method("update_pid_gains"):
			torpedo.update_pid_gains(current_gains[trajectory_name])

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

func analyze_cycle_results():
	# Get results from observer
	var results = pid_observer.get_cycle_results()
	
	var result_str = "Result: %d/%d hits" % [results.hits, results.total_fired]
	
	# Check if perfect volley
	if results.hits == 8 and results.misses == 0:
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
		result_str += " | IMPERFECT - Resetting count"
		
		# Show miss reasons
		if results.misses > 0:
			for reason in results.miss_reasons:
				result_str += "\n  %s: %d" % [reason, results.miss_reasons[reason]]
		
		print(result_str)
		
		# Apply gradient descent
		apply_gradient_descent(results)
	
	print("Next cycle in %.0fs..." % next_cycle_delay)
	
	tuning_state = TuningState.ANALYZING_RESULTS
	state_timer = 0.0

func apply_gradient_descent(results: Dictionary):
	var trajectory_name = get_current_trajectory_name()
	var gains = current_gains[trajectory_name]
	
	# Calculate cost (lower is better)
	var cost = (1.0 - results.hit_rate) * 100.0
	
	# Store best cost for comparison
	if cost < best_cost:
		best_cost = cost
		print("New best cost: %.3f (hit_rate: %.1f%%)" % [cost, results.hit_rate * 100.0])
	
	# Simple gradient estimation based on miss patterns
	var gradient = {"kp": 0.0, "ki": 0.0, "kd": 0.0}
	
	# Heuristic adjustments
	if results.misses > 0:
		if results.miss_reasons.has("overshot") or results.miss_reasons.has("missed_target"):
			gradient.kp = -0.1
			gradient.kd = 0.05
		else:
			gradient.kp = 0.05
			gradient.ki = 0.01
	
	# Adaptive learning rate
	var adaptive_lr = learning_rate
	if results.hit_rate < 0.5:
		adaptive_lr *= 2.0
	elif results.hit_rate > 0.9:
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
	tuning_state = TuningState.WAITING_BETWEEN_CYCLES
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
	
	# Return to NONE mode
	GameMode.set_mode(GameMode.Mode.NONE)

# Public interface for external queries
func get_pid_gains(trajectory_type: String) -> Dictionary:
	if trajectory_type in current_gains:
		return current_gains[trajectory_type]
	return {}

func is_tuning_active() -> bool:
	return tuning_active

# Called by torpedoes when they hit
func report_torpedo_hit(hit_data: Dictionary):
	if not tuning_active:
		return
	
	# Let observer handle the tracking
	pass

# Called by torpedoes when they miss
func report_torpedo_miss(miss_data: Dictionary):
	if not tuning_active:
		return
	
	# Let observer handle the tracking
	pass

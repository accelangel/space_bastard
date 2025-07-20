# Scripts/Systems/MPCTuner.gd - Automated MPC Tuning System
extends Node
# Register this as an autoload with the name "MPCTunerSystem"

# Tuning state
enum TuningPhase {
	IDLE,
	TUNING_STRAIGHT,
	TUNING_MULTI_ANGLE,
	TUNING_SIMULTANEOUS,
	COMPLETE
}

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
const ENEMY_START_POS = Vector2(60000, -33000)
const ENEMY_START_ROT = -2.35619  # -135 degrees

# Cycle management
var current_cycle: int = 0
var consecutive_perfect_cycles: int = 0
const REQUIRED_PERFECT_CYCLES: int = 100  # More stringent for MPC
var cycle_start_time: float = 0.0
var tuning_start_time: float = 0.0
var next_cycle_delay: float = 2.0

# MPC Template Evolution
var trajectory_templates: Dictionary = {
	"straight": [],
	"multi_angle": [],
	"simultaneous": []
}

# Cost function weights being tuned
var cost_weights: Dictionary = {
	"straight": {
		"distance": 1.0,
		"control": 0.1,
		"alignment": 0.5,
		"smoothness": 0.2
	},
	"multi_angle": {
		"distance": 1.0,
		"control": 0.1,
		"alignment": 0.5,
		"smoothness": 0.2,
		"angle_separation": 1.0
	},
	"simultaneous": {
		"distance": 1.0,
		"control": 0.1,
		"alignment": 0.5,
		"smoothness": 0.2,
		"impact_time_sync": 2.0,
		"angle_adherence": 1.0
	}
}

# Learning parameters
var learning_rate: float = 0.05
var mutation_rate: float = 0.1
var best_fitness: float = 0.0

# Evolutionary algorithm parameters
const POPULATION_SIZE: int = 50
const ELITE_COUNT: int = 10
const TOURNAMENT_SIZE: int = 3

# Performance monitoring
var tuning_metrics: Dictionary = {}
var generation_count: int = 0

# Observer for tracking torpedo performance
var mpc_observer: MPCTuningObserver

# Debug
@export var debug_enabled: bool = false

# Preload torpedo scene - we'll create this with instructions
# Comment out for now since scene doesn't exist yet
# var torpedo_mpc_scene = preload("res://Scenes/TorpedoMPC.tscn")

func _ready():
	set_process(false)
	
	# Subscribe to mode changes
	GameMode.mode_changed.connect(_on_mode_changed)
	
	# Create observer
	mpc_observer = MPCTuningObserver.new()
	mpc_observer.name = "MPCTuningObserver"
	add_child(mpc_observer)
	
	# Initialize template populations
	initialize_template_populations()
	
	print("MPCTuner singleton ready")

func _on_mode_changed(new_mode: GameMode.Mode):
	if new_mode == GameMode.Mode.MPC_TUNING:
		start_tuning()
	else:
		stop_tuning()

func initialize_template_populations():
	"""Create initial random populations of trajectory templates"""
	for trajectory_type in trajectory_templates:
		trajectory_templates[trajectory_type] = []
		
		for i in range(POPULATION_SIZE):
			var template = create_random_template(trajectory_type)
			template["id"] = "%s_%d" % [trajectory_type, i]
			template["fitness"] = 0.0
			template["success_rate"] = 0.0
			template["uses"] = 0
			trajectory_templates[trajectory_type].append(template)

func create_random_template(trajectory_type: String) -> Dictionary:
	"""Create a random trajectory template based on type"""
	var template = {
		"control_points": [],
		"phase_transitions": [],
		"parameters": {}
	}
	
	match trajectory_type:
		"straight":
			# Simple direct approach with variations
			template.parameters["thrust_factor"] = randf_range(0.7, 1.0)
			template.parameters["initial_angle_offset"] = randf_range(-10, 10)  # degrees
			template.phase_transitions = [1.0]  # No phases, just direct
			
		"multi_angle":
			# Arc approach with phases
			template.parameters["arc_factor"] = randf_range(0.2, 0.5)
			template.parameters["arc_start"] = randf_range(0.1, 0.3)
			template.parameters["arc_peak"] = randf_range(0.4, 0.6)
			template.parameters["final_approach"] = randf_range(0.8, 0.9)
			template.phase_transitions = [
				template.parameters["arc_start"],
				template.parameters["arc_peak"],
				template.parameters["final_approach"]
			]
			
		"simultaneous":
			# Fan out and converge
			template.parameters["fan_rate"] = randf_range(0.5, 1.5)
			template.parameters["fan_duration"] = randf_range(0.2, 0.4)
			template.parameters["converge_start"] = randf_range(0.6, 0.8)
			template.parameters["converge_aggression"] = randf_range(0.8, 1.2)
			template.phase_transitions = [
				template.parameters["fan_duration"],
				template.parameters["converge_start"]
			]
	
	return template

func start_tuning():
	if tuning_active:
		return
	
	print("\n" + "=".repeat(40))
	print("    MPC AUTO-TUNING ACTIVE")
	print("    Phase 1/3: STRAIGHT TRAJECTORY")
	print("    Population: %d templates" % POPULATION_SIZE)
	print("    Press SPACE to stop")
	print("=".repeat(40))
	
	tuning_active = true
	tuning_state = TuningState.WAITING_BETWEEN_CYCLES
	current_phase = TuningPhase.TUNING_STRAIGHT
	current_cycle = 0
	consecutive_perfect_cycles = 0
	generation_count = 0
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
	print("    MPC TUNING STOPPED")
	print("=".repeat(40))
	
	tuning_active = false
	current_phase = TuningPhase.IDLE
	tuning_state = TuningState.IDLE
	set_process(false)
	
	# Save best templates
	save_tuned_parameters()
	
	# Clean up
	cleanup_field()

func find_game_objects():
	# Find ships
	var player_ships = get_tree().get_nodes_in_group("player_ships")
	if player_ships.size() > 0:
		player_ship = player_ships[0]
		torpedo_launcher = player_ship.get_node_or_null("TorpedoLauncher")
	
	var enemy_ships = get_tree().get_nodes_in_group("enemy_ships")
	if enemy_ships.size() > 0:
		enemy_ship = enemy_ships[0]
	
	if not player_ship or not enemy_ship or not torpedo_launcher:
		print("ERROR: Cannot find required game objects for tuning")
		stop_tuning()

func _process(delta):
	if not tuning_active:
		return
	
	state_timer += delta
	
	match tuning_state:
		TuningState.WAITING_BETWEEN_CYCLES:
			if state_timer >= next_cycle_delay:
				prepare_new_cycle()
		
		TuningState.PREPARING_CYCLE:
			if state_timer >= 0.5:
				fire_mpc_torpedo_volley()
				tuning_state = TuningState.TORPEDOES_ACTIVE
				state_timer = 0.0
		
		TuningState.TORPEDOES_ACTIVE:
			var active_torpedo_count = 0
			var torpedoes = get_tree().get_nodes_in_group("torpedoes")
			
			for torpedo in torpedoes:
				if is_instance_valid(torpedo) and not torpedo.get("marked_for_death"):
					active_torpedo_count += 1
			
			if active_torpedo_count == 0 and state_timer > 1.0:
				analyze_cycle_results()
		
		TuningState.ANALYZING_RESULTS:
			tuning_state = TuningState.WAITING_BETWEEN_CYCLES
			state_timer = 0.0

func prepare_new_cycle():
	current_cycle += 1
	cycle_start_time = Time.get_ticks_msec() / 1000.0
	
	var trajectory_type = get_current_trajectory_name()
	
	print("\nCycle %d (Gen %d) | Type: %s | Best Fitness: %.3f" % [
		current_cycle, generation_count, trajectory_type, best_fitness
	])
	
	# Reset observer
	mpc_observer.reset_cycle_data()
	mpc_observer.set_trajectory_type(trajectory_type)
	
	# Clean field and reset
	cleanup_field()
	reset_battle_positions()
	
	tuning_state = TuningState.PREPARING_CYCLE
	state_timer = 0.0

func fire_mpc_torpedo_volley():
	if not torpedo_launcher or not enemy_ship:
		return
	
	# We need to create MPC torpedoes instead of regular ones
	# For now, we'll use the regular launcher and convert torpedoes
	# This is a temporary solution until we have the MPC torpedo scene
	
	# Set the launcher to the correct type
	var trajectory_type = get_current_trajectory_name()
	match trajectory_type:
		"straight":
			torpedo_launcher.use_straight_trajectory = true
			torpedo_launcher.use_multi_angle_trajectory = false
			torpedo_launcher.use_simultaneous_impact = false
		"multi_angle":
			torpedo_launcher.use_straight_trajectory = false
			torpedo_launcher.use_multi_angle_trajectory = true
			torpedo_launcher.use_simultaneous_impact = false
		"simultaneous":
			torpedo_launcher.use_straight_trajectory = false
			torpedo_launcher.use_multi_angle_trajectory = false
			torpedo_launcher.use_simultaneous_impact = true
	
	# Fire the volley
	torpedo_launcher.fire_torpedo(enemy_ship, 8)
	
	# After firing, we need to assign templates to torpedoes
	await get_tree().create_timer(0.1).timeout
	assign_templates_to_torpedoes()

func assign_templates_to_torpedoes():
	"""Assign trajectory templates to the fired torpedoes"""
	var torpedoes = get_tree().get_nodes_in_group("torpedoes")
	var trajectory_type = get_current_trajectory_name()
	var templates = trajectory_templates[trajectory_type]
	
	# Use tournament selection to choose templates
	var assigned_templates = []
	for i in range(min(torpedoes.size(), 8)):
		var template = tournament_select(templates)
		assigned_templates.append(template)
		template.uses += 1
	
	# Assign to torpedoes and configure MPC if they support it
	for i in range(min(torpedoes.size(), assigned_templates.size())):
		var torpedo = torpedoes[i]
		if is_instance_valid(torpedo):
			# Store template info for analysis
			torpedo.set_meta("mpc_template", assigned_templates[i])
			torpedo.set_meta("mpc_weights", cost_weights[trajectory_type])
			
			# If torpedo has MPC controller, configure it
			if torpedo.has_method("set_mpc_parameters"):
				torpedo.set_mpc_parameters(
					assigned_templates[i],
					cost_weights[trajectory_type]
				)

func tournament_select(population: Array) -> Dictionary:
	"""Select a template using tournament selection"""
	var tournament = []
	for i in range(TOURNAMENT_SIZE):
		var idx = randi() % population.size()
		tournament.append(population[idx])
	
	# Sort by fitness
	tournament.sort_custom(func(a, b): return a.fitness > b.fitness)
	return tournament[0]

func analyze_cycle_results():
	var results = mpc_observer.get_cycle_results()
	var trajectory_type = get_current_trajectory_name()
	
	# Update template fitness based on results
	update_template_fitness(results)
	
	# Check for perfect cycle
	if results.hits == 8 and results.misses == 0:
		consecutive_perfect_cycles += 1
		print("Result: PERFECT! Consecutive: %d/%d" % [
			consecutive_perfect_cycles, REQUIRED_PERFECT_CYCLES
		])
		
		if consecutive_perfect_cycles >= REQUIRED_PERFECT_CYCLES:
			complete_current_phase()
			return
	else:
		consecutive_perfect_cycles = 0
		print("Result: %d/%d hits - Resetting count" % [results.hits, results.total_fired])
	
	# Evolve population every N cycles
	if current_cycle % 10 == 0:
		evolve_population(trajectory_type)
		generation_count += 1
		print("Evolution: Generation %d complete" % generation_count)
	
	# Update cost weights based on performance
	update_cost_weights(results, trajectory_type)
	
	tuning_state = TuningState.ANALYZING_RESULTS

func update_template_fitness(results: Dictionary):
	"""Update fitness scores for templates used this cycle"""
	var torpedoes_data = results.get("torpedo_outcomes", [])
	
	for torpedo_data in torpedoes_data:
		var template = torpedo_data.get("template")
		if not template:
			continue
		
		# Calculate fitness based on outcome
		var fitness_delta = 0.0
		
		if torpedo_data.hit:
			fitness_delta += 1.0
			# Bonus for good alignment at impact
			if torpedo_data.get("impact_alignment_error", 90) < 10:
				fitness_delta += 0.5
			# Bonus for smooth trajectory
			if torpedo_data.get("trajectory_smoothness", 0) > 0.8:
				fitness_delta += 0.3
		else:
			fitness_delta -= 0.5
			# Extra penalty for bad misses
			if torpedo_data.get("closest_approach", INF) > 1000:
				fitness_delta -= 0.5
		
		# Update template fitness (moving average)
		var alpha = 0.1
		template.fitness = (1 - alpha) * template.fitness + alpha * fitness_delta
		
		# Update success rate
		var success = 1.0 if torpedo_data.hit else 0.0
		template.success_rate = (1 - alpha) * template.success_rate + alpha * success

func evolve_population(trajectory_type: String):
	"""Evolve the template population using genetic algorithm"""
	var population = trajectory_templates[trajectory_type]
	
	# Sort by fitness
	population.sort_custom(func(a, b): return a.fitness > b.fitness)
	
	# Track best fitness
	if population[0].fitness > best_fitness:
		best_fitness = population[0].fitness
	
	# Create new population
	var new_population = []
	
	# Keep elite templates
	for i in range(ELITE_COUNT):
		new_population.append(population[i].duplicate(true))
	
	# Generate rest through crossover and mutation
	while new_population.size() < POPULATION_SIZE:
		var parent1 = tournament_select(population)
		var parent2 = tournament_select(population)
		
		var child = crossover_templates(parent1, parent2, trajectory_type)
		child = mutate_template(child, trajectory_type)
		
		child["id"] = "%s_%d_%d" % [trajectory_type, generation_count, new_population.size()]
		child["fitness"] = 0.0
		child["success_rate"] = 0.0
		child["uses"] = 0
		
		new_population.append(child)
	
	# Replace old population
	trajectory_templates[trajectory_type] = new_population

func crossover_templates(parent1: Dictionary, parent2: Dictionary, trajectory_type: String) -> Dictionary:
	"""Create child template from two parents"""
	var child = {
		"control_points": [],
		"phase_transitions": [],
		"parameters": {}
	}
	
	# Crossover parameters
	for key in parent1.parameters:
		if randf() < 0.5:
			child.parameters[key] = parent1.parameters[key]
		else:
			child.parameters[key] = parent2.parameters[key]
	
	# Rebuild phase transitions based on parameters
	match trajectory_type:
		"straight":
			child.phase_transitions = [1.0]
		"multi_angle":
			child.phase_transitions = [
				child.parameters.get("arc_start", 0.2),
				child.parameters.get("arc_peak", 0.5),
				child.parameters.get("final_approach", 0.8)
			]
		"simultaneous":
			child.phase_transitions = [
				child.parameters.get("fan_duration", 0.3),
				child.parameters.get("converge_start", 0.7)
			]
	
	return child

func mutate_template(template: Dictionary, trajectory_type: String) -> Dictionary:
	"""Apply mutations to template parameters"""
	var mutated = template.duplicate(true)
	
	# Define parameter constraints based on trajectory type
	var param_constraints = {}
	
	match trajectory_type:
		"straight":
			param_constraints = {
				"thrust_factor": {"min": 0.5, "max": 1.0, "mutation_scale": 0.05},
				"initial_angle_offset": {"min": -15, "max": 15, "mutation_scale": 2.0}
			}
		
		"multi_angle":
			param_constraints = {
				"arc_factor": {"min": 0.1, "max": 0.6, "mutation_scale": 0.05},
				"arc_start": {"min": 0.05, "max": 0.3, "mutation_scale": 0.02},
				"arc_peak": {"min": 0.3, "max": 0.7, "mutation_scale": 0.05},
				"final_approach": {"min": 0.7, "max": 0.95, "mutation_scale": 0.02}
			}
		
		"simultaneous":
			param_constraints = {
				"fan_rate": {"min": 0.3, "max": 2.0, "mutation_scale": 0.1},
				"fan_duration": {"min": 0.1, "max": 0.5, "mutation_scale": 0.03},
				"converge_start": {"min": 0.5, "max": 0.85, "mutation_scale": 0.03},
				"converge_aggression": {"min": 0.5, "max": 1.5, "mutation_scale": 0.1}
			}
	
	# Apply mutations with type-specific constraints
	for key in mutated.parameters:
		if randf() < mutation_rate:
			var value = mutated.parameters[key]
			
			if param_constraints.has(key):
				var constraints = param_constraints[key]
				var mutation_scale = constraints.get("mutation_scale", 0.1)
				var mutation = randfn(0.0, mutation_scale)  # Gaussian noise with mean=0, deviation=mutation_scale
				var new_value = value + mutation
				
				# Clamp to type-specific bounds
				mutated.parameters[key] = clamp(
					new_value, 
					constraints.min, 
					constraints.max
				)
			else:
				# Unknown parameter - use generic mutation
				var mutation = randfn(0.0, 0.1)  # Gaussian noise with mean=0, deviation=0.1
				mutated.parameters[key] = clamp(value + mutation, 0.0, 2.0)
	
	# Ensure phase transitions are properly ordered after mutation
	match trajectory_type:
		"multi_angle":
			# Ensure arc_start < arc_peak < final_approach
			if mutated.parameters.has_all(["arc_start", "arc_peak", "final_approach"]):
				var start = mutated.parameters.arc_start
				var peak = mutated.parameters.arc_peak
				var final = mutated.parameters.final_approach
				
				# Fix ordering if needed
				if peak <= start:
					mutated.parameters.arc_peak = start + 0.1
				if final <= peak:
					mutated.parameters.final_approach = min(peak + 0.1, 0.95)
				
				# Update phase transitions
				mutated.phase_transitions = [
					mutated.parameters.arc_start,
					mutated.parameters.arc_peak,
					mutated.parameters.final_approach
				]
		
		"simultaneous":
			# Ensure fan_duration < converge_start
			if mutated.parameters.has_all(["fan_duration", "converge_start"]):
				if mutated.parameters.converge_start <= mutated.parameters.fan_duration:
					mutated.parameters.converge_start = min(
						mutated.parameters.fan_duration + 0.1, 
						0.85
					)
				
				# Update phase transitions
				mutated.phase_transitions = [
					mutated.parameters.fan_duration,
					mutated.parameters.converge_start
				]
	
	return mutated

func update_cost_weights(results: Dictionary, trajectory_type: String):
	"""Adjust cost function weights based on performance"""
	var weights = cost_weights[trajectory_type]
	var gradient = {}
	
	# Initialize gradient
	for key in weights:
		gradient[key] = 0.0
	
	# Analyze failure patterns to determine gradient
	if results.miss_reasons.has("out_of_bounds"):
		gradient["distance"] += 0.1
		gradient["control"] -= 0.05
	
	if results.get("avg_alignment_error", 0) > 0.2:
		gradient["alignment"] += 0.1
	
	if results.get("avg_smoothness", 1.0) < 0.7:
		gradient["smoothness"] += 0.05
		gradient["control"] += 0.05
	
	# Apply gradient with learning rate
	for key in weights:
		weights[key] += gradient[key] * learning_rate
		weights[key] = clamp(weights[key], 0.01, 10.0)

func complete_current_phase():
	var trajectory_type = get_current_trajectory_name()
	
	print("\n" + "=".repeat(40))
	print("    PHASE COMPLETE: %s" % trajectory_type.to_upper())
	print("    Generations: %d" % generation_count)
	print("    Best fitness: %.3f" % best_fitness)
	print("=".repeat(40))
	
	# Save best templates for this phase
	save_phase_results(trajectory_type)
	
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
	generation_count = 0
	best_fitness = 0.0
	
	# Reinitialize population for new phase
	initialize_template_populations()
	
	tuning_state = TuningState.WAITING_BETWEEN_CYCLES
	state_timer = 0.0

func complete_tuning():
	tuning_active = false
	current_phase = TuningPhase.COMPLETE
	set_process(false)
	
	print("\n" + "=".repeat(40))
	print("    MPC TUNING COMPLETE")
	print("=".repeat(40))
	
	save_tuned_parameters()
	
	# Return to NONE mode
	GameMode.set_mode(GameMode.Mode.NONE)

func save_phase_results(trajectory_type: String):
	"""Save the best templates from this phase"""
	var population = trajectory_templates[trajectory_type]
	population.sort_custom(func(a, b): return a.fitness > b.fitness)
	
	# Keep only the best templates
	var best_templates = []
	for i in range(min(20, population.size())):
		if population[i].fitness > 0:
			best_templates.append(population[i])
	
	# Store for final save
	tuning_metrics[trajectory_type] = {
		"best_templates": best_templates,
		"cost_weights": cost_weights[trajectory_type].duplicate(),
		"generations": generation_count
	}

func save_tuned_parameters():
	"""Save all tuned parameters to file"""
	var save_data = {
		"tuning_date": Time.get_datetime_string_from_system(),
		"tuning_stats": {
			"total_cycles": current_cycle,
			"total_time": (Time.get_ticks_msec() / 1000.0) - tuning_start_time
		},
		"parameters": {}
	}
	
	# Save parameters for each trajectory type
	for trajectory_type in ["straight", "multi_angle", "simultaneous"]:
		if tuning_metrics.has(trajectory_type):
			save_data.parameters[trajectory_type] = tuning_metrics[trajectory_type]
	
	# Save to file
	var file = FileAccess.open("user://mpc_tuned_parameters.json", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(save_data, "\t"))
		file.close()
		print("Tuned parameters saved to user://mpc_tuned_parameters.json")

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

func reset_battle_positions():
	if player_ship:
		player_ship.set_deferred("global_position", PLAYER_START_POS)
		player_ship.set_deferred("rotation", PLAYER_START_ROT)
		if player_ship.has_method("reset_for_mpc_cycle"):
			player_ship.call_deferred("reset_for_mpc_cycle")
	
	if enemy_ship:
		enemy_ship.set_deferred("global_position", ENEMY_START_POS)
		enemy_ship.set_deferred("rotation", ENEMY_START_ROT)
		if enemy_ship.has_method("reset_for_mpc_cycle"):
			enemy_ship.call_deferred("reset_for_mpc_cycle")
	
	if torpedo_launcher and torpedo_launcher.has_method("reset_all_tubes"):
		torpedo_launcher.reset_all_tubes()

func cleanup_field():
	for torpedo in get_tree().get_nodes_in_group("torpedoes"):
		if is_instance_valid(torpedo):
			torpedo.queue_free()
	
	for bullet in get_tree().get_nodes_in_group("bullets"):
		if is_instance_valid(bullet):
			bullet.queue_free()

func emergency_stop():
	"""Called by GameMode when cleaning up"""
	stop_tuning()

# Public interface
func is_tuning_active() -> bool:
	return tuning_active

func get_tuned_parameters() -> Dictionary:
	"""Load previously tuned parameters"""
	var file = FileAccess.open("user://mpc_tuned_parameters.json", FileAccess.READ)
	if file:
		var json_string = file.get_as_text()
		file.close()
		var json = JSON.new()
		var parse_result = json.parse(json_string)
		if parse_result == OK:
			return json.data
	return {}

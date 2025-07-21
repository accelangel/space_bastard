# Scripts/Systems/DebugConfig.gd
extends Node

var categories = {
	# Critical for MPC tuning - KEEP THESE ON
	"mpc_tuning": true,        # Cycle results, hit rates
	"mpc_evolution": true,     # Template evolution stats
	
	# GPU spam - TURN OFF
	"gpu_boundary": false,     # GPU input/output (THE SPAM)
	"gpu_compute": false,      # Computation times
	
	# Not needed right now
	"pdc_targeting": false,    # PDC acquisition/firing
	"cache_performance": false, # Cache hit/miss spam
	"trajectory_details": false, # Individual torpedo paths
	
	"rotation_clamping": false  # Silences the clamping warnings

}

func should_log(category: String) -> bool:
	return categories.get(category, false)

func log_if_enabled(category: String, message: String):
	if should_log(category):
		print(message)

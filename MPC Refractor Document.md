# MPC Torpedo System Refactoring Plan v7.0 - Complete Physics-First Implementation

## The Problem

The current MPC system is overcomplicated and fights against physics. Torpedoes oscillate between templates, can't hit stationary targets, and the "MPC" is really just template selection. The system tries to recalculate everything every frame instead of committing to a plan and following it smoothly. Templates are parameter sets, not actual trajectories, leading to jerky, unpredictable motion.

### The Fundamental Physics Challenge

In space combat with forward-only thrust, the relationship between velocity and maneuverability is brutal:
- **Turn radius = v²/a_lateral**
- At 2,000 m/s with 150G (1,471.5 m/s²): radius = 2.7 km
- At 20,000 m/s: radius = 272 km
- At 91,000 m/s: radius = 5,633 km

Why this matters: At 4,000 km engagement range, a torpedo trying to achieve a 90° approach angle while traveling at 91,000 m/s would need to start turning before it even launches! The turn radius (5,633 km) is larger than the entire engagement distance. This isn't a control problem - it's physically impossible.

### The Velocity Alignment Paradox

The old system tried to solve "sideways torpedoes" by adding alignment weights that fought against trajectory following. This created an unsolvable conflict:
- To change direction quickly, torpedo must rotate away from velocity vector
- To minimize PDC cross-section, torpedo must align with velocity vector
- These goals are mutually exclusive at high speeds

The real problem wasn't alignment - it was trying to execute impossible trajectories.

## The Solution

A true layered guidance system where GPU-based trajectory planning (Layer 1) generates physically-achievable waypoint paths with velocity profiles, and simple proportional navigation (Layer 2) smoothly flies through them matching both position and velocity targets. When physics demands it, we employ flip-and-burn maneuvers - the same technique The Expanse's ships use for navigation.

### The Flip-and-Burn Revolution

Flip-and-burn isn't a special case - it's the fundamental solution to high-velocity navigation:

1. **Acceleration Phase**: Thrust hard toward desired position (100-150G)
2. **Flip Phase**: Rotate 180° while coasting (2-3 seconds)
3. **Deceleration Phase**: Thrust retrograde to reduce velocity to manageable levels
4. **Maneuver Phase**: Execute desired trajectory at velocity where turn radius allows it

Example: To approach from 90° at 4,000 km:
- Without flip-burn: Need to arc with 5,633 km radius (impossible - larger than battlefield!)
- With flip-burn: Decelerate to 2,000 m/s, arc with 2.7 km radius (easy!)

This isn't slower - it's the ONLY way to achieve sharp angle changes at combat velocities.

## Critical Design Consideration: Terminal Alignment (Natural Solution)

### The Problem Solves Itself

With physics-based trajectories and velocity management:

1. **During Burns**: Torpedo naturally points along velocity vector (thrust = velocity change)
2. **During Flips**: Brief misalignment at maximum range from threats
3. **During Curves**: Velocity low enough that rotation rate can track naturally
4. **Terminal Phase**: Proper trajectory planning ensures nose-first approach

**No alignment weights needed!** Natural physics creates natural alignment.

## Physics Constraints & Requirements

### What We Accept
- **Forward-only thrust** (torpedoes can't thrust sideways or backwards)
- **Continuous acceleration** (30G baseline, up to 150G for maneuvers)
- **No arbitrary speed limit** (only physics limits and target requirements)
- **20-100% throttle range** (no reverse thrust except via flip maneuver)
- **Turn radius = v²/a** (emerges from physics, not programmed)
- **Lateral launch ejection** (all torpedoes launch sideways from tubes)

### What We DON'T Want
- Arbitrary speed caps (old 2000 m/s limit)
- Constant throttle cutting that wastes efficiency
- Impossible turns that physics won't allow
- Competing control objectives (alignment vs tracking)
- Different physics for different torpedo types
- Multiple flip-burns per approach (maximum 1, rarely 2)

## Core Data Architecture Principles

### Immediate State & Zero-Trust Design
**Why**: Godot's node system creates temporal coupling issues. Nodes can be freed between frames, references become invalid, and ID mismatches cause cascading failures. The time between storing a reference and using it is an eternity in game time - ships explode, torpedoes hit targets, PDCs intercept threats. By the time you use a stored reference, the entire battlefield may have changed.

### Fundamental Rules

1. **Never Store Node References**
   ```gdscript
   # WRONG - Reference might be invalid next frame
   var my_target: Node2D = torpedo_node
   
   # RIGHT - Store ID, validate every access
   var target_id: String = torpedo.torpedo_id
   func get_target() -> Node2D:
       return validate_and_get_torpedo(target_id)
   ```

2. **Every Frame is a Fresh Start**
   ```gdscript
   func _physics_process(delta):
       # Re-validate EVERYTHING
       if not is_instance_valid(current_waypoint_marker):
           current_waypoint_marker = null
       
       # Fresh queries for current state
       var valid_torpedoes = get_tree().get_nodes_in_group("torpedoes")
       for torpedo in valid_torpedoes:
           if is_valid_entity(torpedo):
               process_torpedo(torpedo)
   ```

3. **Self-Identifying Nodes**
   - Every torpedo carries its own complete identity
   - No external ID generation or mapping
   - Identity baked into the node as exported properties
   - Metadata redundancy for safety

4. **Mark for Death Pattern**
   ```gdscript
   func mark_for_destruction(reason: String):
       if marked_for_death:
           return  # Already dying
       
       marked_for_death = true
       is_alive = false
       
       # Immediate state changes
       set_physics_process(false)
       $CollisionShape2D.disabled = true
       
       # Notify then cleanup
       get_tree().call_group("battle_observers", "on_entity_dying", self, reason)
       queue_free()
   ```

### System-Specific Implications

**TrajectoryPlanner**:
- Don't store torpedo references between frames
- Each update request includes full torpedo state
- Waypoints returned as positions with velocity targets, not node references
- Validate torpedo still exists before applying updates

**ProportionalNavigation**:
- No stored reference to "current waypoint node"
- Calculate fresh each frame from waypoint array
- Match both position AND velocity targets from waypoints
- Validate torpedo exists before calculating guidance

**TorpedoVisualizer**:
- Trail nodes might be freed - check is_instance_valid()
- Waypoint markers are visual only - don't rely on them for logic
- Clear all visuals when torpedo dies, don't assume they'll clean themselves
- Show velocity targets and maneuver types visually

**SimpleAutoTuner**:
- Don't track torpedoes across cycles
- Count hits/misses through event observation, not direct tracking
- Ship reset positions are fresh teleports, not state preservation
- Tune for both position accuracy AND velocity matching

This architecture principle overrides any implementation detail that would violate it. When in doubt: query fresh, validate everything, trust nothing across frames.

## Files to DELETE

### Complete Removal
- `BatchMPCManager.gd` - replaced by TrajectoryPlanner
- `GPUBatchCompute.gd` - replaced by cleaner GPU planner
- `MPCController.gd` - no longer needed
- `MPCTuner.gd` - no tuning system needed
- `MPCTuningObserver.gd` - no tuning system needed
- `mpc_trajectory_batch.glsl` - replaced with trajectory planning shader

### Heavy Modification
- `TorpedoMPC.gd` - becomes SmartTorpedo.gd (90% rewrite)
- `ProportionalNavigation.gd` - add velocity matching (50% rewrite)
- `TrajectoryPlanner.gd` - add physics simulation (75% rewrite)

## New Architecture

### **TorpedoBase.gd**
**Why**: Shared foundation prevents code duplication and ensures consistent physics, launch behavior, and now velocity tracking

Provides ALL torpedoes with:
- Core physics state (position, velocity, orientation)
- Thrust and rotation application
- **Lateral launch system** (unchanged from v6.1)
- Trail rendering
- Enhanced waypoint structure with velocity profiles:

```gdscript
class Waypoint:
    var position: Vector2
    var velocity_target: float        # Desired speed at this waypoint in m/s
    var velocity_tolerance: float     # How close to target velocity (default 500 m/s)
    var maneuver_type: String        # "cruise", "flip", "burn", "curve", "terminal"
    var thrust_limit: float          # 0.0-1.0, allows fine control per segment
    
    func should_accept(torpedo_pos: Vector2, torpedo_vel: float) -> bool:
        var pos_error = position.distance_to(torpedo_pos) * WorldSettings.meters_per_pixel
        var vel_error = abs(velocity_target - torpedo_vel)
        
        # Position acceptance remains the same
        if pos_error < acceptance_radius_meters:
            return true
            
        # NEW: Also accept if we're close in velocity and moving toward waypoint
        if vel_error < velocity_tolerance and is_moving_toward_waypoint(torpedo_pos, position):
            return true
            
        return false
```

Waypoint acceptance logic enhanced:
```gdscript
@export var acceptance_radius: float = 100.0  # meters
@export var waypoint_timeout: float = 10.0    # seconds per waypoint
@export var velocity_acceptance: float = 500.0 # m/s tolerance

func check_waypoint_advance():
    if current_waypoint_index >= waypoints.size() - 1:
        return  # Already at final waypoint
    
    var current_waypoint = waypoints[current_waypoint_index]
    var to_waypoint = current_waypoint.position - global_position
    var distance = to_waypoint.length()
    var distance_meters = distance * WorldSettings.meters_per_pixel
    
    # NEW: Check velocity matching
    var velocity_error = abs(velocity_mps.length() - current_waypoint.velocity_target)
    var velocity_matched = velocity_error < current_waypoint.velocity_tolerance
    
    # Three conditions for advancing (enhanced)
    if distance_meters < acceptance_radius:
        advance_waypoint("reached")
    elif to_waypoint.dot(velocity) < 0 and velocity_matched:
        advance_waypoint("passed_with_velocity_match")
    elif Time.get_ticks_msec() / 1000.0 - waypoint_start_time > waypoint_timeout:
        advance_waypoint("timeout")
        # Log velocity mismatch if that's why we timed out
        if not velocity_matched:
            print("Torpedo %s: Waypoint timeout with velocity error: %.1f m/s" % [torpedo_id, velocity_error])

func advance_waypoint(reason: String):
    # Store velocity achievement for tuning
    var wp = waypoints[current_waypoint_index]
    var velocity_achievement = 1.0 - (abs(velocity_mps.length() - wp.velocity_target) / wp.velocity_target)
    
    current_waypoint_index += 1
    waypoint_start_time = Time.get_ticks_msec() / 1000.0
    emit_signal("waypoint_reached", current_waypoint_index - 1, reason, velocity_achievement)
```

**What NOT to do**: 
- Don't put trajectory-specific logic here
- Don't add velocity control logic - that's Layer 2's job
- Don't make waypoint acceptance too strict on velocity

### **StandardTorpedo.gd** (extends TorpedoBase)
**Why**: Even simple torpedoes benefit from waypoint visualization and velocity planning

Simple direct-attack torpedo with velocity awareness:
```gdscript
func generate_waypoints():
    var to_target = target.global_position - global_position
    var distance = to_target.length()
    var distance_meters = distance * WorldSettings.meters_per_pixel
    
    waypoints.clear()
    
    # Calculate if we'll need velocity management
    var final_velocity_if_constant_accel = sqrt(2 * max_acceleration * distance_meters)
    var needs_velocity_management = final_velocity_if_constant_accel > 10000.0  # 10 km/s threshold
    
    if needs_velocity_management:
        generate_velocity_managed_waypoints(distance, to_target)
    else:
        generate_simple_waypoints(distance, to_target)

func generate_simple_waypoints(distance: float, to_target: Vector2):
    # Initial offset to clear launching ship
    var offset_dir = Vector2.UP.rotated(launcher.rotation + launch_side * PI/2)
    waypoints.append(Waypoint.new(
        global_position + offset_dir * 100,
        500.0,  # Low initial velocity target
        "cruise",
        0.8
    ))
    
    # Acceleration phase waypoints
    for i in range(1, 4):
        var t = float(i) / 4.0
        waypoints.append(Waypoint.new(
            global_position + to_target * t,
            2000.0 + t * 8000.0,  # Ramping velocity
            "cruise",
            1.0
        ))
    
    # Terminal waypoint
    waypoints.append(Waypoint.new(
        target.global_position,
        10000.0,  # High impact velocity
        "terminal",
        1.0
    ))

func generate_velocity_managed_waypoints(distance: float, to_target: Vector2):
    # This is rare for straight torpedoes but handles extreme range
    # Plan a slight S-curve to manage velocity
    # ... implementation for velocity management
```

**What NOT to do**: 
- Don't make these use different physics or guidance laws
- Don't skip velocity planning even for "simple" torpedoes

### **SmartTorpedo.gd** (extends TorpedoBase)
**Why**: Complex trajectories REQUIRE velocity management and flip-burn capabilities

Advanced multi-role torpedo with physics-based planning:

**Multi-Angle Attack with Flip-Burn**:
```gdscript
func generate_multi_angle_waypoints():
    var to_target = target.global_position - global_position
    var distance = to_target.length()
    var distance_meters = distance * WorldSettings.meters_per_pixel
    var perpendicular = to_target.rotated(approach_side * PI/2).normalized()
    
    # Physics calculation - can we arc without flip-burn?
    var direct_velocity = calculate_direct_intercept_velocity(distance_meters)
    var turn_radius = (direct_velocity * direct_velocity) / max_acceleration
    var min_safe_radius = distance_meters * 0.15  # Need 15% of distance for safe arc
    
    waypoints.clear()
    
    if turn_radius > min_safe_radius:
        # MUST use flip-burn approach
        print("Torpedo %s: Turn radius %.1f km exceeds safe limit %.1f km - using flip-burn" % 
              [torpedo_id, turn_radius/1000.0, min_safe_radius/1000.0])
        generate_flip_burn_multi_angle()
    else:
        # Can use curved approach
        generate_curved_multi_angle()

func generate_flip_burn_multi_angle():
    # Phase 1: Aggressive positioning burn (30-40 waypoints)
    var burn_angle = PI/3 * approach_side  # 60° off direct path
    var burn_direction = to_target.rotated(burn_angle).normalized()
    
    # Calculate burn duration to reach position
    var lateral_displacement_needed = distance * 0.3  # Get 30% to the side
    var burn_time = calculate_burn_time_for_displacement(lateral_displacement_needed)
    var waypoints_for_burn = int(burn_time * 2)  # 2 waypoints per second
    
    for i in range(waypoints_for_burn):
        var t = float(i) / float(waypoints_for_burn - 1)
        var accel_profile = ease(t, 0.2)  # Smooth acceleration ramp
        
        waypoints.append(Waypoint.new(
            global_position + burn_direction * lateral_displacement_needed * accel_profile,
            1000.0 + 40000.0 * t,  # Accelerate to 41 km/s
            "cruise",
            0.9 + 0.1 * t  # Ramp thrust from 90% to 100%
        ))
    
    # Phase 2: Flip maneuver (3 waypoints)
    var flip_position = waypoints[-1].position
    var flip_velocity = waypoints[-1].velocity_target
    
    waypoints.append(Waypoint.new(
        flip_position + velocity.normalized() * 50,  # Pre-flip coast
        flip_velocity,
        "flip",
        0.0  # No thrust during flip
    ))
    
    waypoints.append(Waypoint.new(
        flip_position + velocity.normalized() * 150,  # Mid-flip
        flip_velocity,
        "flip",
        0.0
    ))
    
    waypoints.append(Waypoint.new(
        flip_position + velocity.normalized() * 250,  # Post-flip
        flip_velocity,
        "flip",
        0.0
    ))
    
    # Phase 3: Deceleration burn (20-30 waypoints)
    var decel_waypoints = 25
    var target_velocity = 2000.0  # Decelerate to 2 km/s for arc
    
    for i in range(decel_waypoints):
        var t = float(i) / float(decel_waypoints - 1)
        var vel = flip_velocity - (flip_velocity - target_velocity) * ease(t, 0.5)
        
        # Continue moving forward while decelerating
        var decel_pos = flip_position + burn_direction * (300 + i * 20)
        
        waypoints.append(Waypoint.new(
            decel_pos,
            vel,
            "burn",
            1.0  # Maximum thrust for deceleration
        ))
    
    # Phase 4: Arc approach at manageable velocity (40-50 waypoints)
    var arc_start_pos = waypoints[-1].position
    var arc_waypoints = 45
    
    for i in range(arc_waypoints):
        var t = float(i) / float(arc_waypoints - 1)
        
        # Calculate arc position
        var arc_progress = ease(t, 0.3)
        var to_target_from_arc = target.global_position - arc_start_pos
        
        # Blend from perpendicular to direct approach
        var blend_factor = 1.0 - pow(t, 2)  # Start perpendicular, end direct
        var arc_offset = perpendicular * distance * 0.4 * blend_factor
        var arc_pos = arc_start_pos + to_target_from_arc * arc_progress + arc_offset
        
        # Gradually increase velocity during approach
        var approach_velocity = target_velocity + t * 8000.0  # Accelerate to 10 km/s
        
        waypoints.append(Waypoint.new(
            arc_pos,
            approach_velocity,
            "curve",
            0.7 + 0.3 * t  # Increase thrust as we straighten out
        ))
    
    # Final approach waypoint
    waypoints.append(Waypoint.new(
        target.global_position,
        10000.0,  # Maximum impact velocity
        "terminal",
        1.0
    ))
```

**Simultaneous Impact with Velocity Coordination**:
```gdscript
func generate_simultaneous_waypoints(assigned_angle: float, impact_time: float):
    # Calculate required path length based on impact time
    var direct_distance = global_position.distance_to(target.global_position)
    var direct_distance_meters = direct_distance * WorldSettings.meters_per_pixel
    
    # Physics check - can we reach target in time?
    var min_flight_time = calculate_minimum_flight_time(direct_distance_meters)
    if impact_time < min_flight_time:
        print("WARNING: Impact time %.1fs less than minimum %.1fs" % [impact_time, min_flight_time])
        impact_time = min_flight_time * 1.1  # Add 10% margin
    
    waypoints.clear()
    
    # Fan angle determines how extreme our trajectory is
    var extreme_angle = abs(assigned_angle) > deg_to_rad(60)
    
    if extreme_angle:
        generate_extreme_simultaneous_trajectory(assigned_angle, impact_time)
    else:
        generate_moderate_simultaneous_trajectory(assigned_angle, impact_time)

func generate_extreme_simultaneous_trajectory(assigned_angle: float, impact_time: float):
    # For ±70-80° approaches, we NEED flip-burn
    
    # Phase 1: Fan out aggressively (20 waypoints)
    var fan_direction = Vector2.from_angle(parent_ship.rotation + assigned_angle)
    var fan_distance = 500.0  # kilometers
    
    for i in range(20):
        var t = float(i) / 19.0
        var fan_progress = ease(t, 0.2)
        
        waypoints.append(Waypoint.new(
            global_position + fan_direction * fan_distance * fan_progress,
            500.0 + 20000.0 * t,  # Accelerate to 20.5 km/s
            "cruise",
            1.0
        ))
    
    # Phase 2: Flip maneuver
    # Similar to multi-angle but timed for simultaneous arrival
    # ... (flip waypoints as before)
    
    # Phase 3: Deceleration to manageable speed
    # ... (deceleration waypoints)
    
    # Phase 4: Timed approach
    var remaining_time = impact_time - calculate_elapsed_time(waypoints)
    var remaining_distance = calculate_remaining_distance(waypoints[-1].position, target.global_position)
    var required_velocity = remaining_distance / remaining_time
    
    # Generate waypoints to match timing requirement
    # ... (timed approach waypoints)
```

**What NOT to do**: 
- Don't add special physics - complexity comes from waypoints
- Don't allow more than one flip-burn per trajectory
- Don't generate physically impossible velocity transitions

### **TrajectoryPlanner.gd** (Singleton)
**Why**: GPU acceleration makes complex trajectory optimization with physics validation feasible

GPU-accelerated trajectory optimization with full physics simulation:

```gdscript
extends Node
class_name TrajectoryPlanner

# GPU compute resources
var rd: RenderingDevice
var shader: RID
var pipeline: RID

# Physics validation parameters
const TURN_RADIUS_SAFETY_FACTOR: float = 1.5  # 50% safety margin
const MIN_WAYPOINT_SPACING_METERS: float = 100.0
const FLIP_DURATION_SECONDS: float = 2.5
const VELOCITY_CHANGE_RATE_LIMIT: float = 2000.0  # m/s per second max

# Template evolution state
var trajectory_templates: Dictionary = {}
var template_success_rates: Dictionary = {}

func generate_waypoints_gpu(torpedo: SmartTorpedo) -> Array:
    var start_time = Time.get_ticks_usec()
    
    # Prepare state for GPU
    var current_state = torpedo.get_physics_state()
    var target_state = torpedo.get_target_state()
    var constraints = torpedo.get_trajectory_constraints()
    
    # Determine if flip-burn is required
    var needs_flip_burn = evaluate_flip_burn_requirement(
        current_state, target_state, constraints
    )
    
    if needs_flip_burn:
        # Generate flip-burn trajectory on CPU (too complex for current GPU shader)
        var trajectory = generate_flip_burn_trajectory_cpu(
            current_state, target_state, constraints
        )
        validate_trajectory_physics(trajectory)
        return trajectory
    
    # Use GPU for standard trajectory optimization
    var gpu_result = compute_trajectory_gpu(current_state, target_state, constraints)
    
    # Validate physics
    if not validate_trajectory_physics(gpu_result):
        # GPU trajectory is impossible - fall back to flip-burn
        print("GPU trajectory failed physics validation - using flip-burn")
        return generate_flip_burn_trajectory_cpu(
            current_state, target_state, constraints
        )
    
    var compute_time = (Time.get_ticks_usec() - start_time) / 1000.0
    if compute_time > 10.0:  # Log slow computations
        print("Trajectory planning took %.1f ms" % compute_time)
    
    return gpu_result

func evaluate_flip_burn_requirement(current_state: Dictionary, target_state: Dictionary, constraints: Dictionary) -> bool:
    """Determine if physics requires flip-burn maneuver"""
    
    var to_target = target_state.position - current_state.position
    var distance = to_target.length()
    
    # Calculate velocity if we accelerate all the way
    var final_velocity = sqrt(
        current_state.velocity.length_squared() + 
        2 * constraints.max_acceleration * distance
    )
    
    # Calculate turn radius at that velocity
    var turn_radius = (final_velocity * final_velocity) / constraints.max_acceleration
    
    # Check against trajectory requirements
    match constraints.trajectory_type:
        "multi_angle":
            # Need to turn ~90 degrees
            var required_turn_distance = distance * 0.3  # 30% for safe arc
            return turn_radius > required_turn_distance
            
        "simultaneous":
            # Check if assigned angle is extreme
            if abs(constraints.assigned_angle) > deg_to_rad(60):
                return turn_radius > distance * 0.2
            return false
            
        _:
            # Straight trajectories rarely need flip-burn
            return false

func validate_trajectory_physics(waypoints: Array) -> bool:
    """Validate that trajectory is physically achievable"""
    
    if waypoints.size() < 2:
        return false
    
    var validation_passed = true
    var max_violation = 0.0
    
    for i in range(waypoints.size() - 1):
        var wp1 = waypoints[i]
        var wp2 = waypoints[i + 1]
        
        # Check waypoint spacing
        var distance = wp1.position.distance_to(wp2.position) * WorldSettings.meters_per_pixel
        if distance < MIN_WAYPOINT_SPACING_METERS:
            print("Waypoints too close: %.1f m" % distance)
            validation_passed = false
            continue
        
        # Check velocity change feasibility
        var time_between = estimate_time_between_waypoints(wp1, wp2)
        var velocity_change = abs(wp2.velocity_target - wp1.velocity_target)
        var max_velocity_change = wp1.max_acceleration * time_between
        
        if velocity_change > max_velocity_change * 1.1:  # 10% tolerance
            print("Velocity change impossible: need %.0f m/s in %.1f s (max: %.0f)" % 
                  [velocity_change, time_between, max_velocity_change])
            validation_passed = false
        
        # Check turn radius if direction changes significantly
        if i > 0:
            var wp0 = waypoints[i - 1]
            var dir1 = (wp1.position - wp0.position).normalized()
            var dir2 = (wp2.position - wp1.position).normalized()
            var angle_change = acos(clamp(dir1.dot(dir2), -1.0, 1.0))
            
            if angle_change > deg_to_rad(5):  # Significant turn
                var velocity = wp1.velocity_target
                var required_radius = distance / (2 * sin(angle_change / 2))
                var actual_radius = (velocity * velocity) / wp1.max_acceleration
                
                if actual_radius > required_radius * TURN_RADIUS_SAFETY_FACTOR:
                    var violation = actual_radius / required_radius
                    max_violation = max(max_violation, violation)
                    print("Turn radius violation at waypoint %d: %.1fx too large" % [i, violation])
                    validation_passed = false
    
    return validation_passed

func generate_flip_burn_trajectory_cpu(current_state: Dictionary, target_state: Dictionary, constraints: Dictionary) -> Array:
    """Generate flip-burn trajectory when physics demands it"""
    
    var waypoints = []
    var to_target = target_state.position - current_state.position
    var distance = to_target.length()
    
    # Determine burn angle based on trajectory type
    var burn_angle = calculate_optimal_burn_angle(constraints)
    var burn_direction = to_target.rotated(burn_angle).normalized()
    
    # Phase 1: Acceleration burn
    var burn_time = 30.0  # seconds
    var burn_waypoints = int(burn_time * 2)  # 2 per second
    
    for i in range(burn_waypoints):
        var t = float(i) / float(burn_waypoints - 1)
        var acceleration = constraints.max_acceleration * (0.8 + 0.2 * t)  # Ramp up
        var burn_velocity = acceleration * t * burn_time
        
        waypoints.append(create_waypoint(
            current_state.position + burn_direction * calculate_burn_distance(t, burn_time, acceleration),
            min(burn_velocity, 50000.0),  # Cap at 50 km/s for safety
            "cruise",
            0.8 + 0.2 * t
        ))
    
    # Phase 2: Flip maneuver
    add_flip_waypoints(waypoints, burn_direction, constraints)
    
    # Phase 3: Deceleration burn
    var current_velocity = waypoints[-1].velocity_target
    var target_velocity = calculate_safe_approach_velocity(constraints)
    add_deceleration_waypoints(waypoints, current_velocity, target_velocity, constraints)
    
    # Phase 4: Final approach
    add_approach_waypoints(waypoints, target_state, constraints)
    
    return waypoints
```

**Dynamic Update Rate** (unchanged from v6.1 but with velocity profile updates):
```gdscript
func calculate_update_rate(time_to_impact: float) -> float:
    if time_to_impact >= 15.0:
        return 1.0  # 1 Hz
    elif time_to_impact >= 10.0:
        return 2.0  # 2 Hz
    elif time_to_impact >= 5.0:
        return 3.0  # 3 Hz
    else:
        return 3.0  # Cap at 3 Hz even in terminal phase

func should_update_waypoints(torpedo: SmartTorpedo) -> bool:
    var time_to_impact = calculate_time_to_impact(torpedo)
    var update_rate = calculate_update_rate(time_to_impact)
    var time_since_last = Time.get_ticks_msec() / 1000.0 - torpedo.last_waypoint_update
    
    # Force update if physics violation detected
    if detect_physics_violation(torpedo):
        print("Physics violation detected - forcing trajectory update")
        return true
    
    return time_since_last >= (1.0 / update_rate)

func update_torpedo_waypoints(torpedo: SmartTorpedo):
    var new_waypoints = generate_waypoints_gpu(torpedo)
    
    # Protect current waypoint AND the next TWO after it
    var current_idx = torpedo.current_waypoint_index
    var protected_until = min(current_idx + 3, torpedo.waypoints.size())
    
    # Smooth velocity transitions in updated waypoints
    smooth_velocity_profile(new_waypoints, torpedo.velocity_mps.length(), protected_until)
    
    # Only update waypoints after the protection zone
    for i in range(protected_until, new_waypoints.size()):
        if i < torpedo.waypoints.size():
            torpedo.waypoints[i] = new_waypoints[i]
        else:
            torpedo.waypoints.append(new_waypoints[i])
    
    torpedo.last_waypoint_update = Time.get_ticks_msec() / 1000.0
```

**What NOT to do**: 
- Don't update waypoints torpedo is approaching or about to reach
- Don't generate physically impossible paths
- Don't allow arbitrary velocity changes between waypoints
- Don't skip physics validation to save computation time

### **trajectory_planning.glsl** (GPU Compute Shader)
**Why**: Parallel evaluation of trajectory variations with physics constraints

Enhanced GPU compute shader with velocity planning:
```glsl
#version 450

layout(local_size_x = 64) in;

// Torpedo state includes velocity targets now
struct WaypointData {
    vec2 position;
    float velocity_target;
    float maneuver_type;  // 0=cruise, 1=flip, 2=burn, 3=curve, 4=terminal
};

// Input buffers
layout(binding = 0) buffer TorpedoState {
    vec4 position_velocity;
    vec4 orientation_params;  // orientation, angular_vel, max_accel, max_rotation
} torpedo_state;

layout(binding = 1) buffer TargetState {
    vec4 position_velocity;
} target_state;

layout(binding = 2) buffer Constraints {
    vec4 params;  // trajectory_type, assigned_angle, impact_time, reserved
} constraints;

// Output buffer
layout(binding = 3) buffer TrajectoryOutput {
    WaypointData waypoints[100];
    float total_cost;
    float physics_valid;
} output;

// Shared memory for parallel physics validation
shared float physics_violations[64];

void main() {
    uint idx = gl_GlobalInvocationID.x;
    
    // Each thread evaluates a trajectory variant
    float variant_param = float(idx) / 64.0;
    
    // Initialize trajectory
    vec2 current_pos = torpedo_state.position_velocity.xy;
    vec2 current_vel = torpedo_state.position_velocity.zw;
    float orientation = torpedo_state.orientation_params.x;
    float max_accel = torpedo_state.orientation_params.z;
    
    float total_cost = 0.0;
    uint num_waypoints = 0;
    
    // Generate trajectory based on type
    if (constraints.params.x == 0.0) {  // Straight
        num_waypoints = generate_straight_trajectory(variant_param);
    } else if (constraints.params.x == 1.0) {  // Multi-angle
        num_waypoints = generate_multi_angle_trajectory(variant_param);
    } else if (constraints.params.x == 2.0) {  // Simultaneous
        num_waypoints = generate_simultaneous_trajectory(variant_param);
    }
    
    // Physics validation in parallel
    float my_violations = 0.0;
    
    for (uint i = 1; i < num_waypoints; i++) {
        vec2 wp1_pos = output.waypoints[i-1].position;
        vec2 wp2_pos = output.waypoints[i].position;
        float v1 = output.waypoints[i-1].velocity_target;
        float v2 = output.waypoints[i].velocity_target;
        
        // Check turn radius
        if (i > 1) {
            vec2 wp0_pos = output.waypoints[i-2].position;
            vec2 dir1 = normalize(wp1_pos - wp0_pos);
            vec2 dir2 = normalize(wp2_pos - wp1_pos);
            float angle_change = acos(clamp(dot(dir1, dir2), -1.0, 1.0));
            
            if (angle_change > 0.087) {  // 5 degrees
                float turn_radius = v1 * v1 / max_accel;
                float required_radius = length(wp2_pos - wp1_pos) / (2.0 * sin(angle_change / 2.0));
                
                if (turn_radius > required_radius * 1.5) {  // Safety factor
                    my_violations += (turn_radius / required_radius);
                }
            }
        }
        
        // Check velocity change feasibility
        float time_between = estimate_time_between_waypoints(i-1, i);
        float max_vel_change = max_accel * time_between;
        if (abs(v2 - v1) > max_vel_change * 1.1) {
            my_violations += abs(v2 - v1) / max_vel_change;
        }
    }
    
    // Store violations for reduction
    physics_violations[idx] = my_violations;
    barrier();
    
    // Parallel reduction to find best trajectory
    for (uint stride = 32; stride > 0; stride >>= 1) {
        if (idx < stride) {
            if (physics_violations[idx + stride] < physics_violations[idx]) {
                physics_violations[idx] = physics_violations[idx + stride];
                // Copy trajectory data if this one is better
                // ... (trajectory copying logic)
            }
        }
        barrier();
    }
    
    // Thread 0 outputs the best trajectory
    if (idx == 0) {
        output.physics_valid = (physics_violations[0] < 0.1) ? 1.0 : 0.0;
    }
}

uint generate_multi_angle_trajectory(float variant) {
    // Generate waypoints with velocity profiles
    uint wp_count = 0;
    
    // Determine if flip-burn needed based on physics
    float direct_velocity = calculate_direct_velocity();
    float turn_radius = direct_velocity * direct_velocity / torpedo_state.orientation_params.z;
    
    if (turn_radius > target_distance * 0.15) {
        // Generate flip-burn trajectory
        wp_count = generate_flip_burn_waypoints(variant);
    } else {
        // Generate curved trajectory
        wp_count = generate_curved_waypoints(variant);
    }
    
    return wp_count;
}
```

**What NOT to do**: 
- Don't ignore physics constraints in GPU calculations
- Don't generate trajectories without velocity profiles
- Don't skip validation to save GPU cycles

### **ProportionalNavigation.gd** (Component)
**Why**: PN naturally creates smooth curves through waypoints, now with velocity matching

Layer 2 guidance enhanced for velocity targets:
```gdscript
class_name ProportionalNavigation
extends Node

var N: float = 3.0  # Navigation constant
var last_los_angle: float = 0.0
var first_frame: bool = true

# Velocity control parameters
var velocity_gain: float = 0.001  # How aggressively to match velocity
var min_thrust: float = 0.2
var max_thrust: float = 1.0

func calculate_guidance(torpedo_pos: Vector2, torpedo_vel: Vector2, 
                       torpedo_orientation: float, torpedo_max_acceleration: float,
                       torpedo_max_rotation: float,
                       current_waypoint: Waypoint,
                       next_waypoint: Waypoint = null) -> Dictionary:
    
    # Line of sight to current waypoint
    var los = current_waypoint.position - torpedo_pos
    var los_angle = los.angle()
    
    # First frame initialization
    if first_frame:
        last_los_angle = los_angle
        first_frame = false
        return {"turn_rate": 0.0, "thrust": 0.5}
    
    # Calculate LOS rate
    var los_rate = angle_difference(los_angle, last_los_angle) / get_physics_process_delta_time()
    last_los_angle = los_angle
    
    # Closing velocity
    var closing_velocity = -torpedo_vel.dot(los.normalized())
    
    # PN guidance law for position tracking
    var commanded_acceleration = N * closing_velocity * los_rate
    var pn_turn_rate = commanded_acceleration / torpedo_vel.length() if torpedo_vel.length() > 0.1 else 0.0
    
    # Handle special maneuvers
    if current_waypoint.maneuver_type == "flip":
        # Flip maneuver - maximum rotation, no thrust
        return {
            "turn_rate": sign(angle_difference(torpedo_orientation + PI, torpedo_orientation)) * torpedo_max_rotation,
            "thrust": 0.0
        }
    
    # Velocity matching through thrust control
    var current_speed = torpedo_vel.length()
    var target_speed = current_waypoint.velocity_target
    var speed_error = target_speed - current_speed
    
    # Look ahead to next waypoint for anticipatory control
    if next_waypoint:
        var time_to_waypoint = los.length() / max(closing_velocity, 100.0)
        var next_speed = next_waypoint.velocity_target
        var speed_change_needed = next_speed - target_speed
        
        # Anticipate needed velocity changes
        if abs(speed_change_needed) > 1000.0 and time_to_waypoint < 5.0:
            # Big velocity change coming up - start adjusting now
            target_speed = lerp(target_speed, next_speed, 1.0 - time_to_waypoint / 5.0)
            speed_error = target_speed - current_speed
    
    # Calculate thrust based on velocity error and maneuver type
    var thrust = calculate_thrust_for_velocity(
        speed_error, 
        current_waypoint.maneuver_type,
        current_waypoint.thrust_limit,
        torpedo_max_acceleration
    )
    
    # Reduce thrust during high rotation rates (can't thrust efficiently sideways)
    var rotation_factor = 1.0 - min(abs(pn_turn_rate) / torpedo_max_rotation, 0.5)
    thrust *= rotation_factor
    
    # Natural alignment emerges from proper velocity management
    # No alignment weights needed!
    
    return {
        "turn_rate": clamp(pn_turn_rate, -torpedo_max_rotation, torpedo_max_rotation),
        "thrust": clamp(thrust, min_thrust, max_thrust)
    }

func calculate_thrust_for_velocity(speed_error: float, maneuver_type: String, 
                                  thrust_limit: float, max_acceleration: float) -> float:
    """Calculate thrust to achieve velocity target"""
    
    # Base thrust from velocity error
    var base_thrust = 0.5 + speed_error * velocity_gain
    
    # Maneuver-specific adjustments
    match maneuver_type:
        "burn":
            # Always maximum thrust during burns
            base_thrust = 1.0
        "curve":
            # Moderate thrust during curves
            base_thrust = clamp(base_thrust, 0.3, 0.8)
        "terminal":
            # Maximum thrust for impact
            base_thrust = 1.0
        _:
            # Normal cruise
            base_thrust = clamp(base_thrust, min_thrust, max_thrust)
    
    # Apply waypoint thrust limit
    return base_thrust * thrust_limit
```

**Key Features**:
- Tracks both position AND velocity targets
- Anticipates upcoming velocity changes
- Natural handling of flip maneuvers
- Thrust modulation based on rotation (can't thrust efficiently while turning hard)
- NO alignment weights - proper velocity creates proper alignment

**What NOT to do**: 
- Don't add alignment weights back in
- Don't make Layer 2 decide when to flip-burn
- Don't ignore waypoint thrust limits
- Don't try to match velocity exactly - close enough is fine

### **TorpedoVisualizer.gd** (Scene-wide Overlay)
**Why**: Visual debugging shows both trajectory planning and velocity management quality

**Core Components** (enhanced from v6.1):

**Torpedo Trails** (unchanged)
- Single Line2D per torpedo
- Fixed width (2 pixels)
- Color: Cyan (#00FFFF) for all torpedoes
- Shows exact path taken by torpedo center
- Persists until next torpedo volley launches

**Waypoint Markers** (enhanced)
- Circle shapes (8 pixel radius)
- Color coding by maneuver type:
  - Gray (#808080): Passed waypoints
  - Green (#00FF00): Current target waypoint (cruise)
  - Yellow (#FFFF00): Flip maneuver waypoints
  - Red (#FF0000): Burn (deceleration) waypoints
  - Blue (#0080FF): Curve approach waypoints
  - White (#FFFFFF): Terminal waypoints
- When waypoints update (1-3 Hz):
  - All waypoints briefly flash white (#FFFFFF) for 200ms
  - Flash intensity proportional to velocity error
- Final waypoint (target) always visible with pulsing animation

**Velocity Indicators** (NEW)
- Small velocity vector at each waypoint
- Length proportional to velocity_target (log scale)
- Color indicates velocity error:
  - Green: Within tolerance
  - Yellow: 500-1000 m/s error
  - Red: >1000 m/s error
- Angle shows expected heading at waypoint

**Rendering Details**:
```gdscript
func update_waypoint_markers(torpedo: Node2D):
    # Validate torpedo first
    if not is_instance_valid(torpedo):
        return
    
    var markers = waypoint_markers.get(torpedo.torpedo_id, [])
    
    # Return old markers to pool
    for marker in markers:
        if is_instance_valid(marker):
            marker.visible = false
            waypoint_pool.append(marker)
    markers.clear()
    
    # Get markers from pool for new waypoints
    for i in range(torpedo.waypoints.size()):
        if waypoint_pool.is_empty():
            break
        
        var marker = waypoint_pool.pop_back()
        var waypoint = torpedo.waypoints[i]
        
        # Color based on maneuver type
        var color = get_waypoint_color(waypoint.maneuver_type, i, torpedo)
        
        marker.color = color
        marker.global_position = waypoint.position - Vector2(8, 8)
        marker.visible = true
        markers.append(marker)
        
        # Add velocity indicator
        if velocity_indicator_pool.size() > 0:
            var vel_indicator = velocity_indicator_pool.pop_back()
            setup_velocity_indicator(vel_indicator, waypoint, torpedo)
    
    waypoint_markers[torpedo.torpedo_id] = markers
    
    # Flash based on velocity error magnitude
    var max_velocity_error = calculate_max_velocity_error(torpedo)
    flash_waypoints(markers, max_velocity_error)

func get_waypoint_color(maneuver_type: String, index: int, torpedo: Node2D) -> Color:
    # Check if passed
    if index < torpedo.current_waypoint_index:
        return Color.GRAY
    
    # Current waypoint
    if index == torpedo.current_waypoint_index:
        return Color.GREEN
    
    # Future waypoints by type
    match maneuver_type:
        "flip":
            return Color.YELLOW
        "burn":
            return Color.RED
        "curve":
            return Color(0, 0.5, 1)  # Light blue
        "terminal":
            return Color.WHITE
        _:
            return Color.CYAN  # Default cruise

func setup_velocity_indicator(indicator: Line2D, waypoint: Waypoint, torpedo: Node2D):
    # Calculate velocity vector length (log scale for visibility)
    var vel_magnitude = log(waypoint.velocity_target / 100.0) * 10.0
    var vel_direction = calculate_expected_direction(waypoint, torpedo)
    
    # Set up line
    indicator.clear_points()
    indicator.add_point(waypoint.position)
    indicator.add_point(waypoint.position + vel_direction * vel_magnitude)
    
    # Color by velocity error
    var current_velocity = torpedo.velocity_mps.length()
    var velocity_error = abs(waypoint.velocity_target - current_velocity)
    
    if velocity_error < waypoint.velocity_tolerance:
        indicator.default_color = Color.GREEN
    elif velocity_error < 1000.0:
        indicator.default_color = Color.YELLOW
    else:
        indicator.default_color = Color.RED
    
    indicator.width = 1.0
    indicator.visible = true
```

**Trail Management** (unchanged):
- Each torpedo gets one continuous line
- Line drawn from launch position through current position
- All trails cleared when new volley launches

**Implementation Notes**:
- Pure observer - reads torpedo state, never modifies
- Efficient pooling of visual elements
- Increased marker pool size to handle double waypoints
- Velocity indicators are optional (can be toggled)

**What NOT to do**: 
- Don't draw predicted paths
- Don't show physics calculations
- Don't clutter with too many indicators
- Don't make performance-heavy

### **TorpedoLauncher.gd**
**Why**: Must understand trajectory physics requirements when spawning torpedoes

Updates for physics-aware launching:
```gdscript
func fire_torpedo(target: Node2D, count: int = 8):
    # Pre-calculate if trajectories will need flip-burn
    var distance_to_target = global_position.distance_to(target.global_position)
    var physics_analysis = analyze_trajectory_requirements(target, distance_to_target)
    
    match torpedo_mode:
        TorpedoMode.MULTI_ANGLE:
            fire_multi_angle_volley(target, count, physics_analysis)
        TorpedoMode.SIMULTANEOUS:
            fire_simultaneous_volley(target, count, physics_analysis)
        _:
            fire_standard_volley(target, count)

func analyze_trajectory_requirements(target: Node2D, distance: float) -> Dictionary:
    """Pre-flight physics analysis"""
    var analysis = {
        "needs_flip_burn": false,
        "estimated_flight_time": 0.0,
        "max_achievable_angle": 0.0,
        "recommended_acceleration_profile": {}
    }
    
    # Calculate arrival velocity if constant acceleration
    var distance_meters = distance * WorldSettings.meters_per_pixel
    var arrival_velocity = sqrt(2 * 150 * 9.81 * distance_meters)
    var turn_radius = (arrival_velocity * arrival_velocity) / (150 * 9.81)
    
    # For multi-angle, check if 90° approach is possible
    if torpedo_mode == TorpedoMode.MULTI_ANGLE:
        var required_arc_distance = distance_meters * 0.3
        if turn_radius > required_arc_distance:
            analysis.needs_flip_burn = true
            analysis.estimated_flight_time = calculate_flip_burn_time(distance_meters)
        else:
            analysis.estimated_flight_time = calculate_direct_time(distance_meters)
    
    return analysis

func fire_simultaneous_volley(target: Node2D, count: int, physics_analysis: Dictionary):
    var impact_time = calculate_simultaneous_impact_time(target, count, physics_analysis)
    var angle_spacing = deg_to_rad(160.0) / float(count - 1) if count > 1 else 0
    var start_angle = -deg_to_rad(80.0)
    
    for i in range(count):
        var torpedo = create_torpedo(SmartTorpedo)
        torpedo.target = target
        
        var assigned_angle = start_angle + angle_spacing * i
        var extreme_angle = abs(assigned_angle) > deg_to_rad(60)
        
        torpedo.set_flight_plan("simultaneous", {
            "assigned_angle": assigned_angle,
            "impact_time": impact_time,
            "torpedo_index": i,
            "total_torpedoes": count,
            "requires_flip_burn": extreme_angle,  # Pre-calculated physics hint
            "physics_analysis": physics_analysis
        })
        launch_torpedo(torpedo)
```

## Tuning System (Enhanced for Velocity Profiles)

### **SimpleAutoTuner.gd** (Layer 2 Parameter Optimization)
**Why**: Even with good physics design, parameters need tuning for velocity matching

**Core Functionality** (enhanced):
- Tunes both position tracking AND velocity matching performance
- Measures how well torpedoes achieve velocity targets
- Optimizes for smooth velocity profiles

**Implementation** (key changes):
```gdscript
func calculate_performance() -> float:
    var total_score = 0.0
    
    for result in torpedo_results:
        if result.hit:
            total_score += 100.0
            
            # NEW: Bonus for good velocity profile
            if result.velocity_achievement > 0.8:  # Within 20% of targets
                total_score += 30.0
            
            # Bonus for smooth trajectory (no jerky velocity changes)
            if result.trajectory_smoothness > 0.8:
                total_score += 20.0
        else:
            # Inverse miss distance scoring
            var miss_penalty = min(result.miss_distance / 100.0, 50.0)
            total_score += 50.0 - miss_penalty
            
            # NEW: Penalty for poor velocity matching
            if result.velocity_achievement < 0.5:
                total_score -= 20.0
    
    return total_score / torpedo_results.size()
```

**Layer 2 Tuned Parameters by Type** (enhanced):

**Straight Torpedoes**:
- `navigation_constant_N`: Core PN parameter (2.0-4.0 range)
- `velocity_gain`: How aggressively to match velocity targets (0.0005-0.002)
- `thrust_smoothing`: Smooth thrust changes over time (0.1-0.3)

**Multi-Angle Torpedoes**:
- `navigation_constant_N`: Core PN parameter (3.0-5.0 range)
- `velocity_gain`: Velocity matching aggression (0.001-0.003)
- `flip_recognition_time`: How quickly to recognize flip maneuver (0.1-0.5s)
- `burn_thrust_profile`: Thrust curve during deceleration burn

**Simultaneous Impact Torpedoes**:
- `navigation_constant_N`: Core PN parameter (2.5-4.5 range)
- `velocity_gain`: Must be precise for timing (0.0008-0.0015)
- `terminal_velocity_boost`: Extra velocity gain for final approach (1.0-1.5)
- `coordination_factor`: How much to adjust for other torpedoes (0.0-1.0)

### **ManualTuningPanel.gd** (Layer 1 Trajectory Shaping)
**Why**: Layer 1 trajectory generation has physics parameters that need human judgment

**Layer 1 Manual Sliders by Type** (enhanced):

**Straight Torpedoes**:
- `velocity_profile_aggression` (0.5-1.0): How quickly to build velocity
- `terminal_velocity_target` (5000-50000 m/s): Desired impact velocity

**Multi-Angle Torpedoes**:
- `flip_burn_threshold` (3000-10000 m/s): When to trigger flip-burn
- `deceleration_target` (1000-3000 m/s): Target velocity after burn
- `arc_velocity_profile` (linear/exponential/s-curve): How to accelerate through arc

**Simultaneous Impact Torpedoes**:
- `extreme_angle_threshold` (45-75°): When angles require flip-burn
- `velocity_coordination` (0.0-1.0): How much to match velocities between torpedoes
- `impact_velocity_variance` (0-2000 m/s): Acceptable velocity difference at impact

## Data Flow (Complete with Velocity)

### Launch Sequence
1. **Launcher** creates torpedo with type and constraints
2. **Launcher** performs pre-flight physics analysis
3. **Torpedo** asks TrajectoryPlanner for waypoints
4. **TrajectoryPlanner**:
   - Simulates full trajectory with physics
   - Determines if flip-burn required (turn radius check)
   - Generates waypoints with positions + velocities + maneuver types
   - Validates physics before returning
5. **Torpedo** begins following waypoints with PN + velocity matching
6. **Visualizer** displays waypoints with velocity indicators

### Runtime Updates (Dynamic Rate)
- **TrajectoryPlanner** recalculates at 1-3 Hz based on time-to-impact
- **Update triggers**:
  - Timer based on time-to-impact (1-3 Hz)
  - Physics violation detection (immediate)
  - Major target velocity change (immediate)
- **Preserves** current waypoint and next 2 waypoints
- **Updates** all subsequent waypoints with smooth velocity transitions
- **Validates** physics on every update
- If trajectory becomes impossible, replans with flip-burn

## Key Improvements from v6.1

- **Physics-First Design** - Turn radius calculations drive all decisions
- **Velocity Profiles** - Each waypoint has position + velocity + maneuver type
- **Flip-and-Burn** - Core maneuver for impossible trajectories, not special case
- **Natural Alignment** - Emerges from proper velocity management
- **No Alignment Weights** - Removed entire competing objective system
- **Smart Layer 1** - Full physics simulation and validation
- **Simple Layer 2** - Just tracks waypoints and matches velocities
- **Complete Validation** - Every trajectory tested for physics feasibility

## Critical Implementation Notes

**DO NOT**:
- Add alignment weights anywhere
- Let torpedoes fly faster than physics allows for their trajectory
- Generate more than one flip-burn per approach (two absolute maximum)
- Let Layer 2 make strategic decisions
- Update waypoints the torpedo is about to reach
- Skip physics validation to save computation

**ALWAYS**:
- Check turn radius before planning trajectories
- Validate physics on every trajectory update
- Use flip-burn when turn radius exceeds safe limits
- Let Layer 1 handle all replanning decisions
- Smooth velocity transitions between waypoints
- Trust that proper velocity creates proper alignment

The ideal result: Torpedoes that navigate like expert Expanse pilots, using flip-and-burn when physics demands it, achieving "impossible" approach angles through intelligent velocity management, all while maintaining nose-forward flight for minimum PDC vulnerability. No magic, no arbitrary limits, just physics.
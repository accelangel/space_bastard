# Complete Torpedo System Refactor Plan

## Architecture Overview
**THREE SCRIPTS ONLY**:
1. `TorpedoFlightPlans.gd` - Static flight plan calculations
2. `Torpedo.gd` - Physics execution and control
3. `TorpedoLauncher.gd` - Spawning and configuration

**DELETE THESE FILES**:
- `TorpedoConfig.gd` 
- `TorpedoType.gd`

---

## 1. TorpedoFlightPlans.gd (Static Class)

**PURPOSE**: Calculate desired velocity vectors for different flight patterns. Returns where the torpedo SHOULD be going, not how to get there.

**CORE FUNCTIONS**:
```gdscript
static func calculate_straight_intercept(
    current_pos: Vector2, 
    current_vel: Vector2, 
    target_pos: Vector2, 
    target_vel: Vector2,
    max_speed: float
) -> Vector2:
    # Returns velocity vector pointing at intercept point
    # NO LATERAL COMPONENTS
    # NO THRUST CALCULATIONS
    # ONLY "where should I be going"

static func calculate_multi_angle_intercept(
    current_pos: Vector2,
    current_vel: Vector2, 
    target_pos: Vector2,
    target_vel: Vector2,
    max_speed: float,
    approach_side: int  # 1 for right, -1 for left
) -> Vector2:
    # Returns velocity that creates 45° impact angle
    # Arc trajectory, NOT straight line
    # Impact perpendicular to each other (90° apart)

static func calculate_simultaneous_impact_intercept(
    current_pos: Vector2,
    current_vel: Vector2,
    target_pos: Vector2, 
    target_vel: Vector2,
    max_speed: float,
    impact_time: float,  # When to hit
    impact_angle: float  # Assigned angle within 160° arc
) -> Vector2:
    # Returns velocity to hit at exact time and angle
    # Angles spread across 160° arc (80° each side)
    # Example: 8 torpedoes = 20° spacing
```

**WHAT IT DOES NOT DO**:
- ❌ NO thrust calculations
- ❌ NO rotation calculations  
- ❌ NO physics simulation
- ❌ NO lateral thrust vectors
- ❌ NO PID control

---

## 2. Torpedo.gd

**PURPOSE**: Execute physics with single-axis thrust and orientation control ONLY.

**PHYSICS MODEL**:
```gdscript
# State variables
var position: Vector2
var velocity: Vector2  # Current actual velocity
var orientation: float  # Direction torpedo is pointing
var max_rotation_rate: float = deg_to_rad(360)  # Can turn 360°/second
var max_acceleration: float = 1430.0  # 150G

# PID Controller for velocity error
var pid_kp: float = 5.0
var pid_ki: float = 0.5  
var pid_kd: float = 2.0
var integral_error: Vector2
var previous_error: Vector2

# Flight plan
var flight_plan_type: String  # "straight", "multi_angle", "simultaneous"
var flight_plan_data: Dictionary  # approach_side, impact_time, etc.
```

**PHYSICS LOOP EACH FRAME**:
1. Get desired velocity from flight plan
2. Calculate velocity error (desired - current)
3. Run PID on velocity error
4. PID output determines desired orientation
5. Rotate toward desired orientation (LIMITED by max_rotation_rate)
6. Thrust FORWARD ONLY in orientation direction
7. Update velocity: `velocity += thrust_direction * max_acceleration * delta`
8. Update position: `position += velocity * delta`

**CRITICAL PHYSICS RULES**:
- ✅ Torpedo can ONLY thrust in the direction it's pointing
- ✅ Torpedo must rotate to change thrust direction
- ✅ Rotation is limited by max_rotation_rate
- ✅ To change velocity by 90°, torpedo must rotate 90° and thrust
- ❌ NO lateral thrust components
- ❌ NO thrust vectoring
- ❌ NO magical velocity changes

**PROPER INTERCEPT CALCULATION**:
```gdscript
func calculate_realistic_intercept_point() -> Vector2:
    # Must account for:
    # - Current velocity (can't instantly change)
    # - Rotation time (can't instantly point elsewhere)
    # - Single-axis thrust only
    # Returns achievable intercept, not ideal intercept
```

---

## 3. TorpedoLauncher.gd

**PURPOSE**: Spawn torpedoes with correct initial conditions and flight plans.

**CONFIGURATION**:
```gdscript
@export var use_straight_trajectory: bool = true
@export var use_multi_angle_trajectory: bool = false  
@export var use_simultaneous_impact: bool = false
@export var auto_volley: bool = false  # MUST BE FALSE

# Fixed parameters
var torpedoes_per_volley: int = 8  # ALWAYS 8
var tubes_per_side: int = 4  # 4 port, 4 starboard
```

**VOLLEY BEHAVIOR**:
- Fire all 8 torpedoes in sequence
- NO multiple waves
- NO continuous fire
- ONE volley per manual trigger only

**SIMULTANEOUS IMPACT CALCULATION**:
```gdscript
func calculate_simultaneous_impact_data(target: Node2D) -> Dictionary:
    # 160° total arc (80° each side from ship centerline)
    # Divide by number of torpedoes
    # Example: 8 torpedoes = 160°/8 = 20° spacing
    # Returns: {
    #   impact_time: float,  # Same for all
    #   impact_angles: Array[float]  # One per torpedo
    # }
```

**LAUNCH SEQUENCE**:
1. Calculate initial velocity (ship velocity + lateral launch velocity)
2. Set initial orientation (ship forward direction)
3. Assign flight plan based on boolean flags
4. For simultaneous impact: calculate timing and angles
5. Spawn torpedo with ALL data

---

## Integration Notes

**MUST WORK WITH EXISTING**:
- Ship movement system (inherit ship velocity)
- PDC targeting system (torpedoes must be trackable)
- Collision system (must trigger on impact)
- Battle recording system (must log events)

**MUST NOT BREAK**:
- Torpedo collision detection
- PDC intercept calculations
- Ship acceleration inheritance
- Battle end detection

**PID TUNING APPROACH**:
- Start with moderate values (Kp=5, Ki=0.5, Kd=2)
- Test with different speeds (1000, 2000, 5000 m/s)
- Adjust if seeing oscillation (reduce Kp) or undershoot (increase Kp)
- NO auto-tuning initially, just manual testing

**SUCCESS CRITERIA**:
- ✅ All torpedoes hit their targets
- ✅ Multi-angle creates visible arc trajectories
- ✅ Simultaneous impact torpedoes hit within 0.1 seconds
- ✅ No "panic steering" at last second
- ✅ Smooth, predictable trajectories
- ❌ NO lateral thrust vectors in code
- ❌ NO magic velocity changes
- ❌ NO impossible physics

---

## Real Physics Philosophy

This torpedo system is designed to mimic **actual physics**, not gamified approximations. Every torpedo must obey Newton's laws:

1. **Momentum is conserved** - A torpedo traveling at 5 km/s cannot instantly change direction. It must rotate and thrust against its current velocity vector to alter its trajectory.

2. **Single-axis thrust reality** - Real spacecraft and missiles can only thrust in one direction (along their engine axis). To change direction, they must rotate first. This creates realistic curved trajectories as the torpedo "fights" its own momentum.

3. **No magic physics** - No lateral thrusters, no thrust vectoring, no impossible instant velocity changes. If a torpedo needs to turn 90 degrees, it must physically rotate 90 degrees first, then thrust.

4. **Scalable to extreme conditions** - While currently limited to 2000 m/s for testing, this system is designed to work at ANY speed. When we remove the speed limit and torpedoes accelerate at 150G for 8 minutes across 250,000 km maps, reaching speeds of 700+ km/s, the physics will still be accurate. The PID controller will naturally adapt, requiring more aggressive orientation changes at higher speeds, creating realistic high-energy intercept trajectories.

5. **True intercept calculation** - The system must solve the real physics problem: "Given my current velocity vector, my thrust limitations, and my rotation constraints, what is the earliest possible intercept point?" This is the same calculation real missile guidance systems perform.

This approach ensures that whether we're testing at 1 km/s or operating at 700 km/s in massive fleet engagements, the torpedoes behave according to real physics, creating authentic and predictable behavior that players can learn and master.
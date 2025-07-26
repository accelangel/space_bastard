# MPC Torpedo System Implementation Plan

## Project Context

Space Bastard is a physics-based space combat game inspired by The Expanse, featuring realistic space warfare at extreme scales. The game currently uses PID-controlled torpedoes that struggle to hit targets maneuvering at 10G acceleration. This document outlines the complete replacement of the PID system with Model Predictive Control (MPC) to achieve reliable hits against highly maneuverable targets.

### Why MPC Over PID

**PID Limitations:**
- Only reacts to current error (position difference)
- Cannot anticipate future target positions beyond simple linear prediction
- Struggles with complex trajectory requirements (multi-angle attacks, simultaneous impacts)
- No concept of "planning ahead" - just chases the error

**MPC Advantages:**
- Plans entire trajectory from current position to impact
- Can enforce complex constraints (approach angles, impact timing)
- Naturally handles the three torpedo types through different cost functions
- Sees the "whole picture" rather than just the current error

## Core Design Philosophy

### Simplicity First
We're not implementing every possible MPC feature. The goal is to reliably hit 10G maneuvering targets with three specific attack patterns. No fuel optimization, no PDC dodging (yet), no predictive target modeling. Just clean, effective trajectories.

### GPU-Accelerated Trajectory Evaluation
The RTX 3080's 8,704 CUDA cores can evaluate thousands of trajectories in parallel. Instead of the CPU struggling with sequential calculations, we'll evaluate 20-30 trajectory templates per torpedo simultaneously on the GPU.

### Learning Through Tuning
Rather than hand-coding trajectory shapes, the MPC tuner will discover optimal templates through iterative testing. This ensures the trajectories are perfectly suited to the game's specific physics and requirements.

## Technical Architecture

### 1. Sliding Window Horizon

**The Problem:** 
An 8-minute flight at 0.1s resolution would require 4,800 steps - computationally impossible.

**The Solution:**
```
Near Future (0-30 seconds): 0.1s resolution (300 steps)
Far Future (30s-end): 1.0s resolution (~450 steps for 8-minute flight)
Total: ~750 steps maximum
```

**Why This Works:**
- Immediate maneuvers need precise control (0.1s)
- Distant trajectory only needs rough planning (1.0s)
- Window slides forward each update, always maintaining detail where needed
- Computational cost stays constant regardless of flight duration

### 2. Trajectory Templates

Instead of generating random control sequences, we use structured templates based on the desired flight patterns:

#### Standard Torpedo Template
**Purpose:** Direct intercept with minimal complexity
**Implementation:**
- Base trajectory: straight line to predicted intercept point
- Variations: ±10% thrust, ±5° initial angle
- Always maintains alignment with velocity vector

#### Multi-Angle Template
**Purpose:** Create 90° separated impact vectors
**Flight Phases:**
1. **Direct Phase (0-50%):** Build speed toward target area
2. **Arc Phase (50-90%):** Curve to assigned side (port/starboard)
3. **Impact Phase (90-100%):** Align with final attack vector

**Key Constraint:** Port and starboard groups must impact perpendicular to each other

#### Simultaneous Impact Template
**Purpose:** All 8 torpedoes hit within 0.1 seconds
**Flight Phases:**
1. **Fan Phase (0-40%):** Spread to assigned angles (20° spacing)
2. **Cruise Phase (40-80%):** Maintain formation while approaching
3. **Converge Phase (80-100%):** All curve inward to impact simultaneously

**Key Constraint:** All torpedoes share the same calculated impact time

### 3. Trajectory Recycling

**Why:** Starting from scratch each frame wastes computation
**How:**
1. Take the optimal trajectory from last frame
2. Shift it forward by 100ms (remove first step, extrapolate last)
3. Generate 20-30 variations around this baseline
4. Evaluate variations to find improvements

**Benefits:**
- Smooth trajectory evolution
- 10x fewer candidates needed
- Natural trajectory continuity

### 4. Cost Function Design

The cost function tells MPC what "good" means. Lower cost = better trajectory.

#### Core Components (All Torpedoes)

**Distance Cost:**
```
cost += (predicted_impact_point - target_position)²
```
Minimizes miss distance

**Control Smoothness:**
```
cost += thrust_changes² + rotation_changes²
```
Prevents jerky, inefficient flight

**Orientation-Velocity Alignment:**
```
alignment_error = |torpedo.orientation - torpedo.velocity.angle()|
cost += alignment_error * weight
```
**Why This Matters:**
- Aligned torpedo = smaller cross-section for PDCs
- Aligned impact = proper nose-first hit
- Aligned flight = more efficient physics

#### Type-Specific Costs

**Multi-Angle Addition:**
```
angle_separation = |port_impact_angle - starboard_impact_angle|
cost += (angle_separation - 90°)² * weight
```

**Simultaneous Addition:**
```
time_variance = variance(all_impact_times)
cost += time_variance * weight
angle_adherence = |assigned_angle - actual_approach_angle|
cost += angle_adherence² * weight
```

### 5. Phase-Based Weight Adjustment

Different flight phases need different priorities:

```
progress = distance_to_target / initial_distance

if progress > 0.9:  # Final 10%
    alignment_weight *= 10  # MUST be aligned for impact
    accuracy_weight *= 10   # MUST hit target
elif progress > 0.5:  # Maneuvering phase
    alignment_weight *= 0.5  # Allow turning
    trajectory_weight *= 2   # Follow the planned curve
```

This creates natural behavior:
- Early flight: Efficient cruise
- Mid flight: Execute required maneuvers
- Final approach: Perfect alignment and accuracy

## MPC Tuning System

### Purpose
Discover optimal trajectory templates and cost function weights through automated testing against 10G maneuvering targets.

### Tuning Process

#### State Machine
```
IDLE → TUNING_STANDARD → TUNING_MULTI_ANGLE → TUNING_SIMULTANEOUS → COMPLETE
```

Each state requires 100 consecutive "perfect" cycles where:
- All 8 torpedoes hit the target
- All parameters within 1% of optimal

#### What Gets Tuned

1. **Trajectory Templates**
   - Start with 100s of random variations
   - Track success rates
   - Evolve toward optimal shapes
   - Condense to 10-20 best templates

2. **Cost Weights**
   - Distance weight
   - Control weight
   - Alignment weight
   - Type-specific weights

3. **Phase Transitions**
   - When to start arcing (multi-angle)
   - When to begin convergence (simultaneous)
   - When to prioritize alignment

4. **Window Parameters**
   - Detailed window size
   - Resolution transitions
   - Update frequency

### Learning Algorithm

**Evolutionary Approach:**
1. **Generation 1:** Random templates and weights
2. **Selection:** Keep best 50% based on success rate
3. **Mutation:** Create variations of successful templates
4. **Innovation:** Add 10% completely new templates
5. **Repeat:** Until convergence

**Perfection Refinement (99% → 99.99%):**
Even "perfect" cycles can improve:
- Reduce trajectory roughness
- Minimize computation time
- Improve impact precision
- Enhance alignment throughout flight

### File Persistence

Tuned parameters saved to JSON:
```json
{
  "torpedo_type": "multi_angle",
  "tuning_stats": {
    "cycles_to_converge": 487,
    "final_success_rate": 99.97,
    "avg_compute_time_ms": 8.2
  },
  "templates": [
    {
      "id": "arc_aggressive",
      "success_rate": 0.994,
      "control_points": [...]
    }
  ],
  "cost_weights": {
    "distance": 1.0,
    "control": 0.1,
    "alignment": 5.0,
    "angle_separation": 10.0
  },
  "phase_transitions": [0.5, 0.9]
}
```

## Implementation Steps

### Step 1: Core MPC Framework
1. Create sliding window trajectory representation
2. Implement basic GPU compute pipeline
3. Set up cost function evaluation
4. Test with single torpedo, static target

### Step 2: Trajectory Templates
1. Implement standard (straight) template
2. Add multi-angle arc templates
3. Add simultaneous fan/converge templates
4. Verify each matches intended flight pattern

### Step 3: GPU Optimization
1. Create compute shader for parallel evaluation
2. Optimize memory layout for coalesced access
3. Implement trajectory recycling
4. Benchmark performance

### Step 4: MPC Tuner
1. Port PID tuning infrastructure to MPC
2. Implement evolutionary learning
3. Add parameter persistence
4. Create detailed logging/analysis

### Step 5: Integration
1. Replace PID torpedoes with MPC in tuning mode
2. Verify all three types work correctly
3. Run full tuning sequences
4. Save optimal parameters

### Step 6: Battle Mode
1. Load tuned parameters
2. Test in actual combat scenarios
3. Verify performance against 10G targets
4. Compare hit rates to PID system

## Why This Approach Will Succeed

### Computational Efficiency
- 20-30 templates vs 1000s of random trajectories
- GPU parallel evaluation vs CPU sequential
- Trajectory recycling vs fresh generation
- Learned templates vs brute force search

### Physical Realism
- Respects rotation rate limits
- Maintains velocity continuity
- Enforces proper alignment
- Creates believable flight paths

### Adaptability
- Templates evolve through tuning
- Weights adjust to game physics
- System learns what works
- No hand-tuning required

### Scalability
- Fixed computational cost per torpedo
- Handles 100+ simultaneous torpedoes
- Works at any engagement range
- Adapts to different target speeds

## Success Metrics

### Tuning Success
- 100 consecutive perfect volleys per type
- <1% error on all parameters
- <10ms computation per torpedo
- Stable, converged templates

### Combat Success
- >95% hit rate vs 10G targets
- Proper approach angles maintained
- Smooth, realistic trajectories
- No "sideways bonking" impacts

### Performance Success
- 60 FPS with 100+ torpedoes
- <1GB GPU memory usage
- Consistent frame timing
- No CPU bottlenecks

## Future Enhancements (Post-MVP)

Once this system works:
1. **PDC Avoidance:** Add threat fields to cost function
2. **Predictive Targeting:** Model target evasion patterns
3. **Collaborative Targeting:** Torpedoes share information
4. **Terminal Guidance:** Special last-second maneuvers
5. **Adaptive Difficulty:** Tune AI torpedo intelligence

But first, we need the foundation: MPC torpedoes that reliably hit 10G targets with beautiful, aligned trajectories that match your three distinct attack patterns.

## Conclusion

This plan transforms Space Bastard's torpedoes from reactive PID chasers to intelligent MPC planners. By focusing on the core challenge (hitting 10G targets), using GPU acceleration wisely, and letting the system learn optimal strategies, we create a robust foundation for all future torpedo enhancements.

The key insight: MPC doesn't need to be complex to be effective. With smart templates, trajectory recycling, and learned parameters, we can achieve superior performance with reasonable computational cost.
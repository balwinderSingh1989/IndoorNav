# How Indoor Navigation Works

The app combines four kinds of information:

- **BLE RSSI**: which beacons are visible and how strong their signals are.
- **The beacon graph**: which beacons are connected by walkable corridors.
- **PDR**: step-based movement between confirmed beacon anchors.
- **Position estimates**: a location estimate made from three, two, or one visible beacon.

BLE and position estimates provide evidence. The navigation controller decides
when that evidence is strong enough to change the navigation anchor.

## 1. The map is loaded from JSON

The store JSON contains:

- beacon IDs, BLE IDs, names, and map positions;
- edges connecting walkable beacon pairs;
- `distanceMeters` for every edge;
- optional waypoints for corridors that bend around walls;
- item and destination metadata.

An edge such as:

```json
{
  "from": "b2",
  "to": "b7",
  "distanceMeters": 6
}
```

means that the user can walk between `b2` and `b7` and that the physical
segment is 6 metres long. Edges are treated as an undirected graph for
routing, unless the data says otherwise through a future routing rule.

The graph is used for:

- shortest-path calculation;
- direct-neighbor checks;
- physical reachability checks;
- route drawing and route progress;
- rejecting impossible beacon jumps.

The app does not infer walkable corridors from the SVG alone. The JSON graph
and its waypoints define the walkable path.

## 2. BLE observations are normalized

The scanner discovers nearby BLE devices and reports RSSI readings. The
scanner maps each device to the stable beacon identity used by the store map.
The navigation engine consumes a map similar to:

```text
{
  "b2": -61.5,
  "b7": -70.2,
  "b3": -82.0
}
```

The raw device address is not used as the navigation identity. Readings are
filtered, averaged, and removed when they become stale. The controller then
applies RSSI smoothing so one noisy BLE packet cannot immediately move the
user.

Every RSSI update follows this broad order:

1. Smooth the current RSSI values.
2. Update the route-constrained visual position.
3. Evaluate whether the user appears off route.
4. Update current-beacon and candidate RSSI state.
5. Update the RSSI trend for the immediate next route beacon.
6. Apply BLE-based visual progress correction.
7. Select a normal navigation candidate.
8. Validate and possibly commit a beacon transition.

The off-route check happens before normal candidate selection because a valid
reroute may replace the current route and anchor during the same update.

## 3. There are two navigation modes

The controller behaves differently depending on whether a destination exists.

### Mode A: free roam, with no destination

There is no active route. The controller can choose among all known visible
beacons, subject to RSSI and switching safety rules.

### Mode B: destination navigation

There is an active destination and route. After the current beacon is known,
normal beacon selection is route-constrained. A globally strong beacon that is
not the next valid route beacon cannot normally pull the user across the map.

These modes must not be confused: free-roam selection is global RSSI ranking;
destination navigation is route-aware selection.

## 4. Free-roam and single-beacon selection

This is the process used when there is no destination, including the initial
selection of a beacon.

### 4.1 Initial beacon selection

When there is no current beacon:

1. Keep only RSSI observations that map to known beacons.
2. Sort visible beacons from strongest RSSI to weakest RSSI.
3. Select the strongest valid beacon as the initial anchor.
4. Snap the visual position to that beacon.
5. Start tracking movement from that anchor.

There is no route yet, so adjacency and route-order restrictions do not apply
to this first fix.

### 4.2 Switching while free roaming

When a current beacon already exists, observations are considered in RSSI
order. The first candidate that passes the configured comparison is used.

For every possible new beacon:

1. Ignore the current beacon itself.
2. Compare the candidate RSSI with the current beacon RSSI.
3. Require the configured RSSI margin.
4. Use the adjacent-beacon margin when the candidate is directly connected.
5. Use the standard margin for a non-adjacent candidate.
6. Require the configured confirmation readings and persistence duration.
7. Apply switch cooldown and other anti-flapping gates.

The candidate does not become the current beacon merely because it is the
strongest visible signal. It must remain competitive and stable long enough to
show that the user has probably entered the new beacon area.

### 4.3 Free-roam commit

After all gates pass, the controller commits:

```text
currentBeacon = candidate
```

It then:

- resets segment distance;
- resets PDR progress and step counters;
- resets the next-beacon RSSI trend;
- resets the visual route-position estimator;
- clears the pending beacon-switch candidate;
- updates the UI and zone event.

## 5. Position estimation from visible beacons

RSSI selection and geometric position estimation are related but different.
RSSI identifies useful beacon anchors. The position estimator calculates a map
position from the beacons currently visible.

### 5.1 Solved estimate: three or more beacons

When enough known beacons are visible, the estimator can solve a multi-beacon
position. The result includes:

- estimated map position;
- estimation method;
- contributor count;
- residual error.

Solved estimates are the strongest position evidence, but they still pass
residual, route-deviation, movement-jump, and reachability checks before they
can trigger a reroute.

### 5.2 Two-beacon weighted-centroid estimate

When only two known beacons are visible, the engine can use a weighted
centroid estimate if sparse fallback is enabled. This is less precise than a
solved estimate, so it uses more conservative deviation, persistence, margin,
and confirmation rules.

The two-beacon estimate can support:

- visual route correction;
- cautious off-route evidence when configured;
- continued navigation while triangulation is temporarily incomplete.

It does not by itself authorize an arbitrary beacon jump.

### 5.3 Single-beacon estimate

When only one known beacon is visible, the engine can use that beacon as a
single-beacon position estimate if single-beacon fallback is enabled.

This estimate is intentionally conservative because one beacon cannot reliably
prove a two-dimensional position. It must still satisfy:

- single-beacon minimum RSSI;
- minimum route deviation;
- candidate persistence and confirmation readings;
- candidate margin rules where applicable;
- graph reachability from the current anchor;
- maximum anchor-distance limits.

Single-beacon evidence can help recover when the BLE scan is sparse, but it is
not treated as equivalent to a three-beacon solve.

## 6. Choosing a destination

When the user selects a destination:

1. Store the destination beacon.
2. Reset route-tracking and pending-switch state.
3. Set the status to rerouting while the initial route is prepared.
4. If a current beacon exists, ask the pathfinder for a route.
5. If there is no current beacon yet, wait for the initial BLE fix.

The pathfinder uses Dijkstra-style shortest-path search over the beacon graph.
For example:

```text
Seating 2-A -> Seating 2 -> Reception-2 -> Reception -> Safari
```

The route contains both beacon order and total edge distance.

## 7. Normal destination candidate selection

Once a destination and current beacon exist, the controller does not simply
choose the strongest beacon in the entire store.

Let the current route be:

```text
current -> next -> secondary -> ... -> destination
```

### 7.1 Immediate next beacon

The immediate next beacon is the normal candidate. The controller checks its
RSSI and tracks its trend, but route order prevents a distant strong beacon
from becoming a normal handoff.

### 7.2 Secondary look-ahead

A secondary route beacon may be selected only when the configured look-ahead
policy allows it. The relevant evidence includes:

- route look-ahead is enabled;
- a secondary beacon exists;
- both primary and secondary RSSI values are present;
- the primary beacon has genuinely been passed;
- the secondary has enough RSSI lead over the primary;
- the secondary remains valid under the later hop checks.

Look-ahead is controlled. It is not permission to skip arbitrary route nodes.

### 7.3 PDR endpoint preference

If PDR reaches the physical end of the current segment, the immediate next
route beacon is preferred before secondary look-ahead.

For example:

```text
current = Seating 2-A
next = Seating 2
segment length = 10 m
PDR progress = 10 m
```

Even if `Seating 2-A` still has stronger RSSI, `Seating 2` is selected when it
has a live RSSI observation. This prevents a weak next beacon from being
ignored after the user has physically reached its segment endpoint.

PDR preference does not bypass all safety checks. The selected beacon still
passes physical proximity, route-order, persistence, cooldown, and
anti-teleport validation before commit.

### 7.4 Pending candidate stability

Once a route candidate starts accumulating confirmation readings, the
controller keeps that candidate stable across temporary RSSI fluctuations.
This prevents a brief signal spike from replacing a candidate and resetting
its persistence counter.

If the candidate changes, the pending candidate ID and confirmation count are
replaced for the new candidate.

## 8. Validating a normal beacon transition

Selecting a candidate is not the same as committing it. The candidate must
pass the switch validator.

The validator checks, as applicable:

1. A current beacon and destination exist.
2. The candidate is on the active route.
3. The candidate is normally the immediate next route beacon.
4. A secondary hop satisfies the controlled look-ahead rules.
5. Candidate and current RSSI values are available.
6. RSSI margin and trend rules are satisfied, unless the PDR endpoint rule
   provides the supported endpoint exception.
7. The candidate is physically plausible from the current anchor.
8. The candidate does not require a teleport over route nodes.
9. The candidate has not already been passed according to the live position.
10. Persistence, required readings, and switch cooldown pass.

If validation fails, the pending normal switch state is cleared. This prevents
old confirmation readings from accumulating across invalid periods.

## 9. Normal beacon commit

Only after validation and persistence succeed does the controller change the
navigation anchor:

```text
currentBeacon = candidate
```

At that exact handoff it:

1. Records any completed segment calibration.
2. Resets `_metersSinceBeacon`.
3. Resets `_segmentProgressMeters`.
4. Resets the PDR step count and last-step timing.
5. Resets the immediate-next RSSI trend to unknown.
6. Clears the off-route detector's pending candidate and position baseline.
7. Recomputes the route from the new anchor.
8. Snaps or corrects the visual position to the new beacon.
9. Clears the RSSI EMA so the next segment starts fresh.
10. Emits the beacon/zone event and notifies the UI.

Resetting the off-route detector here is important for fast walking. Evidence
collected around the previous anchor must not be reused after the user has
entered a new beacon segment.

## 10. PDR tracks movement between anchors

BLE identifies anchor beacons but is too noisy to draw smooth movement by
itself. The pedometer fills in the movement between the current beacon and the
next route beacon.

For every accepted step, the controller updates:

- total metres since the current beacon;
- visual segment progress;
- step count;
- movement direction and confidence where available.

The physical distance used for reachability can continue to accumulate, while
visual progress is clamped to the current edge length. This prevents the arrow
from moving beyond the next beacon before that beacon is confirmed.

PDR does not directly change `currentBeacon`. It only supplies movement
evidence. A BLE observation and the normal transition gates still confirm the
new anchor.

If off-route evidence is pending, PDR can be paused for off-route evaluation
so the UI does not continue presenting confident route progress while the
controller is deciding whether the user left the route.

## 11. BLE progress corrects the visual position

The controller compares current-beacon RSSI with next-beacon RSSI to estimate
where the user is between anchors. That estimate is bounded and blended with
PDR progress.

This BLE progress correction can move the visual marker smoothly, but it does
not itself commit a beacon. The marker and the navigation anchor are separate:

- the marker can be near the end of a segment;
- PDR can report the endpoint;
- the anchor changes only after the transition gates pass.

RSSI trend is supporting evidence. A weakening trend should not automatically
block a PDR-supported endpoint handoff, because the next beacon can remain
weak or noisy even after the user reaches it.

## 12. Off-route detection and rerouting

Off-route detection is separate from normal route progression. It is used when
the estimated position is meaningfully away from the active route.

### 12.1 Off-route prerequisites

The detector requires:

- off-route detection enabled;
- a destination;
- a current beacon;
- a route with at least two beacons;
- a valid solved, sparse, or configured single-beacon estimate;
- no active off-route cooldown.

The position must remain sufficiently far from the route. A single large
position jump is rejected, and sustained deviation is required.

### 12.2 Local candidate rule

Off-route recovery is local to the current anchor. Candidates must be direct
graph neighbors of the current beacon.

For normal solved or sparse estimates, the detector excludes:

- the current beacon;
- beacons already in the active route;
- beacons that are not direct neighbors of the current beacon.

This prevents a distant beacon from winning only because it has a stronger
RSSI signal.

The immediate route-next beacon belongs to normal route handoff, not off-route
rerouting. PDR endpoint preference handles that case.

Single-beacon fallback uses a more permissive ranking stage because only one
signal is available, but it still rejects a strongest candidate that is not an
allowed local alternative or is already part of the current route.

### 12.3 Off-route persistence and reachability

After local candidate filtering, the detector applies:

1. minimum candidate RSSI;
2. candidate margin when multiple candidates are visible;
3. graph distance from the current anchor;
4. maximum reachable anchor distance;
5. required consecutive readings;
6. required persistence duration;
7. cooldown after a completed decision.

The detector returns an `OffRouteDecision`; it does not mutate the navigation
controller itself.

### 12.4 Reroute commit

When a decision is returned:

1. `RerouteService` asks the pathfinder for a route from the candidate anchor
   to the destination.
2. An empty path rejects the decision.
3. A valid path makes the candidate the new `currentBeacon`.
4. The new path and route distance replace the old route.
5. PDR distance, segment progress, step timing, and route-position estimator
   reset.
6. The visual marker snaps to the new anchor.
7. The status returns to navigating, or becomes arrived if the candidate is the
   destination.
8. The UI and zone event are updated.

The detector's completed-decision cooldown is preserved after rerouting so a
single noisy update cannot immediately trigger another reroute.

The same RSSI update continues through normal RSSI processing after a
successful reroute. This allows the new route to begin evaluating immediately.

## 13. Arrival and missing confirmations

When the committed beacon equals the destination:

- navigation status becomes `arrived`;
- arrival is locked;
- neighboring beacon signals cannot pull the controller away from the
destination.

If the visual marker reaches the end of a segment but the next beacon is not
confirmed for the configured timeout, the UI can enter a waiting or checking
state instead of silently freezing. A later valid beacon observation can then
resume normal route correction or trigger a guarded recovery.

## 14. Waypoints and map drawing

An edge can contain intermediate waypoints:

```text
b2 -> waypoint 1 -> waypoint 2 -> b7
```

Waypoints are not additional routing beacons. They describe the shape of the
corridor for:

- drawing the route;
- placing the visual marker;
- snapping movement to the corridor;
- avoiding a straight line that would cut through a wall.

The pathfinder still routes between real beacon nodes.

## 15. Heading and step safety

Compass and gyroscope data can help estimate the phone's heading. Heading is
treated as a heuristic, not proof of walking direction, because the phone may
be held sideways, placed in a pocket, or pointed away from the user's travel
direction.

When heading strongly disagrees with the next route direction, the controller
can temporarily reject a step for forward progress. This protects against
obvious backward movement without making the navigation unusable when the
phone orientation is imperfect.

## 16. Stride calibration

When a valid beacon-to-beacon segment completes, the controller can compare:

```text
measured beacon-to-beacon distance
----------------------------------
       accepted step count
```

with the current stride estimate. Recent samples are retained and combined
using a robust statistic such as the median, so one noisy transition does not
immediately change the user's stride calibration.

## 17. Complete example: Seating 2-A to Safari

Suppose the route is:

```text
Seating 2-A -> Seating 2 -> Reception-2 -> Reception -> Safari
```

### Normal movement to Seating 2

1. `currentBeacon` is `Seating 2-A`.
2. The immediate route-next beacon is `Seating 2`.
3. PDR reports progress toward the next segment.
4. `Seating 2` is visible but weak, for example `-87 dBm`.
5. `Seating 2-A` may still be stronger, for example `-75 dBm`.
6. When PDR reaches the segment endpoint, the selector prefers `Seating 2`.
7. The validator checks that the beacon is visible, physically plausible, and
   not a teleport.
8. Persistence and cooldown must still pass.
9. The controller commits `Seating 2` and resets the old segment state.

### Genuine off-route movement near Seating 2-A

Assume the current anchor is `Seating 2-A` and the visible signals are:

```text
Reception: -50 dBm
Breakout:  -62 dBm
Seating 2: -70 dBm
```

If `Reception` is not a direct graph neighbor of `Seating 2-A`, it cannot be
selected as an off-route anchor just because its RSSI is strongest. Only local
direct neighbors remain eligible, and the position deviation, persistence,
margin, and reachability checks still apply.

### Rerouting to Safari

If the user is confirmed away from the active route near a valid local beacon:

1. The detector persists the deviation and candidate.
2. The candidate is returned as an off-route decision.
3. The controller asks for a new path from that candidate to `Safari`.
4. If the path exists, the candidate becomes the new anchor.
5. PDR and route progress reset.
6. Navigation continues on the new route.

## 18. The complete rule in one paragraph

BLE identifies visible beacons, RSSI ranking proposes candidates, position
estimates provide geometric evidence, the graph limits legal movement, and PDR
tracks progress between anchors. Free roam can select the strongest valid
visible beacon globally. Destination navigation normally selects the immediate
next route beacon, prefers it at a PDR segment endpoint, and permits only
controlled secondary look-ahead. Off-route recovery is persistent and local to
direct neighbors, then reroutes through the graph. No candidate changes the
navigation anchor until validation, persistence, reachability, and safety
checks pass; every confirmed handoff resets the state that belongs to the
previous segment.

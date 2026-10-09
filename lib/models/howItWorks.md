Simple explanation
The app works like a road map made from beacons.

1. The JSON is the map
Each beacon has a position:


This tells the app where to draw it on the SVG map.

Each edge connects two beacons:


This means:

The user can walk from b2 to b7, and the corridor distance is 6 meters.

The edges define the legal walking network.

2. The user chooses a destination
The user selects a destination beacon, for example b7.

The app then asks:

From the beacon where the user is now, what is the shortest route to b7?

The pathfinder checks all connected edges and produces a route such as:


It adds the edge distances to calculate the total distance.

3. BLE finds the user’s current beacon
The phone scans for nearby BLE beacons.

The app receives signal strengths such as:


The strongest signal is usually treated as the beacon nearest to the user.

The app does not switch immediately. A new beacon must:

be noticeably stronger
appear in multiple readings
remain stable for a short period
not be a beacon the user already passed
This prevents random RSSI noise from moving the user backward and forward.

4. The app calculates a route
When the current beacon is confirmed, the app calculates:


If the user is detected near a different beacon while navigating, the app can recalculate from that new beacon. This is the current off-route recovery behavior.

For example:


This works only if the JSON contains valid edges connecting those beacons.

5. The pedometer moves the user between beacons
BLE is good for finding known anchor points, but it is not smooth enough to track every step.

The pedometer fills in the movement between beacons.

The app currently assumes:


If the user takes four steps:


The app adds that distance to the current route segment.

6. Movement is limited by the edge distance
Suppose the user is travelling from b2 to b7:


The app tracks:


It will not allow progress beyond 6 meters, even if the pedometer reports extra steps.

When the next beacon is confirmed, that beacon becomes the new starting anchor and progress resets to zero.

7. The arrow is placed on the map
The app converts the progress into a percentage.

For example:


The arrow is placed halfway along the edge.

For a straight edge:


the arrow moves halfway between the two beacon coordinates.

For an edge with waypoints:


the arrow now follows that bent path instead of cutting directly through the middle.

8. Waypoints avoid walls
Waypoints are manually added to an edge when the corridor bends:


The route becomes:


The same path is used for:

drawing the route
moving the arrow
snapping movement to the corridor shape
The app does not automatically read walls from the SVG. The JSON graph and waypoints define the safe walking path.

9. The app handles pauses and missing beacon confirmations
If the arrow reaches the end of a segment but the next beacon is not confirmed for about 5 seconds, the status changes to:


This prevents the arrow from silently staying frozen at the edge.

The app can then use a later beacon reading to recalculate the route.

10. The app handles heading cautiously
The app listens to compass and gyroscope data to estimate the phone’s heading.

If the heading appears strongly opposite to the next route direction, the app temporarily ignores that step for forward progress.

This helps with backward movement, but it is only a heuristic because:

the phone may be held sideways
the phone may be in a pocket
the user may look in another direction while walking
So the heading is not treated as perfect proof of walking direction.

11. The app calibrates stride gradually
When a valid beacon-to-beacon segment is completed, the app can calculate:


For example:


It keeps recent samples and uses their median, so one inaccurate beacon confirmation does not immediately corrupt the calibration.

The whole process

In short:

JSON edges define where the user may walk.
distanceMeters defines how long each corridor segment is.
BLE provides known location anchors.
Pedometer tracks movement between anchors.
Waypoints keep routes around walls.
Dijkstra chooses the route.
Beacon confirmations correct drift.
Status states tell the user when the app is navigating, recalculating, checking location, or has arrived.
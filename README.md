# Indoor Navigation — MVP Skeleton

BLE beacon → RSSI scan → zone snap → Dijkstra pathfinding → SVG map render → UI.

## Architecture

```
lib/
  models/
    beacon.dart            Beacon (id, bleId, major/minor, name, position)
    item.dart               Item (name, beaconId, category) — a searchable thing, its nearest beacon, and its display category
    store_map.dart          StoreMap + Edge, loaded from store_data.json
  services/
    store_data_repository.dart   Loads assets/store_data.json
    ble_scanner_service.dart     flutter_reactive_ble scan, 3s rolling RSSI avg
    motion_service.dart          pedometer step distance + gyroscope/compass fused heading
    zone_snap_service.dart       RSSI -> distance -> trilaterated position + nearest beacon
    pathfinding_service.dart     Dijkstra over the beacon graph
    navigation_controller.dart   Wires the above into app state (ChangeNotifier)
  ui/
    screens/home_screen.dart       Search, live map preview, categories (by item type or zone)
    screens/category_screen.dart   Items within one category -> pick one to navigate
    screens/navigation_screen.dart Full-screen live tracking view
    widgets/live_navigation_card.dart  Status + map + directions, shared by home_screen and navigation_screen
    widgets/map_painter.dart     CustomPainter: user pin + route overlay
    widgets/item_search_delegate.dart   Search-as-you-type over items -> sets destination
    widgets/item_tile.dart       Reusable tappable item row (icon, title, subtitle)
    widgets/section_header.dart  Reusable section label row
    utils/icon_lookup.dart       Keyword -> Material icon heuristics (cosmetic only)
  app.dart / main.dart
assets/
  store_data.json           Beacons, aisle graph, and searchable items (edit this per store)
  floorMap.svg               Real floor plan, 297x210 (landscape) coordinate space
```

## Screens

`HomeScreen` → `CategoryScreen` → `NavigationScreen`, all sharing the one
`NavigationController` instance created in `app.dart` (BLE/motion tracking
starts once, in `HomeScreen.initState`, and runs for the app's whole
lifetime regardless of which screen is on top).

- **`HomeScreen`**: search bar, a live map preview (`LiveNavigationCard` —
  the same widget `NavigationScreen` uses, so the two never show
  inconsistent state), and a **Categories** grid. The grid defaults to
  grouping by `Item.category` (`_GroupBy.item`); the segmented control next
  to the "Categories" header switches to grouping by zone/beacon instead
  (`_GroupBy.zone`) — both computed client-side in `_categoriesFor`
  (`lib/ui/screens/home_screen.dart`), not stored anywhere.
- **`CategoryScreen`**: every item in one category. Under item-type
  grouping, a category's items can span several beacons (e.g.
  "Electronics" has items in both the ChatGPT Room and the SOC Room), so
  each row shows its *own* room as a subtitle rather than one blanket
  location — that's why `CategoryScreen` takes a `StoreMap` rather than a
  single `Beacon`.
- **`NavigationScreen`**: the dedicated full-screen live view, reached
  after picking an item via search or a category — both call
  `NavigationController.setDestination` before pushing this screen.
- **Refresh on close**: `_HomeScreenState` mixes in `WidgetsBindingObserver`
  and calls `NavigationController.clearDestination()` on
  `AppLifecycleState.paused`/`detached` — leaving the app (backgrounding
  it, or on the way to being fully closed) drops the in-progress
  destination/route, so coming back starts fresh instead of resuming
  whatever was being navigated to before. BLE/PDR tracking itself isn't
  affected — only the chosen destination/path resets, via the same public
  `clearDestination()` the manual refresh button already used.

## Setup

```
flutter pub get
```

### BLE permissions

Declared already, but both layers matter — the manifest/plist entries alone
are not enough, the app must also request them at runtime:

- **Android** (`android/app/src/main/AndroidManifest.xml`): `BLUETOOTH_SCAN`,
  `BLUETOOTH_CONNECT`, `ACCESS_FINE_LOCATION` (plus legacy `BLUETOOTH` /
  `BLUETOOTH_ADMIN` for API < 31, which the `flutter_reactive_ble` plugin's
  own manifest already contributes).
- **iOS** (`ios/Runner/Info.plist`): `NSBluetoothAlwaysUsageDescription` /
  `NSBluetoothPeripheralUsageDescription`.
- **Runtime request**: `BleScannerService.startScan()`
  (`lib/services/ble_scanner_service.dart`) requests these via
  `permission_handler` before scanning, and emits a message on
  `BleScannerService.errors` if the user denies one — both `HomeScreen`
  and `NavigationScreen` listen and show it as a `SnackBar`, so it surfaces
  wherever the user currently is. If you deny a permission once, most OSes
  won't prompt again automatically; grant it manually in system settings
  and restart the app.

## Wiring real beacons

Edit `assets/store_data.json`:
- `beacons[].bleId` is the beacon's iBeacon identity as
  `"uuid:major:minor"`, e.g. `"01020304-0506-0708-090a-0b0c0d0e0f10:256:1"`
  — matched by `parseIBeacon()` in `lib/services/ble_scanner_service.dart`,
  which decodes the UUID/major/minor straight out of the advertisement's
  manufacturer data. A beacon fleet commonly shares one UUID and is
  differentiated only by minor, so the UUID alone isn't a safe key — always
  set all three. Confirmed working for `b1` (verified against nRF Connect's
  raw advertisement view: Company `Apple, Inc. <0x004C>`, Type `Beacon
  <0x02>`, UUID `01020304-...`, Major `256`, Minor `1`); `b2`–`b4` are now
  confirmed against their real physical positions too. If you re-wire
  beacons later and need to re-diagnose, `BleScannerService._onDeviceSeen`
  previously had a temporary `debugPrint` dumping every advertisement seen,
  and `MainActivity.kt` a raw `BluetoothLeScanner` diagnostic (tag
  `RAWBLE`) that bypassed the Flutter plugin entirely to check whether the
  OS saw a beacon at all — both were removed once detection was confirmed
  working end-to-end; re-add similar logging temporarily if needed rather
  than leaving it in permanently.
- **If a beacon still doesn't show up**, check `local_packages/reactive_ble_mobile/android/.../ble/ReactiveBleClient.kt`'s
  `scanForDevices` — it previously called `.setLegacy(false)` on
  `ScanSettings.Builder`, which tells Android to report only Bluetooth 5
  extended-advertising results and silently drop legacy-format ones. iBeacon
  is a legacy-only format, so that one line made every iBeacon invisible to
  this app while still letting BLE5 devices (most modern phones/wearables)
  through — which is exactly why a scan log could show 100+ nearby devices
  and still miss the one beacon that mattered. It's been removed; if it
  reappears (e.g. from re-vendoring the plugin), take it back out. This is
  **native Android code** — changes here need a full rebuild, not hot
  reload/restart.
- `BleScannerService.startScan()` also explicitly requests
  `ScanMode.lowLatency` rather than the library's `balanced` default, for a
  higher scan duty cycle — matters for beacons with a sparse advertising
  interval.
- `beacons[].x/y` and `mapWidth`/`mapHeight` are in the same coordinate
  space as `assets/floorMap.svg`'s `viewBox` (currently `0 0 297 210`).
- `beacons[].x/y` for `b1`–`b4` are **estimated** corridor positions,
  computed from the gaps between the room rectangles in `floorMap.svg`
  (beacons are mounted on the walkway between rooms, not inside them) —
  adjust to match actual mounting locations once surveyed.
- `edges` describe walkable aisle connections and their distance/weight;
  the pathfinder treats them as undirected.
- `edges[].waypoints` (optional, e.g. `[{"x":235,"y":115},{"x":235,"y":75}]`)
  bends an edge's *shape* through intermediate points, ordered from `from`
  toward `to`, for corridors that curve around a room rather than running
  in a straight line between the two beacons — see "Rerouting when off the
  path" below. These are purely geometric, **not** additional graph nodes:
  they don't get a `beacons[]` entry, don't need real beacon hardware,
  can't become `currentBeacon`, and never appear as a selectable
  destination — deliberately, since real deployments only have as many
  beacons as there is physical hardware for. `Dijkstra` (`PathfindingService`)
  is completely unaware waypoints exist; they only affect
  `StoreMap.snapToGraph`'s map-matching and `MapPainter`'s drawn route
  line, both of which look them up per-edge via `StoreMap.edgeBetween`.

If you later mount a beacon inside/near one of the 7 labeled rooms
(ChatGPT Meeting Room, Safari Room, Gemma Room, SOC Room, Seating Area 1,
Seating Area 2, Breakout Room) instead of the walkway, add a beacon entry
for it and wire it into `edges` the same way.

## Live position tracking (PDR)

The map arrow no longer only jumps between beacon fixes — between fixes it
moves continuously via **pedestrian dead reckoning (PDR)**: each detected
step (`pedometer`, backed by the OS's accelerometer-based step counter)
advances a position estimate by one step-length, and each confirmed BLE
zone-snap fix resets that estimate back to the beacon's known position,
correcting drift. See `MotionService` (`lib/services/motion_service.dart`)
and `NavigationController`'s `_onStepDistance`/`_onRssiUpdate`
(`lib/services/navigation_controller.dart`).

- **Direction = along the route, not raw heading.** `_stepDirection`
  (`NavigationController`) walks toward the next waypoint on `currentPath`
  whenever a route is active, using the compass/gyro heading only as a
  fallback when there's no destination set. Indoor compass headings are
  noisy enough (see below) that trusting the planned route's direction is
  more reliable than trusting the phone's heading — and it's what keeps the
  pin advancing along the path the user actually asked to follow rather
  than wherever the compass happens to point. `storeMap.snapToGraph` still
  clamps the result onto the corridor graph either way, since a
  straight-line aim at a waypoint can cut a corner through a room interior.

- `store_data.json`'s `metersPerUnit` converts step-length meters into map
  coordinate units; `mapNorthOffsetDegrees` is the compass bearing that
  corresponds to the map's "up" direction, used to rotate a heading into
  the map's coordinate frame.
- **Current calibration is approximate.** Measured `b1↔b4` = 65 map units
  for 6 m (0.0923 m/unit) and `b4↔b3` = 103 map units for 12 m (0.1165
  m/unit) — these two disagree by ~26%, meaning the floor plan isn't
  uniformly to scale (expected, given it was reconstructed from a rotated
  SVG rather than surveyed). `metersPerUnit: 0.104` is their average.
  Re-measure more beacon pairs and adjust this single number to improve
  accuracy. `mapNorthOffsetDegrees: 180` was corrected empirically (on-device
  testing showed the arrow off by 90°) — note this means the map's "up"
  direction now works out to compass **South**, not the East originally
  described; if direction ever looks wrong again after further changes,
  that mismatch is the first thing to check, not another blind 90° nudge.
- `stepLengthMeters` (`MotionService`, default `0.75`) is a generic average
  adult stride — personalize per-user if needed.
- **Heading = gyroscope + compass fusion**: raw compass readings are noisy
  indoors (structural metal, electronics interfere with the magnetometer)
  and comparatively slow to update. `MotionService` now integrates
  `sensors_plus`' `gyroscopeEventStream()` (rotation rate, typically
  50-200 Hz) into the heading continuously (`_onGyro`) for fast, low-noise
  turn response, and corrects the accumulating gyro drift on every compass
  sample with a small-weight circular blend (`_onCompass`, `_blendHeading`,
  weight `0.08`) rather than trusting either sensor alone. Tune that weight
  if turns feel laggy (raise it) or the heading drifts/jitters between
  compass fixes (lower it).
- **Trilateration, not winner-take-all or a bare signal-weighted average**:
  `ZoneSnapService` used to snap to whichever single beacon read
  strongest — noisy indoors, since a farther beacon can transiently
  out-read a closer one, which was exactly the "shows me at the wrong room"
  symptom even with all 4 beacons correctly labeled. A signal-weighted
  centroid was tried after that (RSSI → linear power via `10^(rssi/10)`,
  averaged); it fixed *which node* got picked but, fed continuously into
  the live position, could overshoot toward a beacon just because it was
  in range — a proximity-weighted average doesn't reason about *absolute*
  distance. `estimatePosition` now does real multilateration: each
  beacon's RSSI is converted to an estimated distance in meters (a
  log-distance path-loss model, `_txPowerAt1m`/`_pathLossExponent` — not
  per-beacon calibrated, so treat distances as approximate), then solves
  (weighted least squares, closed-form for 2 unknowns) for the point
  consistent with *all* those distances — with >=3 beacons in range.
  Falls back to a distance-weighted centroid with only 1-2 beacons, or
  when the visible beacons are too close to collinear to solve (common
  here, since they're mounted along corridors rather than spread in a
  grid) — the solver's determinant check and a map-bounds plausibility
  check both guard against a degenerate solve shooting off to a
  nonsensical point. `nearestBeacon` picks whichever known beacon is
  closest to that estimate, for `currentBeacon`/pathfinding.
- **Target vs. drawn position — a continuous "chase"**: `NavigationController`
  tracks two positions. `_targetPosition` is the *logical* best-known
  spot, updated continuously by *both* PDR steps (`_stepDirection`) *and*
  every BLE reading's trilaterated estimate (`_onRssiUpdate`) — not just
  once a node flip is confirmed, which is what lets the pin keep moving
  and stay roughly accurate *between* beacons rather than only updating at
  them. `liveUserPosition` — what's actually drawn — is never set
  directly; `_advanceTowardTarget` (ticked every 80ms) continuously eases
  it toward `_targetPosition` at a capped `_walkingSpeedMetersPerSecond`
  (1.3 m/s). That speed cap is deliberate: even if a given trilateration
  reading is briefly noisy, the drawn pin can only be pulled by that much
  before the next (hopefully better) reading corrects it, rather than
  visibly teleporting — the mechanism that made the earlier
  proximity-centroid approach's overshoot-toward-destination bug possible
  no longer exists structurally. Both the target's updates and the
  chase's ticks run through `storeMap.snapToGraph`, so the pin stays on
  the walkable corridor throughout, never free-drifting through a room
  interior.
- **Permissions**: step counting needs `ACTIVITY_RECOGNITION`
  (`AndroidManifest.xml`, API 29+) / `NSMotionUsageDescription`
  (`Info.plist`), requested at runtime by `MotionService.start()` the same
  way `BleScannerService` handles BLE permissions; denial surfaces via
  `MotionService.errors` as a `SnackBar`, same pattern. `flutter_compass`
  needs no extra runtime permission on either platform as far as tested —
  flagged here in case that turns out wrong on a given device, consistent
  with this project's history of permission surprises.
- New native permission → needs a full rebuild (`flutter pub get`, then
  `flutter run`), not hot reload/restart.
- **Confined to the corridor graph**: `NavigationController._onStepDelta`
  runs every dead-reckoned position through `StoreMap.snapToGraph`
  (`lib/models/store_map.dart`) before using it — a map-matching step that
  projects the raw point onto the nearest edge of `storeMap.edges`, clamped
  to that segment. This is what stops PDR from drifting into the black room
  rectangles: those have no edges, so the graph itself defines walkable
  space. Simplification worth knowing about: it always snaps to whichever
  edge is geometrically nearest, with no directionality/continuity
  awareness — fine for this graph's current size (4 edges), but if the
  corridor layout grows dense enough for edges to run close and parallel,
  nearest-segment snapping can occasionally jump to the wrong nearby
  corridor instead of staying on the one actually being walked.
- **Animated arrow movement**: `_MapFrame` (`lib/ui/widgets/live_navigation_card.dart`,
  shared by `HomeScreen` and `NavigationScreen`) is a `StatefulWidget` that
  tweens the *drawn* position from wherever it currently is to each new
  `liveUserPosition` over ~120ms (`Curves.easeOut`), redirecting smoothly
  mid-flight if another update arrives before the tween finishes, rather
  than snapping instantly on every `notifyListeners()`. This is what makes
  the arrow read as continuous walking motion instead of discrete jumps.
  Heading isn't separately animated — `MotionService`'s heading smoothing
  (above) already keeps it visually smooth at the source.
- **Destination pin**: `MapPainter._drawDestinationPin` renders a
  `location_on` Material icon glyph directly onto the canvas (drawing an
  `Icon`'s glyph via `TextPainter` inside a `CustomPainter`) at the last
  beacon in the route, instead of the plain dot every other waypoint gets —
  makes the endpoint visually distinct from the path it took to get there.
- **"Arrived" no longer blanks the UI**: when `currentBeacon` equals
  `destinationBeacon`, `PathfindingService.findPath` correctly returns a
  1-beacon path (nothing to walk) — but `MapPainter` used to only draw
  *anything* `if (path.length > 1)`, so arriving made the route line, pin,
  distance, and directions all vanish together, indistinguishable from "no
  route selected." It now always draws the destination pin whenever `path`
  is non-empty, and `NavigationController` reports `0 m` instead of `null`
  distance for a 1-beacon path.
- **Beacon-flip debounce**: `NavigationController._onRssiUpdate` now
  requires a candidate "nearest beacon" to win `_requiredConsecutiveReadings`
  (2) updates in a row before committing it to `currentBeacon` — a single
  noisy RSSI reading was previously enough to flip zones outright, which is
  a likely cause of the app reporting a beacon that didn't match physical
  reality. **This can only filter noise, not fix a wrong `bleId`-to-position
  mapping** — if `store_data.json`'s `beacons[].bleId` values don't
  correspond to where those physical beacons are actually mounted, no
  amount of software debouncing will report the correct zone. Worth
  re-verifying against nRF Connect (as done for the original `b1`) if
  misidentification continues after this.
- **Edge-stickiness**: `StoreMap.snapToGraph` now takes an optional
  `preferredEdge` and discounts its distance before comparing, so a noisy
  step doesn't flip the live position to a different, similarly-close
  corridor edge on every update — `NavigationController` tracks
  `_lastSnappedEdge` and passes it back in each call. This graph is small
  enough (4 short edges) that PDR error from a single step can be a
  significant fraction of an entire edge's length, so some jumpiness here
  is a real precision limit of step-based positioning at this map's scale,
  not purely a smoothing bug — expect it to improve as `metersPerUnit` gets
  more accurately calibrated (see above), not fully disappear.

## Rerouting when off the path

`NavigationController._applySnap` — the one place all three position
sources (PDR steps, BLE trilateration, and the follow-ticker) funnel their
`storeMap.snapToGraph` result through — checks whether the corridor edge
tracking just snapped onto is actually part of `currentPath` (`_isOffPath`).
If it isn't, `_recomputeFromEdge` immediately recalculates the route from
the nearer endpoint of that edge to `destinationBeacon`, the same way a
turn-by-turn nav app reroutes when you go off the suggested path. This is
deliberately separate from `_recomputePath` (which still anchors on the
BLE-confirmed `currentBeacon`): rerouting reacts to *any* corridor
deviation immediately, without waiting for a full beacon confirmation to
catch up. It only fires when the snapped edge actually changes, so it
doesn't refire every tick while lingering on the same off-path corridor,
and it's a no-op with no active multi-node route (nothing to be "off" of).

This machinery only works on corridors that actually exist as `edges` in
`store_data.json` — `snapToGraph` can only snap onto a real edge, never
"nowhere." If a corridor curves around a room (so a straight line between
its two beacons would cut through space nobody can actually walk),
give that edge `waypoints` (see "Wiring real beacons" above) rather than
adding a new beacon-shaped node — waypoints bend an existing edge's shape
without implying hardware that doesn't exist. If a part of the floor plan
needs a walkable connection that isn't between two already-adjacent
beacons at all, that does need a new edge (and if it doesn't touch an
existing beacon, that's a genuine hardware/mounting question — not
something to fake in software).

## Route distance

Once a destination is picked, the status card above the map shows total
route distance (e.g. "142 m"), computed from `PathfindingService.findPath`'s
`RouteResult.distanceUnits` (the sum of edge weights Dijkstra already
computes to find the shortest path — no separate calculation) multiplied by
`metersPerUnit`. Since that scale factor is only roughly calibrated (see
above), treat this distance as approximate too.

- **If the distance looks way off** (e.g. reported ~44 m for a route
  expected to be ~24 m): check which beacon is actually set as
  `destinationBeacon` first, before suspecting `metersPerUnit`. With the
  current graph (`b2↔b3` 132 units, `b3↔b4` 103, `b4↔b1` 188), `b2→b4` is
  235 units × `0.104` ≈ **24 m** — already correct — while `b2→b1` (the
  graph's two *opposite ends*, via `b3` and `b4`) is 423 units × `0.104` ≈
  **44 m**. That exact match is what a wrong-destination selection looks
  like; it isn't reproducible from a `metersPerUnit`/edge-weight bug given
  the numbers above.
- **The route no longer disappears on its own.** `_recomputePath`
  (`NavigationController`) used to blank `currentPath`/`currentDistanceMeters`
  whenever `currentBeacon` was momentarily null or `PathfindingService`
  came back empty — which could happen transiently mid-walk, hiding the
  route line, destination pin, and directions chips for no reason visible
  to the user. It now leaves the existing route on screen untouched in
  both cases and only ever replaces or clears it for one of two
  intentional reasons: `setDestination` (a genuinely new destination) or
  `clearDestination` (the map card's refresh button).

## Item search

Tap the search icon in the app bar to search-as-you-type over
`store_data.json`'s `items` array; picking a result calls
`NavigationController.setDestination` with that item's nearest beacon, same
as picking one from the destination-picker menu, and the route renders the
same way.

- Each item is `{ "name": "...", "beaconId": "b1", "category": "Electronics" }`
  — `beaconId` must match an existing `beacons[].id`; there's no separate
  "room" concept beyond that, an item's location *is* whichever beacon is
  nearest to it. `category` is freeform display grouping only (see
  "Screens" below) — `Item.fromJson` defaults it to `"Other"` if omitted,
  so it's optional, not a breaking schema change.
- Matching is a plain case-insensitive substring match on `name`
  (`StoreMap.searchItems` in `lib/models/store_map.dart`) — fine for a
  handful of items; if the catalog grows large, that's the place to swap in
  something smarter (fuzzy matching, indexing, etc.).
- The current 8 items are placeholders illustrating the shape — replace with
  the store's real inventory.

## Zone-arrival offer notifications

Each item can also carry an optional `"offer"` string, e.g.
`{ "name": "Coffee Machine", "beaconId": "b3", "category": "Appliances",
"offer": "Free bag of coffee beans with purchase" }` — `Item.offer` is
`null` if omitted, same optional/non-breaking pattern as `category`.
`NavigationController.zoneEnteredStream` (`lib/services/navigation_controller.dart`)
fires once each time `currentBeacon` is freshly confirmed as a *new* zone
(not on every RSSI update while already in one — it's emitted from the
same `_requiredConsecutiveReadings`-debounced branch that sets
`currentBeacon`, so it inherits that stability). `HomeScreen` listens for
it for the app's whole lifetime and, if the zone has any items with a
non-null `offer`, shows `OffersDialog` (`lib/ui/widgets/offers_dialog.dart`)
— a dismissible popup listing them. Since `showDialog` targets the app's
one shared `Navigator`, this pops up correctly regardless of whether
`HomeScreen` or `NavigationScreen` is the currently visible route. The
current offers on Whiteboard Markers/Standing Desk (`b1`), HDMI Cable
(`b2`), Coffee Machine (`b3`), and Server Rack (`b4`) are placeholder data
illustrating the shape, same as the items themselves.

## Logging and analytics

Two separate local text files, both under the app's documents directory
(`path_provider`'s `getApplicationDocumentsDirectory()` — app-private
storage, no extra runtime permission needed on either platform):

- **`app_log.txt`** (`ActivityLogger`, `lib/services/activity_logger.dart`)
  — a general append-only debug trail: app start/background, BLE/motion
  errors, destination changes, zone entries. One timestamped line per
  event (`log()` also `debugPrint`s it, so it shows up in `flutter run`'s
  console too). Fire-and-forget and failure-tolerant by design — a logging
  write failing must never crash or block the app it's observing.
- **`analytics.txt`** (`AnalyticsService`, `lib/services/analytics_service.dart`)
  — dwell-time data: one tab-separated row per zone visit (entry
  timestamp, zone id, zone name, seconds spent), so "where do people spend
  most of their time" is answerable straight from the file, or via
  `AnalyticsService.totalTimePerZone`/`mostVisitedZone` in-session. Kept
  in its own file rather than interleaved into the debug log deliberately
  — one is diagnostic output you might clear/rotate constantly, the other
  is user-behavior data you'd want to keep and analyze separately.

Both are driven by the same `NavigationController.zoneEnteredStream`
(see "Zone-arrival offer notifications" above for what that stream is)
— `AnalyticsService.start()` and `HomeScreen`'s own listener both
subscribe to it, so a zone visit both gets logged *and* timed from the
same debounced signal. `AnalyticsService` closes out the in-progress
visit (`flush()`) whenever `HomeScreen` sees `AppLifecycleState.paused`/
`detached`, alongside the existing `clearDestination()` call there — so
backgrounding or closing the app doesn't silently lose whatever visit was
still ongoing. Both services are instantiated once in `_HomeScreenState`
(same app-lifetime ownership pattern as `NavigationController.start()`
and the error-stream subscriptions already there) and disposed in its
`dispose()`.

## Troubleshooting: map stuck on the loading spinner

The map (`_MapFrame` in `lib/ui/widgets/live_navigation_card.dart`) shows a `CircularProgressIndicator` (via `placeholderBuilder`)
until `floorMap.svg` resolves, and now shows a red error message (via
`errorBuilder`) if it fails to parse instead of spinning forever. If you
still see the spinner after editing `assets/floorMap.svg`:

1. **Full restart, not hot reload.** Flutter bundles `assets/` content at
   build/restart time — editing an asset file's bytes while the app is
   running usually isn't picked up by hot reload. Stop the app and
   `flutter run` again (or hot **restart**, not hot reload).
2. Run `flutter pub get` after any change to `pubspec.yaml`'s `assets:` list.
3. Check the debug console for a `flutter_svg` parse error — invalid SVG
   (e.g. an unclosed tag) will now surface via `errorBuilder` instead of
   hanging silently.

## Notes / MVP shortcuts

- Zone snap picks the single strongest beacon rather than trilaterating —
  fine for aisle-level granularity, not sub-meter precision.
- Pathfinding is a plain O(V²) Dijkstra, which is fine for a graph sized to
  a store's aisle endpoints (tens of nodes).
- No state management library — `NavigationController` is a single
  `ChangeNotifier` consumed via `AnimatedBuilder`.

# In-store navigation

Guides the shopper from the entrance past every item to the cashier using the phone's own motion tracking. It needs no beacons or GPS.

Source: `UI/ShellApp/ShellApp/Navigation/`, `UI/ShellApp/ShellApp/StoreMap/`. Map drawings: `map-preview/`.

## Stack

ARKit (world tracking), simd, SwiftUI, and WatchConnectivity for the cues.

## How it works

1. **Map (`StoreMap`):** the store is a graph of named nodes, with walked edge lengths in meters. Each store location (`G44`) maps to either a stop at a node or a lane scanned end to end.
2. **Plan (`RoutePlanner`):** Dijkstra finds the distances between nodes. Held-Karp then finds the shortest entrance → items → cashier order (exact for up to ~15 groups, nearest-first beyond that).
3. **Track (`PositionTracker`):** ARKit gives the phone's position, starting from the entrance.
4. **Guide (`RouteNavigator`):** measures progress along each leg and announces turns ("Turn left" and 2 watch taps). It learns the angle between ARKit and the map on the first leg and relearns it at every leg, so drift doesn't build up. A wrong turn is caught within a couple of meters.
5. **Stop:** at an item's spot, navigation waits while the camera finds it ([item-recognition.md](item-recognition.md)), then re-plans for what's left.

## Replicating it

- The shopper must start at the **store entrance**, with the phone mounted upright on the cart. Tracking is measured from there.
- The bundled map is **Target Waterford Lakes**, built from 4 calibration walks in `StoreMap/Calibration/*.json`. **Any other store needs its own map.**
- To map a new store, record walks with the calibration app on the `GraphCalibration` branch. It marks nodes and records walked edges with ARKit and exports `shell-calibration-v2` JSON. Add the files to `StoreMap/Calibration/` and build the map in `StoreMap.target` the same way.
- Item locations (`G44`) must use the same block and aisle names as the catalog.

## Testing without a store

When ARKit isn't available (simulator, or no camera permission), shopping runs a **simulated walk**. The navigation screen then shows **Walk 1 m**, **To next point**, and **Wrong turn** buttons. Simulated walks don't scan for items.

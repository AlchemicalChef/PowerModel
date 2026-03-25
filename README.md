# PowerModel

Interactive simulation of the US power grid. Visualizes ~27,000 generators, ~52,000 transmission lines, and ~10,500 substations across the three US interconnections (Eastern, Western, ERCOT). Click any component to inject a failure and watch cascading blackouts propagate in real time.

Built with Elixir/Phoenix LiveView, Deck.gl, and MapLibre GL JS.

## Prerequisites

- **Erlang/OTP** 28+
- **Elixir** 1.15+
- **PostgreSQL** 14+ with the **PostGIS** extension
- **Rust** (stable toolchain) for the sparse matrix NIF
- **Node.js** 18+

### macOS (Homebrew)

```sh
brew install elixir postgresql@17 postgis rust node
brew services start postgresql@17
```

## Quick Start

The repo includes a pre-built database dump (38 MB) with all grid data already ingested, plus binary files for the frontend. No need to download or process any external datasets.

```sh
git clone <repo-url> && cd PowerModel
mix setup
mix phx.server
```

Open http://localhost:4000.

`mix setup` does the following:
1. `deps.get` — install Elixir and JS dependencies, compile the Rust NIF
2. `power_model.restore_db` — create the database and restore from the included dump
3. `assets.setup` + `assets.build` — install and build Tailwind/esbuild assets

### Database Credentials

Default dev config expects a local PostgreSQL with:

| Setting  | Value           |
|----------|-----------------|
| Username | postgres        |
| Password | postgres        |
| Host     | localhost       |
| Database | power_model_dev |

Edit `config/dev.exs` to change these.

## Using the Simulation

1. **Pan and zoom** the map to explore the grid
2. **Click** any generator, transmission line, or substation to select it
3. Click **"Inject Failure"** in the info panel to trip the component
4. Watch the **cascade** propagate — overloaded lines trip, generation re-dispatches, load is shed
5. The **timeline** at the bottom lets you step through each cascade stage
6. The **"Final"** step shows the post-cascade steady state with all cumulative impact

### What the Colors Mean

- **Green** — normal operation
- **Yellow** — stressed (high loading)
- **Red** — overloaded or tripped
- **Black** — de-energized

During an active cascade, unaffected components fade to translucent grey to highlight the impact area.

## Included Data

All data is sourced from US government public datasets and included in the repo:

| Source | Contents | Location |
|--------|----------|----------|
| EIA Form 860 | Generator locations, capacity, fuel type | `data/eia860_2024.zip` |
| EPA eGRID | Emissions and generation mix | `data/egrid2022.xlsx` |
| HIFLD | Transmission lines, substations | Ingested via API, in DB dump |
| Database dump | All tables fully populated | `priv/repo/power_model_dev.dump` (38 MB) |
| Frontend binaries | Pre-built Deck.gl data | `priv/static/grid_data/` (~13 MB) |

### What's in the Database

| Table | Rows |
|-------|------|
| Buses | 14,486 |
| Generators | 26,883 |
| Transmission lines | 52,272 |
| Substations | 65,450 |
| Loads | 12,844 |
| Transformers | 2,331 |
| Water facilities | 44 |
| International tie lines | 28 |

## Re-ingesting Data (Optional)

If you want to rebuild the database from scratch instead of using the dump:

```sh
mix ecto.reset

mix power_model.ingest substations --api
mix power_model.ingest transmission_lines --api
mix power_model.ingest generators data/eia860_2024.zip
mix power_model.ingest egrid data/egrid2022.xlsx
mix power_model.ingest map_buses
mix power_model.ingest estimate_parameters
mix power_model.ingest estimate_loads
mix power_model.ingest international

mix power_model.export_grid_data
```

## Architecture

```
lib/
  power_model/
    grid/            # Ecto schemas (bus, generator, line, substation, etc.)
    solver/          # DC & AC power flow, frequency dynamics, Y-bus
    failure/         # Cascade engine, protection relays, load shedding
    engine/          # SimulationServer GenServer, runtime orchestration
    ingestion/       # Data import from EIA, HIFLD, EPA
  power_model_web/
    live/grid_live/  # LiveView, LiveComponents (info panel, timeline, metrics)

assets/js/
  grid/              # Deck.gl map manager, data store, color scales
    layers/          # GPU-rendered layers (generators, lines, substations)
  hooks/             # LiveView JS hooks bridging server <-> map

native/
  sparse_solver/     # Rust NIF for sparse matrix operations (sprs + LDL)
```

### Simulation Flow

1. User clicks a component and injects a failure
2. `SimulationServer` (GenServer) loads the grid topology for that interconnection
3. DC power flow solves in ~100ms, results push to the browser
4. Cascade engine checks for thermal overloads, voltage violations, under-frequency
5. Each cascade step trips overloaded components and re-solves
6. Results stream to the frontend via PubSub -> LiveView `push_event`
7. Deck.gl updates component colors/states on the GPU

## Tests

```sh
mix test
```

81 tests covering IEEE 14-bus validation, cascade engine, island detection, and more.

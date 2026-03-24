# Wisconet API Client

An R6 class providing an interface to the Wisconet v1 API
(<https://wisconet.wisc.edu/api/v1>). Supports fetching station
metadata, available field definitions, and observation data for one or
more stations.

## Public fields

- `stations`:

  Tibble of station metadata, populated by `get_stations()`.

- `fields`:

  Tibble of available field definitions, populated by `get_fields()`.

- `timezone`:

  Timezone used when parsing observation timestamps. Defaults to local
  time for the mesonet ("America/Chicago").

## Methods

### Public methods

- [`Wisconet$new()`](#method-Wisconet-new)

- [`Wisconet$get_stations()`](#method-Wisconet-get_stations)

- [`Wisconet$find_nearest_station()`](#method-Wisconet-find_nearest_station)

- [`Wisconet$get_fields()`](#method-Wisconet-get_fields)

- [`Wisconet$find_fields()`](#method-Wisconet-find_fields)

- [`Wisconet$get_measures()`](#method-Wisconet-get_measures)

- [`Wisconet$get_measures_stations()`](#method-Wisconet-get_measures_stations)

- [`Wisconet$get_measures_all()`](#method-Wisconet-get_measures_all)

- [`Wisconet$map_stations()`](#method-Wisconet-map_stations)

- [`Wisconet$print()`](#method-Wisconet-print)

- [`Wisconet$clone()`](#method-Wisconet-clone)

------------------------------------------------------------------------

### Method `new()`

Initializes the class.

#### Usage

    Wisconet$new(timezone = "America/Chicago", fetch_on_init = TRUE)

#### Arguments

- `timezone`:

  Character. Timezone for parsing observation timestamps. Defaults to
  "America/Chicago".

- `fetch_on_init`:

  Logical. Whether to fetch station and field metadata on
  initialization. Default `TRUE`.

------------------------------------------------------------------------

### Method `get_stations()`

Fetch or refresh the station metadata table from the API. Wrapper for
`/api/v1/stations/`

#### Usage

    Wisconet$get_stations()

------------------------------------------------------------------------

### Method `find_nearest_station()`

Find the nearest station(s) to a given latitude and longitude.

#### Usage

    Wisconet$find_nearest_station(lat, lng, n = 1)

#### Arguments

- `lat`:

  Numeric. Latitude of point to search from.

- `lng`:

  Numeric. Longitude of point to search from.

- `n`:

  Integer. Number of nearest stations to return. Default `1`.

------------------------------------------------------------------------

### Method `get_fields()`

Fetch or refresh the available field definitions from the API. Wrapper
for `/api/v1/fields/`

#### Usage

    Wisconet$get_fields()

------------------------------------------------------------------------

### Method `find_fields()`

Filter the list of available fields by type and/or frequency. Called
with no arguments, prints the available filter options and returns the
full fields table.

#### Usage

    Wisconet$find_fields(type = NULL, freq = NULL)

#### Arguments

- `type`:

  Character. A measure type to filter by (e.g. `"Air Temp"`,
  `"Soil Temp"`).

- `freq`:

  Character. A collection frequency to filter by (e.g. `"5min"`,
  `"60min"`, `"daily"`).

------------------------------------------------------------------------

### Method `get_measures()`

Fetch observations for a single station. Wrapper for
`/api/v1/stations/{station_id}/measures`

#### Usage

    Wisconet$get_measures(stn_id, fields, start_time, end_time = now())

#### Arguments

- `stn_id`:

  Character. A single station ID.

- `fields`:

  Character vector of field `standard_name` values to request.

- `start_time`:

  A `POSIXct` datetime for the start of the query window.

- `end_time`:

  A `POSIXct` datetime for the end of the query window. Defaults to
  `now()`.

------------------------------------------------------------------------

### Method `get_measures_stations()`

Fetch observations for a specific set of stations in parallel.
`start_time` may be a named list (keyed by `stn_id`) to use per-station
start times.

#### Usage

    Wisconet$get_measures_stations(
      stn_ids,
      fields,
      start_time,
      end_time = now(),
      max_concurrent = 10
    )

#### Arguments

- `stn_ids`:

  Character vector of station IDs to query.

- `fields`:

  Character vector of field `standard_name` values to request.

- `start_time`:

  A `POSIXct` datetime, or a named list of `POSIXct` values keyed by
  station ID for per-station start times.

- `end_time`:

  A `POSIXct` datetime for the end of the query window. Defaults to
  `now()`.

- `max_concurrent`:

  Integer. Maximum number of concurrent requests. Default `10`.

------------------------------------------------------------------------

### Method `get_measures_all()`

Fetch observations for all active stations in parallel.

#### Usage

    Wisconet$get_measures_all(fields, start_time, end_time = now())

#### Arguments

- `fields`:

  Character vector of field `standard_name` values to request.

- `start_time`:

  A `POSIXct` datetime for the start of the query window.

- `end_time`:

  A `POSIXct` datetime for the end of the query window. Defaults to
  `now()`.

------------------------------------------------------------------------

### Method `map_stations()`

Display all stations on an interactive leaflet map. Requires the leaflet
package.

#### Usage

    Wisconet$map_stations()

------------------------------------------------------------------------

### Method [`print()`](https://rdrr.io/r/base/print.html)

Prints a status message when the class is called without any arguments.

#### Usage

    Wisconet$print(...)

#### Arguments

- `...`:

  Ignored.

------------------------------------------------------------------------

### Method `clone()`

The objects of this class are cloneable with this method.

#### Usage

    Wisconet$clone(deep = FALSE)

#### Arguments

- `deep`:

  Whether to make a deep clone.

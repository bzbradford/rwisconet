#' Wisconet API Client
#'
#' @description
#' An R6 class providing an interface to the Wisconet v1 API
#' (<https://wisconet.wisc.edu/api/v1>). Supports fetching station metadata,
#' available field definitions, and observation data for one or more stations.
#'
#' @section Methods:
#' \describe{
#'   \item{`new(timezone, fetch_on_init)`}{
#'     Initialize the client. `timezone` defaults to `Sys.timezone()`.
#'     Set `fetch_on_init = FALSE` to skip the initial metadata fetch.
#'   }
#'   \item{`get_stations()`}{Fetch/refresh the station metadata table.}
#'   \item{`find_nearest_station()`}{Find the nearest station(s) to a given latitude and longitude.}
#'   \item{`get_fields()`}{Fetch/refresh the available fields table.}
#'   \item{`find_fields()`}{Filter the list of available fields by type and/or frequency.}
#'   \item{`get_measures(stn_id, fields, start_time, end_time)`}{
#'     Fetch observations for a single station.
#'   }
#'   \item{`get_measures_stations(stn_ids, fields, start_time, end_time, max_concurrent)`}{
#'     Fetch observations for a specific set of stations in parallel.
#'     `start_time` may be a named list (keyed by `stn_id`) to use
#'     per-station start times.
#'   }
#'   \item{`get_measures_all(fields, start_time, end_time)`}{
#'     Fetch observations for all active stations in parallel.
#'   }
#'   \item{`map_stations()`}{
#'     Display stations on an interactive leaflet map.
#'     Requires the \pkg{leaflet} package.
#'   }
#' }
#'
#' @export
#'
#' @importFrom R6 R6Class
#' @importFrom httr2 request req_url_query req_error req_perform
#'   req_perform_parallel resp_is_error resp_status resp_body_json
#' @importFrom lubridate with_tz as_datetime as_date now mdy
#' @importFrom tibble tibble as_tibble enframe
#' @importFrom dplyr select any_of rename filter mutate left_join join_by
#'   bind_cols bind_rows across arrange where
#' @importFrom tidyr unnest_wider unnest_longer
#' @importFrom purrr map map2 map_int
#' @importFrom rlang .data
Wisconet <- R6Class(
  "Wisconet",

  # Private methods ----
  private = list(
    api_url = "https://wisconet.wisc.edu/api/v1",

    # Build a URL path under the API root
    build_url = function(...) {
      paste(private$api_url, ..., sep = "/")
    },

    # Convert local time to GMT unix timestamp
    time_to_gmt = function(t) {
      as.numeric(with_tz(t, "GMT"))
    },

    # Ensure station and field metadata are loaded
    ensure_metadata = function() {
      if (is.null(self$stations)) {
        self$get_stations()
      }
      if (is.null(self$fields)) self$get_fields()
    },

    # Build a generic httr2 request
    build_request = function(endpoint, query_params = list()) {
      request(private$build_url(endpoint)) |>
        req_url_query(!!!query_params) |>
        req_error(is_error = ~FALSE)
    },

    # Build an httr2 request for station measures
    build_measures_request = function(stn_id, fields, start_time, end_time) {
      private$build_request(
        paste("stations", stn_id, "measures", sep = "/"),
        list(
          start_time = private$time_to_gmt(start_time),
          end_time = private$time_to_gmt(end_time),
          fields = paste(fields, collapse = ",")
        )
      )
    },

    # Parse the fieldlist metadata from a measures response
    parse_fieldlist = function(fieldlist) {
      fieldlist |>
        enframe() |>
        select(-name) |>
        unnest_wider(value) |>
        rename(measure_id = id) |>
        select(where(~ !all(is.na(.x) | .x == "")))
    },

    # Parse the data array from a measures response
    parse_data = function(data) {
      data |>
        enframe() |>
        select(-name) |>
        unnest_wider(value) |>
        mutate(
          dttm = as_datetime(collection_time),
          date = as_date(dttm, tz = self$timezone),
          .after = collection_time
        ) |>
        unnest_longer(measures) |>
        unnest_wider(measures, names_sep = "_") |>
        rename(measure_id = measures_1, measure_value = measures_2)
    },

    # Parse a single measures response, joining station metadata
    parse_measures_response = function(resp, stn_id) {
      if (resp_is_error(resp)) {
        message("  FAIL [", stn_id, "]: HTTP ", resp_status(resp))
        return(tibble())
      }

      body <- resp_body_json(resp)

      if (length(body[["data"]]) == 0) {
        message("  No data for ", stn_id)
        return(tibble())
      }

      resp_fields <- private$parse_fieldlist(body$fieldlist)
      resp_data <- private$parse_data(body$data)
      resp_joined <- resp_data |> left_join(resp_fields, join_by(measure_id))

      stn <- self$stations |> filter(station_id == stn_id)
      data <- tibble(station_id = stn_id) |> bind_cols(resp_joined)
      stn |> left_join(data, join_by(station_id))
    },

    # Validate station IDs and field names, lazily fetching metadata if needed
    validate_inputs = function(stn_ids, fields) {
      private$ensure_metadata()
      bad_stns <- setdiff(stn_ids, self$stations$station_id)
      if (length(bad_stns) > 0) {
        stop("Unknown station(s): ", paste(bad_stns, collapse = ", "))
      }
      bad_fields <- setdiff(fields, self$fields$standard_name)
      if (length(bad_fields) > 0) {
        stop("Unknown field(s): ", paste(bad_fields, collapse = ", "))
      }
    }
  ),

  # Public methods ----
  public = list(
    #' @field stations Tibble of station metadata, populated by `get_stations()`.
    stations = NULL,
    #' @field fields Tibble of available field definitions, populated by `get_fields()`.
    fields = NULL,
    #' @field timezone Timezone used when parsing observation timestamps. Defaults to system timezone.
    timezone = NULL,

    #' @description
    #' Initializes the class.
    #'
    #' @param timezone Character. Timezone for parsing observation timestamps.
    #'   Defaults to the system timezone.
    #' @param fetch_on_init Logical. Whether to fetch station and field metadata
    #'   on initialization. Default `TRUE`.
    #'
    initialize = function(timezone = Sys.timezone(), fetch_on_init = TRUE) {
      self$timezone <- timezone
      if (fetch_on_init) {
        self$get_stations()
        self$get_fields()
      }
    },

    #' @description
    #' Fetch or refresh the station metadata table from the API.
    #' Wrapper for `/api/v1/stations/`
    #'
    get_stations = function() {
      url <- private$build_url("stations")
      req <- request(url)
      resp <- req_perform(req) |>
        resp_body_json(simplifyVector = TRUE) |>
        as_tibble()
      self$stations <- resp |>
        mutate(across(earliest_api_date, mdy)) |>
        select(
          -any_of(c("campbell_cloud_id", "legacy_id"))
        ) |>
        filter(!grepl("TEST", station_id))
      invisible(self)
    },

    #' @description
    #' Find the nearest station(s) to a given latitude and longitude.
    #'
    #' @param lat Numeric. Latitude of point to search from.
    #' @param lng Numeric. Longitude of point to search from.
    #' @param n Integer. Number of nearest stations to return. Default `1`.
    #'
    find_nearest_station = function(lat, lng, n = 1) {
      stopifnot(
        "Longitude must be between -95 and -85" = length(lng) == 1 &
          is.numeric(lng) &
          lng >= -95 &
          lng <= -85,
        "Latitude must be between 40 and 50" = length(lat) == 1 &
          is.numeric(lat) &
          lat >= 40 &
          lat <= 50
      )
      private$ensure_metadata()
      cos_lat <- cos(lat * pi / 180)
      self$stations |>
        select(station_id, station_name, latitude, longitude) |>
        mutate(
          dist_km = 111.32 *
            sqrt(
              (latitude - lat)^2 + ((longitude - lng) * cos_lat)^2
            )
        ) |>
        arrange(dist_km) |>
        head(n)
    },

    #' @description
    #' Fetch or refresh the available field definitions from the API.
    #' Wrapper for `/api/v1/fields/`
    #'
    get_fields = function() {
      url <- private$build_url("fields")
      req <- request(url)
      resp <- req_perform(req) |>
        resp_body_json(simplifyVector = TRUE) |>
        as_tibble()
      self$fields <- resp |>
        select(where(~ !all(is.na(.x) | .x == "")))
      invisible(self)
    },

    #' @description
    #' Filter the list of available fields by type and/or frequency.
    #' Called with no arguments, prints the available filter options
    #' and returns the full fields table.
    #'
    #' @param type Character. A measure type to filter by (e.g. `"Air Temp"`,
    #'   `"Soil Temp"`).
    #' @param freq Character. A collection frequency to filter by (e.g.
    #'   `"5min"`, `"60min"`, `"daily"`).
    #'
    find_fields = function(type = NULL, freq = NULL) {
      private$ensure_metadata()

      # Map parameter names to column names; extend here to add new filters
      filter_map <- list(
        type = "measure_type",
        freq = "collection_frequency"
      )

      fields <- self$fields
      args <- list(type = type, freq = freq)
      active <- Filter(Negate(is.null), args)

      # no filter provided, list options and return full list
      if (length(active) == 0) {
        for (name in names(filter_map)) {
          col <- filter_map[[name]]
          vals <- paste(sprintf("'%s'", unique(fields[[col]])), collapse = ", ")
          message("Available [", name, "] values: ", vals)
        }
        return(fields)
      }

      # apply each filter in turn, checking validity
      for (name in names(active)) {
        col <- filter_map[[name]]
        val <- active[[name]]
        valid <- unique(fields[[col]])
        if (!(val %in% valid)) {
          valid_list <- paste(sprintf("'%s'", valid), collapse = ", ")
          stop("Invalid ", name, " '", val, "'. Must be one of: ", valid_list)
        }
        fields <- filter(fields, .data[[col]] == val)
      }
      fields
    },

    #' @description
    #' Fetch observations for a single station.
    #' Wrapper for `/api/v1/stations/{station_id}/measures`
    #'
    #' @param stn_id Character. A single station ID.
    #' @param fields Character vector of field `standard_name` values to request.
    #' @param start_time A `POSIXct` datetime for the start of the query window.
    #' @param end_time A `POSIXct` datetime for the end of the query window.
    #'   Defaults to `now()`.
    #'
    get_measures = function(stn_id, fields, start_time, end_time = now()) {
      private$validate_inputs(stn_id, fields)
      message("GET ==> ", stn_id, ": ", start_time, " to ", end_time)

      req <- private$build_measures_request(
        stn_id,
        fields,
        start_time,
        end_time
      )
      t <- now()
      resp <- req_perform(req)
      result <- private$parse_measures_response(resp, stn_id)

      if (nrow(result) > 0) {
        n_obs <- length(unique(result$collection_time))
        elapsed <- as.numeric(difftime(now(), t, units = "secs"))
        message(sprintf("  Received %s observations in %.3fs", n_obs, elapsed))
      }

      result
    },

    #' @description
    #' Fetch observations for a specific set of stations in parallel.
    #' `start_time` may be a named list (keyed by `stn_id`) to use per-station
    #' start times.
    #'
    #' @param stn_ids Character vector of station IDs to query.
    #' @param fields Character vector of field `standard_name` values to request.
    #' @param start_time A `POSIXct` datetime, or a named list of `POSIXct` values
    #'   keyed by station ID for per-station start times.
    #' @param end_time A `POSIXct` datetime for the end of the query window.
    #'   Defaults to `now()`.
    #' @param max_concurrent Integer. Maximum number of concurrent requests.
    #'   Default `10`.
    #'
    get_measures_stations = function(
      stn_ids,
      fields,
      start_time,
      end_time = now(),
      max_concurrent = 10
    ) {
      private$validate_inputs(stn_ids, fields)

      message("Fetching ", length(stn_ids), " stations")

      reqs <- if (length(start_time) > 1) {
        map(
          stn_ids,
          ~ private$build_measures_request(
            .x,
            fields,
            start_time[[.x]],
            end_time
          )
        )
      } else {
        map(
          stn_ids,
          ~ private$build_measures_request(.x, fields, start_time, end_time)
        )
      }

      t <- now()
      resps <- req_perform_parallel(
        reqs,
        on_error = "continue",
        progress = "Fetching station data",
        max_active = max_concurrent
      )

      results <- map2(
        resps,
        stn_ids,
        ~ private$parse_measures_response(.x, .y),
        .progress = "Parsing responses"
      )
      combined <- bind_rows(results)

      elapsed <- as.numeric(difftime(now(), t, units = "secs"))
      n_stns <- sum(map_int(results, nrow) > 0)
      message(sprintf(
        "  Done: %i/%i stations returned data in %.1fs",
        n_stns,
        length(stn_ids),
        elapsed
      ))

      combined
    },

    #' @description
    #' Fetch observations for all active stations in parallel.
    #'
    #' @param fields Character vector of field `standard_name` values to request.
    #' @param start_time A `POSIXct` datetime for the start of the query window.
    #' @param end_time A `POSIXct` datetime for the end of the query window.
    #'   Defaults to `now()`.
    #'
    get_measures_all = function(
      fields,
      start_time,
      end_time = now()
    ) {
      private$ensure_metadata()

      active_stns <- self$stations |> filter(earliest_api_date <= end_time)
      stn_ids <- active_stns$station_id

      self$get_measures_stations(stn_ids, fields, start_time, end_time)
    },

    #' @description Display all stations on an interactive leaflet map.
    #'   Requires the \pkg{leaflet} package.
    #'
    map_stations = function() {
      if (!requireNamespace("leaflet", quietly = TRUE)) {
        stop(
          "Package 'leaflet' is required for map_stations(). Install it with: install.packages('leaflet')"
        )
      }
      if (is.null(self$stations)) {
        self$get_stations()
      }
      leaflet::leaflet(self$stations) |>
        leaflet::addTiles() |>
        leaflet::addMarkers(
          lng = ~longitude,
          lat = ~latitude,
          label = ~ paste0(station_id, ": ", station_name)
        )
    },

    #' @description
    #' Prints a status message when the class is called without any arguments.
    #'
    #' @param ... Ignored.
    #'
    print = function(...) {
      n_stns <- if (!is.null(self$stations)) nrow(self$stations) else "?"
      n_fields <- if (!is.null(self$fields)) nrow(self$fields) else "?"
      cat("<Wisconet API>\n")
      cat("  Timezone:", self$timezone, "\n")
      cat("  Stations:", n_stns, "\n")
      cat("  Fields:", n_fields, "\n")
      invisible(self)
    }
  )
)

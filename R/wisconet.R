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
#'   \item{`get_fields()`}{Fetch/refresh the available fields table.}
#'   \item{`get_measures(stn_id, fields, start_time, end_time)`}{
#'     Fetch observations for a single station.
#'   }
#'   \item{`get_measures_stations(stn_ids, fields, start_time, end_time, max_reqs_per_sec)`}{
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
#' @importFrom stringr str_glue
#' @importFrom tibble tibble as_tibble enframe
#' @importFrom dplyr select rename filter mutate left_join join_by
#'   bind_cols bind_rows across arrange where
#' @importFrom tidyr unnest_wider unnest_longer
#' @importFrom purrr map map2 map_int
Wisconet <- R6Class(
  "Wisconet",
  private = list(
    api_url = "https://wisconet.wisc.edu/api/v1",

    # Convert local time to GMT unix timestamp
    time_to_gmt = function(t) {
      as.numeric(with_tz(t, "GMT"))
    },

    # Build an httr2 request for a single station
    build_request = function(stn_id, fields, start_time, end_time) {
      request(str_glue("{private$api_url}/stations/{stn_id}/measures")) |>
        req_url_query(
          start_time = private$time_to_gmt(start_time),
          end_time = private$time_to_gmt(end_time),
          fields = paste(fields, collapse = ",")
        ) |>
        req_error(is_error = ~FALSE)
    },

    # Parse the fieldlist metadata from a response
    parse_fieldlist = function(fieldlist) {
      fieldlist |>
        enframe() |>
        select(-name) |>
        unnest_wider(value) |>
        rename(measure_id = id) |>
        select(where(~ !all(is.na(.x) | .x == "")))
    },

    # Parse the data array from a response
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

    # Parse a single response, joining station metadata
    parse_response = function(resp, stn_id) {
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

    # Validate inputs, lazily fetching metadata if needed
    validate_inputs = function(stn_ids, fields) {
      if (is.null(self$stations)) {
        self$get_stations()
      }
      if (is.null(self$fields)) {
        self$get_fields()
      }
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

  public = list(
    #' @field stations Tibble of station metadata, populated by `get_stations()`.
    stations = NULL,
    #' @field fields Tibble of available field definitions, populated by `get_fields()`.
    fields = NULL,
    #' @field timezone Timezone used when parsing observation timestamps.
    timezone = NULL,

    #' @description Initializes the class.
    #' @param timezone Character. Timezone for parsing observation timestamps.
    #'   Defaults to the system timezone.
    #' @param fetch_on_init Logical. Whether to fetch station and field metadata
    #'   on initialization. Default `TRUE`.
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
    get_stations = function() {
      self$stations <- str_glue("{private$api_url}/stations") |>
        request() |>
        req_perform() |>
        resp_body_json(simplifyVector = TRUE) |>
        as_tibble() |>
        mutate(across(earliest_api_date, mdy)) |>
        select(-c(id, campbell_cloud_id, legacy_id, station_slug)) |>
        filter(!grepl("TEST", station_id))
      invisible(self)
    },

    #' @description
    #' Fetch or refresh the available field definitions from the API.
    #' Wrapper for `/api/v1/stations/`
    get_fields = function() {
      self$fields <- str_glue("{private$api_url}/fields") |>
        request() |>
        req_perform() |>
        resp_body_json(simplifyVector = TRUE) |>
        as_tibble() |>
        select(where(~ !all(is.na(.x) | .x == ""))) |>
        arrange(measure_type, standard_name)
      invisible(self)
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
    get_measures = function(stn_id, fields, start_time, end_time = now()) {
      private$validate_inputs(stn_id, fields)
      message("GET ==> ", stn_id, ": ", start_time, " to ", end_time)

      req <- private$build_request(stn_id, fields, start_time, end_time)
      t <- now()
      resp <- req_perform(req)
      result <- private$parse_response(resp, stn_id)

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
    #' @param max_reqs_per_sec Integer. Maximum number of concurrent requests.
    #'   Default `10`.
    get_measures_stations = function(
      stn_ids,
      fields,
      start_time,
      end_time = now(),
      max_reqs_per_sec = 10
    ) {
      private$validate_inputs(stn_ids, fields)

      message("Fetching ", length(stn_ids), " stations")

      reqs <- if (length(start_time) > 1) {
        map(
          stn_ids,
          ~ private$build_request(.x, fields, start_time[[.x]], end_time)
        )
      } else {
        map(
          stn_ids,
          ~ private$build_request(.x, fields, start_time, end_time)
        )
      }

      t <- now()
      resps <- req_perform_parallel(
        reqs,
        on_error = "continue",
        progress = "Fetching station data",
        max_active = max_reqs_per_sec
      )

      results <- map2(
        resps,
        stn_ids,
        ~ private$parse_response(.x, .y),
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
    get_measures_all = function(
      fields,
      start_time,
      end_time = now()
    ) {
      if (is.null(self$stations)) {
        self$get_stations()
      }
      if (is.null(self$fields)) {
        self$get_fields()
      }

      active_stns <- self$stations |> filter(earliest_api_date <= end_time)
      stn_ids <- active_stns$station_id

      self$get_measures_stations(stn_ids, fields, start_time, end_time)
    },

    #' @description Display all stations on an interactive leaflet map.
    #'   Requires the \pkg{leaflet} package.
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

    #' @param ... Ignored.
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

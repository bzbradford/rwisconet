# Helper: create a client with pre-loaded fixture data (no HTTP calls)
make_test_client <- function() {
  w <- Wisconet$new(timezone = "US/Central", fetch_on_init = FALSE)

  stations_json <- jsonlite::fromJSON(
    test_path("fixtures", "stations.json"),
    simplifyVector = TRUE
  )
  w$stations <- stations_json |>
    tibble::as_tibble() |>
    dplyr::mutate(dplyr::across(earliest_api_date, lubridate::mdy)) |>
    dplyr::select(-dplyr::any_of(c("campbell_cloud_id", "legacy_id"))) |>
    dplyr::filter(!grepl("TEST", station_id))

  fields_json <- jsonlite::fromJSON(
    test_path("fixtures", "fields.json"),
    simplifyVector = TRUE
  )
  w$fields <- fields_json |>
    tibble::as_tibble() |>
    dplyr::select(dplyr::where(~ !all(is.na(.x) | .x == "")))

  w
}

# --- initialize -----------------------------------------------------------

test_that("initialize sets timezone and skips fetch when fetch_on_init = FALSE", {
  w <- Wisconet$new(timezone = "US/Eastern", fetch_on_init = FALSE)
  expect_equal(w$timezone, "US/Eastern")
  expect_null(w$stations)
  expect_null(w$fields)
})

# --- get_stations ----------------------------------------------------------

test_that("get_stations populates stations tibble and filters TEST stations", {
  w <- make_test_client()
  expect_s3_class(w$stations, "tbl_df")
  expect_true(nrow(w$stations) > 0)
  expect_false(any(grepl("TEST", w$stations$station_id)))
  expect_true("station_id" %in% names(w$stations))
  expect_true("latitude" %in% names(w$stations))
  expect_true("longitude" %in% names(w$stations))
  expect_s3_class(w$stations$earliest_api_date, "Date")
})

# --- get_fields ------------------------------------------------------------

test_that("get_fields populates fields tibble and drops empty columns", {
  w <- make_test_client()
  expect_s3_class(w$fields, "tbl_df")
  expect_true(nrow(w$fields) > 0)
  expect_true("standard_name" %in% names(w$fields))
  expect_true("measure_type" %in% names(w$fields))
  # all-NA/empty columns should be dropped
  for (col in names(w$fields)) {
    vals <- w$fields[[col]]
    expect_false(all(is.na(vals) | vals == ""), label = paste("column", col))
  }
})

# --- find_nearest_station --------------------------------------------------

test_that("find_nearest_station returns closest station", {
  w <- make_test_client()
  # Madison, WI coordinates
  result <- w$find_nearest_station(lat = 43.07, lng = -89.40)
  expect_s3_class(result, "tbl_df")
  expect_equal(nrow(result), 1)
  expect_true("dist_km" %in% names(result))
  expect_true("station_id" %in% names(result))
})

test_that("find_nearest_station respects n parameter", {
  w <- make_test_client()
  result <- w$find_nearest_station(lat = 43.07, lng = -89.40, n = 3)
  expect_equal(nrow(result), 3)
  # distances should be sorted ascending
  expect_equal(result$dist_km, sort(result$dist_km))
})

test_that("find_nearest_station rejects out-of-bounds coordinates", {
  w <- make_test_client()
  expect_error(w$find_nearest_station(lat = 30, lng = -89))
  expect_error(w$find_nearest_station(lat = 43, lng = -70))
})

# --- find_fields -----------------------------------------------------------

test_that("find_fields with no args returns all fields and messages", {
  w <- make_test_client()
  msgs <- character(0)
  result <- withCallingHandlers(
    w$find_fields(),
    message = function(m) {
      msgs <<- c(msgs, conditionMessage(m))
      invokeRestart("muffleMessage")
    }
  )
  expect_true(any(grepl("Available.*type", msgs)))
  expect_true(any(grepl("Available.*freq", msgs)))
  expect_equal(nrow(result), nrow(w$fields))
})

test_that("find_fields filters by type", {
  w <- make_test_client()
  result <- w$find_fields(type = "Air Temp")
  expect_true(all(result$measure_type == "Air Temp"))
  expect_true(nrow(result) > 0)
  expect_true(nrow(result) < nrow(w$fields))
})

test_that("find_fields filters by freq", {
  w <- make_test_client()
  result <- w$find_fields(freq = "5min")
  expect_true(all(result$collection_frequency == "5min"))
  expect_true(nrow(result) > 0)
})

test_that("find_fields filters by both type and freq", {
  w <- make_test_client()
  result <- w$find_fields(type = "Air Temp", freq = "5min")
  expect_true(all(result$measure_type == "Air Temp"))
  expect_true(all(result$collection_frequency == "5min"))
})

test_that("find_fields errors on invalid type", {
  w <- make_test_client()
  expect_error(w$find_fields(type = "Fake Type"), "Invalid type")
})

test_that("find_fields errors on invalid freq", {
  w <- make_test_client()
  expect_error(w$find_fields(freq = "999min"), "Invalid freq")
})

# --- validate_inputs -------------------------------------------------------

test_that("validate_inputs errors on unknown station", {
  w <- make_test_client()
  env <- w$.__enclos_env__$private
  expect_error(
    env$validate_inputs("FAKE_STN", w$fields$standard_name[1]),
    "Unknown station"
  )
})

test_that("validate_inputs errors on unknown field", {
  w <- make_test_client()
  env <- w$.__enclos_env__$private
  expect_error(
    env$validate_inputs(w$stations$station_id[1], "fake_field"),
    "Unknown field"
  )
})

test_that("validate_inputs passes with valid inputs", {
  w <- make_test_client()
  env <- w$.__enclos_env__$private
  expect_no_error(
    env$validate_inputs(
      w$stations$station_id[1],
      w$fields$standard_name[1]
    )
  )
})

# --- build_measures_request ------------------------------------------------

test_that("build_measures_request constructs correct URL and params", {
  w <- make_test_client()
  env <- w$.__enclos_env__$private
  start <- as.POSIXct("2025-03-24 00:00:00", tz = "US/Central")
  end <- as.POSIXct("2025-03-25 00:00:00", tz = "US/Central")

  req <- env$build_measures_request("ALTN", "5min_air_temp_f_avg", start, end)
  expect_s3_class(req, "httr2_request")
  expect_true(grepl("stations/ALTN/measures", req$url))
  expect_true(grepl("fields=5min_air_temp_f_avg", req$url))
})

# --- parse_measures_response -----------------------------------------------

test_that("parse_measures_response parses fixture data correctly", {
  w <- make_test_client()
  env <- w$.__enclos_env__$private

  # Build a mock response from the fixture file
  fixture_path <- test_path("fixtures", "measures_ALTN.json")
  body <- readLines(fixture_path, warn = FALSE) |> paste(collapse = "")

  mock_resp <- httr2::response_json(
    status_code = 200,
    body = jsonlite::fromJSON(body, simplifyVector = FALSE)
  )

  result <- env$parse_measures_response(mock_resp, "ALTN")
  expect_s3_class(result, "tbl_df")
  expect_true(nrow(result) > 0)
  expect_true("station_id" %in% names(result))
  expect_true("collection_time" %in% names(result))
  expect_true("measure_id" %in% names(result))
  expect_true("measure_value" %in% names(result))
  expect_true("dttm" %in% names(result))
  expect_true("date" %in% names(result))
  expect_true(all(result$station_id == "ALTN"))
})

test_that("parse_measures_response returns empty tibble on HTTP error", {
  w <- make_test_client()
  env <- w$.__enclos_env__$private

  mock_resp <- httr2::response(status_code = 500)
  expect_message(
    result <- env$parse_measures_response(mock_resp, "FAKE"),
    "FAIL"
  )
  expect_equal(nrow(result), 0)
})

# --- print -----------------------------------------------------------------

test_that("print outputs expected format", {
  w <- make_test_client()
  output <- capture.output(w$print())
  expect_true(any(grepl("<Wisconet API>", output)))
  expect_true(any(grepl("Timezone:", output)))
  expect_true(any(grepl("Stations:", output)))
  expect_true(any(grepl("Fields:", output)))
})

test_that("print shows ? when metadata not loaded", {
  w <- Wisconet$new(timezone = "US/Central", fetch_on_init = FALSE)
  output <- capture.output(w$print())
  expect_true(any(grepl("Stations: \\?", output)))
  expect_true(any(grepl("Fields: \\?", output)))
})

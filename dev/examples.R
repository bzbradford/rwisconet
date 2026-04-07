library(tidyverse)
library(R6)
library(httr2)

source("R/wisconet.R")

# initialize
wn <- Wisconet$new()
wn <- Wisconet$new(fetch_on_init = FALSE)

wn

# stations
wn$stations
wn$find_nearest(45, -89)
wn$map_stations()

# fields
wn$fields |> count(collection_frequency)
wn$find_fields()
wn$find_fields(freq = "5min")
wn$find_fields(freq = "daily")
wn$find_fields(type = "Air Temp", freq = "5min")


# single station measures
measures_5min <- c(
  "5min_air_temp_f_avg",
  "5min_relative_humidity_pct_avg",
  "5min_wind_speed_mph_avg"
)

obs <- wn$get_measures(
  stn_id = "HNCK", # Hancock
  fields = measures_5min,
  start_time = now() - days(1),
  end_time = now()
)


# multiple stations
obs <- wn$get_measures_stations(
  stn_ids = c("ALTN", "HNCK"), # Arlington, Hancock
  fields = measures_5min,
  start_time = now() - days(1),
  end_time = now()
)


# specific start/end times
measures_daily <- c(
  "daily_air_temp_f_min",
  "daily_air_temp_f_avg",
  "daily_air_temp_f_max"
)

starts <- list(
  ALTN = now() - months(2),
  HNCK = now() - months(1)
)

ends <- map(starts, ~ .x + days(7))

ends <- lapply(starts, \(x) x + days(7))


obs <- wn$get_measures_stations(
  stn_ids = names(starts),
  fields = measures_daily,
  start_time = starts,
  end_time = ends
)


# all stations
obs <- wn$get_measures_all(
  fields = measures_daily,
  start_time = today() - days(7),
  end_time = today()
)


# simplify data
obs <- wn$get_measures_stations(
  stn_ids = c("ALTN", "HNCK"), # Arlington, Hancock
  fields = measures_daily,
  start_time = now() - months(1),
  end_time = now()
)

select_obs <- obs |>
  select(station_id, dttm_local, date, standard_name, measure_value)

obs_wide <- select_obs |>
  pivot_wider(names_from = standard_name, values_from = measure_value)


# plot
select_obs |>
  ggplot(aes(x = dttm_local, y = measure_value, color = standard_name)) +
  geom_line() +
  facet_wrap(~station_id, ncol = 1) +
  theme(legend.position = "bottom")

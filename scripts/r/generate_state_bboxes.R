# ---- generate state bounding boxes from TIGER/Census -----------------------
# uses tigris + sf to get authoritative state boundaries and extract bboxes
# output: data/meta/state_bboxes.csv

suppressPackageStartupMessages({
  library(tigris)
  library(sf)
})

options(tigris_use_cache = TRUE)

message("[", format(Sys.time()), "] fetching state boundaries from Census TIGER...")
states <- tigris::states(year = 2024, cb = TRUE)

message("[", format(Sys.time()), "] computing bounding boxes...")
bboxes <- do.call(rbind, lapply(seq_len(nrow(states)), function(i) {
  bb <- sf::st_bbox(states[i, ])
  data.frame(
    statefp = states$STATEFP[i],
    name = states$NAME[i],
    min_x = round(bb["xmin"], 3),
    min_y = round(bb["ymin"], 3),
    max_x = round(bb["xmax"], 3),
    max_y = round(bb["ymax"], 3),
    stringsAsFactors = FALSE
  )
}))

bboxes <- bboxes[order(bboxes$statefp), ]
rownames(bboxes) <- NULL

message("[", format(Sys.time()), "] writing data/meta/state_bboxes.csv...")
write.csv(bboxes, "data/meta/state_bboxes.csv", row.names = FALSE)

message("[", format(Sys.time()), "] done: ", nrow(bboxes), " states/territories")
print(head(bboxes, 10))

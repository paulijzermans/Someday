REEL_CACHE_ENABLED = True
PLACE_CACHE_ENABLED = True

# Speed optimisation flags
CONCURRENT_FRAGMENTS = True   # A: download video segments in parallel — 2.5x faster download
LOW_QUALITY_DOWNLOAD = False  # B: benchmarked, no effect — Instagram doesn't serve lower res variants
SINGLE_CALL_PLACES = True     # C: get all place fields in one Text Search call — eliminates round-trip

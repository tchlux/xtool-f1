# Print Preview Known Failure Modes

## Mixed Raster And Vector Preview Must Preserve Raster DPI

Do not render mixed raster/vector jobs by collapsing the whole work area into a fixed-size bitmap. A 500 DPI raster asset must remain represented by its generated raster dimensions in the preview model, even when vector paths are present.

Preferred fix pattern:
- Keep raster assets in `GCodePreviewRaster` layers generated from `RasterOutput`.
- Draw vector paths as timed segments layered over those raster layers.
- Use whole-bed parsed G-code bitmaps only as a fallback for previews that do not have raster layer data.

Regression guard:
- A mixed raster/vector preview for a 25.4 mm wide 500 DPI raster should expose a raster layer with `500` source pixels across, not a smaller whole-bed preview image.

## Preview Playback Time Is A UI Timeline, Not Machine Time

Print preview should preserve relative draw order while staying usable. Each asset should draw for at least 1 second when possible and no more than 3 seconds. The whole preview must not exceed 10 seconds; if necessary, scale all asset durations down together and allow the 1 second minimum to bend.

Regression guard:
- Sequential asset previews should clamp individual asset durations to 1-3 seconds before applying the 10 second total cap.
- Simultaneous raster previews should draw raster layers as one timed group, then draw later vector objects in generated print order.

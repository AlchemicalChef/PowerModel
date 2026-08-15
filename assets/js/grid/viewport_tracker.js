/**
 * Tracks viewport state and provides LOD thresholds.
 * Debounces viewport change events to avoid overwhelming the server.
 */

// Every zoom threshold at which client-side layer visibility, filtering, or
// resolution changes: 4.5/6/7.5 (demand hex resolution), 5 (generators),
// 6 (line declutter band, generator size scale), 7 (transformers),
// 8 (substations, line declutter band), 10 (labels). A move that crosses one
// of these MUST re-render even if it is otherwise "insignificant" — a small
// zoom from 7.9 to 8.05 is what reveals substations.
export const LOD_ZOOM_THRESHOLDS = [4.5, 5, 6, 7, 7.5, 8, 10];

export function lodBand(zoom) {
  let band = 0;
  for (const t of LOD_ZOOM_THRESHOLDS) {
    if (zoom >= t) band++;
  }
  return band;
}

export class ViewportTracker {
  constructor(map, onViewportChange, debounceMs = 300) {
    this.map = map;
    this.onViewportChange = onViewportChange;
    this.debounceMs = debounceMs;
    this._timeout = null;
    this._lastZoom = null;
    this._lastBounds = null;

    this._onMove = this._onMove.bind(this);
    map.on("moveend", this._onMove);
    map.on("zoomend", this._onMove);
  }

  _onMove() {
    if (this._timeout) clearTimeout(this._timeout);
    this._timeout = setTimeout(() => {
      const zoom = this.map.getZoom();
      const bounds = this.map.getBounds();

      const newBounds = {
        west: bounds.getWest(),
        south: bounds.getSouth(),
        east: bounds.getEast(),
        north: bounds.getNorth(),
      };

      // Notify when the zoom changed significantly, the viewport moved
      // meaningfully, or the zoom crossed an LOD band boundary (a tiny zoom
      // step across a visibility threshold must not be swallowed).
      if (
        this._lastZoom === null ||
        Math.abs(zoom - this._lastZoom) > 0.5 ||
        lodBand(zoom) !== lodBand(this._lastZoom) ||
        this._boundsChanged(newBounds)
      ) {
        this._lastZoom = zoom;
        this._lastBounds = newBounds;
        this.onViewportChange(zoom, newBounds);
      }
    }, this.debounceMs);
  }

  _boundsChanged(newBounds) {
    if (!this._lastBounds) return true;
    // Threshold relative to the current viewport span: a fixed degree
    // threshold ignored meaningful pans at high zoom (city-scale pans move
    // the bounds far less than half a degree).
    const lonSpan = Math.abs(newBounds.east - newBounds.west) || 1e-6;
    const latSpan = Math.abs(newBounds.north - newBounds.south) || 1e-6;
    const frac = 0.1; // 10% of the viewport
    return (
      Math.abs(newBounds.west - this._lastBounds.west) > lonSpan * frac ||
      Math.abs(newBounds.south - this._lastBounds.south) > latSpan * frac ||
      Math.abs(newBounds.east - this._lastBounds.east) > lonSpan * frac ||
      Math.abs(newBounds.north - this._lastBounds.north) > latSpan * frac
    );
  }

  /** Get LOD config for current zoom */
  getLOD() {
    const zoom = this._lastZoom || this.map.getZoom();
    return {
      showGenerators: zoom >= 5,
      showSubstations: zoom >= 8,
      showLabels: zoom >= 10,
      clusterGenerators: zoom < 6,
      minLineVoltage: zoom < 6 ? 345 : zoom < 8 ? 138 : 0,
      lineWidth: zoom < 6 ? 0.5 : zoom < 8 ? 1 : 1.5,
    };
  }

  destroy() {
    if (this._timeout) clearTimeout(this._timeout);
    this.map.off("moveend", this._onMove);
    this.map.off("zoomend", this._onMove);
  }
}

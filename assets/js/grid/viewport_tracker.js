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

      if (
        this._lastZoom === null ||
        Math.abs(zoom - this._lastZoom) > 0.5 ||
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
    const threshold = 0.5;
    return (
      Math.abs(newBounds.west - this._lastBounds.west) > threshold ||
      Math.abs(newBounds.south - this._lastBounds.south) > threshold ||
      Math.abs(newBounds.east - this._lastBounds.east) > threshold ||
      Math.abs(newBounds.north - this._lastBounds.north) > threshold
    );
  }

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

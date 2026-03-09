const CascadeTimelineHook = {
  mounted() {
    this.el.addEventListener("input", (e) => {
      if (e.target.classList.contains("timeline-scrubber")) {
        const step = parseInt(e.target.value, 10);
        this.pushEvent("scrub_timeline", { step: String(step) });
      }
    });
  },
};

export default CascadeTimelineHook;

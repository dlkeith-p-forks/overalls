export const DashboardVisibility = {
  mounted() {
    this.changed = () => this.pushEvent("visibility", {visible: !document.hidden});
    document.addEventListener("visibilitychange", this.changed);
    this.changed();
  },
  destroyed() { document.removeEventListener("visibilitychange", this.changed); },
};

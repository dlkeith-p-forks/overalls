# @cc [owner:ghuntley,label:reliability] recording-gap-window-eligibility
# Every enrolled request series MUST have a fresh matching coverage clock older
# than the requested window. Missing clocks and a gap on any source MUST withhold
# the window, including retained recordings, without resetting source lifetime.
service: seconds:
let
  labels = ''overalls_telemetry_origin="application",service_name="${service}"'';
  coverage = "overalls_outer_${service}_source_coverage_start_time";
  requests = "overalls_outer_${service}_requests_total";
  started = "overalls_outer_${service}_source_start_time";
in ''
  (count(${coverage}{${labels}}) == count(${requests}{${labels}}))
  and on() (count(${requests}{${labels}} and on(host_name,service_instance_id) ${coverage}{${labels}})
    == count(${requests}{${labels}}))
  and on() (count(${coverage}{${labels}} >= on(host_name,service_instance_id) ${started}{${labels}})
    == count(${requests}{${labels}}))
  and on() (max(${coverage}{${labels}}) < time() - ${toString seconds})
  and on() (count((time() - timestamp(${coverage}{${labels}})) < 45) == count(${requests}{${labels}}))
''

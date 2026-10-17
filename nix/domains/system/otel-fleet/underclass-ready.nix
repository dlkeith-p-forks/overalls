let
  metric = ''overalls_underclass_monitor_ready{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name=~"overalls|dungarees"}'';
  clock = ''overalls_underclass_monitor_sample_time{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name=~"overalls|dungarees"}'';
in
# @cc [owner:ghuntley,label:reliability;verification] underclass-both-hosts-observed
# A local monitor candidate exists only with exactly one fresh, complete probe
# series and source sampling clock from each enrolled host. Missing, cached older
# than 45 seconds or more than two seconds future observations MUST remain unknown.
''
  count(overalls_underclass_monitor_ready{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name="overalls"}) == 1
  and count(overalls_underclass_monitor_ready{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name="dungarees"}) == 1
  and (min(count_over_time(${metric}[5m])) >= 10)
  and (max(time() - timestamp(${metric})) < 45)
  and count(overalls_underclass_monitor_sample_time{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name="overalls"}) == 1
  and count(overalls_underclass_monitor_sample_time{overalls_telemetry_origin="application",service_name="underclass_monitor",host_name="dungarees"}) == 1
  and (max(time() - ${clock}) < 45)
  and (min(time() - ${clock}) >= -2)
''

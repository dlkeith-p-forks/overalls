# @cc [owner:ghuntley,label:reliability] ingress-direct-source-observation
# Retained ingress values MUST remain unknown unless exactly one direct local
# source scrape succeeds and its observation is younger than 45 seconds.
''
  (count(up{job="overalls-ingress-source",instance="127.0.0.1:8405"}) == 1)
  and (min(up{job="overalls-ingress-source",instance="127.0.0.1:8405"}) == 1)
  and (max(time() - timestamp(up{job="overalls-ingress-source",instance="127.0.0.1:8405"})) < 45)
''

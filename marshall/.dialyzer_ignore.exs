# @cc [owner:ghuntley,label:verification] dependency-only-dialyzer-exclusion
# Exclusions MUST identify a specific upstream diagnostic and removal condition;
# application findings MUST NOT be hidden by broad patterns or ignored exit codes.
# AshAuthentication Phoenix 3.0.0-rc.11 fixes the former OTP 29 record/0 warning.
# No exclusions are currently needed; unused-filter detection stays enabled.
[]

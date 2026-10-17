{ lib, cfg }:
# Applied by env after EnvironmentFile loading, for serving and migrations.
lib.optionalString cfg.enable ''
  -u MARSHALL_SMTP_USERNAME -u MARSHALL_SMTP_PASSWORD \
  -u MARSHALL_SMTP_TLS -u MARSHALL_SMTP_CA_CERTFILE \
'' + lib.optionalString cfg.enable ''
  MARSHALL_MAIL_TRANSPORT=local_relay MARSHALL_SMTP_HOST=127.0.0.1 \
  MARSHALL_SMTP_PORT=${toString cfg.port} MARSHALL_MAIL_FROM=${lib.escapeShellArg cfg.from} \
''

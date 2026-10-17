{
  uid = "overalls-fleet-logs";
  title = "Overalls fleet logs and traces";
  tags = [ "overalls" "logs" "traces" ];
  schemaVersion = 41; version = 1; refresh = "30s";
  time = { from = "now-1h"; to = "now"; };
  description = "Reviewed ordinary platform diagnostics. Select a trace identifier to open Tempo. Restricted host audit, Firecracker raw evidence and guest content have separate custody.";
  templating.list = [{
    name = "source"; label = "Service"; type = "custom";
    query = "marshall,lilly,audi,brady,ziggy,galileo,enrico,porsche,underclass,haproxy,auth,kernel,storage,mail,operations,system";
    current = { text = "lilly"; value = "lilly"; };
    multi = false; includeAll = false;
  }];
  panels = [{
    id = 1; title = "Fleet diagnostics"; type = "logs";
    gridPos = { h = 16; w = 24; x = 0; y = 0; };
    datasource = { type = "victoriametrics-logs-datasource"; uid = "overalls-victorialogs"; };
    targets = [{ refId = "A"; expr = ''source:"$source"''; queryType = "instant"; editorMode = "code"; maxLines = 500; }];
    options = { showTime = true; showLabels = true; enableLogDetails = true; sortOrder = "Descending"; wrapLogMessage = true; };
  } {
    id = 2; title = "Application traces"; type = "table";
    gridPos = { h = 12; w = 24; x = 0; y = 16; };
    datasource = { type = "tempo"; uid = "overalls-tempo"; };
    targets = [{ refId = "A"; queryType = "traceql"; query = ''{ resource.service.name = "$source" && resource.overalls.telemetry.origin = "application" }''; limit = 100; }];
  }];
}

let
  scrapeSeconds = 10;
  samplesPerDay = builtins.div 86400 scrapeSeconds;
in {
  inherit scrapeSeconds samplesPerDay;
  sevenDaySamples = 7 * samplesPerDay;
}

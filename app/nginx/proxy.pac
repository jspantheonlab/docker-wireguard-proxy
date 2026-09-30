function FindProxyForURL(url, host) {
  var PROXY = "PROXY ${WG_HOST}:${WG_PROXY_PORT}";
  var HOST_PATTERNS_STR = "${WG_TUNNEL_HOSTS}";
  if (HOST_PATTERNS_STR) {
    var HOST_PATTERNS = HOST_PATTERNS_STR.split(",");

    for (var i = 0; i < HOST_PATTERNS.length; i++) {
      var pattern = HOST_PATTERNS[i].replace(/^\s+|\s+$/g, "");
      if (!pattern) {
        continue;
      }
      if (shExpMatch(host, pattern)) {
        return PROXY;
      }
      // "*.example.com" should also match the apex "example.com"
      if (pattern.indexOf("*.") === 0 && shExpMatch(host, pattern.substring(2))) {
        return PROXY;
      }
    }
  }
  return "DIRECT";
}

function FindProxyForURL(url, host) {
  var HOST_PATTERNS_STR = "${WG_TUNNEL_HOSTS}";
  if (HOST_PATTERNS_STR) {
    var HOST_PATTERNS = HOST_PATTERNS_STR.split(",");

    for (var i = 0; i < HOST_PATTERNS.length; i++) {
      var pattern = HOST_PATTERNS[i];
      if (shExpMatch(host, pattern)) {
        return "PROXY ${WG_HOST}:${WG_PROXY_PORT}";
      }
    }
  }
}

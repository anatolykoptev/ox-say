package config

// hostMemoryBytes reports the installed RAM, or 0 when it cannot be read. A
// variable so tests can pin any size on any host.
var hostMemoryBytes = readHostMemoryBytes

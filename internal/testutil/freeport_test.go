package testutil

import "testing"

// FreePorts must hand out pairwise distinct ports: its listeners all stay
// open until every port is chosen, so the kernel cannot return one twice.
// Mutation: fakechild.go FreePorts - close each listener right after taking
// its port (instead of after the loop) -> RED (duplicate port).
func TestFreePortsAreDistinct(t *testing.T) {
	const n, rounds = 8, 200
	for r := 0; r < rounds; r++ {
		ports := FreePorts(t, n)
		if len(ports) != n {
			t.Fatalf("round %d: got %d ports, want %d", r, len(ports), n)
		}
		seen := map[int]bool{}
		for _, p := range ports {
			if p <= 0 {
				t.Fatalf("round %d: bad port %d", r, p)
			}
			if seen[p] {
				t.Fatalf("round %d: duplicate port %d in %v", r, p, ports)
			}
			seen[p] = true
		}
	}
}

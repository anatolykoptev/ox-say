package meeting

import "testing"

// relaxedRatio lists the samples allowed to be estimated looser than
// maxEstimateRatio, each with the reason. None today: Thai and Arabic sat at
// 3.0 until #545 stopped charging their spaces a whole token (the tokenizer
// merges them into the next word).
var relaxedRatio = map[string]float64{}

const maxEstimateRatio = 2.5

// The estimator is an upper bound of the real tokenizer on every sample, and
// not an absurd one: a bound that grows too loose shrinks chunks for nothing.
// The oracle is llama-server /tokenize (Qwen3.5 vocab), see
// notes_calibration_data_test.go for where each count came from; the
// weights in runeUnits are fitted to it, never the reverse.
//
// Mutations, each RED: notes.go runeUnits returns 3 for ASCII digits (the
// digits, digits_only and chat samples fall under the real count); the
// symbol/emoji case dropped into the "any other script" 20 (the emoji
// sample falls under).
func TestEstimateTokensCoversTheRealTokenizer(t *testing.T) {
	for _, tc := range tokenCalibration {
		got := EstimateTokens(tc.text)
		ratio := float64(got) / float64(tc.real)
		limit := maxEstimateRatio
		if r, ok := relaxedRatio[tc.name]; ok {
			limit = r
		}
		t.Logf("%-12s real %4d estimate %4d ratio %.2f", tc.name, tc.real, got, ratio)
		if got < tc.real {
			t.Errorf("%s: EstimateTokens = %d, under the real %d tokens", tc.name, got, tc.real)
		}
		if ratio > limit {
			t.Errorf("%s: EstimateTokens = %d is %.2fx the real %d tokens, over the %.1fx bound", tc.name, got, ratio, tc.real, limit)
		}
	}
}

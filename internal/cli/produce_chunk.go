package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
)

// chunkDetail is GET /v1/produce/{id}/chunks/{n}: one chunk with its takes.
type chunkDetail struct {
	Text    string   `json:"text"`
	Status  string   `json:"status"`
	Pick    string   `json:"pick"`
	Reasons []string `json:"reasons"`
	Takes   []struct {
		Key       string  `json:"key"`
		DurationS float64 `json:"duration_s"`
		WER       float64 `json:"wer"`
		Passed    bool    `json:"passed"`
	} `json:"takes"`
	TakeFiles map[string]string `json:"take_files"`
}

func fetchChunk(id string, n int) (chunkDetail, error) {
	var d chunkDetail
	data, err := produceCall(http.MethodGet, producePath+"/"+url.PathEscape(id)+"/chunks/"+strconv.Itoa(n), nil)
	if err != nil {
		return d, err
	}
	if err := json.Unmarshal(data, &d); err != nil {
		return d, fmt.Errorf("unreadable answer from the daemon: %w", err)
	}
	return d, nil
}

// print writes the chunk: its text, the current pick and every take with the
// file to listen to.
func (d *chunkDetail) print(w io.Writer, id string, n int) {
	outf(w, "chunk %d (%s): %s\n", n, d.Status, d.Text)
	for _, r := range d.Reasons {
		outf(w, "  problem: %s\n", r)
	}
	for _, t := range d.Takes {
		d.printTake(w, id, n, t.Key)
	}
}

// printTake writes one take's line; the pick marks the one in the file now.
func (d *chunkDetail) printTake(w io.Writer, id string, n int, key string) {
	for _, t := range d.Takes {
		if t.Key != key {
			continue
		}
		mark := " "
		if key == d.Pick {
			mark = "*"
		}
		verdict := "passed the checks"
		if !t.Passed {
			verdict = "failed the checks"
		}
		outf(w, " %s take %s  %.1f s  word errors %.0f%%  %s\n    listen: %s\n    use it: ox-say produce chunk %s %d --pick %s\n",
			mark, t.Key, t.DurationS, t.WER*percent, verdict, d.TakeFiles[key], id, n, key)
	}
}

const percent = 100

// newTakeKeys are the keys in after that were not in before, in order.
func newTakeKeys(before, after *chunkDetail) []string {
	had := map[string]bool{}
	for _, t := range before.Takes {
		had[t.Key] = true
	}
	var out []string
	for _, t := range after.Takes {
		if !had[t.Key] {
			out = append(out, t.Key)
		}
	}
	return out
}

// chunkRequestBody builds the request of `produce chunk` from its flags;
// ok is false when not exactly one of --regen, --pick, --text is given.
func (c *produceCmd) chunkRequestBody() (map[string]any, bool) {
	given := 0
	body := map[string]any{}
	if raw, ok := c.vals["regen"]; ok {
		given++
		n, err := strconv.Atoi(raw)
		if err != nil {
			outf(c.err, "ox-say: --regen %s: not a number\n", raw)
			return nil, false
		}
		body["action"], body["takes"] = "regenerate", n
	}
	if k, ok := c.vals["pick"]; ok {
		given++
		body["action"], body["take"] = "pick", k
	}
	if t, ok := c.vals["text"]; ok {
		given++
		body["action"], body["text"] = "edit", t
	}
	if given != 1 {
		outln(c.err, "ox-say: give exactly one of --regen N, --pick KEY, --text \"…\"")
		return nil, false
	}
	return body, true
}

// chunk is `produce chunk <id> <n> --regen|--pick|--text`.
func (c *produceCmd) chunk(pos []string) int {
	if len(pos) != 2 {
		outln(c.err, produceUsage)
		return exitUsage
	}
	id := pos[0]
	n, err := strconv.Atoi(pos[1])
	if err != nil || n < 0 {
		outf(c.err, "ox-say: %s: not a chunk number\n", pos[1])
		return exitUsage
	}
	body, ok := c.chunkRequestBody()
	if !ok {
		return exitUsage
	}
	var before chunkDetail
	if body["action"] == "regenerate" {
		// Regenerate keeps the person's pick: the new takes are found by
		// comparing with the takes the chunk had.
		if before, err = fetchChunk(id, n); err != nil {
			return failProduce(c.err, err)
		}
	}
	path := producePath + "/" + url.PathEscape(id) + "/chunks/" + strconv.Itoa(n)
	data, err := produceCall(http.MethodPost, path, body)
	if err != nil {
		return failProduce(c.err, err)
	}
	code, final := c.follow(data)
	if body["action"] != "regenerate" || final == nil || (final.Status != statusDone && final.Status != statusReview) {
		return code // no new takes to show: no wait, or the run did not finish
	}
	c.showNewTakes(id, n, &before)
	return code
}

// showNewTakes prints the takes a regenerate added and the exact command that
// keeps one of them; the current pick stays until then.
func (c *produceCmd) showNewTakes(id string, n int, before *chunkDetail) {
	after, err := fetchChunk(id, n)
	if err != nil {
		outf(c.err, "ox-say: could not read the new takes: %v\n", err)
		return
	}
	keys := newTakeKeys(before, &after)
	if len(keys) == 0 {
		outf(c.out, "no new takes were added to chunk %d: see ox-say produce status %s --chunk %d\n", n, id, n)
		return
	}
	outf(c.out, "new takes for chunk %d (the current pick is unchanged until you choose one):\n", n)
	for _, k := range keys {
		after.printTake(c.out, id, n, k)
	}
}

package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"net/url"
)

const vocabUsage = "usage: ox-say vocab add <heard> <meant> [--context <sentence>] | ls | ok <id> | rm <id>"

func cmdVocab(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		outln(stderr, vocabUsage)
		return 2
	}
	switch args[0] {
	case "add":
		return cmdVocabAdd(args[1:], stdout, stderr)
	case "ls", "list":
		return cmdVocabList(stdout, stderr)
	case "ok":
		return cmdVocabSet(args[1:], "approve", stdout, stderr)
	case "rm":
		return cmdVocabSet(args[1:], "reject", stdout, stderr)
	}
	outln(stderr, vocabUsage)
	return 2
}

type vocabPair struct {
	ID     string `json:"id"`
	Heard  string `json:"heard"`
	Meant  string `json:"meant"`
	Status string `json:"status"`
	Seen   int    `json:"seen"`
}

func printPair(w io.Writer, p vocabPair) {
	fmt.Fprintf(w, "%s  %s  %s → %s  (seen %d)\n", p.ID, p.Status, p.Heard, p.Meant, p.Seen)
}

func printPairBody(stdout, stderr io.Writer, body []byte) int {
	var p vocabPair
	if err := json.Unmarshal(body, &p); err != nil {
		fmt.Fprintln(stderr, "ox-say: unreadable answer:", err)
		return 1
	}
	printPair(stdout, p)
	return 0
}

func cmdVocabAdd(args []string, stdout, stderr io.Writer) int {
	vals, pos, err := pullFlags(args, "context")
	if err != nil {
		fmt.Fprintln(stderr, "ox-say:", err)
		return 2
	}
	if len(pos) != 2 {
		outln(stderr, vocabUsage)
		return 2
	}
	body, err := postJSON(daemonURL()+"/v1/glossary", map[string]any{
		"heard": pos[0], "meant": pos[1], "context": vals["context"],
	})
	if err != nil {
		return failDaemon(stderr, err)
	}
	return printPairBody(stdout, stderr, body)
}

func cmdVocabList(stdout, stderr io.Writer) int {
	resp, err := httpClient.Get(daemonURL() + "/v1/glossary")
	if err != nil {
		return failDaemon(stderr, daemonErr(err))
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode/100 != 2 {
		fmt.Fprintln(stderr, "ox-say:", extractErr(raw))
		return 1
	}
	var list struct {
		Pairs []vocabPair `json:"pairs"`
	}
	if err := json.Unmarshal(raw, &list); err != nil {
		fmt.Fprintln(stderr, "ox-say: unreadable answer:", err)
		return 1
	}
	for _, p := range list.Pairs {
		printPair(stdout, p)
	}
	return 0
}

func cmdVocabSet(args []string, action string, stdout, stderr io.Writer) int {
	if len(args) != 1 {
		outln(stderr, vocabUsage)
		return 2
	}
	body, err := postJSON(daemonURL()+"/v1/glossary/"+url.PathEscape(args[0])+"/"+action, map[string]any{})
	if err != nil {
		return failDaemon(stderr, err)
	}
	return printPairBody(stdout, stderr, body)
}

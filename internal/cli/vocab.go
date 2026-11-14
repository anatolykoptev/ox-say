package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/term"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/daemon"
)

const vocabUsage = "usage: ox-say vocab add <heard> <meant> [--context <sentence>] | ls | ok <id> | rm <id>"

// vocabIn and vocabTTY are the test seams for the person check: production
// reads the answer from stdin and insists both stdin and stdout are real
// terminals, so an agent piping the command cannot settle a pair.
var (
	vocabIn  io.Reader = os.Stdin
	vocabTTY           = func(in io.Reader, out io.Writer) bool {
		inf, inOK := in.(*os.File)
		outf, outOK := out.(*os.File)
		return inOK && outOK && term.IsTerminal(int(inf.Fd())) && term.IsTerminal(int(outf.Fd()))
	}
)

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

// vocabPairs fetches every pair the daemon holds.
func vocabPairs() ([]vocabPair, error) {
	resp, err := httpClient.Get(daemonURL() + "/v1/glossary")
	if err != nil {
		return nil, daemonErr(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("daemon: %s: %s", resp.Status, extractErr(raw))
	}
	var list struct {
		Pairs []vocabPair `json:"pairs"`
	}
	if err := json.Unmarshal(raw, &list); err != nil {
		return nil, err
	}
	return list.Pairs, nil
}

// vocabFind returns the pair id names.
func vocabFind(id string) (vocabPair, error) {
	pairs, err := vocabPairs()
	if err != nil {
		return vocabPair{}, err
	}
	for _, p := range pairs {
		if p.ID == id {
			return p, nil
		}
	}
	return vocabPair{}, fmt.Errorf("no such pair %q — `ox-say vocab ls` lists them", id)
}

// vocabConfirmed reports whether the typed answer is a bare "y" — the only
// yes; enter, n, yes, anything else: all no.
func vocabConfirmed(in io.Reader) bool {
	var line string
	if _, err := fmt.Fscanln(in, &line); err != nil {
		return false
	}
	return line == "y"
}

// ownerToken reads the bearer the daemon wrote at $OX_SAY_HOME/owner.token.
func ownerToken() (string, error) {
	raw, err := os.ReadFile(filepath.Join(config.Home(), daemon.OwnerTokenFile))
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(raw)), nil
}

// vocabSet POSTs an owner-only action with the owner bearer.
func vocabSet(url, token string) ([]byte, error) {
	req, err := http.NewRequest(http.MethodPost, url, strings.NewReader("{}"))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, daemonErr(err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("daemon: %s: %s", resp.Status, extractErr(data))
	}
	return data, nil
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
	pairs, err := vocabPairs()
	if err != nil {
		return failDaemon(stderr, err)
	}
	for _, p := range pairs {
		printPair(stdout, p)
	}
	return 0
}

// cmdVocabSet runs the owner-only verbs. The daemon refuses them without
// the owner bearer, and the command refuses to even ask unless both stdin
// and stdout are terminals — settling a pair is a person's decision, made
// by reading the pair and typing y, never an agent's.
func cmdVocabSet(args []string, action string, stdout, stderr io.Writer) int {
	if len(args) != 1 {
		outln(stderr, vocabUsage)
		return 2
	}
	if !vocabTTY(vocabIn, stdout) {
		fmt.Fprintf(stderr, "ox-say: vocab %s asks a person — run it at a terminal (stdin and stdout both)\n", action)
		return 2
	}
	p, err := vocabFind(args[0])
	if err != nil {
		return failDaemon(stderr, err)
	}
	printPair(stdout, p)
	word := "Approve"
	if action == "reject" {
		word = "Reject"
	}
	fmt.Fprintf(stdout, "%s? [y/N] ", word)
	if !vocabConfirmed(vocabIn) {
		fmt.Fprintf(stdout, "left %s\n", p.Status)
		return 1
	}
	tok, err := ownerToken()
	if err != nil {
		fmt.Fprintf(stderr, "ox-say: cannot read %s (the daemon writes it on start): %v\n",
			filepath.Join(config.Home(), daemon.OwnerTokenFile), err)
		return 1
	}
	body, err := vocabSet(daemonURL()+"/v1/glossary/"+url.PathEscape(args[0])+"/"+action, tok)
	if err != nil {
		return failDaemon(stderr, err)
	}
	return printPairBody(stdout, stderr, body)
}

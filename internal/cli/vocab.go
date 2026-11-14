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

// ownerKeyUnreadable is all a failed owner.token read says: the path and the fs
// error name the daemon home, which stays out of terminals and logs.
const ownerKeyUnreadable = "ox-say: cannot read the owner key (the daemon writes it on start; is it running?)"

const vocabUsage = "usage: ox-say vocab add <heard> <meant> [--context <sentence>] | ls | ok <id> | rm <id> | edit <id> <meant> | purge <id>\n" +
	"ok, rm, edit and purge are owner-only: they ask a person at a terminal. purge deletes the pair for good (rm keeps a rejected tombstone)."

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
	case "edit":
		return cmdVocabEdit(args[1:], stdout, stderr)
	case "purge":
		return cmdVocabPurge(args[1:], stdout, stderr)
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

// vocabOwnerCall sends an owner-only request with the owner bearer.
func vocabOwnerCall(method, url, token, body string) ([]byte, error) {
	req, err := http.NewRequest(method, url, strings.NewReader(body))
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
		fmt.Fprintln(stderr, ownerKeyUnreadable)
		return 1
	}
	body, err := vocabOwnerCall(http.MethodPost, daemonURL()+"/v1/glossary/"+url.PathEscape(args[0])+"/"+action, tok, "{}")
	if err != nil {
		return failDaemon(stderr, err)
	}
	return printPairBody(stdout, stderr, body)
}

// vocabOwnerGate is the shared start of the owner verbs that change or remove
// a pair: refuse without a terminal, show the pair, ask y/N, read the bearer.
// ok is false when the command ended here, with its exit code.
func vocabOwnerGate(id, verb, question string, stdout, stderr io.Writer) (tok string, code int, ok bool) {
	if !vocabTTY(vocabIn, stdout) {
		fmt.Fprintf(stderr, "ox-say: vocab %s asks a person — run it at a terminal (stdin and stdout both)\n", verb)
		return "", 2, false
	}
	p, err := vocabFind(id)
	if err != nil {
		return "", failDaemon(stderr, err), false
	}
	printPair(stdout, p)
	fmt.Fprintf(stdout, "%s [y/N] ", question)
	if !vocabConfirmed(vocabIn) {
		fmt.Fprintf(stdout, "left %s\n", p.Status)
		return "", 1, false
	}
	tok, err = ownerToken()
	if err != nil {
		fmt.Fprintln(stderr, ownerKeyUnreadable)
		return "", 1, false
	}
	return tok, 0, true
}

// cmdVocabEdit gives a pair a different meant form. Owner-only, like ok and rm.
func cmdVocabEdit(args []string, stdout, stderr io.Writer) int {
	if len(args) != 2 {
		outln(stderr, vocabUsage)
		return 2
	}
	tok, code, ok := vocabOwnerGate(args[0], "edit", "Change it to “"+args[1]+"”?", stdout, stderr)
	if !ok {
		return code
	}
	reqBody, err := json.Marshal(map[string]string{"meant": args[1]})
	if err != nil {
		fmt.Fprintln(stderr, "ox-say:", err)
		return 1
	}
	body, err := vocabOwnerCall(http.MethodPost, daemonURL()+"/v1/glossary/"+url.PathEscape(args[0])+"/edit", tok, string(reqBody))
	if err != nil {
		return failDaemon(stderr, err)
	}
	return printPairBody(stdout, stderr, body)
}

// cmdVocabPurge deletes a pair for good, with no tombstone. Owner-only.
func cmdVocabPurge(args []string, stdout, stderr io.Writer) int {
	if len(args) != 1 {
		outln(stderr, vocabUsage)
		return 2
	}
	tok, code, ok := vocabOwnerGate(args[0], "purge", "Delete it for good?", stdout, stderr)
	if !ok {
		return code
	}
	if _, err := vocabOwnerCall(http.MethodDelete, daemonURL()+"/v1/glossary/"+url.PathEscape(args[0]), tok, ""); err != nil {
		return failDaemon(stderr, err)
	}
	fmt.Fprintf(stdout, "deleted %s\n", args[0])
	return 0
}

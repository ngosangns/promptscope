package updater

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestParseReleaseRequiresDigestAndExactURL(t *testing.T) {
	const digest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	good := releaseJSON("v1.2.3", "promptscope-v1.2.3-darwin-arm64", 12, digest, false, false)
	release, err := parseRelease(good)
	if err != nil {
		t.Fatal(err)
	}
	if release.version != "1.2.3" || release.sha256 != strings.TrimPrefix(digest, "sha256:") {
		t.Fatalf("parsed %+v", release)
	}

	cases := []struct {
		name string
		body string
		want string
	}{
		{"draft", releaseJSON("v1.2.3", "promptscope-v1.2.3-darwin-arm64", 12, digest, true, false), "draft"},
		{"prerelease", releaseJSON("v1.2.3", "promptscope-v1.2.3-darwin-arm64", 12, digest, false, true), "prerelease"},
		{"tag", releaseJSON("1.2.3", "promptscope-v1.2.3-darwin-arm64", 12, digest, false, false), "not vX.Y.Z"},
		{"missing asset", releaseJSON("v1.2.3", "other", 12, digest, false, false), "no asset"},
		{"no digest", releaseJSON("v1.2.3", "promptscope-v1.2.3-darwin-arm64", 12, "", false, false), "digest"},
		{"bad digest", releaseJSON("v1.2.3", "promptscope-v1.2.3-darwin-arm64", 12, "md5:abcd", false, false), "sha256"},
		{"wrong url", strings.ReplaceAll(good, "https://github.com/ngosangns/promptscope", "https://evil.example"), "download url"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := parseRelease(tc.body)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("got %v, want substring %q", err, tc.want)
			}
		})
	}
}

func TestRunRefusesDowngradeAndForeignBinary(t *testing.T) {
	home := t.TempDir()
	link := filepath.Join(home, ".local", "bin", "promptscope")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("missing", link); err != nil {
		t.Fatal(err)
	}
	body := releaseJSON("v1.0.0", "promptscope-v1.0.0-darwin-arm64", 4, "sha256:"+strings.Repeat("ab", 32), false, false)
	transport := staticTransport{latest: body}

	var out, errOut strings.Builder
	err := Run(context.Background(), Options{
		Args:              []string{"--check"},
		Version:           "1.2.0",
		Home:              home,
		CurrentExe:        filepath.Join(home, ".local", "share", "promptscope", "bin", "promptscope-1.2.0"),
		PlatformSupported: boolPtr(true),
		Transport:         transport,
		Stdout:            &out,
		Stderr:            &errOut,
	})
	if err != nil {
		t.Fatal(err, errOut.String())
	}
	if !strings.Contains(out.String(), "newer than the latest release") {
		t.Fatalf("stdout %q", out.String())
	}

	errOut.Reset()
	err = Run(context.Background(), Options{
		Version:           "1.0.0",
		Home:              home,
		CurrentExe:        filepath.Join(home, "elsewhere", "promptscope"),
		PlatformSupported: boolPtr(true),
		Transport:         transport,
		Stderr:            &errOut,
	})
	if ExitCode(err) != 1 || !strings.Contains(errOut.String(), "only replaces") {
		t.Fatalf("exit %v stderr %q", err, errOut.String())
	}
}

func TestRunInstallsWhenDigestMatches(t *testing.T) {
	home := t.TempDir()
	current := filepath.Join(home, ".local", "share", "promptscope", "bin", "promptscope-1.0.0")
	if err := os.MkdirAll(filepath.Dir(current), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(current, []byte("old"), 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(home, ".local", "bin", "promptscope")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../share/promptscope/bin/promptscope-1.0.0", link); err != nil {
		t.Fatal(err)
	}

	payload := []byte("#!/bin/sh\n")
	sum := sha256.Sum256(payload)
	body := releaseJSON("v1.1.0", "promptscope-v1.1.0-darwin-arm64", uint64(len(payload)), "sha256:"+hex.EncodeToString(sum[:]), false, false)

	var out strings.Builder
	err := Run(context.Background(), Options{
		Version:           "1.0.0",
		Home:              home,
		CurrentExe:        current,
		PlatformSupported: boolPtr(true),
		Transport:         staticTransport{latest: body, payload: payload},
		Smoke:             func(string) (string, error) { return "1.1.0", nil },
		Stdout:            &out,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "updated promptscope to 1.1.0") {
		t.Fatalf("stdout %q", out.String())
	}
	target, err := os.Readlink(link)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(target, "promptscope-1.1.0") {
		t.Fatalf("link target %s", target)
	}
	if _, err := os.Stat(current); err != nil {
		t.Fatal("previous generation was removed", err)
	}
}

func TestRunRejectsChecksumMismatch(t *testing.T) {
	home := t.TempDir()
	current := filepath.Join(home, ".local", "share", "promptscope", "bin", "promptscope-1.0.0")
	if err := os.MkdirAll(filepath.Dir(current), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(current, []byte("old"), 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(home, ".local", "bin", "promptscope")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(current, link); err != nil {
		t.Fatal(err)
	}
	payload := []byte("nope")
	body := releaseJSON("v1.1.0", "promptscope-v1.1.0-darwin-arm64", uint64(len(payload)), "sha256:"+strings.Repeat("ab", 32), false, false)
	var errOut strings.Builder
	err := Run(context.Background(), Options{
		Version:           "1.0.0",
		Home:              home,
		CurrentExe:        current,
		PlatformSupported: boolPtr(true),
		Transport:         staticTransport{latest: body, payload: payload},
		Stderr:            &errOut,
	})
	if ExitCode(err) != 1 || !strings.Contains(errOut.String(), "sha256 mismatch") {
		t.Fatalf("exit %v stderr %q", err, errOut.String())
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(current), "promptscope-1.1.0")); !os.IsNotExist(err) {
		t.Fatal("mismatched download was installed")
	}
}

type staticTransport struct {
	latest  string
	payload []byte
}

func (s staticTransport) FetchLatest(context.Context) (string, error) { return s.latest, nil }

func (s staticTransport) Download(_ context.Context, rawURL, dest string) error {
	payload := s.payload
	if strings.Contains(rawURL, "promptscope-update-") {
		payload = []byte("updater!")
	}
	return os.WriteFile(dest, payload, 0o644)
}

func releaseJSON(tag, asset string, size uint64, digest string, draft, prerelease bool) string {
	companion := "promptscope-update-" + tag + "-darwin-arm64"
	return `{
		"tag_name": "` + tag + `",
		"draft": ` + strconv.FormatBool(draft) + `,
		"prerelease": ` + strconv.FormatBool(prerelease) + `,
		"assets": [
			` + assetObject(tag, asset, size, digest) + `,
			` + assetObject(tag, companion, 8, "sha256:2c901957c30a124316f313f48f1b42e697cb14606b0f80872365e054d62291bb") + `
		]
	}`
}

func assetObject(tag, asset string, size uint64, digest string) string {
	url := "https://github.com/ngosangns/promptscope/releases/download/" + tag + "/" + asset
	digestJSON := "null"
	if digest != "" {
		digestJSON = `"` + digest + `"`
	}
	return `{
		"name": "` + asset + `",
		"state": "uploaded",
		"size": ` + strconv.FormatUint(size, 10) + `,
		"digest": ` + digestJSON + `,
		"browser_download_url": "` + url + `"
	}`
}

func boolPtr(v bool) *bool { return &v }
